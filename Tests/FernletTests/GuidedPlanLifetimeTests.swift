import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Store-level coverage for the lifetime of today's committed plan (the owner's fixes e3, e4 and e7,
/// 2026-11-10): "Anything else?" reaching the plan through the store, the rebuild of not-yet-started
/// sessions when the space, the limits or the hidden exercises change (with completed and running
/// sessions kept, and the "Updated for Home" line), and the plan's file — written on every change,
/// read back by a new store with its edits and approval, dropped when the day changes, and erased by
/// "Delete everything".
///
/// Serialized for the same reason as `GuidedWorkoutRunStoreTests`: each test stands up a real
/// `FernletStore`, which reaches process-global registries the directory seams do not cover.
@MainActor
@Suite(.serialized)
struct GuidedPlanLifetimeTests {

    // MARK: - Fixtures

    /// THIS test's app-group root and plan folder: every store one test builds shares them, which is
    /// what the relaunch tests need, and no other test can reach them.
    private let appGroupDirectory = uniqueAppGroupDirectory()
    private let planDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("fernlet.tests.todaysPlan.\(UUID().uuidString)", isDirectory: true)

    private var planFile: GuidedPlanFile { GuidedPlanFile(directory: planDirectory) }

    /// A store on a one-session-a-day split whose first day squats, presses, rows and hinges, for an
    /// intermediate lifter (so the full gym's day is barbell work Home cannot run), at the full gym,
    /// with the plan file in this test's folder.
    private func makeStore(split: String = "full-body-3", date: Date = .now) -> FernletStore {
        let store = makeTestStore(date: date, appGroupDirectory: appGroupDirectory)
        store.setSelectedSplit(split)
        var profile = store.settings.workoutProfile
        profile.experience = .intermediate
        store.setWorkoutProfile(profile)
        store.setWorkoutLocations([.fullGym, .home], activeID: WorkoutLocation.fullGym.id)
        store.guidedPlanFile = planFile
        return store
    }

    private func lifts(_ plan: WorkoutProgram.DayPlan?) -> [String] {
        (plan?.sessions ?? []).flatMap(\.exercises).filter { $0.block == .lifting && $0.fromCatalog }.map(\.name)
    }

    private func target(_ name: String) throws -> ExerciseTarget {
        try #require(WorkoutExerciseCatalog.exercise(named: name))
    }

    private func severeKnee(_ store: FernletStore) {
        var profile = store.settings.workoutProfile
        profile.injuryAreas[.knee] = .severe
        store.setWorkoutProfile(profile)
    }

    // MARK: - "Anything else?" through the store (e3)

    /// The sheet's note reaches the planner: the knee is eased in today's plan and the note says so,
    /// while the saved profile is exactly what it was.
    @Test func aSoreKneeTypedOnTheSheetEasesTodayOnly() throws {
        let store = makeStore()
        let before = store.settings.workoutProfile
        let plain = store.workoutDayPlan(intensity: .moderate, context: "")
        let plan = store.commitTodaysGuidedWorkoutPlan(intensity: .moderate, context: "sore left knee")
        #expect(lifts(plain).contains("Back squat"))
        #expect(!lifts(plan).contains("Back squat"))
        #expect(plan.sessions.first?.suggestion.notes.contains("Going easy on your knee today.") == true)
        #expect(store.settings.workoutProfile == before)
        #expect(store.committedGuidedPlanInputs?.context == "sore left knee")
    }

    /// A length chosen on the sheet stands against "short on time"; left alone, the note shortens.
    @Test func shortOnTimeShortensUnlessALengthWasChosenOnTheSheet() {
        let store = makeStore()
        let short = store.workoutDayPlan(intensity: .moderate, context: "short on time")
        let chosen = store.workoutDayPlan(intensity: .moderate, context: "short on time", sessionLength: .min60)
        #expect(short.sessions.first?.suggestion.notes.contains("Kept to about 20 minutes, as you asked.") == true)
        #expect(chosen.sessions.first?.suggestion.notes.contains("as you asked") == false)
    }

