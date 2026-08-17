import Foundation
import FernletFoundation
import CoreData
import FernletDomainModel
import FernletPersistence

// Web-imported recipes are now represented by the canonical `RecipeDefinition` model (carrying a
// `RecipeWebImport` payload). The legacy `SavedRecipe` struct has been removed; the repositories
// below load/save `RecipeDefinition`s while keeping the existing on-disk formats stable so that
// recipes saved by older builds migrate without loss.

/// Mirror of the legacy `SavedRecipe` JSON schema for the pre-merge `SavedRecipes.json` file.
///
/// Used only by ``LegacySavedRecipeJSONRepository`` to decode (and re-encode) that file so older
/// builds' saved recipes survive the model merge; maps losslessly to/from `RecipeDefinition`
/// via its `webImport` payload, with defensive defaults for every optional field.
nonisolated private struct LegacySavedRecipeDTO: Codable {
    var id: UUID?
    var sourceURLString: String?
    var name: String
    var ingredients: [String]?
    var summary: String?
    var servings: Int?
    var protein: Int?
    var carbs: Int?
    var fat: Int?
    var micronutrients: Micronutrients?
    var savedAt: Date?

    init(recipe: RecipeDefinition) {
        let webImport = recipe.webImport
        id = recipe.id
        sourceURLString = webImport?.sourceURLString ?? ""
        name = recipe.name
        ingredients = webImport?.ingredientLines ?? []
        summary = recipe.notes
        servings = recipe.servings
        protein = webImport?.macros.protein ?? 0
        carbs = webImport?.macros.carbs ?? 0
        fat = webImport?.macros.fat ?? 0
        micronutrients = webImport?.micronutrients ?? Micronutrients()
        savedAt = recipe.createdAt
    }

    func toRecipeDefinition() -> RecipeDefinition {
        SavedRecipeMapping.recipe(
            id: id ?? UUID(),
            sourceURLString: sourceURLString ?? "",
            name: name,
            ingredientLines: ingredients ?? [],
            summary: summary ?? "",
            servings: servings ?? 1,
            protein: protein ?? 0,
            carbs: carbs ?? 0,
            fat: fat ?? 0,
            micronutrients: micronutrients ?? Micronutrients(),
            savedAt: savedAt ?? Date()
        )
    }
}

/// STEP 0 (Docs/AI-Feature-Expansion-2026-07-23.md §9.1): the versioned JSON blob stored in the new
/// additive `payloadData` column of `SavedRecipeRecord`. It carries the FULL structured
/// `RecipeDefinition` — real structured `ingredients`, real `source`, optional `webImport` — that the
/// legacy typed columns (which hardcode `ingredients: []` + `source: .webImport`) cannot represent, so
/// non-web-import recipes and structured ingredients/steps can finally round-trip.
///
/// Tolerant decode: `container(keyedBy:)` ignores unknown future keys, and `RecipeDefinition`'s own
/// `decodeIfPresent` discipline covers additive fields — an unknown key must never fail the decode.
/// `lastPayloadEncodedAt` is the write-time stamp used by the staleness guard in
/// `SavedRecipeRepository.recipe(from:)`.
nonisolated struct SavedRecipePayload: Codable {
    var schemaVersion: Int
    var recipe: RecipeDefinition
    var lastPayloadEncodedAt: Date

    init(recipe: RecipeDefinition, lastPayloadEncodedAt: Date, schemaVersion: Int = 1) {
        self.schemaVersion = schemaVersion
        self.recipe = recipe
        self.lastPayloadEncodedAt = lastPayloadEncodedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        recipe = try container.decode(RecipeDefinition.self, forKey: .recipe)
        lastPayloadEncodedAt = try container.decodeIfPresent(Date.self, forKey: .lastPayloadEncodedAt) ?? .distantPast
    }
}

