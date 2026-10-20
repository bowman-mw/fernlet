import Foundation
import Testing
import FernletDomainModel
import AIProviders
@testable import Fernlet

/// Pins idea 15's exercise preferences: "Don't suggest this" keeps an exercise out of every slot,
/// every block and the AI adjuster's candidates, with its own note when it empties a slot; a saved
/// alternate wins only when it is eligible, allowed by the equipment and injury filters, not hidden
/// and no longer under a time budget; a hand-made custom exercise is judged by the safety filter and
/// slot eligibility exactly like a catalog row; the synced settings decode tolerantly at the blob's
/// top level; and the custom list keeps its cap of 500.
///
/// Engine cells pass `catalog:` explicitly, so they never read the process-wide custom registry.
@MainActor
struct WorkoutExercisePreferencesTests {

    // MARK: - Fixtures

    private var base: [ExerciseTarget] { WorkoutExerciseCatalog.baseExercises }

    private func dayPlan(
        _ template: WorkoutSessionTemplate,
        location: WorkoutLocation,
        profile: WorkoutProfile,
        preferences: WorkoutExercisePreferences,
        options: WorkoutSessionOptions,
        catalog: [ExerciseTarget]
    ) -> WorkoutProgram.DayPlan {
        let split = TrainingSplit(id: "probe", name: "Probe", summary: "", specificity: .balanced,
                                  goalFit: [.strength], days: [WorkoutSplitDay(title: "Day", sessions: [template])])
        return WorkoutProgram.dayPlan(
            goal: .strength, intensity: .moderate, profile: profile, location: location, context: "",
            split: split, rotationIndex: 0, options: options, preferences: preferences, catalog: catalog
        )
    }

    /// The common case: full gym, intermediate, no limits, no budget, the bundled catalog.
    private func plan(
        _ template: WorkoutSessionTemplate, preferences: WorkoutExercisePreferences
    ) -> WorkoutProgram.DayPlan {
        dayPlan(template, location: .fullGym, profile: WorkoutProfile(experience: .intermediate),
                preferences: preferences, options: WorkoutSessionOptions(), catalog: base)
    }

    private func lifting(_ plan: WorkoutProgram.DayPlan) -> [String] {
        plan.sessions.flatMap(\.exercises).filter { $0.fromCatalog && $0.block == .lifting }.map(\.name)
    }

    private func everything(_ plan: WorkoutProgram.DayPlan) -> [String] {
        plan.sessions.flatMap(\.exercises).map(\.name)
    }

    private func notes(_ plan: WorkoutProgram.DayPlan) -> String {
        plan.sessions.map(\.suggestion.notes).joined(separator: " · ")
    }

    private func target(_ name: String) throws -> ExerciseTarget {
        try #require(base.first { $0.name == name })
    }

    /// The lifting pick whose catalog row has `pattern` — the slot it filled, by its movement.
    private func pick(_ plan: WorkoutProgram.DayPlan, pattern: MovementPattern) -> String? {
        lifting(plan).first { name in base.first { $0.name == name }?.movementPattern == pattern }
    }

    // MARK: - Never suggest

    /// Hiding every lift a split day picks leaves none of them anywhere in the re-planned day —
    /// warm-up, activation, lifting, cool-down — on every day of three splits.
    @Test func hiddenExercisesAreNeverPlannedOnAnyDay() {
        let profile = WorkoutProfile(experience: .intermediate)
        for split in [WorkoutSplitCatalog.fullBody3, WorkoutSplitCatalog.upperLower4, WorkoutSplitCatalog.ppl3] {
            for day in split.days.indices {
                let before = WorkoutProgram.dayPlan(
                    goal: .strength, intensity: .moderate, profile: profile, location: .fullGym, context: "",
                    split: split, rotationIndex: day, catalog: base
                )
                let picked = Set(lifting(before))
                #expect(!picked.isEmpty)
                let after = WorkoutProgram.dayPlan(
                    goal: .strength, intensity: .moderate, profile: profile, location: .fullGym, context: "",
                    split: split, rotationIndex: day,
                    preferences: WorkoutExercisePreferences(hidden: Array(picked)), catalog: base
                )
                let leaked = Set(everything(after)).intersection(picked)
                #expect(leaked.isEmpty, "\(split.name) day \(day) still plans \(leaked.sorted())")
            }
        }
    }

