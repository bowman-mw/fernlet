// CoachPlan.swift
// The `CoachPlan v1` wire schema (Fernlet Coach spec §3.5) — a 1-30 day workout plan authored
// outside Fernlet and ingested through a review gate.
//
// Transport-agnostic BY DESIGN. The first shipping producer is the manual clipboard loop (export a
// summary → paste into an AI assistant → paste the returned plan back), but the same bytes are what
// the `fernlet-coach` proximity mesh and the sealed iMessage link will carry once the Coach app
// exists. Nothing in this file knows or cares which pipe it came down.
//
// SECURITY POSTURE: a plan arriving here is UNTRUSTED and UNSIGNED. On the mesh it will be signed
// and sealed before it reaches this type; on the clipboard path it is literally whatever text the
// user pasted. So decoding is deliberately FAIL-CLOSED and bounded — every collection has a hard
// cap, every enum is matched explicitly (never `park`ed — a parked token is the compatibility story
// for a NEWER FERNLET BUILD's bytes, not for a language model's typo), and `validate()` reports
// every problem at once so the review screen can be honest about what is wrong instead of throwing
// one opaque `DecodingError`.

import Foundation

// MARK: - Plan

/// One coach-authored workout plan: 1-30 days of sessions, plus definitions for any exercise
/// Fernlet's catalog doesn't already know.
///
/// The unit of the coach information exchange (spec §3.5). Maps onto shipped types on ingestion —
/// a ``CoachSession`` becomes one `PlannedWorkout` tagged `WorkoutPlanSource.coach`, and each
/// ``CoachExerciseDefinition`` becomes a custom ``ExerciseTarget`` in the user's catalog.
///
/// Never trust a decoded value: `init(from:)` enforces structure and bounds, and ``validate()``
/// enforces semantics (day numbering, undefined exercise names, absurd set counts). A plan that
/// fails either must not reach `PlannedWorkout` materialization.
public nonisolated struct CoachPlan: Codable, Equatable, Sendable, Identifiable {

    /// `planID` — so a decoded plan can drive a SwiftUI `.sheet(item:)` without a wrapper.
    public var id: UUID { planID }

    /// The schema version this build writes and is the newest it can read.
    ///
    /// A plan declaring a HIGHER version is rejected outright rather than partially understood —
    /// the same "tell the user to update, don't guess" posture the spec sets for the remote
    /// channels (§3.3).
    public static let currentSchemaVersion = 1

    /// The wire format tag, so a pasted blob that happens to be valid JSON but isn't a plan fails
    /// with a useful message instead of a field-by-field decode error.
    public static let formatTag = "fernlet.coach.plan"

    public var format: String
    public var schemaVersion: Int
    public var planID: UUID
    public var title: String
    /// Who authored the plan, as free text — "Claude", a trainer's name. Display only; it is NOT an
    /// identity claim and must never be rendered as if it were verified. (On the mesh path the
    /// verified identity comes from the envelope signature, never from this field.)
    public var coachDisplayName: String
    public var notes: String?
    public var startPolicy: CoachPlanStartPolicy
    public var days: [CoachPlanDay]
    /// Changes to workouts the user has ALREADY planned, targeted by the ids the export echoed.
    ///
    /// This is what makes "the coach adjusts my month" possible rather than only "the coach hands me
    /// a new block": `days` above proposes NEW workouts, while these rewrite or remove existing
    /// ones in place. Empty for a plain new-plan hand-off.
    public var edits: [CoachPlanEdit]
    /// Definitions for exercises this plan uses that Fernlet's catalog doesn't know.
    ///
    /// Metadata is REQUIRED (muscles + equipment + movement pattern) rather than optional: an
    /// exercise with no muscle or movement data is invisible to ``WorkoutSafetyFilter``, so it
    /// could silently prescribe a movement the user's profile avoids. Requiring the metadata is
    /// what keeps the safety pass meaningful for exercises Fernlet has never heard of.
    public var newExercises: [CoachExerciseDefinition]

    public init(
        format: String = CoachPlan.formatTag,
        schemaVersion: Int = CoachPlan.currentSchemaVersion,
        planID: UUID = UUID(),
        title: String,
        coachDisplayName: String,
        notes: String? = nil,
        startPolicy: CoachPlanStartPolicy = .onAccept,
        days: [CoachPlanDay],
        edits: [CoachPlanEdit] = [],
        newExercises: [CoachExerciseDefinition] = []
    ) {
        self.edits = edits
        self.format = format
        self.schemaVersion = schemaVersion
        self.planID = planID
        self.title = title
        self.coachDisplayName = coachDisplayName
        self.notes = notes
        self.startPolicy = startPolicy
        self.days = days
        self.newExercises = newExercises
    }

    /// Decodes leniently about *shape* (a missing `planID` is minted, a missing `format` is assumed)
    /// and strictly about *size* — every collection is capped here, before the values are retained,
    /// so a hostile or runaway blob can't be held in memory in full.
    ///
    /// `planID` is minted rather than required because a language model has no reason to invent a
    /// UUID and shouldn't be asked to; identity of a manually-pasted plan is established at import.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? CoachPlan.formatTag
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? CoachPlan.currentSchemaVersion
        planID = try c.decodeIfPresent(UUID.self, forKey: .planID) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Workout plan"
        coachDisplayName = try c.decodeIfPresent(String.self, forKey: .coachDisplayName) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        startPolicy = try c.decodeIfPresent(CoachPlanStartPolicy.self, forKey: .startPolicy) ?? .onAccept

        let decodedDays = try c.decodeIfPresent([CoachPlanDay].self, forKey: .days) ?? []
        guard decodedDays.count <= CoachPlanLimits.maxDays else {
            throw CoachPlanDecodeError.tooManyDays(decodedDays.count)
        }
        days = decodedDays

        let decodedExercises = try c.decodeIfPresent([CoachExerciseDefinition].self, forKey: .newExercises) ?? []
        guard decodedExercises.count <= CoachPlanLimits.maxNewExercises else {
            throw CoachPlanDecodeError.tooManyNewExercises(decodedExercises.count)
        }
        newExercises = decodedExercises

        let decodedEdits = try c.decodeIfPresent([CoachPlanEdit].self, forKey: .edits) ?? []
        guard decodedEdits.count <= CoachPlanLimits.maxEdits else {
            throw CoachPlanDecodeError.tooManyEdits(decodedEdits.count)
        }
        edits = decodedEdits
    }

    /// Persisted/wire JSON keys for a ``CoachPlan``.
    ///
    /// These names are also what the export prompt tells the model to emit, so renaming a case is a
    /// wire break on both halves of the loop — update `CoachExportPromptBuilder` in the same change.
    private enum CodingKeys: String, CodingKey {
        case format, schemaVersion, planID, title, coachDisplayName, notes, startPolicy, days
        case edits, newExercises
    }

    /// Every exercise name the plan actually prescribes, in first-seen order.
    ///
    /// Covers `edits` as well as `days`: an exercise introduced only by an edit still has to be
    /// known or defined, or the safety filter has nothing to check it against.
    public var prescribedExerciseNames: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        func absorb(_ exercises: [CoachExercise]) {
            for exercise in exercises {
                let key = CoachPlan.normalizedName(exercise.name)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                ordered.append(exercise.name)
            }
        }
        for day in days {
            for session in day.sessions { absorb(session.exercises) }
        }
        for edit in edits { absorb(edit.exercises ?? []) }
        return ordered
    }

    /// The count used for the "N sessions over M days" summary on the review screen.
    public var sessionCount: Int { days.reduce(0) { $0 + $1.sessions.count } }

    /// The case- and whitespace-insensitive key used to match a prescribed name against the catalog
    /// and against ``newExercises``.
    ///
    /// A model writes "Bench Press", "bench press", and "Bench  press" interchangeably; matching on
    /// the raw string would treat all three as unknown exercises and mint three catalog duplicates.
    public static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

