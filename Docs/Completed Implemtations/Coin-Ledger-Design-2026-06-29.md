> **CLOSED 2026-08-09 — SHIPPED.** The append-only ledger design is on `main`: `FernletKit/Sources/StoreCore/CoinLedgerService.swift` + `FernletKit/Sources/CloudKitSync/CoinLedgerRepository.swift` over the shared `AppendOnlyRowStore` engine (the same engine also backs `MilestoneLedgerRepository`). The "derive balance from day history" model this doc replaced is gone. Live tracker: [RemainingWork-2026-07-19.md](../RemainingWork-2026-07-19.md).

# Coin Ledger — Design (Increment 2 redesign)

**Status:** proposed, awaiting sign-off. Supersedes the "derive balance from day history + `coinsSpent`
counter" model that the Increment-2 code review found unsound.
**Branch:** `claude/wonderful-bardeen-1969f6`.

## Why the first model failed (code review, 2026-06-29)

The shipped Increment-2 code derived `earnedCoins = activeDayCount × 5` live from the day history and
stored only `coinsSpent`. The review confirmed that breaks because **the day history shrinks**:

- Disabling HealthKit purges every day's `healthContext` (`CoreDataHealthKitCacheCleaner`), so days that
  were active only via passive health data flip inactive → earned drops.
- Day storage is capped at `FernletLimits.maxStoredDays = 370` and prunes oldest-first, so "cumulative"
  active days is really a sliding 370-day window → earned plateaus and can decrease.
- `coinsSpent` lives in the **last-writer-wins** synced settings blob, so two devices spending offline
  don't sum → double-spend.

Net: the balance could silently shrink with no spend, and (with spending in Inc 3) already-spent coins
would be confiscated. Two fixes already landed regardless (empty-`healthContext` no longer grants a
coin; the wallet badge reads live instead of a stale `@State` snapshot).

## Locked decisions (owner, 2026-06-29)

1. Earning is an **idempotent ledger**: each active day earns once; re-processing a known day does nothing.
2. **Spend correctness across devices must be handled now** (not deferred to Inc 3).
3. The ledger lives in the **synced** per-row store, **not** the on-phone sealed store. **Decided
   2026-06-29: store it unencrypted** — same as how custom clothing items already sync (in the clear).
   (Encryption was considered; the owner chose plaintext for simplicity since coins are low-sensitivity.)
4. Watermark pruning was requested to bound size and stop re-synced old days from double-granting. **The
   deterministic `earn` id (below) already prevents double-grant on re-sync without a watermark**, and a
   per-row store handles thousands of tiny rows fine — so **v1 retains all rows; watermark compaction is
   a documented future optimization** (it has distributed-compaction hazards not worth shipping wrong).
5. Coins-per-active-day = **5**; an active day = any day with real logged content (incl. *non-empty*
   HealthKit context). Gentle, cumulative, never a streak.

## Architecture

A single append-only ledger of entries, persisted as **plaintext per-row CloudKit records** (Decision 3)
that sync independently across devices — mirroring the proven `CustomItemRecord` per-row store
(Increment 1), **but append/upsert-only** (never "delete-unlisted", which would clobber another device's
synced rows). The cross-device "union-merge" (collapsing duplicate-id rows) is done in **`CoinEconomy`
aggregation**, not by the store — see the entry model below.

### Entry model — `FernletDomainModel/CoinEconomy.swift` (wall-safe)

```
enum CoinLedgerKind: String, Codable { case earn, spend }

struct CoinLedgerEntry: Codable, Identifiable {
    let id: String          // "earn:<dayKey>" (deterministic) or "spend:<ref>"
    let kind: CoinLedgerKind
    let amount: Int         // earn: +coinsPerActiveDay; spend: the price
    let dayKey: String?     // earn: the active day; nil for spend
    let spendRef: String?   // spend: item/purchase id (idempotency); nil for earn
    let createdAt: Date
}
```

- **Idempotent earn:** an `earn` row's `id` is *derived* from its `dayKey` (`"earn:<dayKey>"`). On one
  device the repository upserts by id, so a re-mint is a no-op. Across devices, two independent mints of
  `earn:2026-06-29` produce **two physical rows** — CloudKit mirrors by record identity and
  `NSPersistentCloudKitContainer` cannot enforce the `idString` as unique, so the store does **not**
  collapse them. The collapse happens in **`CoinEconomy` aggregation** (`deduplicatedByID`): every total
  dedups rows by id first, so the day is credited exactly once. This application-level dedup — not any
  storage-level "union-merge" — is what makes earning double-grant-free. (An earlier draft of this doc
  wrongly assumed the store would collapse same-id rows; the 2026-06-29 code review caught that.)
