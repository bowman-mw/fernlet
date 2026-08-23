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
                // Both halves go through `Text(verbatim:)`, for two very different reasons.
                // `Date.formatted` has already localized itself and must not be re-looked-up. The
                // phase title has NOT: `CyclePhase.title` is `rawValue.capitalized` — a storage
                // token wearing paint — so this subtitle reads "Follicular" in every language.
                // `verbatim:` is honest about that but does not fix it; the phase belongs to the
                // deferred `.capitalized`-on-rawValue class in `PeriodTrackerStore`, and still
                // needs the `displayName` fork the flow, mucus, and ovulation words have.
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
                    Button(hasCycleLog ? "Edit" : "Log this day", action: onEdit)
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.moss)
                        .padding(.horizontal, 4)
                        // The only way back into the log sheet, and it was a bare ~18pt-tall word
                        // (review T2-18). `fernletTapTarget` is `.frame(minWidth: 44,
                        // minHeight: 44)` + `.contentShape(Rectangle())`, so it grows the button's
                        // LAYOUT box — not merely a hit box — to at least 44×44 and makes all of
                        // that box tappable. This row is therefore ~26pt taller than it was and
                        // everything below it sits lower; `minWidth` is inert here, since the
                        // padded word is already wider than 44. The word itself keeps its size and
                        // face, now centered in the taller box rather than filling it.
                        .fernletTapTarget()
                    if hasCycleLog {
                        Button(role: .destructive) {
                            pendingDelete = DestructiveConfirmation(
                                title: "Delete this day's cycle log?",
                                message: "This removes the health samples Fernlet wrote for \(entry.date.formatted(.dateTime.month(.wide).day())) and the sealed note kept with them. It can't be undone.",
                                confirmLabel: "Delete",
                                auditEvent: "cycle.dayDeleteConfirmed",
                                perform: { onDelete() }
                            )
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(DestructiveCardButtonStyle())
                    }
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
                        sampleLabel(for: sample)
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
                        // One utterance per event instead of three (review T2-18): the time, the
                        // note, and the "Saved to Apple Health" footnote are one row's worth of
                        // meaning, and swiping through them separately made a two-event day a
                        // six-stop journey. No `.accessibilityLabel` on top — the combined
                        // fragments already say everything the row draws, and a label would
                        // silently replace them.
                        .accessibilityElement(children: .combine)
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

    /// The drawn and spoken row for one HealthKit cycle sample.
    ///
    /// Returns `Text`, not `String`: a `String` reaches SwiftUI through the non-localizing
    /// `StringProtocol` initializer, so every row on this screen rendered English forever even in a
    /// translated build (localization wall). Each branch is one whole sentence with the runtime
    /// value interpolated, so a translator gets a complete format string per row instead of clauses
    /// glued together in English word order.
    private func sampleLabel(for sample: HKSample) -> Text {
        let kind = CycleSampleKind(identifier: sample.sampleType.identifier)
        guard let category = sample as? HKCategorySample else {
            // Basal temperature is the one quantity sample this screen shows. Anything else —
            // including a basal identifier on a class that cannot carry a temperature — is
            // malformed input, not a reason to trap.
            if let quantity = sample as? HKQuantitySample, case .basalBodyTemperature = kind {
                return basalTemperatureLabel(quantity)
            }
            return Text("Other cycle sample")
        }
        switch kind {
        case .menstrualFlow:
            // `flowDisplayName` (app-target fork), not the sealed store's English `flowLabel`.
            return Text("Flow: \(entry.flowDisplayName)")
        case .cervicalMucus:
            return Text("Cervical mucus: \(mucusDisplayName(category.value))")
        case .ovulationTest:
            return Text("Ovulation test: \(ovulationDisplayName(category.value))")
        case .intermenstrualBleeding:
            return Text("Intermenstrual bleeding")
        case .basalBodyTemperature, .other:
            return Text("Other cycle sample")
        }
    }

    /// The basal-temperature row, in the unit this device's region actually reads.
    ///
    /// Localization Phase 0 shipped metric body entry and this one row stayed hardcoded to
    /// Fahrenheit, so a metric user's own basal chart came back in a scale they do not use, on
    /// numbers whose entire value is small day-to-day movement. The first fix reached for
    /// ``BodyMeasurementEntry/usesImperial`` — the WEIGHT and HEIGHT preference — while the log
    /// sheet's picker asked a different question of the same locale, and the two disagreed about
    /// `.uk`: the picker offered Fahrenheit and this row answered in Celsius. It now resolves
    /// ``PeriodTemperatureUnit/regionDefault``, the single derivation `LogPeriodSheet` seeds its
    /// picker from, so the unit a reading is entered in is the unit it is read back in, and a
    /// Region change in iOS Settings moves both without a relaunch.
    ///
    /// The degree symbol sits inside each format string rather than being appended, because where
    /// the unit goes relative to the number is a translator's decision.
    ///
    /// - Note: what the user actually SELECTED in that picker is `@State` on the sheet and is
    ///   persisted nowhere, so a reading a US user deliberately typed in °C still reads back in
    ///   °F. Honouring it needs a durable preference, which is a separate change.
    private func basalTemperatureLabel(_ quantity: HKQuantitySample) -> Text {
        // R5: the caller's precondition, restated at the entry point it protects.
        // `doubleValue(for:)` raises an uncatchable Objective-C exception when the quantity is not
        // a temperature, so a non-basal quantity arriving here would take the app down rather than
        // render one odd row.
        guard case .basalBodyTemperature = CycleSampleKind(identifier: quantity.quantityType.identifier) else {
            return Text("Other cycle sample")
        }
        let unit = PeriodTemperatureUnit.regionDefault
        let hkUnit: HKUnit = unit == .fahrenheit ? .degreeFahrenheit() : .degreeCelsius()
        let reading = quantity.quantity
            .doubleValue(for: hkUnit)
            .formatted(.number.precision(.fractionLength(1)))
        return unit == .fahrenheit
            ? Text("Basal body temperature: \(reading) °F")
            : Text("Basal body temperature: \(reading) °C")
    }

    /// The localized cervical-mucus word for HealthKit's raw category value.
    ///
    /// The `Int` is the frozen token (HealthKit's own storage value, matched never shown); this is
    /// the display half. Both halves of the mapping now come from ONE place each. Which case a raw
    /// value is, is decided by ``CervicalMucusQuality/hkValue`` — the sealed store's own token
    /// table, the same one `CycleDayEntry.cervicalMucusQuality` matches on — and the word by the
    /// app-target ``CervicalMucusQuality/displayName`` fork the log sheet's picker also renders.
    /// The `HKCategoryValueCervicalMucusQuality` switch this replaces was a second, independent
    /// copy of both, and it had already drifted: it said "Egg white" while the picker said
    /// "Egg White".
    ///
    /// Matched per SAMPLE rather than through `CycleDayEntry.cervicalMucusQuality`, which reports
    /// only the day's FIRST mucus sample — this screen lists every one, including other apps'.
    /// A value no case claims (a quality HealthKit gained after this build) reads "Unknown" rather
    /// than a number.
    private func mucusDisplayName(_ value: Int) -> String {
        guard let quality = CervicalMucusQuality.allCases.first(where: { $0.hkValue == value }) else {
            return unknownSampleValueName
        }
        return quality.displayName
    }

    /// The localized ovulation-test word for HealthKit's raw category value. Token source, display
    /// source, per-sample matching and unknown handling exactly as in ``mucusDisplayName(_:)``.
    private func ovulationDisplayName(_ value: Int) -> String {
        guard let result = OvulationTestResult.allCases.first(where: { $0.hkValue == value }) else {
            return unknownSampleValueName
        }
        return result.displayName
    }

    /// The shared fallback word for a sample value neither display fork recognises.
    private var unknownSampleValueName: String {
        String(localized: "cycle.sample.unknownValue", defaultValue: "Unknown",
               comment: "Shown in place of a cycle sample's value when the recorded value is one Fernlet has no wording for.")
    }
}

