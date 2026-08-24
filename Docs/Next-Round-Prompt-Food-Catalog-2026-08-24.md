# Continuation prompt — food catalog implementation (2026-08-24)

Paste the block below into a fresh Codex task opened at
`/Users/michaelbowman/Desktop/Fernlet 5-18/Fernlet`.

---

## Prompt to paste

Continue Fernlet's food-catalog work as a strictly sequential implementation round. Work on only one
numbered task at a time. Preserve all unrelated and uncommitted work.

### Mandatory usage checkpoint

After **every numbered task** is fully implemented, reviewed, and verified:

1. summarize the outcome, files changed, tests run, commit state, and remaining risks;
2. stop before opening or editing files for the next task;
3. ask exactly: **“What is the current usage level?”**; and
4. wait until I report the current usage level and explicitly tell you to continue.

Do not infer usage, read it from unrelated counters, or claim you can see account usage. If I say
`continue` without reporting usage, ask for the usage level again. Do not pre-dispatch, parallelize,
or begin the next task while waiting. A task is not complete merely because code was written: its
required positive and negative verification must finish first. If a task is blocked, report the
blocker and stop; do not skip ahead.

### 0. Orient without changing anything

Read these files completely before implementation:

- `AGENTS.md`
- `Docs/FileIndex.md`
- `Docs/Round-2026-08-22-Progress.md`
- `Docs/Food-Search-And-Community-Database-Research-2026-08-22.md`
- `Docs/Food-Catalog-Remaining-Plan-2026-08-24.md`

Then inspect, read-only:

```sh
cd "/Users/michaelbowman/Desktop/Fernlet 5-18/Fernlet"
git status --short
git worktree list
git log --oneline -5
git -C ../fernlet-wt-food status --short
git -C ../fernlet-wt-food log --oneline -12
```

The food implementation branch is `claude/food-search-2026-08-22` in `../fernlet-wt-food`; items
9–11 are committed there through item 11 commit `dcee2ec`. Item 13 has an uncommitted experimental
tooling draft and a local ignored artifact in that worktree. The main worktree also contains approved
documentation edits. Treat all of those changes as owner work: do not clean, reset, overwrite, move,
or casually reformat them. Re-resolve current paths and hashes instead of trusting stale line numbers.
If the observed topology materially differs, stop and report it.

Setup is not a numbered task and does not trigger the usage checkpoint. Do not edit during setup.

### Binding scope and decisions

- Current sources only: FDC Survey, SR Legacy, Foundation, exactly 50,000 selected branded products,
  FNDDS Ingredients, and CoFID. CNF is rejected. NEVO and all additional sources are excluded.
- Never ingest the full FDC branded set, experimental foods, samples, subsamples, or acquisition
  records.
- The FNDDS Ingredients workbook is authoritative for exactly 18,584 ingredient relations and
  moisture metadata, not portions.
- CoFID remains source-namespaced. Preserve each food's 100 g versus 100 mL basis and distinguish
  numeric, parenthesized numeric, `Tr`, `N`, and blank.
- Raw archives, generated SQLite databases, scratch outputs, and local reproducibility artifacts stay
  ignored and uncommitted. The shipped `FernletKit/Sources/FoodCatalog/Resources/FoodCatalog.sqlite`
  must remain byte-identical until a later owner-approved runtime projection task.
- Do not download data or add a network destination. Use only the pinned local inputs already placed
  in scope. If any required input is absent or its hash differs, stop and ask rather than substituting.
- No runtime integration during item 13. Commit hardened tooling before item 12 runtime work.
- Preserve item 11's serving rule: use the food's true serving basis; unsupported or ambiguous units
  fail closed; grams never silently become a slice, piece, item, or serving.
- The approved household default is `glass = 12 US fl oz = 354.882 mL`, explicitly marked as an
  editable assumption. It is never 12 mass ounces and never bridges to grams without density or
  source gram evidence.
- The item 9d ingredient preference is derived from existing bounded meal history. Add no preference
  store. Explicit wording and saved corrections outrank inferred history.
