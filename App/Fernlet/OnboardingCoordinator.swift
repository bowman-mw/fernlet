import Observation
import SwiftUI
import CloudKitSync
import FernletDomainModel
import FernletFoundation
import FernletLock
import FernletScoring
import FernletUI

/// Abstraction over the "does this iCloud account already hold Fernlet data?" probe.
///
/// Conformers: `CloudKitDataService` (the real CloudKit query, via the retroactive conformance
/// below) and ``MockExistingCloudDataDetector`` (fixed answers for UI tests and previews).
/// ``OnboardingStorageChoiceView`` runs it before revealing the storage choices so a returning
/// user sees "Restore from iCloud" and the local-only warning instead of the fresh-install copy.
protocol ExistingCloudDataDetecting {
    /// - Returns: Counts of the account's existing Fernlet records, or nil when none were found.
    func detectExistingData() async throws -> ExistingDataSummary?
}

extension CloudKitDataService: ExistingCloudDataDetecting {}

// DEBUG-only: this double fabricates the answer the storage step keys its durable
// `cloudCopyKept` decision off, so in a shipping binary it must be ABSENT, not merely unreachable.
// Its only reference is `OnboardingCloudDataDetectorFactory.makeDetector`, itself inside `#if DEBUG`.
#if DEBUG
/// Test double for ``ExistingCloudDataDetecting`` that returns a canned summary without touching CloudKit.
///
/// Built by ``OnboardingCloudDataDetectorFactory`` when the UI-test launch environment asks for a
/// deterministic storage step — either "no existing data" or a summary assembled from env counts.
private struct MockExistingCloudDataDetector: ExistingCloudDataDetecting {
    var summary: ExistingDataSummary?

    func detectExistingData() async throws -> ExistingDataSummary? {
        summary
    }
}
#endif

/// Namespace for the `UserDefaults` keys onboarding writes and the rest of the app reads.
///
/// `FernletApp` keys the onboarding-vs-main-UI decision off `hasCompletedOnboardingKey`;
/// `lockSetupDeferredKey` records that the lock step was skipped so lockable features can prompt
/// for setup at first use instead of assuming a lock exists. ``DeferredLockSetupNudge`` is that
/// first-use prompt, and `progressPhotoLockNudgeAnsweredKey` is its one bit of memory.
enum OnboardingDefaults {
    static let hasCompletedOnboardingKey = "hasCompletedOnboarding"
    static let lockSetupDeferredKey = "lockSetupDeferred"
    /// `true` once the progress-photo lock-setup nudge has been answered — "Not now", or a lock set
    /// up from it — so it never shows again. Device-local UI memory: no content, no timestamps.
    static let progressPhotoLockNudgeAnsweredKey = "fernlet.progressPhotos.lockNudgeAnswered"
}

/// The first-use prompt a deferred onboarding lock step promises, on the one lockable surface that
/// keeps working without a lock: the progress-photo strip under Move.
///
/// `OnboardingDefaults.lockSetupDeferredKey` has said since it was written that lockable features
/// "can prompt for setup at first use" — and until this type nothing read it. The Private hub owes
/// no nudge (its gate will not open at all without a lock). The photo strip does, because it
/// deliberately keeps capture working with no lock: a user who tapped "Skip for now" could fill it
/// with body photos without ever hearing that the lock could cover them.
///
/// **When it is offered** — all three must hold: no lock is configured; the user DEFERRED the
/// onboarding lock step (`lockSetupDeferred == true` — a user who chose a lock there and later
/// removed it made that call deliberately, and nobody is assumed to have skipped a step they never
/// saw); and it has not been answered yet.
///
/// **How it is answered** — "Not now", or a lock actually set up from it; either way it never
/// returns. A setup sheet backed out of configures nothing and so answers nothing: the card stays.
/// A lock set up from it also clears the deferral — the same write the onboarding lock step makes
/// when a lock is chosen there — so the bit stays true to its name.
///
/// **What it never does** — gate, delay or intercept capture. It is an inline card ABOVE the
/// capture control (``ProgressPhotoSectionContent``), never a modal in front of it.
///
/// Lives beside ``OnboardingDefaults`` on purpose: both keys it touches are literals declared in
/// this file, which is what lets `PersistedSurfaceWipeBoundaryTests` resolve them to their rows
/// rather than record a symbolic seam. `@MainActor` + `@Observable` because a SwiftUI view owns it
/// as `@State` and must re-render the moment it is answered — `UserDefaults` is not observable.
@MainActor
@Observable
final class DeferredLockSetupNudge {
    /// The one surface a lock set up from the nudge opens: the strip the user is standing on, so
    /// they land back on their photos rather than behind a prompt. The Private hub still asks for
    /// the new passcode the first time it opens (`FernletLockService.configure(credential:grantingScope:)`).
    static let grantingScope: FernletLockScope = .progressPhotos

    /// Drives the lock-setup sheet. Raised only by ``setUpLock()``; SwiftUI lowers it on dismissal.
    var isPresentingLockSetup = false
    /// Mirrors the persisted answer so the card disappears the moment it is answered.
    private(set) var isAnswered: Bool
    @ObservationIgnored private let defaults: UserDefaults

