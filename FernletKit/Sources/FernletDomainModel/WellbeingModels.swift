// WellbeingModels.swift
// Split out of Models.swift (SPM carve-up §5c). Day, health-context, journal, sleep, hygiene, goals, and daily-score models.

import Foundation

/// One planned recipe on a day's meal plan, carrying the meal slot it was planned for (2026-08-21
/// redesign, FOOD-35: "each planned recipe logs against the meal type it was planned for").
///
/// The typed successor to a bare id in ``FernletDay/plannedRecipeIDs``. The meal type persists as
/// its FROZEN ``MealType`` rawValue token in `mealTypeToken` — a plain optional `String`, so a
/// token only a newer build knows (or a legacy entry with none) decodes without failure and
/// round-trips untouched; read the typed slot through ``mealType``, which is `nil` for both. The
/// struct is additive and tolerant: `recipeID` is the only required key, mirroring the
/// `plannedRecipeIDs` element it upgrades.
public nonisolated struct PlannedMealEntry: Codable, Hashable, Identifiable, Sendable {
    /// The planned recipe's id (either recipe store half). A dangling id — recipe since deleted —
    /// resolves to nothing at render time and is dropped silently, exactly like the legacy list.
    public var recipeID: UUID
    /// The FROZEN persisted ``MealType`` rawValue token, or nil for a legacy/untyped entry.
    /// Kept as a `String` so an unknown token from a newer build survives a round trip here.
    public var mealTypeToken: String?

    /// Keyed by the recipe id — the plan holds at most one entry per recipe per day.
    public var id: UUID { recipeID }

    /// The typed meal slot, or nil when the entry carries no (or an unrecognised) token.
    public var mealType: MealType? {
        mealTypeToken.flatMap(MealType.init(rawValue:))
    }

    public init(recipeID: UUID, mealType: MealType?) {
        self.recipeID = recipeID
        self.mealTypeToken = mealType?.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recipeID = try container.decode(UUID.self, forKey: .recipeID)
        mealTypeToken = try container.decodeIfPresent(String.self, forKey: .mealTypeToken)
    }
}

