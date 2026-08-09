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

/// The root of the "Export my data" JSON file: a curated, human-readable projection of the user's
/// own non-sealed data.
///
/// Built by `FernletStore.buildDataExport()` from live decrypted in-memory state and encoded by
/// `writeDataExportFile()` (pretty-printed, sorted keys, ISO-8601 dates) for the Privacy & Data
/// screen's share sheet. The shape is deliberately an *allowlist*: every field here was consciously
/// chosen, so new store data stays out of the export until someone adds a projection — that is the
/// mechanism that keeps period/cycle data, intimate-activity data, sensitive (Tier-2) memories,
/// Worry Box notes, photo bytes, and identity keys excluded by construction. Field names are plain
/// English and empty sections are omitted, because the audience is the person the data belongs to,
/// not a machine.
struct FernletDataExport: Codable {
    var about: About
    var you: Profile
    var days: [DayExport]
    var coreMemories: [MemoryExport]
    var goals: [GoalExport]
    var recipes: [RecipeExport]
    var wardrobe: Wardrobe
    var friends: [FriendExport]

    /// The export's self-describing preamble: app name, export date, and explicit includes/excludes
    /// lists.
    ///
    /// Written first so a person opening the file learns what is (and deliberately isn't) inside
    /// before scrolling into their history.
    struct About: Codable {
        var app = "Fernlet"
        var exportedOn: String
        var note = "Your own Fernlet data, exported for you. Fernlet keeps this on your device — we "
            + "never receive it. Logs are grouped by day."
        var includes: [String]
        var excludes: [String]
    }

    /// The handful of non-sensitive profile settings worth exporting: goal, hydration targets, and
    /// the calories-visibility choice.
    ///
    /// Body measurements (age, weight, height, sex) are deliberately not projected here.
    struct Profile: Codable {
        var goal: String
        var dailyWaterTargetBottles: Int
        var bottleOunces: Int
        var showsCalories: Bool
    }

    /// One logged day, newest-first in the export: wellbeing score plus every log category the day
    /// actually holds.
    ///
    /// Projected from `FernletDay` by `projectDay`; each optional section is nil (and therefore
    /// omitted from the JSON) when empty, so a day reads as only what happened.
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
        /// Recipe names the user assigned to this day in the F3 shopping-list planner
        /// (`FernletDay.plannedRecipeIDs`). Names only — a planned web-import recipe contributes its
        /// name here without widening the standing gap that web-import recipe BODIES stay absent from
        /// the `recipes` array (§4.3). Dangling ids (recipe since deleted) are dropped.
        var plannedMeals: [String]?

