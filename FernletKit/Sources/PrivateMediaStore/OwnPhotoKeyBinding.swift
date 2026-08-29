import Foundation
import Security

/// The user's explicit, recorded acceptance that their own photos become **device-bound** — the
/// second half of the binding gate for users who leave the escrow photo backup switched off.
///
/// Device-binding the own-photos key is a real trade, not a free win: once the row is bound, the
/// user's meal / recipe / progress photos no longer ride the encrypted device backup onto a
/// replacement phone. Fernlet will not make that trade on the user's behalf. Either the sanctioned
/// cross-device route is switched on (the own-photo escrow backup, step 5b) **or** the user has
/// been told, in as many words, that these photos will not come back on a new phone — and said yes.
/// This type is that second answer, written down.
///
/// **One-way on purpose.** ``reset()`` exists for tests and for a future step that legitimately
/// invalidates the decision; nothing user-facing withdraws consent, because un-binding a bound row
/// would *widen* custody again and would be a security regression the user could trigger by
/// accident. It would also be mostly theatre: an encrypted device backup taken while the row was
/// still backup-restorable already carries the old key, so the binding only ever protects backups
/// taken after the flip (stated honestly in `Docs/Verifiability.md` §5).
///
/// Device-local by construction (`UserDefaults`, never synced), exactly like
/// ``MediaAtRestFormatMigrationLatch``: it records a decision about THIS device's keychain row.
///
/// Concurrency: a `nonisolated` value type over `UserDefaults` (itself thread-safe).
public struct OwnPhotoDeviceBindingConsent {
    /// The `UserDefaults` key holding the recorded consent.
    public static let defaultsKey = "com.fernlet.private-media.ownPhotoDeviceBindingConsent"

    private let defaults: UserDefaults

    /// Creates a consent record over `defaults`; tests inject an isolated suite so they never read
    /// or write the device's real decision.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the user has explicitly accepted that own photos will not restore to a new phone.
    /// Absent (never asked) reads as false — the fail-closed direction, so silence never binds.
    public var isRecorded: Bool {
        defaults.bool(forKey: Self.defaultsKey)
    }

    /// Records the user's acceptance. Called ONLY from a confirmed, user-initiated ceremony
    /// (Privacy & Data → "Lock photos to this device"), never speculatively and never from a
    /// launch path.
    public func record() {
        defaults.set(true, forKey: Self.defaultsKey)
    }

    /// Clears the recorded consent. For tests, and for any future step that must ask again.
    public func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}

/// What one evaluation of the own-photo key binding gate did — or, far more interestingly, why it
/// refused.
///
/// Every non-``bound`` case leaves the row exactly as it was AND leaves the read-path dual-open
/// fallback in place, so a refusal is always the safe direction: nothing becomes unreadable, and
/// the next launch tries again.
public enum OwnPhotoKeyBindingOutcome: Sendable, Equatable {
    /// The own-photos row is device-bound now — either it already was, or this call re-bound it.
    case bound
    /// The sweep latch is not set: this device has not successfully walked and classified its own
    /// photo corpora (or a pass found something it could not classify). Binding on a corpus nobody
    /// managed to LOOK at is the documented data-loss path — a straggler would become permanently
    /// unreadable bytes with no error anywhere — so the gate refuses.
    ///
    /// The name is kept from when `OwnPhotoMigrationLatch` filled this half, because it is a
    /// public case other layers switch on and renaming it buys nothing; what changed underneath is
    /// which pass proves the property. See ``OwnPhotoKeyBinder`` for that history.
    case refusedMigrationIncomplete
    /// The migration is proven complete, but the user has neither the escrow photo backup switched
    /// on nor recorded ``OwnPhotoDeviceBindingConsent``. Binding would silently trade away their
    /// phone-swap recovery.
    case refusedNoRecoveryRoute
    /// The gate is satisfied but the keychain could not produce the own-photos key at all (locked
    /// device, failing keychain). Nothing was written; retried on a later pass.
    case deferredKeyUnavailable
    /// The gate is satisfied and the key exists, but the in-place accessibility update failed,
    /// carrying the failing `OSStatus`. The row keeps its previous class.
    case rebindFailed(OSStatus)

