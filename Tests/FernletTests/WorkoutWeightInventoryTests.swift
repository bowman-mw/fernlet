import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Pins idea 10 of the comparison report: "Weights I have" per location and the light-load guard.
///
/// The engine snaps suggestions and ranges onto the dumbbell pairs, kettlebells and bar-plus-plate
/// totals a location has; when the next load is too big a jump (over ``WorkoutLoadEngine/lightLoadGuardRatio``)
/// or missing, a lift adds reps, then a set, before the weight moves — with or without weights set.
/// The monthly calibration lands on owned loads too. The weights sync at the settings blob's top level
/// (`workoutLocationWeights`), so an older build that drops a location's unknown nested keys still
/// keeps them, and a location now parks a newer build's equipment tokens and keys.
@MainActor
struct WorkoutWeightInventoryTests {

    // MARK: - Fixtures

    static let base = Date(timeIntervalSince1970: 1_790_000_000)
    static let garageID = "11111111-2222-4333-8444-555555555555"

    func day(_ offset: Int) -> Date { Self.base.addingTimeInterval(Double(offset) * 86_400) }

    /// One completed structured session: every set at `reps`, which was also the target.
    func session(_ offset: Int, _ weight: Double, reps: Int, sets: Int = 3, unit: LoadUnit = .lb) -> LiftExposure {
        LiftExposure(date: day(offset), weight: weight, unit: unit, targetReps: reps,
                     repsPerSet: Array(repeating: reps, count: sets), structured: true)
    }

    func plan(
        _ history: [LiftExposure], equipment: Equipment, inventory: WorkoutWeightInventory? = nil,
        unit: LoadUnit = .lb, lowerBody: Bool = false, today: Int = 30
    ) -> LiftPlan {
        WorkoutLoadEngine.plan(WorkoutLoadEngine.LiftInputs(
            scheme: RepScheme(low: 8, high: 12), baseSets: 3, exposures: history, equipment: equipment,
            isLowerBody: lowerBody, defaultUnit: unit, today: day(today), inventory: inventory
        ))
    }

    /// A fixed home set: five pairs, 5–25 lb.
    func homeSet() -> WorkoutWeightInventory {
        var inventory = WorkoutWeightInventory(unit: .lb)
        inventory.setDumbbells([5, 10, 15, 20, 25])
        return inventory
    }

    /// A 45 lb bar with one pair each of 45 and 25: it makes 45, 95, 135 and 185 lb.
    func coarseBarbell() -> WorkoutWeightInventory {
        var inventory = WorkoutWeightInventory(unit: .lb)
        inventory.setBar(45)
        inventory.setPairs(1, of: 45)
        inventory.setPairs(1, of: 25)
        return inventory
    }

    func settings(_ json: String) throws -> FernletSettings {
        try JSONDecoder().decode(FernletSettings.self, from: Data(json.utf8))
    }

