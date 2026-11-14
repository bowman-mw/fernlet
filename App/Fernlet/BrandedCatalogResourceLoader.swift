import Foundation
import FernletFoundation
import FoodCatalog

/// Loads the full branded food database (~364k products, `FoodCatalogBranded.sqlite`) and attaches it to
/// the live `FoodCatalog` as a secondary source, so barcode scans and search resolve the full branded set.
///
/// The database is delivered as an **On-Demand Resource** (tag `branded-food-catalog`) so it is *not* part
/// of the base install and iOS can purge it under storage pressure. When it is absent or has been purged,
/// the catalog gracefully falls back to its bundled base source (generics + the curated branded floor) plus
/// the user's own remembered items — nothing here ever blocks launch or crashes on failure.
///
/// Two acquisition paths, tried in order:
///   1. **Bundle-first** — if `FoodCatalogBranded.sqlite` is present directly in the app bundle (a dev /
///      QA / manual build where the file is embedded rather than ODR-tagged), open it straight away. This
///      makes the whole feature exercisable in the Simulator and unit/UI tests *without* ODR infrastructure.
///   2. **On-Demand Resource** — otherwise request the `branded-food-catalog` tag and, once the OS has the
///      asset resident, open it from the request's bundle.
///
/// NOTE (setup / validation boundary):
///   • The `branded-food-catalog` tag is assigned in the project: `ODRAssets/` is a synchronized folder of
///     the app target whose exception set tags `FoodCatalogBranded.sqlite` (`assetTagsByRelativePath`).
///     The database itself is gitignored (178 MB), so a clone without it builds an EMPTY placeholder pack
///     (the target's "Ensure branded catalog ODR source" phase; Release refuses to). An empty file opens
///     as a valid SQLite database with no `food` table, so `attach` refuses a source with zero rows rather
///     than attaching a catalog that answers nothing. See `ODRAssets/README.md`.
///   • Real ODR *download* and *purge* behavior is only fully observable on a device / TestFlight.
///     Simulator Debug builds embed the pack in the app (`EMBED_ASSET_PACKS_IN_PRODUCT_BUNDLE` for the
///     simulator SDK), so the ODR path itself runs there however the app was installed; without that,
///     only a launch from the Xcode IDE could reach the development pack server.
@MainActor
final class BrandedCatalogResourceLoader {
    static let odrTag = "branded-food-catalog"
    static let resourceName = "FoodCatalogBranded"
    static let resourceExtension = "sqlite"

    /// The scale-tuned config for the branded source: it is 100% one `data_type`, so the priority
    /// `ORDER BY` is a wasted full-match-set sort — skip it, and cap candidates tightly (we only ever
    /// display a handful) so a broad prefix over ~364k rows stays a few milliseconds.
    private static let candidateCap = 600

    /// Held for the app session so the OS doesn't reclaim the ODR access mid-use. `endAccessingResources`
    /// is only called when we deliberately detach (`purge`).
    private var request: NSBundleResourceRequest?
    private var attached = false
    /// The single in-flight load. R3 (task fan-out): overlapping calls await this one instead of each
    /// creating an `NSBundleResourceRequest`, where the loser's resource hold would be leaked when the
    /// winner overwrote `request`.
    private var inFlight: Task<Void, Never>?
    /// When the last On-Demand Resource request failed (offline, not downloaded yet, purged), so a later
    /// foreground can try again (roadmap G1, F10: a failure used to wait for the next cold launch).
    private var lastFailure: Date?
    /// Set when the pack arrived but holds no usable catalog (a build without the database ships an
    /// empty placeholder): asking again cannot help, so the retry never runs.
    private var packUnusable = false

    /// The least time between two retries after a failed request: a foreground activation inside it
    /// does nothing, so switching apps back and forth never queues ODR request after request.
    static let retryInterval: TimeInterval = 5 * 60

    /// Best-effort attach of the branded catalog. Safe to call more than once (no-op once attached, and
    /// a concurrent call joins the one in flight), never throws, never blocks launch. Leaves the catalog
    /// on base + user items on any failure.
    func loadBrandedCatalog(into catalog: FoodCatalog) async {
        if let inFlight {
            await inFlight.value
            return
        }
        guard !attached, !catalog.hasBrandedSource else { return }
        let task = Task { await self.performLoad(into: catalog) }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// Tries the load again when the last attempt FAILED at least ``retryInterval`` ago (roadmap G1,
    /// F10). A no-op once attached, before any attempt, after an unusable pack, and inside the interval.
    /// Called on every foreground activation (`FernletStore.retryBrandedCatalogIfNeeded()`).
    func retryIfNeeded(into catalog: FoodCatalog, now: Date = Date()) async {
        guard !attached, !packUnusable, let lastFailure,
              now.timeIntervalSince(lastFailure) >= Self.retryInterval else { return }
        await loadBrandedCatalog(into: catalog)
    }

    /// The actual acquisition, run inside the single in-flight task (see `loadBrandedCatalog`).
    private func performLoad(into catalog: FoodCatalog) async {
        // 1) Bundle-first (dev / QA / tests): the DB embedded directly, not ODR-tagged.
        if let url = Bundle.main.url(forResource: Self.resourceName, withExtension: Self.resourceExtension),
           attach(from: url, into: catalog) {
            return
        }

        // 2) On-Demand Resource.
        let req = NSBundleResourceRequest(tags: [Self.odrTag])
        req.loadingPriority = 0.2   // low / non-urgent — never competes with interactive launch work
        do {
            try await req.beginAccessingResources()
            guard let url = req.bundle.url(forResource: Self.resourceName, withExtension: Self.resourceExtension),
                  attach(from: url, into: catalog) else {
                // The pack arrived but holds no usable catalog: the placeholder a build without the
                // database ships (see the type's NOTE), or a file that would not open.
                FernletAuditLog.log("brandedCatalog.odr.packUnusable")
                packUnusable = true
                req.endAccessingResources()
                return
            }
            request = req   // keep the access alive for the session
            lastFailure = nil
        } catch {
            lastFailure = Date()
            // Recovery: not downloaded yet, offline, or purged — stay on base coverage until a later
            // foreground retries (`retryIfNeeded`). Logged
            // unconditionally so a Release install can say WHY it is on the base catalog.
            FernletAuditLog.log(
                "brandedCatalog.odr.unavailable",
                context: ["error": error.localizedDescription]
            )
        }
    }

    /// Detach the branded source and release the ODR hold — e.g. in response to storage/memory pressure.
    /// The catalog immediately falls back to base + user items. Nothing calls it today (the 2026-11-09
    /// review); it stays as the release seam, and a later ``loadBrandedCatalog(into:)`` re-attaches.
    func purge(from catalog: FoodCatalog) {
        catalog.detachBrandedSource()
        attached = false
        request?.endAccessingResources()
        request = nil
    }

    private func attach(from url: URL, into catalog: FoodCatalog) -> Bool {
        guard let source = SQLiteBundledFoodSource(
            url: url,
            skipPriorityOrder: true,
            candidateCap: Self.candidateCap
        ) else { return false }
        // An empty placeholder opens fine and counts zero rows (no `food` table); attaching it would
        // put a source that answers nothing ahead of the fallback.
        guard source.count > 0 else { return false }
        catalog.attachBrandedSource(source)
        attached = true
        return true
    }
}