    /// - Parameter defaults: Where the answer and the deferral live. Production uses `.standard`,
    ///   which the onboarding lock step writes; tests pass a throwaway suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isAnswered = defaults.bool(forKey: OnboardingDefaults.progressPhotoLockNudgeAnsweredKey)
    }

    /// Whether the card shows right now — the three conditions in the type's documentation.
    func isOffered(isLockConfigured: Bool) -> Bool {
        guard !isLockConfigured, !isAnswered else { return false }
        return defaults.bool(forKey: OnboardingDefaults.lockSetupDeferredKey)
    }

    /// "Set up lock": presents `FernletLockSetupView` granting ``grantingScope``.
    func setUpLock() {
        isPresentingLockSetup = true
    }

    /// "Not now": answered for good. The deferral itself stands — no lock was set up.
    func notNow() {
        recordAnswered()
    }

    /// The setup sheet's `onDismiss`. Only a lock that now EXISTS answers the nudge; a sheet the user
    /// cancelled configured nothing, so the card stays for them.
    func lockSetupDismissed(isLockConfigured: Bool) {
        guard isLockConfigured else { return }
        recordAnswered()
        defaults.set(false, forKey: OnboardingDefaults.lockSetupDeferredKey)
    }

    private func recordAnswered() {
        defaults.set(true, forKey: OnboardingDefaults.progressPhotoLockNudgeAnsweredKey)
        isAnswered = true
    }
}

/// Chooses the ``ExistingCloudDataDetecting`` implementation for this launch.
///
/// `FernletApp` calls ``makeDetector()`` when presenting onboarding: UI-test launch environment
/// variables select a ``MockExistingCloudDataDetector`` (detection disabled, or a summary built
/// from env-supplied counts); every normal launch gets the real `CloudKitDataService`.
@MainActor
struct OnboardingCloudDataDetectorFactory {
    /// - Returns: A mock detector when the UI-test environment requests one, else the live CloudKit service.
    static func makeDetector() -> any ExistingCloudDataDetecting {
        // The `environment` binding lives INSIDE the region with its only readers: left outside it
        // would be unused in Release, and warnings are errors on every target.
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["FERNLET_UI_TEST_DISABLE_CLOUD_DETECTION"] == "1" {
            return MockExistingCloudDataDetector(summary: nil)
        }

        guard environment["FERNLET_UI_TEST_EXISTING_CLOUD_DATA"] == "1" else {
            return CloudKitDataService()
        }

        return MockExistingCloudDataDetector(summary: ExistingDataSummary(
            mealLogCount: Int(environment["FERNLET_UI_TEST_MEAL_LOGS"] ?? "7") ?? 7,
            journalEntryCount: Int(environment["FERNLET_UI_TEST_JOURNAL_ENTRIES"] ?? "3") ?? 3,
            workoutCount: Int(environment["FERNLET_UI_TEST_WORKOUTS"] ?? "2") ?? 2,
            hygieneLogCount: 0,
            hydrationLogCount: 0,
            sleepRecordCount: 0
        ))
        #else
        return CloudKitDataService()
        #endif
    }
}

/// View model for the whole first-run onboarding flow: the current ``Step`` plus every draft choice
/// the user makes along the way.
///
/// Owned as `@State` by ``OnboardingCoordinator``. All choices (goal, body profile, dietary
/// preferences, starter name/color, proximity display name, training level/interests/constraints)
/// accumulate here as plain properties and are committed to ``FernletStore`` in one shot by
/// ``complete()`` — nothing persists per-step, so abandoning onboarding mid-flow writes nothing.
/// The two exceptions are the lock step, which records its skip/choice in `UserDefaults`
/// (``OnboardingDefaults``) immediately, and the storage step, which writes preferences from its
/// own view. `@MainActor` + `@Observable`: SwiftUI reads it on the main actor and re-renders on
/// mutation; the store and completion callback are `@ObservationIgnored` since they never change.
///
/// The personal-details step exits through ``ageCheckFinished()`` rather than ``advance()``: for a
/// user the 16+ intimacy gate admits, the age check is followed by ``OnboardingIntimacyChoiceScreen``
/// — keep intimacy tracking (the default) or turn it off — as a second page of that same step. The
/// answer is draft state too, committed by ``complete()`` through the same setter the Settings
/// toggle uses. Under-16 and undetermined users never see the page and their setting is never
/// touched.
@MainActor
@Observable
final class OnboardingCoordinatorModel {
    /// The ordered onboarding pages.
    ///
    /// `rawValue` order is the flow order — ``advance()`` walks `rawValue + 1` and completes the
    /// flow after the final case — so reordering cases reorders the screens.
    enum Step: Int, CaseIterable {
        case welcome
        case lockSetup
        case storageChoice
        case goal
        case starterCustomization
        case personalDetails
        case dietaryPattern
        case permissions

        /// The "3 of 8" progress caption shown at the top of every onboarding screen.
        ///
        /// Resolved here because ``OnboardingScreenContainer`` draws it with `Text(String)`, which never
        /// looks a `String` up — it read "3 of 8" in every language.
        var indexText: String {
            String(localized: "onboarding.step.index", defaultValue: "\(rawValue + 1) of \(Self.allCases.count)",
                   comment: "Onboarding progress caption, e.g. '3 of 8'. Arguments: this step's number, then the number of steps.")
        }
    }

