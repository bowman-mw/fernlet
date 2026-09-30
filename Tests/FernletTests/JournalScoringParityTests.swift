import Foundation
import CryptoKit
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
///
/// Check-ins count half (owner, 2026-09-24): "maybe a check in is worth half the points of a journal
/// entry", confirmed as half the credit ABOVE not journaling. A day holding only one-tap mood
/// check-ins earns 0.55 + 0.45 / 2 = 0.775, never less than writing nothing. One written entry that
/// day earns the full 1.0. The check-in's tag still feeds the mood reading exactly as before.
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

    // MARK: - Check-ins count half (2026-09-24)

    /// A one-tap mood check-in exactly as `FernletStore.logQuickMood` writes it.
    private static func checkIn(_ tag: FeelingTag) -> JournalEntry {
        JournalEntry(text: "", tag: tag, isQuickMood: true)
    }

    /// A written journal entry.
    private static func written(_ tag: FeelingTag) -> JournalEntry {
        JournalEntry(text: "wrote a little about the day", tag: tag)
    }

    /// One ordinary day that differs only in its journal entries, derived the way both production
    /// call sites derive it: the last entry's tag, and `isCheckInOnly` over the whole day.
    private func breakdown(journals: [JournalEntry], goal: GoalType = .wellness) -> ScoreBreakdown {
        FernletScoring.computeBreakdown(
            journalTag: journals.last?.tag,
            journalIsCheckInOnly: FernletScoring.isCheckInOnly(journals),
            mealCount: 2,
            workoutCount: 1,
            sleepQuality: .good,
            bottleCount: 2,
            hydrationTarget: 4,
            hygiene: [],
            weights: GoalWeights.forGoal(goal)
        )
    }

    @Test func aCheckInIsWorthHalfTheCreditAboveNotJournaling() {
        // Pinned as a number, not only as the formula, so a change to either constant shows up here.
        #expect(FernletScoring.checkInOnlyScore == 0.775)
        #expect(FernletScoring.checkInOnlyScore
                == FernletScoring.noJournalEntryScore
                + (FernletScoring.journalEntryScore - FernletScoring.noJournalEntryScore) / 2)
    }

    @Test func aCheckInOnlyDayEarnsTheHalfCredit() {
        for tag in FeelingTag.allCases {
            #expect(breakdown(journals: [Self.checkIn(tag)]).components["journal"] == 0.775,
                    "a \(tag.rawValue) check-in did not earn the half credit")
        }
        let twoCheckIns = breakdown(journals: [Self.checkIn(.good), Self.checkIn(.tired)])
        #expect(twoCheckIns.components["journal"] == 0.775, "more check-ins must not add up to an entry")
    }

    @Test func aCheckInPlusAWrittenEntryEarnsTheFullCredit() {
        let entryLast = breakdown(journals: [Self.checkIn(.hard), Self.written(.good)])
        let checkInLast = breakdown(journals: [Self.written(.good), Self.checkIn(.hard)])
        #expect(entryLast.components["journal"] == 1.0)
        #expect(checkInLast.components["journal"] == 1.0, "a later check-in must not cost the day its entry")
    }

    @Test func aWrittenEntryOnlyEarnsTheFullCredit() {
        for tag in FeelingTag.allCases {
            #expect(breakdown(journals: [Self.written(tag)]).components["journal"] == 1.0)
        }
    }

    @Test func noEntryKeepsTheBaseline() {
        let none = breakdown(journals: [])
        #expect(none.components["journal"] == Self.noEntryValue)
        #expect(none.components["mood"] == Self.noEntryValue)
    }

    @Test func theMoodReadingIgnoresTheCheckInRule() {
        for tag in FeelingTag.allCases {
            let checkInMood = breakdown(journals: [Self.checkIn(tag)]).components["mood"]
            #expect(checkInMood == Self.retiredJournalValues[tag], "the \(tag.rawValue) check-in's mood drifted")
            #expect(checkInMood == breakdown(journals: [Self.written(tag)]).components["mood"])
        }
        // The mood is the LAST entry's tag, check-in or not: the existing same-day semantics.
        #expect(breakdown(journals: [Self.written(.bright), Self.checkIn(.hard)]).components["mood"] == 0.3)
        #expect(breakdown(journals: [Self.checkIn(.hard), Self.written(.bright)]).components["mood"] == 1.0)
    }

    @Test func overallOrderIsNoneThenCheckInThenWrittenForEveryGoal() {
        for goal in GoalType.allCases {
            let none = breakdown(journals: [], goal: goal).overall
            let checkIn = breakdown(journals: [Self.checkIn(.good)], goal: goal).overall
            let entry = breakdown(journals: [Self.written(.good)], goal: goal).overall
            #expect(none < checkIn && checkIn < entry, "\(goal.rawValue): \(none), \(checkIn), \(entry)")
            // The only difference is the journal component, weighted by the goal's journal weight.
            let weight = GoalWeights.forGoal(goal).journalWeight
            #expect(abs((entry - checkIn) - 0.225 * weight) < 1e-9, "\(goal.rawValue): \(entry - checkIn)")
        }
    }

    @Test func onlyAPositivelyMarkedEmptyEntryIsACheckIn() {
        #expect(!FernletScoring.isCheckInOnly([]), "no entries is not a check-in day")
        #expect(FernletScoring.isCheckInOnly([Self.checkIn(.quiet)]))
        // A sealed entry from another device (or read while locked) has empty text and no marker. It is
        // a written entry whose words live elsewhere, and a pre-marker check-in decodes the same way.
        let strippedSeal = JournalEntry(text: "", tag: .good, isQuickMood: false)
        #expect(!FernletScoring.isCheckInOnly([strippedSeal]))
        #expect(!FernletScoring.isCheckInOnly([Self.checkIn(.good), strippedSeal]))
        #expect(breakdown(journals: [strippedSeal]).components["journal"] == 1.0)
        // A marked entry that somehow carries words is a written entry.
        let markedWithText = JournalEntry(text: "words", tag: .good, isQuickMood: true)
        #expect(!FernletScoring.isCheckInOnly([markedWithText]))
    }

    @Test func callersThatNeverPassTheFlagScoreAsBefore() {
        // `journalIsCheckInOnly` defaults to false, so the identity-preserving default holds.
        #expect(breakdown(.good).components["journal"] == 1.0)
        #expect(FernletScoring.journalComponentScore(for: .good) == 1.0)
        #expect(FernletScoring.journalComponentScore(for: nil, checkInOnly: true) == Self.noEntryValue,
                "a check-in flag with no entry is still no entry")
    }

    /// Both production call sites: `DiaryStore.scoreBreakdown(for:)` (every stored day score) and
    /// `FernletStore.score` (today's live companion).
    @Test func bothScorePathsGiveACheckInOnlyDayTheHalfCredit() {
        let store = makeTestStore()
        store.activateSealedJournals(contentKey: .journalTestKey)
        store.logQuickMood(.good)
        #expect(store.scoreBreakdown(for: store.day).components["journal"] == FernletScoring.checkInOnlyScore)
        let checkInOnly = store.score
        store.addJournal(text: "wrote a real entry about the day", tag: .good)
        #expect(store.scoreBreakdown(for: store.day).components["journal"] == FernletScoring.journalEntryScore)
        let written = store.score
        let weight = GoalWeights.forGoal(store.settings.selectedGoal).journalWeight
        #expect(abs((written - checkInOnly) - 0.225 * weight) < 1e-9,
                "the live score moved \(written - checkInOnly), not the half credit's \(0.225 * weight)")
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
