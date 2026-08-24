# Offline food-catalog preservation pipeline

This directory builds a source-faithful, search-indexed SQLite catalog for data validation. The
output is **not** the app's shipping schema and must never replace or be committed beside
`FernletKit/Sources/FoodCatalog/Resources/FoodCatalog.sqlite`. Runtime adoption, compacting, and an
ODR split require a separate product/schema decision.

## Authorized sources

`FoodDataSource/FoodCatalogSourceManifest.json` is the source contract. It pins accepted filenames,
byte sizes, SHA-256 values, versions, publishers, licenses, attribution, expected counts, FDC member
hashes, and the FDC data-type/curated-GTIN eligibility rules. The raw archives stay outside Git.

| Source | Pipeline role | Eligibility |
| --- | --- | --- |
| FoodData Central CSV 2026-04-30 | Canonical USDA input | Include Survey (FNDDS), SR Legacy, and Foundation foods. Also enrich only the existing 50,000 GTIN curated-branded allowlist from raw FDC Branded records; preserve every matching record, never the full Branded universe. Exclude Experimental, sample, subsample, market-acquisition, and agricultural-acquisition foods and analytical dependency rows. CC0/public domain. |
| FNDDS 2021-2023 Ingredients workbook | Independent relation validation and moisture authority | Include all 18,584 dish/ingredient relations. USDA public-domain work. |
| `surveyDownload.json` | Prior-release validation fixture | Validate identities, descriptions, categories, ingredient relations, moisture, and portion semantics. Never co-ingest it. |
| SR Legacy 2018-04 JSON | Prior-release validation fixture | Validate the 7,793 canonical SR identities/descriptions. Never co-ingest it. |
| Existing `BrandedCuratedFoodItems.json` | Bounded branded base tier | Include the existing deterministic 50,000-row subset. Do not import the roughly two million current FDC Branded rows. CC0/public domain. |
| CoFID 2021 | Parallel national composition source | Include under OGL v3 with the manifest attribution. Preserve source text and sheet basis. |
| Canadian Nutrient File 2026 | Excluded | CNF's no-modification instruction still needs an exact-value adapter policy or written clearance. Do not ingest without that decision. |
| NEVO 2025 v9.0 | Excluded | Supplied terms do not grant transformed redistribution. Do not ingest without new written permission. |

The curated branded base remains compatible with Fernlet's existing optional branded ODR tier, but
this pipeline neither reads nor writes an ODR database. A full FDC Branded refresh is deliberately
excluded.

## Prerequisites and inputs

Python 3 with SQLite FTS5 is sufficient; the pipeline uses only the standard library. It streams ZIP
CSV and XLSX XML members without extracting or modifying source archives. Before running, verify
that the following exact files are in one external directory:

- `FoodData_Central_csv_2026-04-30.zip`
- `2021-2023 FNDDS At A Glance - FNDDS Ingredients.xlsx` (the manifest also accepts the equivalent
  display filename `FNDDS 2021-2023 Ingredients.xlsx`)
- `surveyDownload.json`
- `FoodData_Central_sr_legacy_food_json_2018-04.json`
- `McCance_Widdowsons_Composition_of_Foods_Integrated_Dataset_2021..xlsx` (the double period is the
  supplied filename)

The repo-local `FoodDataSource/BrandedCuratedFoodItems.json` is also required. The generator checks
every input's filename, byte size, and SHA-256 before opening it. It performs no network access.
This Python tooling is outside the Swift-only Power-of-10 scanner; its separate input-bound and
publication contracts are enforced by the fast Python test suite below.

The tool rejects oversized manifests/evidence, source files, ZIP/XLSX member counts and expansion
ratios, CSV headers/records/cells, XLSX sheets/rows/cells/shared strings, JSON nesting/objects, and
food/nutrient/portion/relation collections before unbounded growth. SQL bulk insertion is capped at
10,000 rows per batch; CSV input is capped at 30,000,000 data records (the pinned FDC nutrient member has
27,195,013). The explicit limits are intentionally above the pinned releases but below
unreviewed archive or memory growth; change them only together with the source contract and tests.

## Reproducible command

Run from the repository root. Set the raw directory explicitly; do not copy archives into Git.

```sh
FERNLET_FOOD_RAW_DIR=/Users/michaelbowman/Downloads

python3 Scripts/food-catalog/build_catalog.py \
  --manifest FoodDataSource/FoodCatalogSourceManifest.json \
  --fdc-zip "$FERNLET_FOOD_RAW_DIR/FoodData_Central_csv_2026-04-30.zip" \
  --fndds-ingredients "$FERNLET_FOOD_RAW_DIR/2021-2023 FNDDS At A Glance - FNDDS Ingredients.xlsx" \
  --survey-validation-json "$FERNLET_FOOD_RAW_DIR/surveyDownload.json" \
  --sr-validation-json "$FERNLET_FOOD_RAW_DIR/FoodData_Central_sr_legacy_food_json_2018-04.json" \
  --branded-curated-json FoodDataSource/BrandedCuratedFoodItems.json \
  --cofid-xlsx "$FERNLET_FOOD_RAW_DIR/McCance_Widdowsons_Composition_of_Foods_Integrated_Dataset_2021..xlsx" \
  --output-dir .food-catalog-build \
  --committed-catalog FernletKit/Sources/FoodCatalog/Resources/FoodCatalog.sqlite
```

