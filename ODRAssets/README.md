# On-Demand Resource: FoodCatalogBranded.sqlite

The full branded food catalog (~364k USDA branded products with UPC/GTIN barcodes), delivered as an
**On-Demand Resource** so it is NOT part of the base app install and iOS can purge it under storage
pressure. When resident it is attached to the live `FoodCatalog` as a secondary source (see
`BrandedCatalogResourceLoader`); when absent the app falls back to the bundled base catalog
(`FernletKit/Sources/FoodCatalog/Resources/FoodCatalog.sqlite` — generics + a 50k curated branded floor).

## How the project wires it
This folder is a synchronized folder of the **Fernlet app target** (`../ODRAssets` in
`App/Fernlet.xcodeproj`). Its exception set tags `FoodCatalogBranded.sqlite` with the On Demand
Resource tag `branded-food-catalog` (`assetTagsByRelativePath`) and keeps this README out of the
bundle. The loader requests that exact tag. Real ODR download/purge is only fully observable on
device / TestFlight.

Simulator Debug builds embed the pack in the app
(`EMBED_ASSET_PACKS_IN_PRODUCT_BUNDLE[sdk=iphonesimulator*] = YES` on the Fernlet target's Debug
configuration). Without it, a development build's pack manifest points at a localhost server that
only exists while Xcode itself launches the app. An `xcodebuild` + `simctl install` run, or a UI-test
run, then fails the request ("Could not connect to the server") and stays on the base catalog.
Device and Release builds are unchanged: the App Store hosts the pack.

The database is gitignored: at 178 MB it is over GitHub's file limit. A tagged resource that is not
on disk fails the build, so the target's **Ensure branded catalog ODR source** phase (before
Resources) handles a clone without it:
- **Debug:** it writes an empty placeholder here and the build goes on. The loader refuses an empty
  database (zero rows), logs `brandedCatalog.odr.packUnusable` and stays on the base catalog.
- **Release:** it fails the build, because shipping the tag without its database is the silent
  fallback this wiring exists to remove. Set `FERNLET_ALLOW_MISSING_BRANDED_CATALOG=YES` to build a
  Release without it on purpose.

A placeholder left behind by a Debug build is a zero-byte file. Replace it with the real database
before a Release build.

## Regeneration
Not committed-from-source. Regenerate from the USDA FDC branded download with the scripts under
`Scripts/branded-catalog/` (see that dir). The bundled base DB's 50k curated floor is regenerated via
the gated `FoodCatalogGenerationTests` (REGEN_FOOD_CATALOG_DB=1).