/// App-target display fork over the raw HealthKit sample identifiers ``CycleDayDetailView`` renders
/// (review T2-18).
///
/// The identifier — `HKCategoryTypeIdentifierMenstrualFlow` and its siblings — is a **frozen
/// token**: Apple owns its spelling, it is what a sample lookup matches on, and it neither
/// localizes nor changes. The bug was that it doubled as *display copy*. The old `label(for:)` had
/// two `default` branches that returned `sampleType.identifier` verbatim, so any sample this screen
/// does not map was drawn — and, once VoiceOver reached a screen that carried no accessibility
/// modifiers at all, **spoken aloud** — as "HKCategoryTypeIdentifierSleepAnalysis".
///
/// This enum is the fork. ``init(identifier:)`` matches the token and nothing else; the view's
/// `sampleLabel(for:)` switches on the resulting *case* to build localized copy, with ``other`` as
/// the deliberate catch-all the unmapped identifiers now land in. Switching on a case rather than
/// on the raw string at the call site is the shape batch A4 used for `PeriodFlowLevel`: a kind
/// added here without copy is a compiler error, not a silently raw row.
private enum CycleSampleKind {
    /// `HKCategoryTypeIdentifierMenstrualFlow`.
    case menstrualFlow
    /// `HKCategoryTypeIdentifierCervicalMucusQuality`.
    case cervicalMucus
    /// `HKCategoryTypeIdentifierOvulationTestResult`.
    case ovulationTest
    /// `HKCategoryTypeIdentifierIntermenstrualBleeding`.
    case intermenstrualBleeding
    /// `HKQuantityTypeIdentifierBasalBodyTemperature` — the one quantity type this screen shows.
    case basalBodyTemperature
    /// Every identifier this screen has no copy for. Its label is generic on purpose: someone
    /// reading their own cycle day learns nothing from Apple's type name, and hearing it read out
    /// character by character is worse than learning nothing.
    case other

    /// Resolves a frozen HealthKit type identifier to a typed case.
    ///
    /// Matching only — the identifier is compared here and never escapes into anything a user
    /// reads or hears.
    init(identifier: String) {
        switch identifier {
        case HKCategoryTypeIdentifier.menstrualFlow.rawValue: self = .menstrualFlow
        case HKCategoryTypeIdentifier.cervicalMucusQuality.rawValue: self = .cervicalMucus
        case HKCategoryTypeIdentifier.ovulationTestResult.rawValue: self = .ovulationTest
        case HKCategoryTypeIdentifier.intermenstrualBleeding.rawValue: self = .intermenstrualBleeding
        case HKQuantityTypeIdentifier.basalBodyTemperature.rawValue: self = .basalBodyTemperature
        default: self = .other
        }
    }
}