    /// A hidden lift's slot falls back to the next eligible pick, not to a dropped slot.
    @Test func aHiddenLiftsSlotTakesTheNextEligiblePick() {
        let before = plan(WorkoutSessions.fullBodyA, preferences: WorkoutExercisePreferences())
        #expect(pick(before, pattern: .squat) == "Back squat")
        let after = plan(WorkoutSessions.fullBodyA, preferences: WorkoutExercisePreferences(hidden: ["back SQUAT"]))
        let squat = pick(after, pattern: .squat)
        #expect(squat != nil && squat != "Back squat", "the squat slot should fall back, got \(squat ?? "nothing")")
        #expect(!after.droppedSlots.contains("Squat"))
    }

    /// A hidden stretch leaves the warm-up and the cool-down too.
    @Test func aHiddenStretchLeavesTheStretchBlocks() throws {
        let before = plan(WorkoutSessions.fullBodyA, preferences: WorkoutExercisePreferences())
        let stretch = try #require(before.sessions.flatMap(\.exercises).first { $0.block == .warmUp }?.name)
        let after = plan(WorkoutSessions.fullBodyA, preferences: WorkoutExercisePreferences(hidden: [stretch]))
        #expect(!everything(after).contains(stretch))
        #expect(after.sessions.flatMap(\.exercises).contains { $0.block == .warmUp }, "the rest of the flow stays")
    }

    /// A slot only hidden exercises could fill is dropped with its own note; a slot nothing at all
    /// could fill keeps the "no safe option here" note.
    @Test func aSlotEmptiedByHidingGetsItsOwnNote() {
        let biceps = WorkoutSlotSpec(label: "Biceps", role: .accessory, movement: .isolation, muscles: [.biceps])
        let impossible = WorkoutSlotSpec(label: "Calf carry", role: .accessory, movement: .carry, muscles: [.calves])
        let template = WorkoutSessionTemplate(title: "Probe", kind: .strength, slots: [biceps, impossible])
        let limits = WorkoutProfile(experience: .intermediate).injuryLimits
        let fits = base.filter {
            WorkoutSafetyFilter.feasible($0, location: .fullGym, limits: limits) && WorkoutProgram.isEligible($0, for: biceps)
        }.map(\.name)
        #expect(!fits.isEmpty)

        let result = plan(template, preferences: WorkoutExercisePreferences(hidden: fits))
        #expect(result.droppedSlots.contains("Biceps"))
        #expect(notes(result).contains(WorkoutProgram.hiddenDropNote(["Biceps"])))
        #expect(!notes(result).contains("Skipped Biceps — no safe option here."))
        #expect(notes(result).contains("Skipped Calf carry — no safe option here."))
        #expect(!notes(result).contains(WorkoutProgram.hiddenDropNote(["Calf carry"])))
    }

    /// The AI adjuster never sees a hidden exercise, matched by name in any case or spacing.
    @Test func theAIAdjustersCandidatesSkipHiddenExercises() {
        let open = WorkoutAdjustmentCandidateBuilder.candidates(
            currentNames: ["Bench press"], request: "swap the bench press", location: .fullGym,
            profile: WorkoutProfile(), limit: 500, catalog: base
        ).map(\.exercise.name)
        #expect(open.contains("Bench press") && open.contains("Push-up"))
        let hidden = WorkoutAdjustmentCandidateBuilder.candidates(
            currentNames: ["Bench press"], request: "swap the bench press", location: .fullGym,
            profile: WorkoutProfile(), limit: 500,
            preferences: WorkoutExercisePreferences(hidden: ["Bench press", "push-UP"]), catalog: base
        ).map(\.exercise.name)
        #expect(!hidden.contains("Bench press") && !hidden.contains("Push-up"))
        #expect(hidden.count == open.count - 2)
    }

    // MARK: - Saved alternates

