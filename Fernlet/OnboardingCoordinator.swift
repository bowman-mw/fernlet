import Observation
import SwiftUI
import FernletDomainModel
import FernletScoring

protocol ExistingCloudDataDetecting {
    func detectExistingData() async throws -> ExistingDataSummary?
}

extension CloudKitDataService: ExistingCloudDataDetecting {}

struct MockExistingCloudDataDetector: ExistingCloudDataDetecting {
    var summary: ExistingDataSummary?

    func detectExistingData() async throws -> ExistingDataSummary? {
        summary
    }
}

enum OnboardingDefaults {
    static let hasCompletedOnboardingKey = "hasCompletedOnboarding"
    static let lockSetupDeferredKey = "lockSetupDeferred"
}

@MainActor
struct OnboardingCloudDataDetectorFactory {
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

@MainActor
@Observable
final class OnboardingCoordinatorModel {
    enum Step: Int, CaseIterable {
        case welcome
        case lockSetup
        case storageChoice
        case goal
        case starterCustomization
        case personalDetails
        case dietaryPattern
        case permissions

        var indexText: String { "\(rawValue + 1) of \(Self.allCases.count)" }
    }

    private(set) var step: Step = .welcome
    var goal: GoalType
    var profile: UserNutritionProfile
    var nutritionPreferences: UserNutritionPreferences
    var goalPlanningLevel = "beginner"
    var goalPlanningInterests = ""
    var goalPlanningConstraints = ""
    var starterName = "Fernlet"
    var starterColor = "Fern"
    var proximityDisplayName = ""

    @ObservationIgnored private let store: FernletStore
    @ObservationIgnored private let onComplete: () -> Void

    init(store: FernletStore, onComplete: @escaping () -> Void) {
        self.store = store
        self.onComplete = onComplete
        self.goal = store.settings.selectedGoal
        self.profile = store.settings.userProfile
        self.nutritionPreferences = store.settings.nutritionPreferences
    }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            complete()
            return
        }
        step = next
    }

    func deferLockSetup() {
        UserDefaults.standard.set(true, forKey: OnboardingDefaults.lockSetupDeferredKey)
        FernletAuditLog.log("onboarding.lock.skipped")
        advance()
    }

    func markLockSetupChosen(via method: String) {
        UserDefaults.standard.set(false, forKey: OnboardingDefaults.lockSetupDeferredKey)
        FernletAuditLog.log("onboarding.lock.chosen", context: ["method": method])
        advance()
    }

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
        let paletteByColor: [String: CompanionPalette] = [
            "Fern": .fern, "Moss": .fern, "Rose": .rose, "Gold": .sun
        ]
        if let palette = paletteByColor[starterColor] {
            var appearance = store.settings.companionAppearance
            appearance.palette = palette
            store.setCompanionAppearance(appearance)
        }
        UserDefaults.standard.set(true, forKey: OnboardingDefaults.hasCompletedOnboardingKey)
        onComplete()
    }
}

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
                        .font(.caption.weight(.semibold))
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

struct OnboardingGoalScreen: View {
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
                    VStack(spacing: 10) {
                        ForEach(GoalType.allCases) { option in
                            OnboardingChoiceRow(
                                title: option.displayName,
                                subtitle: option.tagline,
                                systemImage: goal == option ? "checkmark.circle.fill" : "circle",
                                isSelected: goal == option
                            ) {
                                goal = option
                            }
                            .accessibilityIdentifier("onboarding.goal.\(option.rawValue)")
                        }
                    }

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

struct OnboardingStarterScreen: View {
    var stepText: String
    @Binding var starterName: String
    @Binding var starterColor: String
    var continueAction: () -> Void

    private let colors = ["Fern", "Moss", "Rose", "Gold"]

    var body: some View {
        VStack(spacing: 0) {
            OnboardingScreenContainer(
                stepText: stepText,
                title: "Make Fernlet yours",
                subtitle: "Pick a starter name and color. You can change these later."
            ) {
                CompanionView(state: .thriving, size: 120)
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
                        ForEach(colors, id: \.self) { color in
                            Text(color).tag(color)
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

struct OnboardingPersonalDetailsScreen: View {
    var stepText: String
    @Binding var profile: UserNutritionProfile
    @Binding var displayName: String
    var continueAction: () -> Void

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
            }
            SheetSaveBar(label: "Continue", disabled: profile.age < 13) { continueAction() }
        }
        .accessibilityIdentifier("onboarding.personal")
    }

    private var heightText: String {
        let total = Int(profile.heightInches.rounded())
        return "\(total / 12) ft \(total % 12) in"
    }
}

struct OnboardingDietaryPatternScreen: View {
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

struct OnboardingChoiceRow: View {
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
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.bark)
                    Text(subtitle)
                        .font(.caption)
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