- The rich 449,552,384-byte preservation database is not approved as a runtime database. Runtime/ODR
  design waits for measured compact-projection options and owner choice.

### General implementation discipline

- Use `rg`/`rg --files` first. Read the relevant function indexes before touching persistence or
  proximity code. Preserve the S3 module wall and all privacy/no-tracking boundaries.
- Use `apply_patch` for edits. Never use destructive git commands. Never discard or rewrite existing
  uncommitted work to make a patch easier.
- Keep every shipping Swift change within `Docs/Power-of-10-Swift.md`: no recursion, bounded loops and
  growth, at most 60 code lines per function/`body`, guard validation, no silent traps, no mutable
  globals, no swallowed `try?`, and warnings as errors.
- The Python catalog generator is outside the Swift Power-of-10 scanner. Do not claim scanner
  coverage. Enforce its bounds with explicit validation, tests, review, and documented limits.
- Add no package dependency, outbound destination, raw-data source, schema token, or persisted surface
  unless the active task and owner decisions explicitly authorize it.
- For each task, inspect first, implement the smallest coherent change, run focused tests, run adjacent
  regressions proportional to risk, inspect the final diff, and update the progress ledger. Commit only
  when that task says to commit and the tracked-file set is exact.
- Swift verification uses the AGENTS commands with the named iPhone 17 simulator. Run
  `Scripts/power-of-10-scan.py` and `Scripts/spm-wall-check.sh` for every Swift task. Use a clean build
  for `FernletDomainModel`, enum, or snapshot changes. Never trust a green banner without the command's
  exit code and executed-test count.

## Task 1 — Complete source fidelity and branded enrichment

Work only in the food worktree's item-13 Python tooling and small fixtures. Do not regenerate the full
catalog.

- Use GTIN as the exact 50,000-product selection allowlist, then enrich each selected product from the
  pinned full FDC CSV.
- Preserve FDC ID, GTIN, raw nutrient/source values, ingredients, brand owner/source, market country,
  subbrand, publication/modified/available/discontinued dates, and every other approved raw field.
- Emit explicit, deterministic GTIN → existing shipping UUID compatibility mappings. Prove one-to-one
  coverage, no duplicate GTIN or UUID target, and no selected/unselected leakage.
- Expand FNDDS reconciliation/preservation to dish and WWEIA category fields plus raw numeric text.
  Keep the workbook authoritative only for its 18,584 relations and moisture metadata.
- Preserve CoFID's per-food 100 g/100 mL basis and raw numeric/parenthesized/`Tr`/`N`/blank semantics.
- Record reproducible provenance: canonical URLs, release/version, retrieval date, repack steps,
  archive/member hashes, and the full curated-branded derivation chain.

Verify with small positive and negative fixtures. Do not commit yet if the existing draft is intended
to remain one cohesive item-13 commit. Update the ledger with exact status, then perform the mandatory
usage checkpoint.

## Task 2 — Make validation exact and destructive

Do not regenerate the full catalog.

- Enforce exact counts by source, table, food status, nutrient status, and nutrient basis.
- Enforce food/source/table consistency, complete compatibility mappings, manifest/evidence/input
  hashes, and exact FTS row-ID equality—not merely row counts or positive probes.
- Pin and fail closed on the exact known FNDDS legacy portion-ID drift topology. A change in the set,
  parent mapping, multiplicity, or expected reconciliation must fail by name.
- Add destructive fixtures that independently mutate or remove GTINs, FDC IDs, UUID mappings, source
  fields, raw numeric text, CoFID basis/sentinels, FNDDS topology, manifest/evidence hashes, FTS rows,
  and table counts. Each must prove the validator goes red for the intended reason.

Run the complete Python unit suite and validator against small fixtures only. Update the ledger, then
perform the mandatory usage checkpoint.

## Task 3 — Bound inputs and make publication transactional

Do not regenerate the full catalog.

