//
//  CoachPlanImporter.swift
//  Fernlet
//
//  The receiving half of the manual coach exchange: pasted text → reviewed plan → dated
//  `PlannedWorkout` rows tagged `WorkoutPlanSource.coach`.
//
//  THE INPUT IS UNTRUSTED. On this path the "wire" is the system clipboard, so the bytes are
//  literally whatever the user pasted — a plan, a truncated plan, a chat transcript, or something
//  hostile. Every stage is therefore fail-closed and bounded: size is checked before parsing, the
//  JSON is extracted rather than assumed, decode is capped (`CoachPlanLimits`), semantics are
//  validated, and the safety pass runs BEFORE anything is materialized. Nothing is written to the
//  user's days until they accept on the review screen — spec §F3's review gate, which is exactly
//  the gate that stays in place when this becomes the signed coach-mesh transport.
//
//  THE SAFETY PASS IS NOT COSMETIC. `WorkoutSafetyFilter` is the same filter the app's own planning
//  engine runs, checked against the same `WorkoutProfile`. An outside plan gets no exemption from
//  it: conflicts are flagged inline and the user strikes or keeps each one deliberately. Nothing is
//  silently removed and nothing is silently kept (spec §F3 step 3).
//

import Foundation
import FernletDomainModel
import FernletFoundation

// MARK: - Review model

/// A pasted plan that has been decoded, validated, and safety-checked, but NOT yet applied.
///
/// This is what the review screen renders. Holding the unresolved issues and flags alongside the
/// plan — rather than filtering them out during parsing — is what lets the screen be honest about
/// everything the plan got wrong in one pass.
struct CoachPlanImportReview {
    var plan: CoachPlan
    /// Everything ``CoachPlan/validate(knownExerciseNames:)`` found. Blocking issues stop the import.
    var issues: [CoachPlanIssue]
    /// Exercises that conflict with the user's profile or equipment.
    var safetyFlags: [CoachPlanSafetyFlag]
    /// New exercises this plan would add to the user's catalog on accept.
    var newExercises: [ExerciseTarget]
    /// Day keys that already hold planned workouts and would be affected (spec D4).
    var collidingDayKeys: [String]
    /// Changes to workouts the user already planned, each resolved against the live row so the
    /// review screen can show a real before/after rather than the plan's claim about it.
    var resolvedEdits: [ResolvedCoachPlanEdit]

    /// Whether accept is available at all.
    var isImportable: Bool { !issues.contains(where: \.isBlocking) }

    /// The advisory (non-blocking) issues, shown as notes rather than errors.
    var advisories: [CoachPlanIssue] { issues.filter { !$0.isBlocking } }

    /// The blocking issues, shown as the reason accept is unavailable.
    var blockers: [CoachPlanIssue] { issues.filter(\.isBlocking) }
}

/// A ``CoachPlanEdit`` matched to the live planned workout it targets.
///
/// Holds `before` (what is on the calendar now) alongside `after` (what the edit would make it), so
/// the review screen renders a diff from the real row rather than from the plan's description of
/// it — a plan claiming to adjust "Upper" can't show the user a "before" of its own invention.
struct ResolvedCoachPlanEdit: Identifiable {
    var id: UUID { edit.targetID }
    var edit: CoachPlanEdit
    var action: CoachPlanEditAction
    var dayKey: String
    /// The row as it stands today.
    var before: PlannedWorkout
    /// The row after the edit — nil for a delete, which removes it.
    var after: PlannedWorkout?

    /// Whether this edit changes anything at all. An adjust that names no differing field is
    /// reported and skipped rather than counted as a change that didn't happen.
    var isMeaningful: Bool {
        switch action {
        case .delete:
            return true
        case .adjust, .replace:
            guard let after else { return false }
            return after.name != before.name
                || after.exercises != before.exercises
                || after.notes != before.notes
                || after.split != before.split
        }
    }
}

/// One prescribed exercise that conflicts with the user's own limits.
///
/// Carries the normalized exercise key so the review screen's strike list survives the user
/// striking the same exercise on a different day — striking "Back squat" strikes it everywhere,
/// which is what someone avoiding knee-dominant work means by it.
struct CoachPlanSafetyFlag: Identifiable, Equatable {
    var id = UUID()
    var exerciseKey: String
    var exerciseName: String
    var dayIndex: Int
    var sessionTitle: String
    /// Plain-language reason, e.g. "you avoid squat movements" — rendered after the exercise name.
    var reason: String
}

/// What actually happened when a reviewed plan was applied.
struct CoachPlanImportResult {
    var plannedWorkoutCount: Int
    var dayCount: Int
    var newExerciseCount: Int
    var struckExerciseCount: Int
    /// Existing planned workouts rewritten in place.
    var editedCount: Int
    /// Existing planned workouts removed.
    var deletedCount: Int
    var firstDayKey: String
    var lastDayKey: String

    /// Whether anything at all happened — an edits-only import writes no new rows, so a bare
    /// `plannedWorkoutCount` check would read it as a no-op.
    var changedAnything: Bool {
        plannedWorkoutCount > 0 || editedCount > 0 || deletedCount > 0
    }
}

/// How to handle days that already have planned workouts (spec D4).
enum CoachPlanCollisionPolicy: Equatable {
    /// Preserve a colliding day's planned workouts and skip the incoming sessions for that day.
    case keepExisting
    /// Replace collisions on the current or a future day, preserving collisions in the past.
    case replaceFutureConflicts
    /// Remove the existing planned workouts on colliding days, then write the plan's.
    case replace
    /// Keep what's there and add the plan's alongside it.
    case keepBoth
}

/// Why a paste couldn't become a plan at all.
enum CoachPlanImportFailure: Error, Equatable {
    case empty
    case tooLarge(bytes: Int)
    case noJSONFound
    case bounded(CoachPlanDecodeError)
    /// The plan's JSON didn't decode; the payload is what went wrong as one whole, already-localized
    /// clause ("\"days\" is missing from the plan."), which the paste sheet shows as its secondary
    /// line and ``message`` puts after "That plan couldn't be read:".
    case malformed(String)

