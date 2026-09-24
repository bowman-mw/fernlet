// OnboardingIntimacyChoiceTests.swift
// FernletTests
//
// The intimacy-tracking opt-out right after the onboarding age gate (owner call: intimacy tracking
// stays visible by default for users verified 16+, and onboarding presents the option to disable it
// after the age gate).
//
// What these pin, each against the model the real screens drive (`OnboardingCoordinatorModel`):
//   * The choice lands in the SAME setting the Settings toggle drives, through the same setter, and
//     survives a reload.
//   * The default is unchanged: `intimacyTrackingVisible` still defaults on, the choice opens on
//     "keep", and a user who keeps it (or never answers) leaves the setting untouched.
//   * Under-16 and undetermined users never see the choice, and their setting is never written.
//   * Turning it off HIDES — the gated store reads nothing — and deletes nothing: the sealed row is
//     still there for a reader whose gate is open.
//
// Filter at SUITE level (`-only-testing:FernletTests/OnboardingIntimacyChoiceTests`) — a method-level
// filter matches no Swift Testing case and still prints a green banner.

import CoreData
import CryptoKit
import Foundation
import Testing
import CloudKitSync
import FernletDomainModel
import FernletPersistence
import PrivateHealthStore
import PrivateStoreCore
@testable import Fernlet

/// Every way the 16+ intimacy gate can still be CLOSED when the onboarding age check answers.
enum ClosedIntimacyGate: String, CaseIterable, Sendable {
    /// The system was never asked (or the request never came back) — the fail-closed start.
    case neverAsked
    /// "Don't Share", or an account with no age information.
    case declined
    /// A bracket entirely under 13.
    case underThirteen
    /// The band that motivated the split: old enough for nearby chat, not for intimacy.
    case thirteenToSixteen
    /// A 16+ bracket the system returned WITHOUT provenance — deliberately not enough to open a gate.
    case sixteenPlusWithoutProvenance

    /// Puts `ageAssurance` into this state.
    @MainActor
    func apply(to ageAssurance: AgeAssuranceStore) {
        switch self {
        case .neverAsked:
            ageAssurance.clear()
        case .declined:
            ageAssurance.applyUndetermined()
        case .underThirteen:
            ageAssurance.applyDetermination(lowerBound: nil, upperBound: 13, provenance: .guardianDeclared)
        case .thirteenToSixteen:
            ageAssurance.applyDetermination(lowerBound: 13, upperBound: 16, provenance: .guardianDeclared)
        case .sixteenPlusWithoutProvenance:
            ageAssurance.applyDetermination(lowerBound: 16, upperBound: nil, provenance: nil)
        }
    }
}

@MainActor
struct OnboardingIntimacyChoiceTests {

    // MARK: - Fixtures

