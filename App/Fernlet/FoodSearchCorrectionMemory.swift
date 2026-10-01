// FoodSearchCorrectionMemory.swift
// Fernlet
//
// Research §26 fix 1.10 (Docs/Food-Search-And-Community-Database-Research-2026-08-22.md, §30 row 8):
// the local correction memory. When the user replaces a wrong match in "Adjust meal", the text they
// searched and the food they chose are remembered HERE, on this device only, and republished into
// `FoodCatalog.setSearchAliases` so the same search answers with their own choice first.
//
// DEVIATION FROM THE REPORT, RECORDED AT THE SEAM IT AFFECTS. §26 proposed writing a
// `search-alias:<normalized Q>` TAG onto the picked `FoodItem`, and concluded from that "no new
// persisted surface … so no disposition row". That mechanism cannot carry the feature: the food a
// user picks in the correction typeahead is almost always a row of the read-only bundled/branded
// SQLite catalog, which has no writable `tags` array at all. Mirroring such a row into the synced
// `foodItems` array to give it one would put a COPY of catalog data into the synced blob under the
// same id the SQLite row already has — `FoodCatalog.index(for:)` unions bundled candidates with user
// items without de-duplicating by id, so every corrected food would then appear twice in its own
// search results. A small device-local map avoids both, and keeps corrections off the sync path
// entirely (they are food-name/consumption data). It IS a new persisted surface, so it carries a
// disposition row in Docs/PrivacyWipeCoverage.md, a token in `PrivacyWipeCoverageTests.wipeManifest`,
// and a row in `PersistedSurfaceWipeBoundaryTests.dispositions` — the same commit, as the wall
// requires.
//
// INGREDIENT-SEARCH ROUND F9b (Docs/Ingredient-Search-Deep-Research-2026-09-29.md §8, the owner's
// "sure" of 2026-09-30): the same memory also holds RECIPE PICKS — a food the person chose from below
// the top of a recipe ingredient list for words they typed out (`RecipeSearchPick`). Same key, same
// cap, same wipe row: no new persisted surface. Each entry carries its origin, because the two differ
// in reach and in precedence: a correction answers every search surface, a pick only the recipe ones;
// an ordinary pick never overwrites a correction, while a correction replaces a pick; and when the cap
// is reached the oldest pick goes before any correction.

import Foundation
import FernletDomainModel

