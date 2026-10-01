import Observation
import FernletFoundation
import CryptoKit
import Foundation
import HealthKit
import FernletDomainModel
import PrivateStoreCore

/// Everything the user entered in the log-period sheet for one cycle event.
///
/// The write-side input of ``PeriodTrackerStore/logEvent(_:unlockedContentKey:)`` and
/// ``PeriodTrackerStore/editRecord(_:with:unlockedContentKey:)``: it becomes ONE sealed
/// ``CycleRecord`` (both blocks known), and — only while the user's cycle sharing with Apple Health
/// is on — an Apple Health mirror of its clinical fields (period-data design 2026-09-30, §6.3). A plain
/// value type the log and edit sheets bind to.
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

    /// Whether any narrative content exists: a nonempty trimmed note, any symptom, or any custom
    /// scale.
    public var hasNarrative: Bool {
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !symptoms.isEmpty || !customSymptomScales.isEmpty
    }
}

/// What a cycle save did, in two independent halves (period-data design 2026-09-30, §6.3): where
/// Fernlet's own copy is, and what happened to the Apple Health copy.
///
/// The record is kept FIRST — sealed, or held in the pending buffer until the Private tab next opens
/// — and only then mirrored, so a Health refusal can never cost the user the entry.
public nonisolated struct PeriodLogOutcome: Equatable {
    /// Where Fernlet's copy is.
    public enum Storage: Equatable {
        /// Sealed into the store now.
        case sealed
        /// Held in the pending buffer; sealed the next time the Private tab opens (either mode).
        case pendingUntilPrivateOpens
    }

    /// What happened to the Apple Health copy.
    public enum HealthCopy: Equatable {
        /// No copy was made: cycle sharing is off, or the entry has nothing Apple Health holds.
        case notShared
        /// The copy was written (or rewritten, for an edit).
        case written
        /// Cycle sharing is off, and an EDIT removed Fernlet's older copy of the day from Apple Health
        /// (owner question Q1). Only when at least one sample was really deleted.
        case removedStaleCopy
        /// The Apple Health half failed; Fernlet's copy is kept regardless.
        case failed(HealthCopyFailure)
    }

    /// Why an Apple Health copy failed.
    public enum HealthCopyFailure: Equatable {
        /// Apple Health refused Fernlet (share access denied, or never granted, for a type).
        case healthDenied
        /// Apple Health is not available on this device.
        case healthUnavailable
        /// Anything else.
        case other
    }

    /// Where Fernlet's copy is.
    public var storage: Storage
    /// What happened to the Apple Health copy.
    public var healthCopy: HealthCopy

    /// Creates an outcome.
    public init(storage: Storage, healthCopy: HealthCopy) {
        self.storage = storage
        self.healthCopy = healthCopy
    }
}

/// What deleting a day (or one record) did (period-data design 2026-09-30, §6.3, R2-F11). Fernlet's
/// rows go FIRST — a failure there throws and nothing was deleted anywhere — then Fernlet's own
/// Apple Health copies.
public nonisolated struct PeriodDeleteOutcome: Equatable {
    /// What happened to Fernlet's Apple Health copies.
    public enum HealthCopy: Equatable {
        /// There was nothing of Fernlet's in Apple Health for it.
        case none
        /// At least one Fernlet-authored sample was deleted.
        case removed
        /// Fernlet's rows are gone, but its Apple Health copy could not be removed right now.
        case stillInHealth(PeriodLogOutcome.HealthCopyFailure)
    }

    /// How many sealed records were deleted.
    public var removedRecordCount: Int
    /// What happened to the Apple Health copies.
    public var healthCopy: HealthCopy

    /// Creates an outcome.
    public init(removedRecordCount: Int, healthCopy: HealthCopy) {
        self.removedRecordCount = removedRecordCount
        self.healthCopy = healthCopy
    }
}