    /// Whether the row is device-bound as of this evaluation.
    public var isBound: Bool { self == .bound }
}

/// The **binding gate** for the own-photos at-rest key (security-hardening Phase 5, step 5c):
/// decides whether `com.fernlet.private-media.ownContentKey` may become device-bound, and performs
/// the flip in place when it may.
///
/// ## The gate, and why it is runtime state rather than a compile-time constant
///
/// The plan described 5c as "a one-line policy flip" in
/// ``KeychainPrivateMediaKeyProvider/defaultDeviceBinding(for:)``. It cannot be, and the reason is
/// the whole design: binding is only safe when **both** conditions hold, and both are facts about
/// this device at this moment, not about the build:
///
/// 1. ``MediaAtRestFormatMigrationLatch`` is set — this device has walked every own-photo location
///    and classified every file it found. Binding on a corpus nobody managed to look at turns any
///    straggler into permanently unreadable bytes.
///
///    **This half changed hands at the close of the crypto standardization round, and the history
///    matters more than the diff.** It used to be `OwnPhotoMigrationLatch`, set by the eager
///    `OwnPhotoKeyMigrator` re-seal pass of the media-key split, and it attested the strong thing:
///    every own file is sealed under the own-photos key. Phase 3 deleted the unmarked at-rest read,
///    which (a) left that pass with no input any shipping writer could produce, and (b) silently
///    narrowed what its latch attested, since a genuine pre-split file became `unopenable` residue —
///    a bucket deliberately outside `isClean`, so a pass over a corpus of them latched anyway. The
///    owner retired the pass and its latch rather than keep a healer that could no longer heal.
///
///    ``MediaAtRestFormatMigrationLatch`` replaces it because it sweeps the same locations
///    (`OwnPhotoCorpusLayout.sealedLocations`) and refuses on the same fail-closed grounds:
///    `indeterminate` (an unlistable directory, or bytes that could not be READ at all — own files
///    are `.completeFileProtection` while both key rows are `AfterFirstUnlock` and cached, so a
///    device that locks mid-pass fails every read while the keys stay perfectly available) and
///    `abortedNoOwnKey`. That "I could not look" refusal is the half of the old latch that still had
///    teeth, and it is preserved exactly.
///
///    **What it does NOT preserve, stated rather than glossed.** The new latch also sweeps the
///    FRIEND WALL, so `abortedNoWallKey` — Phase 2.3's benign-pending state on a wall root whose
///    keychain row was never minted — can hold this gate open where the old one would not have. That
///    is strictly harder to satisfy and never looser, which is the correct direction for a gate on an
///    irreversible flip; and it is a format proof rather than a key-custody proof, so it no longer
///    asserts anything about WHICH key a file opens under. Nothing else does either: the reader that
///    could have told the difference is what Phase 3 removed.
/// 2. The user has a sanctioned cross-device route: the opt-in own-photo escrow backup has
///    actually **committed** a copy (not merely been switched on — see ``escrowRouteCommitted``),
///    or ``OwnPhotoDeviceBindingConsent`` is recorded. Binding before that silently deletes their
///    photos' only path onto a replacement phone.
///
/// A build-time `true` would bind on devices failing either condition. So the mint policy stays
/// backup-restorable and this type re-binds the row in place once the conditions are met; the
/// `deviceBound` mint mode is still what mints a *fresh* row bound (see ``bindIfEligible()``).
///
/// ## Why the flip is an in-place update, not a re-store
///
/// `KeychainItem.store` is delete-then-add. Using it here would open a window in which the own
/// photos key does not exist at all — and a crash, a jetsam kill or a device lock inside that
/// window destroys **every** own photo the user has, irrecoverably, with no error. The re-bind
/// therefore goes through `SecItemUpdate`, which changes the row's accessibility class atomically
/// and never removes the key material. See ``KeychainPrivateMediaKeyProvider/bindOwnPhotoRowToThisDevice()``.
///
/// ## What callers do with it
///
/// - The app runs ``bindIfEligible()`` right after the eager migration pass reports completion, and
///   again whenever the escrow backup is switched on.
/// - The consent ceremony calls ``recordConsentAndBind()``.
/// - The own read paths ask ``isOwnPhotoKeyDeviceBound()`` whether to keep the dual-open legacy
///   fallback: bound ⇒ drop it (that is what makes the binding meaningful), not bound ⇒ keep it.
///
/// Concurrency: a `nonisolated` value type over `UserDefaults` and the keychain; safe to evaluate
/// from a background launch task, which is exactly where the migration hands off to it.
public struct OwnPhotoKeyBinder {
    /// Whether the own-photo escrow backup has actually **committed** a copy of this device's
    /// photos — supplied by the caller rather than read here, because `StoragePreferences` and the
    /// CloudKit transport are the app's concern and this module stays preference-agnostic.
    ///
    /// - Important: this is deliberately NOT "the preference is switched on". A preference is a
    ///   statement of intent; binding is irreversible. A user who flips the switch while offline,
    ///   signed out of iCloud, or over quota has a preference that reads ON and zero bytes in the
    ///   cloud — binding on that would destroy the device-backup route without having built the
    ///   replacement. Callers must pass evidence that a manifest write reached iCloud (or that
    ///   there was nothing to commit because the user has no own photos at all); see
    ///   `OwnPhotoEscrowCommitLedger` on the app side.
    private let escrowRouteCommitted: Bool
    /// The sweep proof for gate half 1 — see the type doc for why this is the media at-rest format
    /// latch and not the retired own-photo key latch.
    private let sweepLatch: MediaAtRestFormatMigrationLatch
    private let consent: OwnPhotoDeviceBindingConsent

