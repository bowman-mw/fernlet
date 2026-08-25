# Food catalog remaining plan — 2026-08-24

This is the canonical execution plan for food-catalog work remaining after items 9–11. It
supersedes older ordering and source recommendations where they conflict. It is a plan only: no
runtime implementation or generated catalog is authorized by this document.

## Settled owner decisions

- **Sources:** keep the present scope: FDC Survey, SR Legacy, Foundation, exactly 50,000 selected
  branded products, the FNDDS Ingredients workbook, and CoFID. Do not add another source in this
  round. CNF is rejected. NEVO remains excluded without written transformed-redistribution
  permission. Never ingest the full FDC branded set, experimental foods, samples, subsamples, or
  acquisition records.
- **Branded selection:** retain the current 50,000-product selection for now, including the
  one-to-one existing shipping UUID mapping. Preserve every matching raw FDC record when a GTIN has
  duplicates; a future runtime projection may adopt an owner-approved, dated selection policy, but
  may not widen the allowlist or rewrite the raw record history. A significant redesign remains a
  separate owner decision, not an invitation for the generator to widen implicitly.
- **Tooling before runtime:** item 13's generator, validation, provenance, evidence, and destructive
  fixtures must be reviewed and committed before item 12 or catalog runtime integration proceeds.
  Raw archives and generated SQLite artifacts remain local and ignored.
- **Units:** support deterministic physical conversions and source-backed portions. Mass and volume
  conversions must change quantity and nutrition scale together through one shared result. Count
  units require an exact serving basis or a unique source portion with gram evidence; grams never
  become slices, pieces, or items by assumption.
- **Household defaults:** Fernlet may define a small, explicit vocabulary of editable defaults. The
  first approved default is `glass = 12 US fluid ounces` (354.882 mL), never 12 mass ounces. It may
  bridge to a gram-based food only through source-backed density or a gram-equivalent portion. Bowl,
  plate, handful, serving, meal, stick, and sandwich remain unsupported until individually specified.
- **Attribution and sentinels:** add a Data Sources surface before shipping an attribution-bearing
  source. Preserve CoFID `Tr`, `N`, and blank distinctly; none is numeric zero.

## Measured size baseline and unresolved delivery decision

| Artifact | Bytes | MiB | Meaning |
| --- | ---: | ---: | --- |
| Current shipped base catalog | 59,748,352 | 57.0 | The fresh-clone/runtime baseline |
| Existing optional branded ODR experiment | 177,901,568 | 169.7 | Prior delivery-size benchmark; not the item-13 preservation DB |
| Item-13 local preservation artifact | 449,552,384 | 428.7 | Rich, ignored experimental output; not approved for runtime use |

The preservation artifact is 7.52 times the shipped base and, by itself, 1.89 times the prior base
plus ODR files combined. Do not set a speculative runtime ceiling yet. First define and measure a
compact projection containing only runtime-required columns and indexes. Present at least two
feature/size options, with installed bytes, cold-launch/open cost, query latency, and ODR behavior,
for owner selection. Until then, the 59,748,352-byte shipped base is the non-regression baseline and
the preservation database remains generator/research-only. Whether the compact projection is a
separate database is still an owner gate; separation is the recommended architecture because it
keeps raw provenance and generator-only evidence out of the app payload.

## Personalized ingredient preference — item 9d

The intended behavior is: after a person logs `basmati rice`, a later generic ingredient phrase
`rice` may resolve to that same catalog food. This extends item 9's derived recency/frequency history;
it must not create a second persisted preference ledger.

Precedence is fixed:

1. explicit wording in the current meal (`brown rice`, a brand, preparation, or other qualifier);
2. an explicit saved correction for the same phrase;
3. one clear, compatible recently used specialization;
4. normal cold ranking and review/fallback behavior.

Apply personalization only to the complete extracted ingredient phrase, never to arbitrary resolver
subphrases. The historical row must already pass retrieval, name-carriage, score, source/type, and
food-form compatibility gates. It may re-rank an admitted row but may not inject an unrelated food,
manufacture bind confidence, bypass review, or alter quantity/unit conversion. A generic phrase may
inherit a specialization only when one candidate has a clear bounded recency/frequency lead. If the
person recently logged competing variants (for example basmati and jasmine rice) without a sufficient
lead, retain cold ranking or request review instead of guessing. User-created foods participate when
they have a stable food ID. Wiping meal history immediately removes the preference because the signal
is derived from the existing bounded recent-meal window.

Required examples include:

- `basmati rice` followed several days later by `rice` prefers the same basmati food;
- later explicit `brown rice` does not inherit basmati;
- recent basmati does not change `rice pudding`, `rice noodles`, or the `rice` fragment of a larger
  dish decomposition;
- equally plausible recent basmati and jasmine histories do not silently choose by UUID/source order;
- a preference changes identity ranking only: the selected portion and nutrition still go through
  item 11/item 12's safe conversion result;
- machine-generated whole-ingredient resolution receives only this narrow rule; item 9's broad
  history tier remains excluded from arbitrary machine-generated fragments.

Implement item 9d after item 17 score-first ranking and before bind-score recalibration, so the final
personalized ordering is measured once. Its automatic-assumption margin must be derived from a labeled
test bank rather than chosen by intuition.

## Dependency-ordered work

1. **Harden item 13 tooling.** Enrich the 50,000 GTIN allowlist from the full pinned FDC CSV;
   preserve FDC/raw/ingredient/market/subbrand/date fields and GTIN-to-shipping-UUID mappings; add
   exact counts and consistency/hash/FTS/compatibility checks; pin FNDDS legacy drift; preserve CoFID
   basis and sentinel semantics; bound every input/buffer/string class; record provenance and branded
   derivation; and reconcile FNDDS dish/category fields and raw numeric text. Document explicitly
   that this Python generator is outside the Swift Power-of-10 scanner; its bounds are enforced by
   generator validation, fixtures, and review rather than by claiming Swift scanner coverage.
