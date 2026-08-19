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
/// `UserLoggedCycleEvent`. A fresh log must carry something to write; an edit only has to have
/// changed, so unsetting a mis-logged flow chip stays saveable and removes that entry rather than
/// forcing the user onto the day detail's Delete (see ``canSave`` and ``save()``).
///
/// The clinical fields become HealthKit samples; the note and symptoms
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
    /// The field values the sheet opened with, so the dirty check compares against exactly what was
    /// seeded (a fresh log and an edit of an existing day seed very different things).
    private let initialValues: SheetValues

    /// Every user-editable value on this sheet, as one comparable snapshot.
    ///
    /// `nonisolated` because the target's default isolation is `MainActor`, and a MainActor-isolated
    /// `==` cannot satisfy `Equatable`'s nonisolated requirement.
    private nonisolated struct SheetValues: Equatable {
        var eventDate: Date
        var flowLevel: PeriodFlowLevel?
        var temperatureText: String
        var mucusQuality: CervicalMucusQuality?
        var ovulationResult: OvulationTestResult?
        var hasIntermenstrualBleeding: Bool
        var isCycleStart: Bool
        var note: String
        var symptoms: Set<PeriodSymptom>
        var customScales: [PeriodSymptom: Int]
    }

    private var currentValues: SheetValues {
        SheetValues(
            eventDate: eventDate,
            flowLevel: flowLevel,
            temperatureText: temperatureText,
            mucusQuality: mucusQuality,
            ovulationResult: ovulationResult,
            hasIntermenstrualBleeding: hasIntermenstrualBleeding,
            isCycleStart: isCycleStart,
            note: note,
            symptoms: symptoms,
            customScales: customScales
        )
    }

    /// Whether the sheet holds anything a swipe-down would throw away.
    private var isDirty: Bool { currentValues != initialValues }

    /// Whether Save is available.
    ///
    /// A fresh log needs something to write. An EDIT needs only a change: a day whose only content
    /// was a flow level had no way back once that chip was unset — gating on content alone left Save
    /// disabled, and the sole exit was the day detail's Delete, which also destroys the sealed note
    /// and every Fernlet-owned HealthKit sample for that day. An emptied edit removes exactly the
    /// entry it is editing (see ``save()``), which is what unsetting the chip asked for.
    private var canSave: Bool { hasLoggableContent || (editingEntry != nil && isDirty) }

    /// Whether the user has emptied an edit out — the tap then removes the entry instead of writing
    /// one, so the bar says so rather than calling a deletion "Save". Requires `isDirty` so the label
    /// only ever changes on a button the user can actually press.
    private var isEmptiedEdit: Bool { editingEntry != nil && !hasLoggableContent && isDirty }

    /// Whether there is anything to log at all. Save used to be enabled on an untouched sheet and
    /// dismissed without writing a thing, which reads as "saved" and isn't.
    private var hasLoggableContent: Bool {
        flowLevel != nil
            || isCycleStart
            || hasIntermenstrualBleeding
            || mucusQuality != nil
            || ovulationResult != nil
            || !symptoms.isEmpty
            || !temperatureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(periodStore: PeriodTrackerStore, targetDate: Date? = nil, editingEntry: CycleDayEntry? = nil) {
        self.periodStore = periodStore
        self.editingEntry = editingEntry
        let defaultUnit: PeriodTemperatureUnit = Locale.current.measurementSystem == .metric ? .celsius : .fahrenheit
        // Seeded ONCE and reused for both the @State values and the dirty-check baseline — two
        // separate `Date()` calls would make a freshly opened sheet claim to be dirty.
        let seeded = SheetValues(
            eventDate: editingEntry?.date ?? targetDate ?? Date(),
            flowLevel: editingEntry?.flowLevel,
            temperatureText: editingEntry?.basalBodyTemperatureFahrenheit.map { String(format: "%.2f", $0) } ?? "",
            mucusQuality: editingEntry?.cervicalMucusQuality,
            ovulationResult: editingEntry?.ovulationTestResult,
            hasIntermenstrualBleeding: editingEntry?.hasIntermenstrualBleeding ?? false,
            isCycleStart: editingEntry?.isCycleStart ?? false,
            note: editingEntry?.narrative?.note ?? "",
            symptoms: Set(editingEntry?.narrative?.symptomFlags ?? []),
            customScales: Dictionary(uniqueKeysWithValues: (editingEntry?.narrative?.customSymptomScales ?? [:]).compactMap { rawValue, scale in
                PeriodSymptom(rawValue: rawValue).map { ($0, scale) }
            })
        )
        _eventDate = State(initialValue: seeded.eventDate)
        _flowLevel = State(initialValue: seeded.flowLevel)
        _isCycleStart = State(initialValue: seeded.isCycleStart)
        _hasIntermenstrualBleeding = State(initialValue: seeded.hasIntermenstrualBleeding)
        _mucusQuality = State(initialValue: seeded.mucusQuality)
        _ovulationResult = State(initialValue: seeded.ovulationResult)
        _temperatureText = State(initialValue: seeded.temperatureText)
        _temperatureUnit = State(initialValue: editingEntry?.basalBodyTemperatureFahrenheit == nil ? defaultUnit : .fahrenheit)
        _note = State(initialValue: seeded.note)
        _symptoms = State(initialValue: seeded.symptoms)
        _customScales = State(initialValue: seeded.customScales)
        self.initialValues = seeded
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(editingEntry != nil ? "Edit period" : "Log period")
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

                    lockWarning
                    dateField
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

            SheetSaveBar(label: saveLabel, disabled: isSaving || !canSave) {
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
        // A swipe-down used to throw away a period log with symptoms and a note, with no warning.
        .fernletDraftGuard(isDirty: isDirty) { dismiss() }
        // Capture FRICTION (never a security control), attached at the sheet TYPE so both
        // presenters (the Cycle page and Home's quick-log tile) are covered by one edit.
        .captureProtected(surface: "logPeriod")
    }

    /// Which day is being logged. Without it the sheet silently logged "today" — a user catching up
    /// on yesterday had to back out, find the day on the calendar, open it, and tap Edit.
    private var dateField: some View {
        SheetField("Date") {
            DatePicker("Date", selection: $eventDate, in: ...Date(), displayedComponents: .date)
                .labelsHidden()
                .tint(Color.moss)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
        }
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
                                    .font(.fernlet(.label))
                                    .foregroundStyle(Color.bark)
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

    /// Cervical mucus and ovulation test as labeled rows.
    ///
    /// A bare `Picker` outside a `Form` drops its title and renders in the system accent, so this
    /// read as two stacked, unexplained blue "None" menus. Each row now names itself and carries a
    /// moss chip showing the current value.
    private var observationsField: some View {
        SheetField("Observations") {
            VStack(spacing: 0) {
                observationRow("Cervical mucus", value: mucusQuality?.title ?? "None") {
                    Button("None") { mucusQuality = nil }
                    ForEach(CervicalMucusQuality.allCases) { quality in
                        Button(quality.title) { mucusQuality = quality }
                    }
                }
                Divider()
                observationRow("Ovulation test", value: ovulationResult?.title ?? "None") {
                    Button("None") { ovulationResult = nil }
                    ForEach(OvulationTestResult.allCases) { result in
                        Button(result.title) { ovulationResult = result }
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
            .tint(Color.moss)
        }
    }

    /// One "label on the left, value chip on the right" observation row.
    private func observationRow<Options: View>(
        _ title: String,
        value: String,
        @ViewBuilder options: () -> Options
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Menu {
                options()
            } label: {
                HStack(spacing: 6) {
                    Text(value)
                        .font(.fernlet(.label))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(Color.moss)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(Color.moss.opacity(0.10), in: Capsule())
                .contentShape(Capsule())
            }
            .accessibilityLabel("\(title), \(value)")
        }
        .padding(.vertical, 8)
    }

    private var temperatureField: some View {
        SheetField("Basal body temperature") {
            HStack(spacing: 10) {
                TextField("Optional", text: $temperatureText)
                    .keyboardType(.decimalPad)
                    .sheetTextInput(font: .fernlet(.label))
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

    /// The save bar's word for what the tap will do — "Remove entry" once an edit has been emptied,
    /// because that tap deletes the day's Fernlet-owned samples and sealed note instead of writing.
    private var saveLabel: String {
        if isSaving { return "Saving" }
        return isEmptiedEdit ? "Remove entry" : "Save"
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
            // Without these the label rendered in system SF, next to DM Sans everywhere else.
            .font(.fernlet(.label))
            .foregroundStyle(Color.bark)
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

    /// Writes the sheet.
    ///
    /// An emptied EDIT is a real outcome, not a no-op: `editEvent` deletes that entry's Fernlet-owned
    /// samples and its sealed narrative and then re-logs an event that carries nothing, so no sample
    /// is written and no narrative is sealed — the day's entry goes away and no other day is touched.
    /// A fresh log can never take that path: `canSave` requires content when `editingEntry` is nil,
    /// so an empty sheet cannot write an empty entry.
    private func save() async {
        // Single-flight: the save bar is disabled while saving, but the entry point states it too so
        // a double invocation can never run two writes for one sheet.
        guard !isSaving else { return }
        // The bar is disabled otherwise; stated here too so the write path carries its own
        // precondition — an empty fresh sheet must never write, and an untouched edit must never
        // delete-and-recreate its day for nothing.
        guard canSave else { return }
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