// MARK: - Start policy

/// When the plan's day 1 lands: at accept time, or on a fixed `yyyy-MM-dd` the author chose.
///
/// Encoded as a flat object (`{"kind":"fixedDate","dayKey":"2026-08-17"}`) rather than a Swift
/// enum's default nested-case shape, because the export prompt has to be able to describe it to a
/// language model in one line. On the manual path this is only a *hint* — the user picks the real
/// start date on the review screen — but the Coach app will honour it directly.
public nonisolated enum CoachPlanStartPolicy: Codable, Equatable, Sendable {
    case onAccept
    case fixedDate(dayKey: String)

    /// Wire JSON keys for the flat, tagged encoding (`{"kind":…,"dayKey":…}`).
    ///
    /// Flat rather than Swift's nested-case default so the export prompt can describe the shape to a
    /// language model in one line.
    private enum CodingKeys: String, CodingKey { case kind, dayKey }

    /// A `yyyy-MM-dd` day key, the only bare-string form that can mean `.fixedDate`.
    private static func isDayKey(_ raw: String) -> Bool {
        raw.count == 10 && raw.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil
    }

    public init(from decoder: Decoder) throws {
        // Tolerate the bare string form as well as the object form: handed a one-of description, a
        // model writes `"startPolicy": "onAccept"` or even `"startPolicy": "2026-08-17"` at least as
        // often as the tagged object. Anything else unrecognised falls back to `.onAccept`, which is
        // the safe default — the user picks the real start date on the review screen either way.
        if let single = try? decoder.singleValueContainer(), let raw = try? single.decode(String.self) {
            self = Self.isDayKey(raw) ? .fixedDate(dayKey: raw) : .onAccept
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "onAccept"
        if kind == "fixedDate", let dayKey = try c.decodeIfPresent(String.self, forKey: .dayKey), !dayKey.isEmpty {
            self = .fixedDate(dayKey: dayKey)
        } else {
            self = .onAccept
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .onAccept:
            try c.encode("onAccept", forKey: .kind)
        case .fixedDate(let dayKey):
            try c.encode("fixedDate", forKey: .kind)
            try c.encode(dayKey, forKey: .dayKey)
        }
    }
}

// MARK: - Day / session / exercise

/// One day of a ``CoachPlan``: its 1-based index, a title, and either a rest marker or sessions.
///
/// `dayIndex` is the plan's own numbering, not a calendar date — the calendar anchor is chosen at
/// import. A rest day carries no sessions and materializes no `PlannedWorkout`.
public nonisolated struct CoachPlanDay: Codable, Equatable, Sendable {
    public var dayIndex: Int
    public var title: String
    public var isRestDay: Bool
    public var sessions: [CoachSession]

    public init(dayIndex: Int, title: String, isRestDay: Bool = false, sessions: [CoachSession] = []) {
        self.dayIndex = dayIndex
        self.title = title
        self.isRestDay = isRestDay
        self.sessions = sessions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dayIndex = try c.decodeIfPresent(Int.self, forKey: .dayIndex) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        isRestDay = try c.decodeIfPresent(Bool.self, forKey: .isRestDay) ?? false
        let decoded = try c.decodeIfPresent([CoachSession].self, forKey: .sessions) ?? []
        guard decoded.count <= CoachPlanLimits.maxSessionsPerDay else {
            throw CoachPlanDecodeError.tooManySessions(dayIndex: dayIndex, count: decoded.count)
        }
        sessions = decoded
    }

    /// Wire JSON keys for one plan day; mirrored in the export prompt's schema description.
    private enum CodingKeys: String, CodingKey { case dayIndex, title, isRestDay, sessions }
}

/// One training session within a day: a title, a kind, optional notes/conditioning, and its
/// prescribed exercises.
///
/// Maps onto `WorkoutProgram.SessionSuggestion` on the guided path and onto a single
/// `PlannedWorkout` when materialized. `conditioning` carries the free-text descriptor a cardio or
/// mobility session renders instead of an exercise list.
public nonisolated struct CoachSession: Codable, Equatable, Sendable {
    public var title: String
    /// A ``SessionKind`` raw value. Held as a string so an unrecognised kind degrades to a default
    /// with a *reported* issue rather than failing the whole plan — a wrong session label is
    /// cosmetic, unlike a wrong muscle, which is a safety input.
    public var kind: String
    public var notes: String?
    public var conditioning: String?
    public var exercises: [CoachExercise]

    public init(title: String, kind: String = SessionKind.strength.rawValue, notes: String? = nil,
                conditioning: String? = nil, exercises: [CoachExercise] = []) {
        self.title = title
        self.kind = kind
        self.notes = notes
        self.conditioning = conditioning
        self.exercises = exercises
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? SessionKind.strength.rawValue
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        conditioning = try c.decodeIfPresent(String.self, forKey: .conditioning)
        let decoded = try c.decodeIfPresent([CoachExercise].self, forKey: .exercises) ?? []
        guard decoded.count <= CoachPlanLimits.maxExercisesPerSession else {
            throw CoachPlanDecodeError.tooManyExercises(sessionTitle: title, count: decoded.count)
        }
        exercises = decoded
    }

    /// The parsed session kind, falling back to `.strength` for an unrecognised raw value.
    public var resolvedKind: SessionKind { SessionKind(rawValue: kind) ?? .strength }

    /// Wire JSON keys for one session; mirrored in the export prompt's schema description.
    private enum CodingKeys: String, CodingKey { case title, kind, notes, conditioning, exercises }
}

/// One prescribed exercise: what to do, how much, and how long to rest.
///
/// `reps` is a STRING, not an Int, because real programming says "8-10", "AMRAP", "30s each side" —
/// and the shipped `PrescribedExercise.reps` is already a string for exactly that reason.
public nonisolated struct CoachExercise: Codable, Equatable, Sendable {
    public var name: String
    /// The catalog entry this refers to, when the author knew one. Free-text names are legitimate —
    /// they resolve by normalized name at import, and anything still unmatched must be defined in
    /// the plan's ``CoachPlan/newExercises``.
    public var catalogID: String?
    public var sets: Int
    public var reps: String
    public var restSeconds: Int?
    /// Coaching cue carried through to the plan notes — "RPE 7", "2s pause at the bottom".
    public var guidance: String?

    public init(name: String, catalogID: String? = nil, sets: Int, reps: String,
                restSeconds: Int? = nil, guidance: String? = nil) {
        self.name = name
        self.catalogID = catalogID
        self.sets = sets
        self.reps = reps
        self.restSeconds = restSeconds
        self.guidance = guidance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        catalogID = try c.decodeIfPresent(String.self, forKey: .catalogID)
        sets = try c.decodeIfPresent(Int.self, forKey: .sets) ?? 0
        // Models emit `"reps": 10` as often as `"reps": "8-10"`. Accept both rather than failing a
        // whole plan on a JSON type the schema description didn't fully pin down.
        if let text = try? c.decode(String.self, forKey: .reps) {
            reps = text
        } else if let number = try? c.decode(Int.self, forKey: .reps) {
            reps = String(number)
        } else {
            reps = ""
        }
        restSeconds = try c.decodeIfPresent(Int.self, forKey: .restSeconds)
        guidance = try c.decodeIfPresent(String.self, forKey: .guidance)
    }

    /// Wire JSON keys for one prescribed exercise; mirrored in the export prompt's schema description.
    private enum CodingKeys: String, CodingKey { case name, catalogID, sets, reps, restSeconds, guidance }

    /// The logged/planned free-text line this becomes, matching `PrescribedExercise.line`'s shape so
    /// coach-sourced and app-generated plans read identically in the UI.
    public var line: String {
        var text = "\(name) - \(sets) x \(reps)"
        if let guidance, !guidance.isEmpty { text += " (\(guidance))" }
        return text
    }
}

// MARK: - Edits to already-planned workouts

/// What an edit does to the planned workout it targets.
///
/// Three actions rather than two because the distinction is what makes the review summary honest:
/// "replaced" and "adjusted" are very different things to read in a list of proposed changes, even
/// though both end up rewriting the row.
public nonisolated enum CoachPlanEditAction: String, Codable, CaseIterable, Sendable {
    /// Change parts of the workout, keeping everything the edit doesn't mention.
    case adjust
    /// Rewrite the workout wholesale. Requires a full `exercises` list — a "replace" that named no
    /// exercises would silently be an adjust, which is the sort of quiet mismatch between what the
    /// screen says and what happens that this whole flow exists to avoid.
    case replace
    /// Remove the planned workout. Never touches anything already logged.
    case delete
}

/// One change to a workout the user has already planned.
///
/// `targetID` is a `PlannedWorkout.id` the export echoed. Targeting by id rather than by day+name
/// is what makes an edit survive a rename and stay unambiguous when a day holds two workouts with
/// the same name.
///
/// Every field except `targetID` and `action` is optional, and nil means KEEP: an `adjust` that
/// carries only `exercises` changes the exercises and leaves the name, notes, and duration alone.
public nonisolated struct CoachPlanEdit: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { targetID }

    public var targetID: UUID
    /// A ``CoachPlanEditAction`` raw value, held as a string so an unrecognised action produces a
    /// precise, quotable error instead of failing the whole paste.
    public var action: String
    public var title: String?
    public var kind: String?
    public var notes: String?
    public var conditioning: String?
    public var exercises: [CoachExercise]?

    public init(targetID: UUID, action: CoachPlanEditAction, title: String? = nil, kind: String? = nil,
                notes: String? = nil, conditioning: String? = nil, exercises: [CoachExercise]? = nil) {
        self.targetID = targetID
        self.action = action.rawValue
        self.title = title
        self.kind = kind
        self.notes = notes
        self.conditioning = conditioning
        self.exercises = exercises
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targetID = try c.decode(UUID.self, forKey: .targetID)
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? CoachPlanEditAction.adjust.rawValue
        title = try c.decodeIfPresent(String.self, forKey: .title)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        conditioning = try c.decodeIfPresent(String.self, forKey: .conditioning)
        let decoded = try c.decodeIfPresent([CoachExercise].self, forKey: .exercises)
        if let decoded, decoded.count > CoachPlanLimits.maxExercisesPerSession {
            throw CoachPlanDecodeError.tooManyExercises(sessionTitle: title ?? "an edit", count: decoded.count)
        }
        exercises = decoded
    }

    /// Wire JSON keys for one edit; mirrored in the export prompt's schema description.
    private enum CodingKeys: String, CodingKey {
        case targetID, action, title, kind, notes, conditioning, exercises
    }

    /// The parsed action, or nil for a value outside the vocabulary.
    public var resolvedAction: CoachPlanEditAction? { CoachPlanEditAction(rawValue: action) }
}

