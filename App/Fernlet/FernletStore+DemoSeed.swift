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

// R8: one combined condition instead of a nested `#if canImport(UIKit)` inside `#if DEBUG`
// (nesting is banned; the app target is UIKit-only, so the combined guard is equivalent).
#if DEBUG && canImport(UIKit)
import Foundation
import FernletDomainModel
import DiaryStore
import UIKit

extension FernletStore {
    /// Populate today's diary with representative demo content. Invoked from
    /// ContentView's launch task when `UITestSupport.shouldSeedDemoContent` is set.
    ///
    /// The age record and the sensitive-surface visibility flags apply on EVERY seeded launch
    /// (the Cycle-page gallery variants relaunch with different hide flags on one simulator);
    /// the diary content below them is idempotent per DAY: it bails if today's meals/workouts
    /// already exist so repeated launches don't stack duplicates. The guard must stay
    /// day-scoped — journals and memories persist across days, so gating on them left any
    /// simulator that had seeded on a previous calendar day permanently unseedable (empty
    /// Food/Move tabs); those two seeders carry their own cross-day duplicate checks instead.
    @MainActor
    func seedDemoContent() {
        // Age + surface visibility apply on EVERY seeded launch, BEFORE the day-scoped meal guard
        // below: the Cycle-page gallery variants relaunch the app on the same simulator with
        // different hide flags, and a previous launch's persisted visibility choice must not stick.

        // Ensure the age-gated surfaces are reachable for appearance review. The profile age no longer
        // gates anything — both gates read the device-local age record — so seed that instead, with a
        // bracket above the highest gate and a provenance, since a bracket without one stays undetermined.
        ageAssurance.applyDetermination(
            lowerBound: AgeGate.adult.minimumAge,
            upperBound: nil,
            provenance: .selfDeclared
        )

        // Ensure the Cycle section renders the requested halves for appearance review. Mirrors the
        // age bump above: the period half gates on `isPeriodTrackingVisible`, which absent an
        // explicit choice derives from `userProfile.sex` (default `.male` → hidden). Setting the
        // explicit opt-in surfaces the Private hub's Cycle page for the gallery without asserting a
        // biological sex on the demo persona. Direct settings writes (like the age bump) are enough:
        // nothing sensitive has loaded yet at seed time, and the derived gates cover every later
        // read — ContentView's value-keyed scrub handles any mid-session flip.
        settings.periodTrackingVisible = !UITestSupport.hidePeriodSurface
        settings.intimacyTrackingVisible = !UITestSupport.hideIntimacySurface
        // Applied on EVERY seeded launch like the two above (not inside the day-scoped guard below),
        // so a relaunch that drops the flag puts the coach gate back off rather than leaving it on
        // from an earlier run.
        settings.coachExchangeEnabled = UITestSupport.enableCoachExchange

        guard day.meals.isEmpty, day.workouts.isEmpty else { return }

        seedMeals()
        seedRecipes()
        seedHydrationAndSleep()
        seedJournals()
        seedWorkout()
        seedProgressPhotos()
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
                confidence: MealConfidence.logged.token, note: "Seeded demo meal.", source: "manual"
            ),
            Meal(
                name: "Chicken rice bowl", mealType: .lunch,
                macros: Macros(protein: 42, carbs: 58, fat: 14),
                mealSource: .manual, isAIFallback: false, quality: .good,
                confidence: MealConfidence.logged.token, note: "Seeded demo meal.", source: "manual"
            ),
            Meal(
                name: "Apple and almonds", mealType: .snack,
                macros: Macros(protein: 6, carbs: 22, fat: 12),
                mealSource: .manual, isAIFallback: false, quality: .ok,
                confidence: MealConfidence.logged.token, note: "Seeded demo meal.", source: "manual"
            ),
        ]
        for meal in meals {
            diary.appendMeal(meal, date: todayKey)
        }

        // Attach photos to the first two meals so the "Recent bites" polaroid strip (#11) renders
        // populated in the appearance gallery rather than its empty state. Goes through the real sealed
        // MealPhotoStore via `saveMealPhoto`, so it also exercises the seal/normalize path end to end.
        for (meal, hue) in zip(meals.prefix(2), [0.09, 0.33] as [CGFloat]) {
            if let photoID = saveMealPhoto(Self.demoFoodImage(hue: hue)) {
                attachMealPhoto(mealID: meal.id, photoID: photoID)
            }
        }
    }

    /// A warm gradient stand-in for a food photo (no bundled image assets in the test seed).
    private static func demoFoodImage(hue: CGFloat) -> UIImage {
        let size = CGSize(width: 480, height: 480)
        return demoGradientImage(
            size: size,
            top: UIColor(hue: hue, saturation: 0.62, brightness: 0.86, alpha: 1),
            bottom: UIColor(hue: hue, saturation: 0.72, brightness: 0.58, alpha: 1),
            end: CGPoint(x: size.width, y: size.height)
        )
    }

    /// Renders a two-stop linear gradient tile. R5: a `CGGradient` that fails to build falls back to a
    /// solid fill (the demo tile stays visible) instead of trapping on a force unwrap.
    private static func demoGradientImage(size: CGSize, top: UIColor, bottom: UIColor,
                                          end: CGPoint) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: [top.cgColor, bottom.cgColor] as CFArray,
                                            locations: [0, 1]) else {
                ctx.cgContext.setFillColor(top.cgColor)
                ctx.cgContext.fill(CGRect(origin: .zero, size: size))
                return
            }
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: end, options: [])
        }
    }

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
            ],
            // Structured steps (with one timed step) so the appearance suites and design-round
            // screenshots exercise the read-only Steps card and its timer capsule (FOOD-22).
            steps: [
                RecipeStep(text: "Stir the oats and yogurt together in a jar."),
                RecipeStep(text: "Chill overnight.", durationSeconds: 8 * 60 * 60),
                RecipeStep(text: "Top with blueberries before eating."),
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

    /// A few gym progress photos so the Move tab's timeline (#11) renders populated in the gallery
    /// rather than its empty state. Goes through the real sealed `ProgressPhotoStore` via
    /// `addProgressPhoto`, exercising the seal/normalize/dated-index path end to end.
    ///
    /// Cross-day duplicate check of its own: progress photos persist across days (they are a timeline),
    /// so the day-scoped guard in `seedDemoContent` doesn't cover them — same reasoning as
    /// `seedJournals`/`seedMemories`.
    private func seedProgressPhotos() {
        guard progressPhotoRecords().isEmpty else { return }
        let calendar = Calendar.current
        let entries: [(weeksAgo: Int, hue: CGFloat, caption: String?)] = [
            (6, 0.55, "Starting out"),
            (3, 0.52, nil),
            (0, 0.50, "Feeling stronger"),
        ]
        for entry in entries {
            let image = Self.demoProgressImage(hue: entry.hue)
            guard let data = image.jpegData(compressionQuality: 0.9) else { continue }
            let seeded = seedProgressPhoto(
                data,
                caption: entry.caption,
                capturedAt: calendar.date(byAdding: .weekOfYear, value: -entry.weeksAgo, to: Date()) ?? Date()
            )
            if seeded == nil {
                assertionFailure("demo progress photo failed to seal")
            }
        }
    }

    /// A cool neutral gradient stand-in for a body photo (no bundled image assets in the test seed).
    private static func demoProgressImage(hue: CGFloat) -> UIImage {
        let size = CGSize(width: 480, height: 640)
        return demoGradientImage(
            size: size,
            top: UIColor(hue: hue, saturation: 0.18, brightness: 0.82, alpha: 1),
            bottom: UIColor(hue: hue, saturation: 0.30, brightness: 0.52, alpha: 1),
            end: CGPoint(x: 0, y: size.height)
        )
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
