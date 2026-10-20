// CustomExerciseDraft.swift
// FernletDomainModel
//
// Hand-made custom exercises (2026-10-20, idea 15 of the comparison report). Until now a custom
// exercise could only arrive with an imported coach plan; Hevy and JEFIT let a lifter add their own.
// A hand-made exercise asks for the same fields a bundled catalog row carries — muscles, pattern,
// plane, equipment, gear, measure, sides, difficulty and modality — so ``WorkoutSafetyFilter`` and slot
// eligibility treat it exactly like one. It lives where coach-imported customs live
// (`FernletSettings.customExercises`, mirrored into ``WorkoutExerciseCatalog``), under the same cap.

import Foundation

/// The custom-exercise form's state, and the catalog row it saves as.
///
/// Every field is an ``ExerciseTarget`` field the bundled catalog curates, so the saved row
/// (``target``) is indistinguishable to the planner from a bundled one: the safety filter reads its
/// muscles, pattern, tools and gear; slot eligibility its modality, pattern, plane and primary
/// muscles. The plane is kept only for a push or a pull (the only patterns that have one), the
/// secondary muscles never repeat a primary one, and the main tool never repeats as an alternative.
public nonisolated struct CustomExerciseDraft: Equatable, Sendable {
    public var name: String
    public var primaryMuscles: Set<MuscleGroup>
    public var secondaryMuscles: Set<MuscleGroup>
    public var movementPattern: MovementPattern
    public var plane: MovementPlane?
    public var equipment: Equipment
    public var alternativeEquipment: Set<Equipment>
    public var requiredGear: Set<GymEquipment>
    public var measure: ExerciseMeasure
    public var unilateral: Bool
    public var difficulty: ExerciseDifficulty
    public var modality: ExerciseModality

    /// The measures the form offers, in order (``ExerciseMeasure`` is not `CaseIterable`).
    public static let measures: [ExerciseMeasure] = [.reps, .seconds]

    /// A blank form: a standard strength push with bodyweight, counted in reps.
    public init() {
        name = ""
        primaryMuscles = []
        secondaryMuscles = []
        movementPattern = .push
        plane = nil
        equipment = .bodyweight
        alternativeEquipment = []
        requiredGear = []
        measure = .reps
        unilateral = false
        difficulty = .standard
        modality = .strength
    }

    /// The form opened on an existing custom exercise, for editing.
    public init(_ target: ExerciseTarget) {
        name = target.name
        primaryMuscles = target.primaryMuscles
        secondaryMuscles = target.secondaryMuscles
        movementPattern = target.movementPattern
        plane = target.plane
        equipment = target.equipment
        alternativeEquipment = Set(target.alternativeEquipment)
        requiredGear = Set(target.requiredGear)
        measure = target.measure
        unilateral = target.unilateral
        difficulty = target.difficulty
        modality = target.modality
    }

    /// Whether the pattern has a direction to pick (a push or a pull).
    public var patternHasPlane: Bool {
        movementPattern == .push || movementPattern == .pull
    }

    /// The trimmed name the exercise is saved under — its FROZEN identity from then on.
    public var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The catalog row this draft saves as, in the catalog's own field order.
    public var target: ExerciseTarget {
        ExerciseTarget(
            name: trimmedName,
            primaryMuscles: primaryMuscles,
            secondaryMuscles: secondaryMuscles.subtracting(primaryMuscles),
            equipment: equipment,
            movementPattern: movementPattern,
            inputKind: .strength,
            plane: patternHasPlane ? plane : nil,
            modality: modality,
            difficulty: difficulty,
            measure: measure,
            alternativeEquipment: Equipment.allCases.filter { alternativeEquipment.contains($0) && $0 != equipment },
            requiredGear: GymEquipment.allCases.filter { requiredGear.contains($0) },
            unilateral: unilateral
        )
    }
}

