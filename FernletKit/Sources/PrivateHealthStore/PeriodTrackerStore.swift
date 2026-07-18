import Observation
import FernletFoundation
import CryptoKit
import Foundation
import HealthKit
import FernletDomainModel
import PrivateStoreCore

public nonisolated struct UserLoggedCycleEvent: Equatable {
    public var date: Date = Date()
    public var flowLevel: PeriodFlowLevel?
    public var basalBodyTemperature: Double?
    public var temperatureUnit: PeriodTemperatureUnit = .fahrenheit
    public var cervicalMucusQuality: CervicalMucusQuality?
    public var ovulationTestResult: OvulationTestResult?
    public var hasIntermenstrualBleeding = false
    public var isCycleStart = false
    public var note: String = ""
    public var symptoms: Set<PeriodSymptom> = []
    public var customSymptomScales: [String: Int] = [:]

    public init(
        date: Date = Date(),
        flowLevel: PeriodFlowLevel? = nil,
        basalBodyTemperature: Double? = nil,
        temperatureUnit: PeriodTemperatureUnit = .fahrenheit,
        cervicalMucusQuality: CervicalMucusQuality? = nil,
        ovulationTestResult: OvulationTestResult? = nil,
        hasIntermenstrualBleeding: Bool = false,
        isCycleStart: Bool = false,
        note: String = "",
        symptoms: Set<PeriodSymptom> = [],
        customSymptomScales: [String: Int] = [:]
    ) {
        self.date = date
        self.flowLevel = flowLevel
        self.basalBodyTemperature = basalBodyTemperature
        self.temperatureUnit = temperatureUnit
        self.cervicalMucusQuality = cervicalMucusQuality
        self.ovulationTestResult = ovulationTestResult
        self.hasIntermenstrualBleeding = hasIntermenstrualBleeding
        self.isCycleStart = isCycleStart
        self.note = note
        self.symptoms = symptoms
        self.customSymptomScales = customSymptomScales
    }

    public var hasNarrative: Bool {
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !symptoms.isEmpty || !customSymptomScales.isEmpty
    }
}

public nonisolated enum PeriodLogResult: Equatable {
    case saved
    case savedWithBufferedNarrative
    case savedWithDroppedNarrative
}

/// Thrown when a cycle write is attempted while cycle tracking is hidden. Reaching this means a
/// caller bypassed a suppressed entry point, so it is a programmer error surfaced as a throw rather
/// than a user-facing state — the UI never offers the affordance while hidden.
public nonisolated struct PeriodTrackingHiddenError: Error, Equatable {
    public init() {}
}

public nonisolated enum PeriodFlowLevel: String, CaseIterable, Identifiable, Codable {
    case none, light, medium, heavy, unspecified
    public var id: String { rawValue }
    public var title: String { rawValue == "none" ? "None" : rawValue.capitalized }
    public var hkValue: Int {
        switch self {
        case .none: HKCategoryValueVaginalBleeding.none.rawValue
        case .light: HKCategoryValueVaginalBleeding.light.rawValue
        case .medium: HKCategoryValueVaginalBleeding.medium.rawValue
        case .heavy: HKCategoryValueVaginalBleeding.heavy.rawValue
        case .unspecified: HKCategoryValueVaginalBleeding.unspecified.rawValue
        }
    }
}

public nonisolated enum PeriodTemperatureUnit: String, CaseIterable, Identifiable, Codable {
    case fahrenheit, celsius
    public var id: String { rawValue }
    public var symbol: String { self == .fahrenheit ? "F" : "C" }
}

public nonisolated enum CervicalMucusQuality: String, CaseIterable, Identifiable, Codable {
    case dry, sticky, creamy, watery, eggWhite
    public var id: String { rawValue }
    public var title: String { self == .eggWhite ? "Egg White" : rawValue.capitalized }
    public var hkValue: Int {
        switch self {
        case .dry: HKCategoryValueCervicalMucusQuality.dry.rawValue
        case .sticky: HKCategoryValueCervicalMucusQuality.sticky.rawValue
        case .creamy: HKCategoryValueCervicalMucusQuality.creamy.rawValue
        case .watery: HKCategoryValueCervicalMucusQuality.watery.rawValue
        case .eggWhite: HKCategoryValueCervicalMucusQuality.eggWhite.rawValue
        }
    }
}

public nonisolated enum OvulationTestResult: String, CaseIterable, Identifiable, Codable {
    case negative, positive, indeterminate
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var hkValue: Int {
        switch self {
        case .negative: HKCategoryValueOvulationTestResult.negative.rawValue
        case .positive: HKCategoryValueOvulationTestResult.luteinizingHormoneSurge.rawValue
        case .indeterminate: HKCategoryValueOvulationTestResult.indeterminate.rawValue
        }
    }
}

