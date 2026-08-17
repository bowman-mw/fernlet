import Foundation

/// Device-local memory of which saved recipes' ONE automatic web-image download THIS device has
/// already attempted (success or failure — there is no automatic retry), keyed by recipe id.
///
/// This is the per-device half of the web-image contract — **one attempt per device, suppression
/// syncs**: the user's intent that no web picture may ever be fetched (`RecipeWebImport/webImageSuppressed`)
/// rides the synced recipe row, while this attempt bookkeeping deliberately does NOT. The sealed
/// photo bytes live only in the device-local `RecipePhotos` store, so a second iCloud-synced device
/// receives the row but never the picture; a synced attempted flag would permanently block that
/// device from performing its own single download. Splitting the two lets each device try once
/// while a deletion/ownership decision still propagates everywhere.
///
/// Deliberately a `UserDefaults` sidecar (mirroring `BarcodeServingMemory`), NOT a field on the
/// synced row: small, non-sensitive, device-scoped bookkeeping that must stay off the sync path.
/// Entries are pruned when their recipe is deleted, cleared per-recipe by the explicit "Re-import
/// from source" (which re-arms this device's attempt), and cleared wholesale by the wipe paths.
enum RecipeWebImageAttemptMemory {
    /// The single defaults key: an array of recipe-id UUID strings whose attempt is consumed here.
    static let defaultsKey = "fernlet.recipeWebImageAttempts.v1"

    /// Power-of-10 R3 growth cap: the newest N attempts are remembered, oldest evicted first.
    /// The list is otherwise pruned only by local deletion and the wipe paths, so a recipe deleted
    /// by a sync from another device would leave its id here forever. Evicting an ancient entry
    /// costs at most one re-armed image download for a recipe last seen hundreds of imports ago.
    static let maxRememberedAttempts = 500

    /// Whether this device has already spent its one automatic download attempt for `recipeID`.
    static func hasAttempted(_ recipeID: UUID, defaults: UserDefaults = .standard) -> Bool {
        storedIDs(defaults: defaults).contains(recipeID.uuidString)
    }

    /// Consumes this device's one automatic attempt for `recipeID` (idempotent).
    static func recordAttempt(_ recipeID: UUID, defaults: UserDefaults = .standard) {
        var ids = storedIDs(defaults: defaults)
        guard !ids.contains(recipeID.uuidString) else { return }
        // R3: bounded growth at the point the entry is added — oldest-out, never append-only.
        if ids.count >= maxRememberedAttempts {
            ids.removeFirst(ids.count - maxRememberedAttempts + 1)
        }
        ids.append(recipeID.uuidString)
        defaults.set(ids, forKey: defaultsKey)
    }

    /// Forgets the attempt for `recipeID`: pruning bookkeeping for a deleted recipe, or re-arming
    /// the attempt after an explicit "Re-import from source" (the synced suppression, if any,
    /// still wins at fetch time).
    static func clearAttempt(for recipeID: UUID, defaults: UserDefaults = .standard) {
        let ids = storedIDs(defaults: defaults).filter { $0 != recipeID.uuidString }
        if ids.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(ids, forKey: defaultsKey)
        }
    }

    /// Forgets every recorded attempt. Invoked from the store's wipe paths (`resetAll` /
    /// `deleteAllData`) so this device-local sidecar is cleared alongside the other device-local
    /// ledgers rather than surviving a "Delete all data".
    static func clearAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// The raw stored id-string list (empty when nothing has been recorded).
    private static func storedIDs(defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: defaultsKey) ?? []
    }
}