    // MARK: - The plan follows the space, the limits and the hidden exercises (e4)

    /// Committed at the full gym, then the space changes: the sessions not yet started are rebuilt
    /// for the new space, with the plan's own intensity, and the line says so.
    @Test func changingTheSpaceRebuildsWhatHasNotStarted() throws {
        let store = makeStore()
        let gym = store.commitTodaysGuidedWorkoutPlan(intensity: .hard)
        store.approveTodaysGuidedPlan()
        #expect(lifts(gym).contains("Back squat"))
        #expect(store.todaysGuidedPlanNotice == nil)

        store.setActiveWorkoutLocation(WorkoutLocation.home.id)

        let home = try #require(store.currentGuidedWorkoutPlan)
        #expect(home.locationName == "Home")
        #expect(Set(home.sessions.map(\.id)).isDisjoint(with: gym.sessions.map(\.id)), "rebuilt sessions are new ones")
        #expect(!lifts(home).isEmpty)
        for name in lifts(home) {
            #expect(WorkoutSafetyFilter.hasEquipment(for: try target(name), at: .home), "\(name) needs gear Home lacks")
        }
        #expect(store.committedGuidedIntensity == .hard)
        #expect(store.isTodaysGuidedPlanApproved, "an approved plan stays approved")
        let notice = try #require(store.todaysGuidedPlanNotice)
        #expect(notice.reason == .space && notice.spaceName == "Home" && notice.replacedSessionNames.isEmpty)
        #expect(GuidedPlanNoticeCopy.line(notice) == "Updated for Home.")
        // Asking for the plan again hands back the rebuilt one, unchanged.
        #expect(store.commitTodaysGuidedWorkoutPlan(intensity: .light).sessions.map(\.id) == home.sessions.map(\.id))
    }

    /// A finished session stays exactly as it was — id, content and completion — while the session
    /// still to do is rebuilt for the new space.
    @Test func aFinishedSessionStaysAndTheRestIsRebuilt() throws {
        let store = makeStore(split: "cardio-strength-4")
        let plan = store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        try #require(plan.sessions.count == 2)
        let morning = plan.sessions[0]
        let evening = plan.sessions[1]
        store.markGuidedSessionCompleted(morning.id)

        store.setActiveWorkoutLocation(WorkoutLocation.home.id)

        let rebuilt = try #require(store.currentGuidedWorkoutPlan)
        try #require(rebuilt.sessions.count == 2)
        #expect(rebuilt.sessions[0].id == morning.id)
        #expect(rebuilt.sessions[0].suggestion.exercises == morning.suggestion.exercises)
        #expect(store.guidedCompletedSessionIDs == [morning.id])
        #expect(rebuilt.sessions[1].id != evening.id)
        #expect(rebuilt.sessions[1].suggestion.name == evening.suggestion.name)
        #expect(rebuilt.sessions[1].suggestion.exercises != evening.suggestion.exercises)
    }

    /// A session running in the guided runner finishes as it was planned.
    @Test func aRunningSessionIsLeftAlone() throws {
        let store = makeStore()
        store.clearGuidedRun()
        let plan = store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        let session = try #require(plan.sessions.first)
        try #require(store.startGuidedRun(session))

        store.setActiveWorkoutLocation(WorkoutLocation.home.id)

        #expect(store.currentGuidedWorkoutPlan?.sessions.map(\.id) == [session.id])
        #expect(store.todaysGuidedPlanNotice == nil)
        store.clearGuidedRun()
    }