        /// The day's wellbeing result: score (rounded to two places), companion state, and summary.
        ///
        /// Present only when a `DailyHealthScore` exists for the day.
        struct Wellbeing: Codable {
            var score: Double
            var state: String
            var summary: String?
        }
        /// The day's hydration: bottles drunk against the target in effect at export time.
        ///
        /// Omitted when no bottles were logged that day.
        struct Water: Codable {
            var bottles: Int
            var targetBottles: Int
        }
        /// Non-sensitive Apple Health context for the day: activity and body metrics only.
        ///
        /// Cycle, intimate, and mindfulness contexts are never projected here (see `projectHealth`);
        /// an all-nil projection omits the section entirely.
        struct Health: Codable {
            var steps: Int?
            var activeEnergyKcal: Double?
            var exerciseMinutes: Double?
            var sleepHours: Double?
            var restingHeartRateBPM: Double?
            var heartRateVariabilityMS: Double?
        }
    }

    /// One logged meal: name, meal type, calories, macros, optional note, and the log time.
    ///
    /// Projected from the day's meals; meal photos are excluded from the export by design.
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

    /// One logged workout: name, type, exercise lines, duration, perceived effort, and notes.
    ///
    /// Optional fields are omitted rather than exported empty, matching the export's
    /// readable-by-a-person convention.
    struct WorkoutExport: Codable {
        var name: String
        var type: String
        var exercises: [String]?
        var durationMinutes: Int?
        var perceivedEffortRPE: Double?
        var notes: String?
        var completedAt: Date
    }

    /// The day's sleep entry: optional hours, the quality label, and an optional note.
    ///
    /// Present only when sleep was logged that day.
    struct SleepExport: Codable {
        var hours: Double?
        var quality: String
        var note: String?
    }

    /// One journal entry: the feeling tag, the entry text, tagged emotions, and its date.
    ///
    /// Journal text is readable here because the export is built from live decrypted state behind
    /// the Privacy & Data screen's fresh biometric check; sensitive (Tier-2) memory stays excluded.
    struct JournalExport: Codable {
        var feeling: String
        var text: String?
        var emotions: [String]?
        var date: Date
    }

    /// One core memory Fernlet keeps: its category, the note text, and the source date.
    ///
    /// Only Tier-1 (user-visible, editable) memories are projected; Tier-2 inferred memory is on the
    /// exclusion list.
    struct MemoryExport: Codable {
        var category: String
        var note: String
        var remembered: Date
    }

    /// One fitness goal: type, the goal statement, and its optional timeframe, metric, milestones,
    /// and weekly structure.
    ///
    /// Projected from the store's `FitnessGoal`s with empty strings collapsed to nil.
    struct GoalExport: Codable {
        var type: String
        var goal: String
        var timeframe: String?
        var metric: String?
        var milestones: [String]?
        var weeklyStructure: String?
    }

    /// One saved recipe rendered readably: name, servings, ingredient lines, notes, and steps.
    ///
    /// Ingredients come through `recipeIngredientLines`, which resolves a manual recipe's food ids
    /// to "Name (2 cup)" lines; recipe photos are excluded from the export by design.
    struct RecipeExport: Codable {
        var name: String
        var servings: Int
        var ingredients: [String]?
        var notes: String?
        /// User-authored (or web-import-parsed) ordered cooking steps (F5), rendered as readable lines —
        /// a step's optional timer is appended as " (N min timer)". Omitted when the recipe has no steps.
        /// Steps are the cook's own prose, so the export — a person's take-my-data dump — must carry them.
        var steps: [String]?
        var createdAt: Date
    }

    /// The companion's economy: the coin balance and every custom clothing item.
    ///
    /// Built-in catalog items aren't listed — only custom items the user made or received.
    struct Wardrobe: Codable {
        var coins: Int
        var customItems: [WardrobeItem]

        /// One custom clothing item: name, slot, whether the user designed it, and when it was
        /// created.
        ///
        /// `madeByYou` distinguishes the user's own designs from items received from friends.
        struct WardrobeItem: Codable {
            var name: String
            var slot: String
            var madeByYou: Bool
            var createdAt: Date
        }
    }

    /// One proximity friend: display name, key fingerprint, status, and the friendship dates.
    ///
    /// `status` collapses the trust-vault record to "friend" / "removed" / "blocked" (see
    /// `friendStatus`); the fingerprint is the public identifier — private keys are on the export's
    /// exclusion list.
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

        // Resolve planned-recipe ids to names for the export, unioning BOTH recipe stores exactly as the
        // recipe-book UI does (manual/peer `recipes` + web-import `savedRecipes`). Names only; dangling
        // ids resolve to nothing and drop.
        let recipeNameByID = Dictionary(
            (recipes + savedRecipes).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        let dayExports: [FernletDataExport.DayExport] = loadDays().values
            .filter { $0.hasLoggedContent }
            .sorted { $0.date > $1.date }   // newest first
            .map { day in Self.projectDay(day, score: scoresByDay[day.date], target: settings.hydrationTarget, recipeNameByID: recipeNameByID) }

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
                steps: Self.recipeStepLines(r),
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
                "Daily logs (meals, workouts, sleep, water, hygiene, journal, planned meals) grouped by day",
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

    /// The one directory every user-facing export — the "export my data" dump and the
    /// trainer/nutritionist summary — is written into: a dedicated subfolder of tmp/, so a wipe can
    /// remove it wholesale (the same shape as `MealPhotoStore`) rather than chasing a filename. The export
    /// is an UNENCRYPTED dump of the user's decrypted data, and `deleteAllData` clears this directory by
    /// construction, so a future export path is swept without anyone remembering to update the eraser.
    static var dataExportsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DataExports", isDirectory: true)
    }

    /// The one JSON encoder configuration every user-facing export shares: pretty-printed with sorted
    /// keys (stable, human-readable output), slashes left unescaped, and ISO-8601 dates.
    ///
    /// Both the "export my data" dump and the trainer/nutritionist summary encode through this factory,
    /// so the two files stay byte-for-byte in the same JSON dialect instead of drifting apart.
    static func makeExportJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Writes already-encoded export JSON into `dataExportsDirectory` as
    /// `Fernlet-<kind>-<todayKey>.json` (atomic, `.completeFileProtection`) and returns the file URL for
    /// the share sheet.
    ///
    /// Landing in that one directory is the privacy property: every file written here is covered by the
    /// launch sweep, the share-completion purge, and "Delete everything" by construction —
    /// `purgeDataExports` removes the directory wholesale. Callers own any pre-write purge; this helper
    /// only writes.
    func writeProtectedExport(_ data: Data, kind: String) throws -> URL {
        let directory = Self.dataExportsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Fernlet-\(kind)-\(todayKey).json")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
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
        return try writeProtectedExport(Self.makeExportJSONEncoder().encode(buildDataExport()), kind: "data")
    }

    /// Deletes every exported file — the data export AND the trainer/nutritionist summary. The data
    /// export is a full, UNENCRYPTED JSON dump of the user's decrypted data — days, meals (names, notes,
    /// times), journal, goals, recipes, wardrobe/coins, friends — and the trainer summary carries injury
    /// notes, sickness days, and wellbeing scores in the clear. iOS only reclaims tmp/ under storage
    /// pressure, so without this a user who exported and then tapped "Delete everything" is left with a
    /// complete plaintext copy on disk after a dialog that told them it was gone.
    ///
    /// Removes the whole `dataExportsDirectory` rather than a single filename: exports are named by day
    /// (`Fernlet-data-<todayKey>.json` / `Fernlet-training-<todayKey>.json`), so a user who exported
    /// across several days has several files. Also sweeps any legacy flat-named exports left at the tmp/
    /// root by a build that wrote there before this directory existed. No background writer rebuilds an
    /// export, so this can run at any point in the funnel — the only requirement is that the funnel not
    /// forget it.
    @discardableResult
    func purgeDataExports() -> Bool {
        let fileManager = FileManager.default
        var ok = true

        let directory = Self.dataExportsDirectory
        if fileManager.fileExists(atPath: directory.path) {
            do { try fileManager.removeItem(at: directory) }
            catch { ok = false }
        }

        // Legacy sweep: exports used to be written straight into tmp/ — data exports as
        // `Fernlet-data-<day>.json`, trainer summaries as `Fernlet-training-<day>.json` (before the
        // trainer writer moved into `dataExportsDirectory`). Exactly those two prefixes, deliberately NOT
        // a blanket `Fernlet-` match: other tmp/ files are not this sweep's to delete.
        let tmp = fileManager.temporaryDirectory
        let strays = (try? fileManager.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
        for stray in strays
        where (stray.lastPathComponent.hasPrefix("Fernlet-data-")
               || stray.lastPathComponent.hasPrefix("Fernlet-training-")) && stray.pathExtension == "json" {
            do { try fileManager.removeItem(at: stray) }
            catch { ok = false }
        }
        return ok
    }

    /// Deletes ONE prepared export file, and only if it lives in `dataExportsDirectory`.
    ///
    /// This is the share-sheet completion seam for a *single* export: the trainer/nutritionist summary
    /// and the full data export are prepared independently, so finishing one share must not delete a file
    /// the other share is still reading — which is exactly what the broad ``purgeDataExports()`` would do.
    /// The directory guard keeps a completion handler from becoming an arbitrary-file delete.
    ///
    /// A file that is already gone counts as success: the property being asserted is "no plaintext export
    /// left on disk", not "this call did the removing". Failure is non-fatal — the launch sweep, the
    /// pre-export sweep, and "Delete everything" all still cover the file as a backstop.
    /// - Parameter url: The export file URL returned by ``writeProtectedExport(_:kind:)``.
    /// - Returns: `true` when the file is gone afterwards.
    @discardableResult
    func discardExportedFile(at url: URL) -> Bool {
        let fileManager = FileManager.default
        let target = url.standardizedFileURL
        guard target.deletingLastPathComponent().standardizedFileURL.path
                == Self.dataExportsDirectory.standardizedFileURL.path else { return false }
        guard fileManager.fileExists(atPath: target.path) else { return true }
        do {
            try fileManager.removeItem(at: target)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Projection helpers (static, pure)

    private static func projectDay(_ day: FernletDay, score: DailyHealthScore?, target: Int, recipeNameByID: [UUID: String] = [:]) -> FernletDataExport.DayExport {
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
        // Dangling planned ids (recipe since deleted) resolve to no name and drop silently (§4.3).
        let plannedMeals = day.plannedRecipeIDs.compactMap { recipeNameByID[$0] }

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
            health: projectHealth(day.healthContext),
            plannedMeals: plannedMeals.isEmpty ? nil : plannedMeals)
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

    /// Collapses either recipe shape to `[String]`: a web import's free-text `ingredientLines`, or a
    /// manual recipe's structured ingredients resolved to `"Name (2 cup)"`. The one both-shapes unifier
    /// (§4.1); also reused by the F3 grocery composer for web-import per-recipe sections, so it is
    /// `internal` (not `private`) to reach `GroceryListComposer` in the same target.
    static func recipeIngredientLines(_ recipe: RecipeDefinition, nameByFoodID: [UUID: String] = [:]) -> [String]? {
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

    /// Renders a recipe's ordered cooking steps (F5) to readable lines for the export: the step text, with
    /// a step's optional passive timer appended as " (N min timer)". Returns nil when the recipe has no
    /// steps, so the section is omitted rather than exported as an empty array.
    static func recipeStepLines(_ recipe: RecipeDefinition) -> [String]? {
        guard let steps = recipe.steps, !steps.isEmpty else { return nil }
        return steps.map { step in
            guard let seconds = step.durationSeconds, seconds > 0 else { return step.text }
            let minutes = max(seconds / 60, 1)
            return "\(step.text) (\(minutes) min timer)"
        }
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