/// One remembered search correction: the text the user searched, and the food they chose for it.
///
/// `query` is stored NORMALIZED (`FoodItemSearch.normalized`) because that is the form
/// `FoodCatalog.results` keys on. It is a **frozen English token**, not display copy: it is a
/// persisted dictionary key matched against an FTS index baked in English, so it never localizes
/// (localization wall). Nothing in this type is ever shown to the user.
///
/// Since F9b an entry also says where it came from (``Origin``). A correction is written exactly as
/// before — the stored JSON carries no `origin` key for it — so a file written by an earlier build
/// reads back unchanged, every entry a correction.
///
/// `nonisolated`, like the value it is: the app target defaults to the main actor, and the
/// hand-written `Codable` members below would otherwise make its conformances main-actor-isolated,
/// which an encoder or a comparison off the main actor could not use.
nonisolated struct FoodSearchCorrection: Codable, Equatable, Sendable {
    /// Where a remembered answer came from. The raw values are **frozen persisted tokens** (pinned in
    /// `LocalizationBoundaryTests`): renaming one re-reads every stored pick as something else.
    nonisolated enum Origin: String, CaseIterable, Sendable {
        /// "Adjust meal"'s Replace, saved: the person looked at a wrong answer and fixed it. Answers
        /// every search surface. Stored with no `origin` key, the format it has always had.
        case correction
        /// A recipe ingredient pick (F9b): the person typed the words out and chose this food from
        /// below the top of the recipe editor's or the swap sheet's list. Answers only the recipe
        /// surfaces, and never overwrites a correction.
        case recipePick
    }

    /// The normalized query this correction answers — a frozen persisted key.
    let query: String
    /// The food the user picked for that query.
    let foodItemID: UUID
    /// Where this answer came from.
    let origin: Origin

    /// Builds a correction from raw typed text, or nil when that text cannot be a search key.
    ///
    /// The length guard is `FoodItemSearch.minimumQueryLength`, the same floor the searcher applies:
    /// a query shorter than that returns nothing today, and an alias must never become a back door
    /// that makes two characters resolve to a food.
    init?(searchText: String, foodItemID: UUID, origin: Origin = .correction) {
        let normalizedQuery = FoodItemSearch.normalized(searchText)
        guard normalizedQuery.count >= FoodItemSearch.minimumQueryLength else { return nil }
        self.query = normalizedQuery
        self.foodItemID = foodItemID
        self.origin = origin
    }

    /// The stored JSON keys — frozen persisted tokens, like ``Origin``'s raw values.
    private nonisolated enum CodingKeys: String, CodingKey {
        case query, foodItemID, origin
    }

    /// Reads an entry. A missing `origin` is a correction (every entry an earlier build wrote); an
    /// origin this build does not know reads as a recipe pick — the narrower reach, and one a correction
    /// can still replace — rather than failing the whole list's decode.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = try container.decode(String.self, forKey: .query)
        foodItemID = try container.decode(UUID.self, forKey: .foodItemID)
        let rawOrigin = try container.decodeIfPresent(String.self, forKey: .origin)
        origin = rawOrigin.map { Origin(rawValue: $0) ?? .recipePick } ?? .correction
    }

    /// Writes an entry; a correction omits `origin`, so its bytes are the pre-F9b format.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(query, forKey: .query)
        try container.encode(foodItemID, forKey: .foodItemID)
        guard origin != .correction else { return }
        try container.encode(origin.rawValue, forKey: .origin)
    }
}

/// The corrections ONE sitting of the correction sheet has produced, held until the sheet is saved.
///
/// A value type rather than logic inside the view, and held rather than written, because the
/// invariant it carries is behavioural: **a correction the user cancels out of teaches the app
/// nothing.** Recording into a draft touches no storage at all; only `FernletStore
/// .rememberFoodSearchCorrections(_:)`, called from the sheet's Save, writes — which is what
/// `correctionsRecordedIntoADraftAreNotWrittenUntilSave` pins directly instead of inferring it from
/// where a call happens to sit in a file.
struct FoodSearchCorrectionDraft: Equatable, Sendable {
    /// R3 growth bound on one sitting: one entry per distinct search text corrected in this sheet. A
    /// meal has a handful of components, so 16 is already far past any real sequence of taps, and the
    /// oldest is dropped rather than letting a sheet held open all day grow without limit.
    static let maxPendingCorrections = 16

    /// The queued corrections, oldest first.
    private(set) var corrections: [FoodSearchCorrection] = []

    /// Creates an empty draft.
    init() {}

    /// Queues "this search text means this food".
    ///
    /// - Parameters:
    ///   - searchText: the text in the field at the moment of the pick — what the user actually
    ///     searched. Not the replaced item's name and not the meal's name: those are the app's words,
    ///     and neither is what they will type next time.
    ///   - prefilledWith: the text the field was seeded with (the suspect match's name). A pick made
    ///     WITHOUT editing the prefill is not a search the user typed — one tap would otherwise mint a
    ///     key spelled like a catalog row nobody types ("denny's mozzarella cheese sticks"), spending
    ///     a slot of the capped memory on a query that can never fire again. Compared after
    ///     normalization, so whitespace or case alone does not count as editing.
    ///   - foodItemID: the food they chose.
    mutating func record(searchText: String, prefilledWith prefill: String, foodItemID: UUID) {
        guard FoodItemSearch.normalized(searchText) != FoodItemSearch.normalized(prefill) else { return }
        guard let correction = FoodSearchCorrection(searchText: searchText, foodItemID: foodItemID) else { return }
        corrections.removeAll { $0.query == correction.query }
        // R3: bounded at the point of insertion — oldest-out, never append-only.
        if corrections.count >= Self.maxPendingCorrections {
            corrections.removeFirst(corrections.count - Self.maxPendingCorrections + 1)
        }
        corrections.append(correction)
    }
}