/// One calendar day's diary: meals, workouts, plans, journals, sleep, water, care, and HealthKit
/// context.
///
/// The per-day unit of persistence (a `DayRecord` row on the synced store), keyed by its
/// `yyyy-MM-dd` `date`. `hygiene` decodes tolerantly with parked tokens; `plannedRecipeIDs` is an
/// additive F3 field with a documented strip-on-write landmine for un-updated peers (see the
/// decode note), and `plannedMeals` is its typed 2026-08-21 successor (recipe id + meal slot),
/// written in parallel with it and read new-first via ``plannedMealEntries``.
/// ``hasLoggedContent`` is the single shared definition of "a day with something on
/// it", feeding both fresh-install detection and the coin economy's active-day accrual — a bare
/// HealthKit sync stamp deliberately does NOT count.
public nonisolated struct FernletDay: Codable {
    public var date: String
    public var meals: [Meal]
    public var workouts: [Workout]
    public var plannedWorkouts: [PlannedWorkout]
    public var journals: [JournalEntry]
    public var sleep: SleepLog?
    public var bottleCount: Int
    public var hygiene: Set<HygieneItem>
    /// Raw `hygiene` tokens this build's `HygieneItem` doesn't know — items added by a NEWER build
    /// on another device. Parked (and re-encoded) instead of thrown on, so a newer device's day
    /// can't latch this one into decode-failure recovery via the blob (or silently vanish as a
    /// dropped DayRecord row), and so a save here can't strip them from the synced day. A build
    /// that knows a parked token re-adopts it on decode (`EnumDecodeCompat`).
    public var unknownHygieneTokens: [String] = []
    public var completedPersonalCareTaskIDs: Set<String>
    public var healthContext: HealthDailyContext?
    /// Recipe ids the user assigned to this day in the F3 weekly shopping-list planner. Mirrors the
    /// `plannedWorkouts` precedent EXACTLY: it is a per-day-row field that rides `DayRecord.payloadData`
    /// via Codable — NO Core Data schema change, NO CloudKit deploy, per-row sync for free — and is a
    /// tolerant `decodeIfPresent` addition (absent on every day written before F3 → `[]`, never a decode
    /// failure). The plan is the only persisted grocery-list state; the list itself stays a one-shot
    /// share artifact. Render degrades gracefully: a deleted recipe leaves a DANGLING id here and the
    /// planner/aggregator drop it silently (no such recipe in either store), so no cleanup pass is owed.
    public var plannedRecipeIDs: [UUID]
    /// The typed meal plan (2026-08-21, FOOD-35): each entry pairs a planned recipe id with the
    /// meal slot it was planned for, so logging a planned recipe never asks the user twice.
    ///
    /// Additive-optional FOREVER, following the `plannedRecipeIDs`/`steps` pattern exactly:
    /// `decodeIfPresent`, absent (`nil`) on every day written before the field existed and on rows
    /// re-encoded by an un-updated peer — never a decode failure. Writers keep `plannedRecipeIDs`
    /// populated IN PARALLEL (write both) so an older build's planner keeps rendering the plan;
    /// readers go through ``plannedMealEntries``, which prefers this field and falls back per-id to
    /// the legacy list. The same per-day strip-on-write landmine documented on `plannedRecipeIDs`
    /// applies here, with the same bounded acceptance.
    public var plannedMeals: [PlannedMealEntry]?

    public init(
        date: String,
        meals: [Meal] = [],
        workouts: [Workout] = [],
        plannedWorkouts: [PlannedWorkout] = [],
        journals: [JournalEntry] = [],
        sleep: SleepLog? = nil,
        bottleCount: Int = 0,
        hygiene: Set<HygieneItem> = [],
        completedPersonalCareTaskIDs: Set<String>? = nil,
        healthContext: HealthDailyContext? = nil,
        plannedRecipeIDs: [UUID] = [],
        plannedMeals: [PlannedMealEntry]? = nil
    ) {
        self.date = date
        self.meals = meals
        self.workouts = workouts
        self.plannedWorkouts = plannedWorkouts
        self.journals = journals
        self.sleep = sleep
        self.bottleCount = bottleCount
        self.hygiene = hygiene
        self.completedPersonalCareTaskIDs = completedPersonalCareTaskIDs ?? Set(hygiene.map(\.rawValue))
        self.healthContext = healthContext
        self.plannedRecipeIDs = plannedRecipeIDs
        self.plannedMeals = plannedMeals
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        meals = try container.decodeIfPresent([Meal].self, forKey: .meals) ?? []
        workouts = try container.decodeIfPresent([Workout].self, forKey: .workouts) ?? []
        plannedWorkouts = try container.decodeIfPresent([PlannedWorkout].self, forKey: .plannedWorkouts) ?? []
        journals = try container.decodeIfPresent([JournalEntry].self, forKey: .journals) ?? []
        sleep = try container.decodeIfPresent(SleepLog.self, forKey: .sleep)
        bottleCount = try container.decodeIfPresent(Int.self, forKey: .bottleCount) ?? 0
        // Tolerant set decode: a strict `Set<HygieneItem>` throws on the first member only a NEWER
        // build knows (decodeIfPresent defaults only on an absent KEY), bricking the store via the
        // blob or dropping this day's row. Known members become the typed set; unknown ones park.
        let hygieneSplit = try container.decodeTolerantEnumSet(
            HygieneItem.self, forKey: .hygiene, parkedTokensKey: .unknownHygieneTokens)
        hygiene = hygieneSplit.known
        unknownHygieneTokens = hygieneSplit.unknownTokens
        // The legacy fallback derives task ids from the hygiene raw values; include parked tokens so
        // a newer build's item keeps its completion mark through a legacy-shaped day.
        completedPersonalCareTaskIDs = try container.decodeIfPresent(Set<String>.self, forKey: .completedPersonalCareTaskIDs)
            ?? Set(hygiene.map(\.rawValue)).union(unknownHygieneTokens)
        healthContext = try container.decodeIfPresent(HealthDailyContext.self, forKey: .healthContext)
        // Tolerant + additive (mirrors `plannedWorkouts`): absent on every day written before F3 and on
        // rows re-encoded by an un-updated peer → `[]`, never a decode failure. Synthesized `encode`
        // writes it back into the day row's payload so it syncs per-row like every other day field.
        // LANDMINE (accepted, per-day-scoped): an un-updated paired device does not merely fail to READ
        // this field — its synthesized `encode` re-writes the day row WITHOUT the key, so any day such a
        // device touches loses its plan permanently. That is DATA loss (the user's meal plan), not just
        // provenance loss. It's bounded to the days the old device edits and matches the `plannedWorkouts`
        // precedent, so it's tolerated until every device is updated — but note it's a strip-on-write, not
        // a decode default.
        plannedRecipeIDs = try container.decodeIfPresent([UUID].self, forKey: .plannedRecipeIDs) ?? []
        // Additive-optional, tolerant of absence FOREVER (2026-08-21): nil on every pre-field day
        // and on rows an un-updated peer re-encoded. Written in parallel with `plannedRecipeIDs`;
        // read new-first through `plannedMealEntries`.
        plannedMeals = try container.decodeIfPresent([PlannedMealEntry].self, forKey: .plannedMeals)
    }

    /// The day's meal plan, read new-first: every typed ``plannedMeals`` entry, then a slotless
    /// entry for each legacy `plannedRecipeIDs` id the typed list doesn't already cover.
    ///
    /// This is the ONE read surface for the plan — it makes a mixed-state day (legacy ids written
    /// by an older build alongside typed entries written by this one) render whole instead of
    /// whichever field happened to be read.
    public var plannedMealEntries: [PlannedMealEntry] {
        let typed = plannedMeals ?? []
        let typedIDs = Set(typed.map(\.recipeID))
        let legacy = plannedRecipeIDs
            .filter { !typedIDs.contains($0) }
            .map { PlannedMealEntry(recipeID: $0, mealType: nil) }
        return typed + legacy
    }

    /// True when the day carries *any* recorded content — a logged meal/workout/planned-workout/journal,
    /// sleep, water, hygiene/personal-care, or a HealthKit context that actually holds data. The single
    /// definition of "a day the user has something on", shared by fresh-install detection
    /// (`SealedBackupCoordinator`) and the coin economy's active-day accrual (`DiaryStore.activeDayKeys`,
    /// which feeds the coin ledger) so the two can't drift.
    ///
    /// NOTE: a *content-free* `healthContext` does NOT count. HealthKit sync stamps a non-nil context
    /// (just a `syncedAt`, every metric nil) onto a day merely because integration is enabled and the
    /// app was opened — so a bare `healthContext != nil` would award "active day" coins for nothing.
    /// Requiring `healthContext.hasContent` keeps "active day" meaning a day with real data on it.
    public var hasLoggedContent: Bool {
        !(meals.isEmpty && workouts.isEmpty && plannedWorkouts.isEmpty && journals.isEmpty
          && sleep == nil && hygiene.isEmpty && unknownHygieneTokens.isEmpty
          && completedPersonalCareTaskIDs.isEmpty && plannedRecipeIDs.isEmpty
          && bottleCount == 0 && !(healthContext?.hasContent ?? false))
    }
}

/// The day's imported HealthKit context, grouped by domain (activity, body, cycle, mindfulness,
/// intimate).
///
/// `merge` keeps the freshest non-nil group per sync; ``hasContent`` distinguishes real data from
/// the bare `syncedAt` stamp HealthKit sync writes whenever integration is merely enabled.
public nonisolated struct HealthDailyContext: Codable, Equatable {

    public init(syncedAt: Date = Date(), activity: HealthActivitySummary? = nil, body: HealthBodyContext? = nil, cycle: HealthCycleContext? = nil, mindfulness: HealthMindfulnessContext? = nil, intimate: HealthIntimateContext? = nil) {
        self.syncedAt = syncedAt
        self.activity = activity
        self.body = body
        self.cycle = cycle
        self.mindfulness = mindfulness
        self.intimate = intimate
    }
    public var syncedAt = Date()
    public var activity: HealthActivitySummary?
    public var body: HealthBodyContext?
    public var cycle: HealthCycleContext?
    public var mindfulness: HealthMindfulnessContext?
    public var intimate: HealthIntimateContext?

    public mutating func merge(_ other: HealthDailyContext) {
        syncedAt = other.syncedAt
        activity = other.activity ?? activity
        body = other.body ?? body
        cycle = other.cycle ?? cycle
        mindfulness = other.mindfulness ?? mindfulness
        intimate = other.intimate ?? intimate
    }

    /// True when the context holds at least one real metric — i.e. it is more than the bare `syncedAt`
    /// stamp that HealthKit sync writes whenever integration is enabled. Each sub-struct is all-optional
    /// with an all-nil parameterless init, so "has a value" is "differs from the empty instance".
    /// `syncedAt` is deliberately ignored: a sync timestamp alone is not user/health content.
    public var hasContent: Bool {
        (activity.map { $0 != HealthActivitySummary() } ?? false)
            || (body.map { $0 != HealthBodyContext() } ?? false)
            || (cycle.map { $0 != HealthCycleContext() } ?? false)
            || (mindfulness.map { $0 != HealthMindfulnessContext() } ?? false)
            || (intimate.map { $0 != HealthIntimateContext() } ?? false)
    }
}

