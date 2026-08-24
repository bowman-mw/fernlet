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

import Foundation
import FernletDomainModel

/// One remembered search correction: the text the user searched, and the food they chose for it.
///
/// `query` is stored NORMALIZED (`FoodItemSearch.normalized`) because that is the form
/// `FoodCatalog.results` keys on. It is a **frozen English token**, not display copy: it is a
/// persisted dictionary key matched against an FTS index baked in English, so it never localizes
/// (localization wall). Nothing in this type is ever shown to the user.
struct FoodSearchCorrection: Codable, Equatable, Sendable {
    /// The normalized query this correction answers — a frozen persisted key.
    let query: String
    /// The food the user picked for that query.
    let foodItemID: UUID

    /// Builds a correction from raw typed text, or nil when that text cannot be a search key.
    ///
    /// The length guard is `FoodItemSearch.minimumQueryLength`, the same floor the searcher applies:
    /// a query shorter than that returns nothing today, and an alias must never become a back door
    /// that makes two characters resolve to a food.
    init?(searchText: String, foodItemID: UUID) {
        let normalizedQuery = FoodItemSearch.normalized(searchText)
        guard normalizedQuery.count >= FoodItemSearch.minimumQueryLength else { return nil }
        self.query = normalizedQuery
        self.foodItemID = foodItemID
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

/// Device-local memory of the searches the user has corrected once (research §26 fix 1.10), keyed by
/// normalized query and republished into `FoodCatalog` as a ranking input.
///
/// Deliberately a `UserDefaults` sidecar in the shape of ``BarcodeServingMemory`` and
/// ``RecipeWebImageAttemptMemory``, NOT a field on the synced blob: it is small, device-scoped
/// bookkeeping about how this person searches, and it must stay off the sync path. Order is recency
/// (newest last); re-correcting a query REPLACES its entry and moves it to newest, so the memory
/// holds one answer per query and the answer is always the most recent one.
///
/// **What "device-local" means here, precisely** (the wording `Docs/PrivacyWipeCoverage.md` uses for
/// the sibling sidecars): it never enters the synced snapshot and never reaches CloudKit, so it does
/// not travel between the user's devices — but it lives in the app container's preferences plist, so
/// like `fernlet.barcodeLastServings.v1` and `fernlet.recentActivityTypes` it DOES ride an encrypted
/// device backup and comes back with a restore of this device. It is not keychain-`ThisDeviceOnly`,
/// and nothing here claims otherwise.
///
/// **Bounded growth (Power-of-10 R3):** at most ``maxRememberedCorrections`` entries, oldest evicted
/// first at the point of insertion — the list is otherwise pruned only by the wipe paths.
enum FoodSearchCorrectionMemory {
    /// The single defaults key: a JSON array of ``FoodSearchCorrection``, oldest first.
    static let defaultsKey = "fernlet.foodSearchCorrections.v1"

    /// R3 growth cap. One entry per distinct corrected query — **measured at ~87 bytes** encoded
    /// (17,351 bytes for a full 200 during the 2026-08-23 review), so a saturated memory costs ~17 KB
    /// of the defaults plist while covering far more corrections than a person makes: the
    /// write site is the Replace affordance on a low-confidence match, not ordinary logging. Evicting
    /// the oldest costs one un-learned correction for a query last searched hundreds of corrections
    /// ago, which the user can re-teach with the same single tap that taught it the first time.
    static let maxRememberedCorrections = 200

    /// The alias snapshot to publish into `FoodCatalog.setSearchAliases(_:)`.
    ///
    /// Later entries win on a duplicate key, which cannot arise through ``remember(_:defaults:)``
    /// (it de-duplicates) but is the correct reading of a hand-edited or partially-written file.
    static func aliases(defaults: UserDefaults = .standard) -> [String: UUID] {
        Dictionary(stored(defaults: defaults).map { ($0.query, $0.foodItemID) }, uniquingKeysWith: { _, newest in newest })
    }

    /// Records `corrections` as the newest entries, replacing any earlier answer for the same query.
    ///
    /// No-ops on an empty list, and writes nothing when encoding fails (a corrupt write would be worse
    /// than a forgotten correction — the feature is an optimization, never a source of truth).
    static func remember(_ corrections: [FoodSearchCorrection], defaults: UserDefaults = .standard) {
        guard !corrections.isEmpty else { return }
        let replaced = Set(corrections.map(\.query))
        var entries = stored(defaults: defaults).filter { !replaced.contains($0.query) }
        entries.append(contentsOf: corrections)
        // R3: bounded at the point of insertion — oldest-out, never append-only.
        if entries.count > maxRememberedCorrections {
            entries.removeFirst(entries.count - maxRememberedCorrections)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Forgets every remembered correction. Invoked from the store's wipe paths (`resetAll` /
    /// `deleteAllData`) so this device-local sidecar is cleared alongside the other device-local
    /// ledgers rather than surviving a "Delete all data". The caller must also republish the (now
    /// empty) snapshot into the catalog, or the live process keeps answering with corrections whose
    /// stored copy is gone.
    static func clearAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
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