    /// User-facing copy. Every case says what to do next, because "invalid" alone leaves someone
    /// re-pasting the same text.
    var message: String {
        switch self {
        case .empty:
            String(localized: "coachPlan.paste.error.empty",
                   defaultValue: "There's nothing to import. Copy the plan your assistant replied with, then paste it here.",
                   comment: "Coach plan paste sheet: the person tapped import with nothing pasted")
        case .tooLarge(let bytes):
            String(localized: "coachPlan.paste.error.tooLarge",
                   defaultValue: "That's \(bytes / 1024) KB of text — larger than a workout plan should be. Paste just the JSON block from the reply.",
                   comment: "Coach plan paste sheet: the pasted text is too big. Argument: its size in kilobytes, always over 500.")
        case .noJSONFound:
            String(localized: "coachPlan.paste.error.noJSON",
                   defaultValue: "Fernlet couldn't find a plan in what you pasted. Copy the whole JSON block from the reply, including its braces.",
                   comment: "Coach plan paste sheet: the pasted text holds no JSON plan. 'JSON block' is the code block an AI assistant replies with.")
        case .bounded(let error):
            error.message
        case .malformed(let detail):
            String(localized: "coachPlan.paste.error.unreadable", defaultValue: "That plan couldn't be read: \(detail)",
                   comment: "Coach plan paste sheet: the plan failed to decode. Argument: what went wrong, a whole clause, e.g. '\"days\" is missing from the plan.'")
        }
    }
}

// MARK: - Importer

/// Decodes, validates, and materializes a pasted ``CoachPlan``.
///
/// Split into a pure decode/review half (testable with no store) and a store-side apply half. The
/// review half never mutates anything, which is what makes "review, then accept" a real gate rather
/// than a confirmation dialog over work already done.
enum CoachPlanImporter {

    // MARK: Extracting JSON from a paste

    /// Pulls the JSON object out of pasted text that may also contain prose or markdown fences.
    ///
    /// Assistants wrap replies in ```json fences and sometimes add a sentence either side, and users
    /// select loosely. This recovers the object from all of those without asking anyone to trim by
    /// hand: it collects every balanced top-level `{…}` in the text (tracking string literals and
    /// escapes, so a brace inside `"guidance"` doesn't end a scan) and picks the one that actually
    /// looks like a plan.
    ///
    /// Picking matters because the FIRST brace isn't reliably the plan — a reply like
    /// `Here's your block (I used {sets}x{reps} notation): {…}` would otherwise yield `{sets}`.
    static func extractJSON(from raw: String) -> String? {
        // R5: this is a boundary function over untrusted text and is callable independently of
        // `decode(pastedText:)`, so it carries the size bound itself rather than trusting a caller.
        guard raw.utf8.count <= CoachPlanLimits.maxPastedBytes else { return nil }
        let candidates = balancedObjects(in: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !candidates.isEmpty else { return nil }
        // Strongest signal first: the format tag, then the required `days` key, then whatever came
        // first. Deterministic at every step — never "the longest", which would pick a chat
        // transcript that happens to quote a bigger object.
        return candidates.first { $0.contains(CoachPlan.formatTag) }
            ?? candidates.first { $0.contains("\"days\"") }
            ?? candidates.first
    }

    /// Every balanced top-level `{…}` span in `text`, in order, bounded so a pathological paste
    /// can't make this scan forever.
    private static func balancedObjects(in text: String, limit: Int = 8) -> [String] {
        var found: [String] = []
        var index = text.startIndex

        while index < text.endIndex, found.count < limit {
            guard let start = text[index...].firstIndex(of: "{") else { break }
            var depth = 0
            var inString = false
            var escaped = false
            var cursor = start
            var closed: String.Index?

            while cursor < text.endIndex {
                let character = text[cursor]
                if escaped {
                    escaped = false
                } else if character == "\\" && inString {
                    escaped = true
                } else if character == "\"" {
                    inString.toggle()
                } else if !inString {
                    if character == "{" {
                        depth += 1
                    } else if character == "}" {
                        depth -= 1
                        if depth == 0 { closed = cursor; break }
                    }
                }
                cursor = text.index(after: cursor)
            }

            guard let closed else { break }   // unbalanced from here on — a truncated paste
            found.append(String(text[start...closed]))
            index = text.index(after: closed)
        }
        return found
    }

    // MARK: Decode

    /// Turns pasted text into a ``CoachPlan``, or says precisely why it couldn't.
    static func decode(pastedText: String) -> Result<CoachPlan, CoachPlanImportFailure> {
        let trimmed = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        // Bound BEFORE parsing: the size check is worthless after the parser has already built an
        // object graph from the blob.
        let byteCount = trimmed.utf8.count
        guard byteCount <= CoachPlanLimits.maxPastedBytes else { return .failure(.tooLarge(bytes: byteCount)) }

        guard let json = extractJSON(from: trimmed), let data = json.data(using: .utf8) else {
            return .failure(.noJSONFound)
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return .success(try decoder.decode(CoachPlan.self, from: data))
        } catch let error as CoachPlanDecodeError {
            return .failure(.bounded(error))
        } catch let error as DecodingError {
            return .failure(.malformed(Self.describe(error)))
        } catch {
            return .failure(.malformed(error.localizedDescription))
        }
    }

    /// Turns a `DecodingError` into something a person can act on — which key, and what was wrong
    /// with it. The default `localizedDescription` names neither.
    ///
    /// Returns one whole clause per shape, the paste sheet's secondary line: "the plan" (no key path)
    /// is its own clause rather than a fragment spliced into the others. A key path is the plan's JSON
    /// keys joined with " → ", which are wire tokens and stay as written.
    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String? {
            let keys = context.codingPath.map(\.stringValue).filter { !$0.isEmpty }
            return keys.isEmpty ? nil : keys.joined(separator: " → ")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return missingKey(key.stringValue, from: path(context))
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return wrongKind(at: path(context))
        case .dataCorrupted(let context):
            guard !context.codingPath.isEmpty else {
                return String(localized: "coachPlan.paste.detail.notJSON", defaultValue: "it isn't valid JSON.",
                              comment: "Coach plan paste sheet, what went wrong (shown alone, and after 'That plan couldn't be read:'): the pasted plan is not valid JSON")
            }
            return unreadable(at: path(context))
        @unknown default:
            return String(localized: "coachPlan.paste.detail.unknown", defaultValue: "it couldn't be read.",
                          comment: "Coach plan paste sheet, what went wrong (shown alone, and after 'That plan couldn't be read:'), for a reason Fernlet can't name")
        }
    }

