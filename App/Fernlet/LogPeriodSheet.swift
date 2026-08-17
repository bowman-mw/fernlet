import SwiftUI
import FernletDomainModel
import FernletLock
import PrivateHealthStore
import HealthKitGateway
import FernletUI

/// The log/edit sheet for a cycle day: flow level, cycle-start and intermenstrual-bleeding flags,
/// symptoms with intensity steppers, cervical mucus and ovulation-test observations, basal body
/// temperature, and a private note.
///
/// Serves both flows — a fresh log (optionally pre-dated via `targetDate`) and an edit of an
/// existing `CycleDayEntry` — and saves through `PeriodTrackerStore.logEvent`/`editEvent` as a
/// `UserLoggedCycleEvent`. The clinical fields become HealthKit samples; the note and symptoms
/// become a sealed narrative, so the sheet warns up front when no app lock is configured and maps
/// the store's `PeriodLogResult` (saved / narrative buffered until unlock / narrative dropped) to
/// an honest status message before dismissing.
struct LogPeriodSheet: View {
    var periodStore: PeriodTrackerStore
    private let editingEntry: CycleDayEntry?
    @Environment(FernletLockService.self) private var lockService
    @Environment(\.dismiss) private var dismiss
    @State private var authorization = HealthKitAuthorizationViewModel()

    @State private var eventDate: Date
    @State private var flowLevel: PeriodFlowLevel?
    @State private var temperatureText: String
    @State private var temperatureUnit: PeriodTemperatureUnit
    @State private var mucusQuality: CervicalMucusQuality?
    @State private var ovulationResult: OvulationTestResult?
    @State private var hasIntermenstrualBleeding: Bool
    @State private var isCycleStart: Bool
    @State private var note: String
    @State private var symptoms: Set<PeriodSymptom>
    @State private var customScales: [PeriodSymptom: Int]
    @State private var statusMessage: String?
    @State private var isSaving = false