2. **Make publication transactional.** Validate the staged database and its staged, cross-hashed
   report before atomically publishing a complete generation. Failure leaves prior output unchanged.
3. **Run the later reproducibility proof.** Two runs from identical pinned inputs must produce the
   same normalized content, counts, mappings, manifest, and evidence. This is the first phase allowed
   to regenerate the local artifact.
4. **Review and commit tooling only.** Commit scripts, tests, manifests, evidence schema, provenance,
   and small destructive fixtures. Keep raw inputs, scratch data, and generated databases ignored;
   prove the shipping catalog hash is unchanged.
5. **Implement item 12.** Add the approved mass/volume/count policy, source-backed portions, the
   12-US-fl-oz glass default, editable assumption provenance, and explicit failure. Preserve item 11's
   true-basis/no-grams-as-count behavior.
6. **Implement item 17 score-first ranking.** Re-measure every search and resolver surface.
7. **Implement item 9d personalized ingredient preference.** Use the bounded, derived recent-meal
   signal and the precedence/ambiguity contract above.
8. **Recalibrate `confidentBindScore`.** Calibrate after items 17 and 9d against a predeclared corpus,
   emphasizing false-confident personalized and cold matches.
9. **Complete item 16 partial matching last.** Item 14's persisted bind score and item 15's explicit
   web consent are implemented; keep the AND gate, scorer parity, and review-confidence guarantees
   intact when adding the bounded fallback.
10. **Design the compact runtime/ODR projection.** Present measured options before changing the
    shipping catalog or ODR configuration.
11. **Consider future food-item improvements** only through the prioritization below; no new data
    source is implied.

## Food-item improvements worth carrying in the redesign

These improve correctness without expanding the approved source list. They are candidates for the
projection/data-contract design, not authorization to implement all of them now.

| Priority | Improvement | Why it matters | Planning gate |
| --- | --- | --- | --- |
| P0 | Preparation/form facets | Preserve and normalize raw/cooked, dry/prepared, drained, skin-on/off, salted/unsalted, and frozen states so ranking cannot silently substitute a nutritionally different form | Define source-specific vocabulary; raw text remains authoritative |
| P0 | Portion provenance and confidence | Every derived household measure records whether it came from exact food basis, source portion, density bridge, or Fernlet default | Item 12 shared conversion result; editable assumptions |
| P0 | Cross-source identity/duplicate graph | Keep source rows intact while grouping true equivalents and mapping replacements/GTINs | Never merge nutrients across rows merely because names resemble each other |
| P1 | Nutrient completeness/quality metadata | Expose which values are analytical, label-declared, imputed, trace, unknown, or missing and avoid treating sparse foods as complete | Source-specific status mapping; no synthetic zero |
| P1 | Source version and freshness | Carry publisher, release, source date, market dates, and supersession state into diagnostics and the Data Sources UI | Deterministic stale/replacement rules |
| P1 | Searchable ingredient text with safeguards | Full branded ingredients improve product discovery and allergen review | Separate ingredient FTS field, bounded text, no medical absence claim from missing text |
| P1 | User-specific serving presets | Remember an explicitly edited usual quantity for a stable food ID, separately from catalog truth | New persisted-surface/privacy/wipe decision required; do not conflate with item 9d |
| P2 | Localized aliases and regional display names | Improve recognition without duplicating or translating nutrient rows | Frozen source IDs; locale-specific display/search layer; provenance retained |

## Verification matrix

| Phase | Positive proof | Negative/destructive proof |
| --- | --- | --- |
| Item 13 fixtures | Exact selection/enrichment, raw retention, all exact counts, source consistency, FNDDS/CoFID semantics | Missing/extra GTIN, duplicate/mispointed UUID, drift, sentinel coercion, oversized input, altered manifest/evidence all fail |
| Item 13 generation | Integrity/FKs, exact FTS row-ID equality, compatibility coverage, cross-bound hashes, two-run equivalence | Any staged generation/report failure preserves the prior published pair byte-for-byte |
| Item 13 commit | Only tools/docs/small fixtures tracked; shipping catalog hash remains fixed | No archive, scratch file, generated SQLite, or runtime change enters the commit |
| Item 12 | Exact basis, physical conversions, unique portions, 12-US-fl-oz glass, shared macro/micro/calorie scale | Grams-as-count, mass-ounce/fluid-ounce confusion, unsupported container, ambiguity, nonfinite/overflow, and missing density fail closed |
| Item 17 | Score-first behavior pinned across search/resolver/corpus surfaces | Excluded types, unbounded candidate changes, and false-confident regressions fail |
| Item 9d | Basmati-to-generic-rice and other labeled specialization cases; deterministic recency/frequency lead | Explicit qualifier conflict, competing history, subphrase contamination, injected row, confidence bypass, or history-wipe survival fail |
| Calibration/item 14 | Predeclared threshold evidence; old/new snapshot decode and round trip | False-confident ceiling, invalid score, migration, or sync failures block release |
| Items 15/16 | Consent/revocation/no-egress; bounded zero-AND partial fallback | Pre-consent egress, post-revocation egress, broad-term explosion, or scorer/gate mismatch fail |
| Runtime projection | Approved bytes, latency, exact branded cap, mappings, attribution, attach/detach and ODR behavior | Full branded ingestion, over-budget output, missing attribution, or preservation-only data in runtime blocks publication |

## Remaining owner gates

Only two catalog architecture choices remain open:

1. choose among measured compact-projection size/features options after they exist; and
2. confirm whether the compact runtime projection is a separate database from the preservation
   database (recommended: yes).
