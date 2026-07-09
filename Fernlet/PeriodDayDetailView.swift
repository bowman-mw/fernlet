import HealthKit
import SwiftUI
import FernletDomainModel
import PrivateHealthStore

struct PeriodDayDetailView: View {
    var entry: CycleDayEntry
    var onEdit: () -> Void = { }
    var onDelete: () -> Void = { }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(title: entry.date.formatted(.dateTime.month(.wide).day()), subtitle: entry.phase.title)

                FernletCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Health samples")
                            .font(.fernlet(.header))
                            .foregroundStyle(Color.bark)
                        if entry.samples.isEmpty {
                            EmptyState(text: "No cycle samples for this day.")
                        } else {
                            ForEach(Array(entry.samples.enumerated()), id: \.offset) { _, sample in
                                Text(label(for: sample))
                                    .font(.fernlet(.body))
                                    .foregroundStyle(Color.bark)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }

                FernletCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Narrative")
                            .font(.fernlet(.header))
                            .foregroundStyle(Color.bark)
                        if let narrative = entry.narrative {
                            if let note = narrative.note, !note.isEmpty {
                                Text(note)
                                    .font(.fernlet(.body))
                                    .foregroundStyle(Color.bark)
                                    .fernletWrappingText()
                            }
                            if !narrative.symptomFlags.isEmpty {
                                FlowLayout(spacing: 6) {
                                    ForEach(narrative.symptomFlags.sorted()) { symptom in
                                        Text(symptomLabel(symptom, in: narrative))
                                            .font(.fernlet(.labelSmall))
                                            .foregroundStyle(Color.slate)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 5)
                                            .background(Color.bark.opacity(0.05), in: Capsule())
                                    }
                                }
                            }
                        } else {
                            EmptyState(text: "No saved note for this day.")
                        }
                    }
                }

                HStack {
                    Button("Edit", action: onEdit)
                        .foregroundStyle(Color.moss)
                    Spacer()
                    Button("Delete", role: .destructive, action: onDelete)
                        .foregroundStyle(Color.terracotta)
                }
                .font(.fernlet(.label))
                .padding(.horizontal, 4)
            }
            .padding(20)
        }
        .background(Color.parchment)
        .navigationTitle("")
    }

    private func symptomLabel(_ symptom: PeriodSymptom, in narrative: MenstrualNarrative) -> String {
        guard let rating = narrative.customSymptomScales[symptom.rawValue] else { return symptom.title }
        return "\(symptom.title) · \(rating)"
    }

    private func label(for sample: HKSample) -> String {
        if let category = sample as? HKCategorySample {
            switch category.categoryType.identifier {
            case HKCategoryTypeIdentifier.menstrualFlow.rawValue:
                return "Flow: \(entry.flowLabel)"
            case HKCategoryTypeIdentifier.cervicalMucusQuality.rawValue:
                return "Cervical mucus: \(mucusLabel(category.value))"
            case HKCategoryTypeIdentifier.ovulationTestResult.rawValue:
                return "Ovulation test: \(ovulationLabel(category.value))"
            case HKCategoryTypeIdentifier.intermenstrualBleeding.rawValue:
                return "Intermenstrual bleeding"
            default:
                return category.categoryType.identifier
            }
        }
        if let quantity = sample as? HKQuantitySample,
           quantity.quantityType.identifier == HKQuantityTypeIdentifier.basalBodyTemperature.rawValue {
            return "Basal body temperature: \(quantity.quantity.doubleValue(for: .degreeFahrenheit()).formatted(.number.precision(.fractionLength(1)))) F"
        }
        return sample.sampleType.identifier
    }

    private func mucusLabel(_ value: Int) -> String {
        switch HKCategoryValueCervicalMucusQuality(rawValue: value) {
        case .dry: "Dry"
        case .sticky: "Sticky"
        case .creamy: "Creamy"
        case .watery: "Watery"
        case .eggWhite: "Egg White"
        default: "Unknown"
        }
    }

    private func ovulationLabel(_ value: Int) -> String {
        switch HKCategoryValueOvulationTestResult(rawValue: value) {
        case .negative: "Negative"
        case .luteinizingHormoneSurge: "Positive"
        case .indeterminate: "Indeterminate"
        default: "Unknown"
        }
    }
}
