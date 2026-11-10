// CoachExerciseTraits.swift
// FernletDomainModel
//
// Default traits for an exercise a coach plan defines (the owner's fix e8.5, 2026-11-10).
//
// A coach's definition carries a name, muscles, a tool and a movement pattern. The planner's filters
// read more than that: a slot's plane (a vertical pull slot must not take a row), the modality (only
// strength rows fill lifting slots), the difficulty (a mild area leaves advanced moves out; beginners
// are steered off them) and the specific gear a movement cannot be done without (a pull-up needs a
// bar). A coach-defined exercise used to keep every one of those at its default — any plane, strength,
// standard, no gear — so a coach's "Weighted pull-up" filled a horizontal pull slot in a room with no
// bar. These defaults are read from the definition's own name and tags, conservatively: a trait is set
// only when a word in the name or a tag says so, and is otherwise left at the default it had.
//
// The words are FROZEN English matching vocabulary (the localization wall), like the injury note's.

import Foundation

/// Reads sensible default traits for a coach-defined exercise from its name and tags.
///
/// Pure and deterministic; every scan is over a short fixed word list. The person's own exercise form
/// (``CustomExerciseDraft``) sets these fields directly and never comes through here.
public nonisolated enum CoachExerciseTraits {

    /// `target` with its plane, modality, difficulty and required gear read from its name and tags.
    /// A trait the definition already sets (it cannot today) would be kept.
    public static func applied(to target: ExerciseTarget) -> ExerciseTarget {
        let name = " " + target.name.lowercased().replacingOccurrences(of: "-", with: " ") + " "
        var traited = target
        if traited.plane == nil { traited.plane = plane(for: target, name: name) }
        if traited.modality == .strength { traited.modality = modality(for: target, name: name) }
        if traited.difficulty == .standard { traited.difficulty = difficulty(for: target, name: name) }
        if traited.requiredGear.isEmpty { traited.requiredGear = gear(for: target, name: name) }
        return traited
    }

    /// Words that make a push or pull vertical, or horizontal.
    static let verticalWords = ["overhead", "shoulder press", "military", "pull up", "pullup", "chin up", "chinup",
                                "pulldown", "pull down", "handstand", "pike"]
    /// See ``verticalWords``.
    static let horizontalWords = ["bench", "push up", "pushup", "chest press", "row", "fly", "floor press"]

    /// The plane of a push or pull: from the name, else from the muscles a press targets (chest:
    /// horizontal; shoulders without chest: vertical). Nil — any plane — for everything else.
    static func plane(for target: ExerciseTarget, name: String) -> MovementPlane? {
        guard target.movementPattern == .push || target.movementPattern == .pull else { return nil }
        if verticalWords.contains { name.contains($0) } { return .vertical }
        if horizontalWords.contains { name.contains($0) } { return .horizontal }
        guard target.movementPattern == .push else { return nil }
        if target.primaryMuscles.contains(.chest) { return .horizontal }
        let shoulders: Set<MuscleGroup> = [.frontDelts, .sideDelts]
        return target.primaryMuscles.isDisjoint(with: shoulders) ? nil : .vertical
    }

    /// Words that name a stretch, a jump or throw, cardio, or a balance drill.
    static let mobilityWords = ["stretch", "mobility", "yoga", " pose ", "foam roll"]
    /// See ``mobilityWords``.
    static let powerWords = ["jump", "bound", "slam", "throw", "snatch", " clean ", "plyo"]
    /// See ``mobilityWords``.
    static let cardioWords = ["sprint", " run ", "running", "jog", "treadmill", " bike ", "cycling", "rowing machine",
                              "elliptical", "stair", "jump rope", "skipping"]
    /// See ``mobilityWords``.
    static let balanceWords = ["balance", "single leg stance"]

    /// The modality: cardio for a treadmill entry, locomotion or a cardio word; a stretch, a jump or
    /// throw, or a balance drill by its word; strength otherwise.
    static func modality(for target: ExerciseTarget, name: String) -> ExerciseModality {
        if mobilityWords.contains { name.contains($0) } { return .mobility }
        if balanceWords.contains { name.contains($0) } { return .balance }
        if target.inputKind == .treadmill || cardioWords.contains { name.contains($0) } { return .cardio }
        if powerWords.contains { name.contains($0) } { return .power }
        return target.movementPattern == .locomotion ? .cardio : .strength
    }

    /// Words that mark a harder step, or an easier one.
    static let advancedWords = ["weighted", "single leg", "single arm", "one arm", "one leg", "pistol", "muscle up",
                                "handstand", "deficit", "front squat", "overhead squat", "snatch", " clean ", "nordic",
                                "dragon flag", "pull up", "pullup", "chin up", "chinup", " dip "]
    /// See ``advancedWords``.
    static let foundationalWords = ["assisted", "wall ", "knee push", "incline push", "box squat", "supported", "seated "]

    /// The difficulty: foundational for an assisted or supported step (it wins: an "Assisted pull-up"
    /// is the easy one) or a machine; advanced for a harder-step word; standard otherwise.
    static func difficulty(for target: ExerciseTarget, name: String) -> ExerciseDifficulty {
        if foundationalWords.contains { name.contains($0) } { return .foundational }
        if advancedWords.contains { name.contains($0) } { return .advanced }
        return target.equipment == .machine ? .foundational : .standard
    }

    /// The pieces a name asks for, in the order they are checked.
    static let gearWords: [(word: String, gear: GymEquipment)] = [
        ("pull up", .pullUpBar), ("pullup", .pullUpBar), ("chin up", .pullUpBar), ("chinup", .pullUpBar),
        ("hanging", .pullUpBar), ("pulldown", .latPulldown), ("pull down", .latPulldown),
        ("leg press", .legPress), ("smith", .smithMachine), ("cable", .cableMachine),
        ("bench", .weightBench), ("incline", .weightBench), ("decline", .weightBench),
        ("treadmill", .treadmill), (" bike ", .exerciseBike), ("rowing machine", .rowingMachine),
        ("elliptical", .elliptical), ("stair climber", .stairClimber), ("medicine ball", .medicineBall),
        ("med ball", .medicineBall), ("battle rope", .battleRopes), ("foam roll", .foamRoller),
        ("rack pull", .squatRack), ("ab wheel", .abWheel), ("ab roller", .abWheel), ("inverted row", .lowBar),
    ]

    /// The machine a machine exercise's name asks for (the owner's fix e5: each machine has its own
    /// row). Read only for a definition whose tool is a machine, so a "Band leg curl" asks for none.
    static let machineWords: [(word: String, gear: GymEquipment)] = [
        ("leg extension", .legExtension), ("leg curl", .legCurl), ("hack squat", .hackSquat),
        ("chest press", .chestPress), ("shoulder press", .shoulderPressMachine), ("pec deck", .pecDeck),
        ("seated row", .seatedRowMachine), ("standing calf", .standingCalfRaise), ("seated calf", .seatedCalfRaise),
        ("hip abduction", .hipAbductionAdduction), ("hip adduction", .hipAbductionAdduction),
    ]

    /// The specific gear the movement cannot be done without: a weight bench for a bench exercise,
    /// and each piece its name asks for. "Incline" and "decline" mean a bench only for a loaded lift
    /// (an incline push-up needs none).
    static func gear(for target: ExerciseTarget, name: String) -> [GymEquipment] {
        var gear: [GymEquipment] = target.equipment == .bench ? [.weightBench] : []
        let loaded: Set<Equipment> = [.barbell, .dumbbell, .kettlebell]
        for entry in gearWords where name.contains(entry.word) && !gear.contains(entry.gear) {
            let needsLoad = entry.word == "incline" || entry.word == "decline"
            if needsLoad && !loaded.contains(target.equipment) { continue }
            gear.append(entry.gear)
        }
        guard target.equipment == .machine else { return gear }
        for entry in machineWords where name.contains(entry.word) && !gear.contains(entry.gear) {
            gear.append(entry.gear)
        }
        return gear
    }
}
