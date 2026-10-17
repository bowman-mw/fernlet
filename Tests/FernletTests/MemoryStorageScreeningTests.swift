import Foundation
import Testing
import FernletDomainModel
import AIContext
@testable import LocalPersistence
@testable import Fernlet

/// Spec §8: the diagnostic-language post-classifier must run on every proposed memory
/// *before* storage, not only at AI-prompt read-time. These tests pin the storage-time gate.
@Suite struct MemoryStorageScreeningTests {

    // MARK: - String classifier

    @Test func stringClassifierFlagsDiagnosticText() {
        #expect(MemoryAgent.containsDiagnosticLanguage("I'm dealing with depression lately"))
        #expect(MemoryAgent.containsDiagnosticLanguage("started a new medication"))
        #expect(MemoryAgent.containsDiagnosticLanguage("notes about my cycle"))
    }

    @Test func stringClassifierPassesCleanText() {
        #expect(!MemoryAgent.containsDiagnosticLanguage("had a great workout and felt strong"))
        #expect(!MemoryAgent.containsDiagnosticLanguage("cooked a nice dinner with friends"))
    }

    // MARK: - Normalization defeats trivial separator-injection evasions

    @Test func classifierCatchesSpacingAndPunctuationEvasions() {
        // Intra-word spacing / punctuation that the old plain-substring match let through.
        #expect(DiagnosticLanguage.contains("d e p r e s s i o n"))
        #expect(DiagnosticLanguage.contains("anxie.ty"))
        #expect(DiagnosticLanguage.contains("bi-polar"))
        #expect(DiagnosticLanguage.contains("p.t.s.d"))
        // The self-harm pair is the leakiest term — every separator variant must still match.
        #expect(DiagnosticLanguage.contains("self harm"))
        #expect(DiagnosticLanguage.contains("self-harm"))
        #expect(DiagnosticLanguage.contains("self_harm"))
        #expect(DiagnosticLanguage.contains("self  harm"))
        #expect(DiagnosticLanguage.contains("selfharm"))
    }

    @Test func classifierStillPassesCleanTextUnderNormalization() {
        // Stripping separators must not manufacture a banned token from these clean phrases.
        #expect(!DiagnosticLanguage.contains("Works out 3x per week on average"))
        #expect(!DiagnosticLanguage.contains("Tends to walk daily"))
        #expect(!DiagnosticLanguage.contains("Felt really proud finishing the long walk by the river today"))
    }

    // MARK: - Tier-1 (journal-derived) memory at creation — owner decision 2026-09-23
    //
    // These two pinned the old `MemoryNote.fromJournal`, which stored a 120-character EXCERPT of the
    // entry (rejecting one that held clinical language). A journal entry now mints an EMOTION-ONLY
    // memory — no text to screen at all — and the screen moved to the AI summary that may replace
    // it (`JournalMemorySummaryPolicy`, pinned in JournalMemoryCaptureTests).

