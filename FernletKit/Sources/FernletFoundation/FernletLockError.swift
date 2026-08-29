import Foundation
import Security

/// Errors thrown by the app-lock stack and the sealed narrative repositories.
///
/// `FernletLockService` (FernletLock) throws these from its configure/unlock/reset flows, and the
/// sealed repositories (journal, worry, menstrual narrative, and intimacy log in the `Private*`
/// stores) rethrow them when a decrypt is attempted while the lock is closed or unconfigured. The
/// type lives at Layer 0 so the sealed stores, the lock service, and the lock UI can all name the
/// same cases without dependency edges among themselves. Conforms to `LocalizedError`:
/// ``errorDescription`` renders each case as user-facing copy, including a relative countdown for
/// ``cooldownActive(deadline:)`` and a decoded `OSStatus` message for
/// ``keychainFailure(operation:status:)``.
///
/// `Equatable` so a test can require an exact case rather than the type. That distinction is
/// load-bearing on this type in particular: `#expect(throws: FernletLockError.self)` passes for
/// ``invalidPasscode`` and ``contentKeyWrapFormatRetired`` alike, and telling those two apart is
/// the whole point of the second one existing. Every associated value is already `Equatable`
/// (`String`, `Date`, `OSStatus`), so the conformance is synthesized.
public enum FernletLockError: Error, LocalizedError, Equatable {
    /// No app lock has been set up yet; the operation requires a configured lock.
    case notConfigured
    /// A credential was rejected during setup/validation; the associated message is shown verbatim.
    case invalidCredential(String)
    /// The entered passcode did not match.
    case invalidPasscode
    /// Failed attempts triggered a cooldown; no attempts are accepted before `deadline`.
    case cooldownActive(deadline: Date)
    /// The failed-attempt budget is exhausted; only a full app-lock reset can proceed.
    case resetRequired
    /// Biometric authentication ran but did not succeed.
    case biometricFailed
    /// Biometrics are not available on this device (or not enrolled/permitted).
    case biometricNotAvailable
    /// A keychain call failed; carries the operation name and the raw `OSStatus` for diagnosis.
    case keychainFailure(operation: String, status: OSStatus)
    /// An unexpected internal failure with a diagnostic message.
    case internalError(String)
    /// The lock is currently closed; the operation requires the unlocked state.
    case locked
    /// The passcode was CORRECT but the content key can no longer be recovered: the lock is
    /// hard-bound to this device's Secure Enclave and that enclave key is gone (an "Erase All
    /// Content and Settings", a Secure-Enclave reset, or a restore onto different hardware).
    /// The sealed corpus is cryptographically unopenable — only a destructive app-lock reset
    /// moves the app forward. Distinct from ``invalidPasscode`` on purpose: nothing about the
    /// entry was wrong, so the user must not be told to try again (the nothing-silent principle).
    case contentKeyUnrecoverable
    /// The passcode was CORRECT and the lock is hard-bound to this device's Secure Enclave, but
    /// the enclave/keychain could not be READ at this instant (`errSecInteractionNotAllowed`
    /// while the device is locked, `errSecNotAvailable` before first unlock, protected data
    /// unavailable). The key's fate is unknown, so this is deliberately NOT
    /// ``contentKeyUnrecoverable``: nothing here justifies telling the user to run a destructive
    /// reset. Retry once the device is unlocked.
    case contentKeyTemporarilyUnavailable(status: OSStatus)
    /// The passcode was CORRECT, the scrypt-wrapped content key is PRESENT, and it is in the
    /// pre-`FLW2` unprefixed format whose reader Phase 3 of the crypto standardization round
    /// deleted. Nothing is wrong with the passcode, the wrapping key, or the ciphertext — this
    /// build simply stopped reading that generation, so the wrap is terminal here.
    ///
    /// Deliberately distinct from all three neighbours. Not ``invalidPasscode``: the entry was
    /// right, and telling the user to try again would be a lie they could repeat forever. Not
    /// ``contentKeyUnrecoverable``: that one means a Secure-Enclave key was destroyed, a
    /// different diagnosis with a different history. Not a bare ChaChaPoly authentication throw,
    /// which is what this branch used to degrade into and reads as "your data is corrupt".
    ///
    /// Non-destructive by construction: it is thrown from ``FernletLockCrypto`` before any caller
    /// has written or deleted a row, so the wrap, the verifier, the salt, the enclave wrap and the
    /// biometric bypass all survive the refusal untouched.
    case contentKeyWrapFormatRetired

