import Observation
import CryptoKit
import Foundation
import HealthKit

struct UserLoggedCycleEvent: Equatable {
    var date: Date = Date()
    var flowLevel: PeriodFlowLevel = .unspecified
    var basalBodyTemperature: Double?
    var temperatureUnit: PeriodTemperatureUnit = .fahrenheit
    var cervicalMucusQuality: CervicalMucusQuality?
    var ovulationTestResult: OvulationTestResult?
    var hasIntermenstrualBleeding = false
    var isCycleStart = false
    var note: String = ""
    var symptoms: Set<PeriodSymptom> = []
    var customSymptomScales: [String: Int] = [:]

    var hasNarrative: Bool {
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !symptoms.isEmpty || !customSymptomScales.isEmpty
    }
}

enum PeriodLogResult: Equatable {
    case saved
    case savedWithBufferedNarrative
    case savedWithDroppedNarrative
}

enum PeriodFlowLevel: String, CaseIterable, Identifiable, Codable {
    case none, light, medium, heavy, unspecified
    var id: String { rawValue }
    var title: String { rawValue == "none" ? "None" : rawValue.capitalized }
    nonisolated var hkValue: Int {
        switch self {
        case .none: HKCategoryValueVaginalBleeding.none.rawValue
        case .light: HKCategoryValueVaginalBleeding.light.rawValue
        case .medium: HKCategoryValueVaginalBleeding.medium.rawValue
        case .heavy: HKCategoryValueVaginalBleeding.heavy.rawValue
        case .unspecified: HKCategoryValueVaginalBleeding.unspecified.rawValue
        }
    }
}

enum PeriodTemperatureUnit: String, CaseIterable, Identifiable, Codable {
    case fahrenheit, celsius
    var id: String { rawValue }
    var symbol: String { self == .fahrenheit ? "F" : "C" }
}

enum CervicalMucusQuality: String, CaseIterable, Identifiable, Codable {
    case dry, sticky, creamy, watery, eggWhite
    var id: String { rawValue }
    var title: String { self == .eggWhite ? "Egg White" : rawValue.capitalized }
    nonisolated var hkValue: Int {
        switch self {
        case .dry: HKCategoryValueCervicalMucusQuality.dry.rawValue
        case .sticky: HKCategoryValueCervicalMucusQuality.sticky.rawValue
        case .creamy: HKCategoryValueCervicalMucusQuality.creamy.rawValue
        case .watery: HKCategoryValueCervicalMucusQuality.watery.rawValue
        case .eggWhite: HKCategoryValueCervicalMucusQuality.eggWhite.rawValue
        }
    }
}

enum OvulationTestResult: String, CaseIterable, Identifiable, Codable {
    case negative, positive, indeterminate
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    nonisolated var hkValue: Int {
        switch self {
        case .negative: HKCategoryValueOvulationTestResult.negative.rawValue
        case .positive: HKCategoryValueOvulationTestResult.luteinizingHormoneSurge.rawValue
        case .indeterminate: HKCategoryValueOvulationTestResult.indeterminate.rawValue
        }
    }
}

enum PeriodSymptom: String, CaseIterable, Identifiable, Codable, Comparable {
    case cramps, headache, breastTenderness, moodSwings, fatigue, bloating, acne, backPain, foodCravings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cramps: "Cramps"
        case .headache: "Headache"
        case .breastTenderness: "Breast tenderness"
        case .moodSwings: "Mood swings"
        case .fatigue: "Fatigue"
        case .bloating: "Bloating"
        case .acne: "Acne"
        case .backPain: "Back pain"
        case .foodCravings: "Food cravings"
        }
    }
    static func < (lhs: PeriodSymptom, rhs: PeriodSymptom) -> Bool {
        Self.allCases.firstIndex(of: lhs)! < Self.allCases.firstIndex(of: rhs)!
    }
}