    /// The knee set to Severe after the plan was committed: no squat, and nothing else that loads
    /// the knee, is left in the sessions still to do.
    @Test func aKneeSetToSevereAfterCommitLeavesNoSquat() throws {
        let store = makeStore()
        #expect(lifts(store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)).contains("Back squat"))

        severeKnee(store)

        let plan = try #require(store.currentGuidedWorkoutPlan)
        let limits = store.settings.workoutProfile.injuryLimits
        #expect(limits.severeAreas == [.knee])
        for name in lifts(plan) {
            let lift = try target(name)
            #expect(lift.movementPattern != .squat && limits.allows(lift), "\(name)")
        }
        let notice = try #require(store.todaysGuidedPlanNotice)
        #expect(notice.reason == .limits)
        #expect(GuidedPlanNoticeCopy.line(notice) == "Updated for your limits.")
    }

    /// Hiding an exercise the plan holds removes it; hiding one it does not hold rebuilds nothing.
    @Test func hidingAnExerciseRemovesItFromWhatHasNotStarted() throws {
        let store = makeStore()
        let plan = store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        #expect(lifts(plan).contains("Back squat"))

        #expect(store.hideExercise("Calf raise"))
        #expect(store.currentGuidedWorkoutPlan?.sessions.map(\.id) == plan.sessions.map(\.id), "not in the plan: nothing to rebuild")
        #expect(store.todaysGuidedPlanNotice == nil)

        #expect(store.hideExercise("Back squat"))
        let rebuilt = try #require(store.currentGuidedWorkoutPlan)
        #expect(!lifts(rebuilt).contains("Back squat"))
        #expect(rebuilt.sessions.map(\.id) != plan.sessions.map(\.id))
        #expect(store.todaysGuidedPlanNotice?.reason == .hidden)
        #expect(GuidedPlanNoticeCopy.line(try #require(store.todaysGuidedPlanNotice)) == "Updated to leave out what you've hidden.")
    }

    /// A rebuild replaces a hand edit to a session that has not started, and the line names it. The
    /// editor's own Save, which writes its "Don't suggest" marks with the edit, rebuilds nothing.
    @Test func aRebuildSaysWhenItReplacedTheirChanges() throws {
        let store = makeStore()
        let plan = store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        var edited = try #require(plan.sessions.first)
        edited.exercises.removeAll { $0.block == .lifting && $0.name != "Back squat" }
        edited.suggestion.exercises = WorkoutSessionBlocks.planText(for: edited.exercises)
        #expect(store.updateGuidedSession(edited))
        store.applyExercisePreferenceEdits(hidden: ["Back squat"], alternates: [:])
        #expect(store.currentGuidedWorkoutPlan?.sessions.first?.suggestion.exercises == edited.suggestion.exercises,
                "the editor's Save keeps the session it has just written")
        #expect(store.todaysGuidedPlanNotice == nil)

        store.setActiveWorkoutLocation(WorkoutLocation.home.id)