/// Daily activity metrics from HealthKit: steps, active energy, exercise minutes.
///
/// All optional — absent means HealthKit had no sample, never zero. Retained on
/// ``DailyHealthScore`` for scoring audit.
public nonisolated struct HealthActivitySummary: Codable, Equatable {

    public init(steps: Int? = nil, activeEnergyKilocalories: Double? = nil, exerciseMinutes: Double? = nil) {
        self.steps = steps
        self.activeEnergyKilocalories = activeEnergyKilocalories
        self.exerciseMinutes = exerciseMinutes
    }
    public var steps: Int?
    public var activeEnergyKilocalories: Double?
    public var exerciseMinutes: Double?
}

/// Daily body metrics from HealthKit: sleep hours/stages, resting heart rate, HRV.
///
/// Feeds the sleep-quality refinement and the opt-in stress-awareness baseline comparison; all
/// optional so absent data never reads as zero.
public nonisolated struct HealthBodyContext: Codable, Equatable {

    public init(sleepHours: Double? = nil, restingHeartRateBPM: Double? = nil, heartRateVariabilityMS: Double? = nil, sleepStages: SleepStagesData? = nil) {
        self.sleepHours = sleepHours
        self.restingHeartRateBPM = restingHeartRateBPM
        self.heartRateVariabilityMS = heartRateVariabilityMS
        self.sleepStages = sleepStages
    }
    public var sleepHours: Double?
    public var restingHeartRateBPM: Double?
    public var heartRateVariabilityMS: Double?
    /// Per-stage sleep breakdown from HealthKit (`HKCategoryValueSleepAnalysis`), when a wearable
    /// supplies it. Optional: many users only have an `inBed`/`asleepUnspecified` total.
    public var sleepStages: SleepStagesData?
}

/// Sleep-stage durations (minutes) for a single night, derived from HealthKit sleep-analysis
/// samples. All fields optional — stage data is only available from devices that classify sleep
/// (e.g. Apple Watch). `totalAsleepMinutes` is the merged asleep total used to derive stage ratios.
public nonisolated struct SleepStagesData: Codable, Equatable {

    public init(deepMinutes: Double? = nil, coreMinutes: Double? = nil, remMinutes: Double? = nil, awakeMinutes: Double? = nil, totalAsleepMinutes: Double? = nil) {
        self.deepMinutes = deepMinutes
        self.coreMinutes = coreMinutes
        self.remMinutes = remMinutes
        self.awakeMinutes = awakeMinutes
        self.totalAsleepMinutes = totalAsleepMinutes
    }
    public var deepMinutes: Double?
    public var coreMinutes: Double?
    public var remMinutes: Double?
    public var awakeMinutes: Double?
    public var totalAsleepMinutes: Double?

    /// True when at least one classified asleep stage (deep/core/REM) is present — i.e. the data
    /// is richer than a bare asleep total and worth feeding into the sleep-quality refinement.
    public var hasStageBreakdown: Bool {
        (deepMinutes ?? 0) > 0 || (coreMinutes ?? 0) > 0 || (remMinutes ?? 0) > 0
    }
}

/// Non-sensitive cycle sync metadata: flow-event count and latest event time.
///
/// Deliberately coarse — the clinical cycle samples stay in HealthKit and the sealed store (S3);
/// this only tells the diary that cycle data exists for the day.
public nonisolated struct HealthCycleContext: Codable, Equatable {

    public init(menstrualFlowEventCount: Int? = nil, latestCycleEventAt: Date? = nil) {
        self.menstrualFlowEventCount = menstrualFlowEventCount
        self.latestCycleEventAt = latestCycleEventAt
    }
    public var menstrualFlowEventCount: Int?
    public var latestCycleEventAt: Date?
}

/// Minutes of mindful sessions HealthKit recorded for the day.
///
/// Used for gentle reflection copy; never a score input.
public nonisolated struct HealthMindfulnessContext: Codable, Equatable {

    public init(mindfulSessionMinutes: Double? = nil) {
        self.mindfulSessionMinutes = mindfulSessionMinutes
    }
    public var mindfulSessionMinutes: Double?
}

/// A bare count of intimate-activity events for the day.
///
/// A count only, by design — notes and details live sealed in the private store, and the whole
/// field is age- and visibility-gated upstream before it is ever written.
public nonisolated struct HealthIntimateContext: Codable, Equatable {

    public init(eventCount: Int? = nil) {
        self.eventCount = eventCount
    }
    public var eventCount: Int?
}