    /// The page currently on screen. Moved only by ``advance()`` and ``back()``.
    private(set) var step: Step = .welcome
    var goal: GoalType
    var profile: UserNutritionProfile
    var nutritionPreferences: UserNutritionPreferences
    var goalPlanningLevel = "beginner"
    var goalPlanningInterests = ""
    var goalPlanningConstraints = ""
    var starterName = "Fernlet"
    /// Typed, not a display string — the picker, the live preview, and the write in `complete()` all
    /// read this one value, so they cannot disagree about what colour was chosen.
    var starterColor: CompanionAssetColor = .fern
    var proximityDisplayName = ""
    /// The answer from the intimacy choice page — `nil` until the user continues past it, so a user
    /// who never saw the page (under 16, undetermined) or never answered it leaves the setting
    /// exactly as it stands. Draft like everything else here: only ``complete()`` commits it.
    private(set) var intimacyTrackingDraft: Bool?
    /// Whether the personal-details step is showing its second page, the intimacy choice. Raised
    /// only by ``ageCheckFinished()`` for a user the 16+ gate admits.
    private(set) var isShowingIntimacyChoice = false

    @ObservationIgnored private let store: FernletStore
    @ObservationIgnored private let onComplete: () -> Void
    /// Where the lock step's deferral and the completion bit land (``OnboardingDefaults``).
    @ObservationIgnored private let defaults: UserDefaults

    /// Exposed so the personal-details step can run the system age-range request. Onboarding is the one
    /// place Fernlet asks unprompted; everywhere else the request is user-initiated from Settings.
    var ageAssurance: AgeAssuranceStore { store.ageAssurance }

    /// - Parameter defaults: Where the lock deferral and `hasCompletedOnboarding` are written.
    ///   Production uses `.standard`, which `FernletApp` reads; tests pass a throwaway suite.
    init(store: FernletStore, defaults: UserDefaults = .standard, onComplete: @escaping () -> Void) {
        self.store = store
        self.defaults = defaults
        self.onComplete = onComplete
        self.goal = store.settings.selectedGoal
        self.profile = store.settings.userProfile
        self.nutritionPreferences = store.settings.nutritionPreferences
    }

    /// Moves to the next ``Step``, or runs ``complete()`` when the last step finishes.
    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            complete()
            return
        }
        step = next
    }

    /// Returns to the previous ``Step``; a no-op on the first one.
    ///
    /// Safe to re-enter any step: every choice except the lock deferral and the storage preference
    /// is draft state on this model, and both of those are simply re-written by the step's own
    /// action when the user chooses again.
    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// Whether there is a step to go back to — drives the Back button's presence.
    var canGoBack: Bool { step != .welcome }

    /// The Back handler each step passes to ``OnboardingScreenContainer``; `nil` on the first step.
    var backActionIfAvailable: (() -> Void)? {
        guard canGoBack else { return nil }
        return { self.back() }
    }

    /// Records that lock setup was deferred ("Face ID later" or "Skip for now"), audits it, and advances.
    func deferLockSetup() {
        defaults.set(true, forKey: OnboardingDefaults.lockSetupDeferredKey)
        FernletAuditLog.log("onboarding.lock.skipped")
        advance()
    }

    /// Records that a lock was actually configured (clearing any earlier deferral), audits the
    /// method, and advances.
    /// - Parameter method: Audit-log label for how the lock was set up (e.g. "passcode").
    func markLockSetupChosen(via method: String) {
        defaults.set(false, forKey: OnboardingDefaults.lockSetupDeferredKey)
        FernletAuditLog.log("onboarding.lock.chosen", context: ["method": method])
        advance()
    }

    // MARK: - Intimacy tracking choice (right after the age gate)

    /// Whether the intimacy choice applies to this user: only while the age gate is OPEN for
    /// intimacy. Reads the one derived gate every intimacy surface reads —
    /// `FernletStore.isIntimateLoggingAllowed`, i.e. `AgeAssuranceStore.allows(.intimacy)` — so a
    /// user the system placed under 16, or never ruled on, can never be offered it.
    var offersIntimacyTrackingChoice: Bool { store.isIntimateLoggingAllowed }

    /// What the choice page shows selected: the user's answer once given, else the setting as it
    /// stands — `true` ("keep") on every fresh install, because `intimacyTrackingVisible` defaults on.
    var keepsIntimacyTracking: Bool { intimacyTrackingDraft ?? store.settings.intimacyTrackingVisible }

    /// The personal-details step's exit once the system age check has answered (declined and
    /// unavailable included): straight on for everyone the 16+ gate refuses, the intimacy choice
    /// page first for everyone it admits.
    ///
    /// A page swap inside the step rather than a presented sheet, deliberately: this runs the moment
    /// the SYSTEM age-range sheet returns, and a presentation started while that one is still
    /// animating away can fail silently on device — leaving a flag raised over nothing on screen.
    func ageCheckFinished() {
        guard offersIntimacyTrackingChoice else {
            advance()
            return
        }
        isShowingIntimacyChoice = true
    }

    /// The choice page's Continue: records the answer as draft and moves the flow on.
    func confirmIntimacyTrackingChoice(keep: Bool) {
        intimacyTrackingDraft = keep
        isShowingIntimacyChoice = false
        advance()
    }

    /// The choice page's Back: returns to the personal-details form with nothing recorded.
    func leaveIntimacyChoice() {
        isShowingIntimacyChoice = false
    }

    /// Commits the intimacy answer through `FernletStore.setIntimacyTrackingVisible(_:)` — the SAME
    /// setter the Settings toggle drives — so the answer IS the Settings setting and can be changed
    /// there any time. Off is a hide on the gate's usual terms, never a delete: the sealed logs stay,
    /// unread, until the user turns it back on.
    ///
    /// Writes nothing without an answer, when the answer matches the setting (a default "keep" leaves
    /// the default untouched and runs no un-hide settle), or when the gate is closed by the time
    /// onboarding completes — someone who answered, went back and re-ran the check to a closed verdict
    /// is someone the choice no longer applies to.
    private func applyIntimacyTrackingChoice() {
        guard let keep = intimacyTrackingDraft, offersIntimacyTrackingChoice else { return }
        guard keep != store.settings.intimacyTrackingVisible else { return }
        store.setIntimacyTrackingVisible(keep)
    }

    /// Commits every accumulated choice to the store, marks onboarding done, and hands control back
    /// to `FernletApp` via `onComplete`.
    ///
    /// - Important: This is the single persistence point for the flow — profile, preferences, goal,
    ///   default workout goals/profile, proximity display name, companion name, the starter body
    ///   color, and the intimacy answer all land here, so a flow abandoned before this call leaves
    ///   the store untouched.
    func complete() {
        store.completeOnboarding(profile: profile, preferences: nutritionPreferences, goal: goal)
        applyIntimacyTrackingChoice()
        store.replaceGoals(WorkoutPlanner.defaultGoals(
            level: goalPlanningLevel,
            interests: goalPlanningInterests,
            constraints: goalPlanningConstraints
        ))
        store.setWorkoutProfile(WorkoutProfile.fromOnboarding(
            level: goalPlanningLevel,
            interests: goalPlanningInterests,
            constraints: goalPlanningConstraints
        ))
        let name = proximityDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { store.setProximityDisplayName(name) }
        let trimmedStarterName = starterName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStarterName.isEmpty {
            store.setCompanionName(trimmedStarterName)
        }
        // Write `bodyColor` — the field the renderer actually reads (via
        // `CompanionAppearance.resolvedBodyColor`). This used to set `palette`, which nothing in the
        // render path consults: its only remaining job is supplying the absent-key decode default for
        // `bodyColor`, and since the synthesized encoder always emits `bodyColor`, even that never
        // fired. The colour picked during onboarding was silently discarded.
        //
        // Choosing `CompanionAssetColor` also fixes a second casualty of the old mapping: `CompanionPalette`
        // has no `.moss` case, so Fern and Moss both mapped to `.fern` and were indistinguishable.
        var appearance = store.settings.companionAppearance
        appearance.bodyColor = starterColor
        store.setCompanionAppearance(appearance)
        defaults.set(true, forKey: OnboardingDefaults.hasCompletedOnboardingKey)
        // A14: setup's one completion moment, once ever — felt as "Start Fernlet" lands, and said
        // once the swap to the app has settled (the onboarding view is the one going away, so an
        // unstructured task, not its `.task`).
        FernletFeedback.system.play(.done)
        Task { @MainActor in await TaskConfirmation.onboardingFinished.announceAfterSheetCloses() }
        onComplete()
    }
}