    /// "\"title\" is missing from days → 2." — `path` nil means the plan itself.
    private static func missingKey(_ key: String, from path: String?) -> String {
        guard let path else {
            return String(localized: "coachPlan.paste.detail.missingKeyInPlan", defaultValue: "\"\(key)\" is missing from the plan.",
                          comment: "Coach plan paste sheet, what went wrong. Argument: the JSON key that is missing (not translated).")
        }
        return String(localized: "coachPlan.paste.detail.missingKey", defaultValue: "\"\(key)\" is missing from \(path).",
                      comment: "Coach plan paste sheet, what went wrong. Arguments: the JSON key that is missing, then where it should be, as JSON keys joined by arrows, e.g. 'days → 2' (neither is translated).")
    }

    /// "days → 2 has the wrong kind of value."
    private static func wrongKind(at path: String?) -> String {
        guard let path else {
            return String(localized: "coachPlan.paste.detail.wrongKindInPlan", defaultValue: "the plan has the wrong kind of value.",
                          comment: "Coach plan paste sheet, what went wrong (shown alone, and after 'That plan couldn't be read:'): a value has the wrong type")
        }
        return String(localized: "coachPlan.paste.detail.wrongKind", defaultValue: "\(path) has the wrong kind of value.",
                      comment: "Coach plan paste sheet, what went wrong. Argument: where the bad value is, as JSON keys joined by arrows, e.g. 'days → 2 → sets' (not translated).")
    }

    /// "days → 2 couldn't be read."
    private static func unreadable(at path: String?) -> String {
        guard let path else {
            return String(localized: "coachPlan.paste.detail.unreadablePlan", defaultValue: "the plan couldn't be read.",
                          comment: "Coach plan paste sheet, what went wrong (shown alone, and after 'That plan couldn't be read:'): part of the plan could not be read")
        }
        return String(localized: "coachPlan.paste.detail.unreadableAt", defaultValue: "\(path) couldn't be read.",
                      comment: "Coach plan paste sheet, what went wrong. Argument: where the unreadable value is, as JSON keys joined by arrows (not translated).")
    }
}

// MARK: - Review (store-side, read-only)

extension FernletStore {

    /// Validates and safety-checks a decoded plan against this user's catalog, profile, and calendar
    /// WITHOUT writing anything.
    ///
    /// - Parameters:
    ///   - plan: the decoded plan.
    ///   - startDayKey: the day plan-day 1 would land on, needed for the collision check.
    func reviewCoachPlan(_ plan: CoachPlan, startingOn startDayKey: String) -> CoachPlanImportReview {
        let catalog = WorkoutExerciseCatalog.allExercises
        let knownNames = Set(catalog.map(\.name))
        var issues = plan.validate(knownExerciseNames: knownNames)

        // Resolve the definitions once; both the safety pass and the accept path need them, and
        // resolving twice risks the two disagreeing about what an exercise is.
        var resolvedByKey: [String: ExerciseTarget] = [:]
        for target in catalog {
            resolvedByKey[CoachPlan.normalizedName(target.name)] = target
        }
        var newExercises: [ExerciseTarget] = []
        for definition in plan.newExercises {
            guard case .success(let target) = definition.resolved() else { continue }
            let key = CoachPlan.normalizedName(target.name)
            // A definition for something already in the catalog is ignored (the prompt asks for one
            // per exercise precisely because redundant definitions are cheap) — the curated entry
            // wins so a pasted plan can't redefine what a known lift targets.
            guard resolvedByKey[key] == nil else { continue }
            resolvedByKey[key] = target
            newExercises.append(target)
        }

        // R3: the custom-exercise catalog is capped, so a plan that would overflow it fails closed
        // here — blocking at review beats silently dropping definitions the plan then prescribes.
        let headroom = max(0, WorkoutExerciseCatalog.maxCustomExercises - settings.customExercises.count)
        if newExercises.count > headroom {
            issues.append(.init(kind: .blocking, subject: "New exercises",
                                detail: Self.customExerciseHeadroomDetail(adding: newExercises.count, headroom: headroom)))
        }

        let (resolvedEdits, editIssues) = resolveEdits(plan.edits)
        issues.append(contentsOf: editIssues)

        var flags = Self.safetyFlags(for: plan, resolvedByKey: resolvedByKey,
                                     location: settings.activeWorkoutLocation,
                                     profile: settings.workoutProfile)
        // An edit's exercises get the SAME safety pass as a new day's. A coach swapping a bodyweight
        // row for a barbell one you can't do — or that hits a muscle you avoid — must be flagged
        // whether it arrives as a new workout or as a change to an old one.
        flags.append(contentsOf: Self.safetyFlags(forEdits: resolvedEdits, resolvedByKey: resolvedByKey,
                                                  location: settings.activeWorkoutLocation,
                                                  profile: settings.workoutProfile))

        let collisions = collidingDayKeys(for: plan, startingOn: startDayKey)

        return CoachPlanImportReview(plan: plan, issues: issues, safetyFlags: flags,
                                     newExercises: newExercises, collidingDayKeys: collisions,
                                     resolvedEdits: resolvedEdits)
    }

