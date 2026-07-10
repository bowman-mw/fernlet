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
    /// Idempotent per DAY: bails if today's meals/workouts already exist so repeated
    /// launches don't stack duplicates. The guard must stay day-scoped — journals and
    /// memories persist across days, so gating on them left any simulator that had
    /// seeded on a previous calendar day permanently unseedable (empty Food/Move tabs);
    /// those two seeders carry their own cross-day duplicate checks instead.
    @MainActor
    func seedDemoContent() {
        guard day.meals.isEmpty, day.workouts.isEmpty else { return }

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
        // Journals persist across days — a simulator seeded on a previous day
        // already has these; adding more each day would stack duplicates.
        guard previousJournals.isEmpty else { return }
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
        // Memories persist across days too — skip if a previous day already seeded them.
        // The marker is appended LAST so the trailing suffix(300) cap evicts it last: if
        // it survived, seeding ran, so gating on it never re-appends the trio on a later day.
        let marker = "Enjoys morning walks and steady routines."
        guard !memories.contains(where: { $0.text == marker }) else { return }
        memories.append(MemoryNote(category: "bright", text: "Cooking at home felt rewarding this week."))
        memories.append(MemoryNote(category: "note", text: "Prefers gentle, consistent care over streaks."))
        memories.append(MemoryNote(category: "good", text: marker))
        memories = Array(memories.suffix(300))
    }
}
#endif
