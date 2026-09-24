// ProgressPhotoLockNudgeTests.swift
// FernletTests
//
// The progress-photo lock-setup nudge (tracker §3.2): a user who skipped the onboarding lock step
// hears, on first use of the photo strip, that progress photos can sit behind the app lock — "Set up
// lock" or "Not now" — and the `lockSetupDeferred` bit onboarding has always written finally has a
// reader.
//
// What these pin:
//   * It appears for a deferred, no-lock user on first use, and only once: "Not now" retires it, and
//     the answer survives a relaunch.
//   * It honors the deferral key: a user who chose a lock at onboarding, or never saw the lock step,
//     is not nudged.
//   * It never appears while a lock is configured — checked against the real `FernletLockService`.
//   * "Set up lock" opens the setup, and the setup it opens grants `.progressPhotos` (and only that),
//     so the user lands back on their photos; a lock set up from it clears the deferral.
//   * Capture still works: the nudge never takes the place of the capture control, and capturing
//     needs no answer.
//
// Filter at SUITE level (`-only-testing:FernletTests/ProgressPhotoLockNudgeTests`) — a method-level
// filter matches no Swift Testing case and still prints a green banner.

import Foundation
import Testing
import UIKit
import FernletLock
import PrivateMediaStore
@testable import Fernlet

/// A lock service on keychain services nobody else uses, starting from "not configured".
@MainActor
private func freshLockService() -> FernletLockService {
    let service = FernletLockService(
        keychainService: "com.fernlet.lock.nudgetest.\(UUID().uuidString)",
        // reset() sweeps the sealed-content device keys too; keep that off the real service.
        sealedContentKeyServices: ["com.fernlet.journal.test.\(UUID().uuidString)"],
        mediaKeychainServices: ["com.fernlet.private-media.test.\(UUID().uuidString)"],
        // reset() also purges the pending-narrative buffer; keep that off the process-wide scope.
        narrativeBufferScope: uniqueNarrativeBufferScope()
    )
    try? service.reset()
    return service
}

/// Serialized like the other lock suites: two cases configure a real `FernletLockService`.
@Suite(.serialized)
@MainActor
struct ProgressPhotoLockNudgeTests {

    // MARK: - Fixtures

    /// A throwaway suite, optionally carrying the onboarding lock step's answer.
    /// - Parameter deferred: `true` = "Skip for now", `false` = a lock was chosen, `nil` = never asked.
    private func defaults(deferred: Bool?) -> UserDefaults {
        let suite = UserDefaults(suiteName: "fernlet.tests.lockNudge.\(UUID().uuidString)") ?? .standard
        if let deferred { suite.set(deferred, forKey: OnboardingDefaults.lockSetupDeferredKey) }
        return suite
    }

    /// What the section would render for this lock service and nudge.
    private func content(_ service: FernletLockService, _ nudge: DeferredLockSetupNudge) -> ProgressPhotoSectionContent {
        ProgressPhotoSectionContent.resolve(
            gateActive: service.isLockConfigured,
            isUnlocked: service.isUnlocked(for: .progressPhotos),
            offersLockNudge: nudge.isOffered(isLockConfigured: service.isLockConfigured)
        )
    }