/// The computed daily wellbeing score with its full audit trail.
///
/// Stores not just the `score` and the derived ``CompanionState`` but everything that produced
/// them: per-component sub-scores, the exact (sickness-adjusted) ``ScoringWeights`` vector, the
/// sickness override flag, the period-phase label, and the HealthKit contexts that fed scoring.
/// `companionState` decodes tolerantly; recomputing the day constructs a fresh record, which
/// naturally drops any parked token.
public nonisolated struct DailyHealthScore: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var dateKey: String
    public var score: Double
    public var companionState: CompanionState {
        didSet { unknownCompanionStateToken = nil }
    }
    /// Unknown `companionState` token from a newer build, parked instead of thrown on (a throw in
    /// the blob's `dailyScores` bricks the whole store into read-only recovery). Recomputing the
    /// score on this device constructs a fresh record, which naturally drops the token.
    public var unknownCompanionStateToken: String? = nil
    public var daySummaryText: String?
    public var computedAt: Date
    /// Per-component sub-scores (journal/meal/workout/sleep/hydration/hygiene) that produced `score`.
    public var componentScores: [String: Double]?
    /// The exact (sickness-adjusted) weight vector applied for this day.
    public var weightVector: ScoringWeights?
    /// Whether the day was scored with the sickness override active.
    public var sicknessOverride: Bool?
    /// Optional menstrual-cycle phase label for this day (populated once the period bridge lands).
    public var periodPhase: String?
    /// The HealthKit activity context (steps/active-energy/exercise-minutes) that fed scoring this
    /// day, retained for audit/inspection. Nil when HealthKit was unavailable or disabled.
    public var healthActivityContext: HealthActivitySummary?
    /// The HealthKit body context (sleep hours/stages, resting HR, HRV) that fed scoring this day,
    /// retained for audit/inspection. Nil when HealthKit was unavailable or disabled.
    public var healthBodyContext: HealthBodyContext?

    public init(id: UUID = UUID(), dateKey: String, score: Double, companionState: CompanionState, daySummaryText: String? = nil, computedAt: Date, componentScores: [String: Double]? = nil, weightVector: ScoringWeights? = nil, sicknessOverride: Bool? = nil, periodPhase: String? = nil, healthActivityContext: HealthActivitySummary? = nil, healthBodyContext: HealthBodyContext? = nil) {
        self.id = id; self.dateKey = dateKey; self.score = score; self.companionState = companionState; self.daySummaryText = daySummaryText; self.computedAt = computedAt
        self.componentScores = componentScores; self.weightVector = weightVector; self.sicknessOverride = sicknessOverride; self.periodPhase = periodPhase
        self.healthActivityContext = healthActivityContext; self.healthBodyContext = healthBodyContext
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        dateKey = try c.decode(String.self, forKey: .dateKey)
        score = try c.decode(Double.self, forKey: .score)
        // Required key (was strict `decode` pre-compat): absence is corruption, not a newer build.
        let stateSplit = try c.decodeTolerantRequiredEnum(
            CompanionState.self, forKey: .companionState,
            parkedTokenKey: .unknownCompanionStateToken, default: .okay)
        companionState = stateSplit.value
        unknownCompanionStateToken = stateSplit.parkedToken
        daySummaryText = try c.decodeIfPresent(String.self, forKey: .daySummaryText)
        computedAt = try c.decodeIfPresent(Date.self, forKey: .computedAt) ?? Date()
        componentScores = try c.decodeIfPresent([String: Double].self, forKey: .componentScores)
        weightVector = try c.decodeIfPresent(ScoringWeights.self, forKey: .weightVector)
        sicknessOverride = try c.decodeIfPresent(Bool.self, forKey: .sicknessOverride)
        periodPhase = try c.decodeIfPresent(String.self, forKey: .periodPhase)
        healthActivityContext = try c.decodeIfPresent(HealthActivitySummary.self, forKey: .healthActivityContext)
        healthBodyContext = try c.decodeIfPresent(HealthBodyContext.self, forKey: .healthBodyContext)
    }
}

/// One journal entry (or one-tap mood check-in) for a day.
///
/// Sensitive by default: for entries whose ids are sealed, ``strippedIfSealed(in:)`` is the single
/// definition of "strip before the synced blob" — a FAIL-CLOSED memberwise reconstruct that drops
/// text/emotions and, by construction, any future field until it is consciously allowlisted (S3).
/// `isQuickMood` is the positive discriminator between a genuine empty check-in and a sealed entry
/// whose text was stripped; `tag` decodes tolerantly with a parked token.
public nonisolated struct JournalEntry: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var text: String
    public var tag: FeelingTag {
        didSet { unknownTagToken = nil }
    }
    /// Unknown `tag` token from a newer build (a throw in the blob's `previousJournals` bricks the
    /// store; in a day it drops the DayRecord row). Frozen to `.neutral`, parked, re-adopted by a
    /// build that knows it; an explicit local tag edit clears it (`EnumDecodeCompat`).
    public var unknownTagToken: String? = nil
    public var date = Date()
    public var emotions: [String] = []
    /// True only for one-tap tag-only mood check-ins (created by `FernletStore.logQuickMood`). This is
    /// the POSITIVE discriminator that distinguishes a genuine empty-text check-in from a sealed real
    /// journal entry whose text was stripped to "" for the synced blob (both otherwise look identical:
    /// empty text, empty emotions). Optional/defaulted so old builds ignore it and a pre-marker entry
    /// decodes to `false` (treated as a sealed entry, never falsely labelled a check-in). Carries no
    /// content — only the fact that the entry was a mood tap — so syncing it leaks nothing.
    public var isQuickMood: Bool = false

    public init(id: UUID = UUID(), text: String, tag: FeelingTag, date: Date = Date(), emotions: [String] = [], isQuickMood: Bool = false) {
        self.id = id; self.text = text; self.tag = tag; self.date = date; self.emotions = emotions; self.isQuickMood = isQuickMood
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        // Required key (was strict `decode` pre-compat): absence is corruption, not a newer build.
        let tagSplit = try c.decodeTolerantRequiredEnum(
            FeelingTag.self, forKey: .tag, parkedTokenKey: .unknownTagToken, default: .neutral)
        tag = tagSplit.value
        unknownTagToken = tagSplit.parkedToken
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        emotions = try c.decodeIfPresent([String].self, forKey: .emotions) ?? []
        isQuickMood = try c.decodeIfPresent(Bool.self, forKey: .isQuickMood) ?? false
    }

    /// Returns a copy with `text` + `emotions` cleared when this entry's `id` is in `sealedIDs`
    /// (its plaintext lives in the encrypted narrative store); otherwise returns `self` unchanged.
    ///
    /// The single definition of "strip a sealed journal entry before it is persisted to the
    /// (potentially iCloud-synced) blob" — shared by `FernletSnapshot.forStorage` (the today/snapshot
    /// path) and `DiaryStore.mutatePastDay` (the past-day write path) so sealed journal text can never
    /// reach the synced store regardless of which save path runs (the S3 privacy wall).
    public func strippedIfSealed(in sealedIDs: Set<UUID>) -> JournalEntry {
        guard sealedIDs.contains(id) else { return self }
        // FAIL-CLOSED memberwise reconstruct (S3): the stripped copy is built from an explicit
        // allowlist of non-sensitive fields, so any FUTURE stored field added to JournalEntry is
        // dropped from the sealed strip BY CONSTRUCTION until someone consciously adds it here.
        // Do NOT convert this to copy-and-clear (`var stripped = self`) — that inverts the posture
        // to fail-open and would let a later sensitive field (e.g. an attachment ref) ride into the
        // iCloud-synced blob in plaintext for sealed entries.
        // isQuickMood is preserved (a check-in is never sealed, so this stays false — but keep it
        // explicit so the discriminator survives any future path that seals a marked entry).
        var stripped = JournalEntry(id: id, text: "", tag: tag, date: date, emotions: [], isQuickMood: isQuickMood)
        // Carry the parked unknown-tag token (non-sensitive: a newer build's enum raw value)
        // through the strip so a sealed re-save can't clobber the newer device's tag choice.
        // Safe post-init: the memberwise init assigns `tag` during initialization (property
        // observers don't fire there, so the park isn't cleared by `tag`'s didSet), and the side
        // channel itself has no observer.
        stripped.unknownTagToken = unknownTagToken
        return stripped
    }
}

