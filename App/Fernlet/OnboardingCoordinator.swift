import Observation
import SwiftUI
import CloudKitSync
import FernletDomainModel
import FernletFoundation
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

/// Namespace for the `UserDefaults` keys onboarding writes and the rest of the app reads.
///
/// `FernletApp` keys the onboarding-vs-main-UI decision off `hasCompletedOnboardingKey`;
/// `lockSetupDeferredKey` records that the lock step was skipped so lockable features can prompt
/// for setup at first use instead of assuming a lock exists.
enum OnboardingDefaults {
    static let hasCompletedOnboardingKey = "hasCompletedOnboarding"
    static let lockSetupDeferredKey = "lockSetupDeferred"
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
        var indexText: String { "\(rawValue + 1) of \(Self.allCases.count)" }
    }

    /// The page currently on screen. Only ``advance()`` moves it — the flow is strictly forward.
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

    @ObservationIgnored private let store: FernletStore
    @ObservationIgnored private let onComplete: () -> Void

    /// Exposed so the personal-details step can run the system age-range request. Onboarding is the one
    /// place Fernlet asks unprompted; everywhere else the request is user-initiated from Settings.
    var ageAssurance: AgeAssuranceStore { store.ageAssurance }

    init(store: FernletStore, onComplete: @escaping () -> Void) {
        self.store = store
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

    /// Records that lock setup was skipped (biometrics-only or "skip for now"), audits it, and advances.
    func deferLockSetup() {
        UserDefaults.standard.set(true, forKey: OnboardingDefaults.lockSetupDeferredKey)
        FernletAuditLog.log("onboarding.lock.skipped")
        advance()
    }

    /// Records that a lock was actually configured (clearing any earlier deferral), audits the
    /// method, and advances.
    /// - Parameter method: Audit-log label for how the lock was set up (e.g. "passcode").
    func markLockSetupChosen(via method: String) {
        UserDefaults.standard.set(false, forKey: OnboardingDefaults.lockSetupDeferredKey)
        FernletAuditLog.log("onboarding.lock.chosen", context: ["method": method])
        advance()
    }

    /// Commits every accumulated choice to the store, marks onboarding done, and hands control back
    /// to `FernletApp` via `onComplete`.
    ///
    /// - Important: This is the single persistence point for the flow — profile, preferences, goal,
    ///   default workout goals/profile, proximity display name, companion name, and the starter
    ///   body color all land here, so a flow abandoned before this call leaves the store untouched.
    func complete() {
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
        UserDefaults.standard.set(true, forKey: OnboardingDefaults.hasCompletedOnboardingKey)
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
            Color.parchment.ignoresSafeArea()
            currentScreen
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: model.step)
    }

    @ViewBuilder
    private var currentScreen: some View {
        switch model.step {
        case .welcome:
            OnboardingWelcomeView(stepText: model.step.indexText, continueAction: model.advance)
        case .lockSetup:
            OnboardingLockSetupView(
                stepText: model.step.indexText,
                setPasscodeAction: { model.markLockSetupChosen(via: "passcode") },
                biometricsOnlyAction: model.deferLockSetup,
                skipAction: model.deferLockSetup
            )
        case .storageChoice:
            OnboardingStorageChoiceView(
                stepText: model.step.indexText,
                detector: detector,
                continueAction: model.advance
            )
        case .goal:
            OnboardingGoalScreen(
                stepText: model.step.indexText,
                goal: $model.goal,
                level: $model.goalPlanningLevel,
                interests: $model.goalPlanningInterests,
                constraints: $model.goalPlanningConstraints,
                continueAction: model.advance
            )
        case .starterCustomization:
            OnboardingStarterScreen(
                stepText: model.step.indexText,
                starterName: $model.starterName,
                starterColor: $model.starterColor,
                continueAction: model.advance
            )
        case .personalDetails:
            OnboardingPersonalDetailsScreen(
                stepText: model.step.indexText,
                profile: $model.profile,
                displayName: $model.proximityDisplayName,
                ageAssurance: model.ageAssurance,
                continueAction: model.advance
            )
        case .dietaryPattern:
            OnboardingDietaryPatternScreen(
                stepText: model.step.indexText,
                preferences: $model.nutritionPreferences,
                continueAction: model.advance
            )
        case .permissions:
            OnboardingPermissionsView(stepText: model.step.indexText, finishAction: model.complete)
        }
    }
}

