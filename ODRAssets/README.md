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

## Getting the database (fresh clones and Xcode Cloud)
The published database is a GitHub Release asset on this repository: release
[`branded-food-catalog-v1`](https://github.com/bowman-mw/fernlet/releases/tag/branded-food-catalog-v1),
`FoodCatalogBranded.sqlite.gz` (58 MB gzipped, sha256 of the decompressed database
`7dc78cb95401f7a17cc1b078fbe2a54fd1493019f8fc7864218635ce49a5b5a6`). The data is USDA FoodData Central's
public-domain (CC0) branded download. `Scripts/fetch-branded-catalog.sh` downloads it, checks the pinned
hash and moves it here. It leaves a matching database alone, replaces a zero-byte placeholder, and
refuses to overwrite a different non-empty one without `--force`.

Xcode Cloud clones fresh for every build, so its post-clone hook runs that script before any build:
`App/ci_scripts/ci_post_clone.sh` beside the project and `ci_scripts/ci_post_clone.sh` beside the
workspace. Xcode Cloud reads the `ci_scripts` folder next to whichever container its workflow builds.
That is what lets a Release archive there pass the **Ensure branded catalog ODR source** phase with the
real pack, with no `FERNLET_ALLOW_MISSING_BRANDED_CATALOG` override.

A regenerated database is published as a NEW release (`branded-food-catalog-v2`, …), and the script's
tag, URL and hash move in the same commit. An asset is never replaced in place, so every commit keeps
building the catalog it was tested with.

## Regeneration
Not committed-from-source. Regenerate from the USDA FDC branded download with the scripts under
`Scripts/branded-catalog/` (see that dir). The bundled base DB's 50k curated floor is regenerated via
the gated `FoodCatalogGenerationTests` (REGEN_FOOD_CATALOG_DB=1).
