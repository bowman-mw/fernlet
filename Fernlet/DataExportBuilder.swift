//
//  DataExportBuilder.swift
//  Fernlet
//
//  "Export my data" (App Store blocker A3). Assembles the user's own non-sealed data into a single,
//  human-readable JSON file and returns a temp-file URL for the share sheet.
//
//  Readability: logs are grouped by day (a person can scroll their history date by date), fields have
//  plain names, dates render as ISO-8601 strings, and empty sections are omitted.
//
//  Privacy (spec §8 / §16): built from the app's LIVE, decrypted in-memory state (the Privacy & Data
//  screen requires a fresh biometric check to reach the export button, so sealed journal text is
//  readable). Sealed/sensitive data is EXCLUDED by construction — the projection is an allowlist, so a
//  future field is left out until someone consciously adds it here. Excluded: period/cycle data,
//  intimate-activity data, sensitive/Tier-2 memory, Worry Box notes, photo bytes, and identity keys.
//

import Foundation
import FernletDomainModel
import FoodCatalog

// MARK: - Export DTO (curated, human-readable projections)

struct FernletDataExport: Codable {
    var about: About
    var you: Profile
    var days: [DayExport]
    var coreMemories: [MemoryExport]
    var goals: [GoalExport]
    var recipes: [RecipeExport]
    var wardrobe: Wardrobe
    var friends: [FriendExport]

    struct About: Codable {
        var app = "Fernlet"
        var exportedOn: String
        var note = "Your own Fernlet data, exported for you. Fernlet keeps this on your device — we "
            + "never receive it. Logs are grouped by day."
        var includes: [String]
        var excludes: [String]
    }

    struct Profile: Codable {
        var goal: String
        var dailyWaterTargetBottles: Int
        var bottleOunces: Int
        var showsCalories: Bool
    }

    struct DayExport: Codable {
        var day: String
        var wellbeing: Wellbeing?
        var meals: [MealExport]?
        var workouts: [WorkoutExport]?
        var sleep: SleepExport?
        var water: Water?
        var hygiene: [String]?
        var journal: [JournalExport]?
        var health: Health?

        struct Wellbeing: Codable {
            var score: Double
            var state: String
            var summary: String?
        }
        struct Water: Codable {
            var bottles: Int
            var targetBottles: Int
        }
        struct Health: Codable {
            var steps: Int?
            var activeEnergyKcal: Double?
            var exerciseMinutes: Double?
            var sleepHours: Double?
            var restingHeartRateBPM: Double?
            var heartRateVariabilityMS: Double?
        }
    }

    struct MealExport: Codable {
        var name: String
        var type: String
        var calories: Int
        var proteinGrams: Int
        var carbsGrams: Int
        var fatGrams: Int
        var note: String?
        var loggedAt: Date
    }

    struct WorkoutExport: Codable {
        var name: String
        var type: String
        var exercises: [String]?
        var durationMinutes: Int?
        var perceivedEffortRPE: Double?
        var notes: String?
        var completedAt: Date
    }

    struct SleepExport: Codable {
        var hours: Double?
        var quality: String
        var note: String?
    }

    struct JournalExport: Codable {
        var feeling: String
        var text: String?
        var emotions: [String]?
        var date: Date
    }

    struct MemoryExport: Codable {
        var category: String
        var note: String
        var remembered: Date
    }

    struct GoalExport: Codable {
        var type: String
        var goal: String
        var timeframe: String?
        var metric: String?
        var milestones: [String]?
        var weeklyStructure: String?
    }

    struct RecipeExport: Codable {
        var name: String
        var servings: Int
        var ingredients: [String]?
        var notes: String?
        var createdAt: Date
    }

    struct Wardrobe: Codable {
        var coins: Int
        var customItems: [WardrobeItem]

        struct WardrobeItem: Codable {
            var name: String
            var slot: String
            var madeByYou: Bool
            var createdAt: Date
        }
    }

    struct FriendExport: Codable {
        var displayName: String
        var fingerprint: String
        var status: String
        var friendsSince: Date
        var lastSeen: Date
    }
}

// MARK: - Builder