/// Root view of first-run onboarding: renders whichever screen matches the model's current step.
///
/// Presented by `FernletApp` when `OnboardingDefaults.hasCompletedOnboardingKey` is unset. Owns the
/// ``OnboardingCoordinatorModel`` as `@State` and threads its bindings and callbacks into each step
/// view; the injected ``ExistingCloudDataDetecting`` goes to the storage step. Step changes animate
/// with a shared spring so every transition feels the same.
struct OnboardingCoordinator: View {
    @State private var model: OnboardingCoordinatorModel
    private let detector: any ExistingCloudDataDetecting

    init(
        store: FernletStore,
        detector: any ExistingCloudDataDetecting,
        onComplete: @escaping () -> Void
    ) {
        _model = State(initialValue: OnboardingCoordinatorModel(store: store, onComplete: onComplete))
        self.detector = detector
    }

    var body: some View {
        ZStack {
            // The dotted page of the one design language (designs `b2-onb-1` … `b2-onb-8`).
            FernletDottedPage().ignoresSafeArea()
            currentScreen
        }
        .environment(\.onboardingStepPosition,
                     OnboardingStepPosition(index: model.step.rawValue, count: OnboardingCoordinatorModel.Step.allCases.count))
        // Onboarding comes before ContentView, which sets the look for everything else.
        .worldDesignLanguage()
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: model.step)
        // The personal-details step's second page swaps in with the same spring as a step change.
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: model.isShowingIntimacyChoice)
        // Copy that describes the user follows the Sex picker as it changes, before the profile is
        // saved (AddressedCopy); masculine until it is answered, like the profile's own default.
        .environment(\.fernletTermOfAddress, model.profile.sex.termOfAddress)
        // One keyboard "Done" for every step's fields (the age is a number pad with no return key).
        // The coordinator is the window's root view, with no stack and no sheet chrome around it, and
        // the steps it swaps in all share its host, so they must not declare a second one.
        .keyboardDoneToolbar()
    }

    @ViewBuilder
    private var currentScreen: some View {
        switch model.step {
        case .welcome:
            OnboardingWelcomeView(stepText: model.step.indexText, continueAction: model.advance)
                // R8: the App Review demo build's one extra button, under Continue (`ReviewDemo`).
                #if FERNLET_DEMO
                .safeAreaInset(edge: .bottom, spacing: 0) { ReviewDemoStartLink(start: model.startReviewDemo) }
                #endif
        case .lockSetup:
            OnboardingLockSetupView(
                stepText: model.step.indexText,
                backAction: model.backActionIfAvailable,
                setPasscodeAction: { model.markLockSetupChosen(via: "passcode") },
                laterAction: model.deferLockSetup,
                skipAction: model.deferLockSetup
            )
        case .storageChoice:
            OnboardingStorageChoiceView(
                stepText: model.step.indexText,
                detector: detector,
                backAction: model.backActionIfAvailable,
                continueAction: model.advance
            )
        case .goal:
            OnboardingGoalScreen(
                stepText: model.step.indexText,
                goal: $model.goal,
                level: $model.goalPlanningLevel,
                interests: $model.goalPlanningInterests,
                constraints: $model.goalPlanningConstraints,
                backAction: model.backActionIfAvailable,
                continueAction: model.advance
            )
        case .starterCustomization:
            OnboardingStarterScreen(
                stepText: model.step.indexText,
                starterName: $model.starterName,
                starterColor: $model.starterColor,
                backAction: model.backActionIfAvailable,
                continueAction: model.advance
            )
        case .personalDetails:
            personalDetailsStep
        case .dietaryPattern:
            OnboardingDietaryPatternScreen(
                stepText: model.step.indexText,
                preferences: $model.nutritionPreferences,
                backAction: model.backActionIfAvailable,
                continueAction: model.advance
            )
        case .permissions:
            OnboardingPermissionsView(
                stepText: model.step.indexText,
                backAction: model.backActionIfAvailable,
                finishAction: model.complete
            )
        }
    }

    /// The personal-details step: its form, then — for a user the 16+ gate admits — its second page,
    /// the intimacy choice.
    ///
    /// Continue on the form exits through ``OnboardingCoordinatorModel/ageCheckFinished()`` rather
    /// than `advance`, because the age answer decides whether the choice page comes first. The page
    /// belongs to THIS step (same "N of 8" caption) rather than being a ninth one, so the count
    /// never depends on an age answer and nobody the gate refuses meets a step that isn't there for
    /// them. Its Back returns to the form, not to the previous step.
    @ViewBuilder
    private var personalDetailsStep: some View {
        if model.isShowingIntimacyChoice {
            OnboardingIntimacyChoiceScreen(
                stepText: model.step.indexText,
                keepsIntimacyTracking: model.keepsIntimacyTracking,
                backAction: model.leaveIntimacyChoice,
                continueAction: model.confirmIntimacyTrackingChoice(keep:)
            )
        } else {
            OnboardingPersonalDetailsScreen(
                stepText: model.step.indexText,
                profile: $model.profile,
                displayName: $model.proximityDisplayName,
                ageAssurance: model.ageAssurance,
                backAction: model.backActionIfAvailable,
                continueAction: model.ageCheckFinished
            )
        }
    }
}

