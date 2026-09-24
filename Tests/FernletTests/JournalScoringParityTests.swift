import Foundation
import Testing
import FernletDomainModel
import FernletScoring
import PeriodContextBridge
@testable import Fernlet

/// Journaling scores the same whatever kind of day it was.
///
/// Owner decision, 2026-09-23: "journaling, no matter the type of day, should score the same amount
/// of points. The point is to encourage these habits." Before it, the journal component was weighted
/// by the entry's feeling tag (hard 0.30, tired 0.40, quiet 0.55, neutral 0.60, good 0.85, bright
/// 1.0) and a day with NO entry read 0.55 — so writing about a hard day scored below not writing at
/// all. Now every entry earns the same value, the top of the retired scale, and a day without an
/// entry keeps its 0.55.
///
/// The tag still matters, just never as points: it survives as the unweighted `"mood"` breakdown
/// entry, which is what the period bridge correlates against cycle phase. Flattening the journal
/// component without that would have turned "mood tends to be tender in this phase" into "you
/// journal less in this phase" and fed the wrong answer to period-aware leniency.
@MainActor
struct JournalScoringParityTests {

    /// What each tag earned before the flattening. Pinned here, not read back from the engine, so
    /// "no one loses points for writing" is checked against the retired values rather than against
    /// whatever the engine says today.
    private static let retiredJournalValues: [FeelingTag: Double] = [
        .bright: 1.0, .good: 0.85, .neutral: 0.6, .quiet: 0.55, .tired: 0.4, .hard: 0.3
    ]

    /// The retired value of a day with no journal entry, which the flattening keeps.
    private static let noEntryValue = 0.55

    /// One ordinary day that differs only in its journal tag.
    private func breakdown(_ tag: FeelingTag?, goal: GoalType = .wellness) -> ScoreBreakdown {
        FernletScoring.computeBreakdown(
            journalTag: tag,
            mealCount: 2,
            workoutCount: 1,
            sleepQuality: .good,
            bottleCount: 2,
            hydrationTarget: 4,
            hygiene: [],
            weights: GoalWeights.forGoal(goal)
        )
    }

    // MARK: - The journal component

    @Test func everyFeelingTagEarnsTheSameJournalComponent() {
        let values = FeelingTag.allCases.map { breakdown($0).components["journal"] ?? -1 }
        #expect(Set(values).count == 1, "the journal component still depends on the tag: \(values)")
        #expect(values.allSatisfy { $0 == 1.0 }, "an entry should earn the top of the retired scale: \(values)")
    }

    @Test func anyEntryScoresAboveNoEntry() {
        let none = breakdown(nil).components["journal"] ?? -1
        #expect(none == Self.noEntryValue, "a day with no entry should keep its 0.55")
        for tag in FeelingTag.allCases {
            let written = breakdown(tag).components["journal"] ?? -1
            #expect(written > none, "a \(tag.rawValue) entry scored \(written), not above no entry (\(none))")
        }
    }

    @Test func noTaggedEntryScoresLowerThanItUsedTo() {
        for tag in FeelingTag.allCases {
            let now = breakdown(tag).components["journal"] ?? -1
            let before = Self.retiredJournalValues[tag] ?? 2
            #expect(now >= before, "a \(tag.rawValue) entry lost points: \(before) → \(now)")
        }
    }

    // MARK: - The overall score

    @Test func theOverallScoreNoLongerDependsOnTheTag() {
        for goal in GoalType.allCases {
            let overalls = Set(FeelingTag.allCases.map { breakdown($0, goal: goal).overall })
            #expect(overalls.count == 1, "\(goal.rawValue): a hard day's entry and a bright day's entry still score differently")
        }
    }

    @Test func writingAlwaysBeatsNotWritingOverall() {
        for goal in GoalType.allCases {
            let none = breakdown(nil, goal: goal).overall
            for tag in FeelingTag.allCases {
                #expect(breakdown(tag, goal: goal).overall > none,
                        "\(goal.rawValue): a \(tag.rawValue) entry did not beat not writing")
            }
        }
    }

    // MARK: - The mood reading the period bridge still needs

    @Test func moodReadingKeepsTheRetiredTagScale() {
        for tag in FeelingTag.allCases {
            #expect(breakdown(tag).components["mood"] == Self.retiredJournalValues[tag],
                    "the \(tag.rawValue) mood reading drifted from the retired scale")
        }
        #expect(breakdown(nil).components["mood"] == Self.noEntryValue)
    }

    @Test func periodBridgeReadsTheMoodNotTheFlatJournalCredit() {
        let store = makeTestStore()
        store.dailyScores = [
            // Written after the flattening: "journal" is the flat credit, "mood" is how it felt.
            DailyHealthScore(dateKey: "2026-09-01", score: 0.7, companionState: .okay, computedAt: Date(),
                             componentScores: ["journal": 1.0, "mood": 0.3, "sleep": 0.8, "workout": 0.45, "meal": 0.75]),
            // Written before it: this row's "journal" WAS the tag-weighted mood, and has no "mood".
            DailyHealthScore(dateKey: "2026-08-31", score: 0.6, companionState: .okay, computedAt: Date(),
                             componentScores: ["journal": 0.4, "sleep": 0.6])
        ]
        let byDay = store.periodWellbeingByDay
        #expect(byDay["2026-09-01"]?.mood == 0.3, "the bridge read the flat journal credit as mood")
        #expect(byDay["2026-08-31"]?.mood == 0.4, "a legacy row lost its mood reading")
        #expect(byDay["2026-09-01"]?.sleep == 0.8)
    }
}
