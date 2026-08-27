import Observation
import FernletFoundation
import CryptoKit
import Foundation
import HealthKit
import FernletDomainModel
import PrivateStoreCore

/// Everything the user entered in the log-period sheet for one cycle event, before it is split
/// between HealthKit and the sealed store.
///
/// The write-side counterpart of ``CycleDayEntry``: ``PeriodTrackerStore/logEvent(_:unlockedContentKey:)``
/// sends the clinical fields (flow, temperature, mucus, ovulation test, bleeding and cycle-start
/// flags) to HealthKit through ``PeriodHealthKitServicing`` and routes the narrative fields
/// (``note``, ``symptoms``, ``customSymptomScales``) into the sealed ``MenstrualNarrative`` — or,
/// while locked, into the pending buffer. A plain value type the log and edit sheets bind to.
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

    /// Whether any sealed-store content exists: a nonempty trimmed note, any symptom, or any custom
    /// scale. `false` means logging this event writes HealthKit only.
    public var hasNarrative: Bool {
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !symptoms.isEmpty || !customSymptomScales.isEmpty
    }
}

/// What happened to a logged cycle event's narrative half.
///
/// Returned by ``PeriodTrackerStore/logEvent(_:unlockedContentKey:)`` (and the edit path) so the
/// sheet can tell the user when their note was deferred or lost rather than sealed immediately.
public nonisolated enum PeriodLogResult: Equatable {
    /// The HealthKit samples saved and the narrative, if any, was sealed immediately.
    case saved
    /// The app was locked: the narrative sits sealed in the pending buffer until the next unlock.
    case savedWithBufferedNarrative
    /// No lock is configured, so there was no safe place to keep the narrative — it was dropped.
    case savedWithDroppedNarrative
}

/// Thrown when a cycle write is attempted while cycle tracking is hidden. Reaching this means a
/// caller bypassed a suppressed entry point, so it is a programmer error surfaced as a throw rather
/// than a user-facing state — the UI never offers the affordance while hidden.
public nonisolated struct PeriodTrackingHiddenError: Error, Equatable {
    public init() {}
}

