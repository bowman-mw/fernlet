import SwiftUI
import FernletDomainModel
import FernletUI

/// Reusable editor for the body profile (age, weight, height, sex, activity level) and nutrition
/// preferences (eating pattern, guidance style).
///
/// Despite the file name, this is not an onboarding screen: ``SettingsSheet``'s "Goal & nutrition"
/// tab is its caller, feeding it a Health-synced profile binding so weight/height edits also write
/// back to Apple Health. Both bindings are the caller's; the editor persists nothing itself.
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
                    // Same two labels the onboarding step uses (LabeledProfilePicker) — the two
                    // surfaces edit one profile and used to name these fields differently
                    // ("Gender" / "Estimated lifestyle activity" here, nothing at all there).
                    LabeledProfilePicker(BodyProfileFieldLabel.sex) {
                        Picker(BodyProfileFieldLabel.sex, selection: $profile.sex) {
                            ForEach(BiologicalSex.allCases) { sex in
                                Text(sex.label).tag(sex)
                            }
                        }
                    }
                    LabeledProfilePicker(BodyProfileFieldLabel.activity) {
                        Picker(BodyProfileFieldLabel.activity, selection: $profile.activityLevel) {
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
                    LabeledProfilePicker("Eating pattern") {
                        Picker("Eating pattern", selection: $preferences.dietaryPattern) {
                            ForEach(DietaryPattern.allCases) { pattern in
                                Text(pattern.label).tag(pattern)
                            }
                        }
                    }
                    LabeledProfilePicker("Guidance style") {
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
}

/// The two body-profile field names Settings and onboarding must agree on.
///
/// One home for the words so the same field can't be "Gender" in Settings and an unlabelled
/// "Male ◇" menu in onboarding.
enum BodyProfileFieldLabel {
    static let sex = "Sex"
    static let activity = "Typical activity"
}

/// A menu picker with a small slate caption above it.
///
/// The house treatment for the body-profile / preference pickers on both Settings
/// (``ProfileEditor``) and the onboarding personal-details step: `.menu` style outside a `Form`
/// hides the picker's own label, so the value ("Moderate") renders with nothing saying what it is.
struct LabeledProfilePicker<Content: View>: View {
    private let label: String
    private let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
            content
                .pickerStyle(.menu)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// The cream-card treatment shared by profile-style field groups (padding, rounded cream
    /// background, hairline bark stroke) — also used by the onboarding personal-details step.
    ///
    /// Claims the full proposed width so every one of these cards is the same size: the Preferences
    /// group holds only two menu pickers, so without it the card hugged its content and rendered at
    /// ~40% width beside the full-width Body profile card above it.
    func profileFieldStyle() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }
}