/// Shared chrome for every onboarding screen: the "N of M" caption (with the Back affordance), a
/// `ScreenHeader`, and the step's own content in a scrolling column capped at 620pt.
///
/// Every step view wraps its body in this so spacing, padding, and the step caption's
/// accessibility identifier stay identical across the flow; the save/continue bar sits outside it.
struct OnboardingScreenContainer<Content: View>: View {
    var stepText: String
    /// The header's title. Callers pass an authored literal through the `LocalizedStringKey`
    /// initializer, which is what lets it extract into the string catalog (a `String` here would
    /// silently opt the whole onboarding flow out of localization); Welcome passes a `Text` it
    /// resolved for the user, since "Welcome" agrees with them in Spanish (*Bienvenida*).
    var title: Text
    /// Authored copy, so `LocalizedStringKey` rather than `String`, for the same reason.
    var subtitle: LocalizedStringKey
    /// The step's way back. Every step past Welcome passes ``OnboardingCoordinatorModel/back()``;
    /// `nil` (the first step) draws no button, since there is nowhere to go. Without this the flow
    /// was strictly forward, so a mis-tapped "Skip for now" or storage card could not be undone.
    var backAction: (() -> Void)? = nil
    @ViewBuilder var content: Content
    /// VoiceOver's cursor, moved to the header when a step appears. The coordinator swaps steps in
    /// place — no push, no sheet — so nothing told VoiceOver the screen had changed: the cursor
    /// stayed wherever the old step's Continue had been and could land on the next step's Continue,
    /// skipping a whole screen unheard. Every step builds a fresh container, so `onAppear` fires
    /// once per step and the new title is the first thing spoken.
    @AccessibilityFocusState private var isHeaderFocused: Bool

    /// The localizing initializer, for an authored title: every step but Welcome.
    init(
        stepText: String, title: LocalizedStringKey, subtitle: LocalizedStringKey,
        backAction: (() -> Void)? = nil, @ViewBuilder content: () -> Content
    ) {
        self.init(stepText: stepText, title: Text(title), subtitle: subtitle, backAction: backAction, content: content)
    }

    /// The `Text`-taking initializer, for a title the caller resolved (Welcome's, agreed with the
    /// profile being edited through `AddressedCopy`). `Text` is not expressible by a literal, so this
    /// can never take a call site that meant to localize.
    init(
        stepText: String, title: Text, subtitle: LocalizedStringKey,
        backAction: (() -> Void)? = nil, @ViewBuilder content: () -> Content
    ) {
        self.stepText = stepText
        self.title = title
        self.subtitle = subtitle
        self.backAction = backAction
        self.content = content()
    }

    /// Where this step sits in the flow, for the framed segments (the coordinator sets it).
    @Environment(\.onboardingStepPosition) private var position

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        stepRow
                        if let position { OnboardingStepProgress(position: position) }
                    }
                    ScreenHeader(title: title, subtitle: Text(subtitle))
                        .accessibilityFocused($isHeaderFocused)
                    content
                }
                .padding(20)
                .padding(.bottom, 16)
                .frame(maxWidth: 620, alignment: .leading)
            }
        }
        .onAppear { isHeaderFocused = true }
    }

    /// Back at the start (design `b2-onb-2`), and the step's “2 of 8” at the end in moss.
    private var stepRow: some View {
        HStack(spacing: 12) {
            if let backAction {
                OnboardingBackButton(action: backAction)
            }
            Spacer(minLength: 0)
            Text(stepText)
                .font(FernletFramedFont.buttonSmall)
                .foregroundStyle(WorldPalette.mossInk)
                .accessibilityIdentifier("onboarding.step")
        }
        .frame(minHeight: 44)
    }
}