    /// Matches each ``CoachPlanEdit`` to the live planned workout it targets, reporting every one
    /// that can't be applied.
    ///
    /// Refuses three things, all deliberately blocking rather than silently skipped: a target that
    /// no longer exists (the user deleted or completed it since exporting), a target on a past day
    /// (rewriting yesterday's plan changes nothing and reads as if it did), and — implicitly, by
    /// only ever searching `plannedWorkouts` — anything already LOGGED. An import can propose what
    /// you will do; it can never edit what you did.
    func resolveEdits(_ edits: [CoachPlanEdit]) -> ([ResolvedCoachPlanEdit], [CoachPlanIssue]) {
        guard !edits.isEmpty else { return ([], []) }

        var locations: [UUID: (dayKey: String, workout: PlannedWorkout)] = [:]
        for (dayKey, day) in loadDays() {
            for planned in day.plannedWorkouts { locations[planned.id] = (dayKey, planned) }
        }

        var resolved: [ResolvedCoachPlanEdit] = []
        var issues: [CoachPlanIssue] = []
        let today = todayKey

        for edit in edits {
            guard let action = edit.resolvedAction else { continue }   // already reported by validate()
            let label = edit.title ?? "a planned workout"

            guard let found = locations[edit.targetID] else {
                issues.append(.init(kind: .unresolvableEdit, subject: label,
                                    detail: String(localized: "coachPlan.review.edit.targetGone",
                                                   defaultValue: "A change points at a planned workout that isn't there any more — it may have been done, edited, or deleted since you copied your summary. Copy a fresh summary and ask again.",
                                                   comment: "Coach plan review, a change Fernlet can't apply: the planned workout it targets no longer exists")))
                continue
            }
            guard found.dayKey >= today else {
                issues.append(.init(kind: .unresolvableEdit, subject: found.workout.name,
                                    detail: String(localized: "coachPlan.review.edit.targetPast",
                                                   defaultValue: "\"\(found.workout.displayedName)\" was planned for \(found.dayKey), which has already passed. Fernlet only changes workouts still ahead of you.",
                                                   comment: "Coach plan review, a change Fernlet can't apply. Arguments: the planned workout's name, then its date as year-month-day.")))
                continue
            }

            let after: PlannedWorkout? = action == .delete
                ? nil
                : Self.applying(edit, to: found.workout)
            let resolvedEdit = ResolvedCoachPlanEdit(edit: edit, action: action, dayKey: found.dayKey,
                                                     before: found.workout, after: after)
            if resolvedEdit.isMeaningful {
                resolved.append(resolvedEdit)
            } else {
                issues.append(.init(kind: .clamped, subject: found.workout.name,
                                    detail: String(localized: "coachPlan.review.edit.noChange",
                                                   defaultValue: "\"\(found.workout.displayedName)\" is already exactly what the change asks for; nothing to do.",
                                                   comment: "Coach plan review, a change that would alter nothing. Argument: the planned workout's name.")))
            }
        }
        return (resolved.sorted { $0.dayKey < $1.dayKey }, issues)
    }

    /// The blocker for a plan whose new exercises overflow the custom-exercise list. The exercise
    /// count is a plural-ruled count phrase (``exerciseCount(_:)``), so "1 exercises" can't be
    /// spliced; `headroom` is a bare number after "only", which needs no plural form.
    static func customExerciseHeadroomDetail(adding count: Int, headroom: Int) -> String {
        String(localized: "coachPlan.review.customExercisesFull",
               defaultValue: "This plan adds \(Self.exerciseCount(count)) but your list can hold only \(headroom) more. Remove some custom exercises, then import again.",
               comment: "Coach plan review blocker. Arguments: a count of exercises ('5 exercises'), then how many more the person's custom exercise list can hold (0 or more).")
    }

    /// "5 exercises" — a plural-ruled count phrase placed inside coach-plan sentences.
    static func exerciseCount(_ count: Int) -> String {
        String(localized: "coachPlan.count.exercises", defaultValue: "\(count) exercises",
               comment: "A number of exercises, e.g. '5 exercises', placed inside other coach plan sentences. Needs a plural variation.")
    }

    /// The clamped prescription line one coach-proposed exercise becomes. The single renderer
    /// shared by `applying(_:to:)` and `CoachPlanStrikeFilter`, so the text written to the calendar
    /// and the text the safety strikes are applied to can never disagree.
    ///
    /// `fileprivate`, not `private`: `CoachPlanStrikeFilter` is a file-scope struct and cannot
    /// reach a `private` member of this extension.
    fileprivate static func clampedLine(_ exercise: CoachExercise) -> String {
        var clamped = exercise
        clamped.sets = min(max(exercise.sets, 1), CoachPlanLimits.maxSets)
        if let rest = exercise.restSeconds {
            clamped.restSeconds = min(max(rest, 0), CoachPlanLimits.maxRestSeconds)
        }
        return clamped.line
    }

