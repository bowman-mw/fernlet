//
//  TierTwoMemoryEngine.swift
//  Fernlet
//
//  Derives Tier-2 behavioral memories from the rolling day window.
//

import Foundation
import FernletDomainModel

// MARK: - Tier Two Memory Engine

/// Deterministic inference engine that derives Tier-2 behavioral memories — goal-behavior gaps,
/// consistency profile, journal-avoidance patterns, workout-mood correlation, and travel days — from
/// the rolling day window.
///
/// Runs from ``TierTwoMemoryStore/refresh(from:goals:)`` after every successful repository save,
/// so inferences track the data with no AI involvement (Tier-2 memories are behavioral
/// observations *about* the user, distinct from the user-visible Tier-1 `MemoryNote`s). The
/// engine is change-driven: for each category a fresh candidate is compared against the newest
/// active record and appended only when the behavioral `state` actually changed, deactivating
/// the predecessor — so records form a small per-category history instead of churning every
/// save. Every candidate must pass the `DiagnosticLanguage` post-classifier (spec §8) before
/// storage; any diagnostic-sounding text is silently rejected — and because a rejected candidate
/// leaves its predecessor active, every branch's text is written to pass it (pinned by
/// `MemoryStorageScreeningTests`). The texts reach the companion's prompt as "user pattern:" lines,
/// so they describe what the days show and never judge the user. ``updateInferences(existing:from:goals:)``
/// always ends with ``prune(_:)`` (5 per category / 25 total).
///
/// **Travel days** (G7 follow-on, owner decisions 2026-11-15) arrive as plain values
/// (``TierTwoTravel``, built by the app from the map's vault and the passport), never from the map's
/// store itself. They do two things: the `travel_days` record says a travel day happened (and names
/// the city only while ``TierTwoTravel/namesCities`` holds — the AI that reads memory runs on this
/// iPhone), and the goal gap's workout rate treats a travel day with no workout like a rest day,
/// leaving it out of both sides of the rate. Results persist as
/// `TierTwoMemoryRecord`s in the device-local ``TierTwoMemoryStore`` sidecar — never in the
/// synced ``LocalFernletDatabase`` blob (owner decision 2026-09-23) — and reach the AI layer only
/// through `MemoryAgent`'s filtered projection. Internal to `LocalPersistence`; a stateless
/// namespace enum, nonisolated.
enum TierTwoMemoryEngine {

    /// Each category stores at most 5 records; total is capped at 25.
    /// With 5 categories × 5 = 25 (travel days joined the four on 2026-11-15), the per-category cap
    /// IS the global cap; the global one stays as the backstop against a category added without it.
    private static let maxPerCategory = 5
    /// The global record ceiling enforced by ``prune(_:)`` after the per-category trim.
    private static let maxTotal = 25
    /// The trailing days the engine reads.
    static let windowDays = 14
    /// The travel-day category's frozen token.
    static let travelCategory = "travel_days"

