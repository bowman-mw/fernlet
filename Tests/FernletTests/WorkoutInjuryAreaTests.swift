import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Pins the structured injury input: the body areas and severities (frozen tokens, tolerant parked
/// decoding a newer build's values survive), what mild and severe do to the plan, how the picker,
/// the note and the older avoided sets combine (``InjuryLimits``), and the setup sheet's open and
/// save rules (``WorkoutInjuryDraft``).
@MainActor
struct WorkoutInjuryAreaTests {

    // MARK: - Fixtures

    func settings(_ json: String) throws -> FernletSettings {
        try JSONDecoder().decode(FernletSettings.self, from: Data(json.utf8))
    }

    func resaved(_ settings: FernletSettings) throws -> FernletSettings {
        try JSONDecoder().decode(FernletSettings.self, from: JSONEncoder().encode(settings))
    }

    func object(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    func feasibleNames(_ profile: WorkoutProfile) -> Set<String> {
        Set(WorkoutSafetyFilter.feasibleExercises(
            in: WorkoutExerciseCatalog.baseExercises, location: .fullGym, profile: profile
        ).map(\.name))
    }

    func session(_ template: WorkoutSessionTemplate, profile: WorkoutProfile) throws -> WorkoutProgram.SessionSuggestion {
        let split = TrainingSplit(id: "probe", name: "Probe", specificity: .balanced,
                                  goalFit: [.strength], days: [WorkoutSplitDay(title: "Day", sessions: [template])])
        return try #require(WorkoutProgram.dayPlan(
            goal: .strength, intensity: .moderate, profile: profile, location: .fullGym,
            context: "", split: split, rotationIndex: 0
        ).sessions.first)
    }

    func lifting(_ session: WorkoutProgram.SessionSuggestion) -> [PrescribedExercise] {
        session.exercises.filter { $0.block == .lifting && $0.fromCatalog }
    }

    func target(_ name: String) throws -> ExerciseTarget {
        try #require(WorkoutExerciseCatalog.exercise(named: name))
    }

    // MARK: - Tokens

    /// The raw values persist in the synced profile; renaming one drops a limit on decode.
    @Test func frozenBodyAreaAndSeverityTokens() {
        #expect(BodyArea.allCases.map(\.rawValue) == [
            "neck", "shoulder", "elbow", "wristHand", "upperBack", "lowerBack", "hip", "knee", "ankleFoot",
        ])
        #expect(InjurySeverity.allCases.map(\.rawValue) == ["mild", "severe"])
    }

    /// The six areas the old chips covered keep the chips' exact maps, so an older build's saved
    /// limit reads back as the same area.
    @Test func chipAreasKeepTheOldChipMaps() {
        #expect(BodyArea.shoulder.muscles == [.frontDelts, .sideDelts, .rearDelts] && BodyArea.shoulder.movements == [.push])
        #expect(BodyArea.knee.muscles == [.quads, .hamstrings] && BodyArea.knee.movements == [.squat, .lunge])
        #expect(BodyArea.lowerBack.muscles == [.lowerBack] && BodyArea.lowerBack.movements == [.hinge])
        #expect(BodyArea.elbow.muscles == [.biceps, .triceps] && BodyArea.elbow.movements.isEmpty)
        #expect(BodyArea.wristHand.muscles == [.forearms] && BodyArea.wristHand.movements.isEmpty)
        #expect(BodyArea.hip.muscles == [.glutes, .adductors, .abductors] && BodyArea.hip.movements.isEmpty)
        #expect(Set(BodyArea.allCases.filter(\.hadSetupChip)) == [.shoulder, .elbow, .wristHand, .lowerBack, .hip, .knee])
    }

    // MARK: - Decoding

    /// The areas ride at the settings blob's TOP LEVEL, where an older build's key parking keeps
    /// them through a re-save; the nested profile keeps the shape older builds wrote.
    @Test func areasRideAtTheSettingsTopLevelAndRoundTrip() throws {
        var original = FernletSettings()
        original.workoutProfile.injuryAreas = [.knee: .mild, .lowerBack: .severe]
        let top = try object(original)
        #expect((top["workoutInjuryAreas"] as? [String: String]) == ["knee": "mild", "lowerBack": "severe"])
        #expect(!top.keys.contains("unknownWorkoutInjuryAreaTokens"), "nothing parked, nothing written")
        let nested = try #require(top["workoutProfile"] as? [String: Any])
        #expect(!nested.keys.contains("injuryAreaTokens") && !nested.keys.contains("unknownInjuryAreaTokens"))
        let profileOnly = try object(original.workoutProfile)
        #expect(!profileOnly.keys.contains("injuryAreaTokens"))

        let again = try resaved(original)
        #expect(again.workoutProfile.injuryAreas == [.knee: .mild, .lowerBack: .severe])
        #expect(again.workoutProfile == original.workoutProfile)
        #expect(again.parkedUnknownKeys.isEmpty, "the new keys are known keys, never parked")

        let fresh = try object(FernletSettings())
        #expect(!fresh.keys.contains("workoutInjuryAreas"), "a blob without areas keeps its old shape")
        #expect(try settings(#"{"bottleOz": 24}"#).workoutProfile.injuryAreas.isEmpty)
    }

    /// A newer build's area and a newer severity park instead of failing the decode or vanishing on
    /// a re-save; the unknown severity reads as severe meanwhile (the safe direction).
    @Test func unknownAreasAndSeveritiesParkAndSurviveAReSave() throws {
        let decoded = try settings(#"{"workoutInjuryAreas": {"knee": "mild", "jaw": "severe", "hip": "moderate"}}"#)
        #expect(decoded.workoutProfile.injuryAreas == [.knee: .mild, .hip: .severe])
        #expect(decoded.workoutProfile.unknownInjuryAreaTokens == ["jaw": "severe", "hip": "moderate"])
        let top = try object(decoded)
        #expect((top["unknownWorkoutInjuryAreaTokens"] as? [String: String]) == ["jaw": "severe", "hip": "moderate"])
        #expect((top["workoutInjuryAreas"] as? [String: String]) == ["knee": "mild", "hip": "severe"])

        let again = try resaved(decoded)
        #expect(again.workoutProfile.injuryAreas == [.knee: .mild, .hip: .severe])
        #expect(again.workoutProfile.unknownInjuryAreaTokens == ["jaw": "severe", "hip": "moderate"])

        var edited = again.workoutProfile
        edited.injuryAreas[.hip] = .mild
        #expect(edited.unknownInjuryAreaTokens == ["jaw": "severe"], "the local edit wins over the parked severity")
        edited.injuryAreas[.knee] = nil
        #expect(edited.unknownInjuryAreaTokens == ["jaw": "severe"], "a newer build's area is never cleared here")
    }

    /// A build that knows a parked severity adopts it and clears the channel.
    @Test func aKnownParkedSeverityIsReadopted() throws {
        let decoded = try settings(#"{"workoutInjuryAreas": {"knee": "severe"}, "unknownWorkoutInjuryAreaTokens": {"knee": "mild"}}"#)
        #expect(decoded.workoutProfile.injuryAreas == [.knee: .mild])
        #expect(decoded.workoutProfile.unknownInjuryAreaTokens.isEmpty)
    }

    // MARK: - What severity does

    /// Severe leaves the area's work out entirely — the old chip's behaviour.
    @Test func severeKneeLeavesSquatsAndLungesOut() throws {
        let profile = WorkoutProfile(experience: .intermediate, injuryAreas: [.knee: .severe])
        let names = feasibleNames(profile)
        #expect(!names.contains("Leg press") && !names.contains("Goblet squat") && !names.contains("Low lunge stretch"))
        let lower = try session(WorkoutSessions.lower, profile: profile)
        for step in lifting(lower) {
            let lift = try target(step.name)
            #expect(lift.movementPattern != .squat && lift.movementPattern != .lunge, "\(step.name)")
            #expect(lift.primaryMuscles.union(lift.secondaryMuscles).isDisjoint(with: [.quads, .hamstrings]), "\(step.name)")
        }
    }

    /// Mild keeps training around it: no barbell, advanced or jumping work for the knee, the
    /// supported machine wins the squat slot, and the main lift is prescribed as accessory work.
    @Test func mildKneeTrainsAroundItLighterAndSupported() throws {
        let profile = WorkoutProfile(experience: .intermediate, injuryAreas: [.knee: .mild])
        let names = feasibleNames(profile)
        #expect(!names.contains("Back squat") && !names.contains("Front squat") && !names.contains("Squat jump"))
        #expect(names.contains("Leg press") && names.contains("Goblet squat") && names.contains("Low lunge stretch"))
        #expect(names.contains("Hip thrust"), "a barbell lift that doesn't load the knee stays")

        let lower = try session(WorkoutSessions.lower, profile: profile)
        let squat = try #require(lifting(lower).first)
        #expect(squat.name == "Leg press")
        let style = WorkoutGoalStyle.style(for: .strength, energy: .moderate, sport: "")
        #expect(squat.reps == style.accessoryReps, "the knee's main lift takes the higher, lighter rep range")
        #expect(squat.sets == style.adjustedSets(for: .accessory, energy: .moderate))
        #expect(lower.exercises.contains { $0.block == .warmUp && $0.name == "Low lunge stretch" }, "stretches stay")
    }

    /// The spine areas also leave out a loaded bar's squats, hinges, lunges and carries — and, by
    /// the reviewed area-load records (2026-11-10), a weight carried in front of the spine: the
    /// goblet squat this test used to keep. The back-supported leg press stays.
    @Test func severeLowerBackLeavesBarbellSquatsOut() {
        let names = feasibleNames(WorkoutProfile(injuryAreas: [.lowerBack: .severe]))
        #expect(!names.contains("Back squat") && !names.contains("Romanian deadlift") && !names.contains("Goblet squat"))
        #expect(names.contains("Leg press") && names.contains("Leg extension"))
        #expect(feasibleNames(WorkoutProfile(injuryAreas: [.lowerBack: .mild])).contains("Goblet squat"))
        // The old Lower back chip (avoided sets only) now reads as the same area.
        let legacy = WorkoutProfile(avoidedMuscles: [.lowerBack], avoidedMovements: [.hinge])
        #expect(legacy.injuryLimits.severeAreas == [.lowerBack])
        #expect(!feasibleNames(legacy).contains("Back squat"))
    }

    // MARK: - How the inputs combine

    /// The picker wins for an area it names; the note still covers what the picker leaves alone.
    @Test func thePickerWinsOverTheNoteForItsAreas() {
        let profile = WorkoutProfile(injuryNotes: "bad knee and a sore neck", injuryAreas: [.knee: .mild])
        let limits = profile.injuryLimits
        #expect(limits.mildAreas == [.knee])
        #expect(limits.severeAreas == [.neck])
        #expect(feasibleNames(profile).contains("Leg press"))
        #expect(!feasibleNames(profile).contains("Shrug"))
    }

    // MARK: - The setup sheet's draft

    /// An older build's chips open as severe areas; the one chip no area covers stays a chip.
    @Test func olderChipsOpenAsSevereAreas() {
        let profile = WorkoutProfile(avoidedMuscles: [.quads, .hamstrings, .chest], avoidedMovements: [.squat, .lunge])
        let draft = WorkoutInjuryDraft(profile: profile)
        #expect(draft.areas == [.knee: .severe])
        #expect(draft.restedMuscles == [.chest])
    }

    /// An area the note names is left to the note, and the section lists it.
    @Test func noteAreasAreNotCopiedIntoThePicker() {
        let profile = WorkoutProfile.fromOnboarding(level: "beginner", interests: "", constraints: "bad knee")
        let draft = WorkoutInjuryDraft(profile: profile)
        #expect(draft.areas.isEmpty)
        #expect(draft.restedMuscles.isEmpty)
        #expect(WorkoutInjuryDraft.noteOnlyAreas(note: profile.injuryNotes, areas: draft.areas) == [.knee])
        #expect(WorkoutInjuryDraft.noteOnlyAreas(note: profile.injuryNotes, areas: [.knee: .mild]).isEmpty)
    }

    /// Saving mirrors everything severe into the avoided sets an older build reads, never the mild
    /// areas, and reopening reads the same draft back.
    @Test func savingMirrorsSevereForOlderBuildsAndRoundTrips() {
        let draft = WorkoutInjuryDraft(areas: [.knee: .mild, .lowerBack: .severe], restedMuscles: [.chest])
        let saved = draft.applied(to: WorkoutProfile(injuryNotes: "stiff neck"))
        #expect(saved.injuryAreas == [.knee: .mild, .lowerBack: .severe])
        #expect(saved.avoidedMuscles == [.lowerBack, .chest, .traps])
        #expect(saved.avoidedMovements == [.hinge, .carry])
        #expect(WorkoutInjuryDraft(profile: saved) == draft)
        #expect(saved.injuryLimits.mildAreas == [.knee])
        #expect(saved.injuryLimits.severeAreas == [.lowerBack, .neck])
    }

    // MARK: - The coach-plan gate

    /// A pasted coach plan meets the same limits as the app's own plans.
    @Test func coachPlanFlagsFollowTheCombinedLimits() throws {
        let squat = try target("Back squat")
        let note = WorkoutProfile(injuryNotes: "sore knees").injuryLimits
        #expect(FernletStore.injuryReasons(for: squat, limits: note).contains { $0.contains("resting") })
        let mild = WorkoutProfile(injuryAreas: [.knee: .mild]).injuryLimits
        #expect(FernletStore.injuryReasons(for: squat, limits: mild).contains { $0.contains("heavily") })
        #expect(FernletStore.injuryReasons(for: try target("Leg press"), limits: mild).isEmpty)
        #expect(FernletStore.injuryReasons(for: squat, limits: InjuryLimits.empty).isEmpty)
    }


    // MARK: - Mild easing reaches lightly loaded lifts (2026-11-10)

    /// A mild area eases every kept lift its reviewed record says it loads, not only the ones the
    /// muscle rules catch: for every area, each allowed exercise recorded as loading it is eased.
    @Test func aMildAreaEasesEveryKeptLiftItsRecordNames() throws {
        for area in BodyArea.allCases {
            let limits = InjuryLimits(mildAreas: [area])
            for row in WorkoutExerciseCatalog.baseExercises where limits.allows(row) {
                let loads = try #require(WorkoutExerciseCatalog.areaLoads(for: row), "\(row.name)")
                guard loads.load(on: area) != nil else { continue }
                #expect(loads.load(on: area) == .light, "\(row.name) is kept for a mild \(area.rawValue)")
                #expect(limits.eases(row), "\(row.name) loads a mild \(area.rawValue) and is not eased")
            }
        }
        // An exercise with no record is eased by the muscle and pattern rules alone.
        let custom = ExerciseTarget(name: "Coach's wrist roller", primaryMuscles: [.forearms], equipment: .dumbbell)
        #expect(InjuryLimits(mildAreas: [.wristHand]).eases(custom))
        #expect(!InjuryLimits(mildAreas: [.knee]).eases(custom))
    }

    /// A mild wrist: an Upper day's main lifts grip a bar or handle, which the muscle rules never
    /// saw. Each is now prescribed as accessory work — the lighter, higher rep range and never a
    /// main lift, so the load pass cannot calibrate or max-test it.
    @Test func aMildWristPrescribesGrippedMainLiftsAsAccessoryWork() throws {
        let profile = WorkoutProfile(experience: .intermediate, injuryAreas: [.wristHand: .mild])
        let upper = try session(WorkoutSessions.upper, profile: profile)
        let style = WorkoutGoalStyle.style(for: .strength, energy: .moderate, sport: "")
        var eased = 0
        for step in lifting(upper) {
            let row = try target(step.name)
            guard WorkoutExerciseCatalog.areaLoads(for: row)?.load(on: .wristHand) != nil else { continue }
            eased += 1
            #expect(step.role != .main, "\(step.name) stayed a main lift")
            #expect(step.reps == style.accessoryReps, "\(step.name): \(step.reps)")
        }
        #expect(eased >= 3, "the Upper day's gripped lifts are the ones eased")
        // With no limit the same day keeps its main lifts.
        let usual = try session(WorkoutSessions.upper, profile: WorkoutProfile(experience: .intermediate))
        #expect(lifting(usual).contains { $0.role == .main && $0.reps == style.mainReps })
    }


    // MARK: - "No longer an issue" (the owner's fix s5, 2026-11-10)

    private func eased(_ profile: WorkoutProfile, _ areas: [BodyArea: String]) -> WorkoutProfile {
        var copy = profile
        copy.setInjuryEasing(areas)
        return copy
    }

    /// The switch gives a severe area the Mild treatment, and the two weeks start at the first
    /// workout logged after it is turned on, not at the tap: fourteen days of mild, then no limit.
    @Test func theSwitchEasesForTwoWeeksFromTheNextWorkoutThenLiftsTheLimit() throws {
        var profile = eased(WorkoutProfile(experience: .intermediate, injuryAreas: [.knee: .severe]),
                            [.knee: InjuryEasing.pendingToken])
        #expect(InjuryEasing.days == 14 && InjuryEasing.pendingToken == "pending")
        // Waiting for a workout: mild for as long as it takes, however many days pass.
        for day in ["2026-11-10", "2026-12-31"] {
            let waiting = profile.injuryLimits(onDayKey: day)
            #expect(waiting.severeAreas.isEmpty && waiting.mildAreas == [.knee], "\(day)")
        }
        let started = profile.startInjuryEasing(onDayKey: "2026-11-12")
        #expect(started)
        #expect(profile.injuryEasing == [.knee: "2026-11-12"])
        let restarted = profile.startInjuryEasing(onDayKey: "2026-11-20")
        #expect(!restarted, "a second workout does not restart the clock")
        #expect(profile.injuryEasing == [.knee: "2026-11-12"])
        for day in ["2026-11-12", "2026-11-18", "2026-11-25"] {
            #expect(profile.injuryLimits(onDayKey: day).mildAreas == [.knee], "\(day)")
            #expect(profile.injuryLimits(onDayKey: day).severeAreas.isEmpty, "\(day)")
        }
        #expect(profile.injuryLimits(onDayKey: "2026-11-26").isEmpty, "back to normal by itself")
        #expect(profile.injuryLimits(onDayKey: "2027-03-01").isEmpty)
        #expect(profile.injuryAreas == [.knee: .severe], "an older build still reads the stored severity")

        // The Mild treatment is the planner's: no barbell squat, the supported press, eased prescription.
        let mild = profile.injuryLimits(onDayKey: "2026-11-18")
        let backSquat = try target("Back squat")
        let legPress = try target("Leg press")
        #expect(!mild.allows(backSquat) && mild.allows(legPress))
        #expect(mild.eases(legPress))
        // Turning the switch off puts the area back exactly as the picker has it.
        profile.setInjuryEasing([:])
        #expect(profile.injuryLimits(onDayKey: "2026-11-18").severeAreas == [.knee])
    }

    /// A limit that came from the free-text note stops applying, the note's text is untouched, and
    /// the section can say so; so does one an older build mirrored into the avoided sets.
    @Test func theSwitchEndsALimitFromTheNoteAndFromOlderSets() {
        let noted = WorkoutProfile(injuryNotes: "bad knee, sore shoulder")
        #expect(noted.injuryLimits(onDayKey: "2026-11-10").severeAreas == [.knee, .shoulder])
        var switched = eased(noted, [.knee: InjuryEasing.pendingToken])
        #expect(switched.injuryNotes == "bad knee, sore shoulder")
        #expect(switched.injuryLimits(onDayKey: "2026-11-10").severeAreas == [.shoulder])
        #expect(switched.injuryLimits(onDayKey: "2026-11-10").mildAreas == [.knee])
        switched.startInjuryEasing(onDayKey: "2026-11-10")
        let after = switched.injuryLimits(onDayKey: "2026-12-01")
        #expect(after.severeAreas == [.shoulder] && after.mildAreas.isEmpty, "the note does not start applying again")
        #expect(WorkoutInjuryDraft.noteAreasNoLongerApplied(note: noted.injuryNotes, easing: switched.injuryEasing) == [.knee])
        #expect(WorkoutInjuryDraft.noteOnlyAreas(note: noted.injuryNotes, areas: [:], easing: switched.injuryEasing) == [.shoulder])

        // The old Knees chip: avoided sets only. Switched and healed, nothing of it is left.
        var chip = WorkoutProfile(avoidedMuscles: [.quads, .hamstrings, .chest], avoidedMovements: [.squat, .lunge])
        #expect(chip.injuryLimits(onDayKey: "2026-11-10").severeAreas == [.knee])
        chip.setInjuryEasing([.knee: "2026-10-01"])
        let healed = chip.injuryLimits(onDayKey: "2026-11-10")
        #expect(healed.severeAreas.isEmpty && healed.mildAreas.isEmpty && healed.avoidedMovements.isEmpty)
        #expect(healed.avoidedMuscles == [.chest], "a muscle rested on its own stays rested")
    }

    /// The stored shape: optional, at the settings blob's top level, absent until a switch is on,
    /// decoded from a blob that has never heard of it, and carried verbatim for a newer build.
    @Test func theSwitchRidesTheSettingsTopLevelAndOlderBlobsDecode() throws {
        let old = try settings(#"{"workoutInjuryAreas": {"knee": "severe"}}"#)
        #expect(old.workoutProfile.injuryEasingTokens.isEmpty)
        let oldTop = try object(old)
        #expect(!oldTop.keys.contains("workoutInjuryEasing"), "nothing switched, nothing written")

        var current = FernletSettings()
        current.workoutProfile.injuryAreas = [.knee: .severe]
        current.workoutProfile.setInjuryEasing([.knee: InjuryEasing.pendingToken])
        let top = try object(current)
        #expect((top["workoutInjuryEasing"] as? [String: String]) == ["knee": "pending"])
        let nested = try #require(top["workoutProfile"] as? [String: Any])
        #expect(!nested.keys.contains("injuryEasingTokens"), "an older build re-saving the profile cannot drop it")
        let again = try resaved(current)
        #expect(again.workoutProfile == current.workoutProfile)

        // A newer build's area and value survive a save here; an unreadable value reads as easing.
        let newer = try settings(#"{"workoutInjuryEasing": {"jaw": "pending", "knee": "stage-2", "hip": "2026-11-01"}}"#)
        #expect(newer.workoutProfile.injuryLimits(onDayKey: "2026-12-25").mildAreas == [.knee])
        var touched = newer
        touched.workoutProfile.setInjuryEasing([.knee: "stage-2", .hip: "2026-11-01", .elbow: InjuryEasing.pendingToken])
        let touchedTop = try object(touched)
        #expect((touchedTop["workoutInjuryEasing"] as? [String: String])
                == ["jaw": "pending", "knee": "stage-2", "hip": "2026-11-01", "elbow": "pending"])
        // A hostile blob is bounded.
        let many = (0..<200).map { #""a\#($0)": "pending""# }.joined(separator: ",")
        let bounded = try settings("{\"workoutInjuryEasing\": {\(many)}}")
        #expect(bounded.workoutProfile.injuryEasingTokens.count == InjuryEasing.maxEntries)
    }

    /// The setup sheet's side: the switch is offered where there is a limit to end, choosing a
    /// severity again turns it off, a switched area is not mirrored for older builds, and an area
    /// whose two weeks are over opens as None.
    @Test func theSetupSheetOpensSavesAndTidiesTheSwitch() {
        let profile = WorkoutProfile(injuryNotes: "tweaked my shoulder", injuryAreas: [.knee: .severe, .hip: .mild])
        var draft = WorkoutInjuryDraft(profile: profile, todayKey: "2026-11-10")
        #expect(draft.offersNoLongerAnIssue(.knee, note: profile.injuryNotes))
        #expect(draft.offersNoLongerAnIssue(.shoulder, note: profile.injuryNotes), "a note's area can be ended too")
        #expect(!draft.offersNoLongerAnIssue(.elbow, note: profile.injuryNotes))
        draft.setNoLongerAnIssue(true, for: .knee)
        draft.setNoLongerAnIssue(true, for: .shoulder)
        #expect(draft.isNoLongerAnIssue(.knee) && draft.easing[.knee] == InjuryEasing.pendingToken)

        var saved = draft.applied(to: profile)
        #expect(saved.injuryEasing == [.knee: "pending", .shoulder: "pending"])
        #expect(saved.avoidedMuscles.isDisjoint(with: BodyArea.knee.muscles.union(BodyArea.shoulder.muscles)))
        #expect(saved.avoidedMovements.isEmpty)
        #expect(saved.injuryLimits(onDayKey: "2026-11-10").mildAreas == [.knee, .hip, .shoulder])
        #expect(WorkoutInjuryDraft(profile: saved, todayKey: "2026-11-10") == draft, "the sheet reopens on what it saved")

        // A started switch keeps its day through a reopen and save.
        saved.startInjuryEasing(onDayKey: "2026-11-11")
        var reopened = WorkoutInjuryDraft(profile: saved, todayKey: "2026-11-15")
        reopened.setNoLongerAnIssue(true, for: .knee)
        #expect(reopened.applied(to: saved).injuryEasing[.knee] == "2026-11-11")
        // Hurt again: a severity chosen by hand turns the switch off.
        reopened.setSeverity(.mild, for: .knee)
        #expect(!reopened.isNoLongerAnIssue(.knee) && reopened.areas[.knee] == .mild)
        reopened.setSeverity(.mild, for: .knee)
        #expect(reopened.areas[.knee] == .mild)

        // Two weeks on: the knee opens as None with nothing stored; the shoulder's token stays
        // because the note still names it.
        let later = WorkoutInjuryDraft(profile: saved, todayKey: "2026-12-01")
        #expect(later.areas == [.hip: .mild] && later.easing == [.shoulder: "2026-11-11"])
        let tidied = later.applied(to: saved)
        #expect(tidied.injuryAreas == [.hip: .mild] && tidied.injuryEasing == [.shoulder: "2026-11-11"])
        #expect(tidied.injuryLimits(onDayKey: "2026-12-01").severeAreas.isEmpty)
    }

    /// The store starts the clock at the first workout logged after the switch goes on — never
    /// before today, even for a back-dated log — and leaves it alone after that.
    @Test func loggingAWorkoutStartsTheTwoWeeks() throws {
        let store = makeTestStore()
        var profile = WorkoutProfile(injuryAreas: [.knee: .severe])
        profile.setInjuryEasing([.knee: InjuryEasing.pendingToken])
        store.setWorkoutProfile(profile)
        #expect(store.settings.workoutProfile.injuryEasing == [.knee: "pending"], "turning it on starts nothing")
        let walk = Workout(name: "Walk", type: .cardio, exercises: "", rpe: nil, notes: "", duration: 20, intensity: .light)
        store.addWorkout(walk, date: "2020-01-01")
        #expect(store.settings.workoutProfile.injuryEasing == [.knee: store.todayKey])
        store.addWorkout(walk)
        #expect(store.settings.workoutProfile.injuryEasing == [.knee: store.todayKey])
        #expect(store.settings.workoutProfile.injuryLimits(onDayKey: store.todayKey).mildAreas == [.knee])
    }
}
