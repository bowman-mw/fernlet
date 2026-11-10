import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Pins the reviewed record of the body areas each bundled exercise loads (the owner's fix e1,
/// 2026-11-10): every catalogue row has one, it never says less than the muscle and pattern rules
/// it sits on, a severe area keeps nothing the record names and a mild one nothing it marks hard,
/// the leaks the 2026-11-09 review named stay closed, an exercise with no record keeps the older
/// rules, and every area still leaves a session's worth of work.
///
/// ``ownerReviewListing()`` also writes the owner's per-area listing when asked to
/// (`EXERCISE_AREA_LOADS_OUT`), from the same calls the planner makes.
@MainActor
struct ExerciseAreaLoadTests {

    // MARK: - Fixtures

    /// One catalogue row's record as the repository's JSON spells it: load and note tokens by area.
    struct RawRecord {
        var loads: [String: String]
        var notes: [String: String]
    }

    /// The catalogue rows read from the repository, so a check cannot pass against an empty bundle.
    static func rows() throws -> [ExerciseTarget] {
        let data = try Data(contentsOf: RepoRoot.url("App/Fernlet/WorkoutExercises.json"))
        return try JSONDecoder().decode([ExerciseTarget].self, from: data)
    }

    /// Each row's raw record by frozen name; a row without an `areaLoads` key is absent.
    static func rawRecords() throws -> [String: RawRecord] {
        let data = try Data(contentsOf: RepoRoot.url("App/Fernlet/WorkoutExercises.json"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        var records: [String: RawRecord] = [:]
        for row in json {
            guard let name = row["name"] as? String, let loads = row["areaLoads"] as? [String: String] else { continue }
            records[name] = RawRecord(loads: loads, notes: row["areaLoadNotes"] as? [String: String] ?? [:])
        }
        return records
    }

    static func severe(_ area: BodyArea) -> InjuryLimits { InjuryLimits(severeAreas: [area]) }
    static func mild(_ area: BodyArea) -> InjuryLimits { InjuryLimits(mildAreas: [area]) }

    func feasibleNames(_ areas: [BodyArea: InjurySeverity]) -> Set<String> {
        Set(WorkoutSafetyFilter.feasibleExercises(
            in: WorkoutExerciseCatalog.baseExercises, location: .fullGym, profile: WorkoutProfile(injuryAreas: areas)
        ).map(\.name))
    }

    // MARK: - Every exercise is reviewed

    /// A new exercise cannot ship unreviewed: every row carries an `areaLoads` map (empty means
    /// "reviewed, loads nothing") of known tokens, and one phrase of reasoning per entry.
    @Test func everyBundledExerciseHasAnExplicitRecord() throws {
        let rows = try Self.rows()
        let raw = try Self.rawRecords()
        #expect(rows.count == 199)
        #expect(WorkoutExerciseCatalog.baseExercises.map(\.name) == rows.map(\.name), "the host bundle carries this catalogue")
        let areaTokens = Set(BodyArea.allCases.map(\.rawValue))
        let loadTokens = Set(AreaLoad.allCases.map(\.rawValue))
        for row in rows {
            let record = try #require(raw[row.name], "\(row.name) has no areaLoads record")
            #expect(Set(record.loads.keys).isSubset(of: areaTokens), "\(row.name)")
            #expect(Set(record.loads.values).isSubset(of: loadTokens), "\(row.name)")
            #expect(Set(record.notes.keys) == Set(record.loads.keys), "\(row.name): one reason per recorded load")
            #expect(record.notes.values.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, "\(row.name)")
            let shipped = try #require(WorkoutExerciseCatalog.areaLoads(for: row), "\(row.name)")
            #expect(shipped == ExerciseAreaLoads(tokens: record.loads), "\(row.name)")
        }
    }

    /// The frozen load tokens, and the tolerant read: an unknown area is skipped, an unknown load
    /// on a known area reads as hard (the safe direction).
    @Test func loadTokensAreFrozenAndReadTolerantly() {
        #expect(AreaLoad.allCases.map(\.rawValue) == ["light", "hard"])
        let record = ExerciseAreaLoads(tokens: ["knee": "light", "jaw": "hard", "hip": "crushing"])
        #expect(record == ExerciseAreaLoads([.knee: .light, .hip: .hard]))
        #expect(record.load(on: .knee) == .light && record.load(on: .neck) == nil)
    }

    /// The record only adds to the older rules: whatever the muscle tags, patterns and the spine
    /// rule already count as loading an area is recorded, and their heavy end is recorded hard. So
    /// the record is the whole answer for a bundled exercise, and the owner's listing explains
    /// every removal.
    @Test func theRecordNeverSaysLessThanTheFloor() throws {
        for row in try Self.rows() {
            let record = try #require(WorkoutExerciseCatalog.areaLoads(for: row), "\(row.name)")
            for area in BodyArea.allCases {
                if area.isLoaded(by: row, primaryOnly: false) {
                    #expect(record.load(on: area) != nil, "\(row.name) loads the \(area.rawValue) by its tags")
                }
                if InjuryLimits.isHeavyLoading(row), area.isLoaded(by: row, primaryOnly: true) {
                    #expect(record.load(on: area) == .hard, "\(row.name) is the heavy end for the \(area.rawValue)")
                }
            }
        }
    }

    // MARK: - What severe and mild keep

    /// Every exercise against every area: severe keeps exactly the exercises the record does not
    /// name for the area, mild exactly the ones it does not mark hard.
    @Test func severeKeepsNothingRecordedAndMildNothingHard() throws {
        for row in try Self.rows() {
            let record = try #require(WorkoutExerciseCatalog.areaLoads(for: row), "\(row.name)")
            for area in BodyArea.allCases {
                let load = record.load(on: area)
                #expect(Self.severe(area).allows(row) == (load == nil), "severe \(area.rawValue): \(row.name)")
                #expect(Self.mild(area).allows(row) == (load != .hard), "mild \(area.rawValue): \(row.name)")
            }
        }
    }

    /// The leaks the 2026-11-09 review named (finding E1), each pinned closed.
    @Test func theNamedLeaksAreClosed() {
        let wrist = feasibleNames([.wristHand: .severe])
        for name in ["Push-up", "Plank", "Bench press", "Overhead press", "Dip", "Barbell row"] {
            #expect(!wrist.contains(name), "severe wrist or hand: \(name)")
        }
        let shoulder = feasibleNames([.shoulder: .severe])
        for name in ["Pull-up", "Lat pulldown", "Hanging leg raise", "Hanging knee raise", "Dumbbell pullover",
                     "Dumbbell overhead triceps extension", "Cable overhead triceps extension",
                     "Band overhead triceps extension"] {
            #expect(!shoulder.contains(name), "severe shoulder: \(name)")
        }
        let back = feasibleNames([.lowerBack: .severe])
        for name in ["Barbell row", "Farmer's carry", "Rowing machine"] {
            #expect(!back.contains(name), "severe lower back: \(name)")
        }
        #expect(!feasibleNames([.ankleFoot: .mild]).contains("Squat jump"))
        #expect(!feasibleNames([.knee: .severe]).contains("Single-leg stance"))
    }

    /// Mild keeps the light, supported work and leaves the hard end out.
    @Test func mildKeepsTheLightSupportedWork() {
        let wrist = feasibleNames([.wristHand: .mild])
        #expect(!wrist.contains("Push-up") && !wrist.contains("Bench press") && !wrist.contains("Pull-up"))
        #expect(wrist.contains("Plank") && wrist.contains("Chest press machine") && wrist.contains("Dumbbell bench press"))
        let shoulder = feasibleNames([.shoulder: .mild])
        #expect(!shoulder.contains("Pull-up") && !shoulder.contains("Dumbbell pullover") && !shoulder.contains("Dip"))
        #expect(shoulder.contains("Lat pulldown") && shoulder.contains("Machine shoulder press") && shoulder.contains("Assisted pull-up"))
        let back = feasibleNames([.lowerBack: .mild])
        #expect(!back.contains("Barbell row") && !back.contains("Farmer's carry") && !back.contains("Rowing machine"))
        #expect(back.contains("Chest-supported dumbbell row") && back.contains("Dumbbell row") && back.contains("Glute bridge"))
        let ankle = feasibleNames([.ankleFoot: .mild])
        #expect(!ankle.contains("Jump rope") && !ankle.contains("Treadmill run"))
        #expect(ankle.contains("Calf raise") && ankle.contains("Stationary bike") && ankle.contains("Easy walk"))
    }

    /// The record is read by the frozen name, so a copy of a bundled exercise that lost its fields
    /// (a saved plan, a hand-built value) still meets the bundled record.
    @Test func aCopyOfABundledExerciseMeetsTheSameRecord() {
        let copy = ExerciseTarget(name: "  push-up ", primaryMuscles: [.chest])
        #expect(WorkoutExerciseCatalog.areaLoads(for: copy)?.load(on: .wristHand) == .hard)
        #expect(!Self.severe(.wristHand).allows(copy) && !Self.mild(.wristHand).allows(copy))
    }

    // MARK: - An exercise with no record

    /// A person's or a coach's own exercise has no record: it gets the muscle and pattern rules,
    /// exactly as before — not "loads nothing", and not a guess.
    @Test func aCustomExerciseKeepsTheOlderRules() {
        let handstand = ExerciseTarget(name: "Coach's handstand hold", primaryMuscles: [.chest],
                                       equipment: .bodyweight, movementPattern: .push)
        #expect(WorkoutExerciseCatalog.areaLoads(for: handstand) == nil)
        #expect(Self.severe(.wristHand).allows(handstand), "no forearm tag, no record: the older rule allows it")
        #expect(!Self.severe(.shoulder).allows(handstand), "a push still loads the shoulder")
        #expect(Self.mild(.shoulder).allows(handstand) && Self.mild(.shoulder).eases(handstand))
        let heavySquat = ExerciseTarget(name: "Coach's pause squat", primaryMuscles: [.quads],
                                        equipment: .barbell, movementPattern: .squat)
        #expect(!Self.mild(.knee).allows(heavySquat) && !Self.severe(.lowerBack).allows(heavySquat))
        #expect(InjuryLimits.empty.allows(handstand) && InjuryLimits.empty.allows(heavySquat))
    }

    /// The pure form: a record adds to the rules and never lifts one.
    @Test func aRecordAddsToTheRulesAndNeverLiftsOne() {
        let press = ExerciseTarget(name: "Probe press", primaryMuscles: [.chest], equipment: .dumbbell, movementPattern: .push)
        let hardOnWrist = ExerciseAreaLoads([.wristHand: .hard])
        let lightOnWrist = ExerciseAreaLoads([.wristHand: .light])
        #expect(!Self.severe(.wristHand).allows(press, loads: hardOnWrist) && !Self.mild(.wristHand).allows(press, loads: hardOnWrist))
        #expect(!Self.severe(.wristHand).allows(press, loads: lightOnWrist) && Self.mild(.wristHand).allows(press, loads: lightOnWrist))
        #expect(Self.severe(.wristHand).allows(press, loads: nil) && Self.severe(.wristHand).allows(press, loads: ExerciseAreaLoads()))
        #expect(!Self.severe(.shoulder).allows(press, loads: ExerciseAreaLoads()), "an empty record does not un-load a push")
        #expect(Self.severe(.shoulder).severeAreas(loadedBy: press, loads: lightOnWrist) == [.shoulder])
        #expect(Self.mild(.wristHand).mildAreas(loadedHardBy: press, loads: hardOnWrist) == [.wristHand])
    }

    /// The six areas the old setup chips covered still read back from an older build's avoided
    /// sets, and still leave out what they always did.
    @Test func theLegacyChipsStillDecodeToTheSameAreas() {
        for area in BodyArea.allCases where area.hadSetupChip {
            let legacy = WorkoutProfile(avoidedMuscles: area.muscles, avoidedMovements: area.movements)
            #expect(legacy.injuryLimits.severeAreas == [area], "\(area.rawValue)")
        }
    }

    // MARK: - Enough left to train

    /// What a full gym still offers with one area severe — the lifts, stretches and cardio a
    /// session is built from. A severe hip, knee or ankle leaves no cardio in the catalogue (every
    /// row is on the feet or the pedals; the knee and ankle were so before the records), which is
    /// why the cardio line names only the other six.
    @Test func everyAreaStillLeavesASession() throws {
        let rows = try Self.rows()
        let legs: Set<BodyArea> = [.hip, .knee, .ankleFoot]
        for area in BodyArea.allCases {
            let kept = rows.filter { Self.severe(area).allows($0) }
            let lifts = kept.filter { $0.modality == .strength }
            #expect(lifts.count >= 40, "severe \(area.rawValue) keeps \(lifts.count) lifts")
            #expect(Set(lifts.map(\.bodyRegion)).count >= 2, "severe \(area.rawValue) keeps more than one body region")
            #expect(kept.filter { $0.modality == .mobility }.count >= 6, "severe \(area.rawValue) keeps stretches")
            #expect(legs.contains(area) || kept.filter { $0.modality == .cardio }.count >= 5, "severe \(area.rawValue) keeps cardio")
            let mildKept = rows.filter { Self.mild(area).allows($0) }
            #expect(mildKept.count >= 160, "mild \(area.rawValue) keeps \(mildKept.count)")
            #expect(mildKept.filter { $0.modality == .cardio }.count >= 5, "mild \(area.rawValue) keeps cardio")
        }
    }

    /// A full-body day at a full gym, whichever single area is severe: lifts remain, and nothing in
    /// the session — warm-up and cool-down included — is an exercise that area leaves out. (Filling
    /// a thin session from other body areas is the planner's job, fix s3; this pins only the filter.)
    @Test func aFullBodyDayHoldsNothingASevereAreaLeavesOut() throws {
        let split = TrainingSplit(id: "probe", name: "Probe", specificity: .balanced, goalFit: [.strength],
                                  days: [WorkoutSplitDay(title: "Day", sessions: [WorkoutSessions.fullBodyA])])
        for area in BodyArea.allCases {
            let profile = WorkoutProfile(experience: .intermediate, injuryAreas: [area: .severe])
            let session = try #require(WorkoutProgram.dayPlan(
                goal: .strength, intensity: .moderate, profile: profile, location: .fullGym,
                context: "", split: split, rotationIndex: 0
            ).sessions.first)
            let lifts = session.exercises.filter { $0.block == .lifting && $0.fromCatalog }
            #expect(lifts.count >= 2, "severe \(area.rawValue): \(lifts.map(\.name))")
            for step in session.exercises where step.fromCatalog {
                let target = try #require(WorkoutExerciseCatalog.exercise(named: step.name), "\(step.name)")
                #expect(Self.severe(area).allows(target), "severe \(area.rawValue) plan holds \(step.name)")
            }
        }
    }

    // MARK: - The owner's review listing

    /// The per-area listing the owner spot-checks before this ships: for each area what mild
    /// removes, what only severe removes and what stays — asked of ``InjuryLimits`` itself, so it
    /// cannot drift from what the planner does — plus each exercise's recorded loads with the
    /// catalogue's one-phrase reason. Written only when `EXERCISE_AREA_LOADS_OUT` names a file:
    /// `TEST_RUNNER_EXERCISE_AREA_LOADS_OUT=<path> xcodebuild test-without-building …
    /// -only-testing:FernletTests/ExerciseAreaLoadTests`.
    @Test func ownerReviewListing() throws {
        let rows = try Self.rows()
        let raw = try Self.rawRecords()
        var areas: [[String: Any]] = []
        for area in BodyArea.allCases {
            let removedWhenMild = rows.filter { !Self.mild(area).allows($0) }.map(\.name)
            let removedWhenSevere = rows.filter { !Self.severe(area).allows($0) }.map(\.name)
            let lightOnly = removedWhenSevere.filter { !removedWhenMild.contains($0) }
            let kept = rows.map(\.name).filter { !removedWhenSevere.contains($0) }
            #expect(Set(removedWhenMild).isSubset(of: Set(removedWhenSevere)), "\(area.rawValue)")
            #expect(removedWhenMild.count + lightOnly.count + kept.count == rows.count, "\(area.rawValue)")
            for name in removedWhenSevere {
                #expect(raw[name]?.notes[area.rawValue] != nil, "\(name) is removed for the \(area.rawValue) with no reason")
            }
            areas.append([
                "area": area.rawValue, "name": area.displayName,
                "counts": ["removedWhenMild": removedWhenMild.count, "removedOnlyWhenSevere": lightOnly.count, "kept": kept.count],
                "removedWhenMild": removedWhenMild, "removedOnlyWhenSevere": lightOnly, "kept": kept,
            ])
        }
        let exercises: [[String: Any]] = rows.map { row in
            let record = raw[row.name] ?? RawRecord(loads: [:], notes: [:])
            let loads: [[String: String]] = BodyArea.allCases.compactMap { area in
                guard let load = record.loads[area.rawValue] else { return nil }
                return ["area": area.rawValue, "load": load, "reason": record.notes[area.rawValue] ?? ""]
            }
            return ["name": row.name, "loads": loads]
        }
        guard let path = ProcessInfo.processInfo.environment["EXERCISE_AREA_LOADS_OUT"], !path.isEmpty else { return }
        let listing: [String: Any] = [
            "source": "App/Fernlet/WorkoutExercises.json (areaLoads, areaLoadNotes), asked through InjuryLimits.allows",
            "regenerate": "TEST_RUNNER_EXERCISE_AREA_LOADS_OUT=<this file> xcodebuild test-without-building … -only-testing:FernletTests/ExerciseAreaLoadTests",
            "meaning": [
                "removedWhenMild": "loads the area hard: left out for Mild and Severe",
                "removedOnlyWhenSevere": "loads the area lightly or with support: kept for Mild, left out for Severe",
                "kept": "does not load the area: stays for Mild and Severe",
            ],
            "areas": areas, "exercises": exercises,
        ]
        let data = try JSONSerialization.data(withJSONObject: listing, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
