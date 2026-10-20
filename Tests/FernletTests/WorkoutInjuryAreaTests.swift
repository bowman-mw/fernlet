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
        let split = TrainingSplit(id: "probe", name: "Probe", summary: "", specificity: .balanced,
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

    /// The spine areas also leave out a loaded bar's squats, hinges, lunges and carries.
    @Test func severeLowerBackLeavesBarbellSquatsOut() {
        let names = feasibleNames(WorkoutProfile(injuryAreas: [.lowerBack: .severe]))
        #expect(!names.contains("Back squat") && !names.contains("Romanian deadlift"))
        #expect(names.contains("Leg press") && names.contains("Goblet squat"))
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
}