- Add explicit limits for manifest/evidence files, source files, ZIP member count and individual/total
  expansion, compression ratio, records, columns/cells, shared strings, cell/string length, JSON
  object size, SQL batch/buffer growth, foods, nutrients, portions, and ingredient relations.
- Validate every size before allocation/append when possible and fail with a specific diagnostic.
- Generate a database and report in staging. Validate integrity, foreign keys, exact contracts, and
  cross-bound hashes while staged. Only then atomically publish a complete generation.
- Add failure-injection tests proving a generation or report failure leaves the previous published
  database/report pair byte-for-byte unchanged and exposes no mismatched pair.
- Update the tooling README accurately: the Python generator is outside the Swift scanner, inputs are
  bounded by the Python contract, and publication/rollback behavior is explicit.

Run all Python tests, the small-fixture validator, and `git diff --check`. Update the ledger, then
perform the mandatory usage checkpoint.

## Task 4 — Run the full local reproducibility proof

This is the first task allowed to regenerate catalogs. Use only the already-pinned local inputs; do
not download or substitute anything.

- Preserve the current ignored output until the staged replacement has passed.
- Run two clean generations from the same pinned inputs into separate temporary generation roots.
- Compare normalized database content, schema/user version, exact tables/source/status/basis counts,
  FTS row IDs, compatibility mappings, manifests, evidence, and output/report hashes. Explain any
  intentionally nondeterministic metadata; preferably remove it from content identity.
- Run the destructive publication failure proof against a copy/staged fixture, never against the only
  recoverable output.
- Confirm the shipped catalog hash is unchanged and every generated/raw artifact remains ignored.

Do not commit generated outputs. Update the ledger with commands, exit codes, counts, sizes, and hashes,
then perform the mandatory usage checkpoint.

## Task 5 — Review and commit item 13 tooling

Review the entire item-13 diff adversarially against all eight findings and the canonical verification
matrix. Fix confirmed defects and repeat the required tests. Confirm the tracked set contains only
tooling, tests, manifests/evidence schema or small evidence records, provenance documentation, small
fixtures, and approved plan/ledger updates. It must contain no raw archive, generated SQLite, scratch
output, shipping-catalog change, runtime reader/search/model change, or unrelated owner work.

Commit the coherent item-13 tooling increment with a message naming item 13. Report the commit SHA and
working-tree residue precisely. Then perform the mandatory usage checkpoint.

## Task 6 — Implement item 12 safe household conversion

Read the authoritative item-12 brief in the progress ledger before editing Swift.

- Implement one shared explicit conversion result for component quantity/unit/provenance and every
  macro, micronutrient, and calorie consumer.
- Support mass `mg`/`g`/`kg`/`oz`/`lb` and volume `mL`/`L`/`tsp`/`tbsp`/`cup`/US `fl oz` within their
  dimensions. Volume-to-mass requires source density or gram-equivalent evidence.
- Support `each`/item/piece/slice only by exact serving basis or one uniquely eligible source portion.
- Add the editable, visibly sourced 12-US-fl-oz glass default. Keep other container words unsupported.
- Replace silent identity fallback with explicit failure/review/fallthrough. Preserve item 11's real
  French-toast and breakfast-pizza end-to-end behavior and fix the ramen overcount class.

Run focused conversion/probe/catalog/MealBuilder tests, adjacent corpus tests, clean build, Power-of-10
scan, and strict S3 wall. Commit the coherent item-12 increment, update the ledger, then perform the
mandatory usage checkpoint.

## Task 7 — Implement item 17 score-first ranking

Treat this as a product-wide comparator change. Pre-register the expected corpus/resolver/search-bank
outcomes before altering the comparator. Implement the smallest measured score-first policy, retain
source/type safety constraints, and review every query surface. Do not recalibrate
`confidentBindScore` in this task.

Run all search, resolver, correction, history, whole-description, corpus, and boundary suites plus the
strict build/scanners. Commit, update the ledger with before/after measurements, then perform the
mandatory usage checkpoint.