// MARK: - New-exercise definitions

/// A definition for an exercise Fernlet's catalog doesn't contain, supplied by the plan's author.
///
/// Converted to an ``ExerciseTarget`` and persisted into the user's custom catalog on accept, which
/// is what makes an imported exercise a first-class citizen: searchable in the picker, visible to
/// ``WorkoutSafetyFilter``, and scoreable by the program engine.
///
/// The enum-valued fields are held as STRINGS here and resolved in ``resolved()`` so an
/// unrecognised value produces a precise, quotable error ("unknown muscle 'pecs'") instead of an
/// opaque `DecodingError` that fails the entire paste.
public nonisolated struct CoachExerciseDefinition: Codable, Equatable, Sendable {
    public var name: String
    public var primaryMuscles: [String]
    public var secondaryMuscles: [String]
    public var equipment: String
    public var movementPattern: String
    public var inputKind: String?

    public init(name: String, primaryMuscles: [String], secondaryMuscles: [String] = [],
                equipment: String, movementPattern: String, inputKind: String? = nil) {
        self.name = name
        self.primaryMuscles = primaryMuscles
        self.secondaryMuscles = secondaryMuscles
        self.equipment = equipment
        self.movementPattern = movementPattern
        self.inputKind = inputKind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        // R3: an untrusted plan can list any number of muscle tokens, and each list is retained on
        // the definition. There are only so many muscles, so a list longer than the vocabulary is
        // never legitimate — reject rather than hold it.
        let decodedPrimary = try c.decodeIfPresent([String].self, forKey: .primaryMuscles) ?? []
        let decodedSecondary = try c.decodeIfPresent([String].self, forKey: .secondaryMuscles) ?? []
        let muscleCeiling = MuscleGroup.allCases.count
        guard decodedPrimary.count <= muscleCeiling, decodedSecondary.count <= muscleCeiling else {
            throw CoachPlanDecodeError.tooManyMuscles(
                exerciseName: name, count: max(decodedPrimary.count, decodedSecondary.count))
        }
        primaryMuscles = decodedPrimary
        secondaryMuscles = decodedSecondary
        equipment = try c.decodeIfPresent(String.self, forKey: .equipment) ?? ""
        movementPattern = try c.decodeIfPresent(String.self, forKey: .movementPattern) ?? ""
        inputKind = try c.decodeIfPresent(String.self, forKey: .inputKind)
    }

    /// Wire JSON keys for a new-exercise definition; mirrored in the export prompt's schema description.
    private enum CodingKeys: String, CodingKey {
        case name, primaryMuscles, secondaryMuscles, equipment, movementPattern, inputKind
    }

    /// Resolves this definition into a catalog ``ExerciseTarget``, or reports precisely which token
    /// it couldn't understand.
    ///
    /// Deliberately strict: a definition missing its primary muscles, equipment, or movement
    /// pattern is REJECTED rather than defaulted, because each of those is a ``WorkoutSafetyFilter``
    /// input. Defaulting `movementPattern` to `.isolation` would quietly make a squat variation
    /// pass an "avoid squat patterns" profile.
    public func resolved() -> Result<ExerciseTarget, CoachPlanIssue> {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return .failure(.init(kind: .invalidExerciseDefinition, subject: name,
                                  detail: "An exercise definition has no name."))
        }
        guard trimmedName.count <= CoachPlanLimits.maxNameCharacters else {
            return .failure(.init(kind: .invalidExerciseDefinition, subject: trimmedName,
                                  detail: "That exercise name is too long."))
        }
        guard !primaryMuscles.isEmpty else {
            return .failure(.init(kind: .invalidExerciseDefinition, subject: trimmedName,
                                  detail: "\"\(trimmedName)\" lists no primary muscles, so Fernlet can't "
                                  + "check it against the muscles you avoid."))
        }

        var primary = Set<MuscleGroup>()
        for raw in primaryMuscles {
            guard let muscle = CoachPlanTokens.muscle(raw) else {
                return .failure(.init(kind: .unknownToken, subject: trimmedName,
                                      detail: "Unknown muscle \"\(raw)\". Expected one of: "
                                      + CoachPlanTokens.muscleVocabulary))
            }
            primary.insert(muscle)
        }
        var secondary = Set<MuscleGroup>()
        for raw in secondaryMuscles {
            guard let muscle = CoachPlanTokens.muscle(raw) else {
                return .failure(.init(kind: .unknownToken, subject: trimmedName,
                                      detail: "Unknown muscle \"\(raw)\". Expected one of: "
                                      + CoachPlanTokens.muscleVocabulary))
            }
            secondary.insert(muscle)
        }
        guard let gear = CoachPlanTokens.equipment(equipment) else {
            return .failure(.init(kind: .unknownToken, subject: trimmedName,
                                  detail: "Unknown equipment \"\(equipment)\". Expected one of: "
                                  + CoachPlanTokens.equipmentVocabulary))
        }
        guard let pattern = CoachPlanTokens.movementPattern(movementPattern) else {
            return .failure(.init(kind: .unknownToken, subject: trimmedName,
                                  detail: "Unknown movement pattern \"\(movementPattern)\". Expected one of: "
                                  + CoachPlanTokens.movementVocabulary))
        }
        let kind = inputKind.flatMap(CoachPlanTokens.inputKind) ?? .strength

        return .success(ExerciseTarget(
            name: trimmedName,
            primaryMuscles: primary,
            secondaryMuscles: secondary.subtracting(primary),
            equipment: gear,
            movementPattern: pattern,
            inputKind: kind))
    }
}

