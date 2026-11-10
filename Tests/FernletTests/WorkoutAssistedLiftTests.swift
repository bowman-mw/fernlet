// WorkoutAssistedLiftTests.swift
// FernletTests
//
// Assisted machines (w3, 2026-11-10): on an assisted pull-up or assisted dip the number is help, so the
// load engine's step, miss back-off, cap, words, estimate and trend are all turned round
// (`WorkoutAssistedLifts`). Before the fix a good session added help under "add weight now" and two
// misses took help away under "a little lighter".

import Foundation
import Testing
@testable import FernletDomainModel
@testable import Fernlet

/// Pins the one list of assisted lifts against the catalogue, and everything the flag turns round.
@MainActor
struct WorkoutAssistedLiftTests {

    // MARK: - Fixtures

    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    func day(_ offset: Int) -> Date { Self.base.addingTimeInterval(Double(offset) * 86_400) }

    /// One structured session on a machine at `help` lb, flagged assisted unless told otherwise.
    func session(_ offset: Int, help: Double, reps: [Int], target: Int, assisted: Bool = true) -> LiftExposure {
        LiftExposure(date: day(offset), weight: help, unit: .lb, targetReps: target, repsPerSet: reps,
                     rangeLow: help - 10, rangeHigh: help + 10, structured: true, assisted: assisted)
    }

    func plan(_ history: [LiftExposure], today: Int = 30, inventory: WorkoutWeightInventory? = nil) -> LiftPlan {
        WorkoutLoadEngine.plan(WorkoutLoadEngine.LiftInputs(
            scheme: RepScheme(low: 8, high: 12), baseSets: 3, exposures: history, equipment: .machine,
            isLowerBody: false, defaultUnit: .lb, today: day(today), inventory: inventory
        ))
    }

    func line(_ plan: LiftPlan) -> String? {
        WorkoutProgram.changeLine("Assisted pull-up", plan: plan, addressing: .masculine)
    }

    // MARK: - The one list

