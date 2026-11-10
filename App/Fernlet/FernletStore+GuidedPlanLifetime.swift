import Foundation
import FernletDomainModel
import FernletFoundation
import FernletScoring

/// What today's committed plan was built with, and what has happened to it since: the inputs a
/// rebuild reuses, the basis that tells when a rebuild is due, the sessions changed by hand or by
/// AI, and the "Updated for Home" line. One value on the store (`guidedPlanMemo`), kept in today's
/// plan file with the plan.
nonisolated struct GuidedPlanMemo: Equatable {
    /// "Anything else?" as it was typed for this plan.
    var context = ""
    /// The length chosen on the sheet for this plan; nil when Workout setup's applied.
    var sessionLength: WorkoutSessionLength?
    /// The space, limits and hidden exercises the plan was built for; nil until a plan is committed.
    var basis: GuidedPlanBasis?
    /// Sessions edited in the plan editor or adjusted with AI since they were built.
    var editedSessionIDs: Set<UUID> = []
    /// Why the plan was last rebuilt, for the plan pane's line; nil when it never was.
    var notice: GuidedPlanNotice?
}

/// Where today's plan file stands for this store.
nonisolated struct GuidedPlanDiskState: Equatable {
    /// True once the file has been read (or found missing): the store's plan is then the truth.
    var loaded = false
    /// True when a write failed (the phone was locked): the next foreground writes again.
    var needsWrite = false
}

/// The lifetime of today's committed plan (the owner's fixes e4 and e7, 2026-11-10).
///
/// **It follows the space and the limits (e4).** A committed plan used to be returned whatever had
/// changed since: approve "Upper" at the gym, go home, and the blue button started gym lifts; set
/// the knee to Severe from the plan's own "Equipment & limits" and the squats stayed. Now every
/// change to the active space (or what it owns), the limits or the hidden exercises is compared
/// with what the plan was built for (``GuidedPlanBasis``), and the sessions NOT YET STARTED are
/// built again with the plan's own intensity, "Anything else?" and chosen length. A session already
/// logged, or running in the guided runner, is left exactly as it is, with its id and its
/// completion. A rebuilt session's hand edits or AI adjustment are replaced, and the plan pane says
/// so in one line (``GuidedPlanNotice``).
///
/// **It survives iOS closing the app (e7).** Every change to the plan, its approval, its
/// completions and that line is written to today's plan file (`GuidedPlanFile.swift`, which says
/// where it lives and why it is not behind the app lock), and read back once at launch. A record
/// for another day is deleted. A restored plan goes straight through the rule above.
extension FernletStore {

    // MARK: What the plan is built for

    /// The space, limits and hidden exercises the planner would build from now.
    var currentGuidedPlanBasis: GuidedPlanBasis {
        GuidedPlanBasis(location: settings.activeWorkoutLocation, limits: settings.workoutProfile.injuryLimits,
                        hiddenKeys: settings.workoutExercisePreferences.hiddenKeys)
    }

    /// What `commitTodaysGuidedWorkoutPlan` records about a plan it has just built.
    func noteGuidedPlanBuilt(context: String, sessionLength: WorkoutSessionLength?) {
        guidedPlanMemo = GuidedPlanMemo(context: String(context.prefix(GuidedPlanRecord.maxText)),
                                        sessionLength: sessionLength, basis: currentGuidedPlanBasis)
    }

    /// The inputs today's committed plan was built with, for anything that builds on it again (the
    /// rebuild here; an AI adjustment that wants today's "Anything else?"). Nil without a plan.
    var committedGuidedPlanInputs: (intensity: WorkoutIntensity, context: String, sessionLength: WorkoutSessionLength?)? {
        guard currentGuidedWorkoutPlan != nil else { return nil }
        return (committedGuidedIntensity ?? .moderate, guidedPlanMemo.context, guidedPlanMemo.sessionLength)
    }

    /// The "Updated for Home" line's facts, while today's plan has one.
    var todaysGuidedPlanNotice: GuidedPlanNotice? {
        currentGuidedWorkoutPlan == nil ? nil : guidedPlanMemo.notice
    }

    // MARK: Rebuilding what has not started (e4)