- **Spend correctness:** each `spend` row's id is `"spend:<ref>"`. Distinct purchases have distinct refs,
  so every device's spends survive and **sum** (the LWW double-spend is gone); a retried buy with the
  same ref dedups. Worst case (two offline buys of the same coins) both count, so the balance floors at 0
  — bounded over-acquisition (one item), never unbounded. This residual is inherent without a server.
- **Balance** = `Σ earn.amount − Σ spend.amount` over **id-deduped** rows, floored at 0. `earn` rows are
  never deleted, so **earned is monotonic** regardless of what happens to the day history (HealthKit
  disable, 370-day prune). This is the core fix.

### Pruning (deferred)

v1 retains all rows (one tiny row per active day — fine for years in a per-row store). The deterministic
earn id already makes re-synced old days inert (dedup), so no watermark is needed for correctness.
Watermark compaction (fold old rows into a prefix-sum) is a future size optimization; it carries
distributed-compaction hazards (concurrent compaction on two devices) and is intentionally out of v1.

### Reconciliation (when earn rows are minted)

A `reconcile()` pass walks `loadDays()`, and for each active day (`hasLoggedContent`) with
`dayKey > watermark` and no existing `earn` row, appends one. Idempotent (deterministic id). Runs at
store init and on app-foreground — **not** during view rendering.

### Storage payload (unencrypted, per Decision 3)

Each row's `payloadData` is the JSON of the `CoinLedgerEntry` (plaintext), mirroring `CustomItemRecord`.
No key management, no lock-gating — the wallet is always available. If encryption is ever wanted, the
seam is one `ColumnCrypto.seal/open` call in `CoinLedgerService` (the repo already stores opaque `Data`).

### Module placement (S3-wall-safe)

| Piece | Module | Why safe |
|---|---|---|
| `CoinLedgerEntry`, `CoinEconomy` math | `FernletDomainModel` | wall-safe value types |
| `CoinLedgerRecord` entity + `CoinLedgerRepository` (per-row, **append/upsert + explicit prune**) | `CloudKitSync` | opaque ciphertext rows; no Private import |
| `CoinLedgerRepositoring` protocol | `FernletPersistence` | mirrors `CustomItemRepositoring` |
| `CoinLedgerService` (`@MainActor @Observable`; decrypts, aggregates, reconciles) | `StoreCore` | imports `FernletCrypto` + repo protocol; key injected by closure |
| balance/spend forwarders | `DiaryStore` → `FernletStore` | reach the service, no Private import |

This is exactly how Increment-1 items are wired, so it's a known-good path.

### What gets removed

`FernletSettings.coinsSpent` and the `cumulativeActiveDayCount`-derived balance from the first attempt
(the ledger replaces them). `FernletDay.hasLoggedContent` + the empty-`healthContext` fix stay.

## The 370-day cap (raised separately by owner)

It's an undocumented ~1-year value; the whole day history is one Core Data blob (CloudKit ~1 MB/record
limit risk). Nothing depends on exactly 370 (scoring uses a 14-day window; cycle math is detection-based).
**The ledger decouples coins from it** (watermark prefix-sum preserves earned for pruned days), so the
cap need not change for the coin feature. **Decided 2026-06-29: pursue the per-row day split** (the
architecturally correct fix that removes the cap entirely and improves sync) as a **separate, planned
effort** — see [Day-PerRow-Split-Plan-2026-06-29.md](Day-PerRow-Split-Plan-2026-06-29.md). It is NOT part
of the coin-ledger build; the cap stays at 370 until that lands.

## Test plan

Pure `CoinEconomy` aggregation (earn/spend/prefix → balance, floored, monotonic); deterministic earn-id
idempotency; union-merge simulation (two row-sets merge → spends sum, earns dedup); watermark refuses
pre-watermark earn + compaction preserves total; encrypt→sync→decrypt round-trip; HealthKit-disable and
370-prune simulations show earned **does not** drop; legacy decode (no ledger rows → balance 0).