/// Single source of truth for translating the legacy saved-recipe columns/fields into a
/// `RecipeDefinition` with a `webImport` payload.
///
/// The legacy shape is free-text ingredient lines plus precomputed nutrition and a source URL.
/// Shared by ``SavedRecipeRepository`` (Core Data columns) and
/// ``LegacySavedRecipeJSONRepository`` (the JSON file) so both migrate identically, and reused
/// by the staleness guard's legacy projection.
nonisolated enum SavedRecipeMapping {
    static func recipe(
        id: UUID,
        sourceURLString: String,
        name: String,
        ingredientLines: [String],
        summary: String,
        servings: Int,
        protein: Int,
        carbs: Int,
        fat: Int,
        micronutrients: Micronutrients,
        savedAt: Date
    ) -> RecipeDefinition {
        RecipeDefinition(
            id: id,
            name: name,
            servings: max(servings, 1),
            ingredients: [],
            notes: summary,
            source: MealLogSource.webImport,
            createdAt: savedAt,
            updatedAt: savedAt,
            webImport: RecipeWebImport(
                sourceURLString: sourceURLString,
                ingredientLines: ingredientLines.filter { !$0.isEmpty },
                macros: Macros(
                    protein: max(protein, 0),
                    carbs: max(carbs, 0),
                    fat: max(fat, 0)
                ),
                micronutrients: micronutrients
            )
        )
    }
}

/// Core Data + iCloud store for saved recipes, with a dual legacy/structured on-disk format.
///
/// The `SavedRecipeRepositoring` conformer under Core Data storage. Each recipe is one
/// `SavedRecipeRecord` row carrying BOTH representations: the legacy typed columns (free-text
/// ingredient lines plus precomputed macros — all an un-updated paired device can read or
/// write) and the additive `payloadData` blob (`SavedRecipePayload`, the full structured
/// `RecipeDefinition`). Writes always populate both ("write-both"); reads prefer the blob but
/// fall back to the legacy columns whenever those have diverged from the blob's own legacy
/// projection — divergence means a legacy-only writer edited the row after the blob was
/// encoded, so the legacy columns are the fresher user intent (the STEP 0 staleness guard).
/// Divergence comparison floors dates to whole seconds to match `RowPayloadCoders`' ISO-8601
/// precision, or every runtime-created recipe would false-positive as diverged.
///
/// Also owns the one-time migration from ``LegacySavedRecipeJSONRepository``'s JSON file
/// (guarded by a UserDefaults flag). Same upsert-only row discipline as the sibling stores:
/// never deletes rows it wasn't handed. `@MainActor`, working on ``PersistenceController``'s
/// view context; failed saves assert in Debug, roll back, and return `false`.
@MainActor
public struct SavedRecipeRepository {
    private let controller: PersistenceController
    private let legacyRepository: LegacySavedRecipeJSONRepository
    private let defaults: UserDefaults

    public init() {
        self.init(controller: .shared, legacyRepository: LegacySavedRecipeJSONRepository(), defaults: .standard)
    }

    public init(controller: PersistenceController, legacyRepository: LegacySavedRecipeJSONRepository, defaults: UserDefaults = .standard) {
        self.controller = controller
        self.legacyRepository = legacyRepository
        self.defaults = defaults
    }

    private static let migrationCompletedKey = "com.fernlet.savedRecipeMigrationCompleted"

    /// Loads all saved recipes, newest first, running the one-time legacy-JSON migration when
    /// the Core Data store is empty and migration hasn't been marked complete.
    public func load() -> [RecipeDefinition] {
        StartupTiming.timed("SavedRecipeRepository.load") {
            let recipes = loadCoreDataRecipes()
            if recipes.isEmpty && !defaults.bool(forKey: Self.migrationCompletedKey) {
                let migrated = legacyRepository.load()
                if !migrated.isEmpty {
                    // The one-time flag is set ONLY on a confirmed write (R7): marking the migration
                    // complete after a failed upsert would strand the recipes in the legacy JSON file
                    // that no other code path reads, permanently.
                    guard upsert(migrated) else {
                        FernletAuditLog.log("savedRecipe.legacyMigration.failed", context: [
                            "count": "\(migrated.count)"
                        ])
                        return migrated
                    }
                }
                defaults.set(true, forKey: Self.migrationCompletedKey)
                return migrated
            }
            return recipes
        }
    }

