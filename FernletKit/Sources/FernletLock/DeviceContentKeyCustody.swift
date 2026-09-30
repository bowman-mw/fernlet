// DeviceContentKeyCustody.swift
// Fernlet
//
// The no-passcode home of the hub content key (period-data design 2026-09-30, §4.2): the frozen
// at-rest format of the device-custody row, the seam the row's Secure-Enclave wrap is reached
// through, and the device-owner check that guards adopting that key under a new passcode (§4.4).
// Everything that touches the service's private state (the row's reads, writes and deletes) stays
// in FernletLockService.swift; this file holds only the pieces that are pure or self-contained.

import Foundation
import FernletFoundation
import LocalAuthentication
import Security

/// The frozen at-rest format of ``LockKeychainKey/deviceContentKey``: a four-byte marker, then the
/// body.
///
/// Two markers exist and neither may ever change, because the row outlives every build that reads
/// it:
/// - `FDS1` + an ECIES blob from the Secure-Enclave wrap. **On hardware whose enclave is available
///   this is the only format ever written**: a wrap that fails throws a retryable error and nothing
///   is persisted, so an enclave device never falls back to holding the raw key.
/// - `FDR1` + the raw 32-byte content key, written only where no enclave exists (the simulator on
///   non-Apple-silicon hosts, SE-less hardware). A reader that finds `FDR1` on enclave hardware (a
///   simulator-to-device restore, or an older build) upgrades it in place.
///
/// An unknown marker is **retryable**, never terminal: a downgraded build reading a newer build's
/// format must not route the user to a destructive reset.
///
/// `LockWrapFormatCensus` classifies the row against these same constants, so the census and the
/// writer cannot drift apart. Pure value code; `nonisolated`.
nonisolated enum DeviceCustodyRecord {
    /// The marker of an enclave-wrapped row.
    static let enclaveWrappedMarker = Data("FDS1".utf8)
    /// The marker of a raw row (hardware with no Secure Enclave only).
    static let rawMarker = Data("FDR1".utf8)
    /// The length every marker has.
    static let markerLength = 4

    /// What a stored row decodes to, before anything is opened.
    enum Body: Equatable {
        /// `FDS1`: the ECIES blob to hand to the enclave.
        case enclaveWrapped(Data)
        /// `FDR1`: the raw content key bytes (length not yet checked).
        case raw(Data)
        /// Too short, or a marker this build does not know. Retryable, never terminal.
        case unknownMarker
    }

    /// The row value for an enclave-wrapped content key.
    static func encodeEnclaveWrapped(_ blob: Data) -> Data {
        enclaveWrappedMarker + blob
    }

    /// The row value for a raw content key (hardware with no enclave only).
    static func encodeRaw(_ contentKey: Data) -> Data {
        rawMarker + contentKey
    }

    /// Splits a stored row into its marker's meaning and its body. Never opens anything.
    static func decode(_ value: Data) -> Body {
        guard value.count > markerLength else { return .unknownMarker }
        let body = Data(value.dropFirst(markerLength))
        if value.starts(with: enclaveWrappedMarker) { return .enclaveWrapped(body) }
        if value.starts(with: rawMarker) { return .raw(body) }
        return .unknownMarker
    }
}

/// The seam the device-custody row reaches the Secure Enclave through.
///
/// Production is ``SecureEnclaveDeviceContentKeyWrapper`` (the real enclave, through
/// `SecureEnclaveContentKeyWrap`). Tests inject a fake enclave so the `FDS1` classification — terminal
/// versus retryable, a nil wrap refusing to fall back to `FDR1` — runs in CI on any host, and a fake
/// "no enclave" so the `FDR1` branch runs on Apple-silicon simulators, whose enclave is real.
///
/// Scope: the device row only. The passcode custody (`seWrappedContentKey`, the hard binding) keeps
/// calling the enclave directly, exactly as before this seam existed; both use the same enclave key
/// (one tag per keychain service), which is why removing a passcode deletes the passcode custody's
/// BLOB but never the enclave key the device row's `FDS1` blob still needs.
protocol DeviceContentKeyWrapping {
    /// Whether an enclave exists to wrap under. Decides `FDS1` versus `FDR1` at every write.
    var isAvailable: Bool { get }
    /// Wraps `contentKey` and proves a full unwrap round-trip before returning the blob; nil on any
    /// failure (the caller then refuses to persist anything).
    func wrapVerified(_ contentKey: Data, service: String) -> Data?
    /// Opens `blob`, classifying a failure as terminal (the key is provably gone) or transient.
    func unwrapResult(_ blob: Data, service: String) -> SecureEnclaveContentKeyWrap.UnwrapOutcome
}

