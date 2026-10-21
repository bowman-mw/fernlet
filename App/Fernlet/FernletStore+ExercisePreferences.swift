import Foundation
import FernletDomainModel
import FernletFoundation

/// Exercise preferences and hand-made custom exercises (2026-10-20, idea 15 of the comparison
/// report): "Don't suggest this", "Always use this instead", and the "Add an exercise" form.
///
/// Every write goes through the `settings` forwarder, which schedules the snapshot save, so each
/// change is durable and syncs with the rest of the settings blob. The preferences live in
/// `settings.workoutExercisePreferences` (``WorkoutExercisePreferences``); the custom exercises in
/// `settings.customExercises`, the same list the coach-plan import writes, mirrored into
/// ``WorkoutExerciseCatalog`` (``syncCustomExerciseCatalog()``) after every change so the planner, the
/// safety filter and the log sheet's picker see it at once. The list rules — the cap, the name
/// checks, edit and delete — are ``CustomExerciseLibrary``'s; deleting an exercise never touches a
/// logged workout.
extension FernletStore {

    // MARK: Never suggest

    /// Leaves `name` out of every plan from now on ("Don't suggest this"). Returns false when the
    /// name is unusable or the hidden list is full.
    @discardableResult
    func hideExercise(_ name: String) -> Bool {
        var preferences = settings.workoutExercisePreferences
        guard preferences.hide(name) else { return false }
        guard preferences != settings.workoutExercisePreferences else { return true }
        settings.workoutExercisePreferences = preferences
        return true
    }

    /// Lets the planner suggest `name` again ("Show again").
    func showExerciseAgain(_ name: String) {
        var preferences = settings.workoutExercisePreferences
        preferences.showAgain(name)
        guard preferences != settings.workoutExercisePreferences else { return }
        settings.workoutExercisePreferences = preferences
    }

    // MARK: Saved alternates

    /// Saves `alternate` as the exercise to plan whenever `original` would be picked ("Always use
    /// this instead"). Returns false when a name is unusable or the list is full.
    @discardableResult
    func saveExerciseAlternate(_ alternate: String, for original: String) -> Bool {
        var preferences = settings.workoutExercisePreferences
        guard preferences.setAlternate(alternate, for: original) else { return false }
        guard preferences != settings.workoutExercisePreferences else { return true }
        settings.workoutExercisePreferences = preferences
        return true
    }

    /// Forgets the alternate saved for `original`.
    func removeExerciseAlternate(for original: String) {
        var preferences = settings.workoutExercisePreferences
        preferences.removeAlternate(for: original)
        guard preferences != settings.workoutExercisePreferences else { return }
        settings.workoutExercisePreferences = preferences
    }

    /// Applies the plan editor's pending preferences in one save: the exercises marked "Don't
    /// suggest this" and the swaps marked "Always use this instead" (original → alternate).
    /// A name the lists refuse (unusable, or a full list) is skipped and logged.
    func applyExercisePreferenceEdits(hidden: [String], alternates: [String: String]) {
        guard !hidden.isEmpty || !alternates.isEmpty else { return }
        var preferences = settings.workoutExercisePreferences
        var refused = 0
        for name in hidden.prefix(WorkoutExercisePreferences.maxHidden) {
            if !preferences.hide(name) { refused += 1 }
        }
        for original in alternates.keys.sorted().prefix(WorkoutExercisePreferences.maxAlternates) {
            if !preferences.setAlternate(alternates[original] ?? "", for: original) { refused += 1 }
        }
        if refused > 0 {
            FernletAuditLog.log("workout.preferences.refused", context: ["count": String(refused)])
        }
        guard preferences != settings.workoutExercisePreferences else { return }
        settings.workoutExercisePreferences = preferences
    }