        let notice = try #require(store.todaysGuidedPlanNotice)
        #expect(notice.replacedSessionNames == [edited.suggestion.name])
        #expect(GuidedPlanNoticeCopy.line(notice)
                == "Updated for Home. Your changes to \(WorkoutSessionNames.drawn(edited.suggestion.name)) were replaced.")
        #expect(store.currentGuidedWorkoutPlan?.sessions.first?.suggestion.exercises != edited.suggestion.exercises)
    }

    /// The blue button at another space starts a plan built for that space, not the one approved
    /// somewhere else.
    @Test func theBlueButtonAtAnotherSpaceStartsAPlanForThatSpace() throws {
        let store = makeStore()
        let gym = store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        store.approveTodaysGuidedPlan()
        #expect(lifts(gym).contains("Back squat"))

        let session = try #require(store.startTodaysPlan(at: WorkoutLocation.home.id))

        #expect(store.settings.activeWorkoutLocationID == WorkoutLocation.home.id)
        #expect(!gym.sessions.map(\.id).contains(session.id))
        #expect(store.currentGuidedWorkoutPlan?.locationName == "Home")
        for step in session.exercises where step.block == .lifting && step.fromCatalog {
            #expect(WorkoutSafetyFilter.hasEquipment(for: try target(step.name), at: .home), "\(step.name)")
        }
    }

    /// "Suggest a room workout" no longer shows a committed gym plan under "No equipment".
    @Test func theRoomWorkoutRebuildsACommittedGymPlan() throws {
        let store = makeStore()
        #expect(lifts(store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)).contains("Back squat"))

        store.prepareRoomWorkout()

        let room = try #require(store.settings.workoutLocations.first { $0.id == FernletStore.worldRoomSpaceID })
        let plan = try #require(store.currentGuidedWorkoutPlan)
        #expect(plan.locationName == room.name)
        for name in lifts(plan) {
            #expect(WorkoutSafetyFilter.hasEquipment(for: try target(name), at: room), "\(name)")
        }
        #expect(store.todaysGuidedPlanNotice?.reason == .space)
    }

    // MARK: - The plan survives a relaunch (e7)

    /// A plan saved, the store rebuilt from disk: the plan comes back with its sessions (ids, steps
    /// and load plans), its hand edit, its intensity, "Anything else?", its completions and its
    /// approval.
    @Test func aRelaunchRestoresThePlanWithItsEditsAndApproval() throws {
        let first = makeStore(split: "cardio-strength-4")
        let committed = first.commitTodaysGuidedWorkoutPlan(intensity: .hard, context: "sore left knee", sessionLength: .min45)
        try #require(committed.sessions.count == 2)
        var edited = committed.sessions[1]
        edited.exercises.removeLast()
        edited.suggestion.exercises = WorkoutSessionBlocks.planText(for: edited.exercises)
        #expect(first.updateGuidedSession(edited))
        first.approveTodaysGuidedPlan()
        first.markGuidedSessionCompleted(committed.sessions[0].id)
        let saved = try #require(first.currentGuidedWorkoutPlan)

        let second = makeStore(split: "cardio-strength-4")
        #expect(second.currentGuidedWorkoutPlan == nil, "nothing is read before the launch's restore")
        second.reconcileGuidedRunFromAppGroup()

        let restored = try #require(second.currentGuidedWorkoutPlan)
        #expect(restored.sessions.map(\.id) == saved.sessions.map(\.id))
        #expect(restored.sessions.map(\.exercises) == saved.sessions.map(\.exercises), "every step, with its load plan")
        #expect(restored.sessions.map(\.suggestion) == saved.sessions.map(\.suggestion))
        #expect(restored.sessions[1].suggestion.exercises == edited.suggestion.exercises)
        #expect(restored.splitName == saved.splitName && restored.dayTitle == saved.dayTitle)
        #expect(restored.locationName == saved.locationName && restored.recovery == saved.recovery)
        #expect(second.committedGuidedIntensity == .hard)
        #expect(second.isTodaysGuidedPlanApproved)
        #expect(second.guidedCompletedSessionIDs == [committed.sessions[0].id])
        let inputs = try #require(second.committedGuidedPlanInputs)
        #expect(inputs.context == "sore left knee" && inputs.sessionLength == .min45)
        #expect(second.guidedPlanMemo.editedSessionIDs == [edited.id])
        // The restored plan is the committed one: asking again builds nothing new.
        #expect(second.commitTodaysGuidedWorkoutPlan(intensity: .light).sessions.map(\.id) == saved.sessions.map(\.id))
    }

    /// A plan restored after a relaunch is still held to the space it finds: changed while the app
    /// was closed, the sessions not yet started are rebuilt as it comes back.
    @Test func aRestoredPlanIsRebuiltForASpaceChangedMeanwhile() throws {
        let first = makeStore()
        let gym = first.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        #expect(lifts(gym).contains("Back squat"))

        let second = makeStore()
        second.diaryChangingSpaceWithoutThePlan(to: WorkoutLocation.home.id)
        second.reconcileGuidedRunFromAppGroup()

        let plan = try #require(second.currentGuidedWorkoutPlan)
        #expect(plan.locationName == "Home")
        #expect(second.todaysGuidedPlanNotice?.reason == .space)
        #expect(planFile.read() == .record(try #require(recorded(planFile))), "and the rebuilt plan is what the file now holds")
        #expect(recorded(planFile)?.plan.locationName == "Home")
    }

    /// The file holds one day's plan: read on another day it is deleted and nothing is restored.
    @Test func aNewDayDropsThePlan() throws {
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: .now))
        let first = makeStore(date: yesterday)
        first.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        first.approveTodaysGuidedPlan()
        #expect(recorded(planFile)?.dayKey == first.todayKey)

        let second = makeStore()
        second.reconcileGuidedRunFromAppGroup()
        #expect(second.currentGuidedWorkoutPlan == nil)
        #expect(!second.isTodaysGuidedPlanApproved)
        #expect(planFile.read() == .missing)
    }

    /// A file that is not a plan record is deleted, never adopted, and never fatal.
    @Test func anUnreadableRecordIsDroppedQuietly() throws {
        try FileManager.default.createDirectory(at: planDirectory, withIntermediateDirectories: true)
        try Data("not a plan".utf8).write(to: planDirectory.appendingPathComponent(GuidedPlanFile.fileName))
        #expect(planFile.read() == .undecodable)
        let store = makeStore()
        store.reconcileGuidedRunFromAppGroup()
        #expect(store.currentGuidedWorkoutPlan == nil)
        #expect(planFile.read() == .missing)
    }

    /// Reworking the plan deletes its file with it.
    @Test func reworkingThePlanDeletesItsFile() {
        let store = makeStore()
        store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        #expect(recorded(planFile) != nil)
        #expect(store.reworkTodaysGuidedPlan())
        #expect(planFile.read() == .missing)
    }

    /// "Reset everything" (which "Delete everything" runs) erases the plan from memory and from the
    /// device, so a relaunch finds nothing to restore.
    @Test func theWipeErasesThePlan() throws {
        let store = makeStore()
        store.clearGuidedRun()
        store.commitTodaysGuidedWorkoutPlan(intensity: .moderate, context: "sore left knee")
        store.approveTodaysGuidedPlan()
        #expect(recorded(planFile)?.context == "sore left knee")

        let incomplete = store.resetAll()

        #expect(!incomplete.contains("today's workout plan"))
        #expect(planFile.read() == .missing)
        #expect(store.currentGuidedWorkoutPlan == nil)
        #expect(!store.isTodaysGuidedPlanApproved)
        #expect(store.guidedCompletedSessionIDs.isEmpty)
        #expect(store.guidedPlanMemo == GuidedPlanMemo())

        let relaunched = makeStore()
        relaunched.reconcileGuidedRunFromAppGroup()
        #expect(relaunched.currentGuidedWorkoutPlan == nil)
    }

    /// The file is this device's alone: its own folder outside the app group, excluded from backups.
    @Test func theFileStaysOnThisDevice() throws {
        let store = makeStore()
        store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        let values = try planDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        #expect(!GuidedPlanFile.defaultDirectory().path.contains("group."))
        #expect(GuidedPlanFile.defaultDirectory().lastPathComponent == "FernletTodaysPlan")
        #expect(makeTestStore().guidedPlanFile == nil, "a store that is not the launch path's keeps no file")
    }

    private func recorded(_ file: GuidedPlanFile) -> GuidedPlanRecord? {
        if case .record(let record) = file.read() { return record }
        return nil
    }
}

private extension FernletStore {
    /// Stands in for a change made while the app was closed (another device's sync): the active
    /// space moves in the settings before today's plan has been read back.
    func diaryChangingSpaceWithoutThePlan(to id: UUID) {
        setActiveWorkoutLocation(id)
    }
}