    /// An eligible, allowed alternate replaces the planner's pick — with or without a time budget,
    /// when it takes no longer.
    @Test func anEligibleAlternateReplacesThePick() {
        let preferences = WorkoutExercisePreferences(alternates: ["Back squat": "Goblet squat"])
        let after = plan(WorkoutSessions.fullBodyA, preferences: preferences)
        #expect(pick(after, pattern: .squat) == "Goblet squat")
        #expect(!lifting(after).contains("Back squat"))
        let budgeted = dayPlan(WorkoutSessions.fullBodyA, location: .fullGym,
                               profile: WorkoutProfile(experience: .intermediate), preferences: preferences,
                               options: WorkoutSessionOptions(length: .min60), catalog: base)
        #expect(pick(budgeted, pattern: .squat) == "Goblet squat")
    }

    /// An alternate that cannot fill the slot (a press for a squat) changes nothing.
    @Test func anIneligibleAlternateFallsBackSilently() {
        let before = plan(WorkoutSessions.fullBodyA, preferences: WorkoutExercisePreferences())
        let after = plan(WorkoutSessions.fullBodyA,
                         preferences: WorkoutExercisePreferences(alternates: ["Back squat": "Overhead press"]))
        #expect(lifting(after) == lifting(before))
        #expect(notes(after) == notes(before))
    }

    /// An alternate the location can't equip falls back to the planner's own pick.
    @Test func anAlternateWithoutEquipmentFallsBack() {
        let hotel = WorkoutLocation(name: "Hotel gym",
                                    ownedEquipment: [.treadmill, .exerciseBike, .dumbbells, .weightBench, .cableMachine])
        let profile = WorkoutProfile(experience: .intermediate)
        let before = dayPlan(WorkoutSessions.fullBodyA, location: hotel, profile: profile,
                             preferences: WorkoutExercisePreferences(), options: WorkoutSessionOptions(), catalog: base)
        guard let squat = pick(before, pattern: .squat) else {
            Issue.record("the hotel gym should fill the squat slot")
            return
        }
        let after = dayPlan(WorkoutSessions.fullBodyA, location: hotel, profile: profile,
                            preferences: WorkoutExercisePreferences(alternates: [squat: "Back squat"]),
                            options: WorkoutSessionOptions(), catalog: base)
        #expect(lifting(after) == lifting(before))
        #expect(!lifting(after).contains("Back squat"))
    }

    /// An alternate the injury limits leave out falls back; the same pairing applies without them.
    @Test func anAlternateTheInjuryFilterLeavesOutFallsBack() {
        let hurt = WorkoutProfile(experience: .intermediate, injuryAreas: [.lowerBack: .severe])
        let before = dayPlan(WorkoutSessions.fullBodyA, location: .fullGym, profile: hurt,
                             preferences: WorkoutExercisePreferences(), options: WorkoutSessionOptions(), catalog: base)
        guard let squat = pick(before, pattern: .squat) else {
            Issue.record("a severe lower back should still fill the squat slot")
            return
        }
        let preferences = WorkoutExercisePreferences(alternates: [squat: "Front squat"])
        let after = dayPlan(WorkoutSessions.fullBodyA, location: .fullGym, profile: hurt,
                            preferences: preferences, options: WorkoutSessionOptions(), catalog: base)
        #expect(!everything(after).contains("Front squat"))
        #expect(pick(after, pattern: .squat) == squat)

        let healthy = WorkoutExercisePreferences(alternates: ["Back squat": "Front squat"])
        #expect(pick(plan(WorkoutSessions.fullBodyA, preferences: healthy), pattern: .squat) == "Front squat")
    }

    /// An alternate the user also hid is never planned.
    @Test func aHiddenAlternateFallsBack() {
        let preferences = WorkoutExercisePreferences(hidden: ["Goblet squat"], alternates: ["Back squat": "Goblet squat"])
        let after = plan(WorkoutSessions.fullBodyA, preferences: preferences)
        #expect(pick(after, pattern: .squat) == "Back squat")
        #expect(!everything(after).contains("Goblet squat"))
    }