extension FernletStore {
    /// Assembles the readable export from live in-memory state. Excludes sealed/sensitive data.
    func buildDataExport() -> FernletDataExport {
        let scoresByDay = Dictionary(dailyScores.map { ($0.dateKey, $0) }, uniquingKeysWith: { a, _ in a })

        let dayExports: [FernletDataExport.DayExport] = loadDays().values
            .filter { $0.hasLoggedContent }
            .sorted { $0.date > $1.date }   // newest first
            .map { day in Self.projectDay(day, score: scoresByDay[day.date], target: settings.hydrationTarget) }

        let memoryExports = memories.map {
            FernletDataExport.MemoryExport(category: $0.category, note: $0.text, remembered: $0.sourceDate)
        }

        let goalExports = goals.map { g in
            FernletDataExport.GoalExport(
                type: g.type.rawValue, goal: g.goal,
                timeframe: g.timeframe.isEmpty ? nil : g.timeframe,
                metric: g.metric.isEmpty ? nil : g.metric,
                milestones: g.milestones.isEmpty ? nil : g.milestones,
                weeklyStructure: g.weeklyStructure)
        }

        let recipeExports = recipes.map { r in
            // Resolve each ingredient's food name from the catalog so a manually-built recipe exports
            // "Flour (2 cup)" rather than a nameless "2 cup" (RecipeIngredient stores only a foodItemId).
            let nameByFoodID = Dictionary(
                foodCatalog.items(forRecipe: r).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            return FernletDataExport.RecipeExport(
                name: r.name, servings: r.servings,
                ingredients: Self.recipeIngredientLines(r, nameByFoodID: nameByFoodID),
                notes: r.notes.isEmpty ? nil : r.notes,
                createdAt: r.createdAt)
        }

        let wardrobeItems = customItems.map { item in
            FernletDataExport.Wardrobe.WardrobeItem(
                name: item.name, slot: item.slot.rawValue,
                madeByYou: isSelfDesigned(item), createdAt: item.createdAt)
        }

        let friendExports = trustedProximityPeers.map { peer in
            FernletDataExport.FriendExport(
                displayName: peer.displayName, fingerprint: peer.fingerprint,
                status: Self.friendStatus(peer),
                friendsSince: peer.firstAcceptedAt, lastSeen: peer.lastSeenAt)
        }

        let about = FernletDataExport.About(
            exportedOn: todayKey,
            includes: [
                "Daily logs (meals, workouts, sleep, water, hygiene, journal) grouped by day",
                "Non-sensitive Apple Health context (steps, energy, sleep hours, heart rate)",
                "Your wellbeing scores, core memories, goals, recipes, wardrobe, coins, and friends",
            ],
            excludes: [
                "Period / cycle data and intimate-activity data",
                "Sensitive (Tier-2) memories and Worry Box notes",
                "Photo image data and your private cryptographic keys",
            ])

        return FernletDataExport(
            about: about,
            you: FernletDataExport.Profile(
                goal: settings.selectedGoal.rawValue,
                dailyWaterTargetBottles: settings.hydrationTarget,
                bottleOunces: settings.bottleOz,
                showsCalories: settings.showCalories),
            days: dayExports,
            coreMemories: memoryExports,
            goals: goalExports,
            recipes: recipeExports,
            wardrobe: FernletDataExport.Wardrobe(coins: coinBalance, customItems: wardrobeItems),
            friends: friendExports)
    }

    /// The one directory every data export is written into — a dedicated subfolder of tmp/, so a wipe can
    /// remove it wholesale (the same shape as `MealPhotoStore`) rather than chasing a filename. The export
    /// is an UNENCRYPTED dump of the user's decrypted data, and `deleteAllData` clears this directory by
    /// construction, so a future export path is swept without anyone remembering to update the eraser.
    static var dataExportsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DataExports", isDirectory: true)
    }