    /// Whether `session` of today's plan must be left as it is: already logged (in this run of the
    /// app, or by its tagged name in today's record), or running in the guided runner now.
    func isGuidedSessionPinned(_ session: WorkoutProgram.SessionSuggestion) -> Bool {
        if let run = guidedRunState, !run.isDone, run.sessionID == session.id { return true }
        return GuidedWorkoutAvailability.isAlreadyLogged(session, completed: guidedCompletedSessionIDs,
                                                         loggedGuidedWorkoutNames: loggedGuidedWorkoutNamesToday)
    }

    /// Brings today's plan up to date with the space, limits and hidden exercises: when one has
    /// changed since the plan was built, the sessions not yet started are built again and the plan
    /// pane's line says so. Cheap when nothing changed, and when there is no plan. Called after
    /// every write that can change one of the three, when a plan is asked for, and after a restore.
    func refreshTodaysGuidedPlanForChanges() {
        guard let plan = currentGuidedWorkoutPlan else { return }
        let now = currentGuidedPlanBasis
        guard let built = guidedPlanMemo.basis else {
            // A plan with no recorded basis (set by a caller that replaced it whole): today's is it.
            guidedPlanMemo.basis = now
            return
        }
        guard now != built else { return }
        let reason: GuidedPlanNotice.Reason = now.spaceDiffers(from: built) ? .space
            : (now.limitsDiffer(from: built) ? .limits : .hidden)
        let hidden = reason == .hidden ? Set(now.hidden) : nil
        let stale = plan.sessions.filter { !isGuidedSessionPinned($0) && Self.isStale($0, hiddenOnly: hidden) }
        guidedPlanMemo.basis = now
        guard !stale.isEmpty else {
            persistTodaysGuidedPlan()
            return
        }
        let fresh = freshGuidedPlan(like: plan)
        let staleIDs = Set(stale.map(\.id))
        let replaced = stale.filter { guidedPlanMemo.editedSessionIDs.contains($0.id) }.map(\.suggestion.name)
        guidedPlanStorage = Self.merged(plan, with: fresh, replacing: staleIDs)
        guidedPlanMemo.editedSessionIDs.subtract(staleIDs)
        guidedPlanMemo.notice = GuidedPlanNotice(reason: reason, spaceName: settings.activeWorkoutLocation.name,
                                                 replacedSessionNames: replaced)
        FernletAuditLog.log("workout.guided.planRebuilt", context: ["reason": reason.rawValue, "sessions": String(stale.count)])
        persistTodaysGuidedPlan()
    }

    /// Whether a not-yet-started session needs building again: always for a change of space or
    /// limits; for a change of hidden exercises alone (`hiddenOnly`, the hidden keys), only when
    /// the session holds one of them — so hiding an exercise the plan does not use, or one the
    /// person has just swapped out in the editor, rebuilds nothing.
    static func isStale(_ session: WorkoutProgram.SessionSuggestion, hiddenOnly: Set<String>?) -> Bool {
        guard let hiddenOnly else { return true }
        return session.exercises.contains { $0.fromCatalog && hiddenOnly.contains(WorkoutExerciseCatalog.normalizedName($0.name)) }
    }

    /// Today's plan built again as `plan` was: the rest plan on a day marked unwell, the Travel-day
    /// reset for a travel plan, and otherwise the planner's plan with the intensity, "Anything
    /// else?" and chosen length the committed plan was built with.
    func freshGuidedPlan(like plan: WorkoutProgram.DayPlan) -> WorkoutProgram.DayPlan {
        if !needsRestToday, WorkoutPlanner.isTravelDayPlan(plan) { return travelDayResetPlan() }
        let inputs = committedGuidedPlanInputs
        return workoutDayPlan(intensity: inputs?.intensity ?? .moderate, context: inputs?.context ?? "",
                              sessionLength: inputs?.sessionLength)
    }