/// The six-step mood tag on a journal entry (bright … hard).
///
/// Also the memory category for ``MemoryNote``'s journal capture; unknown tags from newer builds
/// freeze to `.neutral` and park.
public nonisolated enum FeelingTag: String, Codable, CaseIterable, Identifiable, Sendable {
    case bright, good, neutral, quiet, tired, hard

    public var id: String { rawValue }

    /// The localized mood-chip label.
    ///
    /// Was `rawValue.capitalized`, which cannot be localized at all — it is the token wearing a
    /// coat of paint. `rawValue` is FROZEN: it is the value stored in the sealed journal column,
    /// the ``MemoryNote`` category, the parked-token side channel's vocabulary, AND the
    /// accessibility identifier the UI-test suite selects mood chips by. Only this property is
    /// text a person reads.
    public var label: String {
        switch self {
        case .bright:
            String(localized: "feeling.bright", defaultValue: "Bright", bundle: .module,
                   comment: "Journal mood tag: the brightest of the six moods")
        case .good:
            String(localized: "feeling.good", defaultValue: "Good", bundle: .module,
                   comment: "Journal mood tag: a good day")
        case .neutral:
            String(localized: "feeling.neutral", defaultValue: "Neutral", bundle: .module,
                   comment: "Journal mood tag: neither good nor bad")
        case .quiet:
            String(localized: "feeling.quiet", defaultValue: "Quiet", bundle: .module,
                   comment: "Journal mood tag: a subdued, low-key day")
        case .tired:
            String(localized: "feeling.tired", defaultValue: "Tired", bundle: .module,
                   comment: "Journal mood tag: a tired day")
        case .hard:
            String(localized: "feeling.hard", defaultValue: "Hard", bundle: .module,
                   comment: "Journal mood tag: the hardest of the six moods")
        }
    }
}

/// The user's manually logged sleep for a day: hours, quality, and a note.
///
/// Distinct from HealthKit sleep (``HealthBodyContext``) — this is the deliberate log. `quality`
/// decodes tolerantly; re-logging constructs a fresh record, which drops any parked token.
public nonisolated struct SleepLog: Codable, Equatable {
    public var hours: Double?
    public var quality: SleepQuality {
        didSet { unknownQualityToken = nil }
    }
    /// Unknown `quality` token from a newer build; frozen to `.ok`, parked, re-adopted on upgrade
    /// (`EnumDecodeCompat`). Re-logging sleep constructs a fresh log, which drops the token.
    public var unknownQualityToken: String? = nil
    public var note: String
    public var loggedAt = Date()

    public init(hours: Double? = nil, quality: SleepQuality, note: String, loggedAt: Date = Date()) {
        self.hours = hours; self.quality = quality; self.note = note; self.loggedAt = loggedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hours = try c.decodeIfPresent(Double.self, forKey: .hours)
        // Required key (was strict `decode` pre-compat): absence is corruption, not a newer build.
        let qualitySplit = try c.decodeTolerantRequiredEnum(
            SleepQuality.self, forKey: .quality, parkedTokenKey: .unknownQualityToken, default: .ok)
        quality = qualitySplit.value
        unknownQualityToken = qualitySplit.parkedToken
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        loggedAt = try c.decodeIfPresent(Date.self, forKey: .loggedAt) ?? Date()
    }
}

/// The four-step subjective sleep rating with its journal-voice description.
///
/// Feeds the sleep component of the daily score alongside logged hours.
public nonisolated enum SleepQuality: String, Codable, CaseIterable, Identifiable {
    case poor, ok, good, great

    public var id: String { rawValue }

    /// The localized rating label.
    ///
    /// Was `rawValue.capitalized`, which is unlocalizable by construction. `rawValue` is FROZEN —
    /// it is the persisted `SleepLog.quality` token (with a parked-token side channel that assumes
    /// these exact spellings) and the vocabulary the sleep prompt quotes back at the model. A
    /// prompt or an export wanting the stable word must read `rawValue`; only this reads as text.
    public var label: String {
        switch self {
        case .poor:
            String(localized: "sleep.quality.poor", defaultValue: "Poor", bundle: .module,
                   comment: "Sleep quality rating, worst of four")
        case .ok:
            String(localized: "sleep.quality.ok", defaultValue: "Ok", bundle: .module,
                   comment: "Sleep quality rating, second of four")
        case .good:
            String(localized: "sleep.quality.good", defaultValue: "Good", bundle: .module,
                   comment: "Sleep quality rating, third of four")
        case .great:
            String(localized: "sleep.quality.great", defaultValue: "Great", bundle: .module,
                   comment: "Sleep quality rating, best of four")
        }
    }

    /// The journal-voice gloss shown under the rating. Pure display — nothing persists, matches on,
    /// or prompts with this, so it localizes with no token to fork away from.
    public var description: String {
        switch self {
        case .poor:
            String(localized: "sleep.quality.poor.description",
                   defaultValue: "rough, broken, unrested", bundle: .module,
                   comment: "Gloss under the 'Poor' sleep rating; lowercase, journal voice")
        case .ok:
            String(localized: "sleep.quality.ok.description",
                   defaultValue: "enough, not great", bundle: .module,
                   comment: "Gloss under the 'Ok' sleep rating; lowercase, journal voice")
        case .good:
            String(localized: "sleep.quality.good.description",
                   defaultValue: "solid, mostly through", bundle: .module,
                   comment: "Gloss under the 'Good' sleep rating; lowercase, journal voice")
        case .great:
            String(localized: "sleep.quality.great.description",
                   defaultValue: "restorative, woke easy", bundle: .module,
                   comment: "Gloss under the 'Great' sleep rating; lowercase, journal voice")
        }
    }
}