    /// Compares the new 14-day window against existing records and appends a record per category
    /// only when that category's behavioral state has actually changed.
    ///
    /// - Parameters:
    ///   - existing: The persisted Tier-2 records being updated (never mutated in place).
    ///   - days: `(dateKey, day)` pairs, oldest-first; only the trailing 14 are considered, and
    ///     fewer than 3 days short-circuits to a prune of the existing records.
    ///   - goals: The user's fitness goals; the first drives the goal-behavior-gap category.
    ///   - travel: The travel days (``TierTwoTravel/none`` when there are none, in a decoy, or with
    ///     "Airports and flights" off).
    /// - Returns: The pruned, updated record list to persist back into the device-local store.
    static func updateInferences(
        existing: [TierTwoMemoryRecord],
        from days: [(String, FernletDay)],
        goals: [FitnessGoal],
        travel: TierTwoTravel = .none
    ) -> [TierTwoMemoryRecord] {
        let window = Array(days.suffix(windowDays))
        guard window.count >= 3 else { return prune(existing) }

        var updated = existing

        let candidates = [
            goalBehaviorGap(window: window, goals: goals, travel: travel),
            consistencyProfile(window: window),
            journalAvoidancePattern(window: window),
            workoutMoodCorrelation(window: window),
            travelDays(window: window, travel: travel)
        ].compactMap { $0 }

        for new in candidates {
            // Spec §8: diagnostic-language post-classifier runs on every proposed memory
            // before storage; any match is silently rejected. Mirrors
            // MemoryAgent.containsDiagnosticLanguage(_ record:) — the app-side wrapper is a
            // 1-line delegation to this same DiagnosticLanguage primitive, inlined here so the
            // persistence layer carries no upward edge to the app target.
            if DiagnosticLanguage.contains(new.text + " " + new.evidence) { continue }
            let lastActive = updated
                .filter { $0.category == new.category && $0.active }
                .sorted { $0.extractedDate < $1.extractedDate }
                .last
            if let prev = lastActive {
                if prev.state == new.state { continue }  // same verdict, skip
                if let idx = updated.firstIndex(where: { $0.id == prev.id }) {
                    updated[idx].active = false
                }
            }
            updated.append(new)
        }
        // A travel note lasts only while a travel day is in the window and travel may be read (not in a
        // decoy, nor with "Airports and flights" off): without a candidate, every travel record goes,
        // superseded ones and their cities too, rather than lingering as history.
        if !candidates.contains(where: { $0.category == travelCategory }) {
            updated.removeAll { $0.category == travelCategory }
        }

        return prune(updated)
    }

    /// Keeps the most recent ``maxPerCategory`` records per category.
    /// If still over ``maxTotal``, drops oldest inactive records first.
    private static func prune(_ records: [TierTwoMemoryRecord]) -> [TierTwoMemoryRecord] {
        let categories = Array(Set(records.map { $0.category })).sorted()
        var result: [TierTwoMemoryRecord] = []
        for category in categories {
            let byDate = records
                .filter { $0.category == category }
                .sorted { $0.extractedDate < $1.extractedDate }
            result.append(contentsOf: byDate.suffix(maxPerCategory))
        }
        guard result.count > maxTotal else { return result }
        let active = result.filter { $0.active }.sorted { $0.extractedDate > $1.extractedDate }
        let inactive = result.filter { !$0.active }.sorted { $0.extractedDate > $1.extractedDate }
        return Array((active + inactive).prefix(maxTotal))
    }

    // MARK: Goal-Behavior Gap

    /// One goal family's verdict — the four strings ``goalBehaviorGap(window:goals:)`` folds into a
    /// `TierTwoMemoryRecord`. Exists so each goal family is a short, separately readable helper
    /// instead of an arm of one oversized dispatcher (R4).
    private struct GapVerdict {
        let state: String
        let confidence: String
        let evidence: String
        let text: String
    }

    /// The workout side of the goal gap's rates (owner 2026-11-15): a travel day with no workout is
    /// treated gently, like a rest day, and leaves both the numerator and the denominator. A travel
    /// day with a workout still counts on both sides.
    private struct WorkoutCount {
        /// Days with a workout.
        let days: Int
        /// The days the rate is read over: the window less the workout-less travel days.
        let of: Int
        /// The workout-less travel days left out.
        let travelLeftOut: Int

        /// `days / of`; the caller guarantees `of > 0`.
        var rate: Double { Double(days) / Double(of) }

        /// The rate's evidence, e.g. "4/11 workout days (3 travel days left out)".
        func evidence(_ noun: String) -> String {
            let base = "\(days)/\(of) \(noun)"
            guard travelLeftOut > 0 else { return base }
            return base + " (\(travelLeftOut) travel day\(travelLeftOut == 1 ? "" : "s") left out)"
        }
    }

