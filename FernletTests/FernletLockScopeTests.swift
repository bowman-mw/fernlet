// FernletLockScopeTests.swift
// FernletTests
//
// One unlock covers ONE locked surface. These are the tests for that guarantee.
//
// Before scoping, `FernletLockService.state` was a single global `.unlocked`, so unlocking the
// progress-photo strip (or Settings → App lock) also opened the Private tab. The only thing standing
// between those surfaces was a re-lock on `onDisappear` — which a covering sheet, the camera's
// full-screen cover or a scene transition legitimately suppresses. Unlock the progress photos, start
// a workout, then open the Private tab, and you were let straight in.
//
// The fix has three load-bearing parts, each tested here:
//   1. `unlock(passcode:for:)` grants ONE scope; every other scope still reads as locked.
//   2. `revokeUnlockOutside(_:)` — an arriving surface revokes a foreign unlock instead of
//      inheriting it, so the guarantee doesn't depend on the departing surface having locked itself.
//   3. `contentKey(for:)` is the decrypt seam: only `.privateHub` ever gets the sealed-content key.

import Foundation
import SwiftUI
import Testing
import CryptoKit
import UIKit
import FernletFoundation
import FernletDomainModel
import FernletLock
import FernletLockUI
import HealthKitGateway
import LocalPersistence
@testable import Fernlet

@MainActor
private func freshScopedService() -> FernletLockService {
    let service = FernletLockService(
        keychainService: "com.fernlet.lock.scopetest.\(UUID().uuidString)",
        // reset() sweeps the sealed-content device keys too; keep that off the real service.
        sealedContentKeyServices: ["com.fernlet.journal.test.\(UUID().uuidString)"],
        mediaKeychainServices: ["com.fernlet.private-media.test.\(UUID().uuidString)"]
    )
    try? service.reset()
    return service
}

@Suite(.serialized)
struct FernletLockScopeTests {

    // MARK: - An unlock covers exactly one surface

    @MainActor
    @Test func unlockGrantsOnlyTheRequestedScope() async throws {
        let service = freshScopedService()
        defer { try? service.reset() }

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        service.lock(reason: .manual)

        _ = try await service.unlock(passcode: "123456", for: .progressPhotos)

        #expect(service.state == .unlocked(scope: .progressPhotos))
        #expect(service.isUnlocked(for: .progressPhotos))
        #expect(!service.isUnlocked(for: .privateHub))
        #expect(!service.isUnlocked(for: .appLockSettings))
    }

    @MainActor
    @Test func biometricUnlockGrantsOnlyTheRequestedScope() async throws {
        let keychainService = "com.fernlet.lock.scopetest.\(UUID().uuidString)"
        let bypassKey = Data(repeating: 9, count: 32)
        let service = FernletLockService(
            keychainService: keychainService,
            sealedContentKeyServices: ["com.fernlet.journal.test.\(UUID().uuidString)"],
            mediaKeychainServices: ["com.fernlet.private-media.test.\(UUID().uuidString)"],
            biometricBypassLoader: { _, _ in bypassKey }
        )
        defer { try? service.reset() }
        try? service.reset()

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        service.lock(reason: .manual)

        _ = try await service.unlockWithBiometrics(for: .appLockSettings)

        #expect(service.state == .unlocked(scope: .appLockSettings))
        #expect(!service.isUnlocked(for: .privateHub))
    }

    @MainActor
    @Test func configureGrantsOnlyTheSurfaceItWasStartedFrom() async throws {
        let service = freshScopedService()
        defer { try? service.reset() }

        // Setting a passcode up from Settings → App lock must not hand over the Private tab.
        try await service.configure(credential: .pin6("123456"), grantingScope: .appLockSettings)

        #expect(service.state == .unlocked(scope: .appLockSettings))
        #expect(!service.isUnlocked(for: .privateHub))
        #expect(service.contentKey(for: .privateHub) == nil)
    }

    @MainActor
    @Test func unlockingASecondSurfaceTransfersRatherThanAccumulates() async throws {
        let service = freshScopedService()
        defer { try? service.reset() }

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        #expect(service.isUnlocked(for: .privateHub))

        _ = try await service.unlock(passcode: "123456", for: .progressPhotos)

        #expect(service.isUnlocked(for: .progressPhotos))
        #expect(!service.isUnlocked(for: .privateHub))
        #expect(service.contentKey(for: .privateHub) == nil)
    }

    // MARK: - The decrypt seam

    @MainActor
    @Test func contentKeyIsReleasedOnlyToThePrivateHubScope() async throws {
        let service = freshScopedService()
        defer { try? service.reset() }

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        #expect(service.contentKey(for: .privateHub) != nil)
        // Even while the hub holds the unlock, no other scope may ask for the key.
        #expect(service.contentKey(for: .progressPhotos) == nil)
        #expect(service.contentKey(for: .appLockSettings) == nil)
    }