    /// Produces the edited row: every field the edit doesn't mention keeps its current value.
    ///
    /// Set counts and rest are clamped here, matching the new-day path, so a `.clamped` advisory the
    /// review screen showed is actually honoured.
    private static func applying(_ edit: CoachPlanEdit, to planned: PlannedWorkout) -> PlannedWorkout {
        var updated = planned
        if let title = edit.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            updated.name = title
        }
        if let exercises = edit.exercises, !exercises.isEmpty {
            updated.exercises = exercises.map(Self.clampedLine).joined(separator: "\n")
            // Muscle groups are derived from the new prescription, not carried over: keeping the old
            // set would leave the safety filter and scoring reasoning about exercises that are gone.
            var muscles = Set<MuscleGroup>()
            for exercise in exercises {
                guard let target = WorkoutExerciseCatalog.exercise(named: exercise.name) else { continue }
                muscles.formUnion(target.primaryMuscles)
            }
            updated.muscleGroups = muscles
        } else if let conditioning = edit.conditioning, !conditioning.isEmpty {
            updated.exercises = conditioning
        }
        if let notes = edit.notes { updated.notes = notes }
        if let kind = edit.kind, let session = SessionKind(rawValue: kind) {
            updated.mode = session == .cardio ? .activity : .strengthTraining
        }
        return updated
    }

    /// Why the profile's injury limits rule `target` out, one reason per conflict: an avoided
    /// movement, avoided muscles, a body area kept out of training (severe), or the heavy end of an
    /// area being trained around (mild). The same limits ``WorkoutSafetyFilter`` applies to the
    /// app's own plans — the picker, the note read by whole words, and the older avoided sets.
    ///
    /// Each reason is one whole localized clause (2026-10-20): the avoided movement is a clause per
    /// pattern rather than its `rawValue` token spliced into English, and the name lists are drawn
    /// names joined with ", " (the house list separator, right in en/es/fr/de).
    static func injuryReasons(for target: ExerciseTarget, limits: InjuryLimits) -> [String] {
        var reasons: [String] = []
        if limits.avoidedMovements.contains(target.movementPattern) {
            reasons.append(Self.avoidedMovementReason(target.movementPattern))
        }
        let conflicting = target.primaryMuscles.union(target.secondaryMuscles).intersection(limits.avoidedMuscles)
        if !conflicting.isEmpty {
            let muscles = conflicting.map(\.displayName).sorted().joined(separator: ", ")
            reasons.append(String(localized: "coachPlan.safety.avoidedMuscles", defaultValue: "it works \(muscles), which you avoid",
                                  comment: "Coach plan review, why an exercise is flagged, shown under its name. Argument: the muscles it works that the person avoids, e.g. 'Chest, Triceps'."))
        }
        let severe = limits.severeAreas.filter { $0.isLoaded(by: target, primaryOnly: false) }
        if !severe.isEmpty {
            let areas = severe.map(\.displayName).sorted().joined(separator: ", ")
            reasons.append(String(localized: "coachPlan.safety.restingArea", defaultValue: "it loads your \(areas), which you're resting",
                                  comment: "Coach plan review, why an exercise is flagged. Argument: the body areas the person is keeping out of training, e.g. 'Knee'."))
        }
        let mild = limits.mildAreas.filter { $0.isLoaded(by: target, primaryOnly: true) }
        if InjuryLimits.isHeavyLoading(target), !mild.isEmpty {
            let areas = mild.map(\.displayName).sorted().joined(separator: ", ")
            reasons.append(String(localized: "coachPlan.safety.easingArea", defaultValue: "it loads your \(areas) heavily, which you're easing",
                                  comment: "Coach plan review, why a heavy exercise is flagged. Argument: the body areas the person is training around, e.g. 'Lower back'."))
        }
        return reasons
    }

    /// "you avoid squat movements": one whole clause per movement pattern, so no `rawValue` token is
    /// shown and a translator never inflects an English word.
    static func avoidedMovementReason(_ pattern: MovementPattern) -> String {
        switch pattern {
        case .push: String(localized: "coachPlan.safety.avoidedMovement.push", defaultValue: "you avoid push movements", comment: "Coach plan review, why an exercise is flagged: the person avoids pushing movements")
        case .pull: String(localized: "coachPlan.safety.avoidedMovement.pull", defaultValue: "you avoid pull movements", comment: "Coach plan review, why an exercise is flagged: the person avoids pulling movements")
        case .hinge: String(localized: "coachPlan.safety.avoidedMovement.hinge", defaultValue: "you avoid hinge movements", comment: "Coach plan review, why an exercise is flagged: the person avoids hip-hinge movements (deadlifts, swings)")
        case .squat: String(localized: "coachPlan.safety.avoidedMovement.squat", defaultValue: "you avoid squat movements", comment: "Coach plan review, why an exercise is flagged: the person avoids squatting movements")
        case .lunge: String(localized: "coachPlan.safety.avoidedMovement.lunge", defaultValue: "you avoid lunge movements", comment: "Coach plan review, why an exercise is flagged: the person avoids lunges")
        case .carry: String(localized: "coachPlan.safety.avoidedMovement.carry", defaultValue: "you avoid carry movements", comment: "Coach plan review, why an exercise is flagged: the person avoids loaded carries")
        case .twist: String(localized: "coachPlan.safety.avoidedMovement.twist", defaultValue: "you avoid twist movements", comment: "Coach plan review, why an exercise is flagged: the person avoids twisting movements")
        case .isolation: String(localized: "coachPlan.safety.avoidedMovement.isolation", defaultValue: "you avoid isolation movements", comment: "Coach plan review, why an exercise is flagged: the person avoids single-joint isolation movements")
        case .locomotion: String(localized: "coachPlan.safety.avoidedMovement.locomotion", defaultValue: "you avoid locomotion movements", comment: "Coach plan review, why an exercise is flagged: the person avoids locomotion (running, jumping, crawling)")
        }
    }

    /// "Home has no Barbell or Dumbbell": the location's drawn name and the missing equipment's drawn
    /// names as a localized "or" list. The names are NOT lowercased (they were, in English only):
    /// lowercasing a localized word breaks German nouns, so English now keeps the names' own case.
    static func missingEquipmentReason(_ missing: [String], at location: WorkoutLocation) -> String {
        let list = missing.formatted(.list(type: .or))
        return String(localized: "coachPlan.safety.missingEquipment", defaultValue: "\(location.displayedName) has no \(list)",
                      comment: "Coach plan review, why an exercise is flagged. Arguments: where the person trains (e.g. 'Home'), then the equipment it lacks, e.g. 'Barbell or Weight bench'.")
    }

    /// The safety pass over an edit's proposed exercises.
    private static func safetyFlags(forEdits edits: [ResolvedCoachPlanEdit],
                                    resolvedByKey: [String: ExerciseTarget],
                                    location: WorkoutLocation,
                                    profile: WorkoutProfile) -> [CoachPlanSafetyFlag] {
        var flags: [CoachPlanSafetyFlag] = []
        let limits = profile.injuryLimits
        for resolved in edits {
            for exercise in resolved.edit.exercises ?? [] {
                let key = CoachPlan.normalizedName(exercise.name)
                guard let target = resolvedByKey[key] else { continue }
                var reasons = injuryReasons(for: target, limits: limits)
                let missing = WorkoutSafetyFilter.missingEquipment(for: target, at: location)
                if !missing.isEmpty {
                    reasons.append(Self.missingEquipmentReason(missing, at: location))
                }
                guard !reasons.isEmpty else { continue }
                flags.append(CoachPlanSafetyFlag(
                    exerciseKey: key, exerciseName: exercise.name, dayIndex: 0,
                    sessionTitle: resolved.before.name, reason: reasons.joined(separator: "; ")))
            }
        }
        return flags
    }

    /// Flags every prescribed exercise that the user's own profile or equipment rules out.
    ///
    /// Deliberately reports a distinct reason per conflict rather than a generic "not feasible":
    /// "you avoid squat movements" and "your gym has no barbell" call for different decisions from
    /// the user, and `WorkoutSafetyFilter.feasible` collapses both to `false`.
    private static func safetyFlags(for plan: CoachPlan,
                                    resolvedByKey: [String: ExerciseTarget],
                                    location: WorkoutLocation,
                                    profile: WorkoutProfile) -> [CoachPlanSafetyFlag] {
        var flags: [CoachPlanSafetyFlag] = []
        let limits = profile.injuryLimits
        for day in plan.days {
            for session in day.sessions {
                for exercise in session.exercises {
                    let key = CoachPlan.normalizedName(exercise.name)
                    // An unresolved name is already reported as a blocking `undefinedExercise`
                    // issue; flagging it again here would double-report the same problem.
                    guard let target = resolvedByKey[key] else { continue }

                    var reasons = injuryReasons(for: target, limits: limits)
                    let missing = WorkoutSafetyFilter.missingEquipment(for: target, at: location)
                    if !missing.isEmpty {
                        reasons.append(Self.missingEquipmentReason(missing, at: location))
                    }
                    guard !reasons.isEmpty else { continue }

                    flags.append(CoachPlanSafetyFlag(
                        exerciseKey: key,
                        exerciseName: exercise.name,
                        dayIndex: day.dayIndex,
                        sessionTitle: session.title.isEmpty ? day.title : session.title,
                        reason: reasons.joined(separator: "; ")))
                }
            }
        }
        return flags
    }

    /// The day keys this plan would land on that already hold planned workouts.
    func collidingDayKeys(for plan: CoachPlan, startingOn startDayKey: String) -> [String] {
        let existing = loadDays()
        return plan.days
            .filter { !$0.isRestDay && !$0.sessions.isEmpty }
            .compactMap { Self.dayKey(startingOn: startDayKey, offsetBy: $0.dayIndex - 1) }
            .filter { key in (existing[key]?.plannedWorkouts.isEmpty == false) }
            .sorted()
    }

    /// `startDayKey` advanced by `offset` calendar days.
    static func dayKey(startingOn startDayKey: String, offsetBy offset: Int) -> String? {
        guard let start = FernletDate.date(fromDayKey: startDayKey),
              let date = Calendar.current.date(byAdding: .day, value: offset, to: start) else { return nil }
        return FernletDate.dayKey(for: date)
    }
}