    /// Under a time budget an alternate whose sets take longer than the pick's (reps after a short
    /// hold) is passed over; with no budget it is used.
    @Test func anAlternateThatRunsLongerIsPassedOverUnderABudget() {
        let hold = ExerciseTarget(name: "Aa probe hold", primaryMuscles: [.abs], equipment: .bodyweight,
                                  movementPattern: .isolation, measure: .seconds)
        let crunch = ExerciseTarget(name: "Zz probe crunch", primaryMuscles: [.abs], equipment: .bodyweight,
                                    movementPattern: .isolation)
        let template = WorkoutSessionTemplate(title: "Probe", kind: .strength, slots: [
            WorkoutSlotSpec(label: "Core", role: .core, muscles: [.abs], region: .core),
        ])
        let preferences = WorkoutExercisePreferences(alternates: [hold.name: crunch.name])
        let profile = WorkoutProfile(experience: .intermediate)
        let activation: (WorkoutProgram.DayPlan) -> [String] = {
            $0.sessions.flatMap(\.exercises).filter { $0.block == .activation }.map(\.name)
        }
        let plain = dayPlan(template, location: .fullGym, profile: profile, preferences: WorkoutExercisePreferences(),
                            options: WorkoutSessionOptions(), catalog: [hold, crunch])
        #expect(activation(plain) == [hold.name], "the tie goes to the hold by name")
        let open = dayPlan(template, location: .fullGym, profile: profile, preferences: preferences,
                           options: WorkoutSessionOptions(), catalog: [hold, crunch])
        #expect(activation(open) == [crunch.name])
        let budgeted = dayPlan(template, location: .fullGym, profile: profile, preferences: preferences,
                               options: WorkoutSessionOptions(length: .min30), catalog: [hold, crunch])
        #expect(activation(budgeted) == [hold.name])
    }

    /// The editor's swap options do the same work, skip the session's exercises and anything hidden,
    /// and stop at four.
    @Test func swapOptionsDoTheSameWork() throws {
        let squat = try target("Back squat")
        let pool = base.filter { !["Leg press"].contains($0.name) }
        let options = WorkoutExerciseSwapOptions.options(for: squat, in: pool, excluding: ["Goblet squat"])
        #expect(!options.isEmpty && options.count <= WorkoutExerciseSwapOptions.defaultLimit)
        for option in options {
            #expect(option.movementPattern == .squat && option.modality == .strength)
            #expect(!option.primaryMuscles.isDisjoint(with: squat.primaryMuscles))
            #expect(!["Back squat", "Goblet squat", "Leg press"].contains(option.name))
        }
        #expect(WorkoutExerciseSwapOptions.options(for: squat, in: pool, limit: 0).isEmpty)
    }

    // MARK: - Custom exercises judged like catalog rows