## Task 8 — Implement item 9d recent ingredient specialization

Reuse the existing bounded `recentMeals`-derived history; add no new persisted store.

Precedence is explicit current wording → saved correction → one clear compatible recent
specialization → cold ranking/review. Apply the rule only to the complete extracted ingredient phrase,
never arbitrary resolver fragments. It may re-rank a row that passed retrieval/name/score/form gates;
it may not inject, mint confidence, bypass review, or change unit conversion.

Pin at least: basmati then generic rice; explicit brown rice veto; rice pudding/noodle/dish-fragment
non-contamination; basmati/jasmine ambiguity; user-created stable IDs; wipe removal; and item-12
portion/nutrition independence. Derive the clear-lead margin from a labeled bank rather than intuition.

Run the full ranking/resolver/corpus/history/correction/probe matrix and strict build/scanners. Commit,
update the ledger, then perform the mandatory usage checkpoint.

## Task 9 — Recalibrate `confidentBindScore`

Calibrate once against a predeclared cold and personalized corpus after tasks 7–8. Set an explicit
false-confident ceiling, include ambiguous-history cases, and publish the before/after evidence in
tests and the ledger. Do not add item-14 persistence yet.

Run the full search/resolver/ranking/history/correction/probe matrix, clean build, and walls. Commit the
measured calibration increment, update the ledger, then perform the mandatory usage checkpoint.

## Task 10 — Implement item 14 persisted bind score

Add the per-component bind score with tolerant old/new decoding, finite/range checks, round-trip, sync,
migration, and wipe/privacy disposition as required. Do not hide an absent or invalid score behind a
default that makes it confident, and do not change the calibrated ranking semantics in this task.

Run migration/snapshot/sync plus the full search/resolver matrix, clean build, and walls. Commit,
update the ledger, then perform the mandatory usage checkpoint.

## Task 11 — Implement item 15 explicit web-search consent

Specify and implement explicit first-use consent, what data leaves, destination disclosure, rejection,
revocation, disabled/offline behavior, and an audit record. Prove zero egress before consent and after
revocation. Add no new destination; this task governs the already-approved lane only.

Run focused privacy/network/audit/UI tests, localization checks, full relevant walls, and a build.
Commit, update the ledger, then perform the mandatory usage checkpoint.

## Task 12 — Implement item 16 partial matching last

Activate partial matching only when the normal AND gate returns zero. Keep query variants, candidate
growth, time, memory, and result counts explicitly bounded. Preserve scorer/gate parity and review
confidence. Pre-register broad/common-term adversarial cases so the fallback cannot become the normal
path or swamp exact matches.

Run the full corpus, resolver, ranking, history, correction, confidence, and performance-bound matrix
plus strict build/scanners. Commit, update the ledger, then perform the mandatory usage checkpoint.

## Task 13 — Produce compact runtime/ODR options; do not integrate

Design and measure at least two projections of the validated preservation catalog. Include installed
bytes, compressed/download bytes where measurable, schema/index contents, query latency, cold open,
memory, exact 50,000 branded cap, compatibility mapping, attribution, source/form/portion provenance,
and ODR attach/detach/purge behavior.

Carry the P0 redesign fields: preparation/form facets, portion provenance/confidence, and cross-source
identity groups. Assess P1/P2 fields separately so their byte cost is visible. Do not change the shipped
catalog, Xcode resource membership, ODR tags, or runtime loader. Present the options with a recommendation
and explicitly ask the owner to choose the size/features envelope and whether runtime remains a separate
database from preservation.

Update the ledger and plan with measured results, then perform the mandatory usage checkpoint. Stop
after the checkpoint. Runtime projection/integration is a new owner-authorized task, not implicit scope.

### Final completion rule

Never collapse multiple numbered tasks into one turn, even if a later task looks small. The mandatory
usage checkpoint is part of each task's acceptance criteria. There is no authorization to proceed past
Task 13 or to integrate a generated runtime catalog without a new owner decision.
