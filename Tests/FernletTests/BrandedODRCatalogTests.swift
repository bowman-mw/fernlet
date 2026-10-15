import Foundation
import Testing
import FoodCatalog
import FernletDomainModel

/// Integration test for the tiered branded catalog: attaches the REAL On-Demand-Resource branded
/// database (`ODRAssets/FoodCatalogBranded.sqlite`, ~364k products) to the live bundled base
/// `FoodCatalog` and verifies barcode + search resolution and graceful fallback on detach.
///
/// Skips cleanly when the ODR asset is absent or is the app build's empty placeholder (the 178 MB
/// file is gitignored, so a fresh clone or CI never has it), so a lean CI without the large file
/// still passes. When present it exercises the whole data + multi-source pipeline end to end
/// against the real database.
struct BrandedODRCatalogTests {
    private static var odrURL: URL? {
        // repo root -> ODRAssets/FoodCatalogBranded.sqlite (mirrors FoodCatalogGenerationTests).
        usableBrandedDatabase(at: RepoRoot.url("ODRAssets/FoodCatalogBranded.sqlite"))
    }

    /// `url` when it names a branded database worth opening, else nil. A missing file is a checkout
    /// that never generated the catalog; an EMPTY one is the placeholder the app target's "Ensure
    /// branded catalog ODR source" build phase writes there on every build without it, which opens
    /// as valid SQLite with no rows (`BrandedCatalogResourceLoader` refuses it the same way). The
    /// replay probes read the same file through this.
    static func usableBrandedDatabase(at url: URL) -> URL? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return size > 0 ? url : nil
    }

    /// A GTIN that lives ONLY in the ODR set — the branded split is disjoint from the base's curated
    /// 50k floor by construction, and this is verified against both shipped databases.
    private static let odrOnlyBarcode = "01633636543505"   // "Granola, Cinnamon, Raisin"

    @Test func brandedODRAttachesResolvesBarcodeAndFallsBackOnDetach() throws {
        guard let odrURL = Self.odrURL else { return }   // asset absent or placeholder — skip

        let catalog = FoodCatalog.bundled()
        let baseCount = catalog.bundledCount
        #expect(baseCount > 100_000, "base catalog should carry generics + the 50k curated floor")

        // Before attach: an ODR-only product does not resolve from the base floor.
        #expect(catalog.item(forBarcode: Self.odrOnlyBarcode) == nil)

        // Open the branded source with the scale-tuned config the loader uses.
        let branded = try #require(
            SQLiteBundledFoodSource(url: odrURL, skipPriorityOrder: true, candidateCap: 600),
            "should open the ODR branded database"
        )
        #expect(branded.count == 364_457)

        catalog.attachBrandedSource(branded)
        #expect(catalog.hasBrandedSource)
        #expect(catalog.bundledCount == baseCount + branded.count)

        // Barcode now resolves from the attached branded source.
        let scanned = try #require(catalog.item(forBarcode: Self.odrOnlyBarcode))
        #expect(scanned.name.localizedCaseInsensitiveContains("granola"))
        #expect(scanned.barcode != nil)

        // All-searchable: branded products surface in text search too.
        #expect(!catalog.results(for: "granola", context: .userTyped).isEmpty)

        // Detach → graceful fallback to the base floor; the ODR-only product no longer resolves.
        catalog.detachBrandedSource()
        #expect(!catalog.hasBrandedSource)
        #expect(catalog.bundledCount == baseCount)
        #expect(catalog.item(forBarcode: Self.odrOnlyBarcode) == nil)
    }
}
