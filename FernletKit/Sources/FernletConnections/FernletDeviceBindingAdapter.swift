// FernletDeviceBindingAdapter.swift
// FernletConnections
//
// ProximityKit plan step A0.2.9 (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md §4 A0.2, "Injected by
// the host: … the `DeviceBindingID`, so its keychain row stays shared with Fernlet's private stores"):
// Fernlet's answer to ProximityKit's `ProximityInstallBinding`. ProximityKit's copy of the column seal
// asks the host for the install binding instead of reading FernletCrypto's `DeviceBindingID` itself,
// and this adapter answers with `DeviceBindingID`, so the mesh stores and Fernlet's sealed private
// stores keep sealing under the one row they always shared.

import FernletCrypto
import Foundation
import ProximityKit
import Security

/// Fernlet's install binding for ProximityKit: FernletCrypto's `DeviceBindingID`, read at each call.
///
/// **Delegation, never a copy.** A seal reads `DeviceBindingID.current()`, which mints the row on first
/// use and returns it only after a read-back proves it durable; an open reads
/// `DeviceBindingID.currentForOpen()`, which never mints and throws a retryable `ReadError` when the
/// keychain read fails, translated here into ProximityKit's ``ProximityInstallBindingReadError`` with the
/// same status. Both are called at the moment ProximityKit asks, so `DeviceBindingID` keeps its one
/// process-wide cache, its one mint path and its one task-local test seam: an override in force at that
/// moment, including one a test flips partway through an operation, reaches the mesh stores exactly as
/// it reached them when ProximityKit called `DeviceBindingID` itself. A second reader of the same row
/// would agree on the bytes and split everything else.
///
/// **Where it is handed over.** The app's `ProximityHost` adapter answers
/// `proximityInstallBinding` with one, and `FernletStore`'s two storage scopes carry it to the stores.
/// The test target's `ProximityHost` doubles and store fixtures carry one too, so every
/// `DeviceBindingID.$testOverride` in the suites still decides what the stores seal and open under.
///
/// `nonisolated` against this module's `defaultIsolation(MainActor.self)`, and `Sendable`: it holds no
/// state, and ProximityKit's column seal calls it synchronously from inside its nonisolated stores.
public nonisolated struct FernletDeviceBindingAdapter: ProximityInstallBinding {

    /// The adapter. It holds nothing; every read goes to `DeviceBindingID`.
    public init() {}

    /// This install's `DeviceBindingID`, read for `access`.
    ///
    /// - Parameter access: ``ProximityInstallBindingAccess/seal`` reads `DeviceBindingID.current()`,
    ///   which may mint and answers `nil` for any failure; ``ProximityInstallBindingAccess/open`` reads
    ///   `DeviceBindingID.currentForOpen()`, which never mints and answers `nil` only for an absent row.
    /// - Returns: The 16-byte binding, or `nil`.
    /// - Throws: ``ProximityInstallBindingReadError`` when an open's keychain read failed.
    public func read(for access: ProximityInstallBindingAccess) throws(ProximityInstallBindingReadError) -> Data? {
        switch access {
        case .seal:
            return DeviceBindingID.current()
        case .open:
            return try Self.currentForOpen()
        }
    }

    /// `DeviceBindingID.currentForOpen()`, its `ReadError` translated with the status it carries.
    ///
    /// `currentForOpen()` throws nothing but `ReadError`, but it is declared with an untyped `throws`, so
    /// the compiler needs a second arm. A failure of any other kind would leave the row's state just as
    /// unknown, which is what the retryable error says, so it is translated too, as
    /// `errSecInternalError`.
    private static func currentForOpen() throws(ProximityInstallBindingReadError) -> Data? {
        do {
            return try DeviceBindingID.currentForOpen()
        } catch let error as DeviceBindingID.ReadError {
            throw ProximityInstallBindingReadError(status: error.status)
        } catch {
            throw ProximityInstallBindingReadError(status: errSecInternalError)
        }
    }
}