// MARK: - Token matching

/// Case- and separator-insensitive matching from an author's raw string onto Fernlet's enums, plus
/// the human-readable vocabulary lists the export prompt and the error messages both quote.
///
/// A plan author writes "upper back", "upperBack", and "Upper-Back" for the same muscle; matching
/// only the exact raw value would reject all but one. Matching is still an ALLOWLIST — an
/// unrecognised token fails rather than falling back to a default, because these feed the safety
/// filter.
public nonisolated enum CoachPlanTokens {

    /// Folds a raw token to its comparison form: lowercased, with spaces, hyphens, and underscores
    /// removed, so "upper back" / "upper-back" / "upperBack" all collapse together.
    public static func fold(_ raw: String) -> String {
        raw.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
    }

    public static func muscle(_ raw: String) -> MuscleGroup? {
        let key = fold(raw)
        if let exact = MuscleGroup.allCases.first(where: { fold($0.rawValue) == key }) { return exact }
        if let byDisplay = MuscleGroup.allCases.first(where: { fold($0.displayName) == key }) { return byDisplay }
        return MuscleGroup.fromLegacyString(raw.lowercased())
    }

    public static func equipment(_ raw: String) -> Equipment? {
        let key = fold(raw)
        if let exact = Equipment.allCases.first(where: { fold($0.rawValue) == key }) { return exact }
        return Equipment.allCases.first(where: { fold($0.displayName) == key })
    }

    public static func movementPattern(_ raw: String) -> MovementPattern? {
        let key = fold(raw)
        return MovementPattern.allCases.first(where: { fold($0.rawValue) == key })
    }

    public static func inputKind(_ raw: String) -> ExerciseInputKind? {
        switch fold(raw) {
        case "strength": .strength
        case "treadmill": .treadmill
        case "none": ExerciseInputKind.none
        default: nil
        }
    }

    public static var muscleVocabulary: String {
        MuscleGroup.allCases.map(\.rawValue).joined(separator: ", ")
    }
    public static var equipmentVocabulary: String {
        Equipment.allCases.map(\.rawValue).joined(separator: ", ")
    }
    public static var movementVocabulary: String {
        MovementPattern.allCases.map(\.rawValue).joined(separator: ", ")
    }
    public static var sessionKindVocabulary: String {
        SessionKind.allCases.map(\.rawValue).joined(separator: ", ")
    }
}