    /// Async-signature variant of `load()` with its own signposted legacy read.
    public func loadAsync() async -> [RecipeDefinition] {
        StartupTiming.timed("SavedRecipeRepository.loadAsync") {
            let recipes = loadCoreDataRecipes()
            guard recipes.isEmpty && !defaults.bool(forKey: Self.migrationCompletedKey) else { return recipes }

            let signpostID = StartupTiming.begin("SavedRecipeRepository.legacyLoad.async")
            let migrated = legacyRepository.load()
            StartupTiming.end("SavedRecipeRepository.legacyLoad.async", signpostID: signpostID)
            if !migrated.isEmpty {
                // Same rule as `load()`: the migration-complete flag follows a confirmed write.
                guard upsert(migrated) else {
                    FernletAuditLog.log("savedRecipe.legacyMigration.failed", context: [
                        "count": "\(migrated.count)"
                    ])
                    return migrated
                }
            }
            defaults.set(true, forKey: Self.migrationCompletedKey)
            return migrated
        }
    }

    private func loadCoreDataRecipes() -> [RecipeDefinition] {
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "SavedRecipeRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "savedAt", ascending: false)]

        guard let records = try? context.fetch(request) else {
            assertionFailure("saved recipe fetch failed")
            return []
        }

        return records.compactMap(Self.recipe(from:))
    }

    /// Inserts or updates the given recipes by UUID (writing both representations), never
    /// deleting rows it wasn't handed.
    ///
    /// - Returns: `false` when the Core Data save fails (the context is rolled back).
    public func upsert(_ recipes: [RecipeDefinition]) -> Bool {
        guard !recipes.isEmpty else { return true }
        let context = controller.container.viewContext
        // Fetch ONLY the rows we're about to touch (predicate IN), then upsert by idString. We never delete
        // rows we weren't handed (unlike the old full-replace `save`), so flushing a stale set can't wipe
        // rows synced in from another device.
        let request = NSFetchRequest<NSManagedObject>(entityName: "SavedRecipeRecord")
        request.predicate = NSPredicate(format: "idString IN %@", recipes.map { $0.id.uuidString })

        do {
            var existingByID: [String: NSManagedObject] = [:]
            for record in try context.fetch(request) {
                if let idString = record.value(forKey: "idString") as? String {
                    existingByID[idString] = record
                }
            }
            for recipe in recipes {
                let record = existingByID[recipe.id.uuidString]
                    ?? NSEntityDescription.insertNewObject(forEntityName: "SavedRecipeRecord", into: context)
                Self.apply(recipe, to: record)
            }
            if context.hasChanges {
                try context.save()
            }
            return true
        } catch {
            assertionFailure("saved recipe Core Data upsert failed")
            context.rollback()
            return false
        }
    }