    /// Creates a gate evaluation.
    ///
    /// - Parameters:
    ///   - escrowRouteCommitted: Whether the own-photo escrow backup has committed a copy of this
    ///     device's photos — see ``escrowRouteCommitted``. Never merely the preference.
    ///   - defaults: Backing store for the sweep latch and the consent record; tests inject an
    ///     isolated suite.
    public init(escrowRouteCommitted: Bool, defaults: UserDefaults = .standard) {
        self.escrowRouteCommitted = escrowRouteCommitted
        self.sweepLatch = MediaAtRestFormatMigrationLatch(defaults: defaults)
        self.consent = OwnPhotoDeviceBindingConsent(defaults: defaults)
    }

    /// Whether the user has a sanctioned way to get these photos onto a replacement phone: a
    /// committed escrow backup, or a recorded acceptance that there will not be one.
    public var hasCrossDeviceRoute: Bool {
        escrowRouteCommitted || consent.isRecorded
    }

    /// Whether both halves of the gate hold right now. Used by the UI to decide whether the
    /// consent ceremony is offerable yet, without performing any keychain work.
    public var isEligible: Bool {
        sweepLatch.isComplete && hasCrossDeviceRoute
    }

    /// Whether the media at-rest sweep has walked and classified every own-photo location — the
    /// half of the gate the user cannot influence, surfaced so the UI can say "still preparing"
    /// instead of offering a button that would refuse.
    public var isMigrationComplete: Bool {
        sweepLatch.isComplete
    }