/// An error a gateway outside this module throws, able to say what it means for an Apple Health
/// copy — how ``PeriodTrackerStore`` classifies the seam's errors without naming the gateway
/// (`HealthKitGateway`'s `HealthKitServiceError` conforms). `nil` means "sharing is off": nothing was
/// meant to be copied, which is not a failure.
public protocol PeriodHealthCopyErrorClassifying: Error {
    /// The failure this error is, or `nil` when it only says cycle sharing is off.
    var periodHealthCopyFailure: PeriodLogOutcome.HealthCopyFailure? { get }
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
public nonisolated enum PeriodFlowLevel: String, CaseIterable, Identifiable, Codable, Sendable {
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
public nonisolated enum PeriodTemperatureUnit: String, CaseIterable, Identifiable, Codable, Sendable {
    case fahrenheit, celsius
    public var id: String { rawValue }
    /// Single-letter unit suffix for the input field.
    public var symbol: String { self == .fahrenheit ? "F" : "C" }
}

/// Observed cervical-mucus quality, mapped onto HealthKit's `HKCategoryValueCervicalMucusQuality`.
///
/// Fertility-signal input on ``UserLoggedCycleEvent``: ``hkValue`` carries it into the HealthKit
/// sample on write and ``CycleDayEntry/cervicalMucusQuality`` recovers it from samples on read.
public nonisolated enum CervicalMucusQuality: String, CaseIterable, Identifiable, Codable, Sendable {
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
public nonisolated enum OvulationTestResult: String, CaseIterable, Identifiable, Codable, Sendable {
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
/// Stored SEALED: symptom flags live in a record's ``CycleNarrativeFields/symptomFlags`` (and, for
/// entries from before the cutover, ``MenstrualNarrative/symptomFlags``), never in Apple Health.
/// `Comparable` by declaration order so a symptom set serializes in a stable, display-matching order.
/// User-defined symptoms travel separately in ``CycleNarrativeFields/customSymptomScales``.
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

/// Narrow Apple Health seam consumed by ``PeriodTrackerStore`` (period-data design 2026-09-30, §7.1).
/// The concrete `HealthKitService` conformance lives in the `HealthKitGateway` module (it uses the
/// service's internals — a wall-legal edge, since the wall only constrains `AIProviders`/`CloudKitSync`).
/// Tests substitute a mock so the store is exercisable without a Health store.
///
/// Apple Health is a MIRROR now: Fernlet's sealed ``CycleRecord`` is the source of truth, a copy of
/// its clinical block goes to Health only while the user's cycle sharing is on, and every Health
/// write passes the gateway's sharing gate. Deletes of Fernlet's own copies are deliberately
/// ungated — removing what Fernlet wrote, at the user's request, must work with sharing off.
public protocol PeriodHealthKitServicing: AnyObject {
    /// Whether a record's clinical block may be copied to Apple Health right now (the gateway's
    /// write-sharing rule for cycle tracking: Health exists, the master switch and the cycle switch
    /// are on).
    func isCycleMirrorEnabled() -> Bool
    /// Whether Fernlet reads cycle samples from Apple Health (the cycle capability was requested and
    /// is switched on). Otherwise the calendar is Fernlet-only and no Health read happens.
    func isCycleHealthReadEnabled() -> Bool
    /// Whether every cycle type has been asked about, so an empty read is an honest "none" — the
    /// legacy sample import's precondition (§8.3 step 1). Never prompts.
    func cycleReadAuthorizationDetermined() async -> Bool
    /// Writes the record's clinical block to Apple Health, every sample stamped with the record id
    /// (`HKMetadataKeyExternalUUID` and ``FernletCycleRecordMirror/recordIDKey``). Gated: refused
    /// while cycle sharing is off or Apple Health has not granted every type. A record with no
    /// clinical field writes nothing.
    func writeMirror(of record: CycleRecord) async throws
    /// Deletes Fernlet's own Apple Health samples carrying this record id. UNGATED, own source only.
    /// Every kind is attempted. A kind Apple Health refuses (share access denied) is REPORTED in the
    /// result, not thrown — it may hold nothing of Fernlet's (review round 1, R2); any other failure
    /// throws once every kind was attempted.
    ///
    /// - Returns: How many samples were deleted (0 on a device without Health) and the refused kinds.
    func deleteMirror(recordID: UUID) async throws -> CycleMirrorDeletion
    /// Deletes these Fernlet-authored samples (the caller passes only Fernlet's own; the conformer
    /// filters again). UNGATED.
    ///
    /// - Returns: How many samples were deleted.
    func deleteFernletAuthored(_ samples: [HKSample]) async throws -> Int
    /// Every cycle sample (any source) starting in `range` — empty, not an error, where nothing is
    /// readable (no Health, or a type Fernlet was never asked to read).
    func loadHealthCycleSamples(in range: DateInterval) async throws -> [HKSample]
    /// Fernlet's OWN cycle samples that carry no ``FernletCycleRecordMirror/recordIDKey`` (the
    /// pre-cutover ones), all time, at most `limit`. THROWS on any error — an empty answer here must
    /// mean "none", never "not asked" (§8.3, R2-F8).
    func loadLegacyFernletCycleSamples(limit: Int) async throws -> [HKSample]
}

/// Narrow lock seam consumed by ``PeriodTrackerStore`` for holding entries while the Private tab is
/// closed. `FernletLockServicing` (in the `FernletLock` module) refines this, so `FernletLockService`
/// is the production conformer — the seam is owned HERE so `PrivateHealthStore` never names the lock
/// module (a one-directional edge; the lock module depends on this one, not the reverse).
///
/// It no longer asks whether a passcode exists (period-data design 2026-09-30, §4.3): the buffer has
/// its own device key and every install now has a hub key to drain into — opened by a passcode or by
/// a tap — so a closed-tab entry is always buffered, never dropped.
public protocol PeriodLockContext: AnyObject {
    /// Seals `payload` into the device-key pending buffer to await the next time Private opens.
    func bufferPendingNarrative(_ payload: PendingNarrativePayload) throws
    /// Unseals and returns every buffered payload WITHOUT clearing the buffer —
    /// ``purgePendingNarratives()`` is the explicit clear, called only once re-sealing succeeded.
    func drainPendingNarratives() throws -> [PendingNarrativePayload]
    /// Destroys the buffered payloads.
    func purgePendingNarratives() throws
}

/// The observable store for the period tracker: Fernlet's sealed cycle records joined with Apple
/// Health's read-only samples, the cycle-visibility gate, and the published entries, phase and
/// prediction (period-data design 2026-09-30, §6.3).
///
/// This is the S3 funnel for cycle data — every cycle read and write in the app goes through it.
/// **Fernlet's sealed ``CycleRecord`` is the source of truth** (through the gated
/// ``CycleRecordStore``), in both passcode modes and whatever the Health switches say. A save SEALS
/// FIRST — into the store while the Private tab is open, or into the pending buffer (via the
/// ``PeriodLockContext`` seam) while it is closed, drained by ``drainPendingBuffer(contentKey:)`` —
/// and only then copies the clinical block to Apple Health, while the user's cycle sharing is on
/// (the ``PeriodHealthKitServicing`` seam). A Health refusal is reported, never fatal. Edits update
/// the record IN PLACE; deletes remove Fernlet's rows first, then Fernlet's Health copies.
///
/// The load-bearing invariant is ``isVisible``, the fail-closed hard gate at the data seam rather
/// than in any view: while hidden the store is INERT — ``loadEntries(unlockedContentKey:)`` scrubs
/// and returns before any read (gate G1), writes, the drain and the legacy import refuse (gate G2) —
/// yet the deletes stay ungated so hiding never blocks deletion. A load needs the live hub key: a
/// keyless load scrubs, because the records are the calendar now.
///
/// `@MainActor` `@Observable`: SwiftUI observes ``entries``/``currentPhase``/``prediction``
/// directly; record and buffer calls are synchronous on the main actor, Health calls are awaited, and
/// every write that follows an await rechecks visibility, the live key and the writer epoch first.
@MainActor
@Observable
public final class PeriodTrackerStore {
    /// One ``CycleDayEntry`` per day of the 240-day load window, oldest first — `[]` while hidden,
    /// after a scrub, or on load failure.
    public var entries: [CycleDayEntry] = []
    /// Today's phase from direct observation only (`menstrual` when actual flow was logged today,
    /// else `unknown`); richer calendar-math phases live in `PeriodContextBridge`.
    public var currentPhase: CyclePhase = .unknown
    /// The latest ``CyclePredictionEngine`` fit — non-`nil` only after a keyed load with enough
    /// usable history.
    public var prediction: CyclePrediction?
    /// The legacy cycle notes this iPhone cannot open (§8.2) — ids only, found by the legacy import
    /// and named on the Cycle page's card. Scrubbed with the rest of the cycle state.
    public internal(set) var unopenableLegacyNarrativeIDs: [UUID] = []

    @ObservationIgnored let healthService: PeriodHealthKitServicing
    /// The gated sealed-record funnel this store composes. Public so the app can install the backup's
    /// mutation hook on it; its visibility gate is this store's (see ``attachVisibilityGate(_:)``).
    @ObservationIgnored public let recordStore: CycleRecordStore
    @ObservationIgnored let narrativeRepository: MenstrualNarrativeRepository
    @ObservationIgnored let importLedger: CycleLegacyImportLedger
    @ObservationIgnored private var lockService: (any PeriodLockContext)?
    @ObservationIgnored let calendar: Calendar
    /// Whether a Health sample was written by Fernlet (by its source). Injectable for tests, which
    /// cannot mint another app's samples.
    @ObservationIgnored let isOwnSample: (HKSample) -> Bool
    /// The held legacy-import task (§8.4), cancelled by ``cancelBackgroundWriters()``.
    @ObservationIgnored var legacyImportTask: Task<Void, Never>?
    /// Moves on every ``cancelBackgroundWriters()``; a write that began under an older epoch never
    /// lands (§8.4). In memory only.
    @ObservationIgnored public private(set) var writerEpoch = 0

    /// R3 cap on the Health samples one load may hold — roughly 20 samples/day over the 240-day
    /// window. A third-party cycle app writing hourly samples would otherwise grow this without bound.
    static let maxLoadedSamples = 5_000
    /// The load window in days.
    static let loadWindowDays = 240

    /// Hard visibility gate. While this returns false the store is INERT: it performs no cycle
    /// decrypt, no cycle Health read, and holds no cycle plaintext. Enforced here rather than in a
    /// `View` body, because cycle data is read on ambient paths no view drives.
    ///
    /// Injected as a closure read lazily, so a toggle mid-session takes effect on the very next call.
    /// Defaults to fail-CLOSED (`{ false }`); the app installs the derived gate in its launch wiring
    /// via ``attachVisibilityGate(_:)`` before any load. Readable everywhere, writable only there.
    @ObservationIgnored public private(set) var isVisible: () -> Bool = { false }

    /// Installs the visibility gate on this store AND on its ``recordStore`` (one gate for both, so
    /// the funnel can never be visible while the store is hidden). Called from the app's launch
    /// wiring before anything loads; until then both refuse.
    ///
    /// - Parameter gate: The derived visibility verdict, re-read on every call.
    public func attachVisibilityGate(_ gate: @escaping () -> Bool) {
        isVisible = gate
        recordStore.attachVisibilityGate(gate)
    }

    /// The live private-hub content key, when the app has wired one — the post-`await` recheck's
    /// second half. Left `nil` where nobody wired it (tests), in which case the caller's key is the
    /// only authority and only the visibility half of the recheck applies.
    @ObservationIgnored private var liveContentKey: (() -> SymmetricKey?)?

    /// Installs the live-content-key provider used by the post-`await` staleness recheck.
    ///
    /// - Parameter provider: Returns the hub's current content key, or `nil` while closed.
    public func attachLiveContentKeyProvider(_ provider: @escaping () -> SymmetricKey?) {
        liveContentKey = provider
    }

    /// Whether the last published load ran with a key, i.e. whether a prediction is derivable. Guards
    /// the recompute after a delete.
    @ObservationIgnored private var lastLoadHadContentKey = false

    /// Creates the store over its seams.
    ///
    /// - Parameters:
    ///   - healthService: The Apple Health seam (production: `HealthKitService`; tests: a mock).
    ///   - narrativeRepository: The legacy narrative store the import reads; `nil` builds one on the
    ///     shared private stack.
    ///   - lockService: The lock seam, or `nil` to wire later via ``attachLockService(_:)``.
    ///   - calendar: Calendar for all day math.
    ///   - recordStore: The sealed-record funnel; `nil` builds one on the shared private stack. It
    ///     must share the narrative repository's store so the import retires narratives atomically.
    ///   - importLedger: The legacy-import markers; `nil` uses standard defaults.
    ///   - ownSampleFilter: Whether a Health sample is Fernlet's; `nil` compares its source bundle id.
    public init(
        healthService: PeriodHealthKitServicing,
        narrativeRepository: MenstrualNarrativeRepository? = nil,
        lockService: (any PeriodLockContext)? = nil,
        calendar: Calendar = .current,
        recordStore: CycleRecordStore? = nil,
        importLedger: CycleLegacyImportLedger? = nil,
        ownSampleFilter: ((HKSample) -> Bool)? = nil
    ) {
        self.healthService = healthService
        self.narrativeRepository = narrativeRepository ?? MenstrualNarrativeRepository()
        self.lockService = lockService
        self.calendar = calendar
        self.recordStore = recordStore ?? CycleRecordStore()
        self.importLedger = importLedger ?? CycleLegacyImportLedger()
        let ownBundleID = Bundle.main.bundleIdentifier ?? ""
        self.isOwnSample = ownSampleFilter ?? { !ownBundleID.isEmpty && $0.sourceRevision.source.bundleIdentifier == ownBundleID }
    }

    /// Wires the lock seam after construction — the lock service and this store are built in
    /// either order at startup, so the app attaches it from its launch task and the period surfaces.
    public func attachLockService(_ lockService: any PeriodLockContext) {
        self.lockService = lockService
    }

    // MARK: - Load

    /// Rebuilds ``entries`` (plus phase and prediction) for the trailing 240 days (§6.3 Load).
    ///
    /// G1: hidden, or no key, scrubs and returns before any read. The Health half is read only while
    /// the cycle capability is on; after that await, visibility and the live key are rechecked. The
    /// records are decrypted, a record whose clinical block is UNKNOWN is completed from its own
    /// Health samples (fill-on-read), Fernlet's samples are hidden where their record's clinical
    /// block is known, and every other sample stays, read-only. Any failure scrubs.
    public func loadEntries(unlockedContentKey: SymmetricKey?) async {
        guard isVisible(), let key = unlockedContentKey else {
            scrubCycleState()
            return
        }
        let range = loadWindow()
        let epoch = writerEpoch
        do {
            let samples = try await readHealthHalf(in: range)
            // G1 (post-await half): the user can hide cycle tracking, or the hub can close, while the
            // Health read is in flight. Decrypting after that would publish cycle plaintext into a
            // session that is no longer entitled to it.
            guard isVisible(), isContentKeyStillLive(key) else {
                scrubCycleState()
                return
            }
            let windowKeys = Set(FernletDate.dayKeys(in: range, calendar: calendar))
            let stored = try recordStore.allRecords(contentKey: key).records.filter { windowKeys.contains($0.dayKey) }
            let ownSamples = samples.filter(isOwnSample)
            let records = fillOnRead(stored, ownSamples: ownSamples, contentKey: key, epoch: epoch)
            publish(records: records, ownSamples: ownSamples, otherSamples: samples.filter { !isOwnSample($0) }, range: range)
        } catch {
            FernletAuditLog.log("period.loadFailed", context: ["error": "\(type(of: error))"])
            scrubCycleState()
        }
    }

    /// The load window: the trailing ``loadWindowDays`` days to now.
    func loadWindow() -> DateInterval {
        let start = calendar.date(byAdding: .day, value: -Self.loadWindowDays, to: Date())
            ?? Date().addingTimeInterval(-Double(Self.loadWindowDays) * 86_400)
        return DateInterval(start: start, end: Date())
    }

    /// The Health half of a load: nothing — and no Health call — unless the cycle capability is on.
    /// R3: capped where it enters the store.
    private func readHealthHalf(in range: DateInterval) async throws -> [HKSample] {
        guard healthService.isCycleHealthReadEnabled() else { return [] }
        return Array(try await healthService.loadHealthCycleSamples(in: range).prefix(Self.maxLoadedSamples))
    }

    /// Whether `key` — captured before an await — is still the hub's live content key. `true` when no
    /// provider is wired; otherwise the hub must hold a key and it must be the same one.
    func isContentKeyStillLive(_ key: SymmetricKey) -> Bool {
        guard let liveContentKey else { return true }
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

    /// Whether a write that began under `epoch` (before an await) may still land: visible, the key
    /// live, no ``cancelBackgroundWriters()`` since, and the task not cancelled (§8.4 step 5).
    func mayWriteAfterAwait(contentKey: SymmetricKey, epoch: Int) -> Bool {
        isVisible() && isContentKeyStillLive(contentKey) && writerEpoch == epoch && !Task.isCancelled
    }

    /// Fill-on-read (§6.3 step 6): a record whose clinical block is UNKNOWN takes it from its own
    /// Fernlet-authored Health samples, written through ``CycleRecordStore/upsertMerged(_:retiringNarrativeIDs:contentKey:)``
    /// under the import's checks. Completes a record; never creates one or resurrects a deleted one
    /// (only ids already stored are touched). A refused write keeps the unfilled records (their
    /// samples then stay on the page).
    ///
    /// The completion is `importedLegacy` whatever the record's own origin — the block IS built
    /// from Fernlet's Health samples — and the merge hands that origin to the completed record
    /// (``CycleRecord/merged(_:_:)``), so a restored note-only record completed here counts its Health
    /// copy when a delete is refused (review round 2, N-1).
    private func fillOnRead(_ records: [CycleRecord], ownSamples: [HKSample], contentKey: SymmetricKey, epoch: Int) -> [CycleRecord] {
        let groups = Dictionary(
            CycleHealthSamples.groupedByRecordID(ownSamples).map { ($0.id, $0.samples) },
            uniquingKeysWith: +
        )
        let completions = records.compactMap { record -> CycleRecord? in
            guard record.clinical == nil, let samples = groups[record.id] else { return nil }
            return CycleHealthSamples.clinicalRecord(id: record.id, samples: samples, origin: .importedLegacy)
        }
        guard !completions.isEmpty, mayWriteAfterAwait(contentKey: contentKey, epoch: epoch) else { return records }
        do {
            _ = try recordStore.upsertMerged(completions, retiringNarrativeIDs: [], contentKey: contentKey)
        } catch {
            FernletAuditLog.log("period.fillOnReadFailed", context: ["error": "\(type(of: error))"])
            return records
        }
        let byID = Dictionary(completions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return records.map { stored in byID[stored.id].map { CycleRecord.merged(stored, $0) } ?? stored }
    }

    /// Publishes a load: Fernlet's samples are hidden where their record's clinical block is known
    /// (the record is authoritative, §6.3 step 7), the entries built, and the phase and prediction
    /// derived.
    private func publish(records: [CycleRecord], ownSamples: [HKSample], otherSamples: [HKSample], range: DateInterval) {
        let authoritative = Set(records.filter { $0.clinical != nil }.map(\.id))
        let shownOwn = ownSamples.filter { !authoritative.contains(CycleHealthSamples.recordID(of: $0)) }
        entries = buildEntries(records: records, fernletSamples: shownOwn, otherSamples: otherSamples, range: range)
        currentPhase = currentPhaseFromObservations()
        lastLoadHadContentKey = true
        prediction = CyclePredictionEngine.predict(from: entries, today: Date(), calendar: calendar)
    }

    /// One ``CycleDayEntry`` per day key in `range`, oldest first: the day's records (newest first,
    /// id as the tiebreak) and its samples by start day.
    private func buildEntries(records: [CycleRecord], fernletSamples: [HKSample], otherSamples: [HKSample], range: DateInterval) -> [CycleDayEntry] {
        let recordsByDay = Dictionary(grouping: records, by: \.dayKey).mapValues { dayRecords in
            dayRecords.sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id.uuidString < $1.id.uuidString }
        }
        let ownByDay = Dictionary(grouping: fernletSamples) { FernletDate.dayKey(for: $0.startDate) }
        let otherByDay = Dictionary(grouping: otherSamples) { FernletDate.dayKey(for: $0.startDate) }
        return FernletDate.dayKeys(in: range, calendar: calendar).compactMap { key in
            guard let day = FernletDate.date(fromDayKey: key) else { return nil }
            return CycleDayEntry(
                date: day,
                dateKey: key,
                records: recordsByDay[key] ?? [],
                fernletHealthSamples: ownByDay[key] ?? [],
                otherHealthSamples: otherByDay[key] ?? []
            )
        }
    }

    /// Drops every piece of cycle plaintext this store holds (and the unopenable-note ids). Safe to
    /// call when already empty.
    public func scrubCycleState() {
        entries.removeAll(keepingCapacity: false)
        currentPhase = .unknown
        prediction = nil
        lastLoadHadContentKey = false
        unopenableLegacyNarrativeIDs.removeAll(keepingCapacity: false)
    }

    // MARK: - Save

    /// Saves one logged cycle event (§6.3 Save): G2, then SEAL FIRST — into the store with a live
    /// key, else into the pending buffer until the Private tab next opens (either passcode mode;
    /// nothing is ever dropped) — then, only while cycle sharing is on and the entry has a clinical
    /// field, the Apple Health mirror. A seal or buffer failure throws with nothing written to
    /// Health; a mirror failure is reported in the outcome and the entry stays saved.
    ///
    /// - Throws: ``PeriodTrackingHiddenError``; `CycleRecordRepositoryError` (nothing to store, store
    ///   full); a seal error; a `PendingNarrativeBufferError`; `FernletLockError` when no lock seam is
    ///   wired for a closed-tab save.
    public func logEvent(_ event: UserLoggedCycleEvent, unlockedContentKey: SymmetricKey?) async throws -> PeriodLogOutcome {
        guard isVisible() else { throw PeriodTrackingHiddenError() }
        let record = CycleRecord(event: event)
        guard record.isStorable else { throw CycleRecordRepositoryError.recordNotStorable(record.id) }
        let storage = try keep(record, contentKey: unlockedContentKey)
        return PeriodLogOutcome(storage: storage, healthCopy: await mirrorNewRecord(record))
    }

    /// Seals `record` now, or buffers it for the next open.
    private func keep(_ record: CycleRecord, contentKey: SymmetricKey?) throws -> PeriodLogOutcome.Storage {
        if let contentKey {
            try recordStore.insert(record, contentKey: contentKey)
            return .sealed
        }
        // No seam wired means nowhere to keep the entry: refuse loudly rather than report a buffer
        // that never happened.
        guard let lockService else { throw FernletLockError.internalError("pending narrative buffer is not wired") }
        try lockService.bufferPendingNarrative(PendingNarrativePayload(
            cycleRecordID: record.id,
            dayKey: record.dayKey,
            cycleRecordJSON: try record.frozenJSON()
        ))
        return .pendingUntilPrivateOpens
    }

    /// The mirror half of a new entry: nothing unless the entry has a clinical field, the store is
    /// still visible and cycle sharing is on.
    private func mirrorNewRecord(_ record: CycleRecord) async -> PeriodLogOutcome.HealthCopy {
        guard record.hasClinicalFields, isVisible(), healthService.isCycleMirrorEnabled() else { return .notShared }
        do {
            try await healthService.writeMirror(of: record)
            return .written
        } catch {
            return Self.healthCopy(after: error)
        }
    }

    /// Updates a stored record IN PLACE (§6.3 Edit) — no delete-then-recreate of the source of truth
    /// — then re-mirrors: with cycle sharing on, Fernlet's Health copy is deleted and rewritten (a
    /// rewrite refused after the delete leaves Health without the day, never a wrong one, and is
    /// reported); with sharing off, Fernlet's older copy is removed (owner question Q1) and the outcome
    /// says so only when a sample was really deleted.
    ///
    /// An edit that leaves an UNKNOWN block empty leaves it unknown (a legacy narrative-only record
    /// edited for its note does not gain a "none" clinical block). And an edit of a record whose
    /// STORED clinical block is unknown never deletes anything from Apple Health: Fernlet never wrote
    /// a mirror for such a record, so every Fernlet sample carrying its id is a pre-cutover sample —
    /// the block's not-yet-imported source, not a stale copy (review round 1, C-U4-R1 / L-U4-1). An
    /// emptied edit is a delete (``deleteRecord(_:)``), never this.
    ///
    /// - Throws: ``PeriodTrackingHiddenError``; `CycleRecordRepositoryError.recordNotFound` /
    ///   `.undecidedRows` / `.recordNotStorable`; a seal error.
    public func editRecord(_ id: UUID, with event: UserLoggedCycleEvent, unlockedContentKey: SymmetricKey) async throws -> PeriodLogOutcome {
        guard isVisible() else { throw PeriodTrackingHiddenError() }
        let page = try recordStore.records(ids: [id], contentKey: unlockedContentKey)
        guard page.transientCount == 0 else { throw CycleRecordRepositoryError.undecidedRows(count: page.transientCount) }
        guard let stored = page.records.first else { throw CycleRecordRepositoryError.recordNotFound(id) }
        let edited = Self.editedRecord(stored, with: event)
        try recordStore.update(edited, contentKey: unlockedContentKey)
        return PeriodLogOutcome(storage: .sealed, healthCopy: await remirrorEdited(edited, replacing: stored))
    }

    /// The record an edit writes: `event` under the stored id and creation time, with an unknown
    /// block kept unknown when the edit leaves it empty. The stored origin is kept — unless the edit
    /// gives an UNKNOWN clinical block fields: that block is the user's own entry, so the record
    /// becomes `logged` (``CycleRecord/combinedOrigin(_:_:)``; review round 2, N-1). A legacy
    /// note-only day the user adds a flow to is not "built from Fernlet's Apple Health samples",
    /// and a refused Health delete of it must not say a copy was left there.
    static func editedRecord(_ stored: CycleRecord, with event: UserLoggedCycleEvent, now: Date = Date()) -> CycleRecord {
        var edited = CycleRecord(event: event, id: stored.id, origin: .logged, now: now)
        if stored.clinical == nil, edited.clinical?.isEmpty == true { edited.clinical = nil }
        if stored.narrative == nil, edited.narrative?.isEmpty == true { edited.narrative = nil }
        edited.origin = CycleRecord.combinedOrigin(stored, edited)
        edited.createdAt = stored.createdAt
        return edited
    }

    /// The mirror half of an edit (see ``editRecord(_:with:unlockedContentKey:)``): `record` is what
    /// was just sealed, `stored` what it replaced.
    ///
    /// - A stored block that is UNKNOWN: nothing is deleted (its Fernlet samples are its source, not
    ///   a copy); with sharing on, a block the edit made known is written beside them.
    /// - Otherwise the old copy is deleted first. A kind Apple Health refused to delete counts only
    ///   when ``refusalMayLeaveCopy(of:refused:sharing:)`` says a copy can really be there (R2) —
    ///   and with sharing on the rewrite is always attempted after it, its own share check deciding.
    ///   An unexpected delete failure is reported and nothing is rewritten (an old copy beside a new
    ///   one would be a wrong copy).
    private func remirrorEdited(_ record: CycleRecord, replacing stored: CycleRecord) async -> PeriodLogOutcome.HealthCopy {
        guard isVisible() else { return .notShared }
        let sharing = healthService.isCycleMirrorEnabled()
        guard stored.clinical != nil else { return sharing ? await mirrorNewRecord(record) : .notShared }
        let deletion: CycleMirrorDeletion
        do {
            deletion = try await healthService.deleteMirror(recordID: record.id)
        } catch {
            return Self.healthCopy(after: error)
        }
        let copyMayRemain = Self.refusalMayLeaveCopy(of: stored, refused: deletion.refusedKinds, sharing: sharing)
        guard sharing else {
            if copyMayRemain { return .failed(.healthDenied) }
            return deletion.deletedCount > 0 ? .removedStaleCopy : .notShared
        }
        let rewrite = await mirrorNewRecord(record)
        if case .failed = rewrite { return rewrite }
        return copyMayRemain ? .failed(.healthDenied) : rewrite
    }

    /// Whether Apple Health refusing to delete `refused` may have left a Fernlet copy of `record`
    /// there — the only refusal worth telling the user about (review round 1, R2). HealthKit reports
    /// share access never granted exactly as it reports access taken away after a copy was written,
    /// so the record decides:
    ///
    /// - Only a kind the record's copy could hold counts (``CycleMirrorSampleKind/possibleCopyKinds(of:)``):
    ///   a refused kind the entry never set left nothing behind.
    /// - A record whose clinical block was BUILT from Fernlet's Apple Health samples (the legacy
    ///   import, fill-on-read, "Keep in Fernlet": `CycleRecord.clinicalBlockIsFromFernletHealthSamples`)
    ///   had a copy there by construction. The origin can say so because a clinical block supplied
    ///   to an unknown slot brings its own origin (review round 2, N-1): a flow the user added to a
    ///   legacy note-only day makes it `logged`, and a restored note-only record completed from its
    ///   samples becomes `importedLegacy`.
    /// - Any other record — an UNKNOWN block included, whose pre-cutover samples exist only if they
    ///   were written while sharing was on — had a copy only if it was copied with cycle sharing on;
    ///   with sharing off now, a refusal most likely means the access was never granted, and saying
    ///   "Apple Health still has Fernlet's copy" on every edit and delete would be false.
    static func refusalMayLeaveCopy(of record: CycleRecord, refused: Set<CycleMirrorSampleKind>, sharing: Bool) -> Bool {
        guard !refused.isDisjoint(with: CycleMirrorSampleKind.possibleCopyKinds(of: record)) else { return false }
        return record.clinicalBlockIsFromFernletHealthSamples || sharing
    }

    /// The Health-copy outcome a mirror error means: "sharing is off" is no failure.
    static func healthCopy(after error: any Error) -> PeriodLogOutcome.HealthCopy {
        guard let failure = healthCopyFailure(for: error) else { return .notShared }
        return .failed(failure)
    }

    /// Classifies a Health error; `nil` when it only says cycle sharing is off.
    static func healthCopyFailure(for error: any Error) -> PeriodLogOutcome.HealthCopyFailure? {
        if let classified = error as? PeriodHealthCopyErrorClassifying { return classified.periodHealthCopyFailure }
        guard let healthError = error as? HKError else { return .other }
        switch healthError.code {
        case .errorAuthorizationDenied, .errorAuthorizationNotDetermined: return .healthDenied
        case .errorHealthDataUnavailable, .errorHealthDataRestricted: return .healthUnavailable
        default: return .other
        }
    }

    // MARK: - Delete

    /// Deletes a day (§6.3 Delete): Fernlet's rows FIRST, keyless and ungated, in one save — a failure
    /// there throws and nothing was deleted anywhere — then Fernlet's Apple Health copies: each
    /// record's mirror, plus the day's Fernlet-authored samples that have no record (an earlier
    /// install's or the other iPhone's copies). Health refusing is reported, not thrown: the user
    /// asked to delete the entry and Fernlet's copy is the source of truth (§6.3).
    ///
    /// Deliberately not visibility-gated — hiding must never block deletion.
    public func deleteDay(_ entry: CycleDayEntry) async throws -> PeriodDeleteOutcome {
        try await deleteRecords(entry.records, removingCopiesOf: entry.records, orphanCopies: entry.fernletHealthSamples)
    }

    /// Deletes one record — the emptied edit (§6.3 Edit). Same order and outcome as ``deleteDay(_:)``,
    /// with one difference: a record whose clinical block is UNKNOWN keeps its Fernlet samples in
    /// Apple Health. Fernlet never mirrored such a record, so those samples are pre-cutover data the
    /// user never saw in this sheet — the legacy import or "Keep in Fernlet" brings them in later, and
    /// the day's confirmed Delete removes them (review round 1, C-U4-R1). Emptying a note must not
    /// silently delete flow history behind it.
    public func deleteRecord(_ record: CycleRecord) async throws -> PeriodDeleteOutcome {
        try await deleteRecords([record], removingCopiesOf: record.clinical == nil ? [] : [record], orphanCopies: [])
    }

    /// The shared delete: rows first, then the local state, then Health.
    private func deleteRecords(
        _ records: [CycleRecord],
        removingCopiesOf mirrored: [CycleRecord],
        orphanCopies: [HKSample]
    ) async throws -> PeriodDeleteOutcome {
        let ids = records.map(\.id)
        let removed = try recordStore.delete(ids: ids)
        dropFromEntries(ids: Set(ids))
        let healthCopy = await removeHealthCopies(of: mirrored, orphanCopies: orphanCopies)
        return PeriodDeleteOutcome(removedRecordCount: removed, healthCopy: healthCopy)
    }

    /// Fernlet's Apple Health copies of deleted records, plus `orphanCopies`. Every record is
    /// attempted. `.stillInHealth` only when something of Fernlet's can really be left there: a delete
    /// that failed outright, or a refused kind ``refusalMayLeaveCopy(of:refused:sharing:)`` counts
    /// (R2) — a refused kind the entry never held left nothing behind.
    private func removeHealthCopies(of records: [CycleRecord], orphanCopies: [HKSample]) async -> PeriodDeleteOutcome.HealthCopy {
        let sharing = healthService.isCycleMirrorEnabled()
        var deleted = 0
        var failure: PeriodLogOutcome.HealthCopyFailure?
        for record in records {  // R2: bounded by the day's records.
            do {
                let deletion = try await healthService.deleteMirror(recordID: record.id)
                deleted += deletion.deletedCount
                if Self.refusalMayLeaveCopy(of: record, refused: deletion.refusedKinds, sharing: sharing) {
                    failure = failure ?? .healthDenied
                }
            } catch {
                FernletAuditLog.log("period.healthCopyDeleteFailed", context: ["error": "\(type(of: error))"])
                failure = failure ?? Self.healthCopyFailure(for: error) ?? .other
            }
        }
        if !orphanCopies.isEmpty {
            do {
                deleted += try await healthService.deleteFernletAuthored(orphanCopies)
            } catch {
                FernletAuditLog.log("period.healthCopyDeleteFailed", context: ["error": "\(type(of: error))"])
                failure = failure ?? Self.healthCopyFailure(for: error) ?? .other
            }
        }
        if let failure { return .stillInHealth(failure) }
        return deleted > 0 ? .removed : .none
    }

    /// Removes deleted records from the published entries and recomputes local state. The prediction
    /// is recomputed only when the last load was entitled to one (a keyed load).
    private func dropFromEntries(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        entries = entries.map { entry in
            var trimmed = entry
            trimmed.records.removeAll { ids.contains($0.id) }
            return trimmed
        }
        prediction = lastLoadHadContentKey ? CyclePredictionEngine.predict(from: entries, today: Date(), calendar: calendar) : nil
        currentPhase = currentPhaseFromObservations()
    }

    // MARK: - Health-only Fernlet days (§7.3)

    /// "Keep in Fernlet": adopts a Health-only Fernlet day — one record per group of Fernlet's samples
    /// (`id` = the samples' record id, clinical known, narrative unknown, origin `adoptedFromHealth`)
    /// through the one merge write. Gated (it writes).
    ///
    /// - Returns: How many records were inserted, completed or replaced.
    public func keepHealthOnlyDay(_ entry: CycleDayEntry, contentKey: SymmetricKey) throws -> Int {
        guard isVisible() else { throw PeriodTrackingHiddenError() }
        let records = CycleHealthSamples.groupedByRecordID(entry.fernletHealthSamples).compactMap { group in
            CycleHealthSamples.clinicalRecord(id: group.id, samples: group.samples, origin: .adoptedFromHealth)
        }
        guard !records.isEmpty else { return 0 }
        let result = try recordStore.upsertMerged(records, retiringNarrativeIDs: [], contentKey: contentKey)
        return result.inserted + result.merged + result.replaced
    }

    /// "Delete from Apple Health": removes a Health-only Fernlet day's copies. Ungated.
    ///
    /// - Returns: How many samples were deleted.
    public func deleteHealthOnlyCopies(_ entry: CycleDayEntry) async throws -> Int {
        guard !entry.fernletHealthSamples.isEmpty else { return 0 }
        return try await healthService.deleteFernletAuthored(entry.fernletHealthSamples)
    }

    // MARK: - Drain

    /// Seals every buffered entry into the store (§6.3 Drain) through ONE merge write, then purges the
    /// buffer — so a partial drain (or a failed purge) re-drains without duplicates.
    ///
    /// A v2 payload is a whole record; a v1 payload (a narrative buffered before the cutover) becomes
    /// a narrative-only record under its legacy external id, so it later merges with that entry's
    /// legacy Health samples. G2: a silent no-op while hidden — the buffer unseals under a device key
    /// the content-key gate never sees — and the buffer stays intact for a later un-hide. A payload
    /// that will not decode throws before anything is written, leaving the buffer intact.
    public func drainPendingBuffer(contentKey: SymmetricKey) async throws {
        guard isVisible(), let lockService else { return }
        let pending = try lockService.drainPendingNarratives()
        guard !pending.isEmpty else { return }
        let now = Date()
        let records = try pending.map { try Self.record(fromPending: $0, now: now) }
        _ = try recordStore.upsertMerged(records, retiringNarrativeIDs: [], contentKey: contentKey)
        try lockService.purgePendingNarratives()
    }

    /// The record one buffered payload carries.
    static func record(fromPending payload: PendingNarrativePayload, now: Date) throws -> CycleRecord {
        if let json = payload.cycleRecordJSON { return try CycleRecord(frozenJSON: json) }
        // The lossy seam, as the sealed narrative column has always been: `PeriodSymptom`'s raw values
        // are FROZEN tokens, so this `compactMap` never drops a symptom in practice.
        let symptoms = try payload.symptomFlagsBytes.map { try JSONDecoder().decode([String].self, from: $0) } ?? []
        let scales = try payload.customSymptomScalesBytes.map { try JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        return CycleRecord(
            id: CycleLegacyIdentity.recordID(forLegacyExternalID: payload.hkExternalUUID),
            dayKey: payload.dateKey,
            loggedAt: FernletDate.date(fromDayKey: payload.dateKey) ?? now,
            clinical: nil,
            narrative: CycleNarrativeFields(
                note: payload.noteBytes.flatMap { String(data: $0, encoding: .utf8) },
                symptomFlags: symptoms.compactMap(PeriodSymptom.init(rawValue:)),
                customSymptomScales: scales,
                updatedAt: now
            ),
            origin: .importedLegacy,
            createdAt: now,
            updatedAt: now
        )
    }

    // MARK: - Writers

    /// Stops the background writers before "Delete everything" (§8.4): cancels the held legacy
    /// import and moves ``writerEpoch``, so neither the import nor a fill-on-read that began before
    /// this call can write afterwards.
    public func cancelBackgroundWriters() {
        legacyImportTask?.cancel()
        legacyImportTask = nil
        writerEpoch &+= 1
    }

    /// The phase derivable from today's direct observation alone: `menstrual` when today records
    /// actual bleeding, `unknown` otherwise. Needs no prediction, so it is safe on every path.
    public func currentPhaseFromObservations() -> CyclePhase {
        let todayKey = FernletDate.dayKey(for: Date())
        guard let entry = entries.first(where: { $0.dateKey == todayKey }) else { return .unknown }
        return entry.hasActualBleedingFlow ? .menstrual : .unknown
    }
}
