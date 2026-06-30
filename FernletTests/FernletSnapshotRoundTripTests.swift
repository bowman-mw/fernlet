import Foundation
import LocalPersistence
import FernletFoundation
import Testing
import FernletDomainModel
import FernletPersistence
import CloudKitSync
@testable import Fernlet

@MainActor
struct FernletSnapshotRoundTripTests {
    @Test func baselineSnapshotRoundTripPreservesEveryStoreSlice() async throws {
        let date = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 5, day: 19)))
        let todayKey = FernletDate.dayKey(for: date)
        let repository = LocalFernletRepository(fileURL: temporaryDatabaseURL("baseline-round-trip"))
        let snapshot = try baselineSnapshot(todayKey: todayKey)
        let savedRecipeRepository = SavedRecipeRepository()
        let previousSavedRecipes = savedRecipeRepository.load()
        let savedRecipes = try baselineSavedRecipes()
        // The store is now append/upsert-only; emulate the old full-replace by clearing then upserting so
        // this test sets (and restores) an exact row set.
        defer {
            savedRecipeRepository.deleteAll()
            _ = savedRecipeRepository.upsert(previousSavedRecipes)
        }

        savedRecipeRepository.deleteAll()
        #expect(savedRecipeRepository.upsert(savedRecipes))
        #expect(repository.saveSnapshot(snapshot))

        let reloadedSnapshot = repository.loadSnapshot(todayKey: todayKey)
        assertSnapshot(reloadedSnapshot, equals: snapshot)

        let reloadedStore = try await FernletStore.load(date: date, repository: repository)
        assertStore(reloadedStore, equals: snapshot)
        #expect(reloadedStore.savedRecipes.sorted(by: sortSavedRecipes) == savedRecipes.sorted(by: sortSavedRecipes))
    }

    /// The `SanitizedSnapshot.sanitizing` strip (the type-enforced storage boundary) must remove
    /// cycle/intimate health context and cycle-derived `periodPhase` before they can reach the blob,
    /// while non-sensitive health fields survive.
    @Test func sanitizingSnapshotStripsCycleIntimateAndPeriodPhase() throws {
        let todayKey = "2026-05-19"
        let repository = LocalFernletRepository(fileURL: temporaryDatabaseURL("sanitize-strip"))
        var snapshot = try baselineSnapshot(todayKey: todayKey)
        snapshot.dailyScores[0].periodPhase = "luteal"
        // Precondition: the baseline fixture carries the sensitive fields we expect to be stripped.
        #expect(snapshot.day.healthContext?.cycle != nil)
        #expect(snapshot.day.healthContext?.intimate != nil)

        #expect(repository.saveSnapshot(SanitizedSnapshot.sanitizing(snapshot, sealedJournalIDs: [])))
        let reloaded = repository.loadSnapshot(todayKey: todayKey)

        #expect(reloaded.day.healthContext?.cycle == nil)
        #expect(reloaded.day.healthContext?.intimate == nil)
        #expect(reloaded.dailyScores.allSatisfy { $0.periodPhase == nil })
        // Non-sensitive health context still round-trips.
        #expect(reloaded.day.healthContext?.activity != nil)
    }

    /// The strip blanks sealed-journal text (today + previousJournals) while leaving unsealed entries
    /// intact — the data-side journal protection at the storage boundary.
    @Test func sanitizingSnapshotBlanksSealedJournalText() throws {
        let todayKey = "2026-05-19"
        let repository = LocalFernletRepository(fileURL: temporaryDatabaseURL("sanitize-journal"))
        let snapshot = try baselineSnapshot(todayKey: todayKey)
        let sealedID = try uuid("00000000-0000-0000-0000-000000000301")  // journals[0], present in day + previous
        let keptID = try uuid("00000000-0000-0000-0000-000000000302")    // journals[1]

        #expect(repository.saveSnapshot(SanitizedSnapshot.sanitizing(snapshot, sealedJournalIDs: [sealedID])))
        let reloaded = repository.loadSnapshot(todayKey: todayKey)

        #expect(reloaded.day.journals.first { $0.id == sealedID }?.text == "")
        #expect(reloaded.day.journals.first { $0.id == keptID }?.text.isEmpty == false)
        #expect(reloaded.previousJournals.first { $0.id == sealedID }?.text == "")
        #expect(reloaded.previousJournals.first { $0.id == keptID }?.text.isEmpty == false)
    }

    private func baselineSnapshot(todayKey: String) throws -> FernletSnapshot {
        let date0 = Date(timeIntervalSince1970: 1_779_580_800)
        let date1 = Date(timeIntervalSince1970: 1_779_584_400)
        let date2 = Date(timeIntervalSince1970: 1_779_588_000)
        let meal1 = meal(id: try uuid("00000000-0000-0000-0000-000000000101"), name: "Egg Bowl", type: .breakfast, protein: 28, carbs: 20, fat: 12, loggedAt: date0)
        let meal2 = meal(id: try uuid("00000000-0000-0000-0000-000000000102"), name: "Chicken Rice", type: .lunch, protein: 42, carbs: 55, fat: 10, loggedAt: date1)
        let meal3 = meal(id: try uuid("00000000-0000-0000-0000-000000000103"), name: "Yogurt Berries", type: .snack, protein: 20, carbs: 24, fat: 2, loggedAt: date2)
        let workout1 = Workout(
            id: try uuid("00000000-0000-0000-0000-000000000201"),
            name: "Upper Push",
            type: .upper,
            exercises: "Bench press 3x8\nPress 3x6",
            rpe: 7,
            notes: "Controlled reps",
            duration: 45,
            muscleGroups: [.chest, .frontDelts, .triceps],
            intensity: .moderate,
            completedAt: date1,
            loggedAt: date1
        )
        let workout2 = Workout(
            id: try uuid("00000000-0000-0000-0000-000000000202"),
            name: "Recovery Walk",
            type: .cardio,
            mode: .activity,
            exercises: "Outdoor walk",
            rpe: 3,
            notes: "Easy pace",
            duration: 35,
            distanceMiles: 2.1,
            activeEnergyKcal: 140,
            effort: 4,
            intensity: .light,
            completedAt: date2,
            loggedAt: date2
        )
        let journals = [
            JournalEntry(id: try uuid("00000000-0000-0000-0000-000000000301"), text: "Clear morning energy.", tag: .good, date: date0, emotions: ["calm"]),
            JournalEntry(id: try uuid("00000000-0000-0000-0000-000000000302"), text: "Focused afternoon work.", tag: .bright, date: date1, emotions: ["focused"]),
            JournalEntry(id: try uuid("00000000-0000-0000-0000-000000000303"), text: "Quiet evening reset.", tag: .quiet, date: date2, emotions: ["rested"])
        ]
        let day = FernletDay(
            date: todayKey,
            meals: [meal1, meal2],
            workouts: [workout1, workout2],
            journals: Array(journals.prefix(2)),
            sleep: SleepLog(hours: 7.25, quality: .great, note: "Slept through", loggedAt: date0),
            bottleCount: 5,
            hygiene: [.teethAM, .floss, .shower],
            completedPersonalCareTaskIDs: ["teethAM", "floss", "custom-medication"],
            healthContext: HealthDailyContext(
                syncedAt: date1,
                activity: HealthActivitySummary(steps: 8420, activeEnergyKilocalories: 510, exerciseMinutes: 42),
                body: HealthBodyContext(sleepHours: 7.25, restingHeartRateBPM: 58, heartRateVariabilityMS: 64),
                cycle: HealthCycleContext(menstrualFlowEventCount: 1, latestCycleEventAt: date0),
                mindfulness: HealthMindfulnessContext(mindfulSessionMinutes: 12),
                intimate: HealthIntimateContext(eventCount: 1)
            )
        )
        var settings = FernletSettings()
        settings.selectedGoal = .strength
        settings.sickDays = ["2026-01-01": true]
        settings.aiStatus = .ready
        settings.showCalories = true
        settings.userProfile = UserNutritionProfile(age: 34, weightPounds: 165, heightInches: 67, sex: .female, activityLevel: .active)
        settings.nutritionPreferences = UserNutritionPreferences(dietaryPattern: .higherProtein, guidanceIntensity: .detailed)
        settings.homeWidgets = [.companion, .quickLog, .recipeBook, .workout]
        settings.quickLogItems = [.meal, .move, .journal, .sleep, .water, .care]
        settings.proximityDisplayName = "Baseline Trainer"

        let foodItems = try [
            foodItem(id: "00000000-0000-0000-0000-000000000401", name: "Eggs", protein: 12, carbs: 1, fat: 10, verifiedAt: date0),
            foodItem(id: "00000000-0000-0000-0000-000000000402", name: "Chicken Breast", protein: 31, carbs: 0, fat: 4, verifiedAt: date1),
            foodItem(id: "00000000-0000-0000-0000-000000000403", name: "Rice", protein: 4, carbs: 45, fat: 1, verifiedAt: date2)
        ]
        let recipes = [
            RecipeDefinition(
                id: try uuid("00000000-0000-0000-0000-000000000501"),
                name: "Chicken Rice Bowl",
                servings: 2,
                ingredients: [
                    RecipeIngredient(id: try uuid("00000000-0000-0000-0000-000000000511"), foodItemId: foodItems[1].id, quantity: 150, unit: "g"),
                    RecipeIngredient(id: try uuid("00000000-0000-0000-0000-000000000512"), foodItemId: foodItems[2].id, quantity: 200, unit: "g")
                ],
                notes: "Batch lunch",
                source: "manual",
                createdAt: date0,
                updatedAt: date1
            ),
            RecipeDefinition(
                id: try uuid("00000000-0000-0000-0000-000000000502"),
                name: "Egg Breakfast",
                servings: 1,
                ingredients: [RecipeIngredient(id: try uuid("00000000-0000-0000-0000-000000000513"), foodItemId: foodItems[0].id, quantity: 2, unit: "each")],
                notes: "Fast breakfast",
                source: "manual",
                createdAt: date1,
                updatedAt: date2
            )
        ]

        return FernletSnapshot(
            todayKey: todayKey,
            day: day,
            settings: settings,
            recentMeals: [meal3, meal2, meal1],
            previousJournals: journals,
            memories: [
                MemoryNote(id: try uuid("00000000-0000-0000-0000-000000000601"), category: "good", text: "Protein breakfast helps focus.", sourceDate: date0),
                MemoryNote(id: try uuid("00000000-0000-0000-0000-000000000602"), category: "bright", text: "Afternoon walks improve mood.", sourceDate: date1),
                MemoryNote(id: try uuid("00000000-0000-0000-0000-000000000603"), category: "quiet", text: "Evening planning reduces stress.", sourceDate: date2)
            ],
            goals: [
                FitnessGoal(id: try uuid("00000000-0000-0000-0000-000000000701"), type: .strength, goal: "Build pressing strength", timeframe: "12 weeks", metric: "Bench 135", milestones: ["95", "115"], weeklyStructure: "3 lifts"),
                FitnessGoal(id: try uuid("00000000-0000-0000-0000-000000000702"), type: .recovery, goal: "Keep sleep steady", timeframe: "4 weeks", metric: "7 hours", milestones: ["Week 1", "Week 2"], weeklyStructure: "Night routine")
            ],
            workshop: WorkshopData(
                textureEntries: [
                    TextureEntry(id: try uuid("00000000-0000-0000-0000-000000000801"), title: "Food flow", body: "Recipe logging should stay fast.", tags: [.delight], createdAt: date0),
                    TextureEntry(id: try uuid("00000000-0000-0000-0000-000000000802"), title: "Privacy flow", body: "Lock gate should be explicit.", tags: [.tension, .friction], createdAt: date1)
                ],
                handoffEntries: [
                    TextureEntry(id: try uuid("00000000-0000-0000-0000-000000000803"), title: "Native handoff", body: "Core logging remains local.", tags: [.delight], createdAt: date0)
                ],
                claudeNotesEntries: [
                    TextureEntry(id: try uuid("00000000-0000-0000-0000-000000000804"), title: "AI behavior", body: "Model fallbacks stay deterministic.", tags: [.tension], createdAt: date1)
                ]
            ),
            foodItems: foodItems,
            recipes: recipes,
            dailyScores: [
                DailyHealthScore(id: try uuid("00000000-0000-0000-0000-000000000901"), dateKey: todayKey, score: 0.81, companionState: .thriving, daySummaryText: "Strong baseline day.", computedAt: date1),
                DailyHealthScore(id: try uuid("00000000-0000-0000-0000-000000000902"), dateKey: "2026-05-18", score: 0.64, companionState: .okay, daySummaryText: "Steady previous day.", computedAt: date0)
            ],
            retryQueue: [
                AIAnalysisRetryRecord(id: try uuid("00000000-0000-0000-0000-000000001001"), payloadType: "meal", sourceId: meal1.id, createdAt: date0, lastAttemptAt: date1, attemptCount: 1, note: "Retry meal one"),
                AIAnalysisRetryRecord(id: try uuid("00000000-0000-0000-0000-000000001002"), payloadType: "journal", sourceId: journals[0].id, createdAt: date1, lastAttemptAt: date2, attemptCount: 2, note: "Retry journal one")
            ],
            connectionSessionLogs: try connectionLogs(startedAt: date0),
            trustedProximityPeers: try trustedPeers(date: date1),
            trainerAuditEvents: try trainerAuditEvents(date: date2)
        )
    }

    private func assertStore(_ store: FernletStore, equals snapshot: FernletSnapshot, sourceLocation: SourceLocation = #_sourceLocation) {
        assertDay(store.day, equals: snapshot.day, sourceLocation: sourceLocation)
        assertSettings(store.settings, equals: snapshot.settings, sourceLocation: sourceLocation)
        #expect(store.recentMeals == snapshot.recentMeals, sourceLocation: sourceLocation)
        #expect(store.previousJournals == snapshot.previousJournals, sourceLocation: sourceLocation)
        #expect(store.memories == snapshot.memories, sourceLocation: sourceLocation)
        #expect(store.goals == snapshot.goals, sourceLocation: sourceLocation)
        #expect(store.workshop == snapshot.workshop, sourceLocation: sourceLocation)
        #expect(store.foodItems == snapshot.foodItems, sourceLocation: sourceLocation)
        #expect(store.recipes == snapshot.recipes, sourceLocation: sourceLocation)
        #expect(store.dailyScores == snapshot.dailyScores, sourceLocation: sourceLocation)
        #expect(store.retryQueue == snapshot.retryQueue, sourceLocation: sourceLocation)
        #expect(store.connectionSessionLogs == snapshot.connectionSessionLogs, sourceLocation: sourceLocation)
        #expect(store.trustedProximityPeers == snapshot.trustedProximityPeers, sourceLocation: sourceLocation)
        #expect(store.trainerAuditEvents == snapshot.trainerAuditEvents, sourceLocation: sourceLocation)
    }

    private func assertSnapshot(_ actual: FernletSnapshot, equals expected: FernletSnapshot, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.todayKey == expected.todayKey, sourceLocation: sourceLocation)
        assertDay(actual.day, equals: expected.day, sourceLocation: sourceLocation)
        assertSettings(actual.settings, equals: expected.settings, sourceLocation: sourceLocation)
        #expect(actual.recentMeals == expected.recentMeals, sourceLocation: sourceLocation)
        #expect(actual.previousJournals == expected.previousJournals, sourceLocation: sourceLocation)
        #expect(actual.memories == expected.memories, sourceLocation: sourceLocation)
        #expect(actual.goals == expected.goals, sourceLocation: sourceLocation)
        #expect(actual.workshop == expected.workshop, sourceLocation: sourceLocation)
        #expect(actual.foodItems == expected.foodItems, sourceLocation: sourceLocation)
        #expect(actual.recipes == expected.recipes, sourceLocation: sourceLocation)
        #expect(actual.dailyScores == expected.dailyScores, sourceLocation: sourceLocation)
        #expect(actual.retryQueue == expected.retryQueue, sourceLocation: sourceLocation)
        #expect(actual.connectionSessionLogs == expected.connectionSessionLogs, sourceLocation: sourceLocation)
        #expect(actual.trustedProximityPeers == expected.trustedProximityPeers, sourceLocation: sourceLocation)
        #expect(actual.trainerAuditEvents == expected.trainerAuditEvents, sourceLocation: sourceLocation)
    }

    private func assertDay(_ actual: FernletDay, equals expected: FernletDay, sourceLocation: SourceLocation) {
        #expect(actual.date == expected.date, sourceLocation: sourceLocation)
        #expect(actual.meals == expected.meals, sourceLocation: sourceLocation)
        #expect(actual.workouts == expected.workouts, sourceLocation: sourceLocation)
        #expect(actual.journals == expected.journals, sourceLocation: sourceLocation)
        #expect(actual.sleep == expected.sleep, sourceLocation: sourceLocation)
        #expect(actual.bottleCount == expected.bottleCount, sourceLocation: sourceLocation)
        #expect(actual.hygiene == expected.hygiene, sourceLocation: sourceLocation)
        #expect(actual.completedPersonalCareTaskIDs == expected.completedPersonalCareTaskIDs, sourceLocation: sourceLocation)
        #expect(actual.healthContext == expected.healthContext, sourceLocation: sourceLocation)
    }

    private func assertSettings(_ actual: FernletSettings, equals expected: FernletSettings, sourceLocation: SourceLocation) {
        #expect(actual.bottleOz == expected.bottleOz, sourceLocation: sourceLocation)
        #expect(actual.hydrationTarget == expected.hydrationTarget, sourceLocation: sourceLocation)
        #expect(actual.showDeveloperNotes == expected.showDeveloperNotes, sourceLocation: sourceLocation)
        #expect(actual.connectionInspectorMode == expected.connectionInspectorMode, sourceLocation: sourceLocation)
        #expect(actual.selectedGoal == expected.selectedGoal, sourceLocation: sourceLocation)
        #expect(actual.sickDays == expected.sickDays, sourceLocation: sourceLocation)
        #expect(actual.aiStatus == expected.aiStatus, sourceLocation: sourceLocation)
        #expect(actual.showCalories == expected.showCalories, sourceLocation: sourceLocation)
        #expect(actual.hasCompletedOnboarding == expected.hasCompletedOnboarding, sourceLocation: sourceLocation)
        #expect(actual.hidePredictions == expected.hidePredictions, sourceLocation: sourceLocation)
        #expect(actual.hideFertileWindow == expected.hideFertileWindow, sourceLocation: sourceLocation)
        #expect(actual.userProfile == expected.userProfile, sourceLocation: sourceLocation)
        #expect(actual.nutritionPreferences == expected.nutritionPreferences, sourceLocation: sourceLocation)
        #expect(actual.quickLogItems == expected.quickLogItems, sourceLocation: sourceLocation)
        #expect(actual.homeWidgets == expected.homeWidgets, sourceLocation: sourceLocation)
        #expect(actual.personalCareTasks == expected.personalCareTasks, sourceLocation: sourceLocation)
        #expect(actual.proximityDisplayName == expected.proximityDisplayName, sourceLocation: sourceLocation)
    }

    private func baselineSavedRecipes() throws -> [RecipeDefinition] {
        let bowlDate = Date(timeIntervalSince1970: 1_779_588_000)
        let oatsDate = Date(timeIntervalSince1970: 1_779_584_400)
        return [
            RecipeDefinition(
                id: try uuid("00000000-0000-0000-0000-000000002001"),
                name: "Saved Bowl",
                servings: 2,
                ingredients: [],
                notes: "Combine and serve.",
                source: MealLogSource.webImport,
                createdAt: bowlDate,
                updatedAt: bowlDate,
                webImport: RecipeWebImport(
                    sourceURLString: "https://example.com/bowl",
                    ingredientLines: ["rice", "chicken", "sauce"],
                    macros: Macros(protein: 38, carbs: 52, fat: 12)
                )
            ),
            RecipeDefinition(
                id: try uuid("00000000-0000-0000-0000-000000002002"),
                name: "Saved Oats",
                servings: 1,
                ingredients: [],
                notes: "Chill overnight.",
                source: MealLogSource.webImport,
                createdAt: oatsDate,
                updatedAt: oatsDate,
                webImport: RecipeWebImport(
                    sourceURLString: "https://example.com/oats",
                    ingredientLines: ["oats", "yogurt", "berries"],
                    macros: Macros(protein: 24, carbs: 48, fat: 7)
                )
            )
        ]
    }

    private func meal(id: UUID, name: String, type: MealType, protein: Int, carbs: Int, fat: Int, loggedAt: Date) -> Meal {
        let macros = Macros(protein: protein, carbs: carbs, fat: fat)
        return Meal(
            id: id,
            name: name,
            mealType: type,
            macros: macros,
            micronutrientSnapshot: Micronutrients(fiber: 4, sodium: 220),
            mealSource: .manual,
            isAIFallback: false,
            quality: .good,
            confidence: "Baseline",
            note: "Fixture meal",
            source: MealLogSource.manual,
            loggedAt: loggedAt
        )
    }

    private func foodItem(id: String, name: String, protein: Int, carbs: Int, fat: Int, verifiedAt: Date) throws -> FoodItem {
        FoodItem(
            id: try uuid(id),
            name: name,
            brandSource: "Baseline",
            servingSize: 100,
            servingUnit: "g",
            macros: Macros(protein: protein, carbs: carbs, fat: fat),
            micronutrients: Micronutrients(fiber: 3, potassium: 180, sodium: 80),
            category: "baseline",
            source: .manual,
            verificationPolicyDays: 90,
            lastVerified: verifiedAt,
            tags: ["baseline", "round-trip"]
        )
    }

    private func connectionLogs(startedAt: Date) throws -> [ConnectionSessionLog] {
        let peerSeenAt = startedAt.addingTimeInterval(60)
        return [
            ConnectionSessionLog(
                id: try uuid("00000000-0000-0000-0000-000000003001"),
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(180),
                role: .advertiser,
                mode: .trainer,
                localFingerprint: "local-a",
                peer: ConnectionSessionLog.PeerInfo(displayName: "Coach A", advertisedFingerprint: "peer-a", confirmedFingerprint: "peer-a", signingPublicKey: Data([1, 2, 3]), firstSeenAt: peerSeenAt, lastSeenAt: peerSeenAt),
                ranging: ConnectionSessionLog.RangingInfo(
                    mode: .uwb,
                    samples: [ConnectionSessionLog.DistanceSample(timestamp: peerSeenAt, meters: 1.2)],
                    tapConfirmedAt: peerSeenAt,
                    minDistanceMeters: 1.1,
                    maxDistanceMeters: 1.4
                ),
                transport: ConnectionSessionLog.TransportInfo(mcSessionState: "connected", connectedAt: peerSeenAt, disconnectedAt: startedAt.addingTimeInterval(180), bytesSent: 120, bytesReceived: 240, bluetoothActive: true, wifiActive: false, rttSamplesMs: [12, 18]),
                events: [ConnectionSessionLog.Event(id: try uuid("00000000-0000-0000-0000-000000003201"), timestamp: peerSeenAt, kind: .peerDiscovered, message: "Peer discovered")],
                envelopes: [ConnectionSessionLog.EnvelopeRecord(id: try uuid("00000000-0000-0000-0000-000000003301"), envelopeID: try uuid("00000000-0000-0000-0000-000000003302"), direction: .sent, payloadType: PayloadType.trainerPlan.rawValue, payloadByteCount: 512, timestamp: peerSeenAt, signatureVerified: true, encrypted: true, summary: "Plan sent")],
                errors: [],
                endState: "completed"
            ),
            ConnectionSessionLog(
                id: try uuid("00000000-0000-0000-0000-000000003002"),
                startedAt: startedAt.addingTimeInterval(300),
                endedAt: startedAt.addingTimeInterval(420),
                role: .browser,
                mode: .friend,
                localFingerprint: "local-b",
                ranging: ConnectionSessionLog.RangingInfo(mode: .rssi, minDistanceMeters: 2.2, maxDistanceMeters: 3.8),
                transport: ConnectionSessionLog.TransportInfo(mcSessionState: "disconnected", connectedAt: startedAt.addingTimeInterval(330), disconnectedAt: startedAt.addingTimeInterval(420), bytesSent: 90, bytesReceived: 75, bluetoothActive: false, wifiActive: true, rttSamplesMs: [25]),
                events: [ConnectionSessionLog.Event(id: try uuid("00000000-0000-0000-0000-000000003202"), timestamp: startedAt.addingTimeInterval(330), kind: .sessionEnded, message: "Session ended")],
                errors: [ConnectionSessionLog.ErrorRecord(id: try uuid("00000000-0000-0000-0000-000000003401"), timestamp: startedAt.addingTimeInterval(400), domain: "baseline", message: "Recoverable timeout", recoverable: true)],
                endState: "timeout"
            )
        ]
    }

    private func trustedPeers(date: Date) throws -> [ProximityTrustedPeerRecord] {
        [
            ProximityTrustedPeerRecord(id: try uuid("00000000-0000-0000-0000-000000004001"), displayName: "Coach A", fingerprint: "peer-a", signingPublicKey: Data([1, 2, 3]), keyAgreementPublicKey: Data([4, 5, 6]), mode: .trainer, firstAcceptedAt: date, lastSeenAt: date.addingTimeInterval(60)),
            ProximityTrustedPeerRecord(id: try uuid("00000000-0000-0000-0000-000000004002"), displayName: "Friend B", fingerprint: "peer-b", signingPublicKey: Data([7, 8, 9]), keyAgreementPublicKey: Data([10, 11, 12]), mode: .friend, firstAcceptedAt: date.addingTimeInterval(120), lastSeenAt: date.addingTimeInterval(180), revokedAt: date.addingTimeInterval(240))
        ]
    }

    private func trainerAuditEvents(date: Date) throws -> [TrainerAuditEvent] {
        [
            TrainerAuditEvent(id: try uuid("00000000-0000-0000-0000-000000005001"), timestamp: date, kind: .pairingStarted, peerFingerprint: "peer-a", peerDisplayName: "Coach A", message: "Pairing started"),
            TrainerAuditEvent(id: try uuid("00000000-0000-0000-0000-000000005002"), timestamp: date.addingTimeInterval(60), kind: .envelopeSent, peerFingerprint: "peer-a", peerDisplayName: "Coach A", payloadType: .trainerPlan, message: "Plan sent"),
            TrainerAuditEvent(id: try uuid("00000000-0000-0000-0000-000000005003"), timestamp: date.addingTimeInterval(120), kind: .trainerRevoked, peerFingerprint: "peer-b", peerDisplayName: "Friend B", message: "Peer revoked")
        ]
    }

    private func sortSavedRecipes(_ lhs: RecipeDefinition, _ rhs: RecipeDefinition) -> Bool {
        lhs.id.uuidString < rhs.id.uuidString
    }

    private func temporaryDatabaseURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FernletSnapshotRoundTripTests-\(name)-\(UUID().uuidString)")
            .appendingPathExtension("json")
    }

    private func uuid(_ string: String) throws -> UUID {
        try #require(UUID(uuidString: string))
    }
}