    /// Infers whether logged behavior (workout/meal/journal/sleep rates) matches the primary
    /// stated goal, producing an aligned/partial/misaligned-style state per goal type. Returns
    /// nil when the user has no goals, or when the window is too short for the rates to mean
    /// anything (the caller's `>= 3` bound, restated locally so it travels with the function; a
    /// workout-reading family also needs 3 days once the workout-less travel days are left out).
    private static func goalBehaviorGap(
        window: [(String, FernletDay)],
        goals: [FitnessGoal],
        travel: TierTwoTravel
    ) -> TierTwoMemoryRecord? {
        guard let primary = goals.first else { return nil }
        let n = window.count
        guard n >= 3 else { return nil }
        let workoutDays = window.filter { !$0.1.workouts.isEmpty }.count
        let leftOut = window.filter { $0.1.workouts.isEmpty && travel.days[$0.0] != nil }.count
        let workouts = WorkoutCount(days: workoutDays, of: n - leftOut, travelLeftOut: leftOut)
        guard primary.type == .mentalHealth || workouts.of >= 3 else { return nil }
        let mealDays = window.filter { !$0.1.meals.isEmpty }.count
        let journalDays = window.filter { !$0.1.journals.isEmpty }.count
        let mealRate = Double(mealDays) / Double(n)
        let journalRate = Double(journalDays) / Double(n)

        let verdict: GapVerdict
        switch primary.type {
        case .strength, .sportsPrep, .bodybuilding:
            verdict = strengthVerdict(workouts: workouts)
        case .weightManagement:
            verdict = weightManagementVerdict(mealDays: mealDays, n: n, mealRate: mealRate, workouts: workouts)
        case .mentalHealth:
            verdict = mentalHealthVerdict(journalDays: journalDays, n: n, journalRate: journalRate)
        case .recovery:
            verdict = recoveryVerdict(window: window, n: n, workouts: workouts)
        case .wellness, .exploring:
            verdict = wellnessVerdict(mealDays: mealDays, n: n, mealRate: mealRate, workouts: workouts)
        }

        return TierTwoMemoryRecord(
            category: "goal_behavior_gap",
            text: verdict.text,
            state: verdict.state,
            evidence: verdict.evidence,
            confidence: verdict.confidence,
            dataWindowDays: n
        )
    }

    /// Strength / sports-prep: adherence read purely from the workout rate.
    private static func strengthVerdict(workouts: WorkoutCount) -> GapVerdict {
        let evidence = workouts.evidence("days with workouts")
        let workoutRate = workouts.rate
        if workoutRate < 0.2 {
            return GapVerdict(state: "misaligned", confidence: "high", evidence: evidence,
                              text: "Has stated strength goals; workouts have been rare in the data window, a quieter stretch for training.")
        }
        if workoutRate < 0.45 {
            return GapVerdict(state: "partial", confidence: "medium", evidence: evidence,
                              text: "Exercises occasionally but inconsistently relative to stated strength goals; partial adherence.")
        }
        return GapVerdict(state: "aligned", confidence: "high", evidence: evidence,
                          text: "Workout behavior aligns with stated strength goals; demonstrates consistent follow-through.")
    }

    /// Weight management: meal logging first, then whether exercise accompanies it.
    private static func weightManagementVerdict(
        mealDays: Int, n: Int, mealRate: Double, workouts: WorkoutCount
    ) -> GapVerdict {
        let evidence = "\(mealDays)/\(n) meal days, " + workouts.evidence("workout days")
        let workoutRate = workouts.rate
        if mealRate < 0.3 {
            return GapVerdict(state: "misaligned", confidence: "high", evidence: evidence,
                              text: "States weight management goals; meals have been logged on only a few days in the data window.")
        }
        if workoutRate < 0.2 {
            return GapVerdict(state: "dietary_only", confidence: "medium", evidence: evidence,
                              text: "Tracks food reasonably often but seldom exercises; weight management approach is primarily dietary.")
        }
        return GapVerdict(state: "aligned", confidence: "high", evidence: evidence,
                          text: "Actively tracking both food and exercise consistent with weight management goals.")
    }