    /// Deletes only the rows with the listed ids.
    public func delete(ids: [UUID]) -> Bool {
        guard !ids.isEmpty else { return true }
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "SavedRecipeRecord")
        request.predicate = NSPredicate(format: "idString IN %@", ids.map { $0.uuidString })
        do {
            for record in try context.fetch(request) {
                context.delete(record)
            }
            if context.hasChanges {
                try context.save()
            }
            return true
        } catch {
            assertionFailure("saved recipe delete failed")
            context.rollback()
            return false
        }
    }

    /// Removes every saved-recipe row — the delete-all/reset path.
    ///
    /// - Returns: `false` when the Core Data delete/save fails. Not discardable (R7): the wipe
    ///   funnel names the surviving rows instead of promising a clean store.
    public func deleteAll() -> Bool {
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "SavedRecipeRecord")
        do {
            for record in try context.fetch(request) {
                context.delete(record)
            }
            if context.hasChanges {
                try context.save()
            }
            return true
        } catch {
            assertionFailure("saved recipe delete-all failed")
            context.rollback()
            return false
        }
    }

    /// READ-PREFER-PAYLOAD (STEP 0, §9.1). When the additive `payloadData` blob is present and decodes,
    /// it is the structured truth (real ingredients, real source/webImport). We fall back to the legacy
    /// typed columns — the exact behavior shipped before STEP 0 — when the blob is absent (a row written
    /// by an un-updated device, which has no `payloadData` writer) or corrupt (decode fails), so a legacy
    /// row always maps precisely as it does today and a corrupt blob never throws.
    ///
    /// STALENESS RULE (§9.1 point 6) — "prefer the side that is fresher; when in doubt, legacy wins."
    /// An un-updated device can edit the legacy columns but cannot write `payloadData`, so after such an
    /// edit the two diverge: fresh legacy columns, stale blob. We must NOT resurrect the stale structured
    /// state over a real user edit, so we prefer the blob ONLY when the legacy columns still match what
    /// THIS blob wrote alongside itself (`legacyProjection(of:)`). Any divergence means a legacy-only
    /// writer touched the row after the blob was encoded, so the legacy columns are the fresher user
    /// intent and win.
    ///
    /// We detect "the legacy columns were modified after `payloadData` was written" by content comparison
    /// rather than a timestamp — the "or equivalent" the spec allows — because no legacy column records a
    /// reliable legacy-*write* time: the only legacy date, `savedAt`, mirrors `createdAt` and an old
    /// device's own `apply` re-stamps it from the (unchanged) creation date, so a pure timestamp check
    /// can both MISS a real edit and, worse, FALSE-POSITIVE on a freshly written blob whose `createdAt`
    /// happens to be at/after encode time (which would silently discard the structured blob). Content
    /// divergence is comprehensive: it catches any legacy-visible change — name, source URL, ingredient
    /// lines, summary, servings, macros, micronutrients, and `savedAt` itself (which feeds `createdAt`,
    /// part of `RecipeDefinition` equality). `lastPayloadEncodedAt` is retained inside the blob as
    /// write-time provenance for auditing and future conflict logic.
    private static func recipe(from record: NSManagedObject) -> RecipeDefinition? {
        if let payloadData = record.value(forKey: "payloadData") as? Data,
           let payload = try? RowPayloadCoders.makeDecoder().decode(SavedRecipePayload.self, from: payloadData) {
            guard let legacy = legacyRecipe(from: record) else {
                // No usable legacy columns to compare against — trust the blob.
                return payload.recipe
            }
            // Precision-normalize before comparing. The blob's dates pass through `RowPayloadCoders`'
            // `.iso8601` strategy, which truncates to whole seconds, while the Core Data `savedAt`
            // column stores the full sub-second `Date`. A direct `!=` therefore false-positives as
            // "divergence" on EVERY recipe created with a fractional-second `Date()` — i.e. every
            // runtime creation path (web import, proximity accept, future edits) — which would silently
            // discard the structured blob and defeat the whole point of STEP 0. Flooring both sides to
            // whole-second resolution (matching the blob's own precision) removes the artifact while
            // preserving real divergence: a genuine legacy edit still changes a whole-second field
            // (name, lines, macros, or `savedAt`/`createdAt` by >= 1s) and is still caught.
            let legacyDiverged = normalizedForDivergence(legacy) != normalizedForDivergence(legacyProjection(of: payload.recipe))
            return legacyDiverged ? legacy : payload.recipe
        }
        return legacyRecipe(from: record)
    }

    /// The legacy projection of a recipe: what `apply(_:to:)` writes to the typed columns and then reads
    /// back through `SavedRecipeMapping.recipe`. Used only by the staleness guard to detect whether the
    /// on-disk legacy columns still match the blob (no legacy-only edit) or have diverged (a legacy edit
    /// happened, so legacy wins). Deterministic and side-effect-free, mirroring `apply` + `legacyRecipe`.
    private static func legacyProjection(of recipe: RecipeDefinition) -> RecipeDefinition {
        let webImport = recipe.webImport
        return SavedRecipeMapping.recipe(
            id: recipe.id,
            sourceURLString: webImport?.sourceURLString ?? "",
            name: recipe.name,
            ingredientLines: (webImport?.ingredientLines ?? []).joined(separator: "\n").components(separatedBy: "\n"),
            summary: recipe.notes,
            servings: recipe.servings,
            protein: webImport?.macros.protein ?? 0,
            carbs: webImport?.macros.carbs ?? 0,
            fat: webImport?.macros.fat ?? 0,
            micronutrients: webImport?.micronutrients ?? Micronutrients(),
            savedAt: recipe.createdAt
        )
    }

    /// Floor a `Date` to whole seconds — exactly the resolution `RowPayloadCoders`' `.iso8601` strategy
    /// stores (verified: ISO-8601-without-fractional truncates the sub-second part for every fractional
    /// value). Used to align the full-precision legacy `savedAt` column against the whole-second dates a
    /// decoded blob carries, so the staleness comparison doesn't false-positive on sub-second drift.
    private static func flooredToWholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down))
    }

    /// A copy of `recipe` with its date fields floored to whole seconds, for use ONLY in the divergence
    /// comparison. `createdAt`/`updatedAt` are part of `RecipeDefinition`'s synthesized `Equatable`, and
    /// both the legacy and projected representations force `updatedAt == createdAt == savedAt`, so a raw
    /// compare hinges entirely on `savedAt`/`createdAt` precision.
    private static func normalizedForDivergence(_ recipe: RecipeDefinition) -> RecipeDefinition {
        var copy = recipe
        copy.createdAt = flooredToWholeSecond(recipe.createdAt)
        copy.updatedAt = flooredToWholeSecond(recipe.updatedAt)
        return copy
    }

    /// The pre-STEP-0 read path, verbatim: reconstruct a `RecipeDefinition` from the legacy typed columns
    /// alone (always a `.webImport`-shaped recipe with empty structured `ingredients`). This is exactly
    /// what an un-updated device produces and what STEP 0 must preserve indefinitely.
    private static func legacyRecipe(from record: NSManagedObject) -> RecipeDefinition? {
        guard let idString = record.value(forKey: "idString") as? String,
              let id = UUID(uuidString: idString),
              let name = record.value(forKey: "name") as? String else {
            return nil
        }

        let ingredientsText = record.value(forKey: "ingredientsText") as? String ?? ""
        let micronutrients: Micronutrients
        if let json = record.value(forKey: "micronutrientsJSON") as? String,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Micronutrients.self, from: data) {
            micronutrients = decoded
        } else {
            micronutrients = Micronutrients()
        }
        return SavedRecipeMapping.recipe(
            id: id,
            sourceURLString: record.value(forKey: "sourceURLString") as? String ?? "",
            name: name,
            ingredientLines: ingredientsText.components(separatedBy: "\n"),
            summary: record.value(forKey: "summary") as? String ?? "",
            servings: (record.value(forKey: "servings") as? NSNumber)?.intValue ?? 1,
            protein: (record.value(forKey: "protein") as? NSNumber)?.intValue ?? 0,
            carbs: (record.value(forKey: "carbs") as? NSNumber)?.intValue ?? 0,
            fat: (record.value(forKey: "fat") as? NSNumber)?.intValue ?? 0,
            micronutrients: micronutrients,
            savedAt: record.value(forKey: "savedAt") as? Date ?? Date.distantPast
        )
    }

    /// WRITE-BOTH (STEP 0, §9.1 point 3). Every write encodes the full structured `RecipeDefinition` into
    /// the additive `payloadData` blob AND keeps populating every legacy typed column exactly as before —
    /// so an un-updated paired device (which reads only the legacy columns) keeps working indefinitely.
    private static func apply(_ recipe: RecipeDefinition, to record: NSManagedObject, now: Date = Date()) {
        // --- Legacy typed columns (unchanged from pre-STEP-0) ---
        let webImport = recipe.webImport
        record.setValue(recipe.id.uuidString, forKey: "idString")
        record.setValue(webImport?.sourceURLString ?? "", forKey: "sourceURLString")
        record.setValue(recipe.name, forKey: "name")
        record.setValue((webImport?.ingredientLines ?? []).joined(separator: "\n"), forKey: "ingredientsText")
        record.setValue(recipe.notes, forKey: "summary")
        record.setValue(recipe.servings, forKey: "servings")
        record.setValue(webImport?.macros.protein ?? 0, forKey: "protein")
        record.setValue(webImport?.macros.carbs ?? 0, forKey: "carbs")
        record.setValue(webImport?.macros.fat ?? 0, forKey: "fat")
        // Write `micronutrientsJSON` UNCONDITIONALLY (clearing it when there are no micros) so an
        // in-place update that transitions a row from web-import to structured (`webImport == nil`,
        // e.g. a future edit converting an imported recipe) cannot leave stale micronutrients behind.
        // A leftover value would read back as a false divergence — the legacy projection yields an
        // empty `Micronutrients()` while the stale column decodes real values — permanently poisoning
        // the staleness check and hiding the user's structured edit. Every other legacy column is
        // already written unconditionally; this restores that invariant for the one conditional writer.
        if let micros = webImport?.micronutrients,
           let data = try? JSONEncoder().encode(micros),
           let json = String(data: data, encoding: .utf8) {
            record.setValue(json, forKey: "micronutrientsJSON")
        } else {
            record.setValue(nil, forKey: "micronutrientsJSON")
        }
        // Floor `savedAt` to whole seconds so the legacy column stores exactly the resolution the blob's
        // `.iso8601`-encoded `createdAt` reads back at, keeping the two representations byte-consistent
        // and the legacy-fallback read deterministic (whole-second dates on both paths).
        record.setValue(Self.flooredToWholeSecond(recipe.createdAt), forKey: "savedAt")

        // --- Additive structured blob (STEP 0) ---
        let payload = SavedRecipePayload(recipe: recipe, lastPayloadEncodedAt: now)
        if let data = try? RowPayloadCoders.makeEncoder().encode(payload) {
            record.setValue(data, forKey: "payloadData")
        } else {
            assertionFailure("saved recipe payload encode failed")
        }
    }
}

