import HealthKit
import SwiftUI
import FernletDomainModel
import PrivateHealthStore
import FernletUI

/// Read-only detail screen for one day on the merged Cycle calendar: the period half (raw
/// HealthKit cycle samples — flow, cervical mucus, ovulation test, intermenstrual bleeding, basal
/// body temperature — plus the sealed narrative with Edit/Delete) and the intimacy half (that
/// day's events and sealed notes), each rendered only when its own derived gate allows.
///
/// Pushed from ``CycleTrackerView``'s calendar. The period half displays whatever the
/// `CycleDayEntry` already holds — narrative text is only present when the store loaded it with an
/// unlocked content key — and its Edit and Delete buttons are plain callbacks so the parent owns
/// the actual mutation (Edit re-opens ``LogPeriodSheet`` for the day, Delete routes through
/// `PeriodTrackerStore.deleteEntry`). The intimacy half lists the day's decrypted `IntimacyLog`s,
/// which the parent already read through the gated `IntimacyLogStore` funnel, plus a count row for
/// events that exist only as HealthKit samples. The parent passes `showsIntimacyHalf: false` with
/// empty data while intimacy is hidden, so nothing about the hidden half renders here — and the
/// same for the period half.
struct CycleDayDetailView: View {
    /// The period entry for this day (synthesized empty when nothing was logged).
    var entry: CycleDayEntry
    /// Whether the period half (samples, narrative, Edit/Delete) renders at all.
    var showsPeriodHalf: Bool = true
    /// Whether the intimacy half renders at all.
    var showsIntimacyHalf: Bool = false
    /// The day's decrypted intimacy logs, in event order. Empty while intimacy is hidden.
    var intimacyLogs: [IntimacyLog] = []
    /// The day's merged intimacy event count (sealed logs max-merged with HealthKit) — can exceed
    /// `intimacyLogs.count` when events were logged in Apple Health only.
    var intimacyEventCount: Int = 0
    var onEdit: () -> Void = { }
    var onDelete: () -> Void = { }
    /// The pending delete, held until the user confirms it. Deleting a cycle day removes the
    /// HealthKit samples AND the sealed note for that day — never on one tap.
    @State private var pendingDelete: DestructiveConfirmation?

    /// Whether this day actually holds a cycle log. A day with nothing on it gets "Log this day"
    /// and no Delete: the old screen offered "Edit"/"Delete" on an empty day, where Delete was a
    /// no-op that still popped the screen as though something had been removed.
    private var hasCycleLog: Bool {
        entry.hasObservedEvent || entry.narrative != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Both halves are runtime text, so both go through `Text(verbatim:)`:
                // `Date.formatted` has already localized itself and must not be re-looked-up, and
                // the phase title is a domain display property that resolves its own string.
                ScreenHeader(
                    title: Text(verbatim: entry.date.formatted(.dateTime.month(.wide).day())),
                    subtitle: Text(verbatim: showsPeriodHalf
                                   ? entry.phase.title
                                   : entry.date.formatted(.dateTime.weekday(.wide)))
                )

                if showsPeriodHalf {
                    periodSamplesCard
                    narrativeCard
                }

                if showsIntimacyHalf {
                    intimacyCard
                }

                if showsPeriodHalf {
                    HStack {
                        Button(hasCycleLog ? "Edit" : "Log this day", action: onEdit)
                            .foregroundStyle(Color.moss)
                        Spacer()
                        if hasCycleLog {
                            Button("Delete", role: .destructive) {
                                pendingDelete = DestructiveConfirmation(
                                    title: "Delete this day's cycle log?",
                                    message: "This removes the health samples Fernlet wrote for \(entry.date.formatted(.dateTime.month(.wide).day())) and the sealed note kept with them. It can't be undone.",
                                    confirmLabel: "Delete",
                                    auditEvent: "cycle.dayDeleteConfirmed",
                                    perform: { onDelete() }
                                )
                            }
                            .foregroundStyle(Color.terracottaInk)
                        }
                    }
                    .font(.fernlet(.label))
                    .padding(.horizontal, 4)
                }
            }
            .padding(20)
        }
        .background(Color.parchment)
        .navigationTitle("")
        .destructiveConfirmation($pendingDelete)
    }

    // MARK: - Period half

    private var periodSamplesCard: some View {
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
    }

    private var narrativeCard: some View {
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
    }

    // MARK: - Intimacy half

    /// The day's intimacy events and sealed notes. Health-only events (a sexual-activity sample
    /// with no local note) surface as a count row so a marked calendar day never opens to a blank
    /// card.
    private var intimacyCard: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Intimacy")
                    .font(.fernlet(.header))
                    .foregroundStyle(Color.bark)
                if intimacyLogs.isEmpty && intimacyEventCount == 0 {
                    EmptyState(text: "No intimacy events for this day.")
                } else {
                    ForEach(Array(intimacyLogs.enumerated()), id: \.element.id) { index, log in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(log.eventDate.formatted(.dateTime.hour().minute()))
                                .font(.fernlet(.labelSmall))
                                .foregroundStyle(Color.slate)
                            if !log.note.isEmpty {
                                Text(log.note)
                                    .font(.fernlet(.body))
                                    .foregroundStyle(Color.bark)
                                    .fernletWrappingText()
                            }
                            if log.healthKitExternalUUID != nil {
                                Label("Saved to Apple Health", systemImage: "heart.text.square")
                                    .font(.fernlet(.labelSmall))
                                    .foregroundStyle(Color.moss)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if index < intimacyLogs.count - 1 || intimacyEventCount > intimacyLogs.count {
                            FernletRowDivider()
                        }
                    }
                    if intimacyEventCount > intimacyLogs.count {
                        let healthOnly = intimacyEventCount - intimacyLogs.count
                        Label(
                            healthOnly == 1 ? "1 event logged in Apple Health" : "\(healthOnly) events logged in Apple Health",
                            systemImage: "heart.text.square"
                        )
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.moss)
                    }
                }
            }
        }
    }

    // MARK: - Sample labels

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