enum CyclePhase: String, CaseIterable, Identifiable {
    case menstrual, follicular, ovulatory, luteal, unknown
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct CycleDayEntry: Identifiable, Equatable {
    var id: String { dateKey }
    var date: Date
    var dateKey: String
    var samples: [HKSample]
    var narrative: MenstrualNarrative?
    var phase: CyclePhase

    var hasObservedEvent: Bool { !samples.isEmpty }
    var menstrualFlowSamples: [HKCategorySample] {
        samples.compactMap { $0 as? HKCategorySample }.filter { $0.categoryType.identifier == HKCategoryTypeIdentifier.menstrualFlow.rawValue }
    }
    var flowLevel: PeriodFlowLevel? {
        guard let sample = menstrualFlowSamples.first else { return nil }
        switch HKCategoryValueVaginalBleeding(rawValue: sample.value) {
        case .some(HKCategoryValueVaginalBleeding.none): return PeriodFlowLevel.none
        case .some(.light): return .light
        case .some(.medium): return .medium
        case .some(.heavy): return .heavy
        default: return .unspecified
        }
    }
    var flowLabel: String {
        guard let value = menstrualFlowSamples.first?.value else { return "No flow" }
        switch HKCategoryValueVaginalBleeding(rawValue: value) {
        case .some(.none): return "None"
        case .some(.light): return "Light"
        case .some(.medium): return "Medium"
        case .some(.heavy): return "Heavy"
        default: return "Unspecified"
        }
    }
}

protocol PeriodHealthKitServicing: HealthKitServicing {
    func savePeriodEvent(_ event: UserLoggedCycleEvent, externalUUID: UUID) async throws -> [HKSample]
    func loadPeriodEvents(in dateRange: DateInterval) async throws -> [HKSample]
}

extension HealthKitService: PeriodHealthKitServicing {
    func savePeriodEvent(_ event: UserLoggedCycleEvent, externalUUID: UUID) async throws -> [HKSample] {
        guard isHealthDataAvailable() else { throw HealthKitServiceError.healthDataUnavailable }
        let samples = try Self.periodSamples(for: event, externalUUID: externalUUID)
        try await save(samples)
        FernletAuditLog.log("hk.write.saved", context: ["type": "cycle", "externalUUID": externalUUID.uuidString])
        return samples
    }

    func loadPeriodEvents(in dateRange: DateInterval) async throws -> [HKSample] {
        guard isHealthDataAvailable() else { throw HealthKitServiceError.healthDataUnavailable }
        let predicate = HKQuery.predicateForSamples(withStart: dateRange.start, end: dateRange.end, options: .strictStartDate)
        var allSamples: [HKSample] = []
        for sampleType in try Self.periodSampleTypes() {
            allSamples += try await samples(for: sampleType, predicate: predicate)
        }
        return allSamples.sorted { $0.startDate < $1.startDate }
    }

    nonisolated static func periodSamples(for event: UserLoggedCycleEvent, externalUUID: UUID) throws -> [HKSample] {
        let start = event.date
        let end = max(event.date.addingTimeInterval(60), event.date)
        var metadata: [String: Any] = [
            HKMetadataKeyExternalUUID: externalUUID.uuidString,
            HKMetadataKeyMenstrualCycleStart: event.isCycleStart
        ]
        var samples: [HKSample] = [
            HKCategorySample(type: try categoryType(.menstrualFlow), value: event.flowLevel.hkValue, start: start, end: end, metadata: metadata)
        ]

        if let temperature = event.basalBodyTemperature {
            let unit: HKUnit = event.temperatureUnit == .fahrenheit ? .degreeFahrenheit() : .degreeCelsius()
            samples.append(HKQuantitySample(type: try quantityType(.basalBodyTemperature), quantity: HKQuantity(unit: unit, doubleValue: temperature), start: start, end: end, metadata: metadata))
        }
        if let mucus = event.cervicalMucusQuality {
            samples.append(HKCategorySample(type: try categoryType(.cervicalMucusQuality), value: mucus.hkValue, start: start, end: end, metadata: metadata))
        }
        if let ovulation = event.ovulationTestResult {
            samples.append(HKCategorySample(type: try categoryType(.ovulationTestResult), value: ovulation.hkValue, start: start, end: end, metadata: metadata))
        }
        if event.hasIntermenstrualBleeding {
            metadata[HKMetadataKeyMenstrualCycleStart] = false
            samples.append(HKCategorySample(type: try categoryType(.intermenstrualBleeding), value: HKCategoryValue.notApplicable.rawValue, start: start, end: end, metadata: metadata))
        }
        return samples
    }

    nonisolated static func periodSampleTypes() throws -> [HKSampleType] {
        [
            try categoryType(.menstrualFlow),
            try quantityType(.basalBodyTemperature),
            try categoryType(.cervicalMucusQuality),
            try categoryType(.ovulationTestResult),
            try categoryType(.intermenstrualBleeding)
        ]
    }

    private func samples(for type: HKSampleType, predicate: NSPredicate?) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: samples ?? []) }
            }
            healthStore.execute(query)
        }
    }
}

@MainActor
@Observable
final class PeriodTrackerStore {
    var entries: [CycleDayEntry] = []
    var currentPhase: CyclePhase = .unknown
    var prediction: CyclePrediction?

    @ObservationIgnored private let healthService: PeriodHealthKitServicing
    @ObservationIgnored private let narrativeRepository: MenstrualNarrativeRepository
    @ObservationIgnored private var lockService: FernletLockServicing?
    @ObservationIgnored private let calendar: Calendar

    init(
        healthService: PeriodHealthKitServicing? = nil,
        narrativeRepository: MenstrualNarrativeRepository? = nil,
        lockService: FernletLockServicing? = nil,
        calendar: Calendar = .current
    ) {
        self.healthService = healthService ?? HealthKitService()
        self.narrativeRepository = narrativeRepository ?? MenstrualNarrativeRepository()
        self.lockService = lockService
        self.calendar = calendar
    }