    /// The swap options for `name` in the plan editor: up to four exercises that do the same work
    /// (``WorkoutExerciseSwapOptions``), drawn from what the planner itself may suggest here — the
    /// active location's equipment, the injury limits, nothing hidden (saved or `alsoHidden`, the
    /// editor's pending marks) — and none already in the session (`excluding`). A `harder` variation
    /// the planner offered for a lift at its heaviest load (N7, `LoadGuidance.harderVariation`) comes
    /// first when the same rules allow it.
    func exerciseSwapOptions(
        for name: String, excluding names: Set<String>, alsoHidden: [String] = [], harder: String? = nil
    ) -> [ExerciseTarget] {
        guard let original = WorkoutExerciseCatalog.exercise(named: name) else { return [] }
        var preferences = settings.workoutExercisePreferences
        for pending in alsoHidden.prefix(WorkoutExercisePreferences.maxHidden) { preferences.hide(pending) }
        let hidden = preferences.hiddenKeys
        let pool = WorkoutSafetyFilter.feasibleExercises(
            in: WorkoutExerciseCatalog.allExercises,
            location: settings.activeWorkoutLocation,
            profile: settings.workoutProfile
        ).filter { !hidden.contains(WorkoutExerciseCatalog.normalizedName($0.name)) }
        let options = WorkoutExerciseSwapOptions.options(for: original, in: pool, excluding: names)
        let excluded = Set(names.map(WorkoutExerciseCatalog.normalizedName))
        guard let harder, let first = pool.first(where: {
            WorkoutExerciseCatalog.normalizedName($0.name) == WorkoutExerciseCatalog.normalizedName(harder)
        }), !excluded.contains(WorkoutExerciseCatalog.normalizedName(first.name)) else { return options }
        let rest = options.filter { $0.name != first.name }
        return Array(([first] + rest).prefix(WorkoutExerciseSwapOptions.defaultLimit))
    }

    // MARK: Custom exercises

    /// Adds a hand-made exercise to the user's catalog. Returns the issue that stopped it — nil when
    /// it was added.
    func addCustomExercise(_ draft: CustomExerciseDraft) -> CustomExerciseIssue? {
        let result = CustomExerciseLibrary.adding(
            draft, to: settings.customExercises, base: WorkoutExerciseCatalog.baseExercises)
        switch result {
        case .failure(let issue):
            return issue
        case .success(let list):
            settings.customExercises = list
            syncCustomExerciseCatalog()
            return nil
        }
    }

    /// Saves an edit to the custom exercise named `name`. A rename carries its hidden mark and any
    /// saved swap along; logged workouts keep the name they were logged under. Returns the issue that
    /// stopped it — nil when it was saved.
    func updateCustomExercise(named name: String, with draft: CustomExerciseDraft) -> CustomExerciseIssue? {
        let result = CustomExerciseLibrary.replacing(
            name, with: draft, in: settings.customExercises, base: WorkoutExerciseCatalog.baseExercises)
        switch result {
        case .failure(let issue):
            return issue
        case .success(let list):
            var updated = settings
            updated.customExercises = list
            if WorkoutExerciseCatalog.normalizedName(name) != WorkoutExerciseCatalog.normalizedName(draft.trimmedName) {
                updated.workoutExercisePreferences.renameExercise(from: name, to: draft.trimmedName)
            }
            settings = updated
            syncCustomExerciseCatalog()
            return nil
        }
    }

    /// Deletes the custom exercise named `name` from the catalog, with its hidden mark and any saved
    /// swap that names it. Logged workouts, their history and progression are untouched: they are
    /// lines on the day rows, read by name.
    func deleteCustomExercise(named name: String) {
        guard settings.customExercises.contains(where: {
            WorkoutExerciseCatalog.normalizedName($0.name) == WorkoutExerciseCatalog.normalizedName(name)
        }) else { return }
        var updated = settings
        updated.customExercises = CustomExerciseLibrary.removing(name, from: updated.customExercises)
        updated.workoutExercisePreferences.forgetExercise(named: name)
        settings = updated
        syncCustomExerciseCatalog()
    }
}
