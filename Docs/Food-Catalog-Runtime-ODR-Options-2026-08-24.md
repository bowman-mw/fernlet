# Food Catalog Runtime / ODR Options — 2026-08-24

> **STATUS: OPEN — awaiting the owner. Raised 2026-08-24; still open at the 2026-08-27
> documentation/test/review pass, which sharpened the questions below without answering any of
> them.**
>
> **What is blocked while it stays open.** Item 10 of
> [Food-Catalog-Remaining-Plan-2026-08-24.md](Food-Catalog-Remaining-Plan-2026-08-24.md) — "design
> the compact runtime/ODR projection" — cannot start, because the projection's contents *are* the
> answer to questions 2 and 3 below. Nothing else in the food-catalog track is blocked: search
> quality, the review gate, and the match floor all work against the shipped base.
>
> **What is NOT blocked, and must not wait for this.** The 59,748,352-byte shipped base stays the
> non-regression baseline either way. No change to the shipped SQLite, its Xcode resource
> membership, the ODR tags, or `BrandedCatalogResourceLoader` is authorized by this document.
>
> **If it is never answered**, the app keeps shipping Option A (current base + optional branded
> ODR) indefinitely. That is a real, working configuration — the cost of not deciding is the
> missing P0 fields listed under Option C, not a broken build.

## Decision requested

Choose the runtime size/features envelope, and explicitly decide whether the runtime catalog remains a
separate projection from the validated preservation database. The recommendation is **yes: keep two
databases** — a compact, purpose-built runtime projection and an offline preservation database. This is a
design-and-measurement record only; it does not change the shipped SQLite, Xcode resource membership, ODR
tags, or `BrandedCatalogResourceLoader`.

## Measured reference artifacts

Measurements were taken locally with `stat -f %z`, `gzip -9`, and read-only SQLite queries on 2026-08-24.
Gzip is a transport-size proxy, not an App Thinning or TestFlight download measurement.

| Artifact | Installed bytes | `gzip -9` bytes | Food rows | Branded / GTIN rows | Portions | Runtime role today |
|---|---:|---:|---:|---:|---:|---|
| Shipped `FoodCatalog.sqlite` | 59,748,352 (56.98 MiB) | 17,348,111 (16.54 MiB) | 118,317 | 109,163 / 50,000 | 7,985 | Base bundle |
| Existing `ODRAssets/FoodCatalogBranded.sqlite` | 177,901,568 (169.66 MiB) | 58,100,489 (55.41 MiB) | 364,457 | 364,457 / 364,457 | 0 | Optional branded ODR |
| Historical schema-v3 preservation artifact | 449,552,384 (428.73 MiB) | Not retained, so not measured | 66,581 | 50,000 curated compatibility rows | 86,682 | Offline validation only |

The installed base + existing branded ODR pair is 237,649,920 bytes (226.64 MiB); its combined gzip proxy
is 75,448,600 bytes (71.95 MiB). The preservation artifact is historical schema-v3 evidence, whereas the
current reproducibility tooling is schema-v4; it must be regenerated and revalidated before it can support
any new projection.

The shipped base and the ODR artifact both contain the same runtime shape: `food`, indexes on id,
normalized name, and GTIN, plus a contentless `food_fts` FTS5 index (`name`, `category`, `tags`). A direct
cold-process `chicken*` FTS query resolved in the shell's 0.00 s / 0.01 s reporting granularity for base /
ODR respectively. This is not an app cold-open or memory measurement: those must be captured on a release
device before an envelope is accepted.

## Projection options

| Option | What installs / downloads | P0 data | P1/P2 data | ODR lifecycle | Assessment |
|---|---|---|---|---|---|
| A. Keep current base + branded ODR | Measured 56.98 MiB base; optional 169.66 MiB ODR; 226.64 MiB together | Does **not** carry explicit form facets, source-portion confidence, or cross-source identity groups. It has 50,000 GTIN rows in base but not an explicit compatibility table. | Present only in the current lossy runtime shape; no separately attributable size. | Existing loader attaches a secondary source, falls back to base/user foods while unavailable, and `purge` ends ODR access. | Lowest implementation risk, but insufficient for the redesign. |
| B. Use preservation as runtime | Measured 428.73 MiB installed; no retained compressed measurement | Raw source/portion provenance is available in the archival shape and the 50,000 curated compatibility mappings are preserved. | Includes 1,745,863 nutrient values, 18,584 FNDDS relations, and 275,535 FNDDS ingredient-nutrient rows. | Static bundle only; no existing attach/detach/purge behavior. | Reject: larger than base + ODR combined, archival schema, and it would couple app UX to validation storage. |
| C. Generate a dedicated P0 runtime projection (**recommended**) | Not yet measurable: regenerate the current validated v4 artifact, then build and measure the projection before approval. | A compact `food`/FTS read model; exact 50,000-row `branded_compatibility`; source attribution; form/preparation facets; selected raw portion, raw amount/unit/description, gram bridge, and provenance/confidence; cross-source identity groups + membership. | P1 and P2 remain separately selectable tables/ODR projections, never silently included in the base. | Retain the existing secondary-source pattern only after owner authorization; a branded/P1 ODR can attach, detach, and purge without making the base unavailable. | Meets product needs while keeping the preservation contract independently verifiable. |

