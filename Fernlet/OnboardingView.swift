import SwiftUI

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

extension View {
    func profileFieldStyle() -> some View {
        self
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }
}