/// Onboarding step for picking a goal preset and sketching how training should fit the user's life.
///
/// Reuses ``GoalPresetCards`` from Settings so the goal choice shows the same paired nutrition and
/// training summaries in both places. All four bindings point into the coordinator model's draft
/// state; nothing is saved until the flow's `complete()`.
private struct OnboardingGoalScreen: View {
    var stepText: String
    @Binding var goal: GoalType
    @Binding var level: String
    @Binding var interests: String
    @Binding var constraints: String
    var backAction: (() -> Void)?
    var continueAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            OnboardingScreenContainer(
                stepText: stepText,
                title: "Plan your goals",
                subtitle: "Choose a focus and outline how movement should fit your life.",
                backAction: backAction
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    // Reuse the Settings preset cards so the moment the goal is actually chosen shows the
                    // same paired nutrition + training summaries, not just displayName + tagline. The
                    // binding is onboarding's `@State`; it persists on `complete()`, so no per-tap save.
                    GoalPresetCards(selectedGoal: $goal)

                    SheetField("Current level") {
                        FlowLayout(spacing: 8) {
                            // `level` holds the frozen token (`WorkoutPlanner.defaultGoals` and
                            // `WorkoutProfile.fromOnboarding` parse it); the chip draws
                            // `ExperienceLevel.displayName`. It drew `option.capitalized` — the
                            // English token itself, case-folded in code.
                            ForEach(ExperienceLevel.allCases) { option in
                                Button(option.displayName) { FernletFeedback.system.select(option.rawValue, in: &level) }
                                    .buttonStyle(ChipButtonStyle(selected: level == option.rawValue))
                            }
                        }
                    }

                    // Each field is named by its caption: the caption is a separate element, so
                    // VoiceOver otherwise named the field by its example placeholder.
                    SheetField("Interests") {
                        TextField("strength, running, mobility", text: $interests,
                                  prompt: .fieldPrompt("strength, running, mobility"))
                            .sheetTextInput()
                            .accessibilityLabel("Interests")
                    }

                    SheetField("Constraints") {
                        TextField("shoulder issues, hotel gyms only", text: $constraints,
                                  prompt: .fieldPrompt("shoulder issues, hotel gyms only"))
                            .sheetTextInput()
                            .accessibilityLabel("Constraints")
                    }
                }
            }
            SheetSaveBar(label: "Continue") { continueAction() }
        }
        .accessibilityIdentifier("onboarding.goal")
    }
}

/// Onboarding step for naming the companion and choosing its starter body color, with a live preview.
///
/// The color is a typed `CompanionAssetColor` end to end — picker, preview, and the eventual write
/// in the model's `complete()` all read the same binding, which is what keeps the previewed color
/// and the persisted one from drifting (see the property comments below for the history).
private struct OnboardingStarterScreen: View {
    var stepText: String
    @Binding var starterName: String
    @Binding var starterColor: CompanionAssetColor
    var backAction: (() -> Void)?
    var continueAction: () -> Void

    /// A curated starter subset of `CompanionAssetColor` — the wardrobe offers the full set later.
    /// Typed rather than stringly-typed so the picker, the preview, and the write on `complete()` are
    /// driven by one value: the previous `String` needed a lookup table at each use site, and the two
    /// tables drifted (see `complete()`).
    private let colors: [CompanionAssetColor] = [.fern, .moss, .rose, .sun]

    /// The appearance the preview draws. Derived from the live binding, so picking a colour updates the
    /// companion on screen — previously the preview took the default `.standard` and could not react to
    /// the picker at all, which is why changing colour appeared to do nothing.
    private var previewAppearance: CompanionAppearance {
        var appearance = CompanionAppearance.standard
        appearance.bodyColor = starterColor
        return appearance
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingScreenContainer(
                stepText: stepText,
                title: "Make Fernlet yours",
                subtitle: "Pick a starter name and color. You can change these later.",
                backAction: backAction
            ) {
                // Decorative: a live preview of the colour being picked below, at a fixed
                // `.thriving`, close up and as it will stand on the map (design `b2-onb-5`).
                VStack(spacing: 8) {
                    OnboardingPixelCompanion(appearance: previewAppearance, scale: 8, showsMap: true)
                    Text("Close up, and on the map")
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(WorldPalette.dim)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)

                SheetField("Name") {
                    TextField("Fernlet", text: $starterName, prompt: .fieldPrompt("Fernlet"))
                        .textInputAutocapitalization(.words)
                        .sheetTextInput()
                        // Read "Fernlet, text field" — the default name, with nothing saying it is one.
                        .accessibilityLabel("Name")
                        .accessibilityIdentifier("onboarding.starter.name")
                }

                SheetField("Color") {
                    // `label` is the model's own name, so onboarding and the wardrobe agree.
                    FernletSegmentedPicker("Color", selection: $starterColor, options: colors) { color in
                        Text(color.label)
                    }
                    .accessibilityIdentifier("onboarding.starter.color")
                }
            }
            SheetSaveBar(label: "Continue") { continueAction() }
        }
        .accessibilityIdentifier("onboarding.starter")
    }
}

