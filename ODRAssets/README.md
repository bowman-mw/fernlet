# On-Demand Resource: FoodCatalogBranded.sqlite

The full branded food catalog (~364k USDA branded products with UPC/GTIN barcodes), delivered as an
**On-Demand Resource** so it is NOT part of the base app install and iOS can purge it under storage
pressure. When resident it is attached to the live `FoodCatalog` as a secondary source (see
`BrandedCatalogResourceLoader`); when absent the app falls back to the bundled base catalog
(`FernletKit/Sources/FoodCatalog/Resources/FoodCatalog.sqlite` — generics + a 50k curated branded floor).

## Xcode setup (one-time, cannot be done from source)
1. Add `FoodCatalogBranded.sqlite` to the **Fernlet app target**.
2. In the File Inspector, set its **On Demand Resource Tags** to `branded-food-catalog`.
   (Or: target → Build Phases → the resource's ODR tag.)
The loader requests that exact tag. Real ODR download/purge is only fully observable on device / TestFlight.

## Regeneration
Not committed-from-source. Regenerate from the USDA FDC branded download with the scripts under
`Scripts/branded-catalog/` (see that dir). The bundled base DB's 50k curated floor is regenerated via
the gated `FoodCatalogGenerationTests` (REGEN_FOOD_CATALOG_DB=1).
