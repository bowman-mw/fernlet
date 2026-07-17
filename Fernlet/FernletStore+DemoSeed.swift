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
#if canImport(UIKit)
import UIKit
#endif

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

        // Ensure the Period section is reachable for appearance review. Mirrors the age
        // bump above: the Period surface gates on `isPeriodTrackingVisible`, which absent
        // an explicit choice derives from `userProfile.sex` (default `.male` → hidden).
        // Setting the explicit opt-in surfaces the Private hub's Period page for the
        // gallery without asserting a biological sex on the demo persona. This only makes
        // the surface MORE visible, so there is nothing to scrub — a direct settings write
        // (like the age bump) is enough; no need to route through `setPeriodTrackingVisible`.
        if settings.periodTrackingVisible != true { settings.periodTrackingVisible = true }

        seedMeals()
        seedRecipes()
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

        #if canImport(UIKit)
        // Attach photos to the first two meals so the "Recent bites" polaroid strip (#11) renders
        // populated in the appearance gallery rather than its empty state. Goes through the real sealed
        // MealPhotoStore via `saveMealPhoto`, so it also exercises the seal/normalize path end to end.
        for (meal, hue) in zip(meals.prefix(2), [0.09, 0.33] as [CGFloat]) {
            if let photoID = saveMealPhoto(Self.demoFoodImage(hue: hue)) {
                attachMealPhoto(mealID: meal.id, photoID: photoID)
            }
        }
        #endif
    }

    #if canImport(UIKit)
    /// A warm gradient stand-in for a food photo (no bundled image assets in the test seed).
    private static func demoFoodImage(hue: CGFloat) -> UIImage {
        let size = CGSize(width: 480, height: 480)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let top = UIColor(hue: hue, saturation: 0.62, brightness: 0.86, alpha: 1).cgColor
            let bottom = UIColor(hue: hue, saturation: 0.72, brightness: 0.58, alpha: 1).cgColor
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [top, bottom] as CFArray, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(gradient, start: .zero,
                                             end: CGPoint(x: size.width, y: size.height), options: [])
        }
    }
    #endif

    /// Recipes for the Food tab's Recipes section, which otherwise renders its empty state in every
    /// gallery run — the one section reviewers could never actually see. Two entries with different
    /// serving counts and name lengths, so the row layout (title size, servings alignment, wrapping)
    /// is reviewable rather than inferred.
    ///
    /// Cross-day duplicate check of its own: `recipes` persist across days, so the day-scoped guard in
    /// `seedDemoContent` does not cover them (same reasoning as `seedJournals`/`seedMemories`).
    private func seedRecipes() {
        guard recipes.isEmpty else { return }
        addRecipe(
            name: "Overnight oats",
            servings: 2,
            notes: "Seeded demo recipe. Mix, chill overnight, top with fruit.",
            ingredients: [
                ManualRecipeIngredientInput(name: "Rolled oats", quantity: 1, unit: "cup", protein: 10, carbs: 54, fat: 6),
                ManualRecipeIngredientInput(name: "Greek yogurt", quantity: 1, unit: "cup", protein: 20, carbs: 8, fat: 4),
                ManualRecipeIngredientInput(name: "Blueberries", quantity: 0.5, unit: "cup", protein: 1, carbs: 11, fat: 0),
            ]
        )
        addRecipe(
            name: "Sheet pan chicken and vegetables",
            servings: 4,
            notes: "Seeded demo recipe. Roast at 425 for 25 minutes.",
            ingredients: [
                ManualRecipeIngredientInput(name: "Chicken thigh", quantity: 4, unit: "piece", protein: 96, carbs: 0, fat: 40),
                ManualRecipeIngredientInput(name: "Broccoli", quantity: 2, unit: "cup", protein: 5, carbs: 12, fat: 1),
                ManualRecipeIngredientInput(name: "Olive oil", quantity: 2, unit: "tbsp", protein: 0, carbs: 0, fat: 28),
                ManualRecipeIngredientInput(name: "Sweet potato", quantity: 2, unit: "piece", protein: 4, carbs: 52, fat: 0),
            ]
        )
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