/// Onboarding step for the body profile (age, weight, height, sex, activity), the proximity
/// display name, and the one unprompted age-range request Fernlet ever makes.
///
/// The typed age (field + ±1 stepper) feeds nutrition targets only; the age-gated features
/// (intimacy 16+, mesh chat 13+) read Apple's DeclaredAgeRange answer instead, requested through
/// ``AgeAssuranceStore`` when Continue is tapped. A declined or unavailable answer never blocks
/// onboarding. `continueAction` runs once the answer is recorded; the coordinator wires it to
/// ``OnboardingCoordinatorModel/ageCheckFinished()``, which shows users the 16+ gate admits the
/// step's second page, ``OnboardingIntimacyChoiceScreen``.
private struct OnboardingPersonalDetailsScreen: View {
    var stepText: String
    @Binding var profile: UserNutritionProfile
    @Binding var displayName: String
    var ageAssurance: AgeAssuranceStore
    var backAction: (() -> Void)?
    var continueAction: () -> Void

    /// Flipped by Continue to run the system age-range request; the modifier flips it back and advances.
    @State private var isRequestingAgeRange = false

    /// Age as text so it can be TYPED. The stepper alone meant a 48-year-old tapped + eighteen times
    /// from the default 30; the field takes the number directly and the stepper stays for ±1 nudges.
    /// Digits only, and deliberately NOT clamped up to 13 while typing — a half-typed "4" would jump
    /// to 13 mid-entry. Continue stays disabled below 13, which is the real gate.
    private var ageText: Binding<String> {
        Binding(
            get: { profile.age > 0 ? "\(profile.age)" : "" },
            set: { typed in
                let digits = typed.filter(\.isNumber).prefix(3)
                profile.age = min(Int(digits) ?? 0, 100)
            }
        )
    }

    /// The ±1 stepper's value. Reads through a floor of 13 so a half-typed age (or an empty field)
    /// can't hand `Stepper(value:in:)` a value outside its own range and leave the buttons stuck.
    private var steppedAge: Binding<Int> {
        Binding(
            get: { max(profile.age, 13) },
            set: { profile.age = $0 }
        )
    }

    /// Age, weight, height, and the two labelled pickers that feed nutrition targets.
    private var bodyProfileField: some View {
        FernletFramedSection("Body profile") {
            ageRow
            measureRow("Weight", value: BodyMeasurementEntry.weightBinding($profile.weightPounds),
                       range: BodyMeasurementEntry.weightRange(), text: { OnboardingMeasureText.weight($0, imperial: $1) })
            measureRow("Height", value: BodyMeasurementEntry.heightBinding($profile.heightInches),
                       range: BodyMeasurementEntry.heightRange(), text: { OnboardingMeasureText.height($0, imperial: $1) })
            // The same words Settings uses for these two fields (``BodyProfileFieldLabel``).
            FernletDropdown(BodyProfileFieldLabel.sex, selection: $profile.sex, options: BiologicalSex.allCases) { sex in
                Text(sex.label)
            }
            FernletDropdown(BodyProfileFieldLabel.activity, selection: $profile.activityLevel, options: ActivityLevel.allCases) { level in
                Text(level.label)
            }
        }
    }

    /// A measurement row (design `b2-onb-6`): "Weight: **170 lb**", then the framed −/+ at the end.
    /// Voice Control answers to the field's word ("Weight"), not its value.
    private func measureRow(_ label: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>,
                            text: @escaping (Double, Bool) -> String) -> some View {
        let shown = text(value.wrappedValue, BodyMeasurementEntry.usesImperial)
        return HStack(spacing: 12) {
            HStack(spacing: 0) {
                Text(label)
                Text(verbatim: ": ")
                Text(verbatim: shown).fontWeight(.bold)
            }
            .font(FernletFramedFont.rowTitle)
            .foregroundStyle(WorldPalette.bark)
            .accessibilityHidden(true)
            Spacer(minLength: 8)
            FernletStepper(label, value: value, in: range, step: 1, display: nil)
                .accessibilityValue(Text(verbatim: shown))
                .accessibilityInputLabels([Text(label)])
        }
    }