    /// Mental health: journalling cadence as the stated practice's evidence.
    private static func mentalHealthVerdict(journalDays: Int, n: Int, journalRate: Double) -> GapVerdict {
        let evidence = "\(journalDays)/\(n) days with journal entries"
        if journalRate < 0.25 {
            return GapVerdict(state: "misaligned", confidence: "medium", evidence: evidence,
                              text: "Has mental health goals but journals infrequently; reflective self-care behaviors are inconsistent with stated intent.")
        }
        return GapVerdict(state: "aligned", confidence: "medium", evidence: evidence,
                          text: "Journals regularly, consistent with a mental health focus; self-reflection appears to be a real practice.")
    }

    /// Recovery: sleep logging weighed against training volume.
    private static func recoveryVerdict(
        window: [(String, FernletDay)], n: Int, workouts: WorkoutCount
    ) -> GapVerdict {
        let sleepDays = window.filter { $0.1.sleep != nil }.count
        let evidence = "\(sleepDays)/\(n) sleep logged, " + workouts.evidence("workout days")
        let workoutRate = workouts.rate
        let sleepRate = Double(sleepDays) / Double(n)
        if sleepRate < 0.3 && workoutRate > 0.5 {
            return GapVerdict(state: "misaligned", confidence: "medium", evidence: evidence,
                              text: "Trains frequently but rarely logs sleep or rest; recovery behaviors do not match stated recovery goals.")
        }
        if sleepRate >= 0.4 {
            return GapVerdict(state: "aligned", confidence: "medium", evidence: evidence,
                              text: "Sleep and recovery tracking consistent with recovery-focused goals.")
        }
        return GapVerdict(state: "partial", confidence: "low", evidence: evidence,
                          text: "Recovery goal stated but few behaviors in the data consistently support it.")
    }

    /// Wellness / exploring: engagement across any domain at all.
    private static func wellnessVerdict(
        mealDays: Int, n: Int, mealRate: Double, workouts: WorkoutCount
    ) -> GapVerdict {
        let evidence = "\(mealDays)/\(n) meal days, " + workouts.evidence("workout days")
        let workoutRate = workouts.rate
        if mealRate < 0.2 && workoutRate < 0.2 {
            return GapVerdict(state: "passive_wellness", confidence: "high", evidence: evidence,
                              text: "General wellness goal stated but almost no tracking across any domain; app engagement is minimal.")
        }
        return GapVerdict(state: "partial", confidence: "low", evidence: evidence,
                          text: "Wellness-oriented user with intermittent engagement; no structured pattern is apparent.")
    }

    // MARK: Consistency Profile

    /// Classifies overall engagement — consistent / intermittent / sporadic / minimal — from the
    /// fraction of window days with any logged data at all. Returns nil for a window shorter than
    /// three days (the caller's bound, restated locally so the rate can never be NaN).
    private static func consistencyProfile(window: [(String, FernletDay)]) -> TierTwoMemoryRecord? {
        let n = window.count
        guard n >= 3 else { return nil }
        let activeDays = window.filter { _, day in
            !day.meals.isEmpty || !day.workouts.isEmpty || !day.journals.isEmpty || day.sleep != nil
        }.count
        let rate = Double(activeDays) / Double(n)

        let text: String
        let state: String
        let confidence: String

        if rate >= 0.75 {
            state = "consistent"; confidence = "high"
            text = "Logs consistently across most days; self-monitoring appears to be a genuine habit rather than reactive behavior."
        } else if rate >= 0.45 {
            state = "intermittent"; confidence = "medium"
            text = "Logs on some days and not others; checks in when it fits the day, with quieter days in between."
        } else if rate >= 0.2 {
            state = "sporadic"; confidence = "medium"
            text = "Logs now and then; the app is part of some days rather than most."
        } else {
            state = "minimal"; confidence = "high"
            text = "Minimal logging across the window; stated goals are not backed by sustained day-to-day engagement."
        }

        return TierTwoMemoryRecord(
            category: "consistency_profile",
            text: text,
            state: state,
            evidence: "\(activeDays)/\(n) days with any logged data",
            confidence: confidence,
            dataWindowDays: n
        )
    }

    // MARK: Journal Avoidance Pattern