/// The production ``DeviceContentKeyWrapping``: a stateless pass-through to the real Secure Enclave.
struct SecureEnclaveDeviceContentKeyWrapper: DeviceContentKeyWrapping {
    /// `SecureEnclave.isAvailable`.
    var isAvailable: Bool { SecureEnclaveContentKeyWrap.isAvailable }

    /// `SecureEnclaveContentKeyWrap.wrapVerified(_:service:)`.
    func wrapVerified(_ contentKey: Data, service: String) -> Data? {
        SecureEnclaveContentKeyWrap.wrapVerified(contentKey, service: service)
    }

    /// `SecureEnclaveContentKeyWrap.unwrapResult(_:service:)`.
    func unwrapResult(_ blob: Data, service: String) -> SecureEnclaveContentKeyWrap.UnwrapOutcome {
        SecureEnclaveContentKeyWrap.unwrapResult(blob, service: service)
    }
}

/// The outcome of a fresh device-owner check (Face ID, Touch ID or the iPhone passcode).
public enum DeviceOwnerVerification: Sendable, Equatable {
    /// The system confirmed the device owner.
    case verified
    /// The iPhone has no passcode, so nothing can tell the owner from whoever holds it. Adoption
    /// proceeds with an audit line: the tap gate already shows everything on such a phone.
    case passcodeNotSet
    /// The check was cancelled or failed. Nothing may be written.
    case failed
}

/// The seam `FernletLockService.configure(credential:grantingScope:acknowledgedPriorData:)` asks
/// before a new passcode ADOPTS a device-custody key that already seals entries (§4.4 step 3).
///
/// Without it, anyone holding an unlocked iPhone with no Fernlet passcode could open Settings → App
/// lock (ungated while no passcode exists), set a passcode of their own, and take custody of every
/// private entry away from the owner. Production is ``LocalAuthenticationDeviceOwnerVerifier``;
/// tests inject a scripted answer.
@MainActor
public protocol DeviceOwnerVerifying: AnyObject {
    /// Runs one fresh device-owner check and reports how it ended.
    func verifyDeviceOwner() async -> DeviceOwnerVerification
}

/// The production ``DeviceOwnerVerifying``: `LAContext` with `.deviceOwnerAuthentication`, the same
/// policy Privacy & Data's fresh check uses (biometrics with the iPhone passcode as the fallback).
///
/// A new `LAContext` per check, so an earlier success can never be reused.
public final class LocalAuthenticationDeviceOwnerVerifier: DeviceOwnerVerifying {
    /// The sentence the system sheet shows under its title.
    private let localizedReason: String

    /// Creates a verifier that explains itself with `localizedReason` (already localized).
    public init(localizedReason: String) {
        self.localizedReason = localizedReason
    }

    /// Evaluates `.deviceOwnerAuthentication` once.
    public func verifyDeviceOwner() async -> DeviceOwnerVerification {
        let context = LAContext()
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: localizedReason
            )
            return success ? .verified : .failed
        } catch {
            return Self.classify(error)
        }
    }

    /// Maps a LocalAuthentication failure: only `passcodeNotSet` is not a refusal.
    nonisolated static func classify(_ error: any Error) -> DeviceOwnerVerification {
        guard let laError = error as? LAError, laError.code == .passcodeNotSet else { return .failed }
        return .passcodeNotSet
    }
}
