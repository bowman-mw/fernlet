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
public enum FernletLockError: Error, LocalizedError {
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

    /// User-facing description for each case, suitable for direct display in the lock UI.
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "App lock is not configured."
        case .invalidCredential(let message):
            return message
        case .invalidPasscode:
            return "Incorrect passcode."
        case .cooldownActive(let deadline):
            let relative = deadline.timeIntervalSinceNow
            if relative > 3600 {
                return "Too many attempts. Try again in \(Int(relative / 3600))h."
            } else if relative > 60 {
                return "Too many attempts. Try again in \(Int(relative / 60))m."
            } else {
                return "Too many attempts. Try again in \(Int(relative))s."
            }
        case .resetRequired:
            return "Too many failed attempts. Please reset app lock."
        case .biometricFailed:
            return "Biometric authentication failed."
        case .biometricNotAvailable:
            return "Biometric authentication is not available."
        case .keychainFailure(let operation, let status):
            if status == errSecNotAvailable {
                return "Keychain is not available. Set a device passcode and try again."
            }
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain \(operation) failed: \(message) (\(status))."
            }
            return "Keychain \(operation) failed with status \(status)."
        case .internalError(let message):
            return "Internal error: \(message)"
        case .locked:
            return "App lock is locked."
        case .contentKeyUnrecoverable:
            return "Sealed data can no longer be opened on this device. Reset app lock to continue."
        }
    }
}