    func object(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    static let pushSplit = TrainingSplit(
        id: "probe", name: "Probe", summary: "", specificity: .balanced, goalFit: [.wellness],
        days: [WorkoutSplitDay(title: "Push", sessions: [WorkoutSessions.push])]
    )

    func pushSession(at location: WorkoutLocation, history: [String: [LiftExposure]] = [:],
                     calibration: CalibrationSettings = CalibrationSettings(hasCoach: true),
                     goal: GoalType = .wellness) throws -> WorkoutProgram.SessionSuggestion {
        let load = WorkoutLoadContext(exposures: history, today: day(30), defaultUnit: .lb, calibration: calibration)
        let plan = WorkoutProgram.dayPlan(
            goal: goal, intensity: .moderate, profile: WorkoutProfile(experience: .intermediate),
            location: location, context: "", split: Self.pushSplit, rotationIndex: 0, load: load
        )
        return try #require(plan.sessions.first)
    }

    func lifting(_ session: WorkoutProgram.SessionSuggestion) -> [PrescribedExercise] {
        session.exercises.filter { $0.block == .lifting }
    }

    // MARK: - Snapping, by equipment

    @Test func dumbbellsSnapToThePairsOwned() throws {
        let next = plan([session(28, 15, reps: 10)], equipment: .dumbbell, inventory: homeSet())
        #expect((next.reps, next.change) == (11, .moreReps))
        let range = try #require(next.prescription)
        #expect((range.low, range.suggested, range.high) == (10, 15, 20))
        #expect(range.step == 5)
        // A logged weight the set doesn't have lands on the nearest pair — the lighter on a tie.
        let between = plan([session(28, 17.5, reps: 10)], equipment: .dumbbell, inventory: homeSet())
        #expect(between.prescription?.suggested == 15)
    }

    @Test func kettlebellsSnapToTheBellsOwned() throws {
        var bells = WorkoutWeightInventory(unit: .kg)
        for size in [8.0, 12, 16, 24] { bells.addKettlebell(size) }
        let next = plan([session(28, 14, reps: 8, unit: .kg)], equipment: .kettlebell, inventory: bells, unit: .kg)
        let range = try #require(next.prescription)
        #expect((range.low, range.suggested, range.high) == (8, 12, 16))
        #expect(range.step == 4, "the bells' common step, so the runner's −/+ lands on owned bells")

        // Up from 48 lb to the 52 the set has (8 %), not the usual step to 53.
        var heavy = WorkoutWeightInventory(unit: .lb)
        for size in [44.0, 48, 52] { heavy.addKettlebell(size) }
        let up = plan([session(28, 48, reps: 12)], equipment: .kettlebell, inventory: heavy)
        #expect((up.change, up.reps, up.prescription?.suggested) == (.backToBottom, 8, 52))
    }

    @Test func barbellLoadsComeFromTheBarAndPlatePairs() throws {
        var bar = WorkoutWeightInventory(unit: .lb)
        bar.setBar(45)
        for plate in [45.0, 25, 10, 5, 2.5] { bar.setPairs(1, of: plate) }
        let next = plan([session(28, 135, reps: 12)], equipment: .barbell, inventory: bar)
        #expect((next.change, next.reps) == (.backToBottom, 8))
        let range = try #require(next.prescription)
        // 140 = the bar and a 45 and a 2.5 a side; ±10 % at low confidence reaches 125 and 155.
        #expect((range.low, range.suggested, range.high) == (125, 140, 155))
        #expect([range.low, range.suggested, range.high].allSatisfy { bar.barbellTotals.contains($0) })

        #expect(coarseBarbell().barbellTotals == [45, 95, 135, 185])
        var doubled = WorkoutWeightInventory(unit: .lb)
        doubled.setPairs(2, of: 45)
        #expect(doubled.barWeight == 45, "a plate without a bar assumes the standard bar")
        #expect(doubled.barbellTotals == [45, 135, 225])
    }

    @Test func machinesAndCablesHaveNoInventoryAndKeepTheirSteps() {
        #expect(homeSet().ladder(for: .machine, in: .lb) == nil)
        #expect(homeSet().ladder(for: .cable, in: .lb) == nil)
        #expect(WorkoutWeightInventory().ladder(for: .dumbbell, in: .lb) == nil, "an empty list says nothing")
        let machine = plan([session(28, 100, reps: 12)], equipment: .machine, inventory: homeSet())
        #expect((machine.change, machine.prescription?.suggested) == (.backToBottom, 105))
    }

    // MARK: - Reps first when the step is missing or too big

    @Test func aMissingStepAddsRepsThenASetThenTakesTheJump() throws {
        let first = [session(20, 15, reps: 12)]
        let one = plan(first, equipment: .dumbbell, inventory: homeSet(), today: 22)
        #expect((one.change, one.reps, one.sets, one.prescription?.suggested) == (.repsFirst, 13, 3, 15))
        #expect(one.cap == .bigStep(from: 15, to: 20, owned: true))

        let second = first + [session(22, 15, reps: 13)]
        let two = plan(second, equipment: .dumbbell, inventory: homeSet(), today: 24)
        #expect((two.change, two.reps) == (.repsFirst, 14))
        let third = second + [session(24, 15, reps: 14)]
        #expect(plan(third, equipment: .dumbbell, inventory: homeSet(), today: 26).reps == 15)

        let fourth = third + [session(26, 15, reps: 15)]
        let set = plan(fourth, equipment: .dumbbell, inventory: homeSet(), today: 28)
        #expect((set.change, set.reps, set.sets, set.prescription?.suggested) == (.setFirst, 15, 4, 15))

        let fifth = fourth + [session(28, 15, reps: 15, sets: 4)]
        let jump = plan(fifth, equipment: .dumbbell, inventory: homeSet(), today: 30)
        #expect((jump.change, jump.reps, jump.sets, jump.prescription?.suggested) == (.backToBottom, 8, 3, 20))
        #expect(jump.cap == nil)
    }

    @Test func withNothingHeavierItAddsRepsThenASetAndStaysThere() {
        let top = plan([session(26, 25, reps: 12)], equipment: .dumbbell, inventory: homeSet(), today: 28)
        #expect((top.change, top.reps) == (.repsFirst, 13))
        #expect(top.cap == .heaviest(top: 25))
        let held = plan([session(24, 25, reps: 15), session(26, 25, reps: 15, sets: 4)],
                        equipment: .dumbbell, inventory: homeSet(), today: 28)
        #expect((held.change, held.reps, held.sets, held.prescription?.suggested) == (.setFirst, 15, 4, 25))
    }

    @Test func aSmallMissAtTheExtraRepsRepeatsThem() {
        var missed = session(26, 15, reps: 14)
        missed.repsPerSet = [14, 14, 13]
        let after = plan([session(24, 15, reps: 13), missed], equipment: .dumbbell, inventory: homeSet(), today: 28)
        #expect((after.change, after.reps, after.prescription?.suggested) == (.same, 14, 15))
    }

    // MARK: - The light-load guard (no weights set)

    @Test func theGuardWaitsForRepsWhenOneStepIsOverTenPercent() {
        #expect(WorkoutLoadEngine.lightLoadGuardRatio == 0.10)
        func next(_ weight: Double, _ equipment: Equipment, unit: LoadUnit = .lb) -> LiftPlan {
            plan([session(28, weight, reps: 12, unit: unit)], equipment: equipment, unit: unit)
        }
        // Dumbbells: 15 → 20 lb is 33 % and 45 → 50 is 11 %: reps first. 50 → 55 is exactly 10 %.
        let light = next(15, .dumbbell)
        #expect((light.change, light.reps, light.prescription?.suggested) == (.repsFirst, 13, 15))
        #expect(light.cap == .bigStep(from: 15, to: 20, owned: false))
        #expect(next(45, .dumbbell).change == .repsFirst)
        let fifty = next(50, .dumbbell)
        #expect((fifty.change, fifty.prescription?.suggested) == (.backToBottom, 55))
        // Dumbbells in kilograms: 10 → 12 is 20 %; 20 → 22 is 10 %.
        #expect(next(10, .dumbbell, unit: .kg).change == .repsFirst)
        #expect(next(20, .dumbbell, unit: .kg).change == .backToBottom)
        // Kettlebells: 35 → 40 lb is 14 %; 24 → 26 kg is 8 %.
        #expect(next(35, .kettlebell).change == .repsFirst)
        let bell = next(24, .kettlebell, unit: .kg)
        #expect((bell.change, bell.prescription?.suggested) == (.backToBottom, 26))
        // Barbell: the empty 45 lb bar → 50 is 11 %; 100 → 105 is 5 %.
        #expect(next(45, .barbell).change == .repsFirst)
        let bar = next(100, .barbell)
        #expect((bar.change, bar.prescription?.suggested) == (.backToBottom, 105))
        // Machine: 40 → 45 is 12.5 %; 50 → 55 is 10 %.
        #expect(next(40, .machine).change == .repsFirst)
        #expect(next(50, .machine).change == .backToBottom)
    }

    @Test func theGuardIsTheEngineStepMeasuredAgainstTheLoad() throws {
        #expect(WorkoutLoadEngine.loadCap(from: 15, step: 5, lowerBody: false, ladder: nil)
                == .bigStep(from: 15, to: 20, owned: false))
        #expect(WorkoutLoadEngine.loadCap(from: 50, step: 5, lowerBody: false, ladder: nil) == nil)
        #expect(WorkoutLoadEngine.loadCap(from: 200, step: 5, lowerBody: true, ladder: nil) == nil)
        let ladder = try #require(LoadLadder([5, 10, 15, 20, 25]))
        #expect(WorkoutLoadEngine.loadCap(from: 25, step: 5, lowerBody: false, ladder: ladder) == .heaviest(top: 25))
        #expect(WorkoutLoadEngine.loadCap(from: 10, step: 5, lowerBody: false, ladder: ladder)
                == .bigStep(from: 10, to: 15, owned: true))
    }

    /// The plan's note says why, in the brief's words.
    @Test func theSessionNoteNamesTheNextDumbbell() throws {
        var garage = WorkoutLocation(name: "Garage", ownedEquipment: [.dumbbells, .weightBench])
        garage.weights = homeSet()
        let first = lifting(try pushSession(at: garage))
        let lift = try #require(first.first { $0.guidance?.equipment == .dumbbell })
        let style = WorkoutGoalStyle.style(for: .wellness, energy: .moderate, sport: "")
        let scheme = try #require(RepScheme(style.reps(for: lift.role)))
        let history = [WorkoutExerciseCatalog.normalizedName(lift.name): [session(28, 15, reps: scheme.high)]]
        let session = try pushSession(at: garage, history: history)
        let step = try #require(lifting(session).first { $0.name == lift.name })
        #expect(step.reps == "\(scheme.high + 1)")
        #expect(step.guidance?.prescription?.suggested == 15)
        #expect(session.suggestion.notes.contains(
            "\(lift.name): your next dumbbell is 20 lb, so add reps first — \(scheme.high + 1) today."))
    }

    /// Weights change loads only: the same exercises are picked, the injury limits, the time budget
    /// and the hidden list still shape the session.
    @Test func weightsChangeTheLoadsNotWhatIsPlanned() {
        let split = TrainingSplit(id: "probe", name: "Probe", summary: "", specificity: .balanced, goalFit: [.wellness],
                                  days: [WorkoutSplitDay(title: "Day", sessions: [WorkoutSessions.fullBodyA])])
        func names(_ location: WorkoutLocation) -> [String] {
            WorkoutProgram.dayPlan(
                goal: .wellness, intensity: .moderate,
                profile: WorkoutProfile(experience: .intermediate, injuryAreas: [.knee: .mild]),
                location: location, context: "", split: split, rotationIndex: 0,
                load: WorkoutLoadContext(exposures: [:], today: day(30), defaultUnit: .lb),
                options: WorkoutSessionOptions(length: .min30),
                preferences: WorkoutExercisePreferences(hidden: ["Goblet squat"])
            ).sessions.flatMap { $0.exercises.map(\.name) }
        }
        var stocked = WorkoutLocation.home
        stocked.weights = homeSet()
        for size in [8.0, 12, 16] { stocked.weights.addKettlebell(size) }
        #expect(names(stocked) == names(.home))
        #expect(!names(stocked).contains("Goblet squat"))
    }

    // MARK: - Calibration

    @Test func calibrationSetsLandOnTheWeightsOwned() throws {
        let ladder = try #require(LoadLadder([5, 10, 15, 20, 25]))
        let check = WorkoutCalibration.sets(kind: .submaximal, oneRepMax: 30, todaysSuggested: nil, todaysReps: 8,
                                            step: 5, ladder: ladder)
        #expect(check.map(\.step) == [.ramp, .ramp, .test], "a ramp set landing on another is dropped")
        #expect(check.map(\.weight) == [15, 20, 25])
        #expect(zip(check, check.dropFirst()).allSatisfy { $0.weight < $1.weight })

        let max = WorkoutCalibration.sets(kind: .oneRepMax, oneRepMax: 24, todaysSuggested: nil, todaysReps: 8,
                                          step: 5, ladder: ladder)
        #expect(max.filter { $0.step == .ramp }.map(\.weight) == [10, 15, 20])
        #expect(max.filter { $0.step == .attempt }.map(\.weight) == [25], "three singles on one dumbbell are one")
        #expect(max.allSatisfy { ladder.loads.contains($0.weight) })

        let unchanged = WorkoutCalibration.sets(kind: .submaximal, oneRepMax: 200, todaysSuggested: nil, todaysReps: 8, step: 5)
        #expect(unchanged.count == 4, "no ladder, no change")
    }

    @Test func aDueCalibrationRampsOnTheBarAndPlatesOwned() throws {
        var garage = WorkoutLocation(name: "Garage", ownedEquipment: [.barbell, .weightPlates, .squatRack, .weightBench])
        garage.weights = coarseBarbell()
        let main = try #require(lifting(try pushSession(at: garage)).first {
            $0.role == .main && $0.guidance?.equipment == .barbell
        })
        let history = [WorkoutExerciseCatalog.normalizedName(main.name): [
            session(21, 135, reps: 10), session(28, 135, reps: 10),
        ]]
        // The monthly strength check runs for strength and sports prep (G7).
        let session = try pushSession(at: garage, history: history, calibration: CalibrationSettings(), goal: .strength)
        let steps = lifting(session).filter { $0.name == main.name }
        #expect(steps.compactMap(\.guidance?.calibration) == [.ramp, .test])
        // Estimate 189 lb; the 155 lb test lands on 135, the 80 lb ramp on 95, and the ramps that
        // would land on 95 again or on the test are dropped.
        #expect(steps.compactMap(\.guidance?.prescription?.suggested) == [95, 135])
    }

    // MARK: - The synced shape

    @Test func anOlderBlobDecodesWithNoWeightsAndKeepsItsShape() throws {
        let decoded = try settings(#"{"workoutLocations": [{"id": "\#(Self.garageID)", "name": "Garage", "ownedEquipment": ["dumbbells", "weightBench"]}]}"#)
        let garage = try #require(decoded.workoutLocations.first)
        #expect(garage.weights.isEmpty)
        #expect(garage.unknownEquipmentTokens.isEmpty && garage.parkedUnknownKeys.isEmpty)
        #expect(garage.unreadableWeights == nil)
        #expect(garage.ownedEquipment == [.dumbbells, .weightBench])
        let top = try object(decoded)
        #expect(top["workoutLocationWeights"] == nil, "no weights, no key: the old blob's shape")
        let locations = try #require(top["workoutLocations"] as? [[String: Any]])
        #expect(locations.first?.keys.sorted() == ["id", "name", "ownedEquipment"])
        let fresh = try object(FernletSettings())
        #expect(!fresh.keys.contains("workoutLocationWeights"))
    }

    @Test func weightsRideAtTheTopLevelAndRoundTrip() throws {
        var garage = WorkoutLocation(name: "Garage", ownedEquipment: [.dumbbells, .barbell, .weightPlates])
        garage.weights = homeSet()
        garage.weights.setBar(45)
        garage.weights.setPairs(2, of: 45)
        var original = FernletSettings()
        original.workoutLocations = [garage]
        let top = try object(original)
        let entries = try #require(top["workoutLocationWeights"] as? [String: Any])
        let entry = try #require(entries[garage.id.uuidString] as? [String: Any])
        #expect(entry["unit"] as? String == "lb")
        #expect(entry["dumbbells"] as? [Double] == [5, 10, 15, 20, 25])
        #expect(entry["barWeight"] as? Double == 45)
        #expect(entry["platePairs"] as? [Double] == [45, 45])
        let nested = try #require((top["workoutLocations"] as? [[String: Any]])?.first)
        #expect(nested.keys.sorted() == ["id", "name", "ownedEquipment"], "the weights are not nested")

        let again = try JSONDecoder().decode(FernletSettings.self, from: JSONEncoder().encode(original))
        #expect(again.workoutLocations == original.workoutLocations)
        #expect(again.parkedUnknownKeys.isEmpty, "a known key, never parked")
    }

    /// The other direction: a build from before this change re-saves the blob. It drops a location's
    /// unknown nested keys — which is why the weights are not nested — and parks every top-level key
    /// it doesn't know, so the weights come back intact.
    @Test func aBlobReSavedByAnOlderBuildKeepsTheWeights() throws {
        var garage = WorkoutLocation(name: "Garage", ownedEquipment: [.dumbbells, .barbell, .weightPlates])
        garage.weights = homeSet()
        garage.weights.setBar(45)
        garage.weights.setPairs(1, of: 25)
        garage.unknownEquipmentTokens = ["dipStation"]
        var original = FernletSettings()
        original.workoutLocations = [garage]

        let older = try JSONDecoder().decode(OlderBuildSettings.self, from: JSONEncoder().encode(original))
        let resaved = try JSONEncoder().encode(older)
        let resavedTop = try #require(JSONSerialization.jsonObject(with: resaved) as? [String: Any])
        let resavedLocation = try #require((resavedTop["workoutLocations"] as? [[String: Any]])?.first)
        #expect(!resavedLocation.keys.contains("unknownOwnedEquipmentTokens"), "an older build drops nested keys")

        let back = try JSONDecoder().decode(FernletSettings.self, from: resaved)
        let location = try #require(back.workoutLocations.first)
        #expect(location.id == garage.id)
        #expect(location.weights == garage.weights)
    }

    @Test func aNewerBuildsEquipmentAndKeysParkOnTheLocation() throws {
        let decoded = try settings(#"{"workoutLocations": [{"id": "\#(Self.garageID)", "name": "Garage", "ownedEquipment": ["dumbbells", "dipStation"], "unknownOwnedEquipmentTokens": ["kettlebells", "plyoBox"], "futureField": {"x": 1}}]}"#)
        let garage = try #require(decoded.workoutLocations.first)
        #expect(garage.ownedEquipment == [.dumbbells, .kettlebells], "a parked token this build knows is adopted")
        #expect(garage.unknownEquipmentTokens == ["dipStation", "plyoBox"])
        #expect(garage.parkedUnknownKeys["futureField"] == .object(["x": .integer(1)]))

        let top = try object(decoded)
        let nested = try #require((top["workoutLocations"] as? [[String: Any]])?.first)
        #expect(nested["ownedEquipment"] as? [String] == ["dumbbells", "kettlebells"])
        #expect(nested["unknownOwnedEquipmentTokens"] as? [String] == ["dipStation", "plyoBox"])
        #expect(nested["futureField"] != nil)
        let again = try JSONDecoder().decode(FernletSettings.self, from: JSONEncoder().encode(decoded))
        #expect(again.workoutLocations == decoded.workoutLocations)
    }

    @Test func weightsDecodeTolerantly() throws {
        let location = #"{"id": "\#(Self.garageID)", "name": "Garage", "ownedEquipment": ["dumbbells"]}"#
        let messy = try settings(#"{"workoutLocations": [\#(location)], "workoutLocationWeights": {"\#(Self.garageID)": {"unit": "lb", "dumbbells": [25, 5, "x", -3, 5, 10.004, 5000], "bands": ["light"]}}}"#)
        let weights = try #require(messy.workoutLocations.first?.weights)
        #expect(weights.dumbbells == [5, 10, 25], "junk, duplicates and impossible weights skipped")
        #expect(weights.parkedUnknownKeys["bands"] == .array([.string("light")]))
        let messyTop = try object(messy)
        let entries = try #require(messyTop["workoutLocationWeights"] as? [String: Any])
        let entry = try #require(entries[Self.garageID] as? [String: Any])
        #expect(entry["bands"] != nil, "a newer build's key survives the re-save")

        // A unit only a newer build knows: kept verbatim, written back, never read as weights.
        let stone = try settings(#"{"workoutLocations": [\#(location)], "workoutLocationWeights": {"\#(Self.garageID)": {"unit": "stone", "dumbbells": [1, 2]}}}"#)
        let kept = try #require(stone.workoutLocations.first)
        #expect(kept.weights.isEmpty)
        #expect(kept.unreadableWeights != nil)
        let stoneTop = try object(stone)
        let stoneEntries = try #require(stoneTop["workoutLocationWeights"] as? [String: Any])
        #expect((stoneEntries[Self.garageID] as? [String: Any])?["unit"] as? String == "stone")

        // An entry for no location is dropped; a value of another shape reads as none.
        let orphan = try settings(#"{"workoutLocations": [\#(location)], "workoutLocationWeights": {"99999999-2222-4333-8444-555555555555": {"unit": "lb", "dumbbells": [5]}}}"#)
        #expect(orphan.workoutLocations.first?.weights.isEmpty == true)
        let orphanTop = try object(orphan)
        #expect(orphanTop["workoutLocationWeights"] == nil)
        let wrong = try settings(#"{"workoutLocations": [\#(location)], "workoutLocationWeights": [1, 2]}"#)
        #expect(wrong.workoutLocations.first?.weights.isEmpty == true)
    }

    // MARK: - Units

    @Test func presetsFollowTheUnitAndOtherUnitsConvert() throws {
        #expect(WorkoutWeightPresets.Dumbbells.homeSet.weights(in: .lb) == [5, 10, 15, 20, 25])
        #expect(WorkoutWeightPresets.Dumbbells.homeSet.weights(in: .kg) == [2, 4, 6, 8, 10])
        let adjustable = WorkoutWeightPresets.Dumbbells.adjustable.weights(in: .lb)
        #expect((adjustable.count, adjustable.first, adjustable.last) == (20, 5, 52.5))
        let adjustableKg = WorkoutWeightPresets.Dumbbells.adjustable.weights(in: .kg)
        #expect((adjustableKg.count, adjustableKg.first, adjustableKg.last) == (23, 2, 24))
        let rack = WorkoutWeightPresets.Dumbbells.fullRack.weights(in: .lb)
        #expect((rack.count, rack.first, rack.last) == (20, 5, 100))
        let rackKg = WorkoutWeightPresets.Dumbbells.fullRack.weights(in: .kg)
        #expect((rackKg.count, rackKg.first, rackKg.last) == (20, 2.5, 50))
        #expect(WorkoutWeightPresets.standardBar(.kg) == 20)
        #expect(WorkoutLoadContextBuilder.defaultUnit(for: Locale(identifier: "en_US")) == .lb)
        #expect(WorkoutLoadContextBuilder.defaultUnit(for: Locale(identifier: "de_DE")) == .kg)

        var bells = WorkoutWeightInventory(unit: .kg)
        for size in [16.0, 20, 24] { bells.addKettlebell(size) }
        let inPounds = try #require(bells.ladder(for: .kettlebell, in: .lb))
        #expect(inPounds.loads.map { ($0 * 10).rounded() / 10 } == [35.3, 44.1, 52.9])
        // A lift last logged in pounds stays in pounds, on the converted bells.
        let next = plan([session(28, 35, reps: 10)], equipment: .kettlebell, inventory: bells)
        #expect(next.unit == .lb)
        let suggested = try #require(next.prescription?.suggested)
        #expect(abs(suggested - 16 * LoadUnit.poundsPerKilogram) < 0.01)

        var plates = WorkoutWeightInventory(unit: .kg)
        plates.setPairs(1, of: 20)
        #expect(plates.barWeight == 20)
        #expect(plates.barbellTotals == [20, 60])
    }

    // MARK: - The inventory and the ladder

    @Test func theListsStaySortedDedupedAndBounded() {
        var inventory = WorkoutWeightInventory(unit: .lb)
        #expect(inventory.isEmpty)
        let addedHeavy = inventory.addDumbbell(25)
        let addedLight = inventory.addDumbbell(5)
        let addedAgain = inventory.addDumbbell(5.001)
        #expect(addedHeavy && addedLight && addedAgain, "adding one already owned succeeds unchanged")
        #expect(inventory.dumbbells == [5, 25])
        let zero = inventory.addDumbbell(0)
        let negative = inventory.addDumbbell(-5)
        let huge = inventory.addDumbbell(1_500)
        let notANumber = inventory.addDumbbell(.nan)
        #expect(!zero && !negative && !huge && !notANumber)
        inventory.setDumbbells((1...50).map(Double.init))
        #expect(inventory.dumbbells.count == WorkoutWeightInventory.maxDumbbells)
        let full = inventory.addDumbbell(60)
        #expect(!full)
        inventory.removeDumbbell(40)
        #expect(!inventory.dumbbells.contains(40))

        inventory.setPairs(3, of: 45)
        inventory.setPairs(1, of: 45)
        #expect(inventory.pairs(of: 45) == 1)
        inventory.setPairs(40, of: 10)
        #expect(inventory.platePairs.count == WorkoutWeightInventory.maxPlatePairs)
        inventory.clearBarbell()
        #expect(inventory.barWeight == nil && inventory.platePairs.isEmpty)
    }

    @Test func theLadderPicksTheNearestLoadAndAUsefulRunnerStep() throws {
        let set = try #require(LoadLadder([25, 5, 15, 10, 20, 15]))
        #expect(set.loads == [5, 10, 15, 20, 25])
        #expect(set.nearest(to: 17.5) == 15, "a tie goes to the lighter")
        #expect(set.nearest(to: 40) == 25)
        #expect(set.runnerStep(default: 5) == 5)
        let bells = try #require(LoadLadder([8, 12, 16, 24]))
        #expect(bells.runnerStep(default: 2) == 4)
        let irregular = try #require(LoadLadder([18, 26, 35]))
        #expect(irregular.runnerStep(default: 5) == 5, "no useful common step")
        #expect(LoadLadder([]) == nil)
        #expect(LoadLadder([-5, .nan]) == nil)
    }
}

// MARK: - A build from before "Weights I have"

/// The settings blob as a build from before this change re-saves it, as far as locations go: each
/// location's three keys and nothing else (its old `CodingKeys`), and every other top-level key kept
/// verbatim — the generic key parking every build since 2026-08 has.
private nonisolated struct OlderBuildSettings: Codable {
    var workoutLocations: [OlderBuildLocation] = []
    var parked: [String: JSONValue] = [:]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: OlderBuildKey.self)
        for key in container.allKeys {
            if key.stringValue == "workoutLocations" {
                workoutLocations = try container.decode([OlderBuildLocation].self, forKey: key)
            } else {
                parked[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: OlderBuildKey.self)
        try container.encode(workoutLocations, forKey: OlderBuildKey(stringValue: "workoutLocations"))
        for (key, value) in parked {
            try container.encode(value, forKey: OlderBuildKey(stringValue: key))
        }
    }
}

/// A location as a build from before this change reads and writes it.
private nonisolated struct OlderBuildLocation: Codable {
    var id: UUID
    var name: String
    var ownedEquipment: [String]
}

/// Any string key, for the older build's parking.
private nonisolated struct OlderBuildKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