    func attachLockService(_ lockService: FernletLockServicing) {
        self.lockService = lockService
    }

    func loadEntries(unlockedContentKey: SymmetricKey?) async {
        let range = DateInterval(start: calendar.date(byAdding: .day, value: -240, to: Date()) ?? Date().addingTimeInterval(-240 * 86_400), end: Date())
        do {
            let samples = try await healthService.loadPeriodEvents(in: range)
            let narratives = (try? narrativeRepository.narratives(in: range, contentKey: unlockedContentKey)) ?? []
            let narrativeByUUID = Dictionary(uniqueKeysWithValues: narratives.map { ($0.hkExternalUUID, $0) })
            entries = buildEntries(samples: samples, narratives: narrativeByUUID, range: range)
            currentPhase = currentPhaseFromObservations()
            if unlockedContentKey != nil {
                prediction = CyclePredictionEngine.predict(from: entries, today: Date(), calendar: calendar)
            } else {
                prediction = nil
            }
        } catch {
            entries = []
            currentPhase = .unknown
            prediction = nil
        }
    }

    func logEvent(_ event: UserLoggedCycleEvent, unlockedContentKey: SymmetricKey?) async throws -> PeriodLogResult {
        let externalUUID = UUID()
        _ = try await healthService.savePeriodEvent(event, externalUUID: externalUUID)
        guard event.hasNarrative else { return .saved }

        let narrative = MenstrualNarrative(
            hkExternalUUID: externalUUID.uuidString,
            dateKey: FernletDate.dayKey(for: event.date),
            note: String(event.note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000)),
            symptomFlags: event.symptoms.sorted(),
            customSymptomScales: event.customSymptomScales
        )

        if let unlockedContentKey {
            try narrativeRepository.insert(narrative, contentKey: unlockedContentKey)
            return .saved
        }

        if lockService?.state == .notConfigured {
            return .savedWithDroppedNarrative
        }

        try lockService?.bufferPendingNarrative(PendingNarrativePayload(
            hkExternalUUID: narrative.hkExternalUUID,
            dateKey: narrative.dateKey,
            noteBytes: narrative.note.map { Data($0.utf8) },
            symptomFlagsBytes: try JSONEncoder().encode(narrative.symptomFlags.map(\.rawValue)),
            customSymptomScalesBytes: try JSONEncoder().encode(narrative.customSymptomScales)
        ))
        return .savedWithBufferedNarrative
    }

    func deleteEntry(_ entry: CycleDayEntry) async throws {
        try await healthService.delete(entry.samples)
        if let narrative = entry.narrative {
            try narrativeRepository.delete(id: narrative.id)
        }
        entries.removeAll { $0.id == entry.id }
        currentPhase = currentPhaseFromObservations()
    }

    func drainPendingBuffer(contentKey: SymmetricKey) async throws {
        guard let lockService else { return }
        let pending = try lockService.drainPendingNarratives()
        for payload in pending {
            let symptomsRaw = try payload.symptomFlagsBytes.map { try JSONDecoder().decode([String].self, from: $0) } ?? []
            let scales = try payload.customSymptomScalesBytes.map { try JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
            try narrativeRepository.insert(MenstrualNarrative(
                hkExternalUUID: payload.hkExternalUUID,
                dateKey: payload.dateKey,
                note: payload.noteBytes.flatMap { String(data: $0, encoding: .utf8) },
                symptomFlags: symptomsRaw.compactMap(PeriodSymptom.init(rawValue:)),
                customSymptomScales: scales
            ), contentKey: contentKey)
        }
    }

    func currentPhaseFromObservations() -> CyclePhase {
        let todayKey = FernletDate.dayKey(for: Date())
        guard entries.first(where: { $0.dateKey == todayKey })?.menstrualFlowSamples.isEmpty == false else { return .unknown }
        return .menstrual
    }

    private func buildEntries(samples: [HKSample], narratives: [String: MenstrualNarrative], range: DateInterval) -> [CycleDayEntry] {
        let grouped = Dictionary(grouping: samples) { FernletDate.dayKey(for: $0.startDate) }
        var result: [CycleDayEntry] = []
        var day = calendar.startOfDay(for: range.start)
        let end = calendar.startOfDay(for: range.end)
        while day <= end {
            let key = FernletDate.dayKey(for: day)
            let daySamples = grouped[key] ?? []
            let narrative = daySamples.compactMap { $0.metadata?[HKMetadataKeyExternalUUID] as? String }.compactMap { narratives[$0] }.first
            let phase: CyclePhase = daySamples.contains { sample in
                (sample as? HKCategorySample)?.categoryType.identifier == HKCategoryTypeIdentifier.menstrualFlow.rawValue
            } ? .menstrual : .unknown
            result.append(CycleDayEntry(date: day, dateKey: key, samples: daySamples, narrative: narrative, phase: phase))
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        }
        return result
    }
}