    /// User-facing description for each case, suitable for direct display in the lock UI.
    ///
    /// Package source, so every lookup passes `bundle: .module`: without it the resolution goes to
    /// `Bundle.main`, finds nothing, and silently renders the English `defaultValue` forever.
    ///
    /// ``invalidCredential(_:)`` is the one case with no key. Its associated value is already the
    /// finished sentence its thrower chose, so a key here would either discard that sentence or wrap
    /// it in a second one — the pass-through IS the contract.
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "lock.error.notConfigured",
                          defaultValue: "App lock is not configured.",
                          bundle: .module,
                          comment: "Shown when an operation needs a configured app lock and none has been set up yet.")
        case .invalidCredential(let message):
            return message
        case .invalidPasscode:
            return String(localized: "lock.error.invalidPasscode",
                          defaultValue: "Incorrect passcode.",
                          bundle: .module,
                          comment: "Shown when an entered app-lock passcode did not match. Distinct from the unrecoverable-key case, where retrying is pointless.")
        case .cooldownActive(let deadline):
            return Self.cooldownDescription(secondsRemaining: deadline.timeIntervalSinceNow)
        case .resetRequired:
            return String(localized: "lock.error.resetRequired",
                          defaultValue: "Too many failed attempts. Please reset app lock.",
                          bundle: .module,
                          comment: "Shown when the failed-attempt budget is exhausted and only a full app-lock reset can proceed. There is no waiting it out.")
        case .biometricFailed:
            return String(localized: "lock.error.biometricFailed",
                          defaultValue: "Biometric authentication failed.",
                          bundle: .module,
                          comment: "Shown when Face ID or Touch ID ran but did not succeed.")
        case .biometricNotAvailable:
            return String(localized: "lock.error.biometricNotAvailable",
                          defaultValue: "Biometric authentication is not available.",
                          bundle: .module,
                          comment: "Shown when Face ID or Touch ID is absent, not enrolled, or not permitted on this device.")
        case .keychainFailure(let operation, let status):
            return Self.keychainFailureDescription(operation: operation, status: status)
        case .internalError(let message):
            return String(localized: "lock.error.internal",
                          defaultValue: "Internal error: \(message)",
                          bundle: .module,
                          comment: "Diagnostic wrapper for an unexpected app-lock failure. The argument is an untranslated internal message.")
        case .locked:
            return String(localized: "lock.error.locked",
                          defaultValue: "App lock is locked.",
                          bundle: .module,
                          comment: "Shown when an operation requires the unlocked state and the app lock is currently closed.")
        case .contentKeyUnrecoverable:
            return String(localized: "lock.error.contentKeyUnrecoverable",
                          defaultValue: "Sealed data can no longer be opened on this device. Reset app lock to continue.",
                          bundle: .module,
                          comment: "Shown when the passcode was CORRECT but this device's Secure Enclave key is gone, so the sealed notes are cryptographically unopenable. Must NOT suggest retrying — nothing about the entry was wrong — and must name the destructive reset as the only way forward.")
        case .contentKeyTemporarilyUnavailable:
            // Never mentions reset: the key may be perfectly intact and only unreadable right now.
            return String(localized: "lock.error.contentKeyTemporarilyUnavailable",
                          defaultValue: "Fernlet couldn't reach this device's secure hardware. Make sure iPhone is unlocked and try again.",
                          bundle: .module,
                          comment: "Shown when the Secure Enclave could not be READ at this instant, typically because the device is locked. Must NEVER mention resetting: unlike the unrecoverable case the key is probably intact, and a reset here would destroy data for nothing.")
        case .contentKeyWrapFormatRetired:
            return String(localized: "lock.error.contentKeyWrapFormatRetired",
                          defaultValue: "This phone's saved key is in an older format Fernlet no longer opens. Reset app lock to continue.",
                          bundle: .module,
                          comment: "Shown when the passcode was CORRECT but the stored content-key wrap is in a retired at-rest format this build no longer reads. Must NOT suggest retrying the passcode — nothing about the entry was wrong — and must name the destructive reset as the only way forward.")
        }
    }

    /// The three cooldown wordings, split by how much of the wait is left.
    ///
    /// One key per unit rather than one key with a unit argument: an hours/minutes/seconds suffix is
    /// not a substitution in every language, and a single `%lld%@` key would hand translators a
    /// sentence they cannot inflect. Lifted out of the `switch` so the branching is testable and the
    /// three keys sit together where a translator can see they are variants of one sentence.
    nonisolated static func cooldownDescription(secondsRemaining: TimeInterval) -> String {
        if secondsRemaining > 3600 {
            let hours = Int(secondsRemaining / 3600)
            return String(localized: "lock.error.cooldownHours",
                          defaultValue: "Too many attempts. Try again in \(hours)h.",
                          bundle: .module,
                          comment: "Shown during the failed-attempt cooldown when over an hour is left. The argument is a whole number of hours; 'h' is the abbreviated unit.")
        }
        if secondsRemaining > 60 {
            let minutes = Int(secondsRemaining / 60)
            return String(localized: "lock.error.cooldownMinutes",
                          defaultValue: "Too many attempts. Try again in \(minutes)m.",
                          bundle: .module,
                          comment: "Shown during the failed-attempt cooldown when between one minute and one hour is left. The argument is a whole number of minutes; 'm' is the abbreviated unit.")
        }
        let seconds = Int(secondsRemaining)
        return String(localized: "lock.error.cooldownSeconds",
                      defaultValue: "Too many attempts. Try again in \(seconds)s.",
                      bundle: .module,
                      comment: "Shown during the failed-attempt cooldown when under a minute is left. The argument is a whole number of seconds; 's' is the abbreviated unit.")
    }

    /// The three keychain-failure wordings, split by how much the `OSStatus` can be turned into.
    ///
    /// The `errSecNotAvailable` branch is the only one a person can act on, so it is a plain sentence
    /// with no diagnostic in it; the other two are diagnostics that happen to be shown.
    nonisolated static func keychainFailureDescription(operation: String, status: OSStatus) -> String {
        if status == errSecNotAvailable {
            return String(localized: "lock.error.keychainUnavailable",
                          defaultValue: "Keychain is not available. Set a device passcode and try again.",
                          bundle: .module,
                          comment: "Shown when the keychain is unreachable because the device has no passcode set. The recovery is the actionable half.")
        }
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return String(localized: "lock.error.keychainFailureWithMessage",
                          defaultValue: "Keychain \(operation) failed: \(message) (\(status)).",
                          bundle: .module,
                          comment: "Diagnostic for a failed keychain call. First argument is an untranslated internal operation name ('add', 'read'), second is Apple's own already-localized message, third the raw OSStatus.")
        }
        return String(localized: "lock.error.keychainFailureWithStatus",
                      defaultValue: "Keychain \(operation) failed with status \(status).",
                      bundle: .module,
                      comment: "Diagnostic for a failed keychain call whose OSStatus has no system message. First argument is an untranslated internal operation name ('add', 'read'), second the raw OSStatus.")
    }
}