/// Shared chrome for every onboarding screen: the "N of M" caption, a `ScreenHeader`, and the
/// step's own content in a scrolling column capped at 620pt.
///
/// Every step view wraps its body in this so spacing, padding, and the step caption's
/// accessibility identifier stay identical across the flow; the save/continue bar sits outside it.
struct OnboardingScreenContainer<Content: View>: View {
    var stepText: String
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(stepText)
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.moss)
                        .accessibilityIdentifier("onboarding.step")
                    ScreenHeader(title: title, subtitle: subtitle)
                    content
                }
                .padding(20)
                .padding(.bottom, 16)
                .frame(maxWidth: 620, alignment: .leading)
            }
        }
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
    var continueAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            OnboardingScreenContainer(
                stepText: stepText,
                title: "Plan your goals",
                subtitle: "Choose a focus and outline how movement should fit your life."
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    // Reuse the Settings preset cards so the moment the goal is actually chosen shows the
                    // same paired nutrition + training summaries, not just displayName + tagline. The
                    // binding is onboarding's `@State`; it persists on `complete()`, so no per-tap save.
                    GoalPresetCards(selectedGoal: $goal)

                    SheetField("Current level") {
                        FlowLayout(spacing: 8) {
                            ForEach(["beginner", "intermediate", "advanced"], id: \.self) { option in
                                Button(option.capitalized) { level = option }
                                    .buttonStyle(ChipButtonStyle(selected: level == option))
                            }
                        }
                    }

                    SheetField("Interests") {
                        TextField("strength, running, mobility", text: $interests)
                            .sheetTextInput()
                    }

                    SheetField("Constraints") {
                        TextField("shoulder issues, hotel gyms only", text: $constraints)
                            .sheetTextInput()
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
                subtitle: "Pick a starter name and color. You can change these later."
            ) {
                CompanionView(state: .thriving, appearance: previewAppearance, size: 120)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)

                SheetField("Name") {
                    TextField("Fernlet", text: $starterName)
                        .textInputAutocapitalization(.words)
                        .sheetTextInput()
                        .accessibilityIdentifier("onboarding.starter.name")
                }

                SheetField("Color") {
                    Picker("Color", selection: $starterColor) {
                        ForEach(colors) { color in
                            // `label` is the model's own name, so onboarding and the wardrobe agree.
                            // The old hardcoded list said "Gold" for what the model calls "Sun".
                            Text(color.label).tag(color)
                        }
                    }
                    .pickerStyle(.segmented)
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
/// The stepper age feeds nutrition targets only; the age-gated features (intimacy 16+, mesh chat
/// 13+) read Apple's DeclaredAgeRange answer instead, requested through ``AgeAssuranceStore`` when
/// Continue is tapped. A declined or unavailable answer never blocks onboarding.
private struct OnboardingPersonalDetailsScreen: View {
    var stepText: String
    @Binding var profile: UserNutritionProfile
    @Binding var displayName: String
    var ageAssurance: AgeAssuranceStore
    var continueAction: () -> Void

    /// Flipped by Continue to run the system age-range request; the modifier flips it back and advances.
    @State private var isRequestingAgeRange = false

    var body: some View {
        VStack(spacing: 0) {
            OnboardingScreenContainer(
                stepText: stepText,
                title: "Add personal details",
                subtitle: "These are optional except age. Fernlet never asks for weight goals."
            ) {
                SheetField("Your name") {
                    TextField("How friends will see you", text: $displayName)
                        .textInputAutocapitalization(.words)
                        .sheetTextInput()
                        .accessibilityIdentifier("onboarding.displayName")
                }
                SheetField("Body profile") {
                    VStack(alignment: .leading, spacing: 12) {
                        Stepper("Age: \(profile.age)", value: $profile.age, in: 13...100)
                            .accessibilityIdentifier("onboarding.profile.age")
                        Stepper("Weight: \(Int(profile.weightPounds.rounded())) lb", value: $profile.weightPounds, in: 70...500, step: 1)
                        Stepper("Height: \(heightText)", value: $profile.heightInches, in: 48...84, step: 1)
                        Picker("Biological sex", selection: $profile.sex) {
                            ForEach(BiologicalSex.allCases) { sex in
                                Text(sex.label).tag(sex)
                            }
                        }
                        Picker("Activity", selection: $profile.activityLevel) {
                            ForEach(ActivityLevel.allCases) { level in
                                Text(level.label).tag(level)
                            }
                        }
                    }
                    .profileFieldStyle()
                }
                // The age above feeds nutrition targets and nothing else. Two features have real age
                // requirements — intimacy tracking (16+) and messaging friends nearby (13+) — and those
                // read Apple's answer, not this stepper, so say so before the system sheet appears.
                Text("Next, iPhone will ask whether you want to share your age range with Fernlet. It's used only to unlock messaging friends nearby (13+) and intimacy tracking (16+). Fernlet never sees your birthday, and the answer stays on this device.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
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

    private var heightText: String {
        let total = Int(profile.heightInches.rounded())
        return "\(total / 12) ft \(total % 12) in"
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
    var continueAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            OnboardingScreenContainer(
                stepText: stepText,
                title: "Pick an eating pattern",
                subtitle: "This tunes suggestions without locking you into rules."
            ) {
                VStack(spacing: 10) {
                    ForEach(DietaryPattern.allCases) { pattern in
                        OnboardingChoiceRow(
                            title: pattern.label,
                            subtitle: subtitle(for: pattern),
                            systemImage: preferences.dietaryPattern == pattern ? "checkmark.circle.fill" : "circle",
                            isSelected: preferences.dietaryPattern == pattern
                        ) {
                            preferences.dietaryPattern = pattern
                        }
                        .accessibilityIdentifier("onboarding.diet.\(pattern.rawValue)")
                    }
                }
            }
            SheetSaveBar(label: "Continue") { continueAction() }
        }
        .accessibilityIdentifier("onboarding.diet")
    }

    private func subtitle(for pattern: DietaryPattern) -> String {
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
    var subtitle: String
    var systemImage: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.moss : Color.slate.opacity(0.45))
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.fernlet(.headerMedium))
                        .foregroundStyle(Color.bark)
                    Text(subtitle)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
                Spacer(minLength: 8)
            }
            .padding(16)
            .background(isSelected ? Color.moss.opacity(0.07) : Color.cream, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.moss.opacity(0.42) : Color.bark.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
