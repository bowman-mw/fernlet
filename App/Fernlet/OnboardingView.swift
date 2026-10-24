import SwiftUI
import FernletDomainModel
import FernletUI

/// Reusable editor for the body profile (age, weight, height, sex, activity level) and nutrition
/// preferences (eating pattern, guidance style).
///
/// Despite the file name, this is not an onboarding screen: ``SettingsSheet``'s "Goal & nutrition"
/// tab is its caller, feeding it a Health-synced profile binding so weight/height edits also write
/// back to Apple Health. Both bindings are the caller's; the editor persists nothing itself.
///
/// Under the World's framed look (`b2-settings-goal`) the two groups are framed sections: each
/// measurement a row with the framed −/+ at its end, each choice a framed dropdown. Without the look it
/// is today's cream cards with system steppers and menu pickers.
struct ProfileEditor: View {
    @Binding var profile: UserNutritionProfile
    @Binding var preferences: UserNutritionPreferences
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        if look != nil {
            VStack(alignment: .leading, spacing: 16) {
                framedBodyProfile
                framedPreferences
            }
        } else {
            todaysCards
        }
    }

    /// The body profile as framed rows: Age, Weight and Height with the framed stepper, then Sex and
    /// Typical activity as dropdowns (the words ``BodyProfileFieldLabel`` keeps for both surfaces).
    private var framedBodyProfile: some View {
        FernletFramedSection("Body profile") {
            // Voice Control: each stepper answers to its field's word ("Age"); VoiceOver hears today's
            // "Age: 30", the drawn words being hidden in favour of the stepper.
            measureRow(Text("Age: \(profile.age)")) {
                FernletStepper("Age: \(profile.age)", value: $profile.age, in: 13...100, step: 1)
                    .accessibilityInputLabels([Text("Age")])
            }
            let weight = BodyMeasurementEntry.weightLabel(pounds: profile.weightPounds)
            measureRow(Text(verbatim: weight)) {
                FernletStepper("Weight", value: BodyMeasurementEntry.weightBinding($profile.weightPounds),
                               in: BodyMeasurementEntry.weightRange(), step: 1)
                    .accessibilityLabel(Text(verbatim: weight))
                    .accessibilityInputLabels([Text("Weight")])
            }
            let height = BodyMeasurementEntry.heightLabel(inches: profile.heightInches)
            measureRow(Text(verbatim: height)) {
                FernletStepper("Height", value: BodyMeasurementEntry.heightBinding($profile.heightInches),
                               in: BodyMeasurementEntry.heightRange(), step: 1)
                    .accessibilityLabel(Text(verbatim: height))
                    .accessibilityInputLabels([Text("Height")])
            }
            FernletDropdown(BodyProfileFieldLabel.sex, selection: $profile.sex, options: BiologicalSex.allCases) {
                Text($0.label)
            }
            .padding(.vertical, 6)
            FernletDropdown(BodyProfileFieldLabel.activity, selection: $profile.activityLevel,
                            options: ActivityLevel.allCases) { Text($0.label) }
                .padding(.vertical, 6)
        }
    }

    /// Eating pattern and Guidance style as framed dropdowns (each with the row's padding, so a stacked
    /// dropdown at the largest text sizes never touches the rules).
    private var framedPreferences: some View {
        FernletFramedSection("Preferences") {
            FernletDropdown("Eating pattern", selection: $preferences.dietaryPattern, options: DietaryPattern.allCases) {
                Text($0.label)
            }
            .padding(.vertical, 6)
            FernletDropdown("Guidance style", selection: $preferences.guidanceIntensity,
                            options: GuidanceIntensity.allCases) { Text($0.label) }
                .padding(.vertical, 6)
        }
    }

    /// One measurement row: its words (hidden from VoiceOver: the stepper says them), then the stepper.
    private func measureRow<Control: View>(_ words: Text, @ViewBuilder stepper: () -> Control) -> some View {
        HStack(spacing: 12) {
            words
                .font(FernletFramedFont.rowTitle)
                .foregroundStyle(look?.text ?? Color.bark)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            stepper()
        }
        // A wrapped measurement (largest text sizes) keeps the row's padding above and below it.
        .padding(.vertical, 6)
    }

    /// Today's two cream cards with system steppers and menu pickers (no framed look).
    private var todaysCards: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetField("Body profile") {
                VStack(alignment: .leading, spacing: 12) {
                    // Voice Control: each label carries its value ("Age: 30"), so the name a user
                    // would say moves with every step; the field's own word does not.
                    Stepper("Age: \(profile.age)", value: $profile.age, in: 13...100)
                        .accessibilityInputLabels([Text("Age")])
                    Stepper(BodyMeasurementEntry.weightLabel(pounds: profile.weightPounds),
                            value: BodyMeasurementEntry.weightBinding($profile.weightPounds),
                            in: BodyMeasurementEntry.weightRange(), step: 1)
                        .accessibilityInputLabels([Text("Weight")])
                    Stepper(BodyMeasurementEntry.heightLabel(inches: profile.heightInches),
                            value: BodyMeasurementEntry.heightBinding($profile.heightInches),
                            in: BodyMeasurementEntry.heightRange(), step: 1)
                        .accessibilityInputLabels([Text("Height")])
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

}

/// The two body-profile field names Settings and onboarding must agree on.
///
/// One home for the words so the same field can't be "Gender" in Settings and an unlabelled
/// "Male ◇" menu in onboarding.
///
/// `LocalizedStringKey`, not `String`: as `String`s both reached `Picker` and the caption through
/// their verbatim overloads and were never extracted, so every language read "Sex" and "Typical
/// activity".
enum BodyProfileFieldLabel {
    static let sex: LocalizedStringKey = "Sex"
    static let activity: LocalizedStringKey = "Typical activity"
}

/// A menu picker with a small slate caption above it.
///
/// The house treatment for the body-profile / preference pickers on both Settings
/// (``ProfileEditor``) and the onboarding personal-details step: `.menu` style outside a `Form`
/// hides the picker's own label, so the value ("Moderate") renders with nothing saying what it is.
/// The caption is a `LocalizedStringKey`: every caller passes authored copy, and the `String` this
/// took silently opted all four captions out of localization.
struct LabeledProfilePicker<Content: View>: View {
    private let label: LocalizedStringKey
    private let content: Content

    init(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
            // A menu picker draws its value in the tint, and nothing above this one sets it, so it was
            // system blue (3.29:1 on the cream card). `mossInk` is the moss family's text token.
            content
                .pickerStyle(.menu)
                .tint(Color.mossInk)
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
