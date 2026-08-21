# ``StoreCore``

The central store-side services lifted out of the app's `FernletStore`: debounced snapshot
persistence, the per-row synced ledgers (coins, milestones, custom items, saved recipes), the
derived-signal rebuild, and the AI meal-analysis retry queue.

## Overview

StoreCore is layer 7 of the FernletKit package DAG — the home for the stateful service objects
that `FernletStore` (the app-side facade) and `DiaryStore` (the portable diary slice, which
imports this module) compose but that own no UI and no domain math of their own. Each service
holds one slice of app state in memory, knows exactly how that slice is persisted, and exposes a
small mutation surface whose durability guarantees are the module's real product.

The module's persistence model splits into two shapes. ``SnapshotSaveCoordinator`` handles the
**snapshot blob**: every "state changed" signal funnels into its debounced `schedule()`, and at
fire time it mints a fresh `SanitizedSnapshot` (the privacy-stripped aggregate that is the only
input `FernletRepository.saveSnapshot` accepts) and writes it — so the write always serializes
current state, never stale captured state. It also debounces the reverse direction, coalescing a
CloudKit-import burst into a single remote-reload. Its `cancelPending()` is load-bearing for the
delete-everything flow: a pending save is a promise to re-serialize state, and during a wipe that
promise must be broken or the save would resurrect just-purged rows.

The four **per-row services** — ``CoinLedgerService``, ``MilestoneLedgerService``,
``CustomItemService``, and ``SavedRecipeService`` — exist precisely because their data must NOT
live in that last-writer-wins snapshot blob. Each persists to its own per-row store through an
append/upsert-only repository protocol, so flushing a stale in-memory set can never delete rows
that synced in from another device. They share one durability contract: locally minted mutations
sit in a pending queue that is the *sole* un-persisted copy; a flush clears the queue only after
a confirmed write; a failed write keeps the queue for retry; and `reloadFromStore()` re-merges
still-pending mutations on top of freshly loaded rows so nothing vanishes from the in-memory view
while a retry is outstanding. That contract is factored into two shared debounced buffers each
service owns — ``DebouncedRowBuffer`` (upsert + delete rows, for the recipe and custom-item
stores) and ``DebouncedAppendBuffer`` (append-only rows, for the two ledgers) — whose write
closures capture the injected repository, never the service. Cross-device correctness is
application-level: deterministic row ids (one earn per day, one spend per purchase ref, one
milestone per event) plus dedup-by-id on
every load form the union-merge that makes earning idempotent and double-spends structurally
impossible, because `NSPersistentCloudKitContainer` does not enforce id uniqueness itself. The
ledgers differ deliberately at the edges: the coin ledger's `reset()` appends a reset-boundary
marker that voids pre-reset rows sync-safely and deletes nothing, while the milestone ledger's
`reset(deletingRowsWith:)` does both halves on "delete everything" — it empties the ledger
(since 2026-08-20, reversing the earlier rule that lifetime counts survive a wipe) AND, since
2026-08-21, appends a `resetBoundary` marker of its own, so event rows still held by another
signed-in device raise no count and re-mint no award when they sync back into the emptied store
(`MilestoneEconomy` counts only rows whose day is at or after the marker's day AND whose
`createdAt` is strictly after its instant — the day half also voids rows re-derived from
re-synced day records, which carry fresh reconcile-time timestamps).

``DerivedSignalsService`` and the pure ``DerivedSignalsRebuilder`` cover Tier-2 derived data:
signals recomputed deterministically from raw day history (via LocalPersistence's
`DerivedSignalFactory`), with a one-shot deferred rebuild so the first large pass runs at utility
priority after launch. ``AIRetryQueueService`` is the odd one out persistence-wise — its queue
rides inside the snapshot blob, so it fires an `onChange` hook (wired to the coordinator's
`schedule()`) instead of owning a repository; its policy work is the kind-scoped dedupe, TTL
age-out, and bounded eviction that keep a future workout/recipe retry record safe from the meal
path.

**Position relative to the S3 wall:** StoreCore is wall-neutral. Its dependencies are
FernletFoundation, FernletDomainModel, FernletScoring, FernletPersistence, and LocalPersistence —
it imports neither a sealed `Private*` store nor either walled consumer (`AIProviders`,
`CloudKitSync`). The concrete CloudKit-backed repositories it drives are injected by the app
behind FernletPersistence protocols (`CoinLedgerRepositoring`, `SavedRecipeRepositoring`, …);
that inversion is what keeps this module free of any CloudKitSync edge. Nothing here touches
sealed data: snapshots arrive already sanitized, and journal/cycle/intimacy content never passes
through these services.

**Concurrency:** the target sets no default isolation. The seven service classes are individually
`@MainActor` (six of them `@Observable`; ``SnapshotSaveCoordinator`` deliberately not, as it
holds no UI-facing state), the two generic pending-write buffers are `@MainActor` (not
`@Observable` — they hold no UI-facing state), and ``DerivedSignalsRebuilder`` is a nonisolated
pure struct. Debounce work uses self-cancelling `Task`s that hop back to the main actor before
mutating state; clocks
(`now`) are injected where timestamps or TTLs matter, keeping the services deterministic under
test.

## Topics

### Snapshot persistence

- ``SnapshotSaveCoordinator``

### Per-row synced stores

- ``CoinLedgerService``
- ``MilestoneLedgerService``
- ``CustomItemService``
- ``SavedRecipeService``
- ``DebouncedRowBuffer``
- ``DebouncedAppendBuffer``

### Derived signals

- ``DerivedSignalsService``
- ``DerivedSignalsRebuilder``

### AI retry queue

- ``AIRetryQueueService``