The generator refuses the committed resource directory and only accepts `.food-catalog-build` or a
temporary directory. `.food-catalog-build/` is ignored by Git. Each build writes a private staged
generation directory, commits and vacuums the database, validates SQLite integrity, foreign keys,
the exact output contract, source/evidence hashes, and the report/database hash pair. Only then does
one atomic `current` pointer switch publish the matched `FoodCatalog.sqlite` and
`validation-report.json`. A generation or report failure removes its staging directory and leaves the
previous `current` pair byte-for-byte untouched.

Validate an existing schema-compatible artifact without regenerating it with:

```sh
python3 Scripts/food-catalog/validate_catalog.py \
  --manifest FoodDataSource/FoodCatalogSourceManifest.json \
  --catalog .food-catalog-build/current/FoodCatalog.sqlite \
  --evidence .food-catalog-build/current/validation-report.json \
  --committed-catalog FernletKit/Sources/FoodCatalog/Resources/FoodCatalog.sqlite
```

## Preservation and identity rules

- Stable identity is always namespaced source identity (`usda_fdc:<fdc_id>`, curated GTIN identity,
  or `uk_cofid:<code>`), never normalized name. Normalized text is search-only.
- `branded_compatibility` is an exact 50,000-row GTIN-to-shipping-UUID map loaded from the committed
  catalog. A GTIN can map to only one shipping UUID, and a UUID can map to only one GTIN.
- `branded_fdc_record`, `branded_fdc_nutrient`, and `branded_fdc_portion` preserve every selected
  FDC Branded record and its raw FDC fields. Duplicate records for one GTIN are history, not a cue to
  pick a canonical record.
- `00070074649214` is the one pinned compatibility exception: it retains shipping UUID
  `AFC5AD5B-8E57-47C0-8ADC-31DA31CDFB92` but has no matching record in the pinned full FDC archive.
  The generator fails closed for any other missing selected GTIN.
- The duplicate CoFID code `13-669` fails closed unless the two expected names are present. It gets
  deterministic composite IDs `uk_cofid:13-669#198615dc8ced` and
  `uk_cofid:13-669#80c4d8f2ad38`; the records are never conflated.
- FDC nutrient rows retain their FDC row ID, amount text, derivation, data points, range, median,
  limit of quantification, footnote, year, and percent-daily-value fields.
- `fndds_dish` retains the dish description, WWEIA category number/description, and both raw workbook
  and canonical moisture values. FNDDS relations retain FDC relation ID, sequence, ingredient
  code/source ID, raw and canonical weight, retention, amount/unit, portion code/description, and
  raw and canonical workbook-authoritative moisture change. Ingredient nutrient histories are keyed
  by ingredient, nutrient, and start/end date window, preserving all 275,535 release rows rather
  than overwriting older windows.
- Portion rows retain source ID, sequence, raw amount/unit, gram weight, modifier, description,
  data-points, footnote, and year.
- CoFID keeps each sheet and food basis. Fatty-acid sheets distinguish per-100-g-fatty-acid from
  per-100-g-food; alcoholic-beverage (`Q*`) food groups retain the per-100-ml basis and other food
  groups retain the per-100-g basis. Numeric source text, parenthesized numeric text, `Tr`, and `N`
  remain distinct. Blank cells are not written as zero; the complete nutrient-definition grid makes
  their missingness reconstructable.
- `legacy_compatibility` is an explicit nullable projection for the current app model. It uses
  decimal half-up rounding only for numeric macros. Trace, present-but-unknown, and missing values
  remain `NULL`; this mapping never mutates the preservation tables.
- FTS5 indexes display and normalized names, `brand_source`, category, and assembled ingredient text.
  Index population is bounded to one row per food and validated through `fts5vocab` plus field probes.

All loops and collections have explicit upper bounds. Input order does not define identity or
deduplication. The output is deterministic for the pinned inputs and generator revision. Publication
fsyncs both staged files and their directory before atomically replacing `current`, then fsyncs the
output directory again. `published_paths()` resolves `current` once, so its returned database/report
paths are a single generation snapshot even if another build publishes concurrently. A successful
publish retains at most the current generation and one recent prior staged generation; older stages
are retired best-effort only after the pointer is durable. The publication test injects report absence,
post-report, and pre-pointer-swap failures; each proves the previous catalog/report pair remains
visible.