    /// Detects excuse/avoidance language in journal text via a fixed keyword list, emitting a
    /// record only past a threshold (≥30% of entries or ≥3 matches); returns nil below it or
    /// with fewer than 2 entries.
    private static func journalAvoidancePattern(window: [(String, FernletDay)]) -> TierTwoMemoryRecord? {
        let avoidanceKeywords = [
            "couldn't", "too tired", "forgot", "maybe tomorrow", "didn't have time",
            "was going to", "supposed to", "meant to", "next week", "eventually",
            "need to start", "should have", "ran out of time", "not today",
            "kept meaning", "will try", "hoping to", "plan to start"
        ]
        let allJournals = window.flatMap { $0.1.journals }
        guard allJournals.count >= 2 else { return nil }

        let avoidanceCount = allJournals.filter { journal in
            let lower = journal.text.lowercased()
            return avoidanceKeywords.contains { lower.contains($0) }
        }.count

        let rate = Double(avoidanceCount) / Double(allJournals.count)
        guard rate >= 0.3 || avoidanceCount >= 3 else { return nil }

        let text: String
        let state: String
        let confidence: String

        if rate >= 0.6 {
            state = "high_avoidance"; confidence = "high"
            text = "Journal entries often mention putting things off — feeling too tired, running out of time, or meaning to try again later."
        } else {
            state = "moderate_avoidance"; confidence = "medium"
            text = "Journal entries sometimes mention tiredness, forgetting, or planning to get to things later."
        }

        return TierTwoMemoryRecord(
            category: "journal_avoidance_pattern",
            text: text,
            state: state,
            evidence: "\(avoidanceCount)/\(allJournals.count) journal entries contain avoidance language",
            confidence: confidence,
            dataWindowDays: window.count
        )
    }

    // MARK: Workout-Mood Correlation

    /// Compares average journal mood on workout days vs rest days (each needs ≥2 journaled days,
    /// else nil), classifying the delta as mood_boost / mood_drain / neutral.
    private static func workoutMoodCorrelation(window: [(String, FernletDay)]) -> TierTwoMemoryRecord? {
        let workoutWithMood = window.filter { !$0.1.workouts.isEmpty && !$0.1.journals.isEmpty }
        let restWithMood = window.filter { $0.1.workouts.isEmpty && !$0.1.journals.isEmpty }
        guard workoutWithMood.count >= 2, restWithMood.count >= 2 else { return nil }

        func avgMood(_ pairs: [(String, FernletDay)]) -> Double {
            let scores = pairs.flatMap { $0.1.journals }.map { $0.tag.moodScore }
            guard !scores.isEmpty else { return 0 }
            return scores.reduce(0, +) / Double(scores.count)
        }

        let workoutMood = avgMood(workoutWithMood)
        let restMood = avgMood(restWithMood)
        let delta = workoutMood - restMood

        let text: String
        let state: String
        let confidence: String

        if delta >= 0.2 {
            state = "mood_boost"; confidence = "high"
            text = "Mood is noticeably better on workout days; exercise appears to positively affect emotional state — may respond well to reminders framed around mood benefit."
        } else if delta <= -0.15 {
            state = "mood_drain"; confidence = "medium"
            text = "Mood tends to be lower on workout days; workouts may be landing on days that were already tiring or busy."
        } else {
            state = "neutral"; confidence = "medium"
            text = "No clear mood difference between workout and rest days; exercise motivation is likely goal-driven rather than mood-driven."
        }

        let evidenceStr = String(
            format: "workout-day mood %.2f vs rest-day %.2f (delta %.2f, n=%d/%d)",
            workoutMood, restMood, delta, workoutWithMood.count, restWithMood.count
        )
        return TierTwoMemoryRecord(
            category: "workout_mood_correlation",
            text: text,
            state: state,
            evidence: evidenceStr,
            confidence: confidence,
            dataWindowDays: window.count
        )
    }

    // MARK: Travel Days

    /// The English weekday names, Sunday first (Gregorian `weekday` 1...7). Tier-2 text is English
    /// like the rest of the engine's, whatever the interface language.
    private static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    /// The longest city name a line carries (a bound on text that came from the airport list).
    private static let maxCityLength = 60

