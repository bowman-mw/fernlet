# ``DiaryStore``

The portable diary slice of Fernlet's central store — the pure diary state and pure diary
mutations carved out of the app's `FernletStore` facade into their own SPM module.

## Overview

`DiaryStore` (the module) exists so that the heart of Fernlet — what the user logged today and
on every past day, and how those logs score — can compile against portable layers only. It
declares exactly one type, the ``DiaryStore/DiaryStore`` class: a `@MainActor` `@Observable`
store owning the diary state (`day`, `settings`, `recentMeals`, `previousJournals`, `memories`,
`goals`, `workshop`, `foodItems`, `recipes`, `dailyScores`, `companionThought`) plus the pure
diary methods — per-day scoring, meal/recipe/workout/planned-recipe logging, sleep/hydration/
personal-care edits, settings toggles, sickness and dismissal flags, onboarding commit, and the
repository-backed past-day reads and writes. The app-side `FernletStore` facade owns a
`DiaryStore` instance, forwards every diary member to it, and keeps the app-only collaborators
(coordinators, proximity, snapshot machinery, HealthKit, the period bridge) on its own side.

In the FernletKit dependency graph (see `FernletKit/Package.swift`, the "Layer 8" target entry)
this module depends only on portable layers: `StoreCore`, `FernletPersistence`,
`LocalPersistence`, `FernletScoring`, `FernletDomainModel`, `FernletFoundation`, and
`FoodCatalog`. It deliberately has **no** edge to any `Private*` sealed store, `CloudKitSync`,
`AIProviders`, `HealthKitGateway`, `ProximityKit`, or `PeriodContextBridge`. Relative to the S3
privacy wall, `DiaryStore` is therefore neither a sealed store nor a walled consumer — it sits
on the portable side, and sealed data reaches it only in stripped or gated form. Two mechanisms
carry that stance in code: every past-day write funnels through the private `mutatePastDay`,
which passes the day through `SanitizedDay` so sealed journal text and every HealthKit-derived
value can never enter the (potentially iCloud-synced) repository blob or a synced row; and the
sensitive gates (`isAdultVerified`, the period/stress scoring adjustments, the sealed-journal id
set) are injected closures whose defaults fail closed — refusal, `.none`, `0`, and empty,
respectively.

HealthKit readings stay on the device that read them (owner decision 2026-09-23 — HealthKit
information is not stored in iCloud). Because the strip removes them from every row, the facade
attaches this device's HealthKit residue cache with `attachHealthKitResidueStore(_:)` (a
`DeviceHealthResidueStoring` from `FernletPersistence`; the file-backed conformer lives in the app
target), and every day this store hands out — the in-memory `day` at attach, on `applyDiarySlice`
and on `advanceCurrentDay`, and `loadDay`/`loadDays`/`loadAllDaysFromRepository` — has that
residue overlaid. The full-history reads also include the days that exist here only because of what
HealthKit reported (their stripped rows are empty, so none is written), which keeps coin accrual,
trends and the sealed-backup fresh-install gate seeing what they saw before. `mutatePastDay` edits
the overlaid day (so the strip still recognizes HealthKit's sleep hours against the context's
marker, and an Apple Health workout import or deletion on a past day is a residue change) and
records the edited day's residue back into the cache before the strip. With no cache attached the
strip still applies — the values are simply not given back.

Construction is two-phase. The facade builds the store with `init` (which filters USDA rows out
of the snapshot's food items and seeds the injected `FoodCatalog`'s user-item index), then calls
`rewireHooks(scheduleSnapshotSave:periodAdjustment:stressModifier:sealedJournalIDs:)` to swap
the placeholder closures for live ones that weakly capture the facade — avoiding an init-order
cycle. A `hooksRewired` flag backs an assert so a constructor that copies the build-then-rewire
pattern but forgets the rewire trips loudly in debug instead of silently dropping every save.

Persistence follows one invariant: this store never writes the snapshot itself. Every mutation
ends in `scheduleSnapshotSave()` (directly or via the `batchSnapshotPersistence` wrapper), which
invokes the facade's debounced `SnapshotSaveCoordinator`. "Today" is the in-memory `day` keyed
by `todayKey`; all other dates round-trip through the injected `FernletRepository`
(`CoreDataFernletRepository` or `LocalFernletRepository`, chosen by the user's storage
preference) via the single write seam `mutateDay(date:_:)`. A process resident across local
midnight rolls over with `advanceCurrentDay(to:)` — the caller must flush the outgoing day's
pending save first, because the rollover only re-keys and reloads.

Concurrency is uniform: the whole target compiles with `defaultIsolation(MainActor.self)`, and
the class is `@Observable`, so observation tracking lives here — the facade marks its own
forwarding property `@ObservationIgnored` and lets SwiftUI views observe this store's state
directly.

## Topics

### The diary store

- ``DiaryStore/DiaryStore``
