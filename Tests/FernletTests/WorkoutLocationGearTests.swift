import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Each exercise needs its own gear (the owner's fix e5, 2026-11-10).
///
/// Before it, one leg press or chest press unlocked every machine exercise; a Smith machine, plates
/// or a rack alone unlocked the free barbell lifts; Smith machine squat needed a leg press as well;
/// and Dip, Inverted row and Ab wheel needed nothing, so they were planned in an empty hotel room.
/// These cells hold the fix: the catalog names each exercise's specific gear, a space unlocks only
/// what its checklist names, the presets fill the checklist in, and a space saved before the fix
/// keeps the machine exercises its owner has been doing.
@MainActor
struct WorkoutLocationGearTests {

    // MARK: - Fixtures

    private static let catalog = WorkoutExerciseCatalog.baseExercises
    private static let emptyRoom = WorkoutLocation(name: "Hotel room", ownedEquipment: [])

    private static func space(_ gear: Set<GymEquipment>) -> WorkoutLocation {
        WorkoutLocation(name: "Probe", ownedEquipment: gear)
    }

    /// The bundled exercises a space can run.
    private static func unlocked(at location: WorkoutLocation) -> Set<String> {
        Set(catalog.filter { WorkoutSafetyFilter.hasEquipment(for: $0, at: location) }.map(\.name))
    }

    /// The bundled exercises a space can run that an empty room cannot: what its gear adds.
    private static func added(by gear: Set<GymEquipment>) -> Set<String> {
        unlocked(at: space(gear)).subtracting(unlocked(at: emptyRoom))
    }

    private static func decode(_ json: String) throws -> WorkoutLocation {
        try JSONDecoder().decode(WorkoutLocation.self, from: Data(json.utf8))
    }

    private static func savedJSON(_ gear: [GymEquipment], extra: String = "") -> String {
        let tokens = gear.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
        return #"{"id": "0A1B2C3D-4E5F-4061-9273-8495A6B7C8D9", "name": "Saved", "ownedEquipment": [\#(tokens)]\#(extra)}"#
    }

    /// Every lifting, warm-up and cool-down step the planner takes from the catalog for one day.
    private static func plannedRows(
        at location: WorkoutLocation, split: TrainingSplit, day: Int, experience: ExperienceLevel
    ) -> [String] {
        let plan = WorkoutProgram.dayPlan(
            goal: .strength, intensity: .moderate, profile: WorkoutProfile(experience: experience),
            location: location, context: "", split: split, rotationIndex: day)
        return plan.sessions.flatMap(\.exercises).filter(\.fromCatalog).map(\.name)
    }

    /// The machine each bundled machine exercise is done on.
    private static let machineOf: [String: GymEquipment] = [
        "Preacher curl": .preacherCurl, "Leg press": .legPress, "Hack squat": .hackSquat,
        "Leg extension": .legExtension, "Leg curl": .legCurl,
        "Standing calf raise": .standingCalfRaise, "Seated calf raise": .seatedCalfRaise,
        "Chest press machine": .chestPress, "Machine shoulder press": .shoulderPressMachine,
        "Assisted dip": .assistedPullUpDip, "Assisted pull-up": .assistedPullUpDip,
        "Pec deck": .pecDeck, "Reverse pec deck": .pecDeck, "Seated row machine": .seatedRowMachine,
        "Smith machine squat": .smithMachine,
        "Hip abduction machine": .hipAbductionAdduction, "Hip adduction machine": .hipAbductionAdduction,
    ]

    // MARK: - The catalog names each exercise's gear

    /// Every bundled machine exercise names exactly its own machine, and nothing else stands in
    /// for it: that machine alone unlocks it, and no other single piece does.
    @Test func everyMachineExerciseNamesItsMachine() throws {
        let machineRows = Self.catalog.filter { $0.equipment == .machine }
        #expect(Set(machineRows.map(\.name)) == Set(Self.machineOf.keys))
        for row in machineRows {
            let machine = try #require(Self.machineOf[row.name], "\(row.name) has no machine in the table")
            #expect(row.requiredGear == [machine], "\(row.name) names \(row.requiredGear)")
            #expect(machine.category == .machines && machine.capability == .machine, "\(machine) is not a machine")
            #expect(row.alternativeEquipment.isEmpty, "\(row.name) can be done on another tool, so another piece unlocks it")
            #expect(WorkoutSafetyFilter.hasEquipment(for: row, at: Self.space([machine])))
        }
        // No exercise but a machine exercise may be done "on a machine": any machine would unlock it.
        for row in Self.catalog where row.equipment != .machine {
            #expect(!row.alternativeEquipment.contains(.machine), "\(row.name) is unlocked by any machine")
        }
    }

    /// No exercise is unlocked by gear it does not use. A piece ticked alone adds only exercises
    /// that name it, or — for the general tools (dumbbells, kettlebells, bands, a cable station, a
    /// bench) — exercises done with that tool that need nothing else.
    @Test func noExerciseIsUnlockedByGearItDoesNotUse() throws {
        let rows = Dictionary(Self.catalog.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let generalTools: Set<Equipment> = [.dumbbell, .kettlebell, .band, .cable, .bench]
        for piece in GymEquipment.allCases {
            for name in Self.added(by: [piece]) {
                let row = try #require(rows[name])
                if row.requiredGear.contains(piece) { continue }
                let tools = [row.equipment] + row.alternativeEquipment
                #expect(generalTools.contains(piece.capability) && tools.contains(piece.capability) && row.requiredGear.isEmpty,
                        "\(piece.rawValue) alone unlocks \(name)")
            }
        }
        // A machine, the Smith machine included, adds exactly the exercises that name it.
        for piece in GymEquipment.allCases where piece.capability == .machine {
            let named = Set(Self.machineOf.filter { $0.value == piece }.keys)
            #expect(Self.added(by: [piece]) == named, "\(piece.rawValue)")
        }
        // Plates, a rack and the small pieces are no tool: alone they add only what names them alone.
        #expect(Self.added(by: [.weightPlates]).isEmpty)
        #expect(Self.added(by: [.squatRack]).isEmpty)
        #expect(Self.added(by: [.weightPlates, .squatRack, .weightBench]).allSatisfy { rows[$0]?.equipment != .barbell })
        #expect(Self.added(by: [.dipBars]) == ["Dip"])
        #expect(Self.added(by: [.lowBar]) == ["Inverted row"])
        #expect(Self.added(by: [.abWheel]) == ["Ab wheel"])
        // The 2026-11-13 pieces: the sled alone adds its two moves, the trap bar alone nothing (it
        // still needs the plates and a barbell space), and with them only the trap-bar deadlift.
        #expect(Self.added(by: [.sled]) == ["Sled push", "Sled pull"])
        #expect(Self.added(by: [.trapBar]).isEmpty)
        #expect(Self.added(by: [.barbell, .weightPlates, .trapBar]).subtracting(Self.added(by: [.barbell, .weightPlates])) == ["Trap-bar deadlift"])
    }

    /// A free barbell lift needs the barbell and plates — and the rack or bench it is done from.
    @Test func freeBarbellLiftsNeedTheBarbellAndPlates() throws {
        let barbellRows = Self.catalog.filter { $0.equipment == .barbell }
        #expect(barbellRows.count >= 15)
        for row in barbellRows {
            #expect(row.requiredGear.contains(.weightPlates), "\(row.name) is planned for an empty bar")
            #expect(!WorkoutSafetyFilter.hasEquipment(for: row, at: Self.space([.barbell])))
            #expect(!WorkoutSafetyFilter.hasEquipment(for: row, at: Self.space([.weightPlates, .squatRack, .weightBench, .smithMachine])),
                    "\(row.name) is planned with no barbell")
            // A trap-bar lift needs the trap bar too (2026-11-13); every other one only the bar,
            // the plates and the rack or bench.
            let base: Set<GymEquipment> = [.barbell, .weightPlates, .squatRack, .weightBench]
            #expect(WorkoutSafetyFilter.hasEquipment(for: row, at: Self.space(base.union(row.requiredGear.contains(.trapBar) ? [.trapBar] : []))))
            if row.requiredGear.contains(.trapBar) {
                #expect(!WorkoutSafetyFilter.hasEquipment(for: row, at: Self.space(base)), "\(row.name) is planned with no trap bar")
            }
        }
        let bar = Self.added(by: [.barbell, .weightPlates])
        #expect(bar.isSuperset(of: ["Deadlift", "Overhead press", "Barbell row"]))
        #expect(!bar.contains("Back squat") && !bar.contains("Bench press"), "a squat needs the rack, a bench press the bench")
        let squat = try #require(WorkoutExerciseCatalog.exercise(named: "Back squat"))
        #expect(WorkoutSafetyFilter.missingEquipment(for: squat, at: Self.space([.barbell])).count == 2)
    }

    // MARK: - What a space unlocks

    /// The empty hotel room is never given a dip, an inverted row or an ab wheel: not by the
    /// filter, and not on any day of any split at any level.
    @Test func theEmptyRoomNeverGetsDipInvertedRowOrAbWheel() {
        let needGear: Set<String> = ["Dip", "Assisted dip", "Inverted row", "Ab wheel"]
        #expect(Self.unlocked(at: Self.emptyRoom).isDisjoint(with: needGear))
        for split in WorkoutSplitCatalog.all {
            for day in split.days.indices {
                for experience in ExperienceLevel.allCases {
                    let planned = Self.plannedRows(at: Self.emptyRoom, split: split, day: day, experience: experience)
                    #expect(needGear.isDisjoint(with: planned), "\(split.id) day \(day + 1) \(experience.rawValue): \(planned)")
                }
            }
        }
    }

    /// One leg press unlocks the leg press and nothing else: no calf-raise machine, no leg curl.
    @Test func aSingleLegPressUnlocksOnlyLegPressExercises() {
        #expect(Self.added(by: [.legPress]) == ["Leg press"])
        #expect(Self.added(by: [.chestPress]) == ["Chest press machine"])
        #expect(Self.added(by: [.assistedPullUpDip]) == ["Assisted dip", "Assisted pull-up"])
        #expect(Self.added(by: [.pecDeck]) == ["Pec deck", "Reverse pec deck"])
    }

    /// A Smith machine alone gives the Smith machine's squat — which needs nothing else — and no
    /// free barbell lift, with or without plates and a rack beside it.
    @Test func aSmithMachineAloneGivesSmithExercisesAndNoFreeBarbellLift() throws {
        let smith = Self.space([.smithMachine])
        #expect(!smith.has(.barbell) && smith.has(.machine))
        #expect(Self.added(by: [.smithMachine]) == ["Smith machine squat"])
        #expect(Self.added(by: [.smithMachine, .weightPlates, .squatRack]) == ["Smith machine squat"])
        let squat = try #require(WorkoutExerciseCatalog.exercise(named: "Smith machine squat"))
        #expect(squat.requiredGear == [.smithMachine])
        #expect(WorkoutSafetyFilter.missingEquipment(for: squat, at: smith).isEmpty)
        for name in ["Deadlift", "Overhead press", "Barbell row", "Back squat"] {
            let lift = try #require(WorkoutExerciseCatalog.exercise(named: name))
            #expect(!WorkoutSafetyFilter.hasEquipment(for: lift, at: smith), "\(name)")
        }
    }

    // MARK: - Presets

    /// What each preset ticks, pinned: Full gym ticks everything; the others tick no machine but
    /// the ones they always named, and none of the dip bars, low bar or ab wheel.
    @Test func thePresetsFillInTheChecklist() throws {
        func preset(_ id: String) throws -> Set<GymEquipment> {
            try #require(LocationTemplate.all.first { $0.id == id }).equipment
        }
        #expect(LocationTemplate.all.map(\.id) == ["full-gym", "hotel-gym", "apartment-gym", "home-setup"])
        #expect(try preset("full-gym") == Set(GymEquipment.allCases))
        #expect(WorkoutLocation.fullGym.ownedEquipment == Set(GymEquipment.allCases))
        #expect(try preset("hotel-gym") == [.treadmill, .exerciseBike, .dumbbells, .weightBench, .cableMachine])
        #expect(try preset("apartment-gym") == [.treadmill, .elliptical, .dumbbells, .weightBench, .cableMachine, .legPress])
        #expect(try preset("home-setup") == [.dumbbells, .kettlebells, .resistanceBands, .yogaMat, .pullUpBar])
        #expect(WorkoutLocation.home.ownedEquipment == [.dumbbells, .kettlebells, .resistanceBands, .yogaMat, .pullUpBar])
        for template in LocationTemplate.all {
            let made = template.makeLocation()
            #expect(made.ownedEquipment == template.equipment)
            #expect(made.equipmentListVersion == WorkoutLocation.itemizedListVersion)
        }
    }

    /// Each preset's unlocked machine exercises are exactly the ones its checklist names.
    @Test func eachPresetUnlocksExactlyTheMachinesItsChecklistNames() {
        var spaces = LocationTemplate.all.map { $0.makeLocation() }
        spaces += [.fullGym, .home, Self.emptyRoom]
        for location in spaces {
            let named = Set(Self.machineOf.filter { location.ownedEquipment.contains($0.value) }.keys)
            let machineRows = Set(Self.catalog.filter { $0.equipment == .machine }.map(\.name))
            #expect(Self.unlocked(at: location).intersection(machineRows) == named, "\(location.name)")
        }
        func machines(_ id: String) -> Set<String> {
            let location = LocationTemplate.all.first { $0.id == id }?.makeLocation() ?? Self.emptyRoom
            return Self.unlocked(at: location).intersection(Self.machineOf.keys)
        }
        #expect(machines("full-gym") == Set(Self.machineOf.keys))
        #expect(machines("apartment-gym") == ["Leg press"], "the apartment gym's leg press is not a calf-raise machine")
        #expect(machines("hotel-gym").isEmpty && machines("home-setup").isEmpty)
        #expect(Self.unlocked(at: .fullGym).isSuperset(of: ["Dip", "Inverted row", "Ab wheel"]))
        #expect(Self.unlocked(at: .home).isDisjoint(with: ["Dip", "Inverted row", "Ab wheel"]))
    }

    /// The sweep: every exercise planned for every preset, on every day of every split at every
    /// level, is one that preset's gear allows.
    @Test func everyExercisePlannedForEveryPresetIsOneItsGearAllows() throws {
        let rows = Dictionary(Self.catalog.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var spaces = LocationTemplate.all.map { $0.makeLocation() }
        spaces += [.fullGym, .home, Self.emptyRoom]
        for location in spaces {
            for split in WorkoutSplitCatalog.all {
                for day in split.days.indices {
                    for experience in ExperienceLevel.allCases {
                        for name in Self.plannedRows(at: location, split: split, day: day, experience: experience) {
                            let row = try #require(rows[name], "\(name) is not a bundled exercise")
                            let missing = WorkoutSafetyFilter.missingEquipment(for: row, at: location)
                            #expect(missing.isEmpty, "\(location.name), \(split.id) day \(day + 1), \(experience.rawValue): \(name) needs \(missing)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - A space saved before the fix

    /// A location saved before each machine had its own row decodes and keeps its machines: a
    /// leg press or chest press stood for every machine, so every machine is ticked for it. The
    /// version is then written, so the grant runs once and an unticked machine stays unticked.
    @Test func anOldSavedLocationDecodesAndKeepsItsMachines() throws {
        let apartment: [GymEquipment] = [.treadmill, .elliptical, .dumbbells, .weightBench, .cableMachine, .legPress]
        var old = try Self.decode(Self.savedJSON(apartment))
        #expect(old.ownedEquipment == Set(apartment).union(GymEquipment.itemizedMachines))
        #expect(old.equipmentListVersion == WorkoutLocation.itemizedListVersion)
        let kept: Set<String> = ["Leg press", "Leg curl", "Leg extension", "Seated calf raise", "Pec deck", "Assisted pull-up"]
        #expect(Self.unlocked(at: old).isSuperset(of: kept))
        // What its ticks never unlocked stays locked: the chest press and Smith machine named themselves.
        #expect(Self.unlocked(at: old).isDisjoint(with: ["Chest press machine", "Smith machine squat"]))

        // The owner opens the checklist and unticks the leg curl: it stays unticked across a save.
        old.ownedEquipment.remove(.legCurl)
        let saved = try JSONEncoder().encode(old)
        let object = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(object["equipmentListVersion"] as? Int == 2)
        let reopened = try JSONDecoder().decode(WorkoutLocation.self, from: saved)
        #expect(reopened == old && !reopened.ownedEquipment.contains(.legCurl))

        // A chest press alone used to unlock Leg press too: it is kept, ticked.
        let chestOnly = try Self.decode(Self.savedJSON([.dumbbells, .chestPress]))
        #expect(chestOnly.ownedEquipment.contains(.legPress) && chestOnly.ownedEquipment.isSuperset(of: GymEquipment.itemizedMachines))
        // A space with no machines is granted none.
        let home = try Self.decode(Self.savedJSON([.dumbbells, .kettlebells, .resistanceBands, .yogaMat, .pullUpBar]))
        #expect(home.ownedEquipment == WorkoutLocation.home.ownedEquipment)
    }

    /// The default Full gym every install saved — all 22 older pieces — is still the Full gym: it
    /// gets the whole list, dip bars, low bar and ab wheel included.
    @Test func anOldSavedFullGymIsStillTheFullGym() throws {
        #expect(GymEquipment.originalPieces.count == 22)
        let original = GymEquipment.allCases.filter(GymEquipment.originalPieces.contains)
        let old = try Self.decode(Self.savedJSON(original))
        #expect(old.ownedEquipment == Set(GymEquipment.allCases))
        #expect(Self.unlocked(at: old) == Self.unlocked(at: .fullGym))
        // One piece short of everything is the owner's own list: no dip bars are assumed.
        let nearly = try Self.decode(Self.savedJSON(original.filter { $0 != .foamRoller }))
        #expect(nearly.ownedEquipment.isDisjoint(with: GymEquipment.itemizedSmallPieces))
        #expect(nearly.ownedEquipment.isSuperset(of: GymEquipment.itemizedMachines))
    }

    /// The corrections that make a space safer apply to saved spaces at once: a Smith machine,
    /// plates or a rack no longer stand for a barbell, and Dip, Inverted row and Ab wheel need
    /// their gear. A ticked barbell keeps its lifts (the plates they now name are ticked for it).
    @Test func theSaferCorrectionsApplyToSavedSpacesAtOnce() throws {
        let smith = try Self.decode(Self.savedJSON([.smithMachine, .weightPlates, .squatRack, .weightBench, .dumbbells]))
        #expect(smith.ownedEquipment == [.smithMachine, .weightPlates, .squatRack, .weightBench, .dumbbells])
        #expect(!smith.has(.barbell))
        let unlocked = Self.unlocked(at: smith)
        #expect(unlocked.isDisjoint(with: ["Deadlift", "Overhead press", "Barbell row", "Back squat", "Bench press"]))
        #expect(unlocked.isDisjoint(with: ["Dip", "Inverted row", "Ab wheel"]))
        #expect(unlocked.contains("Smith machine squat"), "the Smith machine's own squat no longer needs a leg press")

        let garage = try Self.decode(Self.savedJSON([.barbell, .squatRack, .weightBench]))
        #expect(garage.ownedEquipment == [.barbell, .weightPlates, .squatRack, .weightBench])
        #expect(Self.unlocked(at: garage).isSuperset(of: ["Deadlift", "Back squat", "Bench press"]))
    }

    /// A location this build saved is read literally, a newer build's version number survives a
    /// save here, and a version that is not a number grants nothing.
    @Test func aLocationSavedWithTheItemizedListIsReadLiterally() throws {
        let literal = try Self.decode(Self.savedJSON([.legPress, .barbell], extra: #", "equipmentListVersion": 2"#))
        #expect(literal.ownedEquipment == [.legPress, .barbell])
        let newer = try Self.decode(Self.savedJSON([.legPress], extra: #", "equipmentListVersion": 3"#))
        #expect(newer.ownedEquipment == [.legPress] && newer.equipmentListVersion == 3)
        let resaved = try JSONDecoder().decode(WorkoutLocation.self, from: JSONEncoder().encode(newer))
        #expect(resaved.equipmentListVersion == 3)
        let corrupt = try Self.decode(Self.savedJSON([.legPress], extra: #", "equipmentListVersion": "two""#))
        #expect(corrupt.ownedEquipment == [.legPress] && corrupt.equipmentListVersion == 2)
        // The new tokens round-trip, and an older build's parked copy of them is read back.
        let parked = try Self.decode(Self.savedJSON([.dumbbells], extra: #", "unknownOwnedEquipmentTokens": ["dipBars", "legCurl"], "equipmentListVersion": 2"#))
        #expect(parked.ownedEquipment == [.dumbbells, .dipBars, .legCurl] && parked.unknownEquipmentTokens.isEmpty)
    }

    /// When a correction leaves a saved space's regular day short, the planner fills it from the
    /// lifts the space still allows and says so — never a lift the space has no gear for, and
    /// never fewer than three lifts without becoming the mobility offer.
    @Test func aSavedSpaceLeftShortIsFilledAndSaysSo() throws {
        // Saved when a Smith machine, plates and a rack stood for a barbell: Arms day was barbell
        // curls and skullcrushers there.
        let saved = try Self.decode(Self.savedJSON([.smithMachine, .weightPlates, .squatRack]))
        let rows = Dictionary(Self.catalog.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let profile = WorkoutProfile(experience: .intermediate)
        let arms = WorkoutProgram.dayPlan(goal: .strength, intensity: .moderate, profile: profile, location: saved,
                                          context: "", split: WorkoutSplitCatalog.broSplit5, rotationIndex: 3)
        let session = try #require(arms.sessions.first)
        #expect(session.title == "Arms")
        #expect(session.suggestion.notes.contains("Arms day, filled in with other lifts this space allows."), "\(session.suggestion.notes)")
        for split in WorkoutSplitCatalog.all {
            for (index, day) in split.days.enumerated() {
                let plan = WorkoutProgram.dayPlan(goal: .strength, intensity: .moderate, profile: profile, location: saved,
                                                  context: "", split: split, rotationIndex: index)
                for (planned, template) in zip(plan.sessions, day.sessions) {
                    let what = "\(split.id) day \(index + 1), \(template.title)"
                    #expect(!planned.suggestion.exercises.lowercased().contains("circuit"), "\(what)")
                    var lifts: Set<String> = []
                    for step in planned.exercises where step.fromCatalog {
                        let row = try #require(rows[step.name], "\(what): \(step.name)")
                        #expect(WorkoutSafetyFilter.hasEquipment(for: row, at: saved), "\(what) planned \(step.name)")
                        if step.block == .lifting { lifts.insert(step.name) }
                    }
                    guard template.kind != .cardio, template.kind != .mobility else { continue }
                    let needed = WorkoutProgram.minimumLifts(for: template.slots.filter { $0.role != .core })
                    #expect(lifts.count >= needed || WorkoutProgram.isMobilityOffer(planned), "\(what): \(lifts.sorted())")
                }
            }
        }
    }
}