/// The built-in personal-care checklist items (teeth, floss, shower, skincare, sunscreen).
///
/// Also the seed for the default ``PersonalCareTask``s; day sets decode tolerantly so an item
/// added by a newer build parks instead of dropping the day.
public nonisolated enum HygieneItem: String, Codable, CaseIterable, Identifiable {
    case teethAM, teethPM, floss, shower, deodorant, skincareAM, skincarePM, sunscreen

    public var id: String { rawValue }

    /// The localized checklist label.
    ///
    /// `rawValue` stays the token (it is the day row's `hygiene` set member and this item's
    /// `PersonalCareTask.id`); only this reads as text. Note that ``PersonalCareTask/defaultTasks``
    /// freezes whatever this returns into the persisted settings blob at first decode and never
    /// refreshes it — which is why renderers must go through ``PersonalCareTask/displayLabel``,
    /// not the stored `label`, to pick up the current language.
    public var label: String {
        switch self {
        case .teethAM:
            String(localized: "hygiene.teethAM", defaultValue: "Brush teeth AM", bundle: .module,
                   comment: "Personal-care checklist item: brushing teeth in the morning")
        case .teethPM:
            String(localized: "hygiene.teethPM", defaultValue: "Brush teeth PM", bundle: .module,
                   comment: "Personal-care checklist item: brushing teeth in the evening")
        case .floss:
            String(localized: "hygiene.floss", defaultValue: "Floss", bundle: .module,
                   comment: "Personal-care checklist item: flossing teeth")
        case .shower:
            String(localized: "hygiene.shower", defaultValue: "Shower", bundle: .module,
                   comment: "Personal-care checklist item: taking a shower")
        case .deodorant:
            String(localized: "hygiene.deodorant", defaultValue: "Deodorant", bundle: .module,
                   comment: "Personal-care checklist item: applying deodorant")
        case .skincareAM:
            String(localized: "hygiene.skincareAM", defaultValue: "Skincare AM", bundle: .module,
                   comment: "Personal-care checklist item: morning skincare routine")
        case .skincarePM:
            String(localized: "hygiene.skincarePM", defaultValue: "Skincare PM", bundle: .module,
                   comment: "Personal-care checklist item: evening skincare routine")
        case .sunscreen:
            String(localized: "hygiene.sunscreen", defaultValue: "Sunscreen", bundle: .module,
                   comment: "Personal-care checklist item: applying sunscreen")
        }
    }

    public var systemImage: String {
        switch self {
        case .teethAM, .teethPM: "mouth"
        case .floss: "checkmark.seal"
        case .shower: "shower"
        case .deodorant: "sparkle"
        case .skincareAM: "sun.max"
        case .skincarePM: "moon"
        case .sunscreen: "drop"
        }
    }

    /// The care group this built-in belongs to, as a ``CareGroup`` case.
    ///
    /// The typed form is the one to reason with; ``group`` below is the string spelling that gets
    /// BAKED into a ``PersonalCareTask`` row and persisted, so it must stay the raw token.
    public var careGroup: CareGroup {
        switch self {
        case .teethAM, .skincareAM, .sunscreen: .morning
        case .teethPM, .floss, .skincarePM: .evening
        case .shower, .deodorant: .anytime
        }
    }

    /// FROZEN token spelling of ``careGroup`` — this exact string is written into
    /// `PersonalCareTask.group` by ``PersonalCareTask/defaultTasks`` and then persisted in the
    /// synced settings blob. Never localize it; localize ``CareGroup/label`` instead.
    public var group: String { careGroup.rawValue }
}

/// The three time-of-day buckets the personal-care checklist is sectioned into.
///
/// This type exists because one string was doing three jobs at once: the rendered section header,
/// the value PERSISTED into `PersonalCareTask.group` for every task (it rides the synced settings
/// blob), and the predicate the checklist filters rows with. Localizing that one string would have
/// made a German device write "Morgen" into the blob while the filter still asked for "Morning" —
/// every existing checklist would silently render empty, and the rows would come back wrong on the
/// user's other devices.
///
/// So the two jobs are split: `rawValue` is the frozen token — "Morning" / "Anytime" / "Evening",
/// byte-identical to what shipped, so already-persisted rows keep matching forever — and ``label``
/// is the only thing a person reads.
public nonisolated enum CareGroup: String, Codable, CaseIterable, Identifiable, Sendable {
    case morning = "Morning"
    case anytime = "Anytime"
    case evening = "Evening"

    public var id: String { rawValue }

    /// The FROZEN persisted/filter token. Spelled out as its own property so a call site that
    /// genuinely wants the storage form says so, rather than reaching for `rawValue` and leaving
    /// the next reader to guess whether display was intended.
    public var token: String { rawValue }

    /// The localized section header. Display only — never persist this, never compare against it.
    public var label: String {
        switch self {
        case .morning:
            String(localized: "care.group.morning", defaultValue: "Morning", bundle: .module,
                   comment: "Personal-care checklist section for morning tasks")
        case .anytime:
            String(localized: "care.group.anytime", defaultValue: "Anytime", bundle: .module,
                   comment: "Personal-care checklist section for tasks with no fixed time of day")
        case .evening:
            String(localized: "care.group.evening", defaultValue: "Evening", bundle: .module,
                   comment: "Personal-care checklist section for evening tasks")
        }
    }

    /// Resolves a persisted `PersonalCareTask.group` string back to a case, or nil when the token
    /// is one no build has ever written.
    ///
    /// Deliberately an EXACT rawValue match, not a fuzzy or localized one: a task whose group the
    /// user's device cannot name is better filed under ``anytime`` by the caller than guessed into
    /// the wrong bucket, and a lenient match here would start accepting translated spellings and
    /// re-open exactly the drift this type was created to close.
    public init?(persistedToken: String) {
        self.init(rawValue: persistedToken)
    }
}

