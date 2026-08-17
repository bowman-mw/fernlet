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
///   • Assigning the `branded-food-catalog` ODR tag to `FoodCatalogBranded.sqlite` is an Xcode project
///     setting ("On Demand Resource Tags" on the resource) — it can't be done in source.
///   • Real ODR *download* and *purge* behavior is only fully observable on a device / TestFlight; the
///     bundle-first path above is what covers Simulator and automated tests.
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
                req.endAccessingResources()
                return
            }
            request = req   // keep the access alive for the session
        } catch {
            // Recovery: not downloaded yet, offline, or purged — stay on base coverage. Logged
            // unconditionally so a Release install can say WHY it is on the base catalog.
            FernletAuditLog.log(
                "brandedCatalog.odr.unavailable",
                context: ["error": error.localizedDescription]
            )
        }
    }

    /// Detach the branded source and release the ODR hold — e.g. in response to storage/memory pressure.
    /// The catalog immediately falls back to base + user items.
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
        catalog.attachBrandedSource(source)
        attached = true
        return true
    }
}
