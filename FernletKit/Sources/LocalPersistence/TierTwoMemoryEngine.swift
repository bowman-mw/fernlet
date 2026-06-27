//
//  TierTwoMemoryEngine.swift
//  Fernlet
//
//  Derives Tier-2 behavioral memories from the rolling day window.
//

import Foundation
import FernletDomainModel

// MARK: - Tier Two Memory Engine

enum TierTwoMemoryEngine {

    // Each category stores at most 5 records; total is capped at 20.
    // With 4 categories × 5 = 20, the per-category cap IS the global cap.
    private static let maxPerCategory = 5
    private static let maxTotal = 20

    // Compares the new 14-day window against existing records.
    // Only appends when the behavioral state for a category has actually changed.
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

    // Keeps the most recent maxPerCategory records per category.
    // If still over maxTotal, drops oldest inactive records first.
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

    private static func workoutMoodCorrelation(window: [(String, FernletDay)]) -> TierTwoMemoryRecord? {
        let workoutWithMood = window.filter { !$0.1.workouts.isEmpty && !$0.1.journals.isEmpty }
        let restWithMood = window.filter { $0.1.workouts.isEmpty && !$0.1.journals.isEmpty }
        guard workoutWithMood.count >= 2, restWithMood.count >= 2 else { return nil }

        func avgMood(_ pairs: [(String, FernletDay)]) -> Double {
            let scores = pairs.flatMap { $0.1.journals }.map { moodScore($0.tag) }
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

    private static func moodScore(_ tag: FeelingTag) -> Double {
        switch tag {
        case .bright: return 1
        case .good: return 0.85
        case .neutral: return 0.65
        case .quiet: return 0.55
        case .tired: return 0.35
        case .hard: return 0.2
        }
    }
}