// MARK: - Apply (store-side, writes)

/// The user's safety strikes from the review screen, applied to a plan's sessions and edits.
///
/// One place decides what a strike removes, so the "does this import write anything?" question and
/// the write itself can never disagree — the disagreement that let a fully-struck plan delete rows
/// and then report "nothing was changed".
private struct CoachPlanStrikeFilter {
    /// Normalized exercise keys the user turned off.
    let struckKeys: Set<String>

    /// The exercises of `exercises` that survive the strikes — the one place a strike key is
    /// compared against an exercise name, always in `CoachPlan.normalizedName` form.
    func kept(_ exercises: [CoachExercise]) -> [CoachExercise] {
        exercises.filter { !struckKeys.contains(CoachPlan.normalizedName($0.name)) }
    }

    /// The exercises of `session` that survive the strikes.
    func kept(_ session: CoachSession) -> [CoachExercise] {
        kept(session.exercises)
    }

    /// Whether a session still prescribes anything at all once strikes are applied.
    func prescribesSomething(_ session: CoachSession) -> Bool {
        !kept(session).isEmpty || !(session.conditioning?.isEmpty ?? true)
    }

    /// The edit's replacement exercise text with struck lines removed — nil when nothing survives,
    /// which means the original row must be left standing rather than replaced with an empty one.
    func survivingExercises(of resolved: ResolvedCoachPlanEdit) -> String? {
        guard let after = resolved.after else { return nil }
        var text = after.exercises
        // Filter the edit's own [CoachExercise] by normalized name and RE-RENDER through the same
        // clamped renderer `applying(_:to:)` used. String-prefixing the rendered line compared a
        // raw author name against a normalized strike key, so "Back  squat" outran its own strike.
        // Only when the edit actually proposes a prescription: a title/notes-only edit leaves the
        // user's existing lines standing, and those were never flagged, so they are not strikable.
        if !struckKeys.isEmpty, let proposed = resolved.edit.exercises, !proposed.isEmpty {
            text = kept(proposed).map(FernletStore.clampedLine).joined(separator: "\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// Whether this edit still does something once strikes are applied.
    func survives(_ resolved: ResolvedCoachPlanEdit) -> Bool {
        resolved.action == .delete || survivingExercises(of: resolved) != nil
    }
}

extension FernletStore {

    /// Materializes a reviewed plan into dated ``PlannedWorkout`` rows and registers its new
    /// exercises.
    ///
    /// - Parameters:
    ///   - review: the reviewed plan. Must be `isImportable`; a blocking issue means the caller
    ///     hasn't gated accept properly, so this refuses rather than importing a plan the user was
    ///     told was broken.
    ///   - startDayKey: the day plan-day 1 lands on.
    ///   - struckExerciseKeys: normalized keys the user chose to strike from the safety flags.
    ///   - collisionPolicy: what to do about days that already hold planned workouts.
    func applyCoachPlan(_ review: CoachPlanImportReview,
                        startingOn startDayKey: String,
                        struckExerciseKeys: Set<String>,
                        collisionPolicy: CoachPlanCollisionPolicy) -> CoachPlanImportResult? {
        // R5: validate BOTH parameters at entry. A `startDayKey` that isn't a day key makes every
        // plan day skip, so without this the catalog and the edits would be written for an import
        // that then reports "nothing was changed".
        guard review.isImportable, FernletDate.date(fromDayKey: startDayKey) != nil else { return nil }
        let plan = review.plan
        let filter = CoachPlanStrikeFilter(struckKeys: struckExerciseKeys)

        // Decide up front whether this import does ANYTHING, before touching a single row. If the
        // user struck every exercise, the loops below would delete their existing planned workouts
        // (under `.replace`), write nothing in their place, and then return nil — so the UI would say
        // "nothing was changed" over real data loss. Bail before any mutation instead.
        let writesSomething = planWritesAnything(plan, startingOn: startDayKey, filter: filter,
                                                  collisionPolicy: collisionPolicy)
        // An edits-only plan writes no new days and is still a real import — but only edits that
        // survive the strikes count, or a fully-struck edit set would mutate the catalog first.
        let survivingEdits = review.resolvedEdits.filter(filter.survives)
        guard writesSomething || !survivingEdits.isEmpty else { return nil }

        // Counted across the whole plan rather than accumulated while writing, so the confirmation is
        // accurate even for strikes on days that ended up writing nothing.
        let struckCount = plan.days.reduce(0) { total, day in
            total + day.sessions.reduce(0) { $0 + ($1.exercises.count - filter.kept($1).count) }
        }

        // Register new exercises FIRST: the rows written below carry muscle groups resolved from the
        // catalog, so a plan's own exercises have to be in it before its sessions are projected.
        registerNewExercises(review.newExercises)

        // Edits FIRST, against the calendar as the review screen showed it. Running them after the
        // new days would let a `.replace` collision delete a row an edit was about to rewrite, so
        // the user would see "3 adjusted" for rows that no longer existed when the edit ran.
        let edits = applyResolvedEdits(survivingEdits, filter: filter, plan: plan)
        let days = applyPlanDays(plan, startingOn: startDayKey, filter: filter,
                                 collisionPolicy: collisionPolicy)
        let writtenDayKeys = edits.dayKeys + days.dayKeys

        guard let first = writtenDayKeys.min(), let last = writtenDayKeys.max() else {
            // Unreachable: `writesSomething || !survivingEdits.isEmpty` was checked above, and both
            // paths append a day key. Named rather than silently nil so a regression is visible.
            assertionFailure("applyCoachPlan wrote no day after deciding the import writes something")
            FernletAuditLog.log("coachPlan.import.wroteNothing")
            return nil
        }

        recordTrainerAudit(TrainerAuditEvent(
            kind: .envelopeReceived,
            peerDisplayName: plan.coachDisplayName.isEmpty ? nil : plan.coachDisplayName,
            // Deliberately NOT stamped with a peer fingerprint or a trust basis: a manually pasted
            // plan has no verified sender. Recording one would make an unauthenticated import look
            // like a paired-coach delivery in the audit log.
            message: "Imported a pasted plan across \(writtenDayKeys.count) day(s): \(days.planned) added, "
            + "\(edits.edited) changed, \(edits.deleted) removed."))

        // `settings.customExercises` is written through the plain forwarder, which has no didSet —
        // unlike `planWorkout`, which schedules its own save. Without this an imported exercise
        // would live only in memory until some unrelated mutation happened to persist the blob.
        scheduleSnapshotSave()

        return CoachPlanImportResult(
            plannedWorkoutCount: days.planned,
            dayCount: writtenDayKeys.count,
            newExerciseCount: review.newExercises.count,
            struckExerciseCount: struckCount,
            editedCount: edits.edited,
            deletedCount: edits.deleted,
            firstDayKey: first,
            lastDayKey: last)
    }

    /// Adds the plan's genuinely new exercises to the user's catalog, up to
    /// `WorkoutExerciseCatalog.maxCustomExercises`.
    ///
    /// R3: the persisted catalog is fed by clipboard imports, so the cap is the DOMAIN's — the same
    /// number `WorkoutExerciseCatalog.registerCustomExercises` and the settings decode enforce, so no
    /// two seams can disagree about how many exercises the user has. ``reviewCoachPlan`` already
    /// blocks a plan that would exceed it; this is the belt-and-braces enforcement at the point the
    /// additions actually enter, and a truncation here means the review gate was bypassed — reported
    /// rather than silently swallowed (R7).
    private func registerNewExercises(_ targets: [ExerciseTarget]) {
        guard !targets.isEmpty else { return }
        let existingKeys = Set(settings.customExercises.map { CoachPlan.normalizedName($0.name) })
        let headroom = max(0, WorkoutExerciseCatalog.maxCustomExercises - settings.customExercises.count)
        let wanted = targets.filter { !existingKeys.contains(CoachPlan.normalizedName($0.name)) }
        let additions = wanted.prefix(headroom)
        if additions.count < wanted.count {
            FernletAuditLog.log("coachPlan.customExercises.truncated", context: [
                "requested": String(wanted.count),
                "accepted": String(additions.count),
                "max": String(WorkoutExerciseCatalog.maxCustomExercises)
            ])
        }
        guard !additions.isEmpty else { return }
        settings.customExercises.append(contentsOf: additions)
        syncCustomExerciseCatalog()
    }

    /// Applies the surviving edits to the calendar, reporting what changed and which days it touched.
    private func applyResolvedEdits(_ edits: [ResolvedCoachPlanEdit],
                                    filter: CoachPlanStrikeFilter,
                                    plan: CoachPlan) -> (edited: Int, deleted: Int, dayKeys: [String]) {
        var editedCount = 0
        var deletedCount = 0
        var dayKeys: [String] = []
        for resolved in edits {
            switch resolved.action {
            case .delete:
                // Planned rows only. `deletePlannedWorkout` cannot reach a logged workout, which is
                // the guarantee that an import can never erase something you actually did.
                deletePlannedWorkout(resolved.before, date: resolved.dayKey)
                deletedCount += 1
            case .adjust, .replace:
                // Struck exercises are honoured here too: a safety conflict the user turned off must
                // not come back in through an edit. Nothing surviving leaves the original standing.
                guard var updated = resolved.after,
                      let exercises = filter.survivingExercises(of: resolved) else { continue }
                updated.exercises = exercises
                updated.source = .coach
                updated.notes = Self.editedNote(updated.notes, plan: plan)
                deletePlannedWorkout(resolved.before, date: resolved.dayKey)
                planWorkout(updated, date: resolved.dayKey)
                editedCount += 1
            }
            if !dayKeys.contains(resolved.dayKey) { dayKeys.append(resolved.dayKey) }
        }
        return (editedCount, deletedCount, dayKeys)
    }

    /// Writes the plan's own days, reporting how many rows it planned and which days it touched.
    private func applyPlanDays(_ plan: CoachPlan,
                               startingOn startDayKey: String,
                               filter: CoachPlanStrikeFilter,
                               collisionPolicy: CoachPlanCollisionPolicy) -> (planned: Int, dayKeys: [String]) {
        var plannedCount = 0
        var dayKeys: [String] = []
        let today = FernletDate.dayKey(for: Date())
        for day in plan.days.sorted(by: { $0.dayIndex < $1.dayIndex }) {
            guard !day.isRestDay, !day.sessions.isEmpty else { continue }
            guard let dayKey = Self.dayKey(startingOn: startDayKey, offsetBy: day.dayIndex - 1) else { continue }

            // Sessions surviving the strikes, resolved BEFORE the collision delete: a day this plan
            // now prescribes nothing for must not have the user's existing plan cleared out from
            // under it and replaced with nothing.
            let sessions = day.sessions.filter(filter.prescribesSomething)
            guard !sessions.isEmpty else { continue }

            let existing = loadDay(for: dayKey).plannedWorkouts
            let preservesCollision = collisionPolicy == .keepExisting
                || (collisionPolicy == .replaceFutureConflicts && dayKey < today)
            if preservesCollision, !existing.isEmpty {
                continue
            }

            if collisionPolicy == .replace
                || (collisionPolicy == .replaceFutureConflicts && dayKey >= today) {
                // Only planned rows are cleared — never logged workouts. A plan arriving must not be
                // able to erase what someone actually did.
                for workout in existing {
                    deletePlannedWorkout(workout, date: dayKey)
                }
            }

            for session in sessions {
                planWorkout(Self.plannedWorkout(from: session, keeping: filter.kept(session), day: day, plan: plan),
                            date: dayKey)
                plannedCount += 1
            }
            dayKeys.append(dayKey)
        }
        return (plannedCount, dayKeys)
    }

    /// Mirrors the new-day half of `applyPlanDays` before custom exercises or edits are mutated.
    /// A keep-existing import with only collisions must be a true no-op, not a catalog-only write.
    private func planWritesAnything(_ plan: CoachPlan,
                                    startingOn startDayKey: String,
                                    filter: CoachPlanStrikeFilter,
                                    collisionPolicy: CoachPlanCollisionPolicy) -> Bool {
        let today = FernletDate.dayKey(for: Date())
        for day in plan.days {
            guard !day.isRestDay, day.sessions.contains(where: filter.prescribesSomething),
                  let dayKey = Self.dayKey(startingOn: startDayKey, offsetBy: day.dayIndex - 1) else { continue }
            let preserve = collisionPolicy == .keepExisting
                || (collisionPolicy == .replaceFutureConflicts && dayKey < today)
            if !preserve || loadDay(for: dayKey).plannedWorkouts.isEmpty { return true }
        }
        return false
    }

    /// Stamps an edited row so its origin survives in the row's own text, like a newly imported one.
    ///
    /// Replaces any previous import stamp rather than stacking them — a workout adjusted three times
    /// should read as "changed by X", not carry three generations of provenance.
    ///
    /// The stamp is frozen English on every device (``CoachPlanNoteStamp``; screens draw it localized),
    /// and the previous one is recognised by its exact shape. The strip used to drop every line
    /// starting "Day ", so a user's own "Day off, knees sore" vanished from the row on the first edit.
    static func editedNote(_ existing: String, plan: CoachPlan) -> String {
        let stamp = CoachPlanNoteStamp.changed(author: CoachPlanNoteStamp.author(named: plan.coachDisplayName),
                                               planTitle: plan.title)
        let kept = existing
            .components(separatedBy: .newlines)
            .filter { !CoachPlanNoteStamp.isStamp($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return (kept + [stamp]).joined(separator: "\n")
    }

    /// Projects one ``CoachSession`` onto the shipped ``PlannedWorkout`` shape.
    ///
    /// Set counts and rest are clamped to ``CoachPlanLimits`` here rather than rejected upstream —
    /// the review screen already warned about them as `.clamped` advisories, and this is where that
    /// promise is kept.
    private static func plannedWorkout(from session: CoachSession,
                                       keeping exercises: [CoachExercise],
                                       day: CoachPlanDay,
                                       plan: CoachPlan) -> PlannedWorkout {
        let lines = exercises.map { exercise -> String in
            let sets = min(max(exercise.sets, 1), CoachPlanLimits.maxSets)
            var clamped = exercise
            clamped.sets = sets
            if let rest = exercise.restSeconds {
                clamped.restSeconds = min(max(rest, 0), CoachPlanLimits.maxRestSeconds)
            }
            return clamped.line
        }
        let body = lines.joined(separator: "\n")
        let exerciseText = body.isEmpty ? (session.conditioning ?? "") : body

        var muscles = Set<MuscleGroup>()
        for exercise in exercises {
            guard let target = WorkoutExerciseCatalog.exercise(named: exercise.name) else { continue }
            muscles.formUnion(target.primaryMuscles)
        }

        var noteParts: [String] = []
        if let notes = session.notes, !notes.isEmpty { noteParts.append(notes) }
        if let conditioning = session.conditioning, !conditioning.isEmpty, !body.isEmpty {
            noteParts.append(conditioning)
        }
        // The provenance line is part of the row's text, not just the `.coach` tag, so it survives
        // into the trainer export and into anything that reads the note — an imported plan should
        // never be mistaken later for something Fernlet programmed.
        noteParts.append(CoachPlanNoteStamp.imported(dayIndex: day.dayIndex, planTitle: plan.title,
                                                     author: CoachPlanNoteStamp.author(named: plan.coachDisplayName)))

        return PlannedWorkout(
            name: session.title.isEmpty ? day.title : session.title,
            split: Self.split(for: session, muscles: muscles),
            source: .coach,
            mode: session.resolvedKind == .cardio ? .activity : .strengthTraining,
            exercises: exerciseText,
            muscleGroups: muscles,
            notes: noteParts.joined(separator: "\n"),
            duration: nil)
    }

    /// Picks the ``WorkoutSplit`` label for an imported session from its kind, then its muscle mix.
    private static func split(for session: CoachSession, muscles: Set<MuscleGroup>) -> WorkoutSplit {
        switch session.resolvedKind {
        case .cardio: return .cardio
        case .mobility: return .recovery
        case .strength, .fullBody, .sport: break
        }
        guard !muscles.isEmpty else { return .workout }
        let regions = muscles.map(\.region)
        let upper = regions.filter { $0 == .upper }.count
        let lower = regions.filter { $0 == .lower }.count
        let total = max(regions.count, 1)
        if Double(upper) / Double(total) >= 0.7 { return .upper }
        if Double(lower) / Double(total) >= 0.7 { return .lower }
        return .fullBody
    }
}