    /// A custom exercise with a catalog row's fields gets the catalog row's safety verdict at every
    /// location and injury limit — a severe knee leaves it out like the Step-up.
    @Test func aCustomExercisePassesTheSafetyFilterLikeACatalogRow() throws {
        let stepUp = try target("Step-up")
        var draft = CustomExerciseDraft(stepUp)
        draft.name = "Qzx bench step"
        let custom = draft.target
        let park = WorkoutLocation(name: "Park", ownedEquipment: [])
        let profiles = [
            WorkoutProfile(), WorkoutProfile(injuryAreas: [.knee: .severe]),
            WorkoutProfile(injuryAreas: [.knee: .mild]), WorkoutProfile(injuryAreas: [.hip: .severe]),
        ]
        for profile in profiles {
            for location in [WorkoutLocation.fullGym, park] {
                #expect(WorkoutSafetyFilter.feasible(custom, location: location, profile: profile)
                        == WorkoutSafetyFilter.feasible(stepUp, location: location, profile: profile))
            }
        }
        #expect(!WorkoutSafetyFilter.feasible(custom, location: .fullGym, profile: WorkoutProfile(injuryAreas: [.knee: .severe])))
        #expect(WorkoutSafetyFilter.feasible(custom, location: .fullGym, profile: WorkoutProfile()))
    }

    /// A custom exercise fills an eligible slot like any catalog row, and the injury picker's severe
    /// area drops it with the usual note.
    @Test func aCustomExerciseJoinsThePlannersPool() {
        var draft = CustomExerciseDraft()
        draft.name = "Qzx split squat"
        draft.primaryMuscles = [.quads, .glutes]
        draft.movementPattern = .lunge
        draft.equipment = .dumbbell
        let custom = draft.target
        let lunge = WorkoutSlotSpec(label: "Lunge", role: .accessory, movement: .lunge, muscles: [.quads, .glutes])
        #expect(WorkoutProgram.isEligible(custom, for: lunge))
        let template = WorkoutSessionTemplate(title: "Probe", kind: .strength, slots: [lunge])
        let open = dayPlan(template, location: .fullGym, profile: WorkoutProfile(), preferences: WorkoutExercisePreferences(),
                           options: WorkoutSessionOptions(), catalog: [custom])
        #expect(lifting(open) == [custom.name])
        let kneeHurts = dayPlan(template, location: .fullGym, profile: WorkoutProfile(injuryAreas: [.knee: .severe]),
                                preferences: WorkoutExercisePreferences(), options: WorkoutSessionOptions(), catalog: [custom])
        #expect(lifting(kneeHurts).isEmpty)
        #expect(notes(kneeHurts).contains("Skipped Lunge — no safe option here."))

        var cardio = draft
        cardio.modality = .cardio
        #expect(!WorkoutProgram.isEligible(cardio.target, for: lunge), "only strength fills a lifting slot")
    }

    /// The form saves the catalog's exact fields: the plane only for a push or pull, no muscle both
    /// main and other, no tool both main and alternative, and it round-trips through the synced shape.
    @Test func theFormSavesTheCatalogsFields() throws {
        var draft = CustomExerciseDraft()
        draft.name = "  Qzx landmine press  "
        draft.primaryMuscles = [.chest, .frontDelts]
        draft.secondaryMuscles = [.chest, .triceps]
        draft.movementPattern = .squat
        draft.plane = .vertical
        draft.equipment = .barbell
        draft.alternativeEquipment = [.barbell, .dumbbell]
        draft.requiredGear = [.weightBench]
        draft.measure = .seconds
        draft.unilateral = true
        draft.difficulty = .advanced
        draft.modality = .power
        let saved = draft.target
        #expect(saved.name == "Qzx landmine press")
        #expect(saved.plane == nil, "a squat has no plane")
        #expect(saved.secondaryMuscles == [.triceps])
        #expect(saved.alternativeEquipment == [.dumbbell])
        #expect(saved.requiredGear == [.weightBench] && saved.measure == .seconds && saved.unilateral)
        #expect(saved.difficulty == .advanced && saved.modality == .power)
        draft.movementPattern = .push
        #expect(draft.target.plane == .vertical)
        let decoded = try JSONDecoder().decode(ExerciseTarget.self, from: JSONEncoder().encode(draft.target))
        #expect(decoded == draft.target)
        var expected = draft
        expected.name = "Qzx landmine press"
        expected.secondaryMuscles = [.triceps]
        expected.alternativeEquipment = [.dumbbell]
        #expect(CustomExerciseDraft(decoded) == expected, "editing opens on what was saved")
    }

    // MARK: - Validation and the cap

    @Test func customNamesAreChecked() throws {
        var draft = CustomExerciseDraft()
        draft.primaryMuscles = [.chest]
        let mine = [ExerciseTarget(name: "Qzx press", primaryMuscles: [.chest])]
        func issues(_ name: String, editing: String? = nil) -> [CustomExerciseIssue] {
            var named = draft
            named.name = name
            return CustomExerciseLibrary.issues(for: named, existing: mine, base: base, editing: editing)
        }
        #expect(issues("") == [.emptyName])
        #expect(issues("   ") == [.emptyName])
        #expect(issues("bench  PRESS") == [.clashesWithCatalog])
        #expect(issues("qzx PRESS") == [.duplicateName])
        #expect(issues("Qzx press", editing: "Qzx press").isEmpty, "an edit doesn't clash with itself")
        #expect(issues(String(repeating: "q", count: 81)) == [.nameTooLong])
        #expect(issues("Qzx row").isEmpty)
        var noMuscle = draft
        noMuscle.name = "Qzx row"
        noMuscle.primaryMuscles = []
        #expect(CustomExerciseLibrary.issues(for: noMuscle, existing: mine, base: base) == [.noPrimaryMuscle])
    }

    /// One list, one cap: the 501st exercise is refused, an edit at the cap is not, and a blob with
    /// more is cut to 500 on decode.
    @Test func theCustomListKeepsItsCapOf500() throws {
        let full = (0..<WorkoutExerciseCatalog.maxCustomExercises).map {
            ExerciseTarget(name: "Qzx cap \($0)", primaryMuscles: [.abs])
        }
        var draft = CustomExerciseDraft()
        draft.name = "Qzx one more"
        draft.primaryMuscles = [.abs]
        #expect(CustomExerciseLibrary.adding(draft, to: full, base: base) == .failure(.atCapacity))
        #expect(CustomExerciseLibrary.issues(for: draft, existing: full, base: base, editing: "Qzx cap 3")
            .contains(.atCapacity) == false)
        let added = try CustomExerciseLibrary.adding(draft, to: Array(full.dropLast()), base: base).get()
        #expect(added.count == WorkoutExerciseCatalog.maxCustomExercises)

        var settings = FernletSettings()
        settings.customExercises = full + [draft.target]
        let decoded = try JSONDecoder().decode(FernletSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.customExercises.count == WorkoutExerciseCatalog.maxCustomExercises)
    }

    // MARK: - Settings decode compatibility

    private func settings(_ json: String) throws -> FernletSettings {
        try JSONDecoder().decode(FernletSettings.self, from: Data(json.utf8))
    }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    /// The preferences ride the blob's TOP LEVEL, written only when set, and round-trip.
    @Test func preferencesRideTheSettingsTopLevel() throws {
        var original = FernletSettings()
        original.workoutExercisePreferences = WorkoutExercisePreferences(
            hidden: ["Burpee", "Dip"], alternates: ["Back squat": "Goblet squat"])
        let top = try object(original)
        #expect((top["workoutHiddenExercises"] as? [String]) == ["Burpee", "Dip"])
        #expect((top["workoutExerciseAlternates"] as? [String: String]) == ["Back squat": "Goblet squat"])
        let again = try JSONDecoder().decode(FernletSettings.self, from: JSONEncoder().encode(original))
        #expect(again.workoutExercisePreferences == original.workoutExercisePreferences)
        #expect(again.parkedUnknownKeys.isEmpty, "the new keys are known keys, never parked")

        let fresh = try object(FernletSettings())
        #expect(!fresh.keys.contains("workoutHiddenExercises") && !fresh.keys.contains("workoutExerciseAlternates"))
        #expect(try settings(#"{"bottleOz": 24}"#).workoutExercisePreferences.isEmpty)
    }

    /// A shape this build doesn't expect is skipped, never thrown on: non-string entries, blank and
    /// over-long names, duplicates by name, self-pairs, and whole values of the wrong kind.
    @Test func unexpectedShapesDecodeTolerantly() throws {
        let long = String(repeating: "x", count: 81)
        let decoded = try settings("""
        {"workoutHiddenExercises": ["Bench press", 7, {"name": "Row"}, "  ", "bench  PRESS", "\(long)", " Dip "],
         "workoutExerciseAlternates": {"Back squat": "Goblet squat", "Plank": 3, "Dip": "dip", "": "Row"}}
        """)
        #expect(decoded.workoutExercisePreferences.hidden == ["Bench press", "Dip"])
        #expect(decoded.workoutExercisePreferences.alternates == ["Back squat": "Goblet squat"])

        let wrongKinds = try settings(#"{"workoutHiddenExercises": {"a": 1}, "workoutExerciseAlternates": ["x"]}"#)
        #expect(wrongKinds.workoutExercisePreferences.isEmpty)
    }

    /// Both lists are bounded where they enter this build.
    @Test func preferencesAreBounded() throws {
        let names = (0..<700).map { "Qzx hidden \($0)" }
        let pairs = Dictionary(uniqueKeysWithValues: (0..<300).map { ("Qzx from \($0)", "Qzx to \($0)") })
        var settings = FernletSettings()
        settings.workoutExercisePreferences = WorkoutExercisePreferences(hidden: names, alternates: pairs)
        #expect(settings.workoutExercisePreferences.hidden.count == WorkoutExercisePreferences.maxHidden)
        #expect(settings.workoutExercisePreferences.alternates.count == WorkoutExercisePreferences.maxAlternates)
        var preferences = settings.workoutExercisePreferences
        let hidOneMore = preferences.hide("Qzx one too many")
        let pairedOneMore = preferences.setAlternate("Qzx to", for: "Qzx one too many")
        let replaced = preferences.setAlternate("Qzx elsewhere", for: "Qzx from 0")
        #expect(!hidOneMore && !pairedOneMore)
        #expect(replaced, "replacing a pairing needs no room")
    }

    /// Hide, show again, pair, re-pair and un-pair, all by name in any case or spacing.
    @Test func preferencesEditByName() {
        var preferences = WorkoutExercisePreferences()
        let hid = preferences.hide("Dip")
        let hidAgain = preferences.hide("  dip ")
        #expect(hid && hidAgain)
        #expect(preferences.hidden == ["Dip"] && preferences.isHidden("DIP"))
        preferences.showAgain("dip")
        #expect(preferences.hidden.isEmpty)
        let paired = preferences.setAlternate("Goblet squat", for: "Back squat")
        let repaired = preferences.setAlternate("Leg press", for: "back  squat")
        #expect(paired && repaired)
        #expect(preferences.alternates == ["back  squat": "Leg press"])
        #expect(preferences.alternate(for: "Back squat") == "Leg press")
        let selfPaired = preferences.setAlternate("Back squat", for: "Back squat")
        #expect(selfPaired)
        #expect(preferences.alternates.isEmpty, "pairing an exercise with itself clears its pairing")
        let hidBlank = preferences.hide("")
        #expect(!hidBlank)
    }

    // MARK: - Store

    /// Add, rename and delete a custom exercise through the store: the registry follows each step, a
    /// rename carries its hidden mark and swap along, and a delete leaves logged workouts alone.
    @Test func theStoreAddsRenamesAndDeletesCustomExercises() throws {
        let store = makeTestStore()
        var draft = CustomExerciseDraft()
        draft.name = "Qzx sled drag"
        draft.primaryMuscles = [.quads]
        draft.movementPattern = .locomotion
        draft.modality = .cardio
        #expect(store.addCustomExercise(draft) == nil)
        #expect(store.settings.customExercises.map(\.name) == ["Qzx sled drag"])
        #expect(WorkoutExerciseCatalog.customExercises.map(\.name) == ["Qzx sled drag"])
        #expect(store.addCustomExercise(draft) == .duplicateName)

        store.hideExercise("Qzx sled drag")
        store.saveExerciseAlternate("Qzx sled drag", for: "Sled push")
        var renamed = draft
        renamed.name = "Qzx sled pull"
        #expect(store.updateCustomExercise(named: "Qzx sled drag", with: renamed) == nil)
        #expect(store.settings.workoutExercisePreferences.hidden == ["Qzx sled pull"])
        #expect(store.settings.workoutExercisePreferences.alternate(for: "Sled push") == "Qzx sled pull")

        store.addWorkout(Workout(name: "Qzx day", type: .fullBody, exercises: "Qzx sled pull - 3 x 20 s",
                                 rpe: nil, notes: "", duration: 20, intensity: .moderate), date: store.todayKey)
        store.deleteCustomExercise(named: "qzx SLED pull")
        #expect(store.settings.customExercises.isEmpty)
        #expect(WorkoutExerciseCatalog.customExercises.isEmpty)
        #expect(store.settings.workoutExercisePreferences.isEmpty, "its hidden mark and swap go with it")
        #expect(store.day.workouts.contains { $0.name == "Qzx day" && $0.exercises == "Qzx sled pull - 3 x 20 s" },
                "deleting an exercise never deletes a logged workout")
    }

    /// The store refuses a 501st custom exercise, whichever writer filled the list.
    @Test func theStoreRefusesAnExerciseOverTheCap() {
        let store = makeTestStore()
        var full = store.settings
        full.customExercises = (0..<WorkoutExerciseCatalog.maxCustomExercises).map {
            ExerciseTarget(name: "Qzx cap \($0)", primaryMuscles: [.abs], modality: .cardio)
        }
        store.settings = full
        var draft = CustomExerciseDraft()
        draft.name = "Qzx one more"
        draft.primaryMuscles = [.abs]
        #expect(store.addCustomExercise(draft) == .atCapacity)
        #expect(store.settings.customExercises.count == WorkoutExerciseCatalog.maxCustomExercises)
        var cleared = store.settings
        cleared.customExercises = []
        store.settings = cleared
        store.syncCustomExerciseCatalog()
    }

    /// The plan editor's pending marks land in one save.
    @Test func theEditorsPendingPreferencesApplyTogether() {
        let store = makeTestStore()
        store.applyExercisePreferenceEdits(hidden: ["Burpee", "burpee"], alternates: ["Back squat": "Goblet squat"])
        #expect(store.settings.workoutExercisePreferences.hidden == ["Burpee"])
        #expect(store.settings.workoutExercisePreferences.alternates == ["Back squat": "Goblet squat"])
        store.showExerciseAgain("BURPEE")
        store.removeExerciseAlternate(for: "back squat")
        #expect(store.settings.workoutExercisePreferences.isEmpty)
    }

    // MARK: - Plan editor

    /// A row swapped twice pairs the plan's original with the final pick; swapping back pairs nothing.
    @Test func theEditorPairsThePlansOriginalWithTheFinalPick() {
        var edits = GuidedEditorPreferences()
        let row = UUID()
        edits.recordSwap(row: row, from: "Back squat", to: "Goblet squat")
        edits.chooseAlways("Goblet squat", for: edits.swappedFrom[row])
        #expect(edits.alternates == ["Back squat": "Goblet squat"])
        edits.recordSwap(row: row, from: "Goblet squat", to: "Leg press")
        #expect(edits.swappedFrom[row] == "Back squat")
        #expect(edits.alternates.isEmpty, "the 'always' named the exercise that left")
        edits.chooseAlways("Leg press", for: edits.swappedFrom[row])
        edits.undoAlways(for: edits.swappedFrom[row])
        #expect(!edits.hasPending)
        edits.recordSwap(row: row, from: "Leg press", to: "back squat")
        #expect(edits.swappedFrom[row] == nil)

        edits.hide("Dip")
        #expect(edits.hiddenState(of: "dip", saved: WorkoutExercisePreferences()) == .pending)
        #expect(edits.hiddenState(of: "Burpee", saved: WorkoutExercisePreferences(hidden: ["Burpee"])) == .saved)
        edits.undoHide("DIP")
        #expect(edits.hiddenState(of: "Dip", saved: WorkoutExercisePreferences()) == .suggested)
    }

    /// A swap keeps the row's slot, sets and rest, turns reps into a hold for a timed exercise (and
    /// back), and drops the old lift's load guidance.
    @Test func aSwappedRowKeepsItsPrescription() throws {
        var row = PrescribedExercise(name: "Dead bug", sets: 3, reps: "10-12", role: .core, fromCatalog: true,
                                     restSecondsOverride: 40,
                                     guidance: LoadGuidance(targetReps: 10, equipment: nil, unit: .lb))
        let plank = try target("Plank")
        let timed = GuidedWorkoutEditorSheet.swapped(row, to: plank, goal: .strength)
        #expect(timed.id == row.id && timed.name == "Plank" && timed.sets == 3 && timed.role == .core)
        #expect(timed.restSecondsOverride == 40 && timed.guidance == nil)
        #expect(timed.holdSeconds != nil && timed.reps == PrescribedExercise.holdText(seconds: timed.holdSeconds ?? 0))
        row = timed
        let back = GuidedWorkoutEditorSheet.swapped(row, to: try target("Dead bug"), goal: .strength)
        #expect(back.holdSeconds == nil && !back.reps.hasSuffix(" s"))
    }
}