// MARK: - Limits

/// The hard bounds a decoded plan must satisfy.
///
/// Enforced during decode where they bound memory (collection counts) and in ``CoachPlan/validate()``
/// where they bound sense (set counts, name lengths). `maxDays` is the spec's own 1-30 range (§3.5).
public nonisolated enum CoachPlanLimits {
    public static let maxDays = 30
    public static let maxSessionsPerDay = 4
    public static let maxExercisesPerSession = 20
    public static let maxNewExercises = 60
    /// Upper bound on edits to already-planned workouts in one paste. Generous enough to rework a
    /// full month (a 30-day plan with a workout most days), bounded so a runaway blob can't be held.
    public static let maxEdits = 60
    public static let maxSets = 20
    public static let maxRestSeconds = 900
    public static let maxNameCharacters = 80
    public static let maxTextCharacters = 500
    /// Upper bound on the pasted text itself, checked before any JSON parsing is attempted.
    public static let maxPastedBytes = 512 * 1024
}

// MARK: - Errors and issues

/// A structural failure that stops a plan being decoded at all.
///
/// Distinct from ``CoachPlanIssue``: these abort the decode (the blob is too big or too deep to
/// hold), whereas issues are collected and shown together on the review screen.
public nonisolated enum CoachPlanDecodeError: Error, Equatable, Sendable {
    case tooManyDays(Int)
    case tooManySessions(dayIndex: Int, count: Int)
    case tooManyExercises(sessionTitle: String, count: Int)
    case tooManyNewExercises(Int)
    case tooManyEdits(Int)
    /// A new-exercise definition listed more muscle tokens than the vocabulary has muscles.
    case tooManyMuscles(exerciseName: String, count: Int)

    /// Copy shown to the user; every case names the actual number so the message is checkable.
    public var message: String {
        switch self {
        case .tooManyDays(let n):
            "This plan has \(n) days. Fernlet accepts up to \(CoachPlanLimits.maxDays)."
        case .tooManySessions(let dayIndex, let count):
            "Day \(dayIndex) has \(count) sessions. Fernlet accepts up to \(CoachPlanLimits.maxSessionsPerDay) per day."
        case .tooManyExercises(let title, let count):
            "\"\(title)\" has \(count) exercises. Fernlet accepts up to \(CoachPlanLimits.maxExercisesPerSession) per session."
        case .tooManyNewExercises(let n):
            "This plan defines \(n) new exercises. Fernlet accepts up to \(CoachPlanLimits.maxNewExercises)."
        case .tooManyEdits(let n):
            "This plan changes \(n) workouts you'd already planned. Fernlet accepts up to \(CoachPlanLimits.maxEdits)."
        case .tooManyMuscles(let exerciseName, let count):
            "\"\(exerciseName)\" lists \(count) muscles. Fernlet knows \(MuscleGroup.allCases.count)."
        }
    }
}

