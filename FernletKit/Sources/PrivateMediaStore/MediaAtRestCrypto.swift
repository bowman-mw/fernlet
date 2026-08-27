import Foundation
import CryptoKit
import FernletCrypto
import FernletFoundation

/// The at-rest box FORMAT, addressable without a key.
///
/// The marker bytes used to live only as a `private` member of the ``PrivateMediaKeyProviding``
/// extension below, which put them out of reach of anything that is not a key provider — including
/// ``MediaAtRestFormatCensus``, which must recognise the format precisely because it holds no key.
/// So the bytes live here, in one place, and the extension's own alias reads them from here.
/// `internal`, not `public`: the census shares this constant so the two can never disagree, while
/// the test suites deliberately re-spell the marker themselves (see
/// `OwnPhotoKeyMigrationTests.opens`) — a fixture that asked production what the format is could
/// never notice production changing it.
///
/// Concurrency: `nonisolated` namespace of pure constants; no state.
enum MediaAtRestFormat {
    /// The four ASCII bytes `FMA2`, written in the CLEAR at offset 0 of every box the current
    /// writers produce. Cleartext on purpose: it is a format tag, carries nothing about the
    /// plaintext, and is what makes the two generations tellable apart without a key.
    static var v2Marker: Data { Data("FMA2".utf8) }

    /// Length of ``v2Marker`` — derived from it rather than spelled again, so a marker change
    /// cannot leave a stale length behind.
    static var v2MarkerByteCount: Int { v2Marker.count }
}

/// Shared AES-256-GCM at-rest helpers for the module's media stores.
///
/// Every sealed store here (``PrivateMediaStore``, ``MealPhotoStore``, ``ProgressPhotoStore``)
/// used to hand-roll the same seal / open / seal-then-write idiom against its injected
/// ``PrivateMediaKeyProviding``; these internal helpers are that idiom, verbatim, in one place.
/// They are deliberately dumb about policy: a nil key or a failed open simply returns nil/false,
/// and each call site keeps its own fail-closed decision (skip the write, fall through to a
/// legacy-plaintext branch, refuse the whole save) exactly where it was. In particular the
/// nil-key divergence between `PrivateMediaStore.openSealed` (explicit nil-key guard before
/// calling ``gcmOpen(_:)``) and `MealPhotoStore.imageData(for:)` (no such guard, so a nil key
/// falls through to that store's legacy-plaintext branch) is preserved per-store behavior,
/// not something these helpers arbitrate.
extension PrivateMediaKeyProviding {
    /// Prefix on purpose-authenticated at-rest boxes. Previous boxes began directly with the GCM
    /// nonce and remain read-compatible so upgrade-on-read can rewrite them in this format.
    ///
    /// A local alias for ``MediaAtRestFormat/v2Marker``, which is where the bytes actually live: a
    /// static member of a protocol extension cannot be named without a conforming type, and the
    /// format census must recognise the marker holding no key provider at all.
    private static var atRestFormatV2: Data { MediaAtRestFormat.v2Marker }

    /// Seals `plaintext` with AES-256-GCM under ``mediaKey()``, returning the combined
    /// (nonce + ciphertext + tag) representation, or nil when no key is available or sealing fails.
    func gcmSeal(_ plaintext: Data, purpose: CryptographicPurpose) -> Data? {
        guard let key = mediaKey() else { return nil }
        guard let combined = try? AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: purpose.data
        ).combined else { return nil }
        return Self.atRestFormatV2 + combined
    }

    /// Opens AES-256-GCM combined bytes sealed under ``mediaKey()``. Returns nil when no key is
    /// available, the bytes aren't a well-formed sealed box, or authentication/decryption fails —
    /// callers branch on nil to fail closed (or to try their own legacy-plaintext path).
    func gcmOpen(_ stored: Data, purpose: CryptographicPurpose) -> Data? {
        guard let key = mediaKey() else { return nil }
        if stored.starts(with: Self.atRestFormatV2) {
            guard let currentBox = try? AES.GCM.SealedBox(
                combined: stored.dropFirst(Self.atRestFormatV2.count)
            ) else { return nil }
            return try? AES.GCM.open(currentBox, using: key, authenticating: purpose.data)
        }
        guard let box = try? AES.GCM.SealedBox(combined: stored) else { return nil }
        return try? AES.GCM.open(box, using: key) // cryptographic-domain: legacy-read
    }

    /// Seals `plaintext` via ``gcmSeal(_:)`` and atomically writes the ciphertext to `url` with
    /// `.completeFileProtection`. Returns whether the bytes reached disk; on a nil key, a seal
    /// failure, or a write error NOTHING is written (fail-closed — plaintext never touches disk).
    ///
    /// Deliberately NOT `@discardableResult` (R7): the `Bool` is a success/failure signal, so every
    /// caller must decide. Callers for whom a failed write is genuinely non-fatal use
    /// ``sealAndWriteBestEffort(_:to:reason:)``, which makes that decision explicit and logged.
    func sealAndWrite(_ plaintext: Data, to url: URL, purpose: CryptographicPurpose) -> Bool {
        guard let sealed = gcmSeal(plaintext, purpose: purpose) else { return false }
        do {
            try sealed.write(to: url, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            return false
        }
    }

    /// Best-effort variant for the upgrade-on-read re-seals: the caller has already returned usable
    /// bytes, so a failed write only means the file stays in its old generation and the next pass
    /// retries. The failure is audit-logged rather than dropped.
    ///
    /// - Parameters:
    ///   - plaintext: Bytes to seal.
    ///   - url: Destination file.
    ///   - reason: Short label for the re-seal site, recorded in the audit line.
    func sealAndWriteBestEffort(
        _ plaintext: Data,
        to url: URL,
        purpose: CryptographicPurpose,
        reason: StaticString
    ) {
        guard sealAndWrite(plaintext, to: url, purpose: purpose) else {
            FernletAuditLog.log(
                "privateMedia.resealFailed",
                context: ["reason": "\(reason)", "file": url.lastPathComponent]
            )
            return
        }
    }
}
