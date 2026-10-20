// BiometricUnlockFailureTests.swift
// FernletTests
//
// What the unlock screen says when a biometric attempt does not unlock (FernletBiometricUnlockFailure,
// FernletLockUI). The screen's inline error, its error haptic and its failure announcement all key off
// this one answer, so `nil` here means the screen shows, buzzes and says nothing.
//
// THE BUG THIS PINS SHUT. The gate auto-presents Face ID once per lock session, and someone who prefers
// typing their passcode dismisses that sheet on every visit to the Private tab. The view used to filter
// only the SPEECH for a dismissal. It still set the red error text, and the error haptic (then
// `.sensoryFeedback`, now `.fernletFeedback(.failed, …)`) buzzed on the arriving message, so every visit
// greeted that person with a failure.
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

    /// A face or finger that never matched within the system's retry limit, in both shapes.
    private static let unmatched: [(label: String, error: any Error)] = [
        ("no match", LAError(.authenticationFailed)),
        ("reply NSError, no match",
         NSError(domain: LAError.errorDomain, code: LAError.Code.authenticationFailed.rawValue))
    ]

    /// The sensor locking itself during the prompt, in both shapes.
    private static let lockouts: [(label: String, error: any Error)] = [
        ("lockout", LAError(.biometryLockout)),
        ("reply NSError, lockout",
         NSError(domain: LAError.errorDomain, code: LAError.Code.biometryLockout.rawValue))
    ]

    /// Failures the person must hear about that have no Fernlet line of their own, with the shape
    /// each one arrives in.
    private static let realFailures: [(label: String, error: any Error)] = [
        ("LocalAuthentication context invalidated", LAError(.invalidContext)),
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

    /// The two LocalAuthentication failures a person can cause get Fernlet's own lines, never
    /// LocalAuthentication's untranslated developer text: a face that never matched reads as
    /// "didn't recognize you", and a sensor that locked itself reads as "paused".
    @Test func aFailedMatchAndALockoutGetFernletsOwnLines() {
        for (label, error) in Self.unmatched {
            #expect(!FernletBiometricUnlockFailure.isDismissal(error), "\(label) is not a dismissal")
            #expect(FernletBiometricUnlockFailure.message(for: error, biometry: .faceID)
                    == FernletLockCopy.Unlock.errorBiometricUnrecognized("Face ID"), "\(label)")
        }
        for (label, error) in Self.lockouts {
            #expect(!FernletBiometricUnlockFailure.isDismissal(error), "\(label) is not a dismissal")
            #expect(FernletBiometricUnlockFailure.message(for: error, biometry: .faceID)
                    == FernletLockCopy.Unlock.errorBiometricLockout("Face ID"), "\(label)")
            #expect(FernletBiometricUnlockFailure.message(for: error, biometry: .touchID)
                    == FernletLockCopy.Unlock.errorBiometricLockout("Touch ID"), "\(label)")
            #expect(FernletBiometricUnlockFailure.message(for: error, biometry: .faceID)
                    != error.localizedDescription, "\(label) must not show LocalAuthentication's own text")
        }
    }

    /// An exhausted ladder still sets the too-many-attempts line.
    @Test func resetRequiredStillSetsTheTooManyAttemptsLine() {
        #expect(FernletBiometricUnlockFailure.message(
            for: FernletLockError.resetRequired, biometry: .faceID) == FernletLockCopy.Unlock.errorTooManyAttempts)
    }

    /// Any other LocalAuthentication error and every keychain refusal is not a dismissal, and each
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
            let failure = FernletBiometricUnlockFailure.message(for: error, biometry: biometry) \
            errorMessage = failure \
            if let failure { announceUnlockFailure(failure) }
            """), "triggerBiometric() must take its message and its announcement from FernletBiometricUnlockFailure")
        let biometryRead = try #require(attempt.range(of: "let biometry = lockService.biometricType"),
                                        "triggerBiometric() must read the biometry before the prompt")
        let promptCall = try #require(attempt.range(of: "unlockWithBiometrics(for: scope)"))
        #expect(biometryRead.upperBound <= promptCall.lowerBound,
                "the biometry is read before the prompt; after a lockout it reads as .none")
        #expect(attempt.components(separatedBy: "catch").count == 2,
                "one catch arm, so no arm can set a message of its own around the answer")
        #expect(attempt.components(separatedBy: "errorMessage =").count == 3,
                "triggerBiometric() writes errorMessage twice: nil before the attempt, the answer after it")
        #expect(normalized.components(separatedBy: "unlockWithBiometrics(for: scope)").count == 2,
                "the view attempts a biometric unlock in one place")
        // The haptic moved onto FernletUI's FernletFeedback in the sounds-and-haptics pass (A6): the same
        // trigger and the same "only an ARRIVING message" rule, through the app-wide Haptics level.
        #expect(normalized.contains(
            ".fernletFeedback(.failed, trigger: errorMessage) { _, message in message != nil }"),
            "the unlock screen's error haptic must key off errorMessage, so a nil answer cannot buzz")
    }
}