/// One problem found while validating a decoded plan.
///
/// Collected rather than thrown so the review screen can list everything wrong with a pasted plan
/// at once — a paste-and-fix loop where each attempt reveals one more problem is a bad experience
/// and encourages people to stop reading the errors.
public nonisolated struct CoachPlanIssue: Error, Equatable, Sendable, Identifiable {
    /// What sort of problem an issue describes, which also decides whether it blocks the import
    /// (see ``CoachPlanIssue/isBlocking``).
    public enum Kind: Equatable, Sendable {
        /// The plan can't be imported at all until this is fixed.
        case blocking
        /// An exercise name is used but never defined and isn't in the catalog.
        case undefinedExercise
        /// An edit targets a planned workout that can't be changed — gone, already done, or in the past.
        case unresolvableEdit
        /// A ``CoachExerciseDefinition`` is unusable.
        case invalidExerciseDefinition
        /// A muscle / equipment / movement token didn't match Fernlet's vocabulary.
        case unknownToken
        /// A value was out of range and was clamped; the plan is still importable.
        case clamped
    }

    public var id = UUID()
    public var kind: Kind
    /// What the issue is about — an exercise or session name — for grouping in the UI.
    public var subject: String
    public var detail: String

    public init(id: UUID = UUID(), kind: Kind, subject: String, detail: String) {
        self.id = id
        self.kind = kind
        self.subject = subject
        self.detail = detail
    }

    /// Whether this issue stops the import. Clamps are advisory; everything else is fatal, because
    /// each remaining kind means Fernlet would have to guess at a training instruction.
    public var isBlocking: Bool { kind != .clamped }
}

// MARK: - Validation

extension CoachPlan {

    /// Checks everything decode deliberately didn't: version, day numbering, set/rest sanity, and —
    /// the load-bearing one — that every prescribed exercise either exists in `knownExerciseNames`
    /// or is defined in ``newExercises``.
    ///
    /// - Parameter knownExerciseNames: the names the user's catalog already has (base + custom),
    ///   which the caller supplies so this type stays free of any catalog or bundle dependency.
    /// - Returns: every issue found, blocking ones included. An empty result means the plan is
    ///   importable as-is; `.clamped` issues alone still mean importable, with the noted adjustments.
    public func validate(knownExerciseNames: Set<String>) -> [CoachPlanIssue] {
        let envelope = envelopeIssues()
        guard !envelope.stop else { return envelope.issues }

        // Definitions must resolve before the undefined-name check, so a name that IS defined but
        // whose definition is broken reports the real problem rather than "undefined exercise".
        let (definedNames, definitionIssues) = resolvedDefinitionNames()
        return envelope.issues
            + textLengthIssues()
            + dayIssues()
            + definitionIssues
            + editIssues()
            + undefinedNameIssues(known: knownExerciseNames, defined: definedNames)
    }

