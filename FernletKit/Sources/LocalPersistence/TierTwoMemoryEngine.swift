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
/// consistency profile, journal-avoidance patterns, and workout-mood correlation — from the
/// rolling day window.
///
/// Runs inside `LocalFernletDatabase.rebuildDerivedTables(todayKey:recentDays:)` on every save,
/// so inferences track the data with no AI involvement (Tier-2 memories are behavioral
/// observations *about* the user, distinct from the user-visible Tier-1 `MemoryNote`s). The
/// engine is change-driven: for each category a fresh candidate is compared against the newest
/// active record and appended only when the behavioral `state` actually changed, deactivating
/// the predecessor — so records form a small per-category history instead of churning every
/// save. Every candidate must pass the `DiagnosticLanguage` post-classifier (spec §8) before
/// storage; any diagnostic-sounding text is silently rejected. ``updateInferences(existing:from:goals:)``
/// always ends with ``prune(_:)`` (5 per category / 20 total). Results persist as
/// `TierTwoMemoryRecord`s in the ``LocalFernletDatabase`` blob and reach the AI layer only
/// through snapshot loading. Internal to `LocalPersistence`; a stateless namespace enum,
/// nonisolated.
enum TierTwoMemoryEngine {

    /// Each category stores at most 5 records; total is capped at 20.
    /// With 4 categories × 5 = 20, the per-category cap IS the global cap.
    private static let maxPerCategory = 5
    /// The global record ceiling enforced by ``prune(_:)`` after the per-category trim.
    private static let maxTotal = 20