/// Device-local memory of the searches the user has corrected once (research §26 fix 1.10) and of
/// the foods they picked lower in a recipe ingredient list (F9b), keyed by normalized query and
/// republished into `FoodCatalog` as ranking inputs.
///
/// Deliberately a `UserDefaults` sidecar in the shape of ``BarcodeServingMemory`` and
/// ``RecipeWebImageAttemptMemory``, NOT a field on the synced blob: it is small, device-scoped
/// bookkeeping about how this person searches, and it must stay off the sync path. Order is recency
/// (newest last); re-answering a query REPLACES its entry and moves it to newest, so the memory holds
/// one answer per query and the answer is always the most recent one it is allowed to keep.
///
/// **Precedence between the two origins (F9b).** Latest explicit choice wins: a correction replaces
/// whatever the query held, a pick replaces an earlier pick, and an ordinary pick NEVER replaces a
/// correction — the correction was a person looking at a wrong answer and fixing it, a pick is a
/// person choosing among right-looking ones, and only "Forget corrected searches" or the wipe unlearns
/// a correction. Corrections publish into `FoodCatalog.setSearchAliases` (every surface), picks into
/// `FoodCatalog.setRecipeSearchPicks` (the recipe surfaces only).
///
/// **What "device-local" means here, precisely** (the wording `Docs/PrivacyWipeCoverage.md` uses for
/// the sibling sidecars): it never enters the synced snapshot and never reaches CloudKit, so it does
/// not travel between the user's devices — but it lives in the app container's preferences plist, so
/// like `fernlet.barcodeLastServings.v1` and `fernlet.recentActivityTypes` it DOES ride an encrypted
/// device backup and comes back with a restore of this device. It is not keychain-`ThisDeviceOnly`,
/// and nothing here claims otherwise.
///
/// **Bounded growth (Power-of-10 R3):** at most ``maxRememberedCorrections`` entries of both origins
/// together, trimmed at the point of insertion — every recipe pick, oldest first, before any
/// correction, then the oldest correction — and the list is otherwise pruned only by the wipe paths.
/// So a new pick into a memory already full of corrections is itself the entry dropped: a pick never
/// pushes a correction out.
enum FoodSearchCorrectionMemory {
    /// The single defaults key: a JSON array of ``FoodSearchCorrection``, oldest first.
    static let defaultsKey = "fernlet.foodSearchCorrections.v1"

    /// R3 growth cap, shared by both origins. One entry per distinct query — **measured at ~87 bytes**
    /// encoded for a correction (17,351 bytes for a full 200 during the 2026-08-23 review; a recipe pick
    /// adds its ~22-byte `origin`), so a saturated memory costs ~17–22 KB of the defaults plist. Picks
    /// are far more common than corrections, which is why eviction spends them first: a person's 200th
    /// recipe pick must not quietly unlearn a correction they made in Adjust meal. Evicting costs one
    /// un-learned answer, which the same single tap re-teaches.
    static let maxRememberedCorrections = 200

    /// The correction snapshot to publish into `FoodCatalog.setSearchAliases(_:)` — corrections only.
    ///
    /// Later entries win on a duplicate key, which cannot arise through ``remember(_:defaults:)``
    /// (it de-duplicates) but is the correct reading of a hand-edited or partially-written file.
    static func aliases(defaults: UserDefaults = .standard) -> [String: UUID] {
        answers(of: .correction, defaults: defaults)
    }

    /// The recipe-pick snapshot to publish into `FoodCatalog.setRecipeSearchPicks(_:)` (F9b).
    static func recipePicks(defaults: UserDefaults = .standard) -> [String: UUID] {
        answers(of: .recipePick, defaults: defaults)
    }