## Validation facts for the 2026-08-24 run

The compact evidence record is `FoodDataSource/FoodCatalogGenerationEvidence.json`. Its local
schema-v3 artifact contained 66,581 foods: 5,432 Survey, 7,793 SR Legacy, 469 Foundation, 50,000
curated branded, and 2,887 CoFID. It preserved 1,745,863 food nutrient values, 86,682 portions,
18,584 FNDDS relations, and 275,535 dated FNDDS ingredient-nutrient values. Integrity was `ok`,
foreign-key violations were zero, and `brand_source:costco*`/`ingredient_text:molasses*` returned
21/8 rows. It is retained only as historical evidence: Task 1 raised the tooling schema to v4, so it
must not be run through the current validator or represented as a current build.

The prior Survey JSON has 22,194 parent-scoped portion occurrences. All semantic fields match the
current FDC rows, but 148 occurrences associate four reused legacy portion IDs with sibling food
parents. This is recorded drift, not an instruction to rewrite authoritative FDC parentage. The
fixture also has 550 expected three-significant-digit amount representations and 3,544 JSON
floating-point ingredient-weight tails; comparisons canonicalize those representations while the
FDC CSV text remains unchanged.

The artifact is 449,552,384 bytes (428.73 MiB), versus the current 59,748,352-byte (56.98 MiB)
shipping catalog: 389,804,032 bytes larger, or 7.52 times its size, despite containing 51,736 fewer
foods because it preserves rich nutrient/provenance history. The current base plus approximately
364,457 ODR foods is 482,774 rows; replacing only the base would be 431,038 rows, but would not solve
the 371.75-MiB bundled-size increase. Do not bundle this preservation database. A later design must
produce a measured compact runtime projection and decide whether rich tables belong in ODR or stay
generator-only. Existing candidate-cap arithmetic remains 10,000 for base retrieval and 600 for the
ODR source; adding brand/ingredient FTS must not weaken prefix-AND gating before either cap.

## Future product decision (not implemented)

The preservation database intentionally stores all FDC Branded records matching the fixed GTIN
allowlist and does not choose a current record when FDC has duplicates. A future owner-approved
runtime projection could define a dated selection rule (for example, a source-status and modified-date
policy), measured compact storage budget, refresh cadence, and deprecation behavior. That work must
leave the 50,000-GTIN allowlist, one-to-one shipping UUID map, the listed legacy exception, and raw
record history unchanged; it is a projection decision, not a source rewrite.

## Tests and corrective workflow

Run the fast source-contract suite and validator first:

```sh
PYTHONPYCACHEPREFIX=/tmp/fernlet-food-pycache \
  python3 -m unittest discover -s Scripts/food-catalog/tests -v
python3 Scripts/food-catalog/validate_catalog.py \
  --manifest FoodDataSource/FoodCatalogSourceManifest.json \
  --catalog .food-catalog-build/current/FoodCatalog.sqlite \
  --evidence .food-catalog-build/current/validation-report.json \
  --committed-catalog FernletKit/Sources/FoodCatalog/Resources/FoodCatalog.sqlite
```

The checked local artifact is schema v3 and intentionally does not satisfy the current v4 manifest;
do not run the validator against it. Task 4's schema-v4 build was reproduced only in isolated
temporary output roots, leaving this historical artifact untouched and uncommitted.

For a schema-compatible artifact, validation is exact: it checks table/source/status/basis counts,
the full GTIN-to-shipping-UUID map, FNDDS raw numeric reconciliation, the named Survey legacy
portion-parent drift topology, raw-record content hashes, and equality of FTS row IDs to food IDs.
Passing `--evidence` additionally checks the evidence file's manifest and input-hash contract.

Then run the existing FoodCatalog and corpus tests against the **committed** catalog, followed by the
Power-of-10 scanner and SPM wall. This data-only phase does not authorize pointing runtime tests at
the generated schema. Therefore runtime corpus flips must remain zero; any future compact-catalog
adoption needs a separately reviewed, query-by-query corpus remeasurement.

Expected fail-closed conditions include hash/size/header/count drift, an unexpected FDC type, FNDDS
relation mismatch, missing nutrient date windows, a new CoFID sentinel or duplicate code, duplicate
stable identity, integrity/foreign-key failure, and empty FTS field probes. Inspect the exact source
release and update the manifest/adapters deliberately; never loosen counts, substitute another
archive, round an authoritative value, or deduplicate by name merely to make a run pass. For CNF or
NEVO, stop until the deferred license/adapter decision is documented in the manifest and approved.

Before handing off, prove the committed catalog hash is unchanged and only the committed catalog is
tracked:

```sh
shasum -a 256 FernletKit/Sources/FoodCatalog/Resources/FoodCatalog.sqlite
git ls-files '*.sqlite'
git status --short --ignored
```
