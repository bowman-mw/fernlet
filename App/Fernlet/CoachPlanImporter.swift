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
enum CoachPlanCollisionPolicy {
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
    case malformed(String)

    /// User-facing copy. Every case says what to do next, because "invalid" alone leaves someone
    /// re-pasting the same text.
    var message: String {
        switch self {
        case .empty:
            "There's nothing to import. Copy the plan your assistant replied with, then paste it here."
        case .tooLarge(let bytes):
            "That's \(bytes / 1024) KB of text — larger than a workout plan should be. Paste just the JSON block from the reply."
        case .noJSONFound:
            "Fernlet couldn't find a plan in what you pasted. Copy the whole JSON block from the reply, including its braces."
        case .bounded(let error):
            error.message
        case .malformed(let detail):
            "That plan couldn't be read: \(detail)"
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
    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map(\.stringValue).filter { !$0.isEmpty }
            return keys.isEmpty ? "the plan" : keys.joined(separator: " → ")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "\"\(key.stringValue)\" is missing from \(path(context))."
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "\(path(context)) has the wrong kind of value."
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty
                ? "it isn't valid JSON."
                : "\(path(context)) couldn't be read."
        @unknown default:
            return "it couldn't be read."
        }
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
                                detail: "This plan adds \(newExercises.count) exercises but your list can hold "
                                + "only \(headroom) more. Remove some custom exercises, then import again."))
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
                                    detail: "A change points at a planned workout that isn't there any more — "
                                    + "it may have been done, edited, or deleted since you copied your summary. "
                                    + "Copy a fresh summary and ask again."))
                continue
            }
            guard found.dayKey >= today else {
                issues.append(.init(kind: .unresolvableEdit, subject: found.workout.name,
                                    detail: "\"\(found.workout.name)\" was planned for \(found.dayKey), which has "
                                    + "already passed. Fernlet only changes workouts still ahead of you."))
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
                                    detail: "\"\(found.workout.name)\" is already exactly what the change asks for; "
                                    + "nothing to do."))
            }
        }
        return (resolved.sorted { $0.dayKey < $1.dayKey }, issues)
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
            updated.exercises = exercises.map { exercise -> String in
                var clamped = exercise
                clamped.sets = min(max(exercise.sets, 1), CoachPlanLimits.maxSets)
                if let rest = exercise.restSeconds {
                    clamped.restSeconds = min(max(rest, 0), CoachPlanLimits.maxRestSeconds)
                }
                return clamped.line
            }.joined(separator: "\n")
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

    /// The safety pass over an edit's proposed exercises.
    private static func safetyFlags(forEdits edits: [ResolvedCoachPlanEdit],
                                    resolvedByKey: [String: ExerciseTarget],
                                    location: WorkoutLocation,
                                    profile: WorkoutProfile) -> [CoachPlanSafetyFlag] {
        var flags: [CoachPlanSafetyFlag] = []
        for resolved in edits {
            for exercise in resolved.edit.exercises ?? [] {
                let key = CoachPlan.normalizedName(exercise.name)
                guard let target = resolvedByKey[key] else { continue }
                var reasons: [String] = []
                if profile.avoidedMovements.contains(target.movementPattern) {
                    reasons.append("you avoid \(target.movementPattern.rawValue) movements")
                }
                let conflicting = target.primaryMuscles.union(target.secondaryMuscles)
                    .intersection(profile.avoidedMuscles)
                if !conflicting.isEmpty {
                    reasons.append("it works \(conflicting.map(\.displayName).sorted().joined(separator: ", ")), which you avoid")
                }
                if !location.has(target.equipment) {
                    reasons.append("\(location.name) has no \(target.equipment.displayName.lowercased())")
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
        for day in plan.days {
            for session in day.sessions {
                for exercise in session.exercises {
                    let key = CoachPlan.normalizedName(exercise.name)
                    // An unresolved name is already reported as a blocking `undefinedExercise`
                    // issue; flagging it again here would double-report the same problem.
                    guard let target = resolvedByKey[key] else { continue }

                    var reasons: [String] = []
                    if profile.avoidedMovements.contains(target.movementPattern) {
                        reasons.append("you avoid \(target.movementPattern.rawValue) movements")
                    }
                    let worked = target.primaryMuscles.union(target.secondaryMuscles)
                    let conflicting = worked.intersection(profile.avoidedMuscles)
                    if !conflicting.isEmpty {
                        let names = conflicting.map(\.displayName).sorted().joined(separator: ", ")
                        reasons.append("it works \(names), which you avoid")
                    }
                    if !location.has(target.equipment) {
                        reasons.append("\(location.name) has no \(target.equipment.displayName.lowercased())")
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

    /// The exercises of `session` that survive the strikes.
    func kept(_ session: CoachSession) -> [CoachExercise] {
        session.exercises.filter { !struckKeys.contains(CoachPlan.normalizedName($0.name)) }
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
        if !struckKeys.isEmpty {
            let lines = after.exerciseLines.filter { line in
                !struckKeys.contains(where: { line.lowercased().hasPrefix($0) })
            }
            text = lines.joined(separator: "\n")
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
        let writesSomething = plan.days.contains { day in
            !day.isRestDay && day.sessions.contains(where: filter.prescribesSomething)
        }
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
        for day in plan.days.sorted(by: { $0.dayIndex < $1.dayIndex }) {
            guard !day.isRestDay, !day.sessions.isEmpty else { continue }
            guard let dayKey = Self.dayKey(startingOn: startDayKey, offsetBy: day.dayIndex - 1) else { continue }

            // Sessions surviving the strikes, resolved BEFORE the collision delete: a day this plan
            // now prescribes nothing for must not have the user's existing plan cleared out from
            // under it and replaced with nothing.
            let sessions = day.sessions.filter(filter.prescribesSomething)
            guard !sessions.isEmpty else { continue }

            if collisionPolicy == .replace {
                // Only planned rows are cleared — never logged workouts. A plan arriving must not be
                // able to erase what someone actually did.
                for existing in loadDay(for: dayKey).plannedWorkouts {
                    deletePlannedWorkout(existing, date: dayKey)
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

    /// Stamps an edited row so its origin survives in the row's own text, like a newly imported one.
    ///
    /// Replaces any previous import stamp rather than stacking them — a workout adjusted three times
    /// should read as "changed by X", not carry three generations of provenance.
    private static func editedNote(_ existing: String, plan: CoachPlan) -> String {
        let author = plan.coachDisplayName.isEmpty ? "an assistant" : plan.coachDisplayName
        let stamp = "Changed by \(author) from \"\(plan.title)\"."
        let kept = existing
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("Changed by ") && !$0.hasPrefix("Day ") }
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
        let author = plan.coachDisplayName.isEmpty ? "an assistant" : plan.coachDisplayName
        noteParts.append("Day \(day.dayIndex) of \"\(plan.title)\", imported from \(author).")

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