    private func sampleJPEG() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }

    // MARK: - First use, and only once

    @Test func appearsForADeferredNoLockUserOnFirstUseAndOnlyOnce() {
        let suite = defaults(deferred: true)
        let nudge = DeferredLockSetupNudge(defaults: suite)

        #expect(nudge.isOffered(isLockConfigured: false), "a user who skipped the lock step must be nudged on first use")
        // Until it is answered it waits for them — the next visit, or after a relaunch.
        #expect(DeferredLockSetupNudge(defaults: suite).isOffered(isLockConfigured: false))

        nudge.notNow()

        #expect(!nudge.isOffered(isLockConfigured: false), "\"Not now\" must retire the card at once")
        #expect(!DeferredLockSetupNudge(defaults: suite).isOffered(isLockConfigured: false),
                "the answer must survive a relaunch — the nudge shows only once")
        #expect(suite.bool(forKey: OnboardingDefaults.lockSetupDeferredKey),
                "\"Not now\" sets no lock, so the deferral itself stands")
    }

    /// The nudge is the promise `lockSetupDeferredKey` made, so it speaks only to users who deferred.
    @Test func honorsTheOnboardingDeferralKey() {
        // Chose a lock at onboarding (and has since removed it): a deliberate call, not nagged.
        #expect(!DeferredLockSetupNudge(defaults: defaults(deferred: false)).isOffered(isLockConfigured: false))
        // Never saw the lock step: nobody is assumed to have skipped it.
        #expect(!DeferredLockSetupNudge(defaults: defaults(deferred: nil)).isOffered(isLockConfigured: false))
    }

    // MARK: - Never with a lock

    @Test func neverAppearsWhenALockIsConfigured() async throws {
        let nudge = DeferredLockSetupNudge(defaults: defaults(deferred: true))
        #expect(!nudge.isOffered(isLockConfigured: true))

        // Against the real service: a lock configured ANYWHERE (Settings here) retires the card,
        // whatever the deferral bit still says.
        let service = freshLockService()
        defer { try? service.reset() }
        #expect(content(service, nudge) == .revealed(offersLockNudge: true))

        try await service.configure(credential: .pin6("246810"), grantingScope: .appLockSettings)

        #expect(service.isLockConfigured)
        #expect(!nudge.isOffered(isLockConfigured: service.isLockConfigured), "a lock exists, yet the nudge offered one")
        #expect(content(service, nudge) == .locked)
    }

    // MARK: - "Set up lock"

    @Test func setUpLockRoutesToTheSetupThatGrantsProgressPhotos() async throws {
        let suite = defaults(deferred: true)
        let nudge = DeferredLockSetupNudge(defaults: suite)

        nudge.setUpLock()
        #expect(nudge.isPresentingLockSetup, "\"Set up lock\" must open the setup")
        #expect(DeferredLockSetupNudge.grantingScope == .progressPhotos)

        // A setup the user backed out of configured nothing, so it answers nothing: the card stays.
        nudge.isPresentingLockSetup = false
        nudge.lockSetupDismissed(isLockConfigured: false)
        #expect(nudge.isOffered(isLockConfigured: false))

        // The setup the sheet runs ends in `configure(credential:grantingScope:)` with the nudge's
        // scope: the photo strip opens, and nothing else does.
        let service = freshLockService()
        defer { try? service.reset() }
        nudge.setUpLock()
        try await service.configure(credential: .pin6("135790"), grantingScope: DeferredLockSetupNudge.grantingScope)
        nudge.isPresentingLockSetup = false
        nudge.lockSetupDismissed(isLockConfigured: service.isLockConfigured)

        #expect(service.isUnlocked(for: .progressPhotos))
        #expect(!service.isUnlocked(for: .privateHub), "a lock set up from the photo strip opened the Private tab")
        #expect(content(service, nudge) == .revealed(offersLockNudge: false),
                "the user must land back on their photos, with the card gone")
        #expect(nudge.isAnswered)
        #expect(!suite.bool(forKey: OnboardingDefaults.lockSetupDeferredKey),
                "a lock set up from the nudge must clear the deferral, as the onboarding lock step does")
        // Remove that lock later and the answered nudge still stays retired.
        #expect(!DeferredLockSetupNudge(defaults: suite).isOffered(isLockConfigured: false))
    }

    // MARK: - Capture still works

    /// Over every input, the nudge rides WITH the revealed strip and its capture control — it can
    /// never be what the section shows instead of them.
    @Test func theNudgeNeverTakesThePlaceOfCapture() {
        for gateActive in [false, true] {
            for isUnlocked in [false, true] {
                for offersLockNudge in [false, true] {
                    let content = ProgressPhotoSectionContent.resolve(
                        gateActive: gateActive, isUnlocked: isUnlocked, offersLockNudge: offersLockNudge
                    )
                    #expect((content == .locked) == (gateActive && !isUnlocked))
                    if case .revealed(let shown) = content {
                        #expect(shown == offersLockNudge)
                    }
                }
            }
        }
        // The user the nudge is for (no lock): the card AND the capture control.
        #expect(ProgressPhotoSectionContent.resolve(gateActive: false, isUnlocked: false, offersLockNudge: true)
                == .revealed(offersLockNudge: true))
    }

    /// Capturing needs no answer from the nudge, and leaves it unanswered.
    @Test func captureStillWorksWhileTheNudgeIsUnanswered() throws {
        let store = makeTestStore()
        let nudge = DeferredLockSetupNudge(defaults: defaults(deferred: true))
        #expect(nudge.isOffered(isLockConfigured: false))
        let jpeg = sampleJPEG()
        try #require(!jpeg.isEmpty)

        let record = try #require(store.addProgressPhoto(data: jpeg, capturedAt: Date()), "capture failed with the nudge up")
        defer { store.deleteProgressPhoto(id: record.id) }

        #expect(store.progressPhotoRecords().contains { $0.id == record.id })
        #expect(store.progressPhotoData(for: record.id) != nil)
        #expect(nudge.isOffered(isLockConfigured: false), "capturing must not answer the nudge for the user")
    }
}