    /// Encodes the export to a temp JSON file (complete file protection) and returns its URL.
    ///
    /// Writes into `dataExportsDirectory` rather than the tmp/ root: the file is the user's entire
    /// decrypted dataset in the clear (that is the point — it is theirs to take), so it has to land where
    /// the wipe reaches by construction, not somewhere a cleanup step has to name explicitly.
    func writeDataExportFile() throws -> URL {
        // Belt-and-braces: sweep any earlier plaintext export before writing a new one. The share-sheet
        // completion handler purges once sharing finishes, but a kill/crash/jettison mid-share leaves the
        // full decrypted dump in tmp/ indefinitely — so every fresh export first clears whatever a prior
        // share may have stranded. Best-effort (nothing to keep from a previous export), so the result is
        // ignored; the new file we write below is what the caller shares. Launch sweeps too, so between the
        // two no plaintext dump outlives its share.
        purgeDataExports()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(buildDataExport())
        let directory = Self.dataExportsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Fernlet-data-\(todayKey).json")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Deletes every exported data file. The export is a full, UNENCRYPTED JSON dump of the user's
    /// decrypted data — days, meals (names, notes, times), journal, goals, recipes, wardrobe/coins,
    /// friends — and iOS only reclaims tmp/ under storage pressure, so without this a user who exported
    /// and then tapped "Delete everything" is left with a complete plaintext copy on disk after a dialog
    /// that told them it was gone.
    ///
    /// Removes the whole `dataExportsDirectory` rather than a single filename: exports are named by day
    /// (`Fernlet-data-<todayKey>.json`), so a user who exported across several days has several files.
    /// Also sweeps any legacy flat-named exports left at the tmp/ root by a build that wrote there before
    /// this directory existed. No background writer rebuilds an export, so this can run at any point in
    /// the funnel — the only requirement is that the funnel not forget it.
    @discardableResult
    func purgeDataExports() -> Bool {
        let fileManager = FileManager.default
        var ok = true

        let directory = Self.dataExportsDirectory
        if fileManager.fileExists(atPath: directory.path) {
            do { try fileManager.removeItem(at: directory) }
            catch { ok = false }
        }

        // Legacy sweep: exports used to be written straight into tmp/ as `Fernlet-data-<day>.json`.
        let tmp = fileManager.temporaryDirectory
        let strays = (try? fileManager.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
        for stray in strays
        where stray.lastPathComponent.hasPrefix("Fernlet-data-") && stray.pathExtension == "json" {
            do { try fileManager.removeItem(at: stray) }
            catch { ok = false }
        }
        return ok
    }

    // MARK: - Projection helpers (static, pure)

    private static func projectDay(_ day: FernletDay, score: DailyHealthScore?, target: Int) -> FernletDataExport.DayExport {
        let meals = day.meals.map { m in
            FernletDataExport.MealExport(
                name: m.name, type: m.mealType.rawValue, calories: m.calories,
                proteinGrams: m.macros.protein, carbsGrams: m.macros.carbs, fatGrams: m.macros.fat,
                note: m.note.isEmpty ? nil : m.note, loggedAt: m.loggedAt)
        }
        let workouts = day.workouts.map { w in
            FernletDataExport.WorkoutExport(
                name: w.name, type: w.type.rawValue,
                exercises: w.exerciseLines.isEmpty ? nil : w.exerciseLines,
                durationMinutes: w.duration, perceivedEffortRPE: w.rpe,
                notes: w.notes.isEmpty ? nil : w.notes, completedAt: w.completedAt)
        }
        let journal = day.journals.map { j in
            FernletDataExport.JournalExport(
                feeling: j.tag.rawValue,
                text: j.text.isEmpty ? nil : j.text,
                emotions: j.emotions.isEmpty ? nil : j.emotions,
                date: j.date)
        }
        let sleep = day.sleep.map {
            FernletDataExport.SleepExport(
                hours: $0.hours, quality: $0.quality.rawValue,
                note: $0.note.isEmpty ? nil : $0.note)
        }
        let hygiene = day.hygiene.map(\.rawValue).sorted()

        return FernletDataExport.DayExport(
            day: day.date,
            wellbeing: score.map {
                .init(score: (($0.score * 100).rounded() / 100),
                      state: $0.companionState.rawValue,
                      summary: $0.daySummaryText)
            },
            meals: meals.isEmpty ? nil : meals,
            workouts: workouts.isEmpty ? nil : workouts,
            sleep: sleep,
            water: day.bottleCount > 0 ? .init(bottles: day.bottleCount, targetBottles: target) : nil,
            hygiene: hygiene.isEmpty ? nil : hygiene,
            journal: journal.isEmpty ? nil : journal,
            health: projectHealth(day.healthContext))
    }

    /// Non-sensitive Apple Health context only — activity + body. Cycle, intimate, and mindfulness
    /// contexts are deliberately never read here.
    private static func projectHealth(_ context: HealthDailyContext?) -> FernletDataExport.DayExport.Health? {
        guard let context, context.hasContent else { return nil }
        let a = context.activity
        let b = context.body
        let health = FernletDataExport.DayExport.Health(
            steps: a?.steps,
            activeEnergyKcal: a?.activeEnergyKilocalories,
            exerciseMinutes: a?.exerciseMinutes,
            sleepHours: b?.sleepHours,
            restingHeartRateBPM: b?.restingHeartRateBPM,
            heartRateVariabilityMS: b?.heartRateVariabilityMS)
        // All-nil (e.g. only cycle/intimate present) → omit the section entirely.
        if health.steps == nil, health.activeEnergyKcal == nil, health.exerciseMinutes == nil,
           health.sleepHours == nil, health.restingHeartRateBPM == nil, health.heartRateVariabilityMS == nil {
            return nil
        }
        return health
    }

    private static func recipeIngredientLines(_ recipe: RecipeDefinition, nameByFoodID: [UUID: String] = [:]) -> [String]? {
        if let webImport = recipe.webImport, !webImport.ingredientLines.isEmpty {
            return webImport.ingredientLines
        }
        let lines = recipe.ingredients.map { ing -> String in
            let measure = "\(formatQuantity(ing.quantity)) \(ing.unit)".trimmingCharacters(in: .whitespaces)
            if let name = nameByFoodID[ing.foodItemId], !name.isEmpty {
                return measure.isEmpty ? name : "\(name) (\(measure))"
            }
            return measure   // food not resolvable → measure only (still better than a trap)
        }
        return lines.isEmpty ? nil : lines
    }

    /// Whole numbers render without a trailing decimal; a non-finite / out-of-Int-range quantity falls
    /// back to the raw Double string instead of trapping on the unchecked `Int(...)` initializer.
    private static func formatQuantity(_ q: Double) -> String {
        guard q.isFinite, q == q.rounded(), abs(q) < 1e15 else { return String(q) }
        return String(Int(q))
    }

    private static func friendStatus(_ peer: ProximityTrustedPeerRecord) -> String {
        if peer.blockedAt != nil { return "blocked" }
        if peer.revokedAt != nil { return "removed" }
        return "friend"
    }
}