public nonisolated enum PeriodSymptom: String, CaseIterable, Identifiable, Codable, Comparable {
    case cramps, headache, breastTenderness, moodSwings, fatigue, bloating, acne, backPain, foodCravings
    public var id: String { rawValue }
    public var title: String {
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
    public static func < (lhs: PeriodSymptom, rhs: PeriodSymptom) -> Bool {
        Self.allCases.firstIndex(of: lhs)! < Self.allCases.firstIndex(of: rhs)!
    }
}

public nonisolated enum CyclePhase: String, CaseIterable, Identifiable {
    case menstrual, follicular, ovulatory, luteal, unknown
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public nonisolated struct CycleDayEntry: Identifiable, Equatable {
    public var id: String { dateKey }
    public var date: Date
    public var dateKey: String
    public var samples: [HKSample]
    public var narrative: MenstrualNarrative?
    public var phase: CyclePhase

    public init(
        date: Date,
        dateKey: String,
        samples: [HKSample],
        narrative: MenstrualNarrative?,
        phase: CyclePhase
    ) {
        self.date = date
        self.dateKey = dateKey
        self.samples = samples
        self.narrative = narrative
        self.phase = phase
    }

    public var hasObservedEvent: Bool { !samples.isEmpty || narrative != nil }
    public var menstrualFlowSamples: [HKCategorySample] {
        samples.compactMap { $0 as? HKCategorySample }.filter { $0.categoryType.identifier == HKCategoryTypeIdentifier.menstrualFlow.rawValue }
    }
    public var flowLevel: PeriodFlowLevel? {
        guard let sample = menstrualFlowSamples.first else { return nil }
        switch HKCategoryValueVaginalBleeding(rawValue: sample.value) {
        case .some(HKCategoryValueVaginalBleeding.none): return PeriodFlowLevel.none
        case .some(.light): return .light
        case .some(.medium): return .medium
        case .some(.heavy): return .heavy
        default: return .unspecified
        }
    }
    public var flowLabel: String {
        guard let value = menstrualFlowSamples.first?.value else { return "No flow" }
        switch HKCategoryValueVaginalBleeding(rawValue: value) {
        case .some(.none): return "None"
        case .some(.light): return "Light"
        case .some(.medium): return "Medium"
        case .some(.heavy): return "Heavy"
        default: return "Unspecified"
        }
    }
    public var isCycleStart: Bool {
        menstrualFlowSamples.first?.metadata?[HKMetadataKeyMenstrualCycleStart] as? Bool ?? false
    }
    public var hasIntermenstrualBleeding: Bool {
        samples.contains { ($0 as? HKCategorySample)?.categoryType.identifier == HKCategoryTypeIdentifier.intermenstrualBleeding.rawValue }
    }
    public var cervicalMucusQuality: CervicalMucusQuality? {
        guard let sample = samples.compactMap({ $0 as? HKCategorySample }).first(where: { $0.categoryType.identifier == HKCategoryTypeIdentifier.cervicalMucusQuality.rawValue }) else { return nil }
        return CervicalMucusQuality.allCases.first { $0.hkValue == sample.value }
    }
    public var ovulationTestResult: OvulationTestResult? {
        guard let sample = samples.compactMap({ $0 as? HKCategorySample }).first(where: { $0.categoryType.identifier == HKCategoryTypeIdentifier.ovulationTestResult.rawValue }) else { return nil }
        return OvulationTestResult.allCases.first { $0.hkValue == sample.value }
    }
    public var basalBodyTemperatureFahrenheit: Double? {
        guard let sample = samples.compactMap({ $0 as? HKQuantitySample }).first(where: { $0.quantityType.identifier == HKQuantityTypeIdentifier.basalBodyTemperature.rawValue }) else { return nil }
        return sample.quantity.doubleValue(for: .degreeFahrenheit())
    }
}

/// Narrow HealthKit seam consumed by `PeriodTrackerStore`. The concrete `HealthKitService`
/// conformance lives app-side (it uses HealthKitService internals); this module only needs the
/// three cycle operations and never refines the fat `HealthKitServicing` protocol.
public protocol PeriodHealthKitServicing: AnyObject {
    func savePeriodEvent(_ event: UserLoggedCycleEvent, externalUUID: UUID) async throws -> [HKSample]
    func loadPeriodEvents(in dateRange: DateInterval) async throws -> [HKSample]
    func delete(_ samples: [HKSample]) async throws
}

/// Narrow lock seam consumed by `PeriodTrackerStore` for buffering narratives while the app is
/// locked. The fat app-side `FernletLockServicing` refines this so the store stays decoupled from
/// the lock service's full surface.
public protocol PeriodLockContext: AnyObject {
    var isLockConfigured: Bool { get }
    func bufferPendingNarrative(_ payload: PendingNarrativePayload) throws
    func drainPendingNarratives() throws -> [PendingNarrativePayload]
    func purgePendingNarratives() throws
}

@MainActor
@Observable
public final class PeriodTrackerStore {
    public var entries: [CycleDayEntry] = []
    public var currentPhase: CyclePhase = .unknown
    public var prediction: CyclePrediction?

    @ObservationIgnored private let healthService: PeriodHealthKitServicing
    @ObservationIgnored private let narrativeRepository: MenstrualNarrativeRepository
    @ObservationIgnored private var lockService: (any PeriodLockContext)?
    @ObservationIgnored private let calendar: Calendar

    /// Hard visibility gate. While this returns false the store is INERT: it performs no cycle
    /// decrypt, no cycle HealthKit read, and holds no cycle plaintext. This is deliberately enforced
    /// here rather than in a `View` body — cycle data is read on ambient paths that no view drives
    /// (cold launch, lock-state changes, the Home tab's health-context refresh), so a UI-level check
    /// would hide the surface while the data kept flowing behind it.
    ///
    /// Injected as a closure because this store is a `nonisolated` leaf with no access to settings,
    /// and because reading it lazily (rather than caching a Bool) means a toggle mid-session takes
    /// effect on the very next call. Defaults to fail-CLOSED (`{ false }`): a store nobody wired must
    /// read nothing, so a construction that races ahead of its wiring can never leak cycle data. The
    /// real derived closure is set in `ContentView`'s launch task before any load call runs; tests
    /// that exercise the visible path inject `{ true }` explicitly.
    @ObservationIgnored public var isVisible: () -> Bool = { false }

    /// Whether the last `loadEntries` ran with a content key, i.e. whether `entries` carry narratives
    /// and a prediction is legitimately derivable. Guards the recompute in `deleteEntry`, which has no
    /// key of its own to check.
    @ObservationIgnored private var lastLoadHadContentKey = false

    public init(
        healthService: PeriodHealthKitServicing,
        narrativeRepository: MenstrualNarrativeRepository? = nil,
        lockService: (any PeriodLockContext)? = nil,
        calendar: Calendar = .current
    ) {
        self.healthService = healthService
        self.narrativeRepository = narrativeRepository ?? MenstrualNarrativeRepository()
        self.lockService = lockService
        self.calendar = calendar
    }

    public func attachLockService(_ lockService: any PeriodLockContext) {
        self.lockService = lockService
    }

    public func loadEntries(unlockedContentKey: SymmetricKey?) async {
        // G1 — the hard gate. Returns BEFORE `loadPeriodEvents`, because that HealthKit read is the
        // larger exposure here: flow, cycle dates, and BBT are ordinary unencrypted Health samples,
        // so withholding the content key alone would still leave "is she bleeding today" resolvable.
        // Scrubs on the way out so flipping to hidden mid-session drops plaintext already resident
        // (up to 240 days of it) rather than merely refusing the next load.
        guard isVisible() else {
            scrubCycleState()
            return
        }
        let range = DateInterval(start: calendar.date(byAdding: .day, value: -240, to: Date()) ?? Date().addingTimeInterval(-240 * 86_400), end: Date())
        do {
            let samples = try await healthService.loadPeriodEvents(in: range)
            let narratives = (try? narrativeRepository.narratives(in: range, contentKey: unlockedContentKey)) ?? []
            let narrativeByUUID = Dictionary(uniqueKeysWithValues: narratives.map { ($0.hkExternalUUID, $0) })
            entries = buildEntries(samples: samples, narratives: narrativeByUUID, range: range)
            currentPhase = currentPhaseFromObservations()
            lastLoadHadContentKey = unlockedContentKey != nil
            if unlockedContentKey != nil {
                prediction = CyclePredictionEngine.predict(from: entries, today: Date(), calendar: calendar)
            } else {
                prediction = nil
            }
        } catch {
            entries = []
            currentPhase = .unknown
            prediction = nil
            lastLoadHadContentKey = false
        }
    }

    /// Drops every piece of cycle plaintext this store holds. Safe to call when already empty.
    public func scrubCycleState() {
        entries = []
        currentPhase = .unknown
        prediction = nil
        lastLoadHadContentKey = false
    }

    public func logEvent(_ event: UserLoggedCycleEvent, unlockedContentKey: SymmetricKey?) async throws -> PeriodLogResult {
        // G2 (write half). Refuse before touching HealthKit: logging while hidden would both write
        // cycle data the user asked Fernlet to leave alone and, via the buffer path below, decrypt
        // the whole pending buffer to re-seal it. Entry points are suppressed in the UI, so reaching
        // here means a caller bypassed the gate.
        guard isVisible() else { throw PeriodTrackingHiddenError() }
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

        if lockService?.isLockConfigured == false {
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

    public func editEvent(_ event: UserLoggedCycleEvent, replacingEntry entry: CycleDayEntry, unlockedContentKey: SymmetricKey?) async throws -> PeriodLogResult {
        // Gate BEFORE the deletes below. This is delete-then-recreate: it drops the old HealthKit
        // samples and the sealed narrative, then re-adds via `logEvent`. If the gate only fired inside
        // `logEvent`, an edit racing a hide would destroy the entry and then throw without writing the
        // replacement — turning the hide gate itself into the cause of data loss.
        guard isVisible() else { throw PeriodTrackingHiddenError() }
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let ownedSamples = entry.samples.filter { $0.sourceRevision.source.bundleIdentifier == bundleID }
        if !ownedSamples.isEmpty {
            try await healthService.delete(ownedSamples)
        }
        if let narrative = entry.narrative {
            try? narrativeRepository.delete(id: narrative.id)
        }
        return try await logEvent(event, unlockedContentKey: unlockedContentKey)
    }

    public func deleteEntry(_ entry: CycleDayEntry) async throws {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let ownedSamples = entry.samples.filter { $0.sourceRevision.source.bundleIdentifier == bundleID }
        if !ownedSamples.isEmpty {
            try await healthService.delete(ownedSamples)
        }
        if let narrative = entry.narrative {
            try? narrativeRepository.delete(id: narrative.id)
        }
        entries.removeAll { $0.id == entry.id }
        // Only recompute a prediction we were entitled to in the first place. This used to run
        // unconditionally, while the identical assignment in `loadEntries` is key-gated — so deleting
        // an entry re-enabled full phase resolution (and the scoring softening that rides on it) with
        // no content key at all, and would have punched straight through the visibility gate.
        if lastLoadHadContentKey {
            prediction = CyclePredictionEngine.predict(from: entries, today: Date(), calendar: calendar)
        } else {
            prediction = nil
        }
        currentPhase = currentPhaseFromObservations()
    }

    public func drainPendingBuffer(contentKey: SymmetricKey) async throws {
        // G2 (drain half). `PendingNarrativeBuffer.loadEntries` unseals with a device key that has
        // nothing to do with the content key, so this path is invisible to key-withholding and must
        // be refused explicitly. Not an error: an unlock while hidden is ordinary, and the buffer is
        // left intact to drain later if the user un-hides.
        guard isVisible() else { return }
        guard let lockService else { return }
        let pending = try lockService.drainPendingNarratives()
        guard !pending.isEmpty else { return }
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
        // Purge only after all inserts succeed, so a partial failure leaves the buffer intact.
        try lockService.purgePendingNarratives()
    }

    public func currentPhaseFromObservations() -> CyclePhase {
        let todayKey = FernletDate.dayKey(for: Date())
        guard let entry = entries.first(where: { $0.dateKey == todayKey }) else { return .unknown }
        let hasActualFlow = entry.menstrualFlowSamples.contains { sample in
            guard let flow = HKCategoryValueVaginalBleeding(rawValue: sample.value) else { return false }
            return flow != .none
        }
        return hasActualFlow ? .menstrual : .unknown
    }

    private func buildEntries(samples: [HKSample], narratives: [String: MenstrualNarrative], range: DateInterval) -> [CycleDayEntry] {
        let grouped = Dictionary(grouping: samples) { FernletDate.dayKey(for: $0.startDate) }
        // Note/symptom-only events have no backing HealthKit sample, so they can't be matched
        // by sample external UUID. Index narratives by their own day key so those entries still
        // surface instead of being silently orphaned in the encrypted store.
        var narrativesByDayKey: [String: [MenstrualNarrative]] = [:]
        for narrative in narratives.values {
            narrativesByDayKey[narrative.dateKey, default: []].append(narrative)
        }
        var result: [CycleDayEntry] = []
        for key in FernletDate.dayKeys(in: range, calendar: calendar) {
            guard let day = FernletDate.date(fromDayKey: key) else { continue }
            let daySamples = grouped[key] ?? []
            let sampleUUIDs = Set(daySamples.compactMap { $0.metadata?[HKMetadataKeyExternalUUID] as? String })
            let narrative = sampleUUIDs.compactMap { narratives[$0] }.first
                ?? narrativesByDayKey[key]?.first { !sampleUUIDs.contains($0.hkExternalUUID) }
            let phase: CyclePhase = daySamples.contains { sample in
                (sample as? HKCategorySample)?.categoryType.identifier == HKCategoryTypeIdentifier.menstrualFlow.rawValue
            } ? .menstrual : .unknown
            result.append(CycleDayEntry(date: day, dateKey: key, samples: daySamples, narrative: narrative, phase: phase))
        }
        return result
    }
}