    /// Compares the new 14-day window against existing records and appends a record per category
    /// only when that category's behavioral state has actually changed.
    ///
    /// - Parameters:
    ///   - existing: The persisted Tier-2 records being updated (never mutated in place).
    ///   - days: `(dateKey, day)` pairs, oldest-first; only the trailing 14 are considered, and
    ///     fewer than 3 days short-circuits to a prune of the existing records.
    ///   - goals: The user's fitness goals; the first drives the goal-behavior-gap category.
    /// - Returns: The pruned, updated record list to persist back into the blob.
    static func updateInferences(
        existing: [TierTwoMemoryRecord],
        from days: [(String, FernletDay)],
        goals: [FitnessGoal]
    ) -> [TierTwoMemoryRecord] {
        let window = Array(days.suffix(14))
        guard window.count >= 3 else { return prune(existing) }

        var updated = existing

        let candidates = [
            goalBehaviorGap(window: window, goals: goals),
            consistencyProfile(window: window),
            journalAvoidancePattern(window: window),
            workoutMoodCorrelation(window: window)
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

    /// Infers whether logged behavior (workout/meal/journal/sleep rates) matches the primary
    /// stated goal, producing an aligned/partial/misaligned-style state per goal type. Returns
    /// nil when the user has no goals.
    private static func goalBehaviorGap(
        window: [(String, FernletDay)],
        goals: [FitnessGoal]
    ) -> TierTwoMemoryRecord? {
        guard let primary = goals.first else { return nil }
        let n = window.count
        let workoutDays = window.filter { !$0.1.workouts.isEmpty }.count
        let mealDays = window.filter { !$0.1.meals.isEmpty }.count
        let journalDays = window.filter { !$0.1.journals.isEmpty }.count
        let workoutRate = Double(workoutDays) / Double(n)
        let mealRate = Double(mealDays) / Double(n)
        let journalRate = Double(journalDays) / Double(n)

        let text: String
        let state: String
        let evidence: String
        let confidence: String

        switch primary.type {
        case .strength, .sportsPrep:
            evidence = "\(workoutDays)/\(n) days with workouts"
            if workoutRate < 0.2 {
                state = "misaligned"; confidence = "high"
                text = "Has stated strength goals but rarely exercises in the data window; likely lacks follow-through or is in a low-motivation period."
            } else if workoutRate < 0.45 {
                state = "partial"; confidence = "medium"
                text = "Exercises occasionally but inconsistently relative to stated strength goals; partial adherence."
            } else {
                state = "aligned"; confidence = "high"
                text = "Workout behavior aligns with stated strength goals; demonstrates consistent follow-through."
            }

        case .weightManagement:
            evidence = "\(mealDays)/\(n) meal days, \(workoutDays)/\(n) workout days"
            if mealRate < 0.3 {
                state = "misaligned"; confidence = "high"
                text = "States weight management goals but rarely logs meals; tends to avoid tracking when not on plan."
            } else if workoutRate < 0.2 {
                state = "dietary_only"; confidence = "medium"
                text = "Tracks food reasonably often but seldom exercises; weight management approach is primarily dietary."
            } else {
                state = "aligned"; confidence = "high"
                text = "Actively tracking both food and exercise consistent with weight management goals."
            }

        case .mentalHealth:
            evidence = "\(journalDays)/\(n) days with journal entries"
            if journalRate < 0.25 {
                state = "misaligned"; confidence = "medium"
                text = "Has mental health goals but journals infrequently; reflective self-care behaviors are inconsistent with stated intent."
            } else {
                state = "aligned"; confidence = "medium"
                text = "Journals regularly, consistent with a mental health focus; self-reflection appears to be a real practice."
            }

        case .recovery:
            let sleepDays = window.filter { $0.1.sleep != nil }.count
            evidence = "\(sleepDays)/\(n) sleep logged, \(workoutDays)/\(n) workout days"
            let sleepRate = Double(sleepDays) / Double(n)
            if sleepRate < 0.3 && workoutRate > 0.5 {
                state = "misaligned"; confidence = "medium"
                text = "Trains frequently but rarely logs sleep or rest; recovery behaviors do not match stated recovery goals."
            } else if sleepRate >= 0.4 {
                state = "aligned"; confidence = "medium"
                text = "Sleep and recovery tracking consistent with recovery-focused goals."
            } else {
                state = "partial"; confidence = "low"
                text = "Recovery goal stated but few behaviors in the data consistently support it."
            }

        case .wellness, .exploring:
            evidence = "\(mealDays)/\(n) meal days, \(workoutDays)/\(n) workout days"
            if mealRate < 0.2 && workoutRate < 0.2 {
                state = "passive_wellness"; confidence = "high"
                text = "General wellness goal stated but almost no tracking across any domain; app engagement is minimal."
            } else {
                state = "partial"; confidence = "low"
                text = "Wellness-oriented user with intermittent engagement; no structured pattern is apparent."
            }
        }

        return TierTwoMemoryRecord(
            category: "goal_behavior_gap",
            text: text,
            state: state,
            evidence: evidence,
            confidence: confidence,
            dataWindowDays: n
        )
    }

    // MARK: Consistency Profile

    /// Classifies overall engagement — consistent / intermittent / sporadic / minimal — from the
    /// fraction of window days with any logged data at all.
    private static func consistencyProfile(window: [(String, FernletDay)]) -> TierTwoMemoryRecord? {
        let n = window.count
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
            text = "Logs intermittently — tends to engage when motivated or on good days; gaps likely reflect disengagement or avoidance."
        } else if rate >= 0.2 {
            state = "sporadic"; confidence = "medium"
            text = "Rarely logs data; engagement pattern suggests the app is used sporadically, likely only when already on track."
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
            text = "Journal entries frequently contain excuse and avoidance language rather than reflection; may use journaling to rationalize rather than confront behavior patterns."
        } else {
            state = "moderate_avoidance"; confidence = "medium"
            text = "Journal entries occasionally show avoidance patterns — citing tiredness, forgetting, or planning to act later; gap between stated intentions and follow-through is visible in writing."
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
            text = "Mood tends to be lower on workout days; may push through exercise when already depleted, or training sessions coincide with higher-stress periods."
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
}