    /// The entry that used to be rejected for its clinical language now leaves only its feeling:
    /// nothing of the words is proposed for storage, so there is nothing for the screen to catch.
    @Test func journalMemoryForAnEntryWithClinicalLanguageKeepsOnlyTheFeeling() throws {
        let note = try #require(MemoryNote.emotionOnly(for: JournalEntry(
            text: "I think I have anxiety and should probably start therapy soon",
            tag: .hard
        )))
        #expect(note.text.isEmpty)
        #expect(note.category == FeelingTag.hard.rawValue)
        #expect(!MemoryAgent.containsDiagnosticLanguage(note.text + " " + note.category))
    }

    @Test func journalMemoryForACleanReflectionKeepsOnlyTheFeeling() throws {
        let note = try #require(MemoryNote.emotionOnly(for: JournalEntry(
            text: "Felt really proud finishing the long walk by the river today",
            tag: .bright
        )))
        #expect(note.category == FeelingTag.bright.rawValue)
        #expect(note.text.isEmpty, "Core Memory must never hold the entry's words")
    }

    /// The storage-time screen still runs — on the AI summary, before it may become memory text.
    @Test func aiJournalSummaryWithDiagnosticLanguageIsRejectedBeforeStorage() {
        #expect(JournalMemorySummaryPolicy.accepted(
            "Worried the anxiety is back and thinking about therapy",
            entryText: "A long day at work. I could not settle down all evening."
        ) == nil)
        #expect(JournalMemorySummaryPolicy.accepted(
            "An unsettled evening after a long workday",
            entryText: "A long day at work. I could not settle down all evening."
        ) == "An unsettled evening after a long workday")
    }

    // MARK: - The spec's whole deny list (bug confirmation 2026-10-15, safety §1)

    /// Spec §8's `DIAGNOSTIC_PATTERNS`, verbatim. Nine of these passed before: "depressed" is not
    /// "depression" and "anxious" is not "anxiety", and the rest were never listed.
    static let specDiagnosticTerms = [
        "depressed", "anxious", "ADHD", "bipolar", "traumatized", "burned out", "codependent",
        "avoidant", "OCD", "PTSD", "insomnia", "panic disorder", "eating disorder", "manic",
        "dissociation", "narcissism"
    ]

    @Test func classifierCatchesEverySpecDiagnosticTerm() {
        for term in Self.specDiagnosticTerms {
            #expect(DiagnosticLanguage.contains(term), "spec §8 term not caught: \(term)")
            #expect(DiagnosticLanguage.contains("Felt \(term.uppercased()) this week."), "in a sentence: \(term)")
        }
        #expect(DiagnosticLanguage.contains("burnt out after the move"))
        #expect(DiagnosticLanguage.contains("a manic, scattered afternoon"))
        // The confirmed scenario: an AI journal summary that used to become synced Core Memory text.
        #expect(JournalMemorySummaryPolicy.accepted(
            "Felt anxious and burned out at work",
            entryText: "Work was a lot today."
        ) == nil)
    }

    /// "manic" is matched as a whole word, so the ordinary words around it are not rejected — and
    /// neither is a phrase that fuses into it once spaces are dropped.
    @Test func wholeWordTermsLeaveOrdinaryWordsAlone() {
        #expect(!DiagnosticLanguage.contains("Got a manicure after the long walk"))
        #expect(!DiagnosticLanguage.contains("Read about Germanic languages on the train"))
        #expect(!DiagnosticLanguage.contains("The woman I cooked for loved the soup"))
        #expect(!DiagnosticLanguage.contains("Avoided the rain by taking the bus"))
        #expect(!DiagnosticLanguage.contains("Pressed the reset button on the week"))
    }

    // MARK: - Tier-2 engine copy (bug confirmation 2026-10-15, safety §1)

    /// Every one of the engine's 22 verdicts can be stored. Two could not: the strength
    /// "misaligned" text said "low-motivation period" and "mood_drain" said "higher-stress
    /// periods", so the post-classifier dropped them and the previous verdict stayed active.
    @Test func everyTierTwoVerdictIsReachableAndPassesTheScreen() {
        let reached = Self.tierTwoVerdictsAcrossAGrid()
        #expect(reached.keys.sorted() == Self.expectedTierTwoVerdicts.sorted(),
                "missing: \(Set(Self.expectedTierTwoVerdicts).subtracting(reached.keys).sorted())")
        for (verdict, record) in reached {
            #expect(!DiagnosticLanguage.contains(record.text + " " + record.evidence), "\(verdict) fails the screen")
        }
    }

    /// The engine describes; it does not judge. These phrasings reached the companion's prompt as
    /// "user pattern:" lines before 2026-10-16.
    @Test func noTierTwoVerdictUsesJudgmentalFraming() {
        let judgmental = [
            "lacks follow-through", "low-motivation", "avoid", "excuse", "rationalize", "confront",
            "disengagement", "already on track"
        ]
        for (verdict, record) in Self.tierTwoVerdictsAcrossAGrid() {
            let text = record.text.lowercased()
            for phrase in judgmental {
                #expect(!text.contains(phrase), "\(verdict) says \"\(phrase)\"")
            }
        }
    }

    /// A changed verdict supersedes its predecessor — including the two that used to be dropped,
    /// which left the stale "aligned" / "mood_boost" verdict active for up to 30 days.
    @Test func aChangedTierTwoVerdictSupersedesItsPredecessor() throws {
        let strength = [FitnessGoal(type: .strength, goal: "Get stronger", timeframe: "8 weeks", metric: "lifts")]
        let aligned = TierTwoMemoryEngine.updateInferences(
            existing: [], from: Self.window(workouts: 5), goals: strength
        )
        let before = try #require(aligned.first { $0.category == "goal_behavior_gap" && $0.active })
        #expect(before.state == "aligned")
        let rare = TierTwoMemoryEngine.updateInferences(
            existing: aligned, from: Self.window(workouts: 1), goals: strength
        )
        let gaps = rare.filter { $0.category == "goal_behavior_gap" }
        #expect(gaps.first { $0.id == before.id }?.active == false, "the stale verdict is still active")
        #expect(gaps.filter(\.active).map(\.state) == ["misaligned"])

        let boost = TierTwoMemoryEngine.updateInferences(
            existing: [], from: Self.window(workouts: 3, journals: 5, moods: (.bright, .tired)), goals: []
        )
        let drain = TierTwoMemoryEngine.updateInferences(
            existing: boost, from: Self.window(workouts: 3, journals: 5, moods: (.hard, .good)), goals: []
        )
        let moods = drain.filter { $0.category == "workout_mood_correlation" }
        #expect(moods.filter(\.active).map(\.state) == ["mood_drain"])
        #expect(moods.filter { !$0.active }.map(\.state) == ["mood_boost"])
    }

    /// The engine's verdicts, keyed `category|state` (the goal family first for the goal gap).
    static let expectedTierTwoVerdicts = [
        "strength|goal_behavior_gap|misaligned", "strength|goal_behavior_gap|partial",
        "strength|goal_behavior_gap|aligned",
        "weightManagement|goal_behavior_gap|misaligned", "weightManagement|goal_behavior_gap|dietary_only",
        "weightManagement|goal_behavior_gap|aligned",
        "mentalHealth|goal_behavior_gap|misaligned", "mentalHealth|goal_behavior_gap|aligned",
        "recovery|goal_behavior_gap|misaligned", "recovery|goal_behavior_gap|aligned",
        "recovery|goal_behavior_gap|partial",
        "wellness|goal_behavior_gap|passive_wellness", "wellness|goal_behavior_gap|partial",
        "consistency_profile|consistent", "consistency_profile|intermittent",
        "consistency_profile|sporadic", "consistency_profile|minimal",
        "journal_avoidance_pattern|high_avoidance", "journal_avoidance_pattern|moderate_avoidance",
        "workout_mood_correlation|mood_boost", "workout_mood_correlation|mood_drain",
        "workout_mood_correlation|neutral"
    ]

    /// Every verdict the engine STORES over a grid of ten-day windows wide enough to reach each
    /// branch (each count is a prefix of the window's days), keyed as ``expectedTierTwoVerdicts``.
    static func tierTwoVerdictsAcrossAGrid() -> [String: TierTwoMemoryRecord] {
        let families: [GoalType] = [.strength, .weightManagement, .mentalHealth, .recovery, .wellness]
        let moodPairs: [(FeelingTag, FeelingTag)] = [(.bright, .tired), (.hard, .good), (.good, .good)]
        var reached: [String: TierTwoMemoryRecord] = [:]
        for family in families {
            let goal = FitnessGoal(type: family, goal: "Feel steadier", timeframe: "8 weeks", metric: "days")
            for workouts in [1, 3, 5, 6] {
                for meals in [1, 2, 5, 8] {
                    for journals in [0, 2, 5] {
                        for sleep in [0, 2, 3, 5] {
                            for putOff in [0, 2, 4] {
                                for moods in moodPairs {
                                    let days = window(workouts: workouts, meals: meals, journals: journals,
                                                      sleep: sleep, putOff: putOff, moods: moods)
                                    for record in TierTwoMemoryEngine.updateInferences(existing: [], from: days, goals: [goal]) {
                                        let key = record.category == "goal_behavior_gap"
                                            ? "\(family)|\(record.category)|\(record.state)"
                                            : "\(record.category)|\(record.state)"
                                        reached[key] = record
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return reached
    }

    /// A ten-day window whose first `workouts` days train, first `meals` days log a meal, first
    /// `journals` days journal (the first `putOff` of them about putting something off; tagged
    /// `moods.0` on a training day, `moods.1` on a rest day) and first `sleep` days log sleep.
    static func window(
        workouts: Int = 0, meals: Int = 0, journals: Int = 0, sleep: Int = 0, putOff: Int = 0,
        moods: (FeelingTag, FeelingTag) = (.good, .good)
    ) -> [(String, FernletDay)] {
        (0..<10).map { index in
            let key = String(format: "2026-09-%02d", index + 1)
            let trains = index < workouts
            let journal = JournalEntry(
                text: index < putOff ? "Too tired tonight, maybe tomorrow." : "A calm walk by the river.",
                tag: trains ? moods.0 : moods.1
            )
            return (key, FernletDay(
                date: key,
                meals: index < meals ? [Meal(name: "Oats", mealType: .breakfast, macros: Macros(protein: 12, carbs: 40, fat: 6),
                                             quality: .good, confidence: "Manual", note: "", source: "Manual")] : [],
                workouts: trains ? [Workout(name: "Upper", type: .upper, exercises: "DB row 3x10", rpe: 7,
                                            notes: "steady", duration: 35, intensity: .moderate)] : [],
                journals: index < journals ? [journal] : [],
                sleep: index < sleep ? SleepLog(hours: 8, quality: .good, note: "Solid") : nil
            ))
        }
    }
}
