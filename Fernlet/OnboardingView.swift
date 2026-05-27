import SwiftUI

struct OnboardingView: View {
    var store: FernletStore
    @AppStorage("fernletDarkModeEnabled") private var isDarkModeEnabled = false
    @State private var goal: GoalType
    @State private var profile: UserNutritionProfile
    @State private var preferences: UserNutritionPreferences

    init(store: FernletStore) {
        self.store = store
        _goal = State(initialValue: store.settings.selectedGoal)
        _profile = State(initialValue: store.settings.userProfile)
        _preferences = State(initialValue: store.settings.nutritionPreferences)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ScreenHeader(title: "Set up Fernlet", subtitle: "A few details make food guidance more useful.")

                    SheetField("Goal") {
                        Picker("Goal", selection: $goal) {
                            ForEach(GoalType.allCases) { goal in
                                Text(goal.displayName).tag(goal)
                            }
                        }
                        .pickerStyle(.menu)
                        .profileFieldStyle()

                        Text(goal.tagline)
                            .font(.caption.italic())
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }

                    ProfileEditor(profile: $profile, preferences: $preferences)

                    NutritionPreviewCard(goal: goal, profile: profile, preferences: preferences)
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: "Start", disabled: !canSave) {
                store.completeOnboarding(profile: profile, preferences: preferences, goal: goal)
            }
        }
        .background(Color.parchment)
        .preferredColorScheme(isDarkModeEnabled ? .dark : .light)
    }

    private var canSave: Bool {
        profile.age >= 13 && profile.weightPounds >= 70 && profile.heightInches >= 48
    }
}

struct ProfileEditor: View {
    @Binding var profile: UserNutritionProfile
    @Binding var preferences: UserNutritionPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetField("Body profile") {
                VStack(alignment: .leading, spacing: 12) {
                    Stepper("Age: \(profile.age)", value: $profile.age, in: 13...100)
                    Stepper("Weight: \(Int(profile.weightPounds.rounded())) lb", value: $profile.weightPounds, in: 70...500, step: 1)
                    Stepper("Height: \(heightText)", value: $profile.heightInches, in: 48...84, step: 1)
                    labeledPicker("Gender") {
                        Picker("Gender", selection: $profile.sex) {
                            ForEach(BiologicalSex.allCases) { sex in
                                Text(sex.label).tag(sex)
                            }
                        }
                    }
                    labeledPicker("Estimated lifestyle activity") {
                        Picker("Estimated lifestyle activity", selection: $profile.activityLevel) {
                            ForEach(ActivityLevel.allCases) { level in
                                Text(level.label).tag(level)
                            }
                        }
                    }
                }
                .profileFieldStyle()
            }

            SheetField("Preferences") {
                VStack(alignment: .leading, spacing: 12) {
                    labeledPicker("Eating pattern") {
                        Picker("Eating pattern", selection: $preferences.dietaryPattern) {
                            ForEach(DietaryPattern.allCases) { pattern in
                                Text(pattern.label).tag(pattern)
                            }
                        }
                    }
                    labeledPicker("Guidance style") {
                        Picker("Guidance style", selection: $preferences.guidanceIntensity) {
                            ForEach(GuidanceIntensity.allCases) { intensity in
                                Text(intensity.label).tag(intensity)
                            }
                        }
                    }
                }
                .profileFieldStyle()
            }
        }
    }

    private var heightText: String {
        let total = Int(profile.heightInches.rounded())
        return "\(total / 12) ft \(total % 12) in"
    }

    private func labeledPicker<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.slate)
            content()
                .pickerStyle(.menu)
        }
    }
}

struct NutritionPreviewCard: View {
    var goal: GoalType
    var profile: UserNutritionProfile
    var preferences: UserNutritionPreferences

    var body: some View {
        let settings = previewSettings
        let targets = NutritionTargetCalculator.targets(for: settings)
        FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Estimated daily targets")
                HStack(spacing: 10) {
                    NutritionPill(title: "Calories", value: "\(targets.calories)")
                    NutritionPill(title: "Protein", value: "\(targets.protein)g")
                    NutritionPill(title: "Carbs", value: "\(targets.carbs)g")
                    NutritionPill(title: "Fat", value: "\(targets.fat)g")
                }
                Text("These are guidance targets based on your profile and can be changed in Settings.")
                    .font(.caption.italic())
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
    }

    private var previewSettings: FernletSettings {
        var settings = FernletSettings()
        settings.selectedGoal = goal
        settings.userProfile = profile
        settings.nutritionPreferences = preferences
        return settings
    }
}

extension View {
    func profileFieldStyle() -> some View {
        self
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }
}
