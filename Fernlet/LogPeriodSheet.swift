import SwiftUI
import FernletDomainModel
import FernletLock
import PrivateHealthStore
import HealthKitGateway

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

                    if lockService.state == .notConfigured && hasNarrative {
                        Text("Notes are only saved when app lock is on. Set up app lock in Settings to keep them with this cycle.")
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.terracotta)
                            .fernletWrappingText()
                    }

                    SheetField("Flow level") {
                        FlowLayout(spacing: 8) {
                            ForEach(PeriodFlowLevel.allCases) { level in
                                Button(level.title) { flowLevel = level }
                                    .buttonStyle(ChipButtonStyle(selected: flowLevel == level))
                            }
                        }
                    }

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

                    Text("\(note.count)/1000")
                        .font(.fernlet(.stat))
                        .foregroundStyle(Color.slate)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.moss)
                            .fernletWrappingText()
                    }
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
    }

    private func periodToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .tint(Color.moss)
            .padding(.vertical, 12)
    }

    private var hasNarrative: Bool {
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !symptoms.isEmpty
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let event = UserLoggedCycleEvent(
                date: eventDate,
                flowLevel: flowLevel,
                basalBodyTemperature: Double(temperatureText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")),
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
                result = try await periodStore.editEvent(event, replacingEntry: entry, unlockedContentKey: lockService.contentKey())
            } else {
                result = try await periodStore.logEvent(event, unlockedContentKey: lockService.contentKey())
            }
            switch result {
            case .saved:
                dismiss()
            case .savedWithBufferedNarrative:
                statusMessage = "Note saved. Unlock to view it on your calendar."
                try? await Task.sleep(for: .seconds(1.2))
                dismiss()
            case .savedWithDroppedNarrative:
                statusMessage = "Health event saved. Set up app lock to keep notes with future cycles."
                try? await Task.sleep(for: .seconds(1.5))
                dismiss()
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
