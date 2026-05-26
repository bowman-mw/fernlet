import SwiftUI

struct LogPeriodSheet: View {
    @ObservedObject var periodStore: PeriodTrackerStore
    @EnvironmentObject private var lockService: FernletLockService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var authorization = HealthKitAuthorizationViewModel()

    @State private var eventDate: Date
    @State private var flowLevel: PeriodFlowLevel = .unspecified
    @State private var temperatureText = ""
    @State private var temperatureUnit: PeriodTemperatureUnit = Locale.current.measurementSystem == .metric ? .celsius : .fahrenheit
    @State private var mucusQuality: CervicalMucusQuality?
    @State private var ovulationResult: OvulationTestResult?
    @State private var hasIntermenstrualBleeding = false
    @State private var isCycleStart = false
    @State private var note = ""
    @State private var symptoms: Set<PeriodSymptom> = []
    @State private var customScales: [PeriodSymptom: Int] = [:]
    @State private var statusMessage: String?
    @State private var isSaving = false

    init(periodStore: PeriodTrackerStore, targetDate: Date? = nil) {
        self.periodStore = periodStore
        _eventDate = State(initialValue: targetDate ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                if lockService.state == .notConfigured && hasNarrative {
                    Text("Notes are only saved when app lock is on. Set up app lock in Settings to keep them with this cycle.")
                        .font(.callout)
                        .foregroundStyle(Color.terracotta)
                }

                Section("Flow") {
                    Picker("Flow level", selection: $flowLevel) {
                        ForEach(PeriodFlowLevel.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("First day of cycle", isOn: $isCycleStart)
                    Toggle("Intermenstrual bleeding", isOn: $hasIntermenstrualBleeding)
                }

                Section("Observations") {
                    HStack {
                        TextField("Basal body temperature", text: $temperatureText)
                            .keyboardType(.decimalPad)
                        Picker("Unit", selection: $temperatureUnit) {
                            ForEach(PeriodTemperatureUnit.allCases) { unit in
                                Text(unit.symbol).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 110)
                    }
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

                Section("Symptoms") {
                    ForEach(PeriodSymptom.allCases) { symptom in
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(symptom.title, isOn: Binding(
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
                            }
                        }
                    }
                }

                Section("Note") {
                    TextEditor(text: $note)
                        .frame(minHeight: 120)
                        .onChange(of: note) { _, newValue in
                            if newValue.count > 1000 { note = String(newValue.prefix(1000)) }
                        }
                }

                if let statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(.callout)
                            .foregroundStyle(Color.moss)
                    }
                }
            }
            .navigationTitle("Log period")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving" : "Save") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
            .task {
                periodStore.attachLockService(lockService)
                if !authorization.hasRequested(.cycleTracking) {
                    await authorization.request(.cycleTracking)
                }
            }
        }
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
                basalBodyTemperature: Double(temperatureText.trimmingCharacters(in: .whitespacesAndNewlines)),
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
            let result = try await periodStore.logEvent(event, unlockedContentKey: lockService.contentKey())
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