    /// A throwaway defaults suite for the model's own writes (`lockSetupDeferred`,
    /// `hasCompletedOnboarding`), so `complete()` never touches the test host's `.standard`.
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "fernlet.tests.onboardingIntimacy.\(UUID().uuidString)") ?? .standard
    }

    /// An onboarding model standing on the personal-details step — the step that runs the age check.
    /// Walked there with the real `advance()`, bounded by the step count.
    private func modelAtPersonalDetails(_ store: FernletStore) -> OnboardingCoordinatorModel {
        let model = OnboardingCoordinatorModel(store: store, defaults: isolatedDefaults(), onComplete: {})
        for _ in OnboardingCoordinatorModel.Step.allCases where model.step != .personalDetails {
            model.advance()
        }
        #expect(model.step == .personalDetails)
        return model
    }

    /// A 16+ answer with provenance — the only kind of bracket that opens the intimacy gate.
    private func seedSixteenPlus(_ store: FernletStore) {
        store.ageAssurance.applyDetermination(
            lowerBound: AgeGate.intimacy.minimumAge, upperBound: nil, provenance: .selfDeclared
        )
    }

    /// Walks the choice the way the UI does: the age check answers, the personal-details step swaps to
    /// its second page (still the same step), the user picks and taps Continue, and the flow moves on.
    private func answerIntimacyChoice(_ model: OnboardingCoordinatorModel, keep: Bool) {
        model.ageCheckFinished()
        #expect(model.isShowingIntimacyChoice, "a 16+ user must be offered the choice after the age check")
        #expect(model.step == .personalDetails, "the choice is a page of the personal-details step, not a step")
        model.confirmIntimacyTrackingChoice(keep: keep)
        #expect(!model.isShowingIntimacyChoice)
        #expect(model.step == .dietaryPattern, "Continue must move the flow on")
    }

    // MARK: - The choice persists to the Settings setting

    /// "Turn it off" writes `intimacyTrackingVisible` — the field the Settings toggle reads — through
    /// `setIntimacyTrackingVisible`, the setter the toggle drives, and the value survives a reload.
    @Test func theChoicePersistsToTheSettingsSetting() {
        let sidecar = uniqueSensitiveVisibilityDefaults()
        let (store, repository, _) = makeTestStoreWithRepositories(sensitiveVisibilityDefaults: sidecar)
        seedSixteenPlus(store)
        let model = modelAtPersonalDetails(store)

        answerIntimacyChoice(model, keep: false)
        // Draft until the flow completes, like every other onboarding choice.
        #expect(store.settings.intimacyTrackingVisible, "the answer must not persist before complete()")

        model.complete()

        #expect(!store.settings.intimacyTrackingVisible, "the answer did not reach the Settings setting")
        #expect(!store.isIntimacyTrackingVisible)
        // Written through the Settings setter, not around it: only `setIntimacyTrackingVisible` records
        // the device-local resolution, which is what keeps a mixed-version key-drop from reopening it.
        #expect(sidecar.object(forKey: "sensitiveVisibilityResolvedIntimacyVisible") as? Bool == false,
                "the answer bypassed the setter the Settings toggle uses")
        // Settings shows the toggle (not the age notice) for this user, bound to the value just written.
        #expect(store.isIntimateLoggingAllowed)

        store.flushPendingSnapshotSave()
        let reloaded = repository.loadSnapshot(todayKey: store.todayKey).settings
        #expect(!reloaded.intimacyTrackingVisible, "the answer did not survive a reload")
    }

    // MARK: - The default is unchanged

    /// The setting still defaults on, the choice opens on "keep", and keeping it — or never answering —
    /// leaves the setting exactly where it was.
    @Test func theDefaultIsUnchanged() {
        #expect(FernletSettings().intimacyTrackingVisible, "the default flipped")

        let store = makeTestStore()
        seedSixteenPlus(store)
        let model = modelAtPersonalDetails(store)
        #expect(model.keepsIntimacyTracking, "the choice must open on \"keep\"")

        answerIntimacyChoice(model, keep: true)
        model.complete()

        #expect(store.settings.intimacyTrackingVisible)
        #expect(store.isIntimacyTrackingVisible)

        let untouched = makeTestStore()
        seedSixteenPlus(untouched)
        OnboardingCoordinatorModel(store: untouched, defaults: isolatedDefaults(), onComplete: {}).complete()
        #expect(untouched.settings.intimacyTrackingVisible, "completing without the choice changed the default")
        #expect(untouched.isIntimacyTrackingVisible)
    }

    /// Coming back to the choice shows the answer already given, not the default.
    @Test func theChoiceReopensOnTheAnswerAlreadyGiven() {
        let store = makeTestStore()
        seedSixteenPlus(store)
        let model = modelAtPersonalDetails(store)
        answerIntimacyChoice(model, keep: false)

        model.back()
        #expect(model.step == .personalDetails)
        #expect(!model.keepsIntimacyTracking, "going back lost the answer")
    }

    // MARK: - Under 16 and undetermined never see it

    /// For every closed-gate outcome the age check can produce, the step moves straight on, the choice
    /// never appears, and the setting is never written — intimacy stays hidden exactly as before.
    @Test(arguments: ClosedIntimacyGate.allCases)
    func underSixteenAndUndeterminedUsersNeverSeeTheChoice(gate: ClosedIntimacyGate) {
        let store = makeTestStore()
        gate.apply(to: store.ageAssurance)
        let model = modelAtPersonalDetails(store)

        #expect(!model.offersIntimacyTrackingChoice)
        model.ageCheckFinished()

        #expect(!model.isShowingIntimacyChoice, "\(gate.rawValue): the choice was offered")
        #expect(model.step == .dietaryPattern, "\(gate.rawValue): the flow did not move on")

        model.complete()
        #expect(store.settings.intimacyTrackingVisible, "\(gate.rawValue): the setting was written")
        #expect(!store.isIntimacyTrackingVisible, "\(gate.rawValue): the age gate stopped hiding intimacy")
    }

    /// An answer given while the gate was open does not outlive the gate: go back, re-run the check to
    /// a closed verdict, and completing writes nothing.
    @Test func anAnswerDoesNotOutliveAGateThatClosed() {
        let store = makeTestStore()
        seedSixteenPlus(store)
        let model = modelAtPersonalDetails(store)
        answerIntimacyChoice(model, keep: false)

        model.back()
        ClosedIntimacyGate.thirteenToSixteen.apply(to: store.ageAssurance)
        model.ageCheckFinished()
        #expect(!model.isShowingIntimacyChoice)

        model.complete()
        #expect(store.settings.intimacyTrackingVisible, "a stale answer was written past a closed gate")
    }

    /// The choice page's Back records nothing and returns to the personal-details form.
    @Test func backingOutOfTheChoiceRecordsNothingAndStays() {
        let store = makeTestStore()
        seedSixteenPlus(store)
        let model = modelAtPersonalDetails(store)

        model.ageCheckFinished()
        #expect(model.isShowingIntimacyChoice)
        model.leaveIntimacyChoice()

        #expect(!model.isShowingIntimacyChoice, "Back did not return to the form")
        #expect(model.step == .personalDetails, "Back moved the flow")
        #expect(model.intimacyTrackingDraft == nil, "Back recorded an answer")
    }

    // MARK: - Off hides, never deletes

    /// A sealed intimacy row, gated the way `ContentView` wires the store. Turning intimacy off in
    /// onboarding makes the gated store read nothing and refuse writes — and the row is still there.
    @Test func turningItOffHidesWithoutDeleting() throws {
        let store = makeTestStore()
        seedSixteenPlus(store)
        let context = PrivatePersistenceController(inMemory: true).container.viewContext
        let latch = UserDefaults(suiteName: "fernlet.tests.intimacyLatch.\(UUID().uuidString)") ?? .standard
        let gated = IntimacyLogStore(repository: IntimacyLogRepository(context: context, defaults: latch))
        gated.attachVisibilityGate { [store] in store.isIntimacyTrackingVisible }
        let key = SymmetricKey(size: .bits256)
        try gated.insert(IntimacyLog(eventDate: Date(), note: "logged before onboarding finished"), contentKey: key)
        #expect(try gated.logs(contentKey: key).count == 1)

        let model = modelAtPersonalDetails(store)
        answerIntimacyChoice(model, keep: false)
        model.complete()

        // Hidden: the decrypt seam reads nothing and seals nothing.
        #expect(try gated.logs(contentKey: key).isEmpty, "hidden intimacy was still decrypted")
        #expect(throws: IntimacyTrackingHiddenError.self) {
            try gated.insert(IntimacyLog(eventDate: Date(), note: "must not seal while hidden"), contentKey: key)
        }
        // Never deleted: a reader whose gate is open still finds the row.
        let auditor = IntimacyLogStore(repository: IntimacyLogRepository(context: context, defaults: latch))
        auditor.attachVisibilityGate { true }
        #expect(try auditor.logs(contentKey: key).first?.note == "logged before onboarding finished",
                "turning intimacy off deleted the sealed log")
    }
}
