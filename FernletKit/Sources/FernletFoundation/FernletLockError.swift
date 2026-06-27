import Foundation
import Security

public enum FernletLockError: Error, LocalizedError {
    case notConfigured
    case invalidCredential(String)
    case invalidPasscode
    case cooldownActive(deadline: Date)
    case resetRequired
    case biometricFailed
    case biometricNotAvailable
    case keychainFailure(operation: String, status: OSStatus)
    case internalError(String)
    case locked

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
        }
    }
}
