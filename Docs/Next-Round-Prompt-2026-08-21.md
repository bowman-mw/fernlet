# Next round — working prompt (2026-08-21)

Everything below the line is a self-contained prompt. Paste it into a fresh session. It assumes
nothing from the conversation that produced it; every claim carries a `path:line` anchor that was
true on 2026-08-21 and should be re-grepped rather than trusted.

Scope: **the three items deliberately deferred from the 2026-08-20 round and its residuals wave** —
a one-line search-fold correctness fix, the `hubToggle` half of the Settings localization fork, and
the milestone reset-boundary marker. All owner decisions are already made and recorded in
"Decisions locked" below; nothing here requires a product call.

Out of scope, deliberately (do not drift into these): the 61 dynamic search-title catalog keys
(they belong to the deferred per-language search-catalog curation pass in
[`Localization-Plan-2026-07-19.md`](Localization-Plan-2026-07-19.md)); day-record and custom-item
reset mechanisms beyond the dialog-copy disclosure in Part 3 (decided: disclose, don't tombstone);
`SettingsSearchEntry.breadcrumb` localization (rides the same curation pass).

---

Work on Fernlet at `/Users/michaelbowman/Desktop/Fernlet 5-18/Fernlet`. Read `CLAUDE.md` first —
the walls (S3, no-tracking, Power-of-10, localization) are CI-enforced and non-negotiable, and
since 2026-08-21 a fifth wall is live: `Tests/FernletTests/PersistedSurfaceWipeBoundaryTests.swift`
discovers every UserDefaults-backed surface from source and fails unless it has a disposition row.
None of this round's parts should add a persisted key; if one appears, the wall names it — add the
row deliberately, never weaken the wall.

Branch off `main` (currently at the residuals merge `29f2bed`, 17 commits ahead of origin,
unpushed). Line numbers below WILL have drifted — grep for the code, don't seek to the line.

## Ground rules (the expensive lessons of 2026-08-20/21 — do not relearn them)

- **No red from an incremental build is actionable evidence.** Five times in the last round, red
  test runs were stale-artifact phantoms after FernletKit edits — including `as?` narrowing to an
  SPM class returning nil, and the verbatim signature *"expected error of type X, but 'X()' was
  thrown instead"*. The canary set is `SealedPhotoBackupTests` / `SealedBackupPayloadCoverageTests`
  / `RecipeShareCodecTests` / `SensitiveSurfaceGateTests` failing together (5/1/4/3 issues). The
  protocol: **clean build → re-run the failing suite in isolation → only then debug.** Part 3
  changes `FernletDomainModel`, so its first trusted test run REQUIRES a clean build.
- **The first `test-without-building` launch after any rebuild often fails at install/launch**
  ("Missing bundle ID", "runner hung", "failed preflight checks — Busy"). Retry once before reading
  anything into it; `xcrun simctl shutdown all` + boot + `bootstatus` clears the sticky form.
- **Run `Scripts/power-of-10-scan.py` and `Scripts/doc-coverage-scan.py` before every commit** —
  both have zero baselines. New types need `///` doc comments; ≤ 60 code lines per function/`body`;
  no `!`/`try!`/`as!`/`fatalError`; no swallowed `try?`.
- **A `String` parameter silently opts a call site out of localization**; display text is
  `LocalizedStringKey`. Persisted rawValues / ids / a11y identifiers are frozen English forever.
  Run `Scripts/sync-string-catalogs.sh` and commit the catalog diff with any new display string.
- **Strict-build trap**: `Scripts/spm-wall-check.sh` compiles packages standalone with
  MainActor-by-default — an isolated static used as a **default argument** fails there even though
  the Xcode aggregate build accepts it. Immutable constants used as defaults must be `nonisolated`
  (precedent: `HealthKitAnchorKeychain.service`, fixed `a297d0f`).
- **Swift Testing traps**: `#expect` wraps subexpressions in `@Sendable` closures — hoist calls
  taking non-Sendable closures into a `let` first; a test file comparing `LocalizedStringKey`
  literals needs `import SwiftUI`.
- Test in batches (full `FernletTests` is ~10 min); check exit codes and the
  "Test run with N tests … passed" banner, never a naïve grep — and remember XCTest suites print
  `Executed N tests` separately from the Swift Testing banner.
- Several sessions may share this working tree. Commit only your own hunks.

## Decisions locked (owner, 2026-08-21 — do not re-litigate)

1. **Reset-resurrection scope: milestone marker + disclosure for the rest.** Only the milestone
   ledger gets a boundary marker (it is an append-only event ledger, the exact shape the coin
   mechanism was built for). Custom items and day records stay disclose-don't-tombstone; Part 3
   extends the wipe dialog's multi-device caveat to cover them honestly.
2. **`hubToggle` fork is type-only.** Zero copy changes. Any copy concern discovered at the
   sensitive call sites is *reported*, not edited.
3. **Old-build marker semantics accepted.** A not-yet-updated second device drops the unknown
   marker row at decode (the ledger's documented per-row `try?` forward-compat,
   `FernletKit/Sources/FernletDomainModel/MilestoneLedger.swift:35-37`) and keeps its pre-reset
   rows until updated; the NEW build's aggregation voids everything pre-boundary, so resurrection
   is suppressed on the wiped device regardless, and the old device self-heals on update. (Context
   making this easy: the app is unlaunched; multi-device means the owner's own test devices.)

---

## Part 1 — Settings search fold is locale-sensitive (one line + a test)

`App/Fernlet/SettingsSearchIndex.swift:134`: `normalized` folds with
`.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)`. Under a Turkish
locale "Face ID" case-folds to "face ıd" (dotless ı) while a typed "id" folds to "id" — the query
misses. The codebase's own precedents fold locale-independently:
`FernletKit/Sources/FernletDomainModel/FoodItemSearch.swift:176` and
`ItemNameModeration.swift:108` both pass `locale: nil`.

Fix: `locale: .current` → `locale: nil`. Both sides (index tokens and the typed query) normalize
through this one function at runtime, so matching stays self-consistent; en-only behavior is
unchanged. Add a regression test in `Tests/FernletTests/SettingsSearchIndexTests.swift` pinning the
locale-independence property directly (e.g. `normalized` of a dotted-I fixture equals its
locale-nil folding — mirror however FoodItemSearch's fix is pinned, if it is; check before writing).
The suite's existing matching tests (`matchingRunsOnTheFrozenEnglishTokensOnly` etc., added
2026-08-21) must pass untouched.

## Part 2 — `hubToggle` localization fork (type-only, mirrors the shipped `hubLink` fork)

`App/Fernlet/SettingsSheet.swift:521`: `private func hubToggle(_ title: String, isOn:)` still takes
`String`, so its ~11 literal call sites ("Period tracking", "Hide predictions", "Hide fertile
window", "Period-aware care", "Intimacy tracking", "Allow nearby recipe shares", "Share clothing
shops with friends", "Allow nearby hearts", "Deliver hearts when apart", "Nearby friends presence",
"Share your vibe with friends") render English forever with a clean build.

Fix exactly like the `hubLink` fork (`2a4e217`, same file at :264 — read its doc comment first,
including the warning about why a same-label `String` overload must never be added back): the
parameter becomes `LocalizedStringKey`; every call site is a literal, so each compiles unchanged —
**verify each individually**; there is no matching half here (toggles are not search inputs), so no
`SettingsSearchEntry` work. Several labels sit on gated sensitive surfaces (period/intimacy) and
consent-adjacent toggles — decision 2 applies: type-only, copy untouched.

Then: `Scripts/sync-string-catalogs.sh` (the newly-localizable labels become catalog keys; some
already exist as keys from other surfaces — the sync resolves that) and commit the catalog diff in
the same commit. Extend `Tests/FernletTests/LocalizationBoundaryTests.swift` only if it already
pins `hubLink`'s signature (check); otherwise a small pin in `SettingsSearchIndexTests` or a
source-wall asserting `hubToggle(_ title: LocalizedStringKey` is enough to stop regression.

## Part 3 — Milestone reset-boundary marker (the designed one; FernletDomainModel changes)

**The gap.** `MilestoneLedgerService.reset(deletingRowsWith:)`
(`FernletKit/Sources/StoreCore/MilestoneLedgerService.swift:117`, added 2026-08-20) deletes rows
and empties memory but appends nothing — so a second signed-in device that was offline at wipe time
re-syncs its milestone rows into the wiped store, and the dated trail of "a journal entry happened"
resurrects. Coins already solve this: `CoinLedgerService.reset()`
(`FernletKit/Sources/StoreCore/CoinLedgerService.swift:~129`) deletes all rows THEN appends a
reset-boundary marker (`CoinLedgerEntry.reset(dayKey:at:)`,
`FernletKit/Sources/FernletDomainModel/CoinEconomy.swift:85`), and the aggregation voids every
pre-boundary row — "the append-only economy's 'zero the balance'". Mirror that mechanism exactly.

**3a. Domain model** (`FernletKit/Sources/FernletDomainModel/MilestoneLedger.swift`):
- New frozen case `MilestoneEventKind.resetBoundary` (rawValue `resetBoundary`, English forever;
  rawValues are embedded in persisted row ids — `:34` — never rename anything existing).
- A factory mirroring the coin marker's shape (id deterministic per reset, e.g. mirroring how
  `CoinLedgerEntry.reset` builds its id — read it, don't invent), documented as the wipe's
  zero-the-counts row: **never counted, never awarded, voids everything before it.**
- `MilestoneEconomy` aggregation: counts and `missingAwards` consider only rows strictly after the
  latest `resetBoundary` `createdAt` (mirror `CoinEconomy`'s boundary filter — same file, same
  idiom; `:60-61` documents that the merge happens in aggregation, which is exactly why the filter
  belongs there and works on rows that re-sync later). The exactly-once award interaction matters:
  a re-synced pre-boundary event row must neither raise a count NOR let `missingAwards` re-mint a
  `milestone:<kind>:<n>` coin row. The pre-reset-guard tests at
  `Tests/FernletTests/MilestoneLedgerTests.swift:~145-175` describe the current rule — extend, do
  not weaken.
- **Old-build note in the doc comment**, quoting decision 3: unknown kinds are dropped per-row at
  decode on old builds (`:35-37` documents this deliberately), so the marker degrades safely.

**3b. Service** (`FernletKit/Sources/StoreCore/MilestoneLedgerService.swift`): `reset` appends the
marker after the row delete, exactly like `CoinLedgerService.reset()` including its
failed-append-enqueue retry path (`buffer.enqueue` + `scheduleSave`), and keeps threading the
delete verdict back (the funnel's incomplete-store report must not change shape). In-memory state
after reset = `[marker]`, not `[]` — read the coin service line by line and match.

**3c. Dialog disclosure** (`App/Fernlet/DeleteAllDataConfirmation.swift:~127-135`): the
multi-device caveat currently names only "its most recent days". Decision 1: extend it to honestly
cover the disclose-don't-tombstone stores — a device syncing back may also re-add custom clothing
designs; milestone counts now RESIST resurrection (the marker), so do not list them as a survivor.
Keep the paragraph's existing tone and the `hasICloudDayCopy` gate; this is one sentence, not a
rewrite. `DeleteAllDataUITests` pins only "Kept on purpose" presence — verify nothing else pins
this paragraph before editing.

**3d. Tests** (new file `Tests/FernletTests/MilestoneResetBoundaryTests.swift` + surgical extensions):
- A pre-boundary row re-synced after reset (append it to the repository post-reset with an earlier
  `createdAt`) raises no count and re-mints no award after `reconcileMilestones` +
  `reconcileCoinLedger`.
- Post-boundary events count and award normally from zero.
- The marker itself is never counted, never displayed (check `MilestonesView` renders only earned
  kinds — `:~14` "only earned kinds appear" — and that `ExerciseHistory`-style rollups are
  unaffected), and never awarded.
- Decode-drop: an entry JSON with kind `resetBoundary` round-trips on the current build; the
  per-row-`try?` drop behavior for genuinely unknown kinds stays pinned wherever it is pinned today
  (grep before assuming).
- The wipe-funnel behavioral test `DeleteAllDataTests` extension: after `deleteAllData`, the ledger
  holds exactly the marker and `milestoneCounts` are all zero.
- `MilestoneLedgerWipeTests.resetEmptiesTheLedgerAndDropsRowsStillQueued` will need its
  `entries.isEmpty` expectations updated to "exactly the marker" — that is a real semantic change,
  not a test weakened; say so in its comment.

**3e. Wall/doc obligations, same commit**: `Docs/PrivacyWipeCoverage.md`'s milestone cleared-by row
(`:~138`) gains the marker mechanism in its description (the manifest token
`milestoneLedgerService.reset` should not need to change — verify against
`PrivacyWipeCoverageTests` before touching the manifest). The doc's residuals section drops the
milestone sync-back residual and keeps the day/custom-item disclosure. No new UserDefaults keys →
no `PersistedSurfaceWipeBoundaryTests` row. `Docs/RemainingWork-2026-08-20.md`: strike the
follow-ups this round closes, in the same commits that close them.

**3f. Verification order for this part specifically**: clean build FIRST (FernletDomainModel enum
change — the exact hazard class), then owning suites (`MilestoneLedgerTests`,
`MilestoneLedgerWipeTests`, `MilestoneResetBoundaryTests`, `CoinLedgerTests` or nearest,
`DeleteAllDataTests`, `PrivacyWipeCoverageTests`), then the canary four, then the full suite, then
`Scripts/spm-wall-check.sh`.

---

## Definition of done

- Clean build; full `FernletTests` green (clean build first — Part 3 touches `FernletDomainModel`;
  treat the canary-four signature as stale artifacts until proven otherwise per the protocol).
- `Scripts/power-of-10-scan.py` → 0; `Scripts/doc-coverage-scan.py` → 0;
  `Scripts/spm-wall-check.sh` passes; `Scripts/sync-string-catalogs.sh` run and the diff committed
  with Part 2.
- New tests: Part 1's locale pin, Part 2's signature pin, Part 3's boundary suite.
- [`RemainingWork-2026-08-20.md`](RemainingWork-2026-08-20.md) reconciled in the same commits.