### P0, P1, and P2 byte visibility

P0 is the minimum product read model listed in Option C. Its byte cost is **unmeasured**, not estimated:
the current runtime database omits several fields and the historical database is the wrong schema. The
projection build must report base bytes, gzip/IPA-thinning bytes, FTS/index bytes, and each table's bytes.

P1 is complete nutrient/portion detail (including the 1,745,863 nutrient-value rows in the historical
artifact). P2 is the survey/ingredient and additional analytic provenance relations (including the 18,584
FNDDS relations and 275,535 ingredient-nutrient rows). Neither is required to answer ordinary runtime food
search. Their incremental bytes are likewise **not yet measured** and must be reported separately rather
than buried in P0. This prevents accepting a size envelope by accidentally shipping archival detail.

## Required acceptance measurements for Option C

1. Rebuild the approved schema-v4 preservation artifact and verify its manifest, attribution, exact
   50,000 compatibility mappings, source/form/portion provenance, and identity groups.
2. Produce P0-only, P0+P1, and P0+P1+P2 projections; report installed bytes, compressed/App-Thinning
   download bytes, table/index/FTS bytes, and query latencies for generic and named-brand searches.
3. Measure release-device cold open and peak memory for base-only, ODR attach, ODR detach, and after a
   system purge. Assert a generic item stays above brands unless a brand is named.
4. Exercise current ODR behavior without changing it: unavailable → base/user fallback; attached →
   secondary results; detached/purged → fallback again; no retained ODR file handles.

## Recommendation and owner choices

Adopt Option C only as a new, owner-authorized runtime-projection task. Keep the preservation database
offline and independently validated; do not turn it into a shipped resource. Preserve the exact 50,000-row
compatibility mapping, attribution, P0 provenance fields, and identity groups in the projection contract.

Please choose. Each question below states what a valid answer looks like and what the anchors are, so
it can be answered from this document alone.

**1. Size envelope.** Two numbers, in MiB of INSTALLED bytes (not the gzip proxy, which is a transport
estimate and not what a device spends):

   - a ceiling for the base P0 projection, and
   - a ceiling for the optional ODR download.

   Anchors, all measured 2026-08-24 and tabulated above: the shipped base is **56.98 MiB**, the existing
   branded ODR is **169.66 MiB**, and the two together are **226.64 MiB**. P0's own byte cost is
   **unmeasured** — deliberately, since the current runtime omits fields P0 needs and the historical
   artifact is the wrong schema — so a ceiling here is a BUDGET the projection must be built to hit, not
   a prediction. "No larger than today" (56.98 / 169.66) is a valid and defensible answer.

**2. P1 and P2.** For each of the two tiers independently, one of: *may ship in an optional ODR
projection*, or *never ships*. Note what the question is not: neither tier may enter the base under any
answer — Option C's contract is that P1/P2 stay separately selectable and are never silently included.

**3. Runtime/preservation separation.** Either *confirmed — two databases* (the recommendation, and the
architecture every option above assumes), or *authorize evaluating a coupled alternative*, which is a
request for more measurement rather than a design change: Option B is already rejected on measured
grounds (428.73 MiB, archival schema, and it would couple app UX to validation storage), so a coupled
alternative would need a fourth option built and measured first.

**Not being asked here, to keep the scope honest:** whether to regenerate the v4 preservation artifact
(that is prerequisite work for any Option C measurement, not a choice), and the P1 "user-specific serving
presets" persisted-surface/privacy/wipe decision, which is its own gate in the remaining-work plan.

## Evidence sources

- `FoodDataSource/FoodCatalogGenerationEvidence.json` — historical preservation counts, bytes, and
  committed-catalog checksum evidence.
- `FernletKit/Sources/FoodCatalog/Resources/FoodCatalog.sqlite` — current shipped runtime artifact.
- `ODRAssets/FoodCatalogBranded.sqlite` and `App/Fernlet/BrandedCatalogResourceLoader.swift` — existing
  optional branded artifact and its attach/detach/purge implementation.
- `Docs/Food-Search-And-Community-Database-Research-2026-08-22.md` — catalog/ODR background and design
  rationale.