extension SavedRecipeRepository: SavedRecipeRepositoring {}

/// Reader/writer for the legacy pretty-printed `SavedRecipes.json` file in Application Support.
///
/// Retained as the one-time migration source for ``SavedRecipeRepository`` so recipes saved by
/// pre-Core-Data builds survive without loss: `load` tolerates a missing or undecodable file by
/// returning `[]`, and `save` writes atomically with complete file protection, encoding through
/// the shared `RowPayloadCoders` config with the pretty-printed opt-in.
nonisolated public struct LegacySavedRecipeJSONRepository {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        // Pretty-printed on-disk JSON (a human-readable file), otherwise the canonical shared config.
        self.encoder = RowPayloadCoders.makeEncoder(prettyPrinted: true)
        self.decoder = RowPayloadCoders.makeDecoder()
    }

    public func load() -> [RecipeDefinition] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let recipes = try? decoder.decode([LegacySavedRecipeDTO].self, from: data) else {
            return []
        }
        return recipes.map { $0.toRecipeDefinition() }
    }

    public func save(_ recipes: [RecipeDefinition]) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(recipes.map(LegacySavedRecipeDTO.init(recipe:)))
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            assertionFailure("saved recipe write failed")
            return false
        }
    }

    static func defaultFileURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return (directory ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Fernlet", isDirectory: true)
            .appendingPathComponent("SavedRecipes.json")
    }
}