/// Why a custom exercise cannot be saved as it stands.
public nonisolated enum CustomExerciseIssue: Error, Equatable, Sendable {
    /// No name, or only spaces.
    case emptyName
    /// Longer than ``CustomExerciseLibrary/maxNameCharacters``.
    case nameTooLong
    /// A bundled exercise already has this name (any case or spacing).
    case clashesWithCatalog
    /// Another of the user's own exercises already has this name.
    case duplicateName
    /// No main muscle picked — the planner and the safety filter need at least one.
    case noPrimaryMuscle
    /// The list already holds ``WorkoutExerciseCatalog/maxCustomExercises``.
    case atCapacity

    /// The form's explanation, localized.
    public var message: String {
        switch self {
        case .emptyName:
            String(localized: "customExercise.issue.emptyName", defaultValue: "Give it a name.",
                   bundle: .module, comment: "Custom exercise form: the name is empty")
        case .nameTooLong:
            String(localized: "customExercise.issue.nameTooLong", defaultValue: "That name is too long. Keep it under 80 characters.",
                   bundle: .module, comment: "Custom exercise form: the name is over the length limit")
        case .clashesWithCatalog:
            String(localized: "customExercise.issue.clashesWithCatalog",
                   defaultValue: "Fernlet already has an exercise with that name. Pick another name.",
                   bundle: .module, comment: "Custom exercise form: the name matches a built-in exercise")
        case .duplicateName:
            String(localized: "customExercise.issue.duplicateName",
                   defaultValue: "One of your exercises already has that name.",
                   bundle: .module, comment: "Custom exercise form: the name matches another custom exercise")
        case .noPrimaryMuscle:
            String(localized: "customExercise.issue.noPrimaryMuscle", defaultValue: "Pick at least one main muscle.",
                   bundle: .module, comment: "Custom exercise form: no main muscle chosen")
        case .atCapacity:
            String(localized: "customExercise.issue.atCapacity",
                   defaultValue: "That's the most exercises Fernlet keeps. Delete one to add another.",
                   bundle: .module, comment: "Custom exercise form: the custom exercise list is full")
        }
    }
}

/// Adds, edits and deletes the user's own exercises — pure list operations the store applies to
/// `FernletSettings.customExercises`.
///
/// One list for both writers: the coach-plan import and the hand-made form share it and its cap
/// (``WorkoutExerciseCatalog/maxCustomExercises``), so no seam can disagree about how many exercises
/// the user has. Names compare by ``WorkoutExerciseCatalog/normalizedName(_:)``, the planner's own
/// key. Deleting removes the catalog row only: logged workouts keep their lines, and history,
/// progression and exports read those by name.
public nonisolated enum CustomExerciseLibrary {
    /// The longest name the form accepts — the coach-plan import's limit.
    public static let maxNameCharacters = WorkoutExercisePreferences.maxNameCharacters

    /// What stops `draft` from being saved into `existing`, in the order the form shows them. With
    /// `editing` set (the name of the exercise being edited), that exercise neither counts toward the
    /// cap nor clashes with itself.
    public static func issues(
        for draft: CustomExerciseDraft, existing: [ExerciseTarget], base: [ExerciseTarget], editing: String? = nil
    ) -> [CustomExerciseIssue] {
        var found: [CustomExerciseIssue] = []
        let name = draft.trimmedName
        let key = WorkoutExerciseCatalog.normalizedName(name)
        let editingKey = editing.map(WorkoutExerciseCatalog.normalizedName)
        if editingKey == nil, existing.count >= WorkoutExerciseCatalog.maxCustomExercises { found.append(.atCapacity) }
        if name.isEmpty {
            found.append(.emptyName)
        } else if name.count > maxNameCharacters {
            found.append(.nameTooLong)
        } else if base.contains(where: { WorkoutExerciseCatalog.normalizedName($0.name) == key }) {
            found.append(.clashesWithCatalog)
        } else if existing.contains(where: {
            let other = WorkoutExerciseCatalog.normalizedName($0.name)
            return other == key && other != editingKey
        }) {
            found.append(.duplicateName)
        }
        if draft.primaryMuscles.isEmpty { found.append(.noPrimaryMuscle) }
        return found
    }

    /// `existing` with `draft` appended, or the first issue that stops it.
    public static func adding(
        _ draft: CustomExerciseDraft, to existing: [ExerciseTarget], base: [ExerciseTarget]
    ) -> Result<[ExerciseTarget], CustomExerciseIssue> {
        if let issue = issues(for: draft, existing: existing, base: base).first { return .failure(issue) }
        return .success(existing + [draft.target])
    }

    /// `existing` with the exercise named `name` replaced in place by `draft` (which may rename it),
    /// or the first issue that stops it. An unknown `name` changes nothing.
    public static func replacing(
        _ name: String, with draft: CustomExerciseDraft, in existing: [ExerciseTarget], base: [ExerciseTarget]
    ) -> Result<[ExerciseTarget], CustomExerciseIssue> {
        if let issue = issues(for: draft, existing: existing, base: base, editing: name).first { return .failure(issue) }
        let key = WorkoutExerciseCatalog.normalizedName(name)
        guard let index = existing.firstIndex(where: { WorkoutExerciseCatalog.normalizedName($0.name) == key }) else {
            return .success(existing)
        }
        var updated = existing
        updated[index] = draft.target
        return .success(updated)
    }

    /// `existing` without the exercise named `name`.
    public static func removing(_ name: String, from existing: [ExerciseTarget]) -> [ExerciseTarget] {
        let key = WorkoutExerciseCatalog.normalizedName(name)
        guard !key.isEmpty else { return existing }
        return existing.filter { WorkoutExerciseCatalog.normalizedName($0.name) != key }
    }
}