    /// `plan` with each session in `stale` replaced by its counterpart in `fresh` — the session of
    /// the same name, else the one in the same place — and every other session kept as it is, id
    /// and all. A fresh session with no counterpart at all joins the end (the day changed shape),
    /// and a stale one with none is dropped. The day's own fields are `fresh`'s.
    static func merged(
        _ plan: WorkoutProgram.DayPlan, with fresh: WorkoutProgram.DayPlan, replacing stale: Set<UUID>
    ) -> WorkoutProgram.DayPlan {
        var sessions: [WorkoutProgram.SessionSuggestion] = []
        var taken: Set<UUID> = []
        for (index, old) in plan.sessions.prefix(GuidedPlanRecord.maxSessions).enumerated() {
            guard stale.contains(old.id) else {
                sessions.append(old)
                continue
            }
            let byName = fresh.sessions.first { $0.suggestion.name == old.suggestion.name && !taken.contains($0.id) }
            let byPlace = index < fresh.sessions.count && !taken.contains(fresh.sessions[index].id) ? fresh.sessions[index] : nil
            guard let replacement = byName ?? byPlace else { continue }
            taken.insert(replacement.id)
            sessions.append(replacement)
        }
        let keptNames = Set(sessions.map(\.suggestion.name))
        for extra in fresh.sessions.prefix(GuidedPlanRecord.maxSessions)
        where !taken.contains(extra.id) && !keptNames.contains(extra.suggestion.name) && sessions.count < GuidedPlanRecord.maxSessions {
            sessions.append(extra)
        }
        return WorkoutProgram.DayPlan(splitName: fresh.splitName, dayTitle: fresh.dayTitle, sessions: sessions,
                                      droppedSlots: fresh.droppedSlots, locationName: fresh.locationName,
                                      recovery: fresh.recovery)
    }

    /// Records which sessions a replacement of the whole plan changed (the AI adjustment keeps each
    /// session's id): a session whose plan text differs from the one it replaces now carries a
    /// change of the person's own, which a later rebuild would replace and must say so.
    func noteGuidedSessionsChanged(from old: WorkoutProgram.DayPlan, to new: WorkoutProgram.DayPlan) {
        for session in new.sessions.prefix(GuidedPlanRecord.maxSessions) {
            guard let before = old.sessions.first(where: { $0.id == session.id }),
                  before.suggestion.exercises != session.suggestion.exercises else { continue }
            guidedPlanMemo.editedSessionIDs.insert(session.id)
        }
    }

    // MARK: Keeping it on the device (e7)

    /// Writes today's plan and everything about it to its file, or deletes the file when there is
    /// no plan. A store without a file (tests, previews) keeps nothing. A failed write is tried
    /// again at the next change or the next foreground.
    func persistTodaysGuidedPlan() {
        guard let file = guidedPlanFile else { return }
        guard let plan = guidedPlanStorage, let dayKey = guidedPlanDayKey else {
            guidedPlanDisk.needsWrite = !file.clear()
            return
        }
        let record = GuidedPlanRecord(
            dayKey: dayKey,
            intensity: (committedGuidedIntensityStorage ?? .moderate).rawValue,
            context: guidedPlanMemo.context,
            sessionLength: guidedPlanMemo.sessionLength?.rawValue,
            approved: guidedPlanApprovedDayKey == dayKey,
            completedSessionIDs: guidedCompletedSessionIDs.sorted { $0.uuidString < $1.uuidString },
            editedSessionIDs: guidedPlanMemo.editedSessionIDs.sorted { $0.uuidString < $1.uuidString },
            basis: guidedPlanMemo.basis,
            notice: guidedPlanMemo.notice,
            plan: GuidedPlanRecord.StoredPlan(plan)
        )
        guidedPlanDisk.needsWrite = !file.write(record)
        if guidedPlanDisk.needsWrite { FernletAuditLog.log("workout.guided.planFile.writeDeferred") }
    }

    /// Reads today's plan back once per launch, before anything builds a new one: a record for
    /// today is adopted with its edits, approval and completions, then brought up to date with the
    /// space and limits (e4); a record for another day, or one this build cannot read, is deleted.
    /// A file that cannot be read yet (the phone is locked) is left for the next call. Also where a
    /// write that failed is tried again, and where yesterday's file goes once the day has changed.
    func restoreTodaysGuidedPlanIfNeeded() {
        guard let file = guidedPlanFile else { return }
        guard !guidedPlanDisk.loaded else {
            tidyTodaysGuidedPlanFile(file)
            return
        }
        switch file.read() {
        case .unreadable:
            return
        case .missing:
            guidedPlanDisk.loaded = true
        case .undecodable:
            guidedPlanDisk.loaded = true
            if !file.clear() { FernletAuditLog.log("workout.guided.planFile.clearFailed") }
        case .record(let record):
            guidedPlanDisk.loaded = true
            adoptGuidedPlanRecord(record, from: file)
        }
    }

