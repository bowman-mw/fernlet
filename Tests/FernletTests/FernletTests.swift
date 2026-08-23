//
//  FernletTests.swift
//  FernletTests
//
//  Created by Michael Bowman on 5/16/26.
//

import Foundation
import LocalPersistence
import Combine
import CoreData
import HealthKit
import Testing
import FernletFoundation
import FernletDomainModel
import FernletScoring
import FernletPersistence
import FoodCatalog
import CloudKitSync
import StoreCore
import HealthKitGateway
@testable import Fernlet

struct FernletTests {
    @MainActor
    @Test func addWorkoutDispatchesHealthKitSaveTask() async {
        let authorizedService = MockWorkoutHealthKitService(isWorkoutLoggingAuthorized: true)
        let authorizedStore = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("workout-hk-save-authorized")), healthKitService: authorizedService, sensitiveVisibilityDefaults: uniqueSensitiveVisibilityDefaults(), photoDocumentsDirectory: uniquePhotoDirectory())
        authorizedStore.addWorkout(sampleWorkout())
        await waitForAsyncWork { authorizedService.saveWorkoutCallCount == 1 }

        #expect(authorizedService.saveWorkoutCallCount == 1)

        let unauthorizedService = MockWorkoutHealthKitService(isWorkoutLoggingAuthorized: false)
        let unauthorizedStore = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("workout-hk-save-unauthorized")), healthKitService: unauthorizedService, sensitiveVisibilityDefaults: uniqueSensitiveVisibilityDefaults(), photoDocumentsDirectory: uniquePhotoDirectory())
        unauthorizedStore.addWorkout(sampleWorkout())
        await waitForAsyncWork()

        #expect(unauthorizedService.saveWorkoutCallCount == 0)
    }

    @MainActor
    @Test func addWorkoutPersistsHealthKitUUIDOnSuccess() async throws {
        let expectedUUID = UUID()
        let service = MockWorkoutHealthKitService(isWorkoutLoggingAuthorized: true, saveWorkoutUUID: expectedUUID)
        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("workout-hk-uuid")), healthKitService: service, sensitiveVisibilityDefaults: uniqueSensitiveVisibilityDefaults(), photoDocumentsDirectory: uniquePhotoDirectory())
        let workout = sampleWorkout()

        store.addWorkout(workout)
        await waitForAsyncWork { store.day.workouts.first?.healthKitUUID == expectedUUID }

        let saved = try #require(store.day.workouts.first)
        #expect(saved.healthKitUUID == expectedUUID)
    }

    @MainActor
    @Test func goalWeightVectorsProduceExpectedDistinctScores() {
        let scores = Dictionary(uniqueKeysWithValues: GoalType.allCases.map { goal in
            (
                goal,
                FernletScoring.compute(
                    journalTag: .hard,
                    mealCount: 2,
                    workoutCount: 0,
                    sleepQuality: .great,
                    bottleCount: 2,
                    hydrationTarget: 4,
                    hygiene: [.teethAM, .shower],
                    weights: GoalWeights.forGoal(goal)
                )
            )
        })
        let roundedScores = Set(scores.values.map { ($0 * 10_000).rounded() / 10_000 })

        // 7 GoalTypes with wellness==exploring colliding → 6 distinct scores (sportsPrep added a
        // distinct goal after this test was written for 6 goals / 5 distinct).
        #expect(roundedScores.count == 6)
        #expect(scores[.wellness] == scores[.exploring])
        #expect(scores[.wellness] != scores[.strength])
        #expect(scores[.strength] != scores[.weightManagement])
        #expect(scores[.mentalHealth] != scores[.recovery])
    }

    @MainActor
    @Test func sicknessRedistributionZeroesWorkoutWeight() {
        let base = GoalWeights.forGoal(.strength)
        let sick = base.adjustedForSickness(true)

        #expect(sick.workoutWeight == 0)
        #expect(abs(sick.sleepWeight - (base.sleepWeight + base.workoutWeight * 0.5)) < 0.000_001)
        #expect(abs(sick.hydrationWeight - (base.hydrationWeight + base.workoutWeight * 0.3)) < 0.000_001)
        #expect(abs(sick.hygieneWeight - (base.hygieneWeight + base.workoutWeight * 0.2)) < 0.000_001)
        #expect(abs(sick.total - 1.0) < 0.000_001)
    }

    @MainActor
    @Test func hygieneScoreCoversEmptyAndAllChecked() {
        #expect(FernletScoring.hygieneScore([]) == 0.0)
        #expect(FernletScoring.hygieneScore(Set(HygieneItem.allCases)) == 1.0)
    }

    @MainActor
    @Test func personalCareTasksCanBeCustomizedAndPersisted() throws {
        let url = temporaryDatabaseURL("personal-care-custom")
        let repository = LocalFernletRepository(fileURL: url)
        let store = FernletStore(repository: repository, sensitiveVisibilityDefaults: uniqueSensitiveVisibilityDefaults(), photoDocumentsDirectory: uniquePhotoDirectory())

        #expect(store.personalCareTasks.map(\.id) == HygieneItem.allCases.map(\.rawValue))

        store.addPersonalCareTask(label: "Take meds", group: "Morning")
        let customTask = try #require(store.personalCareTasks.first { $0.label == "Take meds" })
        store.togglePersonalCareTask(customTask)

        #expect(store.isPersonalCareTaskCompleted(customTask))
        #expect(store.personalCareProgress().completed == 1)
        store.flushPendingSnapshotSave()

        let loadedStore = FernletStore(date: Date(), repository: repository, sensitiveVisibilityDefaults: uniqueSensitiveVisibilityDefaults(), photoDocumentsDirectory: uniquePhotoDirectory())
        let loadedTask = try #require(loadedStore.personalCareTasks.first { $0.id == customTask.id })

        #expect(loadedTask.label == "Take meds")
        #expect(loadedStore.isPersonalCareTaskCompleted(loadedTask))
    }

    @MainActor
    @Test func pendingRetryCountIncrementsAndDecrements() throws {
        let url = temporaryDatabaseURL("retry-count")
        let repository = LocalFernletRepository(fileURL: url)
        let todayDate = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 5, day: 17)))
        let store = FernletStore(date: todayDate, repository: repository, sensitiveVisibilityDefaults: uniqueSensitiveVisibilityDefaults(), photoDocumentsDirectory: uniquePhotoDirectory())
        let meal = sampleMeal()

        #expect(store.pendingRetryCount == 0)
        store.queueMealRetry(meal)
        #expect(store.pendingRetryCount == 1)
        let retryId = try #require(store.retryQueue.first?.id)
        store.clearRetryItem(retryId)
        #expect(store.pendingRetryCount == 0)
    }

    /// STEP 0b: a non-meal retry enqueued ahead of a meal record must survive the meal retry path.
    /// The meal is processed; the non-meal record is left untouched and is not counted by the badge.
    @MainActor
    @Test func retryOldestMealLeavesNonMealRecordsInQueue() async throws {
        let url = temporaryDatabaseURL("retry-nonmeal-survives")
        let repository = LocalFernletRepository(fileURL: url)
        let todayDate = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 5, day: 17)))
        let store = FernletStore(date: todayDate, repository: repository, sensitiveVisibilityDefaults: uniqueSensitiveVisibilityDefaults(), photoDocumentsDirectory: uniquePhotoDirectory())

        let meal = store.addMeal(from: "oatmeal")
        store.queueMealRetry(meal)
        let nonMeal = AIAnalysisRetryRecord(payloadType: "recipe-synthesis", sourceId: UUID(), note: "keep me")
        // Non-meal record ahead of the meal record.
        store.aiRetryQueueService.apply([nonMeal] + store.retryQueue)

        #expect(store.retryQueue.count == 2)
        #expect(store.pendingRetryCount == 1)  // badge counts only the meal record

        await store.retryOldestMeal()

        #expect(store.retryQueue.contains { $0.id == nonMeal.id })
    }

    /// STEP 0b: with only non-meal records queued, retryOldestMeal is a no-op — nothing is cleared.
    /// (Under the old first-record logic the record's sourceId miss would silently destroy it.)
    @MainActor
    @Test func retryOldestMealIsNoOpWhenOnlyNonMealRecords() async throws {
        let url = temporaryDatabaseURL("retry-nonmeal-noop")
        let repository = LocalFernletRepository(fileURL: url)
        let todayDate = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 5, day: 17)))
        let store = FernletStore(date: todayDate, repository: repository, sensitiveVisibilityDefaults: uniqueSensitiveVisibilityDefaults(), photoDocumentsDirectory: uniquePhotoDirectory())

        let nonMeal = AIAnalysisRetryRecord(payloadType: "recipe-synthesis", sourceId: UUID(), note: "keep me")
        store.aiRetryQueueService.apply([nonMeal])
        #expect(store.pendingRetryCount == 0)

        await store.retryOldestMeal()

        #expect(store.retryQueue.count == 1)
        #expect(store.retryQueue.first?.id == nonMeal.id)
    }

    @Test func fernletVoiceMessagesAreNonEmpty() {
        for voice in FernletVoice.allCases {
            #expect(FernletVoice.message(for: voice).isEmpty == false)
        }
    }

    @Test func volumeRecipeUnitsScaleAgainstMilliliterServings() {
        let oil = FoodItem(
            name: "Olive oil",
            brandSource: nil,
            servingSize: 100,
            servingUnit: RecipeUnit.milliliter.rawValue,
            macros: Macros(protein: 0, carbs: 0, fat: 100),
            micronutrients: Micronutrients(),
            category: "oil",
            source: .manual,
            tags: ["oil"]
        )

        let tablespoon = RecipeIngredient(foodItemId: oil.id, quantity: 1, unit: RecipeUnit.tablespoon.rawValue)
        let teaspoon = RecipeIngredient(foodItemId: oil.id, quantity: 1, unit: RecipeUnit.teaspoon.rawValue)
        let milliliters = RecipeIngredient(foodItemId: oil.id, quantity: 30, unit: RecipeUnit.milliliter.rawValue)

        #expect(tablespoon.scaledMacros(using: oil).fat == 15)
        #expect(teaspoon.scaledMacros(using: oil).fat == 5)
        #expect(milliliters.scaledMacros(using: oil).fat == 30)
    }

    @Test func milliliterFoodItemsPreferTablespoonForOilEntry() {
        let oil = FoodItem(
            name: "Avocado oil",
            brandSource: nil,
            servingSize: 15,
            servingUnit: "mL",
            macros: Macros(protein: 0, carbs: 0, fat: 14),
            micronutrients: Micronutrients(),
            category: "oil",
            source: .manual,
            tags: ["oil"]
        )

        #expect(oil.preferredRecipeUnit == .tablespoon)
        #expect(oil.defaultRecipeQuantity(for: .milliliter) == 15)
    }

    @Test func ingredientSearchRanksCustomItemsAboveUSDAMatches() {
        let customOil = FoodItem(
            name: "House olive oil",
            brandSource: "Custom ingredient",
            servingSize: 15,
            servingUnit: RecipeUnit.milliliter.rawValue,
            macros: Macros(protein: 0, carbs: 0, fat: 14),
            micronutrients: Micronutrients(),
            category: "custom ingredient",
            source: .manual,
            tags: ["recipe", "custom", "oil"]
        )
        let usdaOil = FoodItem(
            name: "Olive oil",
            brandSource: "USDA",
            servingSize: 100,
            servingUnit: RecipeUnit.milliliter.rawValue,
            macros: Macros(protein: 0, carbs: 0, fat: 100),
            micronutrients: Micronutrients(),
            category: "oil",
            source: .usda,
            tags: ["usda", "oil"]
        )

        let results = FoodItemSearch.results(for: "olive oil", in: [usdaOil, customOil], limit: 2)

        #expect(results.first?.id == customOil.id)
        #expect(results.dropFirst().first?.id == usdaOil.id)
    }

    @MainActor
    @Test func addRecipeKeepsSelectedBundledUSDAIngredient() throws {
        let chicken = FoodItem(
            name: "Chicken breast",
            brandSource: "USDA",
            servingSize: 100,
            servingUnit: RecipeUnit.gram.rawValue,
            macros: Macros(protein: 31, carbs: 0, fat: 4),
            micronutrients: Micronutrients(iron: 1.1, potassium: 256),
            category: "Poultry",
            source: .usda,
            tags: ["usda", "chicken"]
        )
        let store = makeTestStore(bundledFoodItems: [chicken])
        var ingredient = ManualRecipeIngredientInput()
        ingredient.name = chicken.name
        ingredient.selectedFoodItemId = chicken.id
        ingredient.quantity = 150
        ingredient.unit = RecipeUnit.gram.rawValue
        ingredient.protein = chicken.macros.protein
        ingredient.fat = chicken.macros.fat

        let recipe = store.addRecipe(
            name: "Chicken bowl",
            servings: 1,
            ingredients: [ingredient]
        )

        let savedIngredient = try #require(recipe.ingredients.first)
        #expect(savedIngredient.foodItemId == chicken.id)
        #expect(savedIngredient.scaledMacros(using: chicken).protein == 47)
        #expect(savedIngredient.scaledMicronutrients(using: chicken).potassium == 384)
        #expect(store.foodItems.isEmpty)
    }

    @Test func compactSurveyFoodDecodesWithSurveyDataType() throws {
        let data = Data(#"""
        [
          {
            "fdcId": 2708953,
            "name": "Rice, fried, with chicken",
            "servingSize": 1,
            "servingUnit": "cup",
            "protein": 13.4,
            "carbs": 45.2,
            "fat": 11.8,
            "category": "Rice mixed dishes",
            "dataType": "survey",
            "source": "usda",
            "tags": ["fried rice", "chicken rice", "asian", "survey"],
            "portions": [{ "amount": 1, "unit": "cup", "gramWeight": 198, "description": "1 cup" }]
          }
        ]
        """#.utf8)

        let item = try #require(FoodDataCatalog.foodItems(from: data).first)

        #expect(item.dataType == .survey)
        #expect(item.source == .usda)
        #expect(item.name == "Rice, fried, with chicken")
        #expect(item.portions.first?.description == "1 cup")
    }

    /// Regression for prior finding #10: for a branded FDC record whose labelNutrients are
    /// missing a macro, the foodNutrients fallback (per 100 g) must be scaled to the per-serving
    /// basis used by the micronutrients — otherwise carbs would be stored per-100g while sodium
    /// is per-serving for the same 30 g item.
    @Test func brandedLabelMacroFallbackSharesPerServingBasisWithMicros() throws {
        let data = Data(#"""
        [
          {
            "fdcId": 99999,
            "description": "Test Branded Snack",
            "dataType": "Branded",
            "brandOwner": "Test Brand",
            "servingSize": 30,
            "servingSizeUnit": "g",
            "labelNutrients": { "protein": { "value": 5 }, "fat": { "value": 3 } },
            "foodNutrients": [
              { "nutrientId": 1005, "amount": 50 },
              { "nutrientId": 1093, "amount": 1000 }
            ]
          }
        ]
        """#.utf8)

        let item = try #require(FoodDataCatalog.foodItems(from: data).first)

        #expect(item.servingSize == 30)
        #expect(item.macros.protein == 5)
        #expect(item.macros.fat == 3)
        // carbs absent from the label → foodNutrients 50 g/100g scaled to the 30 g serving = 15 g.
        #expect(item.macros.carbs == 15)
        // sodium (a micronutrient) is on the same per-serving basis: 1000 mg/100g × 0.3 = 300 mg.
        #expect(item.micronutrients.sodium == 300)
    }

    @Test func surveyFoodsParticipateInBundledFoodSearch() throws {
        let data = Data(#"""
        [
          {
            "fdcId": 2708953,
            "name": "Rice, fried, with chicken",
            "servingSize": 1,
            "servingUnit": "cup",
            "protein": 13.4,
            "carbs": 45.2,
            "fat": 11.8,
            "category": "Survey (FNDDS) - Fried rice and lo/chow mein",
            "dataType": "survey",
            "source": "usda",
            "tags": ["fried rice", "chicken rice", "asian", "survey"]
          }
        ]
        """#.utf8)
        let surveyItems = FoodDataCatalog.foodItems(from: data)
        let foundationRice = FoodItem(
            name: "Rice, white, cooked",
            brandSource: "USDA",
            servingSize: 100,
            servingUnit: "g",
            macros: Macros(protein: 3, carbs: 28, fat: 0),
            micronutrients: Micronutrients(),
            category: "Foundation Foods",
            source: .usda,
            dataType: .foundation,
            tags: ["rice", "foundation"]
        )

        let results = FoodItemSearch.results(for: "chicken fried rice", in: [foundationRice] + surveyItems, limit: 2)

        #expect(results.first?.name == "Rice, fried, with chicken")
        #expect(results.first?.dataType == .survey)
    }

    @Test func dishTemplateResolutionStillUsesComponentsBeforeSurveyWholeDish() throws {
        let surveyTaco = FoodItem(
            name: "Taco, NFS",
            brandSource: "USDA FDC 2708514",
            servingSize: 1,
            servingUnit: "taco",
            macros: Macros(protein: 12, carbs: 18, fat: 9),
            micronutrients: Micronutrients(),
            category: "Survey (FNDDS) - Burritos and tacos",
            source: .usda,
            dataType: .survey,
            tags: ["taco", "survey", "fndds"]
        )
        let componentItems = [
            surveyComponentFood(name: "Cooked beef ground cooked", tags: ["cooked", "beef", "ground"]),
            surveyComponentFood(name: "Tortilla corn", tags: ["tortilla", "corn"]),
            // Research §26 fix 1.3 repaired taco's cheese/lettuce search strings ("cheese shredded" →
            // "cheese cheddar" bound the wrong food, "lettuce" → "lettuce iceberg raw"); these fixture
            // names are the exact matches for the NEW queries.
            surveyComponentFood(name: "Cheese cheddar", tags: ["cheese", "cheddar"]),
            surveyComponentFood(name: "Lettuce iceberg raw", tags: ["lettuce", "iceberg", "raw"])
        ]

        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([surveyTaco] + componentItems))
        let resolved = try #require(DishTemplateLexicon.resolve(
            description: "taco",
            mealType: nil,
            catalog: catalog
        ))
        let meal = try #require(resolved.meals.first)

        #expect(meal.componentSnapshots.count >= 4)
        #expect(!meal.componentSnapshots.contains { $0.name == surveyTaco.name })
        // Every component here is an exact name match, so the bind-quality derivation (research §26
        // fix 1.1) still yields `.high` — a clean template resolution keeps auto-committing.
        #expect(resolved.confidence == .high)
    }

    @MainActor
    @Test func intimacyAgeGateControlsHubAndQuickLogVisibility() {
        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("intimacy-age-gate")), sensitiveVisibilityDefaults: uniqueSensitiveVisibilityDefaults(), photoDocumentsDirectory: uniquePhotoDirectory())
        // The 16+ gate reads the device-local age record, not the profile stepper. Set explicitly in
        // both directions so a record left behind by another test can never decide this one.
        store.ageAssurance.applyDetermination(
            lowerBound: AgeGate.chat.minimumAge,
            upperBound: AgeGate.intimacy.minimumAge,
            provenance: .guardianDeclared
        )

        #expect(!store.isIntimateLoggingAllowed)
        // The merged Cycle section carries the intimacy half; with period ALSO hidden in this
        // fixture (fresh store: `periodTrackingVisible` nil, `sex` defaults `.male`), the underage
        // gate must remove the whole page.
        #expect(!store.isPeriodTrackingVisible)
        #expect(!PrivateHubSection.visibleSections(visibility: store.sensitiveSurfaceVisibility).contains(.cycle))

        let quickLogItems = FernletShortcut.visibleQuickLog(
            [.meal, .water, .move, .sleep, .journal, .intimacyTracking],
            visibility: store.sensitiveSurfaceVisibility
        )
        #expect(!quickLogItems.contains(.intimacyTracking))

        store.ageAssurance.applyDetermination(
            lowerBound: AgeGate.intimacy.minimumAge,
            upperBound: nil,
            provenance: .selfDeclared
        )

        #expect(store.isIntimateLoggingAllowed)
        #expect(PrivateHubSection.visibleSections(visibility: store.sensitiveSurfaceVisibility).contains(.cycle))
    }

    @MainActor
    @Test func workoutSuggestionLibraryReturnsSuggestionForEachGoal() {
        for goal in GoalType.allCases {
            let suggestions = WorkoutSuggestionLibrary.suggestions(for: goal, intensity: .moderate)

            #expect(suggestions.isEmpty == false)
            #expect(suggestions.first?.workout(intensity: .moderate).mode == .strengthTraining)
        }
    }

    @Test func journalMonthModelUsesActualMonthLengthAndToday() throws {
        let calendar = Calendar(identifier: .gregorian)
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 17)))
        let model = JournalMonthModel(
            date: date,
            allDays: [:],
            todayKey: "2026-05-17",
            calendar: calendar
        )
        let dayCells = model.cells.compactMap(\.day)

        #expect(dayCells.count == 31)
        #expect(dayCells.first == 1)
        #expect(dayCells.last == 31)
        #expect(model.cells.contains { $0.day == 17 && $0.isToday })
    }

    @Test func monthGridModelDayKeysStayCanonicalInEdgeLocales() throws {
        // The shared grid must key its days with the pinned POSIX/Gregorian FernletDate.dayKey
        // even when the layout calendar is non-Gregorian and the locale uses non-Latin digits —
        // exactly the configurations where locale-following formatters produce garbage keys that
        // miss every event/today lookup.
        var calendar = Calendar(identifier: .buddhist)
        calendar.locale = Locale(identifier: "ar_SA")
        // Buddhist era 2569 = Gregorian 2026, so this is 2026-05-17.
        let date = try #require(calendar.date(from: DateComponents(year: 2569, month: 5, day: 17)))
        let model = MonthGridModel(date: date, todayKey: FernletDate.dayKey(for: date), calendar: calendar)

        #expect(model.days.count == 31)
        #expect(model.days.first?.dateKey == "2026-05-01")
        #expect(model.days.contains { $0.day == 17 && $0.isToday })
        for day in model.days {
            let cellDate = try #require(day.date)
            #expect(day.dateKey == FernletDate.dayKey(for: cellDate))
        }
    }

    @MainActor
    @Test func localRepositoryPersistsCurrentSnapshot() {
        let url = temporaryDatabaseURL("snapshot")
        let repository = LocalFernletRepository(fileURL: url)
        let day = FernletDay(date: "2026-05-16", meals: [sampleMeal()], workouts: [], journals: [], sleep: nil, bottleCount: 1)
        let snapshot = FernletSnapshot(todayKey: "2026-05-16", day: day, settings: FernletSettings(), recentMeals: [], previousJournals: [], memories: [], goals: [], workshop: WorkshopData())

        let saved = repository.saveSnapshot(snapshot)
        let loaded = repository.loadSnapshot(todayKey: "2026-05-16")

        #expect(saved)
        #expect(loaded.day.meals.count == 1)
        #expect(loaded.day.bottleCount == 1)
    }

    @MainActor
    @Test func localDatabaseBuildsTableRecordsFromSnapshot() throws {
        let url = temporaryDatabaseURL("tables")
        let repository = LocalFernletRepository(fileURL: url)
        let day = FernletDay(date: "2026-05-16", meals: [sampleMeal()], workouts: [sampleWorkout()], journals: [sampleJournal()], sleep: nil)
        let snapshot = FernletSnapshot(todayKey: "2026-05-16", day: day, settings: FernletSettings(), recentMeals: [], previousJournals: [], memories: [], goals: [], workshop: WorkshopData())

        #expect(repository.saveSnapshot(snapshot))
        let data = try Data(contentsOf: url)
        let database = try testDecoder.decode(LocalFernletDatabase.self, from: data)

        #expect(database.dailyLogs.count == 1)
        #expect(database.mealLogs.count == 1)
        #expect(database.workoutLogs.count == 1)
        #expect(database.journalLogs.count == 1)
    }

    @MainActor
    @Test func localRepositoryRefusesSaveAfterDecodeFailure() throws {
        let url = temporaryDatabaseURL("corrupt-local")
        let corruptData = Data("not-json".utf8)
        try corruptData.write(to: url)
        let repository = LocalFernletRepository(fileURL: url)
        let replacement = FernletSnapshot(todayKey: "2026-05-16", day: FernletDay(date: "2026-05-16", bottleCount: 4), settings: FernletSettings(), recentMeals: [], previousJournals: [], memories: [], goals: [], workshop: WorkshopData())

        _ = repository.loadSnapshot(todayKey: "2026-05-16")
        let saved = repository.saveSnapshot(replacement)
        let persisted = try Data(contentsOf: url)

        #expect(saved == false)
        #expect(persisted == corruptData)
    }

    @MainActor
    @Test func coreDataRepositoryPersistsCurrentSnapshot() {
        let repository = CoreDataFernletRepository(
            controller: PersistenceController(inMemory: true),
            legacyRepository: LocalFernletRepository(fileURL: temporaryDatabaseURL("empty-coredata-legacy"))
        )
        let day = FernletDay(date: "2026-05-16", meals: [sampleMeal()], workouts: [], journals: [], sleep: nil, bottleCount: 2)
        let snapshot = FernletSnapshot(todayKey: "2026-05-16", day: day, settings: FernletSettings(), recentMeals: [], previousJournals: [], memories: [], goals: [], workshop: WorkshopData())

        let saved = repository.saveSnapshot(snapshot)
        let loaded = repository.loadSnapshot(todayKey: "2026-05-16")

        #expect(saved)
        #expect(loaded.day.meals.count == 1)
        #expect(loaded.day.bottleCount == 2)
    }

    @MainActor
    @Test func coreDataRepositoryRefusesSaveAfterFetchFailure() throws {
        let controller = PersistenceController(inMemory: true)
        let repository = CoreDataFernletRepository(
            controller: controller,
            legacyRepository: LocalFernletRepository(fileURL: temporaryDatabaseURL("empty-coredata-fetch-failure-legacy"))
        )
        let snapshot = FernletSnapshot(todayKey: "2026-05-16", day: FernletDay(date: "2026-05-16", bottleCount: 2), settings: FernletSettings(), recentMeals: [], previousJournals: [], memories: [], goals: [], workshop: WorkshopData())
        #expect(repository.saveSnapshot(snapshot))

        // While a fetch is failing, the save's own reload returns the empty fallback, so the
        // save must be refused rather than overwriting the real record with empty data.
        repository.invalidateCache()
        repository.forceNextFetchFailureForTesting(CocoaError(.fileReadUnknown))
        let replacement = FernletSnapshot(todayKey: "2026-05-16", day: FernletDay(date: "2026-05-16", bottleCount: 9), settings: FernletSettings(), recentMeals: [], previousJournals: [], memories: [], goals: [], workshop: WorkshopData())
        #expect(repository.saveSnapshot(replacement) == false)

        // The original record must be intact after the refused save.
        repository.invalidateCache()
        #expect(repository.loadSnapshot(todayKey: "2026-05-16").day.bottleCount == 2)

        // A transient fetch failure must not brick saves for the session: once the store is
        // readable again, saves resume and persist correctly.
        #expect(repository.saveSnapshot(replacement))
        repository.invalidateCache()
        #expect(repository.loadSnapshot(todayKey: "2026-05-16").day.bottleCount == 9)
    }

    @MainActor
    @Test func coreDataRepositoryRefusesSaveAfterDecodeFailure() throws {
        let controller = PersistenceController(inMemory: true)
        let repository = CoreDataFernletRepository(
            controller: controller,
            legacyRepository: LocalFernletRepository(fileURL: temporaryDatabaseURL("empty-coredata-corrupt-legacy"))
        )
        let snapshot = FernletSnapshot(todayKey: "2026-05-16", day: FernletDay(date: "2026-05-16", bottleCount: 2), settings: FernletSettings(), recentMeals: [], previousJournals: [], memories: [], goals: [], workshop: WorkshopData())
        #expect(repository.saveSnapshot(snapshot))

        let corruptData = Data("not-json".utf8)
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "FernletDatabaseRecord")
        request.predicate = NSPredicate(format: "recordID == %@", "primary")
        let record = try #require(try context.fetch(request).first)
        record.setValue(corruptData, forKey: "payloadData")
        try context.save()

        let reloadedRepository = CoreDataFernletRepository(
            controller: controller,
            legacyRepository: LocalFernletRepository(fileURL: temporaryDatabaseURL("empty-coredata-corrupt-legacy-reload"))
        )
        _ = reloadedRepository.loadSnapshot(todayKey: "2026-05-16")
        let replacement = FernletSnapshot(todayKey: "2026-05-16", day: FernletDay(date: "2026-05-16", bottleCount: 9), settings: FernletSettings(), recentMeals: [], previousJournals: [], memories: [], goals: [], workshop: WorkshopData())
        let saved = reloadedRepository.saveSnapshot(replacement)
        let persistedRecord = try #require(try context.fetch(request).first)

        #expect(saved == false)
        #expect(persistedRecord.value(forKey: "payloadData") as? Data == corruptData)
        // The day row must also be untouched: the row write is skipped under read-only recovery, so a
        // refused save can't corrupt the row (regression guard for the isPersistenceBlocked check).
        let dayRow = DayRecordRepository(controller: controller).load(dateKeys: ["2026-05-16"])["2026-05-16"]
        #expect(dayRow?.bottleCount == 2)
    }

    /// A remote-change reload keys on `isInReadOnlyRecovery` to decide whether the snapshot it just
    /// loaded is real data or the empty read-only fallback. This asserts the flag it depends on: a
    /// transient fetch failure returns the empty snapshot AND reports recovery, and a subsequent
    /// successful load returns the real data AND clears the flag. If this flag ever failed to track
    /// the load outcome, `FernletStore.reloadFromRepository` would apply the empty snapshot over live
    /// state and blank every screen (the "page blanks out, then loads" bug).
    ///
    /// A fresh repository on an EMPTY in-memory store. Deliberately never saves through it before the
    /// assertions: a save runs `context.save()`, which fires a CloudKit remote-change whose debounced
    /// subscription can repopulate the (cache-checked) load path mid-test — the exact race that makes
    /// a save-then-fail sequence read cached real data instead of the forced failure under the
    /// parallel suite. With no save, the cache stays cold and the forced fetch failure is
    /// deterministic. `.failed` and `.missing`/`.found` set/clear the recovery latch via the same
    /// `markPersistenceBlockedBy…` / `clearReadOnlyRecoveryFlags` calls in both the sync `loadSnapshot`
    /// and the async `loadSnapshotAsync` that `reloadFromRepository` actually calls, so this is
    /// faithful coverage of the flag that guard depends on.
    @MainActor
    @Test func coreDataRepositoryReportsReadOnlyRecoveryForEmptyFallback() {
        let repository = CoreDataFernletRepository(
            controller: PersistenceController(inMemory: true),
            legacyRepository: LocalFernletRepository(fileURL: temporaryDatabaseURL("empty-coredata-recovery-flag-legacy"))
        )
        #expect(repository.isInReadOnlyRecovery == false)

        // A failed fetch returns the empty fallback AND latches read-only recovery — the exact state
        // in which reloadFromRepository must NOT apply the (empty) snapshot over live data.
        repository.forceNextFetchFailureForTesting(CocoaError(.fileReadUnknown))
        let fallback = repository.loadSnapshot(todayKey: "2026-05-16")
        #expect(fallback.day.meals.isEmpty, "a failed fetch must return the empty fallback")
        #expect(repository.isInReadOnlyRecovery, "a failed fetch must latch read-only recovery")

        // A subsequent readable load (here: no record present → the legitimate empty case) clears the
        // latch, so the next reload is free to apply real data.
        repository.invalidateCache()
        _ = repository.loadSnapshot(todayKey: "2026-05-16")
        #expect(repository.isInReadOnlyRecovery == false, "a readable load must clear recovery")
    }

    @MainActor
    @Test func coreDataRepositoryUpdatesPastDayAndLoadsAllDays() {
        let repository = CoreDataFernletRepository(
            controller: PersistenceController(inMemory: true),
            legacyRepository: LocalFernletRepository(fileURL: temporaryDatabaseURL("empty-coredata-past-day-legacy"))
        )
        let today = "2026-05-17"
        let past = "2026-05-16"
        // `today` carries logged content (bottleCount) so it deterministically gets its own DayRecord row:
        // an empty day writes no row (a device that merely launched must not stamp "existing data"), which
        // would leave `today` out of loadAllDays.
        let todaySnapshot = FernletSnapshot(todayKey: today, day: FernletDay(date: today, bottleCount: 3), settings: FernletSettings(), recentMeals: [], previousJournals: [], memories: [], goals: [], workshop: WorkshopData())
        let pastDay = FernletDay(date: past, meals: [sampleMeal()], workouts: [sampleWorkout()], journals: [sampleJournal()], sleep: nil)

        #expect(repository.saveSnapshot(todaySnapshot))
        #expect(repository.updateDay(pastDay, for: past, todayKey: today))

        let allDays = repository.loadAllDays()
        let pastSnapshot = repository.loadSnapshot(todayKey: past)
        #expect(allDays.keys.sorted() == [past, today])
        #expect(pastSnapshot.day.meals.count == 1)
        #expect(repository.loadTierTwoMemories().count <= FernletLimits.derivedLogWindowDays)
    }

    @MainActor
    @Test func coreDataRepositoryMigratesLegacyJSONOnFirstLoad() {
        let legacyRepository = LocalFernletRepository(fileURL: temporaryDatabaseURL("legacy-coredata-snapshot"))
        let day = FernletDay(date: "2026-05-16", meals: [sampleMeal()], workouts: [], journals: [], sleep: nil, bottleCount: 3)
        let snapshot = FernletSnapshot(todayKey: "2026-05-16", day: day, settings: FernletSettings(), recentMeals: [sampleMeal()], previousJournals: [], memories: [], goals: [], workshop: WorkshopData())
        #expect(legacyRepository.saveSnapshot(snapshot))

        let repository = CoreDataFernletRepository(
            controller: PersistenceController(inMemory: true),
            legacyRepository: legacyRepository
        )

        let migrated = repository.loadSnapshot(todayKey: "2026-05-16")
        let reloaded = repository.loadSnapshot(todayKey: "2026-05-16")

        #expect(migrated.day.bottleCount == 3)
        #expect(migrated.recentMeals.count == 1)
        #expect(reloaded.day.meals.count == 1)
    }

    @MainActor
    @Test func programmaticCoreDataModelIsCloudKitCompatible() {
        let model = PersistenceController(inMemory: true).container.managedObjectModel
        let entities = Dictionary(uniqueKeysWithValues: model.entities.compactMap { entity in
            entity.name.map { ($0, entity) }
        })

        #expect(entities["FernletDatabaseRecord"] != nil)
        #expect(entities["SavedRecipeRecord"] != nil)
        for entity in model.entities {
            for property in entity.properties {
                if let attribute = property as? NSAttributeDescription {
                    #expect(attribute.isOptional || attribute.defaultValue != nil)
                }
                #expect((property as? NSRelationshipDescription) == nil)
            }
        }
    }

    @MainActor
    @Test func retryRecordsRoundTripThroughJSON() throws {
        let record = AIAnalysisRetryRecord(payloadType: "meal", sourceId: UUID(), note: "Analyze later")
        let data = try testEncoder.encode(record)
        let decoded = try testDecoder.decode(AIAnalysisRetryRecord.self, from: data)

        #expect(decoded.payloadType == "meal")
        #expect(decoded.note == "Analyze later")
    }

    @MainActor
    @Test func mealLoggedWithPastDateKeyIsStoredOnThatDate() throws {
        let url = temporaryDatabaseURL("past-date-meal")
        let repository = LocalFernletRepository(fileURL: url)
        let today = "2026-05-17"
        let past = "2026-05-16"
        let todayDate = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 5, day: 17)))
        let store = FernletStore(date: todayDate, repository: repository, sensitiveVisibilityDefaults: uniqueSensitiveVisibilityDefaults(), photoDocumentsDirectory: uniquePhotoDirectory())

        store.addMeal(from: "oatmeal and eggs", type: .breakfast, date: past)
        let todaySnapshot = repository.loadSnapshot(todayKey: today)
        let pastSnapshot = repository.loadSnapshot(todayKey: past)

        #expect(todaySnapshot.day.meals.isEmpty)
        #expect(pastSnapshot.day.date == past)
        #expect(pastSnapshot.day.meals.count == 1)
    }

    @MainActor
    @Test func journalsCanBeEditedAndDeleted() throws {
        let url = temporaryDatabaseURL("journal-edit")
        let repository = LocalFernletRepository(fileURL: url)
        let todayDate = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 5, day: 17)))
        let store = FernletStore(date: todayDate, repository: repository, sensitiveVisibilityDefaults: uniqueSensitiveVisibilityDefaults(), photoDocumentsDirectory: uniquePhotoDirectory())

        store.addJournal(text: "Original journal text", tag: .neutral)
        let entry = try #require(store.day.journals.first)

        store.updateJournal(entry, text: "Edited journal text", tag: .good, date: store.todayKey)

        #expect(store.day.journals.count == 1)
        #expect(store.day.journals[0].text == "Edited journal text")
        #expect(store.day.journals[0].tag == .good)

        store.deleteJournal(entry, date: store.todayKey)

        #expect(store.day.journals.isEmpty)
        #expect(store.previousJournals.isEmpty)
    }

    @MainActor
    @Test func foodItemsRoundTripThroughJSONWithNilAndNonNilLastVerified() throws {
        let verifiedAt = try fixedDate()
        let items = [
            sampleFoodItem(name: "Apple", lastVerified: nil),
            sampleFoodItem(name: "Greek Yogurt", lastVerified: verifiedAt)
        ]

        let data = try testEncoder.encode(items)
        let decoded = try testDecoder.decode([FoodItem].self, from: data)

        #expect(decoded == items)
        #expect(decoded[0].lastVerified == nil)
        #expect(decoded[1].lastVerified == verifiedAt)
    }

    @Test func legacySavedRecipeJSONRepositoryPersistsRecipes() throws {
        let url = temporaryDatabaseURL("saved-recipes")
        let repository = LegacySavedRecipeJSONRepository(fileURL: url)
        let recipe = RecipeDefinition(
            name: "Lentil Soup",
            servings: 4,
            ingredients: [],
            notes: "Simmer until tender.",
            source: MealLogSource.webImport,
            createdAt: try fixedDate(),
            updatedAt: try fixedDate(),
            webImport: RecipeWebImport(
                sourceURLString: "https://example.com/recipe",
                ingredientLines: ["lentils", "carrots", "stock"],
                macros: Macros(protein: 18, carbs: 42, fat: 6)
            )
        )

        #expect(repository.save([recipe]))

        let loaded = repository.load()
        let stored = try #require(loaded.first)
        #expect(loaded.count == 1)
        #expect(stored.id == recipe.id)
        #expect(stored.webImport?.sourceURLString == recipe.webImport?.sourceURLString)
        #expect(stored.webImport?.ingredientLines == recipe.webImport?.ingredientLines)
        #expect(stored.servings == 4)
    }

    @MainActor
    @Test func savedRecipeRepositoryPersistsRecipesInCoreData() throws {
        let controller = PersistenceController(inMemory: true)
        let repository = SavedRecipeRepository(controller: controller, legacyRepository: LegacySavedRecipeJSONRepository(fileURL: temporaryDatabaseURL("empty-legacy-saved-recipes")))
        let soup = RecipeDefinition(
            name: "Lentil Soup",
            servings: 4,
            ingredients: [],
            notes: "Simmer until tender.",
            source: MealLogSource.webImport,
            createdAt: try fixedDate(),
            updatedAt: try fixedDate(),
            webImport: RecipeWebImport(
                sourceURLString: "https://example.com/soup",
                ingredientLines: ["lentils", "carrots", "stock"],
                macros: Macros(protein: 18, carbs: 42, fat: 6)
            )
        )
        let oatsDate = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 5, day: 18)))
        let oats = RecipeDefinition(
            name: "Overnight Oats",
            servings: 1,
            ingredients: [],
            notes: "Chill overnight.",
            source: MealLogSource.webImport,
            createdAt: oatsDate,
            updatedAt: oatsDate,
            webImport: RecipeWebImport(
                sourceURLString: "https://example.com/oats",
                ingredientLines: ["oats", "milk"]
            )
        )

        #expect(repository.upsert([soup, oats]))

        let loaded = repository.load()
        #expect(loaded.map(\.name) == ["Overnight Oats", "Lentil Soup"])
        #expect(loaded.first?.webImport?.ingredientLines == ["oats", "milk"])
        #expect(loaded.last?.webImport?.macros.protein == 18)
    }

    @MainActor
    @Test func savedRecipeRepositoryMigratesLegacyJSONOnFirstLoad() throws {
        let legacyURL = temporaryDatabaseURL("legacy-saved-recipes")
        let legacyRepository = LegacySavedRecipeJSONRepository(fileURL: legacyURL)
        let recipe = RecipeDefinition(
            name: "Migrated Recipe",
            servings: 1,
            ingredients: [],
            notes: "Legacy recipe.",
            source: MealLogSource.webImport,
            createdAt: try fixedDate(),
            updatedAt: try fixedDate(),
            webImport: RecipeWebImport(
                sourceURLString: "https://example.com/migrated",
                ingredientLines: ["beans", "rice"]
            )
        )
        #expect(legacyRepository.save([recipe]))

        let repository = SavedRecipeRepository(
            controller: PersistenceController(inMemory: true),
            legacyRepository: legacyRepository,
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )

        let migrated = repository.load()
        let reloaded = repository.load()

        #expect(migrated.map(\.id) == [recipe.id])
        #expect(reloaded.map(\.id) == [recipe.id])
        #expect(reloaded.first?.webImport?.ingredientLines == ["beans", "rice"])
    }

    @MainActor
    @Test func dailyHealthScoresRoundTripThroughJSONWithNilAndNonNilSummary() throws {
        let computedAt = try fixedDate()
        let scores = [
            DailyHealthScore(dateKey: "2026-05-16", score: 0.72, companionState: .okay, daySummaryText: nil, computedAt: computedAt),
            DailyHealthScore(dateKey: "2026-05-17", score: 0.84, companionState: .thriving, daySummaryText: "A steady day with enough care.", computedAt: computedAt)
        ]

        let data = try testEncoder.encode(scores)
        let decoded = try testDecoder.decode([DailyHealthScore].self, from: data)

        #expect(decoded == scores)
        #expect(decoded[0].daySummaryText == nil)
        #expect(decoded[1].daySummaryText == "A steady day with enough care.")
    }

    @Test func derivedSignalsUseRollingLocalLogs() throws {
        let days = (1...14).map { index in
            let key = "2026-05-\(String(format: "%02d", index))"
            if index >= 12 {
                return (
                    key,
                    FernletDay(
                        date: key,
                        meals: [],
                        workouts: [
                            Workout(
                                name: "Hard session",
                                type: .mixed,
                                exercises: "Intervals",
                                rpe: 9,
                                notes: "Heavy",
                                duration: 120,
                                intensity: .hard
                            )
                        ],
                        journals: [JournalEntry(text: "Very depleted.", tag: .hard)],
                        sleep: SleepLog(hours: 5, quality: .poor, note: "Broken")
                    )
                )
            }
            return (
                key,
                FernletDay(
                    date: key,
                    meals: [sampleMeal(), sampleMeal(), sampleMeal()],
                    workouts: index >= 8 ? [sampleWorkout()] : [],
                    journals: [JournalEntry(text: "Steady.", tag: .good)],
                    sleep: SleepLog(hours: 8, quality: .good, note: "Solid")
                )
            )
        }

        let signals = DerivedSignalFactory.makeSignals(from: days, todayKey: "2026-05-14")

        #expect(signals.first { $0.signalName == "moodTrend" }?.value == "needs gentleness")
        #expect(signals.first { $0.signalName == "energyTrend" }?.value == "low")
        #expect(signals.first { $0.signalName == "eatingPattern" }?.value == "light")
        #expect(signals.first { $0.signalName == "progressionTrend" }?.value == "building")
        #expect(signals.first { $0.signalName == "intensityReadiness" }?.value == "ready for light")
    }

    @MainActor
    @Test func coreMemoriesCanBeEditedAndDeleted() {
        let url = temporaryDatabaseURL("memory-editing")
        let store = FernletStore(repository: LocalFernletRepository(fileURL: url), sensitiveVisibilityDefaults: uniqueSensitiveVisibilityDefaults(), photoDocumentsDirectory: uniquePhotoDirectory())
        let memory = MemoryNote(category: "quiet", text: "Long enough journal text to become a visible memory.")
        store.memories = [memory]

        store.updateMemory(memory, category: "recovery", text: "Prefers gentler evenings after hard workdays.")

        #expect(store.memories.count == 1)
        #expect(store.memories[0].category == "recovery")
        #expect(store.memories[0].text == "Prefers gentler evenings after hard workdays.")

        store.deleteMemory(memory)

        #expect(store.memories.isEmpty)
    }

    @MainActor
    @Test func storeUsesStoredDailyHealthScoreSummary() throws {
        let url = temporaryDatabaseURL("daily-score-summary")
        let repository = LocalFernletRepository(fileURL: url)
        let date = "2026-05-17"
        let computedAt = try fixedDate()
        let score = DailyHealthScore(
            dateKey: date,
            score: 0.84,
            companionState: .thriving,
            daySummaryText: "Stored summary from earlier analysis.",
            computedAt: computedAt
        )
        let snapshot = FernletSnapshot(
            todayKey: date,
            day: FernletDay(date: date, meals: [sampleMeal()]),
            settings: FernletSettings(),
            recentMeals: [],
            previousJournals: [],
            memories: [],
            goals: [],
            workshop: WorkshopData(),
            dailyScores: [score]
        )
        #expect(repository.saveSnapshot(snapshot))

        let store = FernletStore(date: computedAt, repository: repository, sensitiveVisibilityDefaults: uniqueSensitiveVisibilityDefaults(), photoDocumentsDirectory: uniquePhotoDirectory())
        let stored = store.dailyHealthScore(for: date, day: store.day)

        #expect(stored.daySummaryText == "Stored summary from earlier analysis.")
        #expect(stored.score == 0.84)
        #expect(stored.companionState == .thriving)
    }

    @MainActor
    @Test func localDatabaseStoresRollingMicronutrientGapSignals() throws {
        let url = temporaryDatabaseURL("rolling-micronutrient-gaps")
        let repository = LocalFernletRepository(fileURL: url)
        let today = "2026-05-14"

        for day in 1...14 {
            let key = "2026-05-\(String(format: "%02d", day))"
            let log = FernletDay(
                date: key,
                meals: [
                    sampleMeal(micronutrients: Micronutrients(
                        fiber: 8,
                        sugar: 12,
                        vitaminC: 90,
                        calcium: 100,
                        iron: 3
                    ))
                ]
            )
            #expect(repository.updateDay(log, for: key, todayKey: today))
        }

        let data = try Data(contentsOf: url)
        let database = try testDecoder.decode(LocalFernletDatabase.self, from: data)
        let signals = DerivedSignalsRebuilder.rebuild(allDays: database.days, todayKey: today)
        let sevenDaySignal = try #require(signals.first { $0.signalName == "micronutrientGaps7Day" })
        let fourteenDaySignal = try #require(signals.first { $0.signalName == "micronutrientGaps14Day" })

        #expect(sevenDaySignal.nutrientGaps.contains { $0.nutrientKey == "calcium" && $0.status == .gap })
        #expect(fourteenDaySignal.nutrientGaps.contains { $0.nutrientKey == "vitaminC" && $0.status == .covered })
    }

    @Test func bundledUSDAFoodItemsAreAvailable() throws {
        let source = try #require(SQLiteBundledFoodSource(), "FoodCatalog.sqlite must be bundled")

        #expect(source.count > 0)
        #expect(source.exactMatch(normalizedName: FoodItemSearch.normalized("Chicken breast, roasted")) != nil)
        // Exercises the FTS candidate path against the real bundled DB on the simulator.
        #expect(source.candidates(forQuery: "chicken").isEmpty == false)
    }

    private var testEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var testDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func temporaryDatabaseURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FernletTests-\(name)-\(UUID().uuidString)")
            .appendingPathExtension("json")
        #expect(url.pathExtension == "json")
        return url
    }

    private func sampleMeal() -> Meal {
        Meal(name: "Eggs Toast", mealType: .breakfast, macros: Macros(protein: 22, carbs: 34, fat: 14), quality: .good, confidence: "Manual", note: "Test meal", source: "Manual")
    }

    private func sampleMeal(micronutrients: Micronutrients) -> Meal {
        Meal(
            name: "Eggs Toast",
            mealType: .breakfast,
            macros: Macros(protein: 22, carbs: 34, fat: 14),
            micronutrientSnapshot: micronutrients,
            quality: .good,
            confidence: "Manual",
            note: "Test meal",
            source: "Manual"
        )
    }

    private func sampleWorkout() -> Workout {
        Workout(name: "Upper", type: .upper, exercises: "DB row 3x10", rpe: 7, notes: "steady", duration: 35, intensity: .moderate)
    }

    private func sampleJournal() -> JournalEntry {
        JournalEntry(text: "A steady test day with enough done.", tag: .good, emotions: ["steady"])
    }

    private func sampleFoodItem(name: String, lastVerified: Date?) -> FoodItem {
        FoodItem(
            name: name,
            brandSource: nil,
            servingSize: 100,
            servingUnit: "g",
            macros: Macros(protein: 10, carbs: 12, fat: 3),
            micronutrients: Micronutrients(vitaminC: 4.5, calcium: 80, potassium: 120),
            category: "test",
            source: .manual,
            lastVerified: lastVerified,
            tags: ["fixture"]
        )
    }

    private func surveyComponentFood(name: String, tags: [String]) -> FoodItem {
        FoodItem(
            name: name,
            brandSource: "USDA",
            servingSize: 100,
            servingUnit: "g",
            macros: Macros(protein: 10, carbs: 10, fat: 5),
            micronutrients: Micronutrients(),
            category: "Foundation Foods",
            source: .usda,
            dataType: .foundation,
            tags: tags
        )
    }

    private func fixedDate() throws -> Date {
        try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 5, day: 17, hour: 12)))
    }

    @MainActor
    private func waitForAsyncWork(until condition: @MainActor @escaping () -> Bool = { true }) async {
        for _ in 0..<30 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class MockWorkoutHealthKitService: HealthKitServicing {
    private(set) var saveWorkoutCallCount = 0
    let saveWorkoutUUID: UUID
    private let isWorkoutLoggingAuthorized: Bool

    init(isWorkoutLoggingAuthorized: Bool, saveWorkoutUUID: UUID = UUID()) {
        self.isWorkoutLoggingAuthorized = isWorkoutLoggingAuthorized
        self.saveWorkoutUUID = saveWorkoutUUID
    }

    func isHealthDataAvailable() -> Bool { true }
    func requestAuthorization(for capability: HealthCapability) async throws -> AuthorizationOutcome { AuthorizationOutcome(writeStatuses: [:]) }
    func currentAuthorizationSnapshot() -> AuthorizationSnapshot {
        let statuses = isWorkoutLoggingAuthorized
            ? [HKObjectType.workoutType().identifier: HKAuthorizationStatus.sharingAuthorized]
            : [:]
        return AuthorizationSnapshot(isAvailable: true, writeStatuses: statuses)
    }
    func startObserving(_ type: HKSampleType, handler: @escaping (HKAnchoredObjectQuery, [HKSample], [HKDeletedObject]) -> Void) async throws { }
    func startObservingWorkouts(handler: @escaping ([HKWorkout], [UUID]) -> Void) async throws { }
    func stopObservingWorkouts() { }
    func recentWorkouts(since anchorDate: Date) async throws -> [HKWorkout] { [] }
    func backfillWorkoutsFromHealth(referenceDate: Date) async throws -> [HKWorkout] { [] }
    func save(_ samples: [HKObject]) async throws { }
    func delete(_ samples: [HKSample]) async throws { }
    func deleteWorkout(fernletWorkoutID: UUID) async throws -> Bool { false }
    func statistics(for type: HKQuantityType, options: HKStatisticsOptions, interval: DateComponents, anchor: Date) async throws -> [HKStatistics] { [] }
    func requestBodyProfileAuthorization() async throws -> HealthBodyProfile { HealthBodyProfile() }
    func loadBodyProfile() async throws -> HealthBodyProfile { HealthBodyProfile() }
    func saveBodyProfileMeasurements(_ profile: UserNutritionProfile) async throws { }
    func saveWorkout(_ workout: Workout) async throws -> UUID {
        saveWorkoutCallCount += 1
        return saveWorkoutUUID
    }
    func loadLastNightSleepHours(referenceDate: Date) async throws -> Double? { nil }
    func loadDailyHealthContext(referenceDate: Date, capabilities: Set<HealthCapability>?) async throws -> HealthDailyContext { HealthDailyContext() }
    func disableIntegration() async throws { }
    func enableIntegration() async throws { }
    func openHealthPrivacySettings() async { }
}