    /// Envelope checks: schema version, format tag, emptiness, day count. `stop` is `true` when the
    /// plan is unreadable enough that every later pass would be guesswork.
    private func envelopeIssues() -> (issues: [CoachPlanIssue], stop: Bool) {
        if schemaVersion > CoachPlan.currentSchemaVersion {
            // A newer schema means every other check is guesswork — stop here rather than
            // producing a misleading list of "problems" caused by fields this build can't read.
            return ([.init(kind: .blocking, subject: title,
                           detail: "This plan uses a newer format (version \(schemaVersion)). Update Fernlet to open it.")],
                    true)
        }
        if format != CoachPlan.formatTag {
            return ([.init(kind: .blocking, subject: title,
                           detail: "This doesn't look like a Fernlet workout plan.")], true)
        }
        // A plan may legitimately carry NO new days — "adjust what I already have" is a whole plan
        // on its own. Only a paste that proposes nothing at all is empty.
        if days.isEmpty && edits.isEmpty {
            return ([.init(kind: .blocking, subject: title,
                           detail: "This plan has no days and changes nothing.")], true)
        }
        if days.count > CoachPlanLimits.maxDays {
            return ([.init(kind: .blocking, subject: title,
                           detail: "This plan has \(days.count) days. Fernlet accepts up to \(CoachPlanLimits.maxDays).")],
                    false)
        }
        return ([], false)
    }

    /// Enforces ``CoachPlanLimits/maxNameCharacters`` and ``CoachPlanLimits/maxTextCharacters`` on
    /// every free-text field the plan carries (R5: the plan is untrusted pasted text, and these
    /// strings are projected into `PlannedWorkout` rows in the synced blob, so an unbounded `notes`
    /// would be persisted and synced forever).
    private func textLengthIssues() -> [CoachPlanIssue] {
        var issues: [CoachPlanIssue] = []
        issues += Self.nameIssues(title, subject: title, field: "plan title")
        issues += Self.nameIssues(coachDisplayName, subject: title, field: "coach name")
        issues += Self.textIssues(notes, subject: title, field: "plan notes")
        for day in days {
            let label = day.title.isEmpty ? "Day \(day.dayIndex)" : day.title
            issues += Self.nameIssues(day.title, subject: label, field: "day title")
            for session in day.sessions {
                issues += Self.sessionTextIssues(session, label: label)
            }
        }
        for edit in edits {
            let label = edit.title ?? "a planned workout"
            issues += Self.nameIssues(edit.title, subject: label, field: "workout title")
            issues += Self.textIssues(edit.notes, subject: label, field: "notes")
            issues += Self.textIssues(edit.conditioning, subject: label, field: "conditioning")
            for exercise in edit.exercises ?? [] {
                issues += Self.exerciseTextIssues(exercise)
            }
        }
        return issues
    }

    /// Free-text length checks for one session and its exercises.
    private static func sessionTextIssues(_ session: CoachSession, label: String) -> [CoachPlanIssue] {
        var issues = nameIssues(session.title, subject: label, field: "session title")
        issues += textIssues(session.notes, subject: label, field: "session notes")
        issues += textIssues(session.conditioning, subject: label, field: "conditioning")
        for exercise in session.exercises {
            issues += exerciseTextIssues(exercise)
        }
        return issues
    }

    /// Free-text length checks for one prescribed exercise.
    private static func exerciseTextIssues(_ exercise: CoachExercise) -> [CoachPlanIssue] {
        let subject = exercise.name.isEmpty ? "an exercise" : exercise.name
        var issues = nameIssues(exercise.name, subject: subject, field: "exercise name")
        issues += textIssues(exercise.reps, subject: subject, field: "reps")
        issues += textIssues(exercise.guidance, subject: subject, field: "guidance")
        return issues
    }

    /// A blocking issue when `value` exceeds ``CoachPlanLimits/maxNameCharacters``.
    private static func nameIssues(_ value: String?, subject: String, field: String) -> [CoachPlanIssue] {
        guard let value, value.count > CoachPlanLimits.maxNameCharacters else { return [] }
        return [.init(kind: .blocking, subject: subject,
                      detail: "That \(field) is \(value.count) characters. Fernlet accepts up to "
                      + "\(CoachPlanLimits.maxNameCharacters).")]
    }

    /// A blocking issue when `value` exceeds ``CoachPlanLimits/maxTextCharacters``.
    private static func textIssues(_ value: String?, subject: String, field: String) -> [CoachPlanIssue] {
        guard let value, value.count > CoachPlanLimits.maxTextCharacters else { return [] }
        return [.init(kind: .blocking, subject: subject,
                      detail: "That \(field) is \(value.count) characters. Fernlet accepts up to "
                      + "\(CoachPlanLimits.maxTextCharacters).")]
    }

    /// Day numbering, duplicate days, empty non-rest days, and the per-session checks.
    private func dayIssues() -> [CoachPlanIssue] {
        var issues: [CoachPlanIssue] = []
        var seenIndices = Set<Int>()
        for day in days {
            let label = day.title.isEmpty ? "Day \(day.dayIndex)" : day.title
            if day.dayIndex < 1 || day.dayIndex > CoachPlanLimits.maxDays {
                issues.append(.init(kind: .blocking, subject: label,
                                    detail: "Day numbers must run from 1 to \(CoachPlanLimits.maxDays); found \(day.dayIndex)."))
            } else if !seenIndices.insert(day.dayIndex).inserted {
                issues.append(.init(kind: .blocking, subject: "Day \(day.dayIndex)",
                                    detail: "Day \(day.dayIndex) appears more than once."))
            }
            if !day.isRestDay && day.sessions.isEmpty {
                issues.append(.init(kind: .clamped, subject: label,
                                    detail: "Day \(day.dayIndex) has no sessions and isn't marked a rest day; it will be treated as rest."))
            }
            for session in day.sessions {
                issues.append(contentsOf: Self.validate(session: session, dayIndex: day.dayIndex))
            }
        }
        return issues
    }