    /// Notes that travel days fell inside the window (owner decisions 2026-11-15, lines verbatim):
    /// one day reads A1, two or more read A2 with the count and the window's real length, and a
    /// workout logged on a travel day appends A3. The city line (B) joins only while
    /// ``TierTwoTravel/namesCities`` holds and a city is known, and only when the whole text still
    /// passes the diagnostic screen; otherwise the record is written without it. Nil with no travel
    /// day in the window.
    ///
    /// The window's days run from its oldest row's key to its newest; a travel day inside that span
    /// counts even when it has no row of its own (nothing was logged that day). The state carries
    /// the count, the A3 flag and the city line, so a change to any of them supersedes the record;
    /// with no travel day left, ``updateInferences(existing:from:goals:travel:)`` removes the
    /// category's records.
    private static func travelDays(window: [(String, FernletDay)], travel: TierTwoTravel) -> TierTwoMemoryRecord? {
        guard let oldest = window.first?.0, let newest = window.last?.0, !travel.days.isEmpty else { return nil }
        let keys = travel.days.keys.filter { $0 >= oldest && $0 <= newest }.sorted()
        guard !keys.isEmpty else { return nil }
        let windowLength = window.count
        let count = min(keys.count, windowLength)
        let trainedKeys = Set(window.filter { !$0.1.workouts.isEmpty }.map(\.0))
        let movedOnTravelDay = keys.contains { trainedKeys.contains($0) }

        var text = count == 1
            ? "Had a travel day recently; movement eased off around it, as expected on a travel day."
            : "Travelled on \(count) of the last \(windowLength) days; training was lighter around those days, which is normal for travel."
        if movedOnTravelDay { text += " Still fit in some movement on a travel day." }
        var state = (count == 1 ? "one_day" : "days_\(count)") + (movedOnTravelDay ? "_moved" : "")
        if travel.namesCities, let line = cityLine(keys: keys, days: travel.days),
           !DiagnosticLanguage.contains(text + " " + line) {
            text += " " + line
            state += "|" + line
        }
        return TierTwoMemoryRecord(
            category: travelCategory,
            text: text,
            state: state,
            evidence: "\(count)/\(windowLength) travel days, \(keys.filter { trainedKeys.contains($0) }.count) with workouts",
            confidence: "medium",
            dataWindowDays: windowLength
        )
    }

    /// The city line (B): "Flew to Denver and back this fortnight." when a flight to a city is
    /// followed inside the window by one leaving it, else "Flew to Denver on Saturday." for the newest
    /// flight with a known city. Nil when no travel day knows a city (or its key is malformed). `keys` is sorted, oldest first,
    /// and bounded by ``TierTwoTravel/maxDays``.
    static func cityLine(keys: [String], days: [String: TierTwoTravelDay]) -> String? {
        let named = keys.compactMap { key in days[key]?.toCity.flatMap(cleanCity).map { (key, $0) } }
        guard let newest = named.last else { return nil }
        // Bounded: at most `TierTwoTravel.maxDays` keys on either side.
        for (key, city) in named.reversed() {
            let back = keys.contains { later in
                later > key && days[later]?.fromCity.flatMap(cleanCity) == city
            }
            if back { return "Flew to \(city) and back this fortnight." }
        }
        guard let weekday = weekdayName(dayKey: newest.0) else { return nil }
        return "Flew to \(newest.1) on \(weekday)."
    }

    /// A city name trimmed and bounded, or nil when empty.
    private static func cleanCity(_ raw: String) -> String? {
        let city = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !city.isEmpty else { return nil }
        return String(city.prefix(maxCityLength))
    }

    /// The English weekday of a `yyyy-MM-dd` day key, read in UTC from the key's own date (the key is
    /// already the person's local date), or nil for a malformed key.
    static func weekdayName(dayKey: String) -> String? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(identifier: "UTC") else { return nil }
        calendar.timeZone = utc
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else { return nil }
        let weekday = calendar.component(.weekday, from: date)
        guard (1...7).contains(weekday) else { return nil }
        return weekdayNames[weekday - 1]
    }
}
