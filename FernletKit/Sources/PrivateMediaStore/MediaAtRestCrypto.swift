import Foundation
import CryptoKit

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
    /// Seals `plaintext` with AES-256-GCM under ``mediaKey()``, returning the combined
    /// (nonce + ciphertext + tag) representation, or nil when no key is available or sealing fails.
    func gcmSeal(_ plaintext: Data) -> Data? {
        guard let key = mediaKey() else { return nil }
        return try? AES.GCM.seal(plaintext, using: key).combined
    }

    /// Opens AES-256-GCM combined bytes sealed under ``mediaKey()``. Returns nil when no key is
    /// available, the bytes aren't a well-formed sealed box, or authentication/decryption fails —
    /// callers branch on nil to fail closed (or to try their own legacy-plaintext path).
    func gcmOpen(_ stored: Data) -> Data? {
        guard let key = mediaKey(), let box = try? AES.GCM.SealedBox(combined: stored) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    /// Seals `plaintext` via ``gcmSeal(_:)`` and atomically writes the ciphertext to `url` with
    /// `.completeFileProtection`. Returns whether the bytes reached disk; on a nil key, a seal
    /// failure, or a write error NOTHING is written (fail-closed — plaintext never touches disk).
    @discardableResult
    func sealAndWrite(_ plaintext: Data, to url: URL) -> Bool {
        guard let sealed = gcmSeal(plaintext) else { return false }
        do {
            try sealed.write(to: url, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            return false
        }
    }
}