/// A configurable personal-care checklist task (built-in or user-created).
///
/// Built-ins mirror ``HygieneItem`` via `defaultHygieneRawValue` so legacy hygiene sets keep
/// counting; ``normalized(_:)`` is the validating seam every writer goes through — it de-dupes,
/// cleans labels, applies ``maxTasks``/``maxLabelLength``, and falls back to the defaults when a
/// decoded list is unusable.
public nonisolated struct PersonalCareTask: Identifiable, Codable, Equatable {

    /// R3: the largest checklist this type will ever hold. The list grows one row per user tap and
    /// rides the synced settings blob, so the bound belongs HERE, on the type, rather than in the
    /// Settings screen that happens to own today's add button — a restored blob, a paired device, or
    /// any future writer reaches ``normalized(_:)`` and cannot exceed it. The Settings screen keeps
    /// its own check so the button disables before the tap, but reads this constant.
    public static let maxTasks = 40

    /// R5: the longest task label. Free text from the add field; an unbounded label would ride the
    /// synced settings blob and wrap unboundedly in every checklist row. Applied in
    /// ``normalized(_:)``, so a label arriving from anywhere is clamped rather than trusted.
    public static let maxLabelLength = 60

    public init(id: String, label: String, systemImage: String, group: String, defaultHygieneRawValue: String? = nil) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
        self.group = group
        self.defaultHygieneRawValue = defaultHygieneRawValue
    }
    public var id: String
    public var label: String
    public var systemImage: String
    public var group: String
    public var defaultHygieneRawValue: String?

    /// The FROZEN group tokens, in section order — the same three strings, in the same order, this
    /// property has always returned. Kept `[String]` so every existing caller (the checklist's
    /// section `ForEach`, the Settings group chips, the `normalized(_:)` validity check) compiles
    /// and behaves identically; ``groupCases`` is the typed form to render from.
    nonisolated public static var groups: [String] { CareGroup.allCases.map(\.token) }

    /// The care groups as cases, in section order. Render section headers and group chips from
    /// `\.label` on these — never from ``groups``, whose strings are storage tokens.
    nonisolated public static var groupCases: [CareGroup] { CareGroup.allCases }

    /// This task's group as a case; ``CareGroup/anytime`` when the persisted token is unrecognised.
    ///
    /// `normalized(_:)` already rewrites an unknown group to "Anytime" on every read and write, so
    /// the fallback here is belt-and-braces for a row that reached a renderer without passing
    /// through the seam.
    public var careGroup: CareGroup {
        CareGroup(persistedToken: group) ?? .anytime
    }

    /// The label to actually SHOW for this task.
    ///
    /// Built-in tasks resolve their label live from ``HygieneItem/label`` rather than reading the
    /// `label` string stored on the row. That indirection is the fix for a real trap: `defaultTasks`
    /// BAKES the English label into the settings blob the first time settings decode, and nothing
    /// ever refreshes it — so a localized `HygieneItem.label` alone would translate the checklist
    /// for new installs while leaving every existing user permanently on English. Resolving through
    /// `defaultHygieneItem` means the stored label is inert for built-ins and the current language
    /// always wins.
    ///
    /// User-created tasks fall through to their stored `label`, which is exactly right: that text is
    /// the user's own words and must never be translated.
    ///
    /// The `id` arm is the same recovery for rows written before `defaultHygieneRawValue` existed,
    /// which carry a nil hygiene link. ``defaultTasks`` mints built-ins with `id: item.rawValue`
    /// and ``custom(label:group:)`` mints user tasks with a `"custom-<UUID>"` id, so an id that
    /// parses as a ``HygieneItem`` identifies a built-in and cannot collide with a user's task.
    /// Deliberately confined to display: `defaultHygieneItem` keeps its stricter definition,
    /// because it also drives the day's legacy `hygiene` set and its completion mirroring.
    public var displayLabel: String {
        if let item = defaultHygieneItem { return item.label }
        if let legacyBuiltIn = HygieneItem(rawValue: id) { return legacyBuiltIn.label }
        return label
    }

    nonisolated public static var defaultTasks: [PersonalCareTask] {
        HygieneItem.allCases.map { item in
            PersonalCareTask(
                id: item.rawValue,
                label: item.label,
                systemImage: item.systemImage,
                group: item.group,
                defaultHygieneRawValue: item.rawValue
            )
        }
    }

    public var defaultHygieneItem: HygieneItem? {
        guard let defaultHygieneRawValue else { return nil }
        return HygieneItem(rawValue: defaultHygieneRawValue)
    }

    /// Mints a user-created task. `group` is a persisted CareGroup token; anything that is not one
    /// of the three is filed under ``CareGroup/anytime`` rather than persisted as-is, so a caller
    /// can never write a group the checklist's own section filter would then fail to match.
    public static func custom(label: String, group: String) -> PersonalCareTask {
        PersonalCareTask(
            id: "custom-\(UUID().uuidString)",
            label: label,
            systemImage: "checkmark.circle",
            group: (CareGroup(persistedToken: group) ?? .anytime).token,
            defaultHygieneRawValue: nil
        )
    }

    /// Typed convenience for ``custom(label:group:)`` — the form a picker built from
    /// ``groupCases`` should call, since it cannot then hand over a string that isn't a group.
    public static func custom(label: String, group: CareGroup) -> PersonalCareTask {
        custom(label: label, group: group.token)
    }

    /// The validating seam: de-dupes by id, drops empty ids/labels, clamps each label to
    /// ``maxLabelLength``, defaults a missing glyph/group, caps the list at ``maxTasks``, and falls
    /// back to ``defaultTasks`` when nothing usable survives. Every writer (the Settings add path,
    /// the delete path, and the settings decode) runs its list through here, which is what makes the
    /// two caps unbypassable rather than a policy of whichever screen wrote last.
    public static func normalized(_ tasks: [PersonalCareTask]) -> [PersonalCareTask] {
        var seen: Set<String> = []
        let cleaned = tasks.compactMap { task -> PersonalCareTask? in
            let trimmedLabel = task.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.id.isEmpty, !trimmedLabel.isEmpty, !seen.contains(task.id) else { return nil }
            seen.insert(task.id)
            var normalizedTask = task
            // R5: clamp the free-text label at the domain boundary, not at the screen that typed it.
            normalizedTask.label = String(trimmedLabel.prefix(maxLabelLength))
            normalizedTask.systemImage = task.systemImage.isEmpty ? "checkmark.circle" : task.systemImage
            // Exact-token match against CareGroup, NOT against a localized header: a row whose
            // group came back from another device (or an older/newer build) must keep the token it
            // was stored with, and anything unrecognised is filed under Anytime so it still renders
            // in some section instead of vanishing from every one of them.
            normalizedTask.group = (CareGroup(persistedToken: task.group) ?? .anytime).token
            return normalizedTask
        }
        // R3: the list itself is bounded here. Oldest-first (the built-ins lead the array), so a list
        // over the cap keeps the tasks the user has had longest rather than an arbitrary slice.
        return cleaned.isEmpty ? defaultTasks : Array(cleaned.prefix(maxTasks))
    }
}

/// A short, screened memory captured from a journal entry.
///
/// `fromJournal` enforces the capture rules: minimum length, a 120-character cap, and the
/// ``DiagnosticLanguage`` screen that silently rejects clinical language before anything is stored
/// (spec §8).
public nonisolated struct MemoryNote: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var category: String
    public var text: String
    public var sourceDate = Date()

    public init(id: UUID = UUID(), category: String, text: String, sourceDate: Date = Date()) {
        self.id = id; self.category = category; self.text = text; self.sourceDate = sourceDate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        category = try c.decode(String.self, forKey: .category)
        text = try c.decode(String.self, forKey: .text)
        sourceDate = try c.decodeIfPresent(Date.self, forKey: .sourceDate) ?? Date()
    }

    public static func fromJournal(text: String, tag: FeelingTag) -> MemoryNote? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return nil }
        let prefix = String(trimmed.prefix(120))
        // Spec §8: a diagnostic-language post-classifier runs on every proposed memory
        // before storage; any match is silently rejected so clinical language never lands.
        guard !DiagnosticLanguage.contains(prefix) else { return nil }
        return MemoryNote(category: tag.rawValue, text: prefix)
    }
}

