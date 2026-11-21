// OnboardingLaunchGateTests.swift
// FernletTests
//
// Owner's bug, 2026-11-20: "every so often, the onboarding screen shows up instead of the app".
//
// The cause these reproduce: the completion bit lives in `UserDefaults.standard`, which iOS cannot
// read before the first unlock after a restart. A process started then (a drive relaunch, a
// background refresh, a prewarm) reads `false` and `@AppStorage` keeps it, so tapping the icon later
// showed onboarding. A locked read is modelled here the way the app sees it — the defaults bit reads
// `false` — while the store's own settings (which load only after an unlock) say finished.
//
// What these pin:
//   * An unreadable defaults domain never means "new person" while the store says finished.
//   * Nothing finished + still locked = wait for the unlock, never onboarding.
//   * A decision holds: the app is never swapped for onboarding by a later read, and an iCloud pull
//     mid-onboarding does not yank a new person into the app.
//   * Onboarding can never overwrite a finished setup, and over an existing passcode it skips the
//     lock step and offers "Continue to Fernlet", which writes nothing else.
//
// Filter at SUITE level (`-only-testing:FernletTests/OnboardingLaunchGateTests`).

import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

@MainActor
struct OnboardingLaunchGateTests {

    private typealias Gate = OnboardingLaunchGate