    @MainActor
    @Test func journalKeyIsWithheldWhileAnotherSurfaceHoldsTheUnlock() async throws {
        let service = freshScopedService()
        defer { try? service.reset() }

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "123456", for: .progressPhotos)

        // Unlocked — but for the photo strip, so journal/period/intimacy plaintext is never derived.
        #expect(service.state.unlockedScope == .progressPhotos)
        #expect(service.contentKey(for: .privateHub) == nil)
        #expect(service.contentKey(for: .progressPhotos) == nil)

        // …and re-entering the hub with the correct passcode still works after the non-hub session.
        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        #expect(service.contentKey(for: .privateHub) != nil)
    }

    /// A non-hub unlock unwraps the content key as a side effect of verifying the passcode. It must
    /// DROP it, not merely withhold it — so this asserts on `hasResidentContentKey`, which bypasses
    /// the scope guard. Asserting through `contentKey(for:)` here would be vacuous: that guard
    /// returns nil for a foreign scope whatever `_contentKey` holds, so the test would still pass
    /// with the scrub removed.
    @MainActor
    @Test func aNonHubUnlockDoesNotLeaveTheContentKeyResident() async throws {
        let service = freshScopedService()
        defer { try? service.reset() }

        try await service.configure(credential: .pin6("123456"), grantingScope: .appLockSettings)
        #expect(!service.hasResidentContentKey)
        #expect(service.contentKey(for: .privateHub) == nil)

        try await service.changeCredential(current: "123456", new: .pin6("654321"))
        #expect(!service.hasResidentContentKey)

        // Same for a progress-photo unlock, which reaches the key by the unlock() path.
        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "654321", for: .progressPhotos)
        #expect(!service.hasResidentContentKey)

        // The hub still gets a working key from the same passcode.
        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "654321", for: .privateHub)
        #expect(service.hasResidentContentKey)
        #expect(service.contentKey(for: .privateHub) != nil)
    }

    @MainActor
    @Test func lockingScrubsTheKeyForEveryScope() async throws {
        let service = freshScopedService()
        defer { try? service.reset() }

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        #expect(service.hasResidentContentKey)

        service.lock(reason: .manual)

        // `hasResidentContentKey` is the assertion that matters: `contentKey(for:)` would return nil
        // from its scope guard alone, so on its own it proves nothing about scrubbing.
        #expect(!service.hasResidentContentKey)
        #expect(service.state.unlockedScope == nil)
        for scope in FernletLockScope.allCases {
            #expect(service.contentKey(for: scope) == nil)
            #expect(!service.isUnlocked(for: scope))
        }
    }

    // MARK: - revokeUnlockOutside — the appear-side half of the guarantee

    @MainActor
    @Test func revokeLocksWhenAnotherSurfaceHoldsTheUnlock() async throws {
        let service = freshScopedService()
        defer { try? service.reset() }

        try await service.configure(credential: .pin6("123456"), grantingScope: .progressPhotos)
        #expect(service.isUnlocked(for: .progressPhotos))

        // The Private tab comes forward. It must revoke, not inherit.
        service.revokeUnlockOutside(.privateHub)

        #expect(service.state == .locked(cooldownDeadline: nil))
        #expect(!service.isUnlocked(for: .privateHub))
        #expect(service.contentKey(for: .privateHub) == nil)
    }

    @MainActor
    @Test func revokeIsANoOpForTheScopeThatOwnsTheUnlock() async throws {
        let service = freshScopedService()
        defer { try? service.reset() }

        try await service.configure(credential: .pin6("123456"), grantingScope: .progressPhotos)

        // The photo DETAIL shares the strip's scope: re-entering must not cost a second unlock.
        service.revokeUnlockOutside(.progressPhotos)

        #expect(service.state == .unlocked(scope: .progressPhotos))
    }

    @MainActor
    @Test func revokeIsANoOpWhileLockedOrUnconfigured() async throws {
        let service = freshScopedService()
        defer { try? service.reset() }

        #expect(service.state == .notConfigured)
        service.revokeUnlockOutside(.privateHub)
        #expect(service.state == .notConfigured)

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        service.lock(reason: .manual)
        let lockedState = service.state
        service.revokeUnlockOutside(.progressPhotos)
        #expect(service.state == lockedState)
    }

    /// The attempt tally is ONE tally across every surface. Guessing three times at the Private tab
    /// and then walking over to the progress-photo strip must not buy a fresh set of tries — the
    /// fourth wrong guess locks out no matter which screen it was made from.
    @MainActor
    @Test func failedAttemptsAccumulateAcrossScopes() async throws {
        let service = freshScopedService()
        defer { try? service.reset() }

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        service.lock(reason: .manual)

        for _ in 0..<3 {
            _ = try? await service.unlock(passcode: "000000", for: .privateHub)
        }
        #expect(service.currentAttemptCount == 3)

        // Same tally, different surface: this is the fourth failure overall, so it must escalate.
        _ = try? await service.unlock(passcode: "000000", for: .progressPhotos)

        guard case .locked(let deadline) = service.state else {
            Issue.record("Expected a cooldown after the fourth failure, got \(service.state)")
            return
        }
        #expect(deadline != nil)
    }

    /// The revoke itself, fired against a LIVE unlock, must not touch the attempt tally.
    @MainActor
    @Test func revokingALiveUnlockPreservesTheAttemptTally() async throws {
        let service = freshScopedService()
        defer { try? service.reset() }

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        service.lock(reason: .manual)
        for _ in 0..<3 {
            _ = try? await service.unlock(passcode: "000000", for: .privateHub)
        }
        #expect(service.currentAttemptCount == 3)

        // A revoke while LOCKED is a no-op by design; assert that explicitly rather than assuming.
        service.revokeUnlockOutside(.progressPhotos)
        #expect(service.currentAttemptCount == 3)

        // And a revoke against a live unlock locks without disturbing the (now cleared) tally.
        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        #expect(service.isUnlocked(for: .privateHub))
        service.revokeUnlockOutside(.progressPhotos)
        #expect(service.state.unlockedScope == nil)
        #expect(!service.hasResidentContentKey)
        #expect(service.currentAttemptCount == 0)
    }

    // MARK: - Store-level fallout

    @MainActor
    @Test func healthCapabilitiesStayClosedWhenAnotherSurfaceHoldsTheUnlock() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lock-scope-caps-\(UUID().uuidString).json")
        let store = FernletStore(repository: LocalFernletRepository(fileURL: url))
        store.ageAssurance.applyDetermination(
            lowerBound: AgeGate.intimacy.minimumAge,
            upperBound: nil,
            provenance: .selfDeclared
        )
        store.settings.userProfile.sex = .female
        store.settings.periodTrackingVisible = true
        store.settings.intimacyTrackingVisible = true
        let all = Set(HealthCapability.allCases)

        store.lockState = .unlocked(scope: .privateHub)
        #expect(store.allowedHealthCapabilities(from: all).contains(.cycleTracking))

        // Cycle + intimacy are Private Hub data: an unlock held by the photo strip re-closes them.
        store.lockState = .unlocked(scope: .progressPhotos)
        let allowed = store.allowedHealthCapabilities(from: all)
        #expect(!allowed.contains(.cycleTracking))
        #expect(!allowed.contains(.intimateLogging))
    }

    // NOTE: the cycle-state scrub added to `ContentView.drainPendingPeriodNarrativesIfUnlocked` has
    // no unit test — the seam is a private method on a SwiftUI View, and a test that only called
    // `PeriodTrackerStore.scrubCycleState()` directly would re-prove the store (already covered by
    // the visibility-gate tests) while proving nothing about the wiring. Verified by reading; worth
    // a hosting-level test if this area churns again.

    // MARK: - The gate, end to end

    /// The reported bug, as a test: the progress-photo strip holds an unlock, the user wanders off
    /// (no disappear re-lock fires), and the Private tab's gate comes forward. It must revoke.
    @MainActor
    @Test func privateHubGateRevokesAProgressPhotoUnlockOnAppear() async throws {
        let service = freshScopedService()
        defer { try? service.reset() }
        guard let windowScene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            Issue.record("Expected an active window scene for SwiftUI lifecycle testing")
            return
        }

        try await service.configure(credential: .pin6("135246"), grantingScope: .progressPhotos)
        #expect(service.isUnlocked(for: .progressPhotos))

        var window: UIWindow? = UIWindow(windowScene: windowScene)
        window?.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        window?.rootViewController = UIHostingController(
            rootView: Text("private hub")
                .fernletLockGate(scope: .privateHub)
                .environment(service)
        )
        window?.makeKeyAndVisible()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!service.isUnlocked(for: .privateHub))
        #expect(service.state.unlockedScope == nil)
        #expect(service.contentKey(for: .privateHub) == nil)

        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }

    /// The complement: a gate re-entering its OWN scope keeps the session (this is what stops the
    /// strip → photo detail → pop-back path costing a fresh Face ID for every photo).
    @MainActor
    @Test func gateKeepsAnUnlockItAlreadyOwnsOnAppear() async throws {
        let service = freshScopedService()
        defer { try? service.reset() }
        guard let windowScene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            Issue.record("Expected an active window scene for SwiftUI lifecycle testing")
            return
        }

        try await service.configure(credential: .pin6("135246"), grantingScope: .progressPhotos)

        var window: UIWindow? = UIWindow(windowScene: windowScene)
        window?.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        window?.rootViewController = UIHostingController(
            rootView: Text("photo detail")
                .fernletLockGate(scope: .progressPhotos)
                .environment(service)
        )
        window?.makeKeyAndVisible()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(service.isUnlocked(for: .progressPhotos))

        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }
}
