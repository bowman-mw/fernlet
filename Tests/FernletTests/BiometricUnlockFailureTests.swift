// BiometricUnlockFailureTests.swift
// FernletTests
//
// What the unlock screen says when a biometric attempt does not unlock (FernletBiometricUnlockFailure,
// FernletLockUI). The screen's inline error, its error haptic and its failure announcement all key off
// this one answer, so `nil` here means the screen shows, buzzes and says nothing.
//
// THE BUG THIS PINS SHUT. The gate auto-presents Face ID once per lock session, and someone who prefers
// typing their passcode dismisses that sheet on every visit to the Private tab. The view used to filter
// only the SPEECH for a dismissal. It still set the red error text, and `.sensoryFeedback` buzzed
// `.error` on the arriving message, so every visit greeted that person with a failure.
//
// The answer is pure, so the unit tests drive it directly. The last test is a source pin for the one
// thing they cannot reach: that the view takes its message, its announcement and (through the message)
// its haptic from this answer and from nowhere else.

import Foundation
import LocalAuthentication
import Security
import Testing
import FernletFoundation
@testable import FernletLockUI

/// Pins ``FernletBiometricUnlockFailure``: a dismissed biometric sheet sets no message, unavailable
/// biometrics stay quiet, and every real biometric failure still sets one.
@MainActor
@Suite struct FernletBiometricUnlockFailureTests {

    /// Every way the person, or the system on their behalf, closes the sheet, in the shapes
    /// `FernletLockService.unlockWithBiometrics(for:)` actually throws them.
    private static let dismissals: [(label: String, error: any Error)] = [
        // `KeychainItem.loadBiometricBypassSync` rethrows the LocalAuthentication reply unwrapped,
        // and the reply is an NSError in LAErrorDomain, not an `LAError` value. This row is the cast
        // the production path depends on.
        ("reply NSError, user cancel",
         NSError(domain: LAError.errorDomain, code: LAError.Code.userCancel.rawValue)),
        ("user cancel", LAError(.userCancel)),
        ("fallback button", LAError(.userFallback)),
        ("app cancel", LAError(.appCancel)),
        ("system cancel (app left the foreground)", LAError(.systemCancel)),
        // A cancel on a prompt the keychain read put up itself, wrapped by that read.
        ("keychain user cancel",
         FernletLockError.keychainFailure(operation: "read biometric bypass", status: errSecUserCanceled))
    ]

    /// Failures the person must hear about, with the shape each one arrives in.
    private static let realFailures: [(label: String, error: any Error)] = [
        ("no match within the system's retry limit", LAError(.authenticationFailed)),
        ("biometry locked out", LAError(.biometryLockout)),
        ("reply NSError, lockout",
         NSError(domain: LAError.errorDomain, code: LAError.Code.biometryLockout.rawValue)),
        ("keychain refused after a successful match",
         FernletLockError.keychainFailure(operation: "read biometric bypass", status: errSecInteractionNotAllowed)),
        ("keychain authentication failed",
         FernletLockError.keychainFailure(operation: "read biometric bypass", status: errSecAuthFailed))
    ]

    /// A dismissal sets no message, so the screen gets no red text, no error buzz and no
    /// announcement.
    @Test func aDismissedSheetSetsNoMessage() {
        for (label, error) in Self.dismissals {
            #expect(FernletBiometricUnlockFailure.isDismissal(error), "\(label) is a dismissal")
            #expect(FernletBiometricUnlockFailure.message(for: error, biometry: .faceID) == nil,
                    "\(label) must leave the unlock screen silent")
        }
    }

    /// Unavailable biometrics fall back to the keypad quietly, as before. That includes the duress
    /// session's suppression, which throws the same error as every other refusal.
    @Test func unavailableBiometricsSetNoMessage() {
        #expect(FernletBiometricUnlockFailure.message(
            for: FernletLockError.biometricNotAvailable, biometry: .faceID) == nil)
        #expect(!FernletBiometricUnlockFailure.isDismissal(FernletLockError.biometricNotAvailable))
    }

    /// A face that did not match still sets the "didn't recognize you" line, named from the
    /// device's own biometry.
    @Test func anUnrecognizedFaceStillSetsTheUnrecognizedLine() {
        let faceID = FernletBiometricUnlockFailure.message(
            for: FernletLockError.biometricFailed, biometry: .faceID)
        #expect(faceID == FernletLockCopy.Unlock.errorBiometricUnrecognized("Face ID"))
        let touchID = FernletBiometricUnlockFailure.message(
            for: FernletLockError.biometricFailed, biometry: .touchID)
        #expect(touchID == FernletLockCopy.Unlock.errorBiometricUnrecognized("Touch ID"))
    }

    /// An exhausted ladder still sets the too-many-attempts line.
    @Test func resetRequiredStillSetsTheTooManyAttemptsLine() {
        #expect(FernletBiometricUnlockFailure.message(
            for: FernletLockError.resetRequired, biometry: .faceID) == FernletLockCopy.Unlock.errorTooManyAttempts)
    }

    /// A lockout, a match that never came, and a keychain refusal are not dismissals, and each
    /// still sets its own description as the message.
    @Test func everyOtherFailureStillSetsItsDescription() {
        for (label, error) in Self.realFailures {
            #expect(!FernletBiometricUnlockFailure.isDismissal(error), "\(label) is not a dismissal")
            let message = FernletBiometricUnlockFailure.message(for: error, biometry: .faceID)
            #expect(message == error.localizedDescription, "\(label) must still show, speak and buzz")
            #expect(message?.isEmpty == false, "\(label) produced an empty message")
        }
    }

    /// The view's half, which no unit test can drive: the biometric attempt's one catch arm sets
    /// `errorMessage` from the answer and announces only a non-nil one, and the error haptic keys
    /// off `errorMessage`. Together they are what makes `nil` above mean silence on all three
    /// channels.
    @Test func theUnlockScreenTakesAllThreeChannelsFromTheAnswer() throws {
        let path = "FernletKit/Sources/FernletLockUI/FernletLockView.swift"
        let source = try String(contentsOf: RepoRoot.url.appendingPathComponent(path), encoding: .utf8)
        let normalized = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // From the function's head to the next `private func`: its whole body, never another's.
        let afterHead = normalized.components(separatedBy: "private func triggerBiometric() {")
        try #require(afterHead.count == 2, "\(path) no longer declares triggerBiometric() exactly once")
        let attempt = try #require(afterHead[1].components(separatedBy: "private func ").first)

        #expect(attempt.contains("""
            let failure = FernletBiometricUnlockFailure.message( for: error, biometry: lockService.biometricType) \
            errorMessage = failure \
            if let failure { announceUnlockFailure(failure) }
            """), "triggerBiometric() must take its message and its announcement from FernletBiometricUnlockFailure")
        #expect(attempt.components(separatedBy: "catch").count == 2,
                "one catch arm, so no arm can set a message of its own around the answer")
        #expect(attempt.components(separatedBy: "errorMessage =").count == 3,
                "triggerBiometric() writes errorMessage twice: nil before the attempt, the answer after it")
        #expect(normalized.components(separatedBy: "unlockWithBiometrics(for: scope)").count == 2,
                "the view attempts a biometric unlock in one place")
        #expect(normalized.contains(
            ".sensoryFeedback(trigger: errorMessage) { _, message in message == nil ? nil : .error }"),
            "the unlock screen's error haptic must key off errorMessage, so a nil answer cannot buzz")
    }
}