    /// Age: typed, with a framed −/+ beside it for one-year nudges.
    private var ageRow: some View {
        HStack(spacing: 12) {
            Text("Age")
                .font(FernletFramedFont.rowTitle)
                .foregroundStyle(WorldPalette.bark)
            TextField("30", text: ageText, prompt: .fieldPrompt("30"))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .sheetTextInput(font: .fernlet(.label))
                .frame(maxWidth: 90)
                .accessibilityLabel("Age")
                .accessibilityIdentifier("onboarding.profile.age")
            Spacer(minLength: 0)
            FernletStepper("Age", value: steppedAge, in: 13...100, step: 1)
                .fixedSize()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingScreenContainer(
                stepText: stepText,
                title: "Add personal details",
                subtitle: "These are optional except age. Fernlet never asks for weight goals.",
                backAction: backAction
            ) {
                SheetField("Your name") {
                    TextField("How friends will see you", text: $displayName, prompt: .fieldPrompt("How friends will see you"))
                        .textInputAutocapitalization(.words)
                        .sheetTextInput()
                        .accessibilityLabel("Your name")
                        .accessibilityIdentifier("onboarding.displayName")
                }
                bodyProfileField
                // The age above feeds nutrition targets and nothing else. Two features have real age
                // requirements — intimacy tracking (16+) and messaging friends nearby (13+) — and those
                // read Apple's answer, not this field, so say so before the system sheet appears.
                Text("Next, iPhone will ask whether you want to share your age range with Fernlet. It's used only to unlock messaging friends nearby (13+) and intimacy tracking (16+). Fernlet never sees your birthday, and the answer stays on this device.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(WorldPalette.dim)
                    .accessibilityIdentifier("onboarding.profile.ageRangeExplainer")
            }
            SheetSaveBar(
                label: "Continue",
                disabled: profile.age < 13 || isRequestingAgeRange
            ) { isRequestingAgeRange = true }
        }
        .accessibilityIdentifier("onboarding.personal")
        // Ask on Continue rather than on appear, so the system sheet lands after the explainer has been
        // on screen rather than ambushing the step. `onFinish` advances whatever the answer was — a
        // declined or unavailable range is recorded as undetermined and never blocks onboarding.
        .requestsAgeRange(when: $isRequestingAgeRange, into: ageAssurance, onFinish: continueAction)
    }

}

/// Onboarding step for choosing an eating pattern (balanced, higher-protein, plant-forward,
/// lower-carb) via a column of ``OnboardingChoiceRow``s.
///
/// Writes only `preferences.dietaryPattern` on the coordinator model's draft; the subtitle copy is
/// deliberately gentle — the pattern tunes suggestions without imposing rules.
private struct OnboardingDietaryPatternScreen: View {
    var stepText: String
    @Binding var preferences: UserNutritionPreferences
    var backAction: (() -> Void)?
    var continueAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            OnboardingScreenContainer(
                stepText: stepText,
                title: "Pick an eating pattern",
                subtitle: "This tunes suggestions without locking you into rules.",
                backAction: backAction
            ) {
                VStack(spacing: 10) {
                    ForEach(DietaryPattern.allCases) { pattern in
                        OnboardingChoiceRow(
                            title: pattern.label,
                            subtitle: subtitle(for: pattern),
                            isSelected: preferences.dietaryPattern == pattern
                        ) {
                            FernletFeedback.system.select(pattern, in: &preferences.dietaryPattern)
                        }
                        .accessibilityIdentifier("onboarding.diet.\(pattern.rawValue)")
                    }
                }
            }
            SheetSaveBar(label: "Continue") { continueAction() }
        }
        .accessibilityIdentifier("onboarding.diet")
    }

    private func subtitle(for pattern: DietaryPattern) -> LocalizedStringKey {
        switch pattern {
        case .balanced: "A flexible mix of meals and snacks."
        case .higherProtein: "More protein-forward ideas when useful."
        case .plantForward: "More plants, legumes, grains, and produce."
        case .lowerCarb: "Lower-carb options without strict tracking."
        }
    }
}

/// A tappable single-select card row — icon, title, subtitle — with the house selected/unselected
/// styling (moss tint and stroke when chosen).
///
/// Used by ``OnboardingDietaryPatternScreen`` for its pattern choices; purely presentational, with
/// selection state and the tap action owned by the caller.
private struct OnboardingChoiceRow: View {
    var title: String
    var subtitle: LocalizedStringKey
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            OnboardingRadioCard(title: Text(verbatim: title), detail: Text(subtitle), isSelected: isSelected)
        }
        .buttonStyle(.plain)
        // Selection is drawn by the tick and the ring; the trait is the spoken one.
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // Voice Control: the title alone is what a user reads off the card and says.
        .accessibilityInputLabels([Text(verbatim: title)])
    }
}

/// The value half of onboarding's weight and height steppers ("170 lb", "5 ft 8 in"), in the units
/// ``BodyMeasurementEntry`` steps in; the field's word ("Weight") is the stepper's own label.
nonisolated enum OnboardingMeasureText {
    static func weight(_ displayValue: Double, imperial: Bool) -> String {
        "\(Int(displayValue.rounded())) \(imperial ? "lb" : "kg")"
    }

    static func height(_ displayValue: Double, imperial: Bool) -> String {
        let whole = Int(displayValue.rounded())
        return imperial ? "\(whole / 12) ft \(whole % 12) in" : "\(whole) cm"
    }
}

// R8: the one custom condition — the App Review demo build only (`ReviewDemo`).
#if FERNLET_DEMO
extension OnboardingCoordinatorModel {
    /// Welcome's "Look around with sample data": commits the demo persona the way ``complete()``
    /// commits a real answer set, plants the sample data under the demo passcode, and hands over to
    /// the app. Nothing here exists in a normal build.
    ///
    /// - Returns: false when the demo passcode could not be set up; nothing is committed then, and the
    ///   person stays on Welcome.
    func startReviewDemo(lockService: FernletLockService) async -> Bool {
        guard let key = await ReviewDemo.configureLock(lockService) else { return false }
        profile = ReviewDemo.persona(from: profile)
        store.completeOnboarding(profile: profile, preferences: nutritionPreferences, goal: goal)
        store.replaceGoals(WorkoutPlanner.defaultGoals(
            level: goalPlanningLevel,
            interests: goalPlanningInterests,
            constraints: goalPlanningConstraints
        ))
        store.setWorkoutProfile(WorkoutProfile.fromOnboarding(
            level: goalPlanningLevel,
            interests: goalPlanningInterests,
            constraints: goalPlanningConstraints
        ))
        store.setProximityDisplayName(ReviewDemo.personaName)
        store.setCompanionName(starterName)
        await ReviewDemo.seed(store: store, lockService: lockService, key: key)
        defaults.set(true, forKey: OnboardingDefaults.hasCompletedOnboardingKey)
        FernletFeedback.system.play(.done)
        onComplete()
        return true
    }
}
#endif