    /// After the first read: writes again what a failed write left behind, and deletes the file of
    /// a plan whose day has passed (kept in memory only while a run that crossed midnight needs it).
    private func tidyTodaysGuidedPlanFile(_ file: GuidedPlanFile) {
        if let dayKey = guidedPlanDayKey, dayKey != todayKey {
            if !file.clear() { FernletAuditLog.log("workout.guided.planFile.clearFailed") }
            return
        }
        if guidedPlanDisk.needsWrite { persistTodaysGuidedPlan() }
    }

    /// Takes a record read from the file: today's becomes the committed plan unless this run of the
    /// app already committed one (which is newer, and is written over it); any other is deleted.
    private func adoptGuidedPlanRecord(_ record: GuidedPlanRecord, from file: GuidedPlanFile) {
        guard record.version == GuidedPlanRecord.currentVersion, record.dayKey == todayKey else {
            if !file.clear() { FernletAuditLog.log("workout.guided.planFile.clearFailed") }
            return
        }
        guard currentGuidedWorkoutPlan == nil else {
            persistTodaysGuidedPlan()
            return
        }
        guidedPlanStorage = record.plan.plan
        guidedPlanDayKey = record.dayKey
        committedGuidedIntensityStorage = WorkoutIntensity(rawValue: record.intensity) ?? .moderate
        guidedCompletedSessionIDs = Set(record.completedSessionIDs.prefix(GuidedPlanRecord.maxSessions))
        guidedPlanApprovedDayKey = record.approved ? record.dayKey : nil
        guidedPlanMemo = GuidedPlanMemo(
            context: String(record.context.prefix(GuidedPlanRecord.maxText)),
            sessionLength: record.sessionLength.flatMap(WorkoutSessionLength.init(rawValue:)),
            basis: record.basis,
            editedSessionIDs: Set(record.editedSessionIDs.prefix(GuidedPlanRecord.maxSessions)),
            notice: record.notice
        )
        refreshTodaysGuidedPlanForChanges()
    }

    /// Drops today's plan from memory for "Delete everything" and "Reset everything": the plan, its
    /// day, intensity, completions and approval, and everything remembered about it. The file is
    /// deleted by `resetAll` itself, which reports a failure.
    func forgetTodaysGuidedPlanForWipe() {
        guidedPlanStorage = nil
        guidedPlanDayKey = nil
        committedGuidedIntensityStorage = nil
        guidedCompletedSessionIDs = []
        guidedPlanApprovedDayKey = nil
        guidedPlanMemo = GuidedPlanMemo()
        guidedPlanDisk = GuidedPlanDiskState(loaded: true, needsWrite: false)
    }
}

/// The plan pane's "Updated for Home." line (the owner's fix e4), composed from a
/// ``GuidedPlanNotice``. Display text only; the notice itself holds frozen names and tokens.
enum GuidedPlanNoticeCopy {
    /// The line: what the plan was updated for, then, when the rebuild replaced the person's own
    /// changes to a session, a second sentence naming it.
    static func line(_ notice: GuidedPlanNotice) -> String {
        let first: String
        switch notice.reason {
        case .space:
            let space = WorkoutLocationNames.displayed(notice.spaceName) ?? notice.spaceName
            first = String(localized: "move.plan.updated.space", defaultValue: "Updated for \(space).",
                           comment: "Line on today's workout plan: the not-yet-started sessions were rebuilt because the person changed workout space (or its equipment). The argument is the space's name, e.g. 'Home'.")
        case .limits:
            first = String(localized: "move.plan.updated.limits", defaultValue: "Updated for your limits.",
                           comment: "Line on today's workout plan: the not-yet-started sessions were rebuilt because the person changed the body areas to work around.")
        case .hidden:
            first = String(localized: "move.plan.updated.hidden", defaultValue: "Updated to leave out what you've hidden.",
                           comment: "Line on today's workout plan: the not-yet-started sessions were rebuilt because the person hid an exercise ('Don't suggest this') that was in them.")
        }
        guard !notice.replacedSessionNames.isEmpty else { return first }
        let names = notice.replacedSessionNames.prefix(GuidedPlanRecord.maxSessions)
            .map { WorkoutSessionNames.drawn($0) }.formatted(.list(type: .and))
        let second = String(localized: "move.plan.updated.changesReplaced", defaultValue: "Your changes to \(names) were replaced.",
                            comment: "Second sentence of the 'Updated for …' line on today's workout plan: the person's own edits or AI adjustment to one or more sessions were replaced by the rebuild. The argument is the session name or names, e.g. 'Upper', 'Upper and Lower'.")
        return "\(first) \(second)"
    }
}
