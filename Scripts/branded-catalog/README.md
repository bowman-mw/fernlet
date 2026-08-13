# Branded food catalog regeneration

Regenerates the branded UPC/GTIN food data from the USDA FoodData Central **branded** JSON download
(`FoodData_Central_branded_food_json_*.json`, ~3 GB). Produces two artifacts:

- `FoodDataSource/BrandedCuratedFoodItems.json` — ~50k category-balanced curated products, compiled INTO
  the bundled base `FoodCatalog.sqlite` (the always-available floor) by `FoodCatalogGenerationTests`.
- `ODRAssets/FoodCatalogBranded.sqlite` — the remaining ~364k products, shipped as an On-Demand Resource.

The two sets are disjoint by GTIN, so base + ODR = the full ~414k with no duplicates.

## Steps (paths are currently hard-coded to a scratch dir — adjust the constants at the top of each script)
1. `python3 1_convert_branded.py`  → `BrandedFoodItems.json` (full ~414k, deduped by GTIN, cleaned names,
   per-serving macros, 14-digit GTINs).
2. `python3 2_split_curated_odr.py` → `BrandedCuratedFoodItems.json` (50k) + `BrandedODRFoodItems.json` (364k).
3. `python3 3_build_odr_sqlite.py`  → `FoodCatalogBranded.sqlite` (v2 schema, FTS5, matches
   `FoodCatalogSchema` in BundledFoodStore.swift).
4. Copy `BrandedCuratedFoodItems.json` → `FoodDataSource/`, then regenerate the base DB:
   `TEST_RUNNER_REGEN_FOOD_CATALOG_DB=1 xcodebuild test-without-building -project App/Fernlet.xcodeproj -scheme Fernlet \
      -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:Tests/FernletTests/FoodCatalogGenerationTests`
5. Copy `FoodCatalogBranded.sqlite` → `ODRAssets/` and ODR-tag it in Xcode (see ODRAssets/README.md).

The Python build mirrors the Swift `USDAFoodItemRecord` branded decode + `FoodCatalogDatabaseBuilder`
schema; `Tests/FernletTests/BrandedODRCatalogTests` validates the resulting DB against the live `FoodCatalog`.
