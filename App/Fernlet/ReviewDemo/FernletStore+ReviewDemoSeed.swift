// R8: the one custom condition (Docs/Power-of-10-Swift.md §R8) — compiled only into the `Demo`
// build configuration (`Fernlet Demo` scheme). Normal builds carry none of this file.
//
// The App Review demo's sample data. Unlike the DEBUG appearance seed (`FernletStore+DemoSeed`,
// pinned to UI-test baselines), this one fills two believable weeks so every tab shows real content.
// It writes only through the store's own facade and the diary's per-day seam, never to Apple Health:
// workouts go through `diary.appendWorkout` (the facade's `addWorkout` would offer Health access and
// mirror the workout there), and cycle records are sealed straight into the cycle record store (the
// period store's `logEvent` would mirror them to Health while cycle sharing is on).
#if FERNLET_DEMO
import CryptoKit
import Foundation
import UIKit
import DiaryStore
import FernletDomainModel
import FernletFoundation
import PrivateHealthStore
import PrivateMediaStore

/// The demo's sample data: fourteen days of meals, workouts, sleep, water and care, a few journal
/// entries, recipes, progress photos, memories, the solo album, and the Private hub's cycle history
/// (and, once the hub's intimacy funnel is at hand, two intimacy entries).
///
/// Called once by ``ReviewDemo`` on a fresh install, after the demo passcode has opened the Private hub.
/// Everything it plants is erased by the app's own delete-everything funnel when the person leaves the
/// demo. The intimacy section opens only through the manual "I'm 16 or older" confirmation — the system
/// age answer is never faked, so nearby chat stays exactly as the device's own answer leaves it.
extension FernletStore {
    /// How many days the sample diary covers, today included.
    private static let reviewDemoDayCount = 14

    /// The `UserDefaults` bit saying the demo's intimacy entries are still owed: the seed runs during
    /// onboarding, before `ContentView` (the only owner of the app's intimacy funnel) exists, so they
    /// are written at the first Private-hub open (``seedReviewDemoIntimacyIfPending(in:privateHubKey:)``).
    static let reviewDemoIntimacyPendingKey = "reviewDemo.intimacyPending"