    @Test func theListIsTheCataloguesAssistedMachines() throws {
        let rows = WorkoutExerciseCatalog.allExercises
        for name in WorkoutAssistedLifts.names {
            let row = try #require(rows.first { WorkoutExerciseCatalog.normalizedName($0.name) == name },
                                   "\(name) is not a catalogue exercise")
            #expect(row.equipment == .machine, "\(name) must be a machine row: the number is the stack's")
        }
        let named = rows.filter {
            $0.equipment == .machine && WorkoutExerciseCatalog.normalizedName($0.name).hasPrefix("assisted ")
        }
        let listed = Set(named.map { WorkoutExerciseCatalog.normalizedName($0.name) })
        #expect(listed == WorkoutAssistedLifts.names, "a new assisted machine row must be added to WorkoutAssistedLifts.names")
        #expect(WorkoutAssistedLifts.contains("Assisted Pull-Up") && WorkoutAssistedLifts.contains("  assisted dip "))
        #expect(!WorkoutAssistedLifts.contains("Band-assisted pull-up"), "a band has no number to step")
        #expect(!WorkoutAssistedLifts.contains("Pull-up") && !WorkoutAssistedLifts.contains("Lat pulldown"))
        // A logged result carries the flag from its name alone.
        let result = ExerciseResult(name: "Assisted dip", prescribedSets: 3, targetReps: 8, selectedWeight: 60, unit: .lb)
        #expect(LiftExposure(date: day(0), result: result).assisted)
        let plain = ExerciseResult(name: "Dip", prescribedSets: 3, targetReps: 8)
        #expect(!LiftExposure(date: day(0), result: plain).assisted)
    }

    // MARK: - The step and the back-off

    @Test func aGoodSessionTakesHelpAwayAndMissesGiveItBack() {
        let top = plan([session(28, help: 100, reps: [12, 12, 12], target: 12)])
        #expect((top.change, top.reps, top.prescription?.suggested) == (.backToBottom, 8, 95))
        #expect(top.assisted)
        // The same numbers on an ordinary machine add weight.
        let ordinary = plan([session(28, help: 100, reps: [12, 12, 12], target: 12, assisted: false)])
        #expect((ordinary.change, ordinary.prescription?.suggested, ordinary.assisted) == (.backToBottom, 105, false))

        let missed = plan([26, 28].map { session($0, help: 100, reps: [8, 6, 5], target: 8) })
        #expect((missed.change, missed.prescription?.suggested) == (.lighter, 105))
        let thrice = plan([24, 26, 28].map { session($0, help: 100, reps: [8, 6, 5], target: 8) })
        #expect((thrice.change, thrice.sets, thrice.prescription?.suggested) == (.lighterFewerSets, 2, 110))
        let back = plan([session(0, help: 100, reps: [10, 10, 10], target: 10)], today: 60)
        #expect((back.change, back.prescription?.suggested) == (.afterBreak, 110))
        // One miss, or a climb inside the range, leaves the help where it was.
        let once = plan([session(28, help: 100, reps: [8, 6, 5], target: 8)])
        #expect((once.change, once.prescription?.suggested) == (.same, 100))
        let climbing = plan([session(28, help: 100, reps: [9, 9, 9], target: 9)])
        #expect((climbing.change, climbing.reps, climbing.prescription?.suggested) == (.moreReps, 10, 100))
    }

    @Test func theLightLoadGuardDoesNotHoldHelpBackAndTheLeastHelpIsTheEnd() {
        // 20 → 15 lb is a quarter of the number, but a small part of the load moved: it steps.
        let light = plan([session(28, help: 20, reps: [12, 12, 12], target: 12)])
        #expect((light.change, light.prescription?.suggested, light.cap) == (.backToBottom, 15, nil))
        // At one step of help there is no less: reps, one set, then topped out.
        let least = plan([session(28, help: 5, reps: [12, 12, 12], target: 12)])
        #expect((least.change, least.reps, least.prescription?.suggested) == (.repsFirst, 13, 5))
        #expect(least.cap == .leastHelp(bottom: 5))
        let set = plan([session(28, help: 5, reps: [15, 15, 15], target: 15)])
        #expect((set.change, set.sets) == (.setFirst, 4))
        let topped = plan([26, 28].map { session($0, help: 5, reps: [15, 15, 15], target: 15) })
        #expect((topped.change, topped.sets, topped.prescription?.suggested) == (.toppedOut, 4, 5))
    }

    @Test func helpIsPlacedTowardMoreHelpNeverAJumpHarder() throws {
        // A stack that goes 20, 40, 70: 60 lb of help from another gym lands on 70, not on 40.
        let ladder = try #require(LoadLadder([20, 40, 70]))
        #expect(WorkoutLoadEngine.placed(48, on: ladder, assisted: true) == 70)
        #expect(WorkoutLoadEngine.placed(42, on: ladder, assisted: true) == 40, "inside the guard, the nearest")
        #expect(WorkoutLoadEngine.placed(90, on: ladder, assisted: true) == 70, "nothing above: the most help there is")
        #expect(WorkoutLoadEngine.helpMoved(40, by: .up, step: 5, ladder: ladder) == 20)
        #expect(WorkoutLoadEngine.helpMoved(40, by: .down(WorkoutLoadEngine.missDecrease), step: 5, ladder: ladder) == 70)
        #expect(WorkoutLoadEngine.helpCap(from: 20, step: 5, ladder: ladder) == .leastHelp(bottom: 20))
        #expect(WorkoutLoadEngine.helpCap(from: 40, step: 5, ladder: ladder) == nil)
    }

    // MARK: - The words

    @Test func theNotesSayLessHelpAndMoreHelp() throws {
        let less = try #require(line(plan([session(28, help: 100, reps: [12, 12, 12], target: 12)])))
        #expect(less == "Assisted pull-up: back to 8 reps — a little less help now (95 lb).")
        let more = try #require(line(plan([26, 28].map { session($0, help: 100, reps: [8, 6, 5], target: 8) })))
        #expect(more == "Assisted pull-up: a little more help today (105 lb) to get the reps back.")
        let reset = try #require(line(plan([24, 26, 28].map { session($0, help: 100, reps: [8, 6, 5], target: 8) })))
        #expect(reset == "Assisted pull-up: more help and one set fewer today — a reset, not a step back.")
        let back = try #require(line(plan([session(0, help: 100, reps: [10, 10, 10], target: 10)], today: 60)))
        #expect(back == "Assisted pull-up: welcome back — a little more help to start.")
        let fixed = WorkoutLoadEngine.plan(WorkoutLoadEngine.LiftInputs(
            scheme: RepScheme(low: 5, high: 5), baseSets: 3,
            exposures: [session(28, help: 100, reps: [5, 5, 5], target: 5)], equipment: .machine,
            isLowerBody: false, defaultUnit: .lb, today: day(30)
        ))
        #expect(line(fixed) == "Assisted pull-up: a little less help today (95 lb).")
        let least = try #require(line(plan([session(28, help: 5, reps: [12, 12, 12], target: 12)])))
        #expect(least == "Assisted pull-up: 5 lb is the least help here, so more reps instead — 13 today.")
        let set = try #require(line(plan([session(28, help: 5, reps: [15, 15, 15], target: 15)])))
        #expect(set == "Assisted pull-up: one more set today — 5 lb is the least help here.")
        // Nothing an assisted lift is told says "add weight", "lighter" or "heavier".
        for note in [less, more, reset, back, least, set] {
            #expect(!note.contains("add weight") && !note.contains("lighter") && !note.contains("heavier"), "\(note)")
        }
        // An ordinary machine keeps its own words.
        let ordinary = plan([session(28, help: 100, reps: [12, 12, 12], target: 12, assisted: false)])
        #expect(line(ordinary) == "Assisted pull-up: back to 8 reps — add weight now (105 lb).")
    }

    // MARK: - The estimate and the trend

    @Test func theHelpNumberIsNoOneRepMax() {
        let good = session(28, help: 60, reps: [8, 8, 8], target: 8)
        #expect(WorkoutLoadEngine.estimatedMax(of: good, in: .lb) == nil)
        #expect(WorkoutLoadEngine.estimate(from: [session(21, help: 60, reps: [8, 8, 8], target: 8), good],
                                           unit: .lb, today: day(30)) == nil)
        // So a goal change keeps the help rather than loading it from an "estimate".
        let fives = WorkoutLoadEngine.plan(WorkoutLoadEngine.LiftInputs(
            scheme: RepScheme(low: 5, high: 5), baseSets: 3, exposures: [good], equipment: .machine,
            isLowerBody: false, defaultUnit: .lb, today: day(30)
        ))
        #expect((fives.change, fives.reps, fives.prescription?.suggested) == (.addWeight, 5, 55))
    }

    @Test func lessHelpReadsAsStrongerInTheTrend() throws {
        let more = try #require(WorkoutTrend.sessionScore(of: session(0, help: 60, reps: [8, 8, 8], target: 8), in: .lb, bodyWeightKg: 80))
        let less = try #require(WorkoutTrend.sessionScore(of: session(0, help: 40, reps: [8, 8, 8], target: 8), in: .lb, bodyWeightKg: 80))
        #expect(less > more)
        let moved = 80 * LoadUnit.poundsPerKilogram - 40
        #expect(abs(less - moved * (1 + 10.0 / 30)) < 0.001, "body weight less the help, through the usual estimate")
        // An ordinary machine reads the other way, as it always did.
        let heavy = try #require(WorkoutTrend.sessionScore(of: session(0, help: 60, reps: [8, 8, 8], target: 8, assisted: false), in: .lb))
        let light = try #require(WorkoutTrend.sessionScore(of: session(0, help: 40, reps: [8, 8, 8], target: 8, assisted: false), in: .lb))
        #expect(heavy > light)
        // With no body weight known a reference stands in, and help past body weight still scores.
        #expect(WorkoutAssistedLifts.effectiveLoad(help: 40, unit: .kg, bodyWeightKg: nil) == 35)
        #expect(WorkoutAssistedLifts.effectiveLoad(help: 400, unit: .kg, bodyWeightKg: 80) == WorkoutAssistedLifts.minimumEffectiveLoadKg)
        #expect(WorkoutAssistedLifts.effectiveLoad(help: 40, unit: .kg, bodyWeightKg: -3) == 35)
    }

    @Test func needingLessHelpEachWeekIsProgressNotAStall() throws {
        // Twelve weeks, three sessions a week of 3 × 8, the help coming down 5 lb a week from 100.
        let improving = (0..<12).flatMap { week in
            [0, 2, 4].map { session(week * 7 + $0, help: 100 - 5 * Double(week), reps: [8, 8, 8], target: 8) }
        }
        let scores = WorkoutTrend.points(from: improving, unit: .lb, bodyWeightKg: 80).map(\.score)
        #expect(scores.count == improving.count)
        #expect(zip(scores, scores.dropFirst()).allSatisfy { $0.0 <= $0.1 }, "less help never scores lower")
        #expect(try #require(scores.last) > (try #require(scores.first)))
        let profile = TrendProfile(traits: LifterTraits(bodyWeightKg: 80))
        #expect(WorkoutPlateau.status(of: improving, unit: .lb, today: day(82), profile: profile) == nil)
        // Read as load — the old way — the same history is twelve weeks of decline.
        let asLoad = improving.map { exposure -> LiftExposure in
            var copy = exposure
            copy.assisted = false
            return copy
        }
        #expect(WorkoutPlateau.status(of: asLoad, unit: .lb, today: day(82), profile: profile) != nil)
    }
}