    init(periodStore: PeriodTrackerStore, targetDate: Date? = nil, editingEntry: CycleDayEntry? = nil) {
        self.periodStore = periodStore
        self.editingEntry = editingEntry
        let defaultUnit: PeriodTemperatureUnit = Locale.current.measurementSystem == .metric ? .celsius : .fahrenheit
        _eventDate = State(initialValue: editingEntry?.date ?? targetDate ?? Date())
        _flowLevel = State(initialValue: editingEntry?.flowLevel)
        _isCycleStart = State(initialValue: editingEntry?.isCycleStart ?? false)
        _hasIntermenstrualBleeding = State(initialValue: editingEntry?.hasIntermenstrualBleeding ?? false)
        _mucusQuality = State(initialValue: editingEntry?.cervicalMucusQuality)
        _ovulationResult = State(initialValue: editingEntry?.ovulationTestResult)
        if let bbt = editingEntry?.basalBodyTemperatureFahrenheit {
            _temperatureText = State(initialValue: String(format: "%.2f", bbt))
            _temperatureUnit = State(initialValue: .fahrenheit)
        } else {
            _temperatureText = State(initialValue: "")
            _temperatureUnit = State(initialValue: defaultUnit)
        }
        _note = State(initialValue: editingEntry?.narrative?.note ?? "")
        _symptoms = State(initialValue: Set(editingEntry?.narrative?.symptomFlags ?? []))
        _customScales = State(initialValue: Dictionary(uniqueKeysWithValues: (editingEntry?.narrative?.customSymptomScales ?? [:]).compactMap { rawValue, scale in
            PeriodSymptom(rawValue: rawValue).map { ($0, scale) }
        }))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(editingEntry != nil ? "Edit period" : "Log period")
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

                    lockWarning
                    flowLevelField
                    cycleDetailsField
                    symptomsField
                    observationsField
                    temperatureField
                    noteField
                    noteCounter
                    statusText
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: isSaving ? "Saving" : "Save", disabled: isSaving) {
                Task { await save() }
            }
        }
        .background(Color.parchment)
        .task {
            periodStore.attachLockService(lockService)
            if !authorization.hasRequested(.cycleTracking) {
                await authorization.request(.cycleTracking)
            }
        }
        // Capture FRICTION (never a security control), attached at the sheet TYPE so both
        // presenters (the Cycle page and Home's quick-log tile) are covered by one edit.
        .captureProtected(surface: "logPeriod")
    }

    /// Shown only when notes would be dropped for want of an app lock.
    @ViewBuilder
    private var lockWarning: some View {
        if lockService.state == .notConfigured && hasNarrative {
            Text("Notes are only saved when app lock is on. Set up app lock in Settings to keep them with this cycle.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.terracotta)
                .fernletWrappingText()
        }
    }

    private var flowLevelField: some View {
        SheetField("Flow level") {
            FlowLayout(spacing: 8) {
                ForEach(PeriodFlowLevel.allCases) { level in
                    Button(level.title) { flowLevel = level }
                        .buttonStyle(ChipButtonStyle(selected: flowLevel == level))
                }
            }
        }
    }

    private var cycleDetailsField: some View {
        SheetField("Cycle details") {
            VStack(spacing: 0) {
                periodToggle("First day of cycle", isOn: $isCycleStart)
                Divider()
                periodToggle("Intermenstrual bleeding", isOn: $hasIntermenstrualBleeding)
            }
            .padding(.horizontal, 14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
        }
    }

    /// One toggle per symptom, each revealing a 1…10 intensity stepper while it is on.
    private var symptomsField: some View {
        SheetField("Symptoms") {
            VStack(spacing: 0) {
                ForEach(PeriodSymptom.allCases) { symptom in
                    VStack(alignment: .leading, spacing: 8) {
                        periodToggle(symptom.title, isOn: Binding(
                            get: { symptoms.contains(symptom) },
                            set: { isOn in
                                if isOn {
                                    symptoms.insert(symptom)
                                } else {
                                    symptoms.remove(symptom)
                                    customScales[symptom] = nil
                                }
                            }
                        ))

                        if symptoms.contains(symptom) {
                            Stepper(value: Binding(
                                get: { customScales[symptom] ?? 5 },
                                set: { customScales[symptom] = $0 }
                            ), in: 1...10) {
                                Text("Intensity \(customScales[symptom] ?? 5)")
                            }
                            .padding(.bottom, 12)
                        }
                    }
                    if symptom != PeriodSymptom.allCases.last {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
        }
    }

    private var observationsField: some View {
        SheetField("Observations") {
            VStack(spacing: 12) {
                Picker("Cervical mucus", selection: $mucusQuality) {
                    Text("None").tag(CervicalMucusQuality?.none)
                    ForEach(CervicalMucusQuality.allCases) { quality in
                        Text(quality.title).tag(Optional(quality))
                    }
                }
                Picker("Ovulation test", selection: $ovulationResult) {
                    Text("None").tag(OvulationTestResult?.none)
                    ForEach(OvulationTestResult.allCases) { result in
                        Text(result.title).tag(Optional(result))
                    }
                }
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
        }
    }

    private var temperatureField: some View {
        SheetField("Basal body temperature") {
            HStack(spacing: 10) {
                TextField("Optional", text: $temperatureText)
                    .keyboardType(.decimalPad)
                    .sheetTextInput()
                Picker("Unit", selection: $temperatureUnit) {
                    ForEach(PeriodTemperatureUnit.allCases) { unit in
                        Text(unit.symbol).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
            }
        }
    }

    private var noteField: some View {
        SheetField("Note") {
            SheetTextEditor(
                text: Binding(
                    get: { note },
                    set: { note = String($0.prefix(1000)) }
                ),
                placeholder: "Anything important to remember?",
                minHeight: 140
            )
        }
    }

    private var noteCounter: some View {
        Text("\(note.count)/1000")
            .font(.fernlet(.stat))
            .foregroundStyle(Color.slate)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The save outcome (or a validation message) in the sheet's own voice.
    @ViewBuilder
    private var statusText: some View {
        if let statusMessage {
            Text(statusMessage)
                .font(.fernlet(.body))
                .foregroundStyle(Color.moss)
                .fernletWrappingText()
        }
    }

    private func periodToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .tint(Color.moss)
            .padding(.vertical, 12)
    }

    private var hasNarrative: Bool {
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !symptoms.isEmpty
    }

    /// Plausible basal-body-temperature ranges. A value outside them is a typo or a paste, never a
    /// reading, and this sheet's value becomes an `HKQuantitySample` verbatim.
    private static let celsiusRange = 30.0...45.0
    private static let fahrenheitRange = 86.0...113.0

    private var temperatureRange: ClosedRange<Double> {
        temperatureUnit == .celsius ? Self.celsiusRange : Self.fahrenheitRange
    }

    /// Validates the typed basal body temperature.
    ///
    /// R5: `Double("nan")`, `Double("1e400")` and `-5` all parse (paste or a hardware keyboard) and
    /// would reach HealthKit as a non-finite or absurd clinical sample, so the value is checked here
    /// — nil field is fine, unusable field refuses the save with a message.
    private func validatedTemperature() -> TemperatureValidation {
        let trimmed = temperatureText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty else { return .value(nil) }
        let range = temperatureRange
        guard let parsed = Double(trimmed), parsed.isFinite, range.contains(parsed) else {
            return .invalid("Enter a temperature between \(Int(range.lowerBound)) and \(Int(range.upperBound)) \(temperatureUnit.symbol), or leave it blank.")
        }
        return .value(parsed)
    }

    /// The outcome of validating the typed basal body temperature: a usable value (nil when the
    /// field is blank), or the message explaining why the save is refused.
    private enum TemperatureValidation {
        case value(Double?)
        case invalid(String)
    }

    private func save() async {
        // Single-flight: the save bar is disabled while saving, but the entry point states it too so
        // a double invocation can never run two writes for one sheet.
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let basalBodyTemperature: Double?
        switch validatedTemperature() {
        case .value(let value):
            basalBodyTemperature = value
        case .invalid(let message):
            statusMessage = message
            return
        }
        do {
            let event = UserLoggedCycleEvent(
                date: eventDate,
                flowLevel: flowLevel,
                basalBodyTemperature: basalBodyTemperature,
                temperatureUnit: temperatureUnit,
                cervicalMucusQuality: mucusQuality,
                ovulationTestResult: ovulationResult,
                hasIntermenstrualBleeding: hasIntermenstrualBleeding,
                isCycleStart: isCycleStart,
                note: note,
                symptoms: symptoms,
                customSymptomScales: Dictionary(uniqueKeysWithValues: customScales.map { symptom, value in
                    (symptom.rawValue, value)
                })
            )
            let result: PeriodLogResult
            if let entry = editingEntry {
                result = try await periodStore.editEvent(event, replacingEntry: entry, unlockedContentKey: lockService.contentKey(for: .privateHub))
            } else {
                result = try await periodStore.logEvent(event, unlockedContentKey: lockService.contentKey(for: .privateHub))
            }
            switch result {
            case .saved:
                dismiss()
            case .savedWithBufferedNarrative:
                statusMessage = "Note saved. Unlock to view it on your calendar."
                // Cancelled: the sheet is already going away — the save has landed, so there is
                // nothing left to do but stop.
                do { try await Task.sleep(for: .seconds(1.2)) } catch { return }
                dismiss()
            case .savedWithDroppedNarrative:
                statusMessage = "Health event saved. Set up app lock to keep notes with future cycles."
                do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
                dismiss()
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