    /// One piece of sample text — a meal or recipe name, a note, a journal line — in the device's
    /// language, so a person looking at the demo in Spanish sees a Spanish diary. It is the pretend
    /// person's own typing, so it is stored as written, like anything a person types: no token, rawValue
    /// or matched word is ever localized here.
    ///
    /// The keys are MANUAL entries in the app catalog (`extractionState: manual`): this file is compiled
    /// only into the Demo configuration, so `Scripts/sync-string-catalogs.sh` never extracts them, and a
    /// manual entry is one the sync leaves alone.
    static func reviewDemoSample(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, comment: "App Review demo: sample data")
    }

    /// Plants the demo's sample data. Skips (logged) when the diary already holds meals or recipes, so
    /// it can never mix sample entries into a real person's data.
    ///
    /// - Parameter privateHubKey: The Private hub's content key, which seals the cycle records.
    @MainActor
    func seedReviewDemo(privateHubKey: SymmetricKey) async {
        guard recipes.isEmpty, day.meals.isEmpty else {
            FernletAuditLog.log("reviewDemo.seed.skipped", context: ["reason": "notEmpty"])
            return
        }
        openReviewDemoSurfaces()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for offset in 0..<Self.reviewDemoDayCount {
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            seedReviewDemoDay(offset: offset, dayStart: dayStart, calendar: calendar)
        }
        seedReviewDemoJournals(today: today, calendar: calendar)
        seedReviewDemoRecipes()
        seedReviewDemoProgressPhotos(today: today, calendar: calendar)
        seedReviewDemoMemories()
        seedReviewDemoSoloAlbum(today: today, calendar: calendar)
        seedReviewDemoCycle(privateHubKey: privateHubKey, today: today, calendar: calendar)
        UserDefaults.standard.set(true, forKey: Self.reviewDemoIntimacyPendingKey)
        if !flushPendingSnapshotSave() {
            FernletAuditLog.log("reviewDemo.seed.flushFailed")
        }
        FernletAuditLog.log("reviewDemo.seed.done")
    }

    /// Writes the demo's two intimacy entries through the app's one intimacy funnel, sealed with the hub
    /// key — once, while ``reviewDemoIntimacyPendingKey`` is set. Call it with `ContentView`'s
    /// `intimacyStore` (after its visibility gate is wired) whenever the Private hub opens in the demo.
    ///
    /// - Parameters:
    ///   - intimacyStore: The app's intimacy funnel (`ContentView`'s; never a second instance).
    ///   - privateHubKey: The open hub's content key.
    @MainActor
    func seedReviewDemoIntimacyIfPending(in intimacyStore: IntimacyLogStore, privateHubKey: SymmetricKey) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.reviewDemoIntimacyPendingKey) else { return }
        guard isIntimacyTrackingVisible else {
            FernletAuditLog.log("reviewDemo.intimacy.skipped", context: ["reason": "hidden"])
            return
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let entries: [(daysAgo: Int, hour: Int, note: String)] = [
            (4, 22, FernletStore.reviewDemoSample("reviewDemo.intimacy.note", "Slow evening together.")),
            (11, 21, ""),
        ]
        do {
            for entry in entries {
                guard let dayStart = calendar.date(byAdding: .day, value: -entry.daysAgo, to: today),
                      let when = calendar.date(byAdding: .hour, value: entry.hour, to: dayStart) else { continue }
                try intimacyStore.insert(IntimacyLog(eventDate: when, note: entry.note), contentKey: privateHubKey)
            }
            defaults.removeObject(forKey: Self.reviewDemoIntimacyPendingKey)
        } catch {
            FernletAuditLog.log("reviewDemo.intimacy.failed", context: ["error": "\(type(of: error))"])
        }
    }

    // MARK: - Surfaces

    /// Turns the cycle and intimacy sections on. Intimacy (16+) opens only through the manual
    /// confirmation the age-gate notice's "I'm 16 or older" button makes (`selfAttest`) — never
    /// `applyDetermination`, which is the system's answer: faking it would open nearby chat (13+,
    /// system answer only) to anyone holding the public demo build.
    private func openReviewDemoSurfaces() {
        setPeriodTrackingVisible(true)
        ageAssurance.selfAttest(.intimacy)
        guard isIntimateLoggingAllowed else {
            // The device's own age answer placed this person below 16: the section stays shut.
            FernletAuditLog.log("reviewDemo.intimacy.gateClosed")
            return
        }
        setIntimacyTrackingVisible(true)
    }

    // MARK: - One day

    /// One sample day: its meals, its workout (if it is a training day), sleep, water and care.
    private func seedReviewDemoDay(offset: Int, dayStart: Date, calendar: Calendar) {
        let dateKey = FernletDate.dayKey(for: dayStart)
        guard !dateKey.isEmpty else { return }
        seedReviewDemoMeals(offset: offset, dateKey: dateKey, dayStart: dayStart, calendar: calendar)
        if let workout = Self.reviewDemoWorkout(offset: offset, dayStart: dayStart, calendar: calendar) {
            // The diary's seam, not the facade's `addWorkout`: that one offers Health access and
            // mirrors the workout to Apple Health, and sample data never reaches Health.
            diary.appendWorkout(workout, date: dateKey)
        }
        let sleep = Self.reviewDemoSleep[offset % Self.reviewDemoSleep.count]
        setSleep(hours: sleep.hours, quality: sleep.quality, note: sleep.note, date: dateKey)
        setBottleCount(offset == 0 ? 4 : 5 + (offset * 3) % 4, date: dateKey)
        setHygiene(Self.reviewDemoHygiene[offset % Self.reviewDemoHygiene.count], date: dateKey)
    }

    /// The day's meals from the rotating menu; today's first two carry a photo through the sealed
    /// meal-photo store, so the "Recent bites" strip is populated.
    private func seedReviewDemoMeals(offset: Int, dateKey: String, dayStart: Date, calendar: Calendar) {
        let menu = Self.reviewDemoMenus[offset % Self.reviewDemoMenus.count]
        for (index, item) in menu.enumerated() {
            // Clamped to now, so this morning's demo never shows tonight's dinner already eaten.
            let loggedAt = min(calendar.date(byAdding: .hour, value: item.hour, to: dayStart) ?? dayStart, Date())
            let macros = Macros(protein: item.protein, carbs: item.carbs, fat: item.fat)
            var photoID: UUID?
            if offset == 0, index < 2 {
                photoID = saveMealPhoto(ReviewDemoArt.foodImage(hue: index == 0 ? 0.09 : 0.30))
            }
            let meal = Meal(
                name: item.name, mealType: item.type, macros: macros,
                mealSource: .manual, isAIFallback: false,
                quality: item.protein >= Macros.goodProteinThreshold ? .good : .ok,
                confidence: MealConfidence.logged.token, note: "", source: "manual",
                loggedAt: loggedAt, photoID: photoID
            )
            diary.appendMeal(meal, date: dateKey)
        }
    }

    /// The training plan across the fortnight: strength, cardio and yoga, with rest days between.
    private static func reviewDemoWorkout(offset: Int, dayStart: Date, calendar: Calendar) -> Workout? {
        guard let plan = reviewDemoTraining[offset] else { return nil }
        let completedAt = min(calendar.date(byAdding: .hour, value: 18, to: dayStart) ?? dayStart, Date())
        switch plan {
        case .upper:
            return Workout(name: FernletStore.reviewDemoSample("reviewDemo.workout.upper", "Upper body strength"), type: .upper, mode: .strengthTraining,
                           exercises: FernletStore.reviewDemoSample("reviewDemo.workout.upper.exercises", "Bench press 3x8\nSeated row 3x10\nOverhead press 3x8"),
                           rpe: 7, notes: FernletStore.reviewDemoSample("reviewDemo.workout.upper.notes", "Felt strong on the last set."), duration: 45,
                           intensity: .moderate, completedAt: completedAt)
        case .lower:
            return Workout(name: FernletStore.reviewDemoSample("reviewDemo.workout.lower", "Lower body strength"), type: .lower, mode: .strengthTraining,
                           exercises: FernletStore.reviewDemoSample("reviewDemo.workout.lower.exercises", "Goblet squat 3x10\nRomanian deadlift 3x8\nWalking lunge 2x12"),
                           rpe: 7, notes: "", duration: 50, intensity: .moderate, completedAt: completedAt)
        case .run:
            return Workout(name: FernletStore.reviewDemoSample("reviewDemo.workout.run", "Easy run"), type: .cardio, mode: .activity, activityType: .running,
                           exercises: "", rpe: 5, notes: FernletStore.reviewDemoSample("reviewDemo.workout.run.notes", "Park loop."), duration: 30, distanceMiles: 3.1,
                           intensity: .moderate, completedAt: completedAt)
        case .walk:
            return Workout(name: FernletStore.reviewDemoSample("reviewDemo.workout.walk", "Evening walk"), type: .cardio, mode: .activity, activityType: .walking,
                           exercises: "", rpe: 3, notes: "", duration: 40, distanceMiles: 2.0,
                           intensity: .light, completedAt: completedAt)
        case .yoga:
            return Workout(name: FernletStore.reviewDemoSample("reviewDemo.workout.yoga", "Yoga flow"), type: .cardio, mode: .activity, activityType: .yoga,
                           exercises: "", rpe: 4, notes: FernletStore.reviewDemoSample("reviewDemo.workout.yoga.notes", "Gentle hips and shoulders."), duration: 35,
                           intensity: .light, completedAt: completedAt)
        }
    }

    // MARK: - Journal, recipes, photos, memories

    /// Four journal entries across the fortnight, sealed by the journal path like any other entry.
    private func seedReviewDemoJournals(today: Date, calendar: Calendar) {
        let entries: [(daysAgo: Int, tag: FeelingTag, text: String)] = [
            (9, .tired, FernletStore.reviewDemoSample("reviewDemo.journal.tired", "Long day at work. Made soup anyway and went to bed early.")),
            (5, .good, FernletStore.reviewDemoSample("reviewDemo.journal.lifted", "Lifted for the first time in a while. Sore, but the good kind.")),
            (2, .bright, FernletStore.reviewDemoSample("reviewDemo.journal.market", "Walked to the farmers market with a friend. Peaches are back.")),
            (0, .good, FernletStore.reviewDemoSample("reviewDemo.journal.steady", "Slept well and had a slow breakfast. Feeling steady.")),
        ]
        for entry in entries {
            guard let dayStart = calendar.date(byAdding: .day, value: -entry.daysAgo, to: today) else { continue }
            addJournal(text: entry.text, tag: entry.tag, date: FernletDate.dayKey(for: dayStart))
        }
    }

    /// Three recipes; the oats carry structured steps (one timed), so the Steps card shows.
    private func seedReviewDemoRecipes() {
        addRecipe(
            name: FernletStore.reviewDemoSample("reviewDemo.meal.overnightOats", "Overnight oats"), servings: 2, notes: FernletStore.reviewDemoSample("reviewDemo.recipe.oats.notes", "Mix, chill overnight, top with fruit."),
            ingredients: [
                ManualRecipeIngredientInput(name: FernletStore.reviewDemoSample("reviewDemo.ingredient.rolledOats", "Rolled oats"), quantity: 1, unit: "cup", protein: 10, carbs: 54, fat: 6),
                ManualRecipeIngredientInput(name: FernletStore.reviewDemoSample("reviewDemo.ingredient.greekYogurt", "Greek yogurt"), quantity: 1, unit: "cup", protein: 20, carbs: 8, fat: 4),
                ManualRecipeIngredientInput(name: FernletStore.reviewDemoSample("reviewDemo.ingredient.blueberries", "Blueberries"), quantity: 0.5, unit: "cup", protein: 1, carbs: 11, fat: 0),
            ],
            steps: [
                RecipeStep(text: FernletStore.reviewDemoSample("reviewDemo.recipe.oats.step1", "Stir the oats and yogurt together in a jar.")),
                RecipeStep(text: FernletStore.reviewDemoSample("reviewDemo.recipe.oats.step2", "Chill overnight."), durationSeconds: 8 * 60 * 60),
                RecipeStep(text: FernletStore.reviewDemoSample("reviewDemo.recipe.oats.step3", "Top with blueberries before eating.")),
            ]
        )
        addRecipe(
            name: FernletStore.reviewDemoSample("reviewDemo.meal.sheetPanChicken", "Sheet pan chicken and vegetables"), servings: 4, notes: FernletStore.reviewDemoSample("reviewDemo.recipe.sheetPan.notes", "Roast at 425 for 25 minutes."),
            ingredients: [
                ManualRecipeIngredientInput(name: FernletStore.reviewDemoSample("reviewDemo.ingredient.chickenThigh", "Chicken thigh"), quantity: 4, unit: "piece", protein: 96, carbs: 0, fat: 40),
                ManualRecipeIngredientInput(name: FernletStore.reviewDemoSample("reviewDemo.ingredient.broccoli", "Broccoli"), quantity: 2, unit: "cup", protein: 5, carbs: 12, fat: 1),
                ManualRecipeIngredientInput(name: FernletStore.reviewDemoSample("reviewDemo.ingredient.sweetPotato", "Sweet potato"), quantity: 2, unit: "piece", protein: 4, carbs: 52, fat: 0),
                ManualRecipeIngredientInput(name: FernletStore.reviewDemoSample("reviewDemo.ingredient.oliveOil", "Olive oil"), quantity: 2, unit: "tbsp", protein: 0, carbs: 0, fat: 28),
            ]
        )
        addRecipe(
            name: FernletStore.reviewDemoSample("reviewDemo.meal.lentilSoup", "Lentil soup"), servings: 6, notes: FernletStore.reviewDemoSample("reviewDemo.recipe.lentilSoup.notes", "Freezes well."),
            ingredients: [
                ManualRecipeIngredientInput(name: FernletStore.reviewDemoSample("reviewDemo.ingredient.redLentils", "Red lentils"), quantity: 2, unit: "cup", protein: 48, carbs: 120, fat: 4),
                ManualRecipeIngredientInput(name: FernletStore.reviewDemoSample("reviewDemo.ingredient.carrot", "Carrot"), quantity: 2, unit: "piece", protein: 1, carbs: 12, fat: 0),
                ManualRecipeIngredientInput(name: FernletStore.reviewDemoSample("reviewDemo.ingredient.vegetableBroth", "Vegetable broth"), quantity: 6, unit: "cup", protein: 3, carbs: 12, fat: 0),
            ]
        )
    }

    /// Three progress photos a few weeks apart, through the sealed progress-photo store.
    private func seedReviewDemoProgressPhotos(today: Date, calendar: Calendar) {
        let entries: [(daysAgo: Int, hue: CGFloat, caption: String?)] = [
            (42, 0.55, FernletStore.reviewDemoSample("reviewDemo.progressPhoto.start", "Starting out")),
            (21, 0.52, nil),
            (2, 0.50, FernletStore.reviewDemoSample("reviewDemo.progressPhoto.stronger", "Feeling stronger")),
        ]
        for entry in entries {
            guard let dayStart = calendar.date(byAdding: .day, value: -entry.daysAgo, to: today),
                  let data = ReviewDemoArt.progressImage(hue: entry.hue).jpegData(compressionQuality: 0.9) else { continue }
            let capturedAt = calendar.date(byAdding: .hour, value: 8, to: dayStart) ?? dayStart
            guard let record = addProgressPhoto(data: data, capturedAt: capturedAt) else {
                FernletAuditLog.log("reviewDemo.progressPhoto.notSealed")
                continue
            }
            if let caption = entry.caption {
                updateProgressPhotoCaption(id: record.id, caption: caption)
            }
        }
    }

    /// A few companion memories (plain synced notes).
    private func seedReviewDemoMemories() {
        memories.append(MemoryNote(category: "bright", text: FernletStore.reviewDemoSample("reviewDemo.memory.cooking", "Cooking at home felt rewarding this week.")))
        memories.append(MemoryNote(category: "note", text: FernletStore.reviewDemoSample("reviewDemo.memory.gentle", "Prefers gentle, consistent care over streaks.")))
        memories.append(MemoryNote(category: "good", text: FernletStore.reviewDemoSample("reviewDemo.memory.walks", "Enjoys morning walks and steady routines.")))
        memories = Array(memories.suffix(300))
    }

    /// Three solo-album photos from yesterday afternoon, taken through the roll's own camera path, so
    /// they were revealed last night like any other solo shot (the DEBUG `SoloAlbumDemoSeed`'s idea).
    private func seedReviewDemoSoloAlbum(today: Date, calendar: Calendar) {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return }
        let roll = soloCameraRoll()
        for variant in 0..<3 {
            guard let data = ReviewDemoArt.parkScene(variant: variant) else { continue }
            let takenAt = yesterday.addingTimeInterval(Double(14 * 60 + variant * 75) * 60)
            if roll.takePhoto(data, at: takenAt, calendar: calendar) != .kept {
                FernletAuditLog.log("reviewDemo.soloPhoto.notKept")
            }
        }
        roll.refresh()
    }

    // MARK: - Cycle (sealed, never Apple Health)

    /// Four periods 28 days apart — three complete cycles, which is what the Cycle page needs before it
    /// shows predictions and period-aware care, and the current one, which started nine days ago — sealed with the hub key straight into the cycle record store. Never `logEvent`: that
    /// mirrors to Apple Health while cycle sharing is on, and sample data never reaches Health.
    private func seedReviewDemoCycle(privateHubKey: SymmetricKey, today: Date, calendar: Calendar) {
        let records = CycleRecordStore()
        // The same visibility gate `ContentView` gives the app's period store. No backup mutation hook:
        // the demo keeps storage on this iPhone, so the sealed period backup never runs.
        records.attachVisibilityGate { [weak self] in self?.isPeriodTrackingVisible ?? false }
        do {
            for periodStart in [93, 65, 37, 9] {
                for (dayIndex, day) in Self.reviewDemoPeriodDays.enumerated() {
                    let daysAgo = periodStart - dayIndex
                    guard let dayStart = calendar.date(byAdding: .day, value: -daysAgo, to: today),
                          let at = calendar.date(byAdding: .hour, value: 9, to: dayStart) else { continue }
                    let event = UserLoggedCycleEvent(
                        date: at, flowLevel: day.flow, isCycleStart: dayIndex == 0,
                        note: day.note, symptoms: day.symptoms
                    )
                    try records.insert(CycleRecord(event: event), contentKey: privateHubKey)
                }
            }
        } catch {
            FernletAuditLog.log("reviewDemo.cycle.failed", context: ["error": "\(type(of: error))"])
        }
    }

    // MARK: - Tables

    /// One menu item: what was eaten, when (hour of the day), and its macros in grams.
    private struct ReviewDemoMeal {
        let name: String
        let type: MealType
        let hour: Int
        let protein: Int
        let carbs: Int
        let fat: Int
    }

    /// A week of menus, rotated across the fortnight.
    private static let reviewDemoMenus: [[ReviewDemoMeal]] = [
        [ReviewDemoMeal(name: FernletStore.reviewDemoSample("reviewDemo.meal.greekYogurt", "Greek yogurt with berries"), type: .breakfast, hour: 8, protein: 28, carbs: 34, fat: 9),
         ReviewDemoMeal(name: FernletStore.reviewDemoSample("reviewDemo.meal.chickenRiceBowl", "Chicken rice bowl"), type: .lunch, hour: 12, protein: 42, carbs: 58, fat: 14),
         ReviewDemoMeal(name: FernletStore.reviewDemoSample("reviewDemo.meal.appleAlmonds", "Apple and almonds"), type: .snack, hour: 15, protein: 6, carbs: 22, fat: 12)],
        [ReviewDemoMeal(name: FernletStore.reviewDemoSample("reviewDemo.meal.overnightOats", "Overnight oats"), type: .breakfast, hour: 7, protein: 16, carbs: 52, fat: 8),
         ReviewDemoMeal(name: FernletStore.reviewDemoSample("reviewDemo.meal.turkeyWrap", "Turkey and avocado wrap"), type: .lunch, hour: 13, protein: 32, carbs: 40, fat: 18),
         ReviewDemoMeal(name: FernletStore.reviewDemoSample("reviewDemo.meal.salmon", "Salmon with roasted vegetables"), type: .dinner, hour: 19, protein: 38, carbs: 30, fat: 22)],
        [ReviewDemoMeal(name: FernletStore.reviewDemoSample("reviewDemo.meal.eggsToast", "Scrambled eggs on toast"), type: .breakfast, hour: 8, protein: 22, carbs: 28, fat: 16),
         ReviewDemoMeal(name: FernletStore.reviewDemoSample("reviewDemo.meal.lentilSoup", "Lentil soup"), type: .lunch, hour: 12, protein: 18, carbs: 44, fat: 4),
         ReviewDemoMeal(name: FernletStore.reviewDemoSample("reviewDemo.meal.sheetPanChicken", "Sheet pan chicken and vegetables"), type: .dinner, hour: 19, protein: 34, carbs: 26, fat: 18)],
        [ReviewDemoMeal(name: FernletStore.reviewDemoSample("reviewDemo.meal.bananaSmoothie", "Banana smoothie"), type: .breakfast, hour: 8, protein: 20, carbs: 48, fat: 6),
         ReviewDemoMeal(name: FernletStore.reviewDemoSample("reviewDemo.meal.tunaSalad", "Tuna salad"), type: .lunch, hour: 12, protein: 30, carbs: 12, fat: 14),
         ReviewDemoMeal(name: FernletStore.reviewDemoSample("reviewDemo.meal.hummusCarrots", "Hummus and carrots"), type: .snack, hour: 16, protein: 7, carbs: 20, fat: 9),
         ReviewDemoMeal(name: FernletStore.reviewDemoSample("reviewDemo.meal.tofuStirFry", "Veggie stir fry with tofu"), type: .dinner, hour: 19, protein: 24, carbs: 46, fat: 15)],
        [ReviewDemoMeal(name: FernletStore.reviewDemoSample("reviewDemo.meal.peanutButterToast", "Peanut butter toast"), type: .breakfast, hour: 8, protein: 14, carbs: 32, fat: 16),
         ReviewDemoMeal(name: FernletStore.reviewDemoSample("reviewDemo.meal.burritoBowl", "Burrito bowl"), type: .lunch, hour: 13, protein: 35, carbs: 62, fat: 17),
         ReviewDemoMeal(name: FernletStore.reviewDemoSample("reviewDemo.meal.pasta", "Pasta with tomato sauce"), type: .dinner, hour: 19, protein: 18, carbs: 72, fat: 10)],
        [ReviewDemoMeal(name: FernletStore.reviewDemoSample("reviewDemo.meal.cottageCheese", "Cottage cheese and peaches"), type: .breakfast, hour: 9, protein: 26, carbs: 24, fat: 5),
         ReviewDemoMeal(name: FernletStore.reviewDemoSample("reviewDemo.meal.grilledCheese", "Grilled cheese and tomato soup"), type: .lunch, hour: 13, protein: 20, carbs: 48, fat: 22),
         ReviewDemoMeal(name: FernletStore.reviewDemoSample("reviewDemo.meal.shrimpTacos", "Shrimp tacos"), type: .dinner, hour: 19, protein: 30, carbs: 40, fat: 14)],
        [ReviewDemoMeal(name: FernletStore.reviewDemoSample("reviewDemo.meal.pancakes", "Pancakes with fruit"), type: .breakfast, hour: 10, protein: 12, carbs: 66, fat: 12),
         ReviewDemoMeal(name: FernletStore.reviewDemoSample("reviewDemo.meal.caesarSalad", "Chicken caesar salad"), type: .lunch, hour: 14, protein: 36, carbs: 14, fat: 20),
         ReviewDemoMeal(name: FernletStore.reviewDemoSample("reviewDemo.meal.darkChocolate", "Dark chocolate"), type: .snack, hour: 20, protein: 2, carbs: 14, fat: 9)],
    ]

    /// A day's training, by how many days ago it was.
    private enum ReviewDemoTraining {
        case upper, lower, run, walk, yoga
    }

    /// The fortnight's training days (days ago → session); the rest are rest days.
    private static let reviewDemoTraining: [Int: ReviewDemoTraining] = [
        0: .walk, 1: .upper, 2: .yoga, 3: .run, 5: .lower, 6: .walk, 7: .upper,
        8: .yoga, 10: .run, 11: .lower, 12: .walk, 13: .yoga,
    ]

    /// A week of nights, rotated.
    private static let reviewDemoSleep: [(hours: Double, quality: SleepQuality, note: String)] = [
        (8.0, .great, FernletStore.reviewDemoSample("reviewDemo.sleep.rested", "Rested.")), (7.5, .good, ""), (6.5, .ok, FernletStore.reviewDemoSample("reviewDemo.sleep.wokeOnce", "Woke up once.")), (7.0, .good, ""),
        (8.5, .great, FernletStore.reviewDemoSample("reviewDemo.sleep.sleptIn", "Slept in.")), (6.0, .poor, FernletStore.reviewDemoSample("reviewDemo.sleep.lateNight", "Late night.")), (7.5, .good, ""),
    ]

    /// A few patterns of personal care, rotated.
    private static let reviewDemoHygiene: [Set<HygieneItem>] = [
        [.teethAM, .teethPM, .shower, .skincareAM],
        [.teethAM, .teethPM, .floss, .deodorant, .skincarePM],
        [.teethAM, .shower, .sunscreen],
        [.teethAM, .teethPM, .shower, .deodorant, .skincareAM, .skincarePM],
    ]

    /// One period, day by day: flow, the symptoms noticed and a note.
    private static let reviewDemoPeriodDays: [(flow: PeriodFlowLevel, symptoms: Set<PeriodSymptom>, note: String)] = [
        (.medium, [.cramps, .fatigue], FernletStore.reviewDemoSample("reviewDemo.period.note", "Heating pad and an early night.")),
        (.heavy, [.cramps, .bloating], ""),
        (.medium, [.fatigue], ""),
        (.light, [], ""),
        (.light, [], ""),
    ]
}

