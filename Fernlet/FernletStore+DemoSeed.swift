//
//  FernletStore+DemoSeed.swift
//  Fernlet
//
//  DEBUG-only demo seeding for the UX *appearance* UI tests. Populates today's diary
//  with a small, realistic set of entries so Home/Food/Move/Private render populated
//  cards (not empty states) and the companion reads as thriving — the state a reviewer
//  actually needs to see when checking that screens look right.
//
//  S3 wall: this lives in the APP TARGET as a FernletStore extension. FernletStore is
//  the legitimate integration point above the module wall (FernletStore.swift already
//  imports the walled + sealed modules), so this adds no new cross-wall import. It
//  touches only facade methods, the in-module `diary` write seam, and FernletDomainModel
//  value types — never a Private* sealed store, ColumnCrypto, AIProviders or CloudKitSync
//  directly. Journal text is sealed through the existing JournalSealingCoordinator, which
//  falls back to the device journal key under the fresh-simulator `.notConfigured` lock,
//  so seeded journals persist and display without a user passcode. Cycle/intimacy
//  narratives are deliberately NOT seeded: they require an unlocked user content key.
//

#if DEBUG
import Foundation
import FernletDomainModel
import DiaryStore

extension FernletStore {
    /// Populate today's diary with representative demo content. Invoked from
    /// ContentView's launch task when `UITestSupport.shouldSeedDemoContent` is set.
    ///
    /// Idempotent for a launch: bails if today's meals/workouts/journals already exist
    /// so repeated launches against the same simulator don't stack duplicates.
    @MainActor
    func seedDemoContent() {
        guard day.meals.isEmpty, day.workouts.isEmpty, previousJournals.isEmpty else { return }

        // Ensure the (age-gated) Intimacy section is reachable for appearance review.
        if settings.userProfile.age < 18 { settings.userProfile.age = 30 }

        seedMeals()
        seedHydrationAndSleep()
        seedJournals()
        seedWorkout()
        seedHygiene()
        seedMemories()

        // One flush so a test reading persistence immediately after launch sees the data.
        flushPendingSnapshotSave()
    }

    // MARK: - Food

    private func seedMeals() {
        // Build Meal values directly (rather than addMeal(from:)) so macros are
        // guaranteed non-zero and the Food cards render real numbers.
        let meals = [
            Meal(
                name: "Greek yogurt with berries", mealType: .breakfast,
                macros: Macros(protein: 28, carbs: 34, fat: 9),
                mealSource: .manual, isAIFallback: false, quality: .good,
                confidence: "Logged", note: "Seeded demo meal.", source: "manual"
            ),
            Meal(
                name: "Chicken rice bowl", mealType: .lunch,
                macros: Macros(protein: 42, carbs: 58, fat: 14),
                mealSource: .manual, isAIFallback: false, quality: .good,
                confidence: "Logged", note: "Seeded demo meal.", source: "manual"
            ),
            Meal(
                name: "Apple and almonds", mealType: .snack,
                macros: Macros(protein: 6, carbs: 22, fat: 12),
                mealSource: .manual, isAIFallback: false, quality: .ok,
                confidence: "Logged", note: "Seeded demo meal.", source: "manual"
            ),
        ]
        for meal in meals {
            diary.appendMeal(meal, date: todayKey)
        }
    }

    // MARK: - Home (hydration + sleep drive the companion mood)

    private func seedHydrationAndSleep() {
        for _ in 0..<6 { addBottle() }
        setSleep(hours: 8.0, quality: .great, note: "Rested.")
    }

    // MARK: - Private / Journal (sealed via the no-lock device key)

    private func seedJournals() {
        addJournal(text: "Felt steady and focused today. A calm, good kind of day.", tag: .good)
        addJournal(text: "Quiet evening, grateful for the small wins this week.", tag: .bright)
    }

    // MARK: - Move

    private func seedWorkout() {
        let workout = Workout(
            name: "Upper body strength", type: .upper, mode: .strengthTraining,
            exercises: "Bench press 3x8\nRows 3x10\nOverhead press 3x8",
            rpe: 7, notes: "Seeded demo workout.", duration: 45,
            muscleGroups: [], intensity: .moderate
        )
        addWorkout(workout, date: todayKey)
    }

    // MARK: - Home (personal-care / hygiene)

    private func seedHygiene() {
        toggleHygiene(.teethAM)
        toggleHygiene(.shower)
    }

    // MARK: - Memories (plain synced notes; companion context)

    private func seedMemories() {
        memories.append(MemoryNote(category: "good", text: "Enjoys morning walks and steady routines."))
        memories.append(MemoryNote(category: "bright", text: "Cooking at home felt rewarding this week."))
        memories.append(MemoryNote(category: "note", text: "Prefers gentle, consistent care over streaks."))
        memories = Array(memories.suffix(300))
    }
}
#endif
