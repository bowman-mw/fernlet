import SwiftUI
import FernletDomainModel
import HealthKitGateway
import FernletUI

/// The activity half of the workout sheets' Kind toggle: search and pick a `WorkoutActivityType`,
/// then fill its duration / distance / energy / effort fields.
///
/// Recent picks persist as a comma-joined raw-value list in `@AppStorage` (capped at five, most
/// recent first) and render as one-tap chips. Selecting a type seeds sensible defaults into
/// still-empty duration/effort fields; all value fields are bound to the presenting sheet
/// (``WorkoutSheet`` / ``WorkoutPlanSheet``), which owns the save.
struct ActivityPickerSection: View {
    @Binding var selectedActivityType: WorkoutActivityType?
    @Binding var duration: String
    @Binding var distance: String
    @Binding var energyKcal: String
    @Binding var effort: String
    /// Mirrors `settings.showCalories`, the same opt-in the macros card and nutrition label honor: a
    /// user who turned calories off shouldn't be asked for kcal on every activity log. Energy that
    /// arrives from Health is still stored — it just isn't asked for here.
    var showsEnergyField: Bool = false
    @AppStorage("fernlet.recentActivityTypes") private var recentActivityTypeRawValues = ""
    @State private var query = ""

    private var recentActivityTypes: [WorkoutActivityType] {
        recentActivityTypeRawValues
            .split(separator: ",")
            .compactMap { WorkoutActivityType(rawValue: String($0)) }
    }

    private var results: [WorkoutActivityType] {
        ActivityTypeCatalog.search(query)
    }

    private var effortValue: Binding<Double> {
        Binding(
            get: { Double(Int(effort) ?? 5) },
            set: { effort = String(Int($0.rounded())) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !recentActivityTypes.isEmpty {
                SheetField("Recent") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(recentActivityTypes) { type in
                                activityChip(type)
                            }
                        }
                    }
                }
            }

            SheetField("Workout type") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Color.slate)
                        TextField("Search workout type", text: $query)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled(false)
                            .accessibilityIdentifier("activity.search")
                    }
                    .sheetTextInput()

                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(results) { type in
                                activityRow(type)
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                }
            }

            if let selectedActivityType {
                activityDetailFields(for: selectedActivityType)
            }
        }
    }

    private func activityChip(_ type: WorkoutActivityType) -> some View {
        Button {
            select(type)
        } label: {
            Label(type.displayName, systemImage: type.systemImage)
                .font(.fernlet(.label))
                // Selected = ink for the moss fill; unselected = bark on the cream one.
                .foregroundStyle(selectedActivityType == type ? Color.onMoss : Color.bark)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(selectedActivityType == type ? Color.moss : Color.cream, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("activity.recent.\(type.rawValue)")
    }

    private func activityRow(_ type: WorkoutActivityType) -> some View {
        Button {
            select(type)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: type.systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(selectedActivityType == type ? Color.moss : Color.slate)
                    .frame(width: 26)
                Text(type.displayName)
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
                Spacer()
                if selectedActivityType == type {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.moss)
                }
            }
            .padding(12)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.bark.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("activity.row.\(type.rawValue)")
    }

    private func activityDetailFields(for type: WorkoutActivityType) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                SheetField("Duration (min)") {
                    TextField("\(type.defaultDurationMinutes)", text: $duration)
                        .keyboardType(.numberPad)
                        .sheetTextInput(font: .fernlet(.label))
                        .accessibilityIdentifier("activity.duration")
                }
                if type.expectsDistance {
                    SheetField("Distance (mi)") {
                        TextField("3.0", text: $distance)
                            .keyboardType(.decimalPad)
                            .sheetTextInput(font: .fernlet(.label))
                            .accessibilityIdentifier("activity.distance")
                    }
                }
            }

            if showsEnergyField {
                SheetField("Energy (kcal)") {
                    TextField("250", text: $energyKcal)
                        .keyboardType(.numberPad)
                        .sheetTextInput(font: .fernlet(.label))
                        .accessibilityIdentifier("activity.energy")
                }
            }

            SheetField("Effort") {
                VStack(alignment: .leading, spacing: 8) {
                    // Tinted moss: this sheet is presented from the app's root, outside the
                    // `mainInterface` tint scope, so an untinted Slider rendered iOS blue — the only
                    // blue control in the app. The a11y label/value make it readable to VoiceOver,
                    // which otherwise announced just "adjustable".
                    Slider(value: effortValue, in: 1...10, step: 1)
                        .tint(Color.moss)
                        .accessibilityIdentifier("activity.effort")
                        .accessibilityLabel("Effort")
                        .accessibilityValue("\(Int(effort) ?? 5) of 10")
                    HStack {
                        Text("Easy")
                        Spacer()
                        Text(effort.isEmpty ? "5" : effort)
                            .font(.fernlet(.stat))
                        Spacer()
                        Text("All-out")
                    }
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                }
            }
        }
    }

    private func select(_ type: WorkoutActivityType) {
        selectedActivityType = type
        if duration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            duration = String(type.defaultDurationMinutes)
        }
        if effort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            effort = "5"
        }
        updateRecentActivityTypes(with: type)
    }

    private func updateRecentActivityTypes(with type: WorkoutActivityType) {
        var rawValues = recentActivityTypeRawValues
            .split(separator: ",")
            .map(String.init)
        rawValues.removeAll { $0 == type.rawValue }
        rawValues.insert(type.rawValue, at: 0)
        recentActivityTypeRawValues = rawValues.prefix(5).joined(separator: ",")
    }
}