    /// How many searches this memory answers, of both origins — what Settings' "Forget corrected
    /// searches" row counts and clears.
    static func count(defaults: UserDefaults = .standard) -> Int {
        Set(stored(defaults: defaults).map(\.query)).count
    }

    /// Records `entries` as the newest, under the precedence above: a correction replaces any earlier
    /// answer for its query, a recipe pick replaces an earlier pick, and a pick for a query that holds a
    /// correction is dropped. Within one write, the last entry for a query wins.
    ///
    /// No-ops on an empty list or one whose every entry is dropped, and writes nothing when encoding
    /// fails (a corrupt write would be worse than a forgotten correction — the feature is an
    /// optimization, never a source of truth).
    static func remember(_ entries: [FoodSearchCorrection], defaults: UserDefaults = .standard) {
        guard !entries.isEmpty else { return }
        let existing = stored(defaults: defaults)
        let corrected = Set(existing.filter { $0.origin == .correction }.map(\.query))
        let incoming = lastPerQuery(entries).filter { entry in
            entry.origin == .correction || !corrected.contains(entry.query)
        }
        guard !incoming.isEmpty else { return }
        let replaced = Set(incoming.map(\.query))
        var kept = existing.filter { !replaced.contains($0.query) }
        kept.append(contentsOf: incoming)
        guard let data = try? JSONEncoder().encode(bounded(kept)) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Forgets every remembered correction and recipe pick. Invoked from the store's wipe paths
    /// (`resetAll` / `deleteAllData`) and from "Forget corrected searches", so this device-local
    /// sidecar is cleared alongside the other device-local ledgers rather than surviving a "Delete all
    /// data". The caller must also republish the (now empty) snapshots into the catalog, or the live
    /// process keeps answering with answers whose stored copy is gone.
    static func clearAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// One origin's answers as the catalog snapshot, later entries winning a duplicate key.
    private static func answers(of origin: FoodSearchCorrection.Origin, defaults: UserDefaults) -> [String: UUID] {
        Dictionary(
            stored(defaults: defaults).filter { $0.origin == origin }.map { ($0.query, $0.foodItemID) },
            uniquingKeysWith: { _, newest in newest }
        )
    }

    /// `entries` with only the LAST entry per query kept, in their original order — a recipe whose two
    /// rows were both picked for "butter" teaches the one saved last.
    private static func lastPerQuery(_ entries: [FoodSearchCorrection]) -> [FoodSearchCorrection] {
        var seen = Set<String>()
        // R2: bounded by the entries handed in.
        let newestFirst = entries.reversed().filter { seen.insert($0.query).inserted }
        return Array(newestFirst.reversed())
    }

    /// `entries` (oldest first) trimmed to the cap: recipe picks go first, oldest first, and only then
    /// the oldest corrections — so a correction is never evicted while a pick remains.
    private static func bounded(_ entries: [FoodSearchCorrection]) -> [FoodSearchCorrection] {
        var overflow = entries.count - maxRememberedCorrections
        guard overflow > 0 else { return entries }
        var kept: [FoodSearchCorrection] = []
        // R2: one pass over a list already bounded by the cap plus one write.
        for entry in entries {
            if overflow > 0, entry.origin == .recipePick {
                overflow -= 1
                continue
            }
            kept.append(entry)
        }
        // R3: still over only when the corrections alone overflow — oldest out.
        if overflow > 0 { kept.removeFirst(min(overflow, kept.count)) }
        return kept
    }

    /// The stored list, oldest first. Unreadable or malformed data reads as empty rather than
    /// throwing: a decode failure must degrade to "nothing has been corrected yet".
    ///
    /// R3 on the READ side too, mirroring `DiaryStore.boundedDailyScores`: a file already holding more
    /// than the cap — hand-edited, or written by a build whose cap was larger — must not reinstate an
    /// unbounded map into the catalog. The newest entries win.
    private static func stored(defaults: UserDefaults) -> [FoodSearchCorrection] {
        guard let data = defaults.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([FoodSearchCorrection].self, from: data) else { return [] }
        return Array(entries.suffix(maxRememberedCorrections))
    }
}