    private func evidence(
        defaults: Bool = false, settings: Bool = false, unlocked: Bool = true, passcode: Bool = false
    ) -> Gate.Evidence {
        Gate.Evidence(defaultsSayFinished: defaults, settingsSayFinished: settings,
                      protectedDataAvailable: unlocked, passcodeConfigured: passcode)
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "fernlet.tests.onboardingLaunchGate.\(UUID().uuidString)") ?? .standard
    }

    // MARK: - The decision table

    /// The bug itself: a locked launch read the defaults bit as `false`, the store says finished.
    @Test func lockedDefaultsReadWithFinishedStoreShowsTheApp() {
        #expect(Gate.decide(evidence(defaults: false, settings: true, unlocked: false)) == .app)
        #expect(Gate.decide(evidence(defaults: false, settings: true, unlocked: true)) == .app)
    }

    /// Either witness alone is enough.
    @Test func eitherWitnessShowsTheApp() {
        #expect(Gate.decide(evidence(defaults: true, settings: false)) == .app)
        #expect(Gate.decide(evidence(defaults: true, settings: false, unlocked: false)) == .app)
    }

    /// Nothing says finished and the phone is still locked: wait, never onboarding.
    @Test func nothingReadableWhileLockedWaitsForTheUnlock() {
        #expect(Gate.decide(evidence(unlocked: false)) == .waitForUnlock)
        #expect(Gate.decide(evidence(unlocked: false, passcode: true)) == .waitForUnlock)
    }

    /// A genuinely new phone gets onboarding; one holding a passcode gets the existing-setup flow.
    @Test func unlockedWithNothingFinishedShowsOnboarding() {
        #expect(Gate.decide(evidence()) == .onboarding(existingSetup: false))
        #expect(Gate.decide(evidence(passcode: true)) == .onboarding(existingSetup: true))
    }

    // MARK: - Settling

    /// The wait gives way to the decision the unlock makes.
    @Test func theUnlockEdgeReplacesTheWait() {
        let e = evidence(settings: true)
        #expect(Gate.settle(current: .waitForUnlock, next: Gate.decide(e), evidence: e) == .app)
        let fresh = evidence()
        #expect(Gate.settle(current: .waitForUnlock, next: Gate.decide(fresh), evidence: fresh)
                == .onboarding(existingSetup: false))
    }

    /// The app is never swapped for onboarding by a later read.
    @Test func theAppHoldsAgainstALaterRead() {
        let e = evidence(unlocked: true)
        #expect(Gate.settle(current: .app, next: Gate.decide(e), evidence: e) == .app)
        let locked = evidence(unlocked: false)
        #expect(Gate.settle(current: .app, next: Gate.decide(locked), evidence: locked) == .app)
    }

    /// An iCloud settings pull landing mid-onboarding does not end the flow; the device's own bit
    /// (which onboarding's finish writes) does.
    @Test func onboardingGivesWayOnlyToTheDevicesOwnBit() {
        let pulled = evidence(settings: true)
        #expect(Gate.settle(current: .onboarding(existingSetup: false), next: Gate.decide(pulled), evidence: pulled)
                == .onboarding(existingSetup: false))
        let finished = evidence(defaults: true)
        #expect(Gate.settle(current: .onboarding(existingSetup: false), next: Gate.decide(finished), evidence: finished)
                == .app)
    }

    /// The bit is healed only when the store says finished and the write can land.
    @Test func healsTheDefaultsBitOnlyWhenUnlocked() {
        #expect(Gate.shouldHealDefaults(evidence(settings: true, unlocked: true)))
        #expect(!Gate.shouldHealDefaults(evidence(settings: true, unlocked: false)))
        #expect(!Gate.shouldHealDefaults(evidence(defaults: true, settings: true)))
        #expect(!Gate.shouldHealDefaults(evidence()))
    }

    // MARK: - Onboarding can never overwrite a finished setup

    /// Walking the whole flow over a store that already finished onboarding replaces nothing.
    @Test func completingOverAFinishedSetupKeepsEverything() {
        let store = makeTestStore()
        store.completeOnboarding(profile: store.settings.userProfile,
                                 preferences: store.settings.nutritionPreferences, goal: .strength)
        store.setCompanionName("Bramble")
        let defaults = isolatedDefaults()
        var completed = 0
        let model = OnboardingCoordinatorModel(store: store, defaults: defaults, onComplete: { completed += 1 })
        model.goal = .recovery
        model.starterName = "Someone else"

        model.complete()

        #expect(store.settings.selectedGoal == .strength, "onboarding overwrote the person's goal")
        #expect(store.settings.companionName == "Bramble", "onboarding overwrote the companion's name")
        #expect(defaults.bool(forKey: OnboardingDefaults.hasCompletedOnboardingKey))
        #expect(completed == 1)
    }

    /// "Continue to Fernlet" marks onboarding finished and writes nothing else.
    @Test func continueWithExistingSetupWritesOnlyTheCompletionBit() {
        let store = makeTestStore()
        let goalBefore = store.settings.selectedGoal
        let profileBefore = store.settings.userProfile
        let defaults = isolatedDefaults()
        var completed = 0
        let model = OnboardingCoordinatorModel(store: store, defaults: defaults, existingSetup: true,
                                               onComplete: { completed += 1 })
        model.goal = goalBefore == .recovery ? .strength : .recovery

        model.continueWithExistingSetup()

        #expect(store.settings.hasCompletedOnboarding)
        #expect(store.settings.selectedGoal == goalBefore)
        #expect(store.settings.userProfile == profileBefore)
        #expect(defaults.bool(forKey: OnboardingDefaults.hasCompletedOnboardingKey))
        #expect(completed == 1)
    }

    /// Without an existing setup the shortcut does nothing.
    @Test func continueWithoutAnExistingSetupDoesNothing() {
        let store = makeTestStore()
        let defaults = isolatedDefaults()
        let model = OnboardingCoordinatorModel(store: store, defaults: defaults, onComplete: {})
        model.continueWithExistingSetup()
        #expect(!store.settings.hasCompletedOnboarding)
        #expect(!defaults.bool(forKey: OnboardingDefaults.hasCompletedOnboardingKey))
    }

    /// Over an existing passcode the lock step is skipped both ways, so it can never be offered.
    @Test func theLockStepIsSkippedOverAnExistingPasscode() {
        let model = OnboardingCoordinatorModel(store: makeTestStore(), defaults: isolatedDefaults(),
                                               existingSetup: true, onComplete: {})
        model.advance()
        #expect(model.step == .storageChoice)
        model.back()
        #expect(model.step == .welcome)

        let fresh = OnboardingCoordinatorModel(store: makeTestStore(), defaults: isolatedDefaults(), onComplete: {})
        fresh.advance()
        #expect(fresh.step == .lockSetup)
    }
}