/// A structured long-form goal: type, statement, timeframe, metric, and milestones.
///
/// Authored during onboarding/goal editing; `type` links it to the ``GoalType`` presets that drive
/// nutrition and training defaults.
public nonisolated struct FitnessGoal: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var type: GoalType
    public var goal: String
    public var timeframe: String
    public var metric: String
    public var milestones: [String] = []
    public var weeklyStructure: String?

    public init(id: UUID = UUID(), type: GoalType, goal: String, timeframe: String, metric: String, milestones: [String] = [], weeklyStructure: String? = nil) {
        self.id = id; self.type = type; self.goal = goal; self.timeframe = timeframe; self.metric = metric; self.milestones = milestones; self.weeklyStructure = weeklyStructure
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try c.decode(GoalType.self, forKey: .type)
        goal = try c.decode(String.self, forKey: .goal)
        timeframe = try c.decodeIfPresent(String.self, forKey: .timeframe) ?? ""
        metric = try c.decodeIfPresent(String.self, forKey: .metric) ?? ""
        milestones = try c.decodeIfPresent([String].self, forKey: .milestones) ?? []
        weeklyStructure = try c.decodeIfPresent(String.self, forKey: .weeklyStructure)
    }
}

/// The seven goal presets that shape nutrition targets, training splits, and rest guidance.
///
/// The module's central "what is the user optimizing for" switch — consumed by
/// ``NutritionTargetCalculator``, `WorkoutSplitRecommender`, ``WorkoutGoalStyle``, and
/// ``WorkoutRestGuidance``. `init(persistedToken:)` also maps the legacy display-string aliases
/// early builds wrote; the lenient `init(from:)` freezes unrecognized tokens to `.wellness`, and
/// ``FernletSettings`` additionally parks them in a side channel.
public nonisolated enum GoalType: String, Codable, CaseIterable, Identifiable, Sendable {
    case wellness
    case strength
    case weightManagement
    case mentalHealth
    case recovery
    case exploring
    case sportsPrep

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .wellness: "Wellness"
        case .strength: "Strength"
        case .weightManagement: "Weight Management"
        case .mentalHealth: "Mental Health"
        case .recovery: "Recovery"
        case .exploring: "Exploring"
        case .sportsPrep: "Sports Prep"
        }
    }

    public var tagline: String {
        switch self {
        case .wellness: "Balanced daily care."
        case .strength: "Fuel, train, and recover."
        case .weightManagement: "Steady habits without pressure."
        case .mentalHealth: "Mood and steadiness first."
        case .recovery: "Rest, hydration, and gentle care."
        case .exploring: "Learn what feels useful."
        case .sportsPrep: "Train for your sport."
        }
    }

    /// Goals whose programming is built around structured training (drives stricter workout
    /// consistency / progression vs. the gentler wellness-oriented goals).
    public var isTrainingFocused: Bool {
        switch self {
        case .strength, .sportsPrep, .weightManagement: true
        case .wellness, .mentalHealth, .recovery, .exploring: false
        }
    }

    /// One-line description of how this goal shapes the daily nutrition targets, for the goal preset
    /// cards. Descriptive only — it summarizes the calorie/protein logic in
    /// `NutritionTargetCalculator` (per-goal calorie multiplier + protein g/kg), it does not recompute
    /// it. Keep the two in step: strength/sportsPrep eat a little more with more protein, weight
    /// management runs a gentle deficit with higher protein, recovery sits near maintenance, and the
    /// gentler goals hold at balanced maintenance.
    public var nutritionSummary: String {
        switch self {
        case .strength:
            "A little more to grow on · high protein (~1.7 g/kg)"
        case .sportsPrep:
            "Fuelled for training · high protein (~1.6 g/kg)"
        case .weightManagement:
            "A gentle calorie deficit · higher protein"
        case .recovery:
            "Maintenance calories · easy on the body"
        case .wellness, .mentalHealth, .exploring:
            "Balanced maintenance · steady protein"
        }
    }

    /// One-line description of the training split this goal recommends, for the goal preset cards and the
    /// Move tab. Mirrors the split logic in `WorkoutSplitRecommender`; moved here (from a private
    /// MoveView extension) so Settings and Move share one source of truth.
    public var trainingSummary: String {
        switch self {
        case .strength:
            "Upper, lower, and full-body days across the week."
        case .weightManagement:
            "Strength days mixed with cardio and recovery."
        case .mentalHealth:
            "Gentle movement, cardio, and recovery anchors."
        case .recovery:
            "Recovery-first movement with optional light strength."
        case .wellness:
            "Balanced strength, cardio, and rest days."
        case .exploring:
            "Flexible splits based on what feels useful."
        case .sportsPrep:
            "Sport-specific training with strength and conditioning."
        }
    }

    /// Maps a persisted goal token — including the legacy aliases early builds wrote — to a case;
    /// nil for a token no case or alias matches (i.e. one minted by a newer build). The decode
    /// below freezes those to `.wellness`; `FernletSettings.selectedGoal` additionally parks them
    /// in a side channel so a re-save can't clobber a newer device's choice.
    ///
    /// FROZEN: legacy persisted display strings — never translate.
    ///
    /// The Title-Case arms below ("Weight Management", "Mental Health", "Sports Prep",
    /// "Short-term", "Long-term", …) are not labels. They are the literal bytes early builds wrote
    /// into the settings blob back when the goal picker persisted its own on-screen text, and they
    /// are still sitting in those users' iCloud records. They read like display strings, which is
    /// exactly the trap: run them through a localizer and a German device stops recognising its own
    /// stored goal, `init(from:)` falls to `.wellness`, and the user's nutrition targets silently
    /// change underneath them — `NutritionTargetCalculator` reads the goal for both the calorie
    /// multiplier and the protein g/kg, so a legacy `.weightManagement` user quietly loses their
    /// deficit and their higher protein floor with nothing on screen to explain it.
    ///
    /// The display copy for these cases lives on `displayName`/`nutritionSummary`/`trainingSummary`.
    /// This function only ever compares against frozen bytes.
    public init?(persistedToken: String) {
        switch persistedToken {
        case Self.wellness.rawValue, "Wellness", "Short-term":
            self = .wellness
        case Self.strength.rawValue, "Strength", "Long-term":
            self = .strength
        case Self.weightManagement.rawValue, "Weight Management":
            self = .weightManagement
        case Self.mentalHealth.rawValue, "Mental Health":
            self = .mentalHealth
        case Self.recovery.rawValue, "Recovery":
            self = .recovery
        case Self.exploring.rawValue, "Exploring":
            self = .exploring
        case Self.sportsPrep.rawValue, "Sports Prep", "Sport", "Sports":
            self = .sportsPrep
        default:
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = GoalType(persistedToken: value) ?? .wellness
    }
}