    /// Resolves every ``newExercises`` definition, returning the normalized names that resolved and
    /// an issue for each that did not.
    private func resolvedDefinitionNames() -> (names: Set<String>, issues: [CoachPlanIssue]) {
        var definedNames = Set<String>()
        var issues: [CoachPlanIssue] = []
        for definition in newExercises {
            switch definition.resolved() {
            case .success(let target):
                definedNames.insert(CoachPlan.normalizedName(target.name))
            case .failure(let issue):
                issues.append(issue)
            }
        }
        return (definedNames, issues)
    }

    /// Edit shape. Whether a target actually EXISTS is checked store-side (this type has no view of
    /// the user's calendar); what's checkable here is that the instruction is coherent.
    private func editIssues() -> [CoachPlanIssue] {
        var issues: [CoachPlanIssue] = []
        var seenTargets = Set<UUID>()
        for edit in edits {
            let label = edit.title ?? "a planned workout"
            guard let action = edit.resolvedAction else {
                issues.append(.init(kind: .unknownToken, subject: label,
                                    detail: "Unknown change type \"\(edit.action)\". Expected one of: "
                                    + CoachPlanEditAction.allCases.map(\.rawValue).joined(separator: ", ")))
                continue
            }
            if !seenTargets.insert(edit.targetID).inserted {
                issues.append(.init(kind: .blocking, subject: label,
                                    detail: "Two changes target the same planned workout; Fernlet can't apply both."))
            }
            issues.append(contentsOf: Self.editContentIssues(edit, action: action, label: label))
        }
        return issues
    }

    /// The per-edit content checks: a replacement must say what it becomes, a no-op change is
    /// skipped, and each replacement exercise needs a name and a sane set count.
    private static func editContentIssues(_ edit: CoachPlanEdit, action: CoachPlanEditAction,
                                          label: String) -> [CoachPlanIssue] {
        var issues: [CoachPlanIssue] = []
        if action == .replace, (edit.exercises ?? []).isEmpty, (edit.conditioning ?? "").isEmpty {
            issues.append(.init(kind: .blocking, subject: label,
                                detail: "A replacement has to say what the workout becomes, and this one lists no exercises."))
        }
        if action != .delete, edit.exercises == nil, edit.title == nil, edit.notes == nil,
           edit.kind == nil, edit.conditioning == nil {
            issues.append(.init(kind: .clamped, subject: label,
                                detail: "A change to \"\(label)\" alters nothing; it will be skipped."))
        }
        for exercise in edit.exercises ?? [] {
            if exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(kind: .blocking, subject: label,
                                    detail: "A change to \"\(label)\" has an exercise with no name."))
            }
            if exercise.sets < 1 || exercise.sets > CoachPlanLimits.maxSets {
                issues.append(.init(kind: .clamped, subject: exercise.name,
                                    detail: "\(exercise.name): \(exercise.sets) sets is outside 1-\(CoachPlanLimits.maxSets); it will be clamped."))
            }
        }
        return issues
    }

    /// Names the plan prescribes that neither the user's catalog nor the plan itself defines.
    private func undefinedNameIssues(known knownExerciseNames: Set<String>,
                                     defined definedNames: Set<String>) -> [CoachPlanIssue] {
        let known = Set(knownExerciseNames.map(CoachPlan.normalizedName))
        return prescribedExerciseNames.compactMap { name in
            let key = CoachPlan.normalizedName(name)
            guard !known.contains(key), !definedNames.contains(key) else { return nil }
            return .init(kind: .undefinedExercise, subject: name,
                         detail: "\"\(name)\" isn't in your exercise list and the plan doesn't define it. "
                         + "Ask for its muscles, equipment, and movement pattern, then paste again.")
        }
    }

    /// Per-session checks: a title, and set/rep/rest values that mean something.
    private static func validate(session: CoachSession, dayIndex: Int) -> [CoachPlanIssue] {
        var issues: [CoachPlanIssue] = []
        let label = session.title.isEmpty ? "Day \(dayIndex) session" : session.title

        if SessionKind(rawValue: session.kind) == nil {
            issues.append(.init(kind: .clamped, subject: label,
                                detail: "Unknown session kind \"\(session.kind)\"; treating it as strength."))
        }
        // A session with neither exercises nor a conditioning descriptor prescribes nothing at all.
        if session.exercises.isEmpty && (session.conditioning?.isEmpty ?? true) {
            issues.append(.init(kind: .blocking, subject: label,
                                detail: "\"\(label)\" has no exercises and no conditioning description."))
        }
        for exercise in session.exercises {
            let name = exercise.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                issues.append(.init(kind: .blocking, subject: label, detail: "\"\(label)\" has an exercise with no name."))
                continue
            }
            if exercise.sets < 1 || exercise.sets > CoachPlanLimits.maxSets {
                issues.append(.init(kind: .clamped, subject: name,
                                    detail: "\(name): \(exercise.sets) sets is outside 1-\(CoachPlanLimits.maxSets); it will be clamped."))
            }
            if exercise.reps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(kind: .blocking, subject: name, detail: "\(name) has no reps."))
            }
            if let rest = exercise.restSeconds, rest < 0 || rest > CoachPlanLimits.maxRestSeconds {
                issues.append(.init(kind: .clamped, subject: name,
                                    detail: "\(name): \(rest)s rest is outside 0-\(CoachPlanLimits.maxRestSeconds); it will be clamped."))
            }
        }
        return issues
    }
}