    /// Binds the own-photos row to this device if — and only if — both halves of the gate hold.
    ///
    /// Idempotent and cheap: an already-bound row costs one keychain attribute read. A fresh row
    /// (no own photos yet) is minted directly under the device-bound class rather than minted
    /// loose and immediately updated.
    ///
    /// - Returns: the outcome; every non-``OwnPhotoKeyBindingOutcome/bound`` case leaves both the
    ///   row and the dual-open fallback exactly as they were. R7: deliberately not
    ///   `@discardableResult` — the value is Result-shaped (it carries `.rebindFailed(OSStatus)`),
    ///   so ignoring it would drop a failure.
    public func bindIfEligible() -> OwnPhotoKeyBindingOutcome {
        guard sweepLatch.isComplete else { return .refusedMigrationIncomplete }
        guard hasCrossDeviceRoute else { return .refusedNoRecoveryRoute }
        // Mints device-bound when the row is absent; reads (and leaves alone) an existing row.
        let provider = KeychainPrivateMediaKeyProvider(role: .ownPhotos, deviceBound: true)
        guard provider.mediaKey() != nil else { return .deferredKeyUnavailable }
        if Self.isOwnPhotoKeyDeviceBound() { return .bound }
        let status = KeychainPrivateMediaKeyProvider.bindOwnPhotoRowToThisDevice()
        guard status == errSecSuccess else { return .rebindFailed(status) }
        // Trust the read-back, not the status: the property everything downstream rests on is what
        // the row actually says, and a "success" that did not change the class must not drop the
        // fallback.
        return Self.isOwnPhotoKeyDeviceBound() ? .bound : .rebindFailed(errSecInternalError)
    }

    /// Records the user's explicit consent and evaluates the gate in the same breath — the
    /// "Lock photos to this device" ceremony.
    ///
    /// Consent is recorded even when the bind then refuses (the migration is still running, the
    /// keychain is briefly unavailable): the user's decision is a durable fact, and re-asking for
    /// it would be the wrong remedy for a transient failure. The next pass binds.
    ///
    /// - Returns: the ceremony's outcome, which the UI must reflect. R7: not `@discardableResult`.
    public func recordConsentAndBind() -> OwnPhotoKeyBindingOutcome {
        consent.record()
        return bindIfEligible()
    }

    /// Whether the own-photos keychain row is device-bound **right now**, read from the row's
    /// actual `kSecAttrAccessible` attribute.
    ///
    /// Deliberately not a persisted flag. A cached "we bound it" bit rides the device backup onto a
    /// new phone, where the device-bound row itself did not restore — so the new device would
    /// believe it was bound while holding a backup-restorable row, and would have dropped the
    /// dual-open fallback on the strength of that belief. Asking the keychain costs one
    /// `SecItemCopyMatching` and can never be wrong.
    ///
    /// An absent or unreadable row answers **false**, which keeps the fallback — the safe
    /// direction.
    public static func isOwnPhotoKeyDeviceBound() -> Bool {
        KeychainPrivateMediaKeyProvider.ownPhotoRowAccessibility()
            == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    }
}

extension KeychainPrivateMediaKeyProvider {
    /// The accessibility class the own-photos row is currently stored under, or nil when the row is
    /// absent or the keychain read fails. The raw attribute string, so callers compare against the
    /// `kSecAttrAccessible*` constants rather than a stale copy of the policy.
    public static func ownPhotoRowAccessibility() -> String? {
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ownAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrAccessible as String] as? String
    }

    /// Re-binds the own-photos row to this device **in place**, returning the raw `OSStatus`.
    ///
    /// Uses `SecItemUpdate` rather than the module's usual delete-then-add store, and that choice is
    /// load-bearing: a delete-then-add leaves an interval with no own-photos key on the device, and
    /// a crash or lock inside that interval destroys every meal, recipe and progress photo the user
    /// has. `SecItemUpdate` changes only the accessibility attribute, atomically, and never touches
    /// the key material — so the flip cannot strand a single photo.
    ///
    /// Returns `errSecItemNotFound` when there is no row to bind (nothing is minted here; the
    /// caller mints through ``mediaKey()`` first) and `errSecInteractionNotAllowed` when the device
    /// has not been unlocked since boot, both of which the caller treats as "try again later".
    ///
    /// - Important: policy does NOT live here. ``OwnPhotoKeyBinder`` decides *whether* to call this;
    ///   calling it directly bypasses the migration latch and the cross-device-route requirement,
    ///   which is the documented data-loss path.
    public static func bindOwnPhotoRowToThisDevice() -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ownAccount,
            kSecUseDataProtectionKeychain as String: true
        ]
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
}