/// Drawn stand-ins for the demo's photos (meals, progress, the solo album and the pretend friend's
/// photos): the demo bundles no image assets.
enum ReviewDemoArt {
    /// A warm gradient stand-in for a food photo.
    static func foodImage(hue: CGFloat) -> UIImage {
        let size = CGSize(width: 480, height: 480)
        return gradient(size: size,
                        top: UIColor(hue: hue, saturation: 0.62, brightness: 0.86, alpha: 1),
                        bottom: UIColor(hue: hue, saturation: 0.72, brightness: 0.58, alpha: 1),
                        end: CGPoint(x: size.width, y: size.height))
    }

    /// A cool neutral gradient stand-in for a body photo.
    static func progressImage(hue: CGFloat) -> UIImage {
        let size = CGSize(width: 480, height: 640)
        return gradient(size: size,
                        top: UIColor(hue: hue, saturation: 0.18, brightness: 0.82, alpha: 1),
                        bottom: UIColor(hue: hue, saturation: 0.30, brightness: 0.52, alpha: 1),
                        end: CGPoint(x: 0, y: size.height))
    }

    /// A simple park scene (sky, a sun, grass) as JPEG bytes, a different light per variant.
    static func parkScene(variant: Int) -> Data? {
        let skies: [UInt32] = [0xF3D9A4, 0xA9C6DA, 0xE7D3A8, 0xC9D8E6, 0xF0C9A8, 0xB8D4C8]
        let grass: [UInt32] = [0x9CC08A, 0x8DB879, 0xC9A46A, 0x7FAE6E, 0xA7B86A, 0x92B98C]
        let index = abs(variant) % skies.count
        let size = CGSize(width: 600, height: 750)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let picture = UIGraphicsImageRenderer(size: size, format: format).image { context in
            color(skies[index]).setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.45))
            color(grass[index]).setFill()
            context.fill(CGRect(x: 0, y: size.height * 0.45, width: size.width, height: size.height * 0.55))
            color(0xFFF1CF).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 380 - Double(index % 4) * 90, y: 90, width: 110, height: 110))
        }
        return picture.jpegData(compressionQuality: 0.85)
    }

    /// A two-stop linear gradient tile; a gradient that fails to build falls back to a solid fill.
    private static func gradient(size: CGSize, top: UIColor, bottom: UIColor, end: CGPoint) -> UIImage {
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

    /// A `0xRRGGBB` colour.
    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif
