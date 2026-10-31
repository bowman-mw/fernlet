import FernletFoundation
import Foundation

/// Deletes cache files no build reads any more (perf review 2026-10-31): the bundled food catalog's
/// decoded-JSON caches, `food_catalog_v1` and `food_catalog_v2` (`.bplist` plus their `.key`), orphaned in
/// `Library/Caches` since the catalog moved to SQLite (c2d800bb, 2026-06-24) — 38 MB on the owner's phone.
///
/// Only files named here are touched, only in `Caches`, and only ones no shipping code writes, so it can
/// never take user data. Runs once per launch off the main actor; a file already gone costs one `stat`.
nonisolated enum OrphanedCacheSweep {
    /// The retired cache files, by name under `Library/Caches`.
    static let retiredNames = [
        "food_catalog_v1.bplist", "food_catalog_v1.key",
        "food_catalog_v2.bplist", "food_catalog_v2.key",
    ]

    /// Removes every retired file under `caches` (the app's Caches directory unless a test passes its own).
    ///
    /// - Returns: The names actually removed.
    @discardableResult
    static func run(in caches: URL? = nil) -> [String] {
        let fileManager = FileManager.default
        guard let directory = caches ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return [] }
        var removed: [String] = []
        for name in retiredNames {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
                removed.append(name)
            } catch {
                FernletAuditLog.log("orphanedCache.removeFailed", context: ["name": name])
            }
        }
        return removed
    }
}
