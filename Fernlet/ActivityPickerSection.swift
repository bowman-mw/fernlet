import SwiftUI
import FernletDomainModel
import HealthKitGateway
import FernletUI

struct ActivityPickerSection: View {
    @Binding var selectedActivityType: WorkoutActivityType?
    @Binding var duration: String
    @Binding var distance: String
    @Binding var energyKcal: String
    @Binding var effort: String
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
                .foregroundStyle(selectedActivityType == type ? Color.cream : Color.bark)
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
                        .sheetTextInput()
                        .accessibilityIdentifier("activity.duration")
                }
                if type.expectsDistance {
                    SheetField("Distance (mi)") {
                        TextField("3.0", text: $distance)
                            .keyboardType(.decimalPad)
                            .sheetTextInput()
                            .accessibilityIdentifier("activity.distance")
                    }
                }
            }

            SheetField("Energy (kcal)") {
                TextField("250", text: $energyKcal)
                    .keyboardType(.numberPad)
                    .sheetTextInput()
                    .accessibilityIdentifier("activity.energy")
            }

            SheetField("Effort") {
                VStack(alignment: .leading, spacing: 8) {
                    Slider(value: effortValue, in: 1...10, step: 1)
                        .accessibilityIdentifier("activity.effort")
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