/// Observed menstrual-flow level, round-trippable to HealthKit's `HKCategoryValueVaginalBleeding`.
///
/// The user-facing flow vocabulary of the log sheet and calendar. Distinct from
/// ``PredictedFlowLevel`` (forecast-only, includes spotting): this one maps onto the HealthKit
/// category values via ``hkValue`` on write, and ``CycleDayEntry/flowLevel`` recovers it from
/// samples on read.
public nonisolated enum PeriodFlowLevel: String, CaseIterable, Identifiable, Codable {
    case none, light, medium, heavy, unspecified
    public var id: String { rawValue }
    /// Display label for pickers and the calendar detail.
    public var title: String { rawValue == "none" ? "None" : rawValue.capitalized }
    /// The matching `HKCategoryValueVaginalBleeding` raw value for writing the HealthKit sample.
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

/// Unit the user entered basal body temperature in.
///
/// Sheet-level input state carried on ``UserLoggedCycleEvent`` so the HealthKit gateway knows how
/// to interpret the entered value; reads come back normalized through
/// ``CycleDayEntry/basalBodyTemperatureFahrenheit``.
public nonisolated enum PeriodTemperatureUnit: String, CaseIterable, Identifiable, Codable {
    case fahrenheit, celsius
    public var id: String { rawValue }
    /// Single-letter unit suffix for the input field.
    public var symbol: String { self == .fahrenheit ? "F" : "C" }
}

/// Observed cervical-mucus quality, mapped onto HealthKit's `HKCategoryValueCervicalMucusQuality`.
///
/// Fertility-signal input on ``UserLoggedCycleEvent``: ``hkValue`` carries it into the HealthKit
/// sample on write and ``CycleDayEntry/cervicalMucusQuality`` recovers it from samples on read.
public nonisolated enum CervicalMucusQuality: String, CaseIterable, Identifiable, Codable {
    case dry, sticky, creamy, watery, eggWhite
    public var id: String { rawValue }
    /// Display label for pickers and the calendar detail.
    public var title: String { self == .eggWhite ? "Egg White" : rawValue.capitalized }
    /// The matching `HKCategoryValueCervicalMucusQuality` raw value for the HealthKit sample.
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

/// Ovulation-test outcome, mapped onto HealthKit's `HKCategoryValueOvulationTestResult`.
///
/// Input on ``UserLoggedCycleEvent``; `positive` deliberately maps to `luteinizingHormoneSurge` on
/// write, and ``CycleDayEntry/ovulationTestResult`` recovers the value from samples on read.
public nonisolated enum OvulationTestResult: String, CaseIterable, Identifiable, Codable {
    case negative, positive, indeterminate
    public var id: String { rawValue }
    /// Display label for pickers and the calendar detail.
    public var title: String { rawValue.capitalized }
    /// The matching `HKCategoryValueOvulationTestResult` raw value for the HealthKit sample.
    public var hkValue: Int {
        switch self {
        case .negative: HKCategoryValueOvulationTestResult.negative.rawValue
        case .positive: HKCategoryValueOvulationTestResult.luteinizingHormoneSurge.rawValue
        case .indeterminate: HKCategoryValueOvulationTestResult.indeterminate.rawValue
        }
    }
}

/// The fixed vocabulary of built-in period symptoms a narrative can flag.
///
/// Stored SEALED: symptom flags live in ``MenstrualNarrative/symptomFlags`` as an encrypted column,
/// never in HealthKit. `Comparable` by declaration order so the symptom set on
/// ``UserLoggedCycleEvent`` serializes in a stable, display-matching order. User-defined symptoms
/// travel separately in ``MenstrualNarrative/customSymptomScales``.
public nonisolated enum PeriodSymptom: String, CaseIterable, Identifiable, Codable, Comparable, Sendable {
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
    /// Orders by declaration position. R5: a case missing from `allCases` (an `@available` filter, a
    /// future refactor) sorts last instead of trapping — the two force-unwrapped `firstIndex(of:)`
    /// calls this replaces were assertions with no message and no recovery.
    public static func < (lhs: PeriodSymptom, rhs: PeriodSymptom) -> Bool {
        let order = allCases
        return (order.firstIndex(of: lhs) ?? order.count) < (order.firstIndex(of: rhs) ?? order.count)
    }
}

/// The menstrual-cycle phase resolved for a day.
///
/// A RAW sealed-side type on purpose: it lives here rather than in `FernletDomainModel` because the
/// walled `AIProviders` module imports the domain model, and exposing the phase there would defeat
/// the `PeriodContextBridge` abstraction — the bridge converts phases into the abstract period
/// signals scoring consumes, and only those cross the S3 wall. Inside the protected side it appears
/// on ``CycleDayEntry/phase`` and ``PeriodTrackerStore/currentPhase``; `unknown` is the fail-quiet
/// default whenever neither observation nor prediction can place the user.
public nonisolated enum CyclePhase: String, CaseIterable, Identifiable {
    case menstrual, follicular, ovulatory, luteal, unknown
    public var id: String { rawValue }
    /// Display label for the phase chip.
    public var title: String { rawValue.capitalized }
}

/// One calendar day of cycle data: the day's HealthKit samples joined with its sealed narrative and
/// a resolved phase.
///
/// The read-side unit ``PeriodTrackerStore`` publishes — one entry per day of the 240-day load
/// window, present whether or not anything was observed that day. The computed accessors decode the
/// raw `HKSample`s on demand so views and the prediction engine never touch HealthKit values
/// directly. Identified by its day key, so a collection holds at most one entry per day.
public nonisolated struct CycleDayEntry: Identifiable, Equatable {
    public var id: String { dateKey }
    public var date: Date
    /// Canonical `yyyy-MM-dd` day key; doubles as the identity.
    public var dateKey: String
    /// Raw HealthKit samples starting on this day — all sources, not just Fernlet's own.
    public var samples: [HKSample]
    /// The sealed narrative joined to this day (by sample external UUID, else by day key), or `nil`
    /// when none exists or the store was loaded without a content key.
    public var narrative: MenstrualNarrative?
    /// Phase resolved at load time: `menstrual` when a flow sample exists, else `unknown` — richer
    /// calendar-math resolution happens downstream in `PeriodContextBridge`.
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

    /// Whether anything at all was logged on this day (a sample or a narrative).
    public var hasObservedEvent: Bool { !samples.isEmpty || narrative != nil }
    /// The day's samples filtered to the menstrual-flow category.
    public var menstrualFlowSamples: [HKCategorySample] {
        samples.compactMap { $0 as? HKCategorySample }.filter { $0.categoryType.identifier == HKCategoryTypeIdentifier.menstrualFlow.rawValue }
    }
    /// True when this day carries any HealthKit menstrual-flow sample recording actual bleeding
    /// (a decodable `HKCategoryValueVaginalBleeding` above `.none`). The single definition of an
    /// "observed bleeding day" — the store's published phase and the bridge's phase resolution
    /// both key off this, so the two can never drift.
    public var hasActualBleedingFlow: Bool {
        menstrualFlowSamples.contains { sample in
            guard let flow = HKCategoryValueVaginalBleeding(rawValue: sample.value) else { return false }
            return flow != .none
        }
    }
    /// Observed flow decoded from the day's first menstrual-flow sample, or `nil` with no sample.
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
    /// Display string for the observed flow ("No flow" when no sample exists).
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
    /// Whether the first flow sample carries the `HKMetadataKeyMenstrualCycleStart` flag.
    public var isCycleStart: Bool {
        menstrualFlowSamples.first?.metadata?[HKMetadataKeyMenstrualCycleStart] as? Bool ?? false
    }
    /// Whether any sample records intermenstrual (between-period) bleeding.
    public var hasIntermenstrualBleeding: Bool {
        samples.contains { ($0 as? HKCategorySample)?.categoryType.identifier == HKCategoryTypeIdentifier.intermenstrualBleeding.rawValue }
    }
    /// Mucus quality decoded from the day's first cervical-mucus sample, if any.
    public var cervicalMucusQuality: CervicalMucusQuality? {
        guard let sample = samples.compactMap({ $0 as? HKCategorySample }).first(where: { $0.categoryType.identifier == HKCategoryTypeIdentifier.cervicalMucusQuality.rawValue }) else { return nil }
        return CervicalMucusQuality.allCases.first { $0.hkValue == sample.value }
    }
    /// Test outcome decoded from the day's first ovulation-test sample, if any.
    public var ovulationTestResult: OvulationTestResult? {
        guard let sample = samples.compactMap({ $0 as? HKCategorySample }).first(where: { $0.categoryType.identifier == HKCategoryTypeIdentifier.ovulationTestResult.rawValue }) else { return nil }
        return OvulationTestResult.allCases.first { $0.hkValue == sample.value }
    }
    /// The day's first basal-body-temperature reading converted to Fahrenheit, if any.
    public var basalBodyTemperatureFahrenheit: Double? {
        guard let sample = samples.compactMap({ $0 as? HKQuantitySample }).first(where: { $0.quantityType.identifier == HKQuantityTypeIdentifier.basalBodyTemperature.rawValue }) else { return nil }
        return sample.quantity.doubleValue(for: .degreeFahrenheit())
    }
}

/// Narrow HealthKit seam consumed by ``PeriodTrackerStore``. The concrete `HealthKitService`
/// conformance lives in the `HealthKitGateway` module (it uses HealthKitService internals — a
/// wall-legal edge, since the wall only constrains `AIProviders`/`CloudKitSync`); this module only
/// needs the three cycle operations and never refines the fat `HealthKitServicing` protocol.
/// Tests substitute a mock so the store is exercisable without a Health store.
public protocol PeriodHealthKitServicing: AnyObject {
    /// Writes the event's clinical fields as HealthKit samples stamped with `externalUUID` — the
    /// key ``MenstrualNarrative/hkExternalUUID`` later joins on.
    /// - Returns: The samples that were saved.
    func savePeriodEvent(_ event: UserLoggedCycleEvent, externalUUID: UUID) async throws -> [HKSample]
    /// All cycle-relevant samples (from any source app) starting in `dateRange`.
    func loadPeriodEvents(in dateRange: DateInterval) async throws -> [HKSample]
    /// Deletes the given samples; callers pre-filter to Fernlet-owned samples, since HealthKit
    /// refuses deletes of other apps' data.
    func delete(_ samples: [HKSample]) async throws
}

/// Narrow lock seam consumed by ``PeriodTrackerStore`` for buffering narratives while the app is
/// locked. `FernletLockServicing` (in the `FernletLock` module) refines this, so `FernletLockService`
/// is the production conformer — the seam is owned HERE so `PrivateHealthStore` never names the lock
/// module (a one-directional edge; the lock module depends on this one, not the reverse).
public protocol PeriodLockContext: AnyObject {
    /// Whether an app lock exists at all. Without one there is no buffer key and no later unlock to
    /// drain at, so a locked-state narrative is dropped rather than buffered.
    var isLockConfigured: Bool { get }
    /// Seals `payload` into the device-key pending buffer to await the next unlock.
    func bufferPendingNarrative(_ payload: PendingNarrativePayload) throws
    /// Unseals and returns every buffered payload WITHOUT clearing the buffer —
    /// ``purgePendingNarratives()`` is the explicit clear, called only once re-sealing succeeded.
    func drainPendingNarratives() throws -> [PendingNarrativePayload]
    /// Destroys the buffered payloads.
    func purgePendingNarratives() throws
}

/// The observable store for the period tracker: joins HealthKit cycle samples with sealed
/// narratives, enforces the cycle-visibility gate, and publishes entries, current phase, and
/// prediction.
///
/// This is the S3 funnel for cycle data — every cycle read and write in the app goes through it.
/// Splits each event across two stores: clinical samples (flow, temperature, mucus, ovulation
/// tests) live in HealthKit behind the ``PeriodHealthKitServicing`` seam (conformed to by
/// `HealthKitService` in `HealthKitGateway`), while notes/symptoms are sealed into
/// ``MenstrualNarrativeRepository``. While locked, narratives detour through the pending buffer via
/// the ``PeriodLockContext`` seam (`FernletLockService`) and are re-sealed on the next unlock by
/// ``drainPendingBuffer(contentKey:)``. ``CyclePredictionEngine`` supplies ``prediction``; the
/// period calendar, Home surface, and `PeriodContextBridge` (the sanctioned scoring egress) are the
/// consumers.
///
/// The load-bearing invariant is ``isVisible``, the fail-closed hard gate at the data seam rather
/// than in any view: while hidden the store is INERT — ``loadEntries(unlockedContentKey:)`` scrubs
/// and returns before the HealthKit read (gate G1), writes and the buffer drain refuse (gate G2) —
/// yet ``deleteEntry(_:)`` stays ungated so hiding never blocks deletion. Orthogonally, the content
/// key gates the *narrative* and *prediction* half: a keyless load still lists samples but carries
/// no decrypted notes and no prediction.
///
/// `@MainActor` `@Observable`: SwiftUI observes ``entries``/``currentPhase``/``prediction``
/// directly; repository and buffer calls are synchronous on the main actor, HealthKit calls are
/// awaited. Load failures scrub to the empty state rather than surfacing stale cycle data.
@MainActor
@Observable
public final class PeriodTrackerStore {
    /// One ``CycleDayEntry`` per day of the 240-day load window, oldest first — `[]` while hidden,
    /// after a scrub, or on load failure.
    public var entries: [CycleDayEntry] = []
    /// Today's phase from direct observation only (`menstrual` when actual flow was logged today,
    /// else `unknown`); richer calendar-math phases live in `PeriodContextBridge`.
    public var currentPhase: CyclePhase = .unknown
    /// The latest ``CyclePredictionEngine`` fit — non-`nil` only when the last load ran with a
    /// content key and enough usable history existed.
    public var prediction: CyclePrediction?

    @ObservationIgnored private let healthService: PeriodHealthKitServicing
    @ObservationIgnored private let narrativeRepository: MenstrualNarrativeRepository
    @ObservationIgnored private var lockService: (any PeriodLockContext)?
    @ObservationIgnored private let calendar: Calendar

    /// R3 cap on the HealthKit samples one load may hold — roughly 20 samples/day over the 240-day
    /// window. A third-party cycle app writing hourly samples would otherwise grow this without bound.
    private static let maxLoadedSamples = 5_000
    /// R3 cap on the number of user-authored custom symptom entries sealed with one event.
    private static let maxCustomSymptoms = 40
    /// R3 cap on the length of one custom symptom's name.
    private static let maxCustomSymptomNameLength = 40

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
    /// real derived closure is installed in `ContentView`'s launch task, via ``attachVisibilityGate(_:)``,
    /// before any load call runs; tests that exercise the visible path install `{ true }` explicitly.
    ///
    /// R6: readable everywhere, writable only through ``attachVisibilityGate(_:)`` — a gate any
    /// holder of the store could reassign in passing is not a gate; installing one is a deliberate
    /// wiring act with a name.
    @ObservationIgnored public private(set) var isVisible: () -> Bool = { false }

    /// Installs the visibility gate. Called from the app's launch wiring (and by the sealed-backup
    /// coordinator on its own instance) before anything loads; until then the store refuses.
    ///
    /// - Parameter gate: The derived visibility verdict, re-read on every call.
    public func attachVisibilityGate(_ gate: @escaping () -> Bool) {
        isVisible = gate
    }

    /// The live private-hub content key, when the app has wired one.
    ///
    /// The second half of the post-`await` recheck in ``loadEntries(unlockedContentKey:)``: the key a
    /// caller passed in was live when the load STARTED, and a lock can engage during the HealthKit
    /// await. Wired by the app to `FernletLockService.contentKey(for: .privateHub)`; left `nil` where
    /// nobody wired it (tests, and any caller with no lock at all), in which case the caller's key is
    /// the only authority there is and only the visibility half of the recheck applies.
    @ObservationIgnored private var liveContentKey: (() -> SymmetricKey?)?

    /// Installs the live-content-key provider used by the post-`await` staleness recheck.
    ///
    /// - Parameter provider: Returns the hub's current content key, or `nil` while locked.
    public func attachLiveContentKeyProvider(_ provider: @escaping () -> SymmetricKey?) {
        liveContentKey = provider
    }

    /// Whether the last `loadEntries` ran with a content key, i.e. whether `entries` carry narratives
    /// and a prediction is legitimately derivable. Guards the recompute in `deleteEntry`, which has no
    /// key of its own to check.
    @ObservationIgnored private var lastLoadHadContentKey = false

    /// Creates the store over its two persistence seams.
    ///
    /// - Parameters:
    ///   - healthService: The HealthKit seam (production: `HealthKitService`; tests: a mock).
    ///   - narrativeRepository: Sealed narrative store; `nil` builds one on the shared private stack.
    ///   - lockService: The lock seam, or `nil` to wire later via ``attachLockService(_:)``.
    ///   - calendar: Calendar for all day math.
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

    /// Wires the lock seam after construction — the lock service and this store are built in
    /// either order at startup, so the app attaches it from its launch task and the period surfaces.
    public func attachLockService(_ lockService: any PeriodLockContext) {
        self.lockService = lockService
    }

    /// Rebuilds ``entries`` (plus phase and prediction) for the trailing 240 days.
    ///
    /// Gate G1: while hidden this scrubs any resident plaintext and returns BEFORE the HealthKit
    /// read (see the inline note — the samples are the larger exposure). With a `nil` key the
    /// entries still carry samples but no narratives and no prediction. Any load error scrubs to
    /// the empty state rather than leaving stale cycle data visible.
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
            // R3: HealthKit is external input — cap the sample array where it enters the store.
            let samples = Array(try await healthService.loadPeriodEvents(in: range).prefix(Self.maxLoadedSamples))
            // G1 (post-await half). The gate above was checked BEFORE the HealthKit await, and that
            // await is arbitrarily long: the user can hide cycle tracking, or the app can lock, while
            // it is in flight. Re-check both before the decrypt below, not just before assigning —
            // otherwise a load begun while visible+unlocked decrypts narratives with a key the hub has
            // since dropped and publishes 240 days of cycle plaintext into a locked, hidden session.
            guard isVisible() else {
                scrubCycleState()
                return
            }
            guard isContentKeyStillLive(unlockedContentKey) else {
                scrubCycleState()
                return
            }
            let narratives = loadNarratives(in: range, contentKey: unlockedContentKey)
            // R5: `uniqueKeysWithValues` traps on a duplicate `hkExternalUUID`, a state a partial
            // buffer drain can genuinely produce. Newest row wins instead of aborting the process.
            let narrativeByUUID = Dictionary(
                narratives.map { ($0.hkExternalUUID, $0) },
                uniquingKeysWith: { lhs, rhs in lhs.updatedAt >= rhs.updatedAt ? lhs : rhs }
            )
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

    /// Whether `key` — captured by the caller before the HealthKit await — is still the hub's live
    /// content key, i.e. whether decrypting with it now is still legitimate.
    ///
    /// `true` for a keyless load (there is nothing to go stale) and when no provider is wired (the
    /// caller's key is then the only authority in the process). Otherwise the hub must still hold a
    /// key and it must be the SAME key: a re-key or a lock during the await both mean this load's
    /// authorization expired mid-flight, and the recovery is to scrub rather than publish.
    private func isContentKeyStillLive(_ key: SymmetricKey?) -> Bool {
        guard let key, let liveContentKey else { return true }
        guard let live = liveContentKey() else {
            FernletAuditLog.log("period.loadAbandoned", context: ["reason": "lockedDuringLoad"])
            return false
        }
        guard live == key else {
            FernletAuditLog.log("period.loadAbandoned", context: ["reason": "contentKeyChanged"])
            return false
        }
        return true
    }

    /// Fetches the sealed narratives for `range`, distinguishing "no notes" from "notes unavailable".
    ///
    /// A fetch/decrypt failure is audit-logged and rendered as an empty set so the samples still
    /// render — R7: the `?? []` this replaces made a Core Data failure indistinguishable from a user
    /// who had simply written nothing.
    private func loadNarratives(in range: DateInterval, contentKey: SymmetricKey?) -> [MenstrualNarrative] {
        do {
            return try narrativeRepository.narratives(in: range, contentKey: contentKey)
        } catch {
            FernletAuditLog.log("period.narrativeLoadFailed", context: ["error": "\(error)"])
            return []
        }
    }

    /// Drops every piece of cycle plaintext this store holds. Safe to call when already empty.
    public func scrubCycleState() {
        entries.removeAll(keepingCapacity: false)
        currentPhase = .unknown
        prediction = nil
        lastLoadHadContentKey = false
    }

    /// Saves one user-logged cycle event: clinical fields to HealthKit, narrative to the sealed store.
    ///
    /// Gate G2 (write half): throws ``PeriodTrackingHiddenError`` while hidden. The narrative lands
    /// in the sealed store when the content key is available, in the lock service's pending buffer
    /// while locked, and is dropped when no lock is configured — the result says which happened so
    /// the sheet can tell the user. The note is trimmed and capped at 1000 characters before sealing.
    ///
    /// - Returns: What happened to the narrative half; see ``PeriodLogResult``.
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
            customSymptomScales: Self.boundedCustomScales(event.customSymptomScales)
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

    /// Caps the user-authored custom symptom dictionary at ``maxCustomSymptoms`` entries and each
    /// key at ``maxCustomSymptomNameLength`` characters, alongside the note's 1000-character cap.
    /// R3: this dictionary is unbounded user input that is sealed into the store and the pending
    /// buffer. Truncated keys that collide keep the larger value, so the merge cannot trap.
    private static func boundedCustomScales(_ scales: [String: Int]) -> [String: Int] {
        let bounded = scales
            .sorted { $0.key < $1.key }
            .prefix(maxCustomSymptoms)
            .map { (String($0.key.prefix(maxCustomSymptomNameLength)), $0.value) }
        return Dictionary(bounded, uniquingKeysWith: { lhs, rhs in max(lhs, rhs) })
    }

    /// Replaces an existing entry: deletes its Fernlet-owned samples and sealed narrative, then
    /// re-logs `event` through ``logEvent(_:unlockedContentKey:)``. Gated up front so a hide racing
    /// an edit cannot delete without re-creating (see the inline note). Samples written by other
    /// apps are left untouched.
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
            do {
                try narrativeRepository.delete(id: narrative.id)
            } catch {
                // Recovery: continue to the re-log. Throwing here would destroy the entry without
                // writing its replacement — the hazard the gate comment above describes — so the
                // superseded row is named in the log instead of vanishing silently.
                FernletAuditLog.log(
                    "period.narrativeDeleteFailedOnEdit",
                    context: ["id": narrative.id.uuidString, "error": "\(error)"]
                )
            }
        }
        return try await logEvent(event, unlockedContentKey: unlockedContentKey)
    }

    /// Deletes one day's Fernlet-owned samples and sealed narrative, then recomputes local state.
    /// Deliberately not visibility-gated — hiding must never block deletion — and the prediction
    /// recompute is key-gated (see the inline note) so a delete can never resurrect a prediction
    /// the load was not entitled to.
    public func deleteEntry(_ entry: CycleDayEntry) async throws {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let ownedSamples = entry.samples.filter { $0.sourceRevision.source.bundleIdentifier == bundleID }
        if !ownedSamples.isEmpty {
            try await healthService.delete(ownedSamples)
        }
        if let narrative = entry.narrative {
            do {
                try narrativeRepository.delete(id: narrative.id)
            } catch {
                // Recovery: report. A deletion the UI claims happened must not leave the user's
                // sealed note on disk, so the caller surfaces the failure instead of "day removed".
                FernletAuditLog.log("period.narrativeDeleteFailed", context: ["error": "\(error)"])
                throw error
            }
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

    /// Re-seals every pending-buffer narrative into the sealed store after an unlock.
    ///
    /// Gate G2 (drain half): a silent no-op while hidden — the buffer unseals under a device key
    /// the content-key gate never sees, so this path must refuse explicitly, and the buffer stays
    /// intact for a later un-hide. The buffer is purged only after every insert succeeds, so a
    /// partial failure leaves it drainable on the next unlock.
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
            // Idempotent drain. The purge below runs only after EVERY insert succeeds, so a partial
            // drain (or a failed purge) leaves payloads both buffered and inserted; re-inserting them
            // on the next unlock would create duplicate `hkExternalUUID` rows. Skip what is already
            // sealed instead.
            if try narrativeRepository.narrative(forHKUUID: payload.hkExternalUUID, contentKey: contentKey) != nil {
                continue
            }
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

    /// The phase derivable from today's direct observation alone: `menstrual` when an actual
    /// (non-none) flow sample exists today, `unknown` otherwise. Needs no prediction and no content
    /// key, so it is safe on every path.
    public func currentPhaseFromObservations() -> CyclePhase {
        let todayKey = FernletDate.dayKey(for: Date())
        guard let entry = entries.first(where: { $0.dateKey == todayKey }) else { return .unknown }
        return entry.hasActualBleedingFlow ? .menstrual : .unknown
    }

    /// Assembles one ``CycleDayEntry`` per day key in `range`, attaching each day's samples and its
    /// narrative — matched by sample external UUID first, then by day key (see the inline note on
    /// note-only events with no backing sample).
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
