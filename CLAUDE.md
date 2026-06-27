# Fernlet

Fernlet is a privacy-first, "tamagotchi-of-yourself" iOS health & self-care app — it emphasizes
gentle, consistent care over optimization and streaks. A companion creature reflects the user's
daily wellbeing, computed from food, movement, sleep, cycle, journaling, and hygiene signals.

**Stack:** SwiftUI, iOS 26+, Swift. HealthKit for activity/cycle/intimate data, on-device AI
(Apple Foundation Models) with deterministic fallbacks, Core Data + CloudKit for storage, and a
UWB/MultipeerConnectivity proximity mesh for in-person social features (recipe sharing, friend photos).

**Architecture (the short version):**
- `FernletStore` is the central observable app state; mutations are persisted via `SnapshotSaveCoordinator`.
- Data goes through `FernletRepository` implementations — `CoreDataFernletRepository` (Core Data + iCloud)
  and `LocalFernletRepository` (local JSON), selected by `StoragePreferences`.
- Sensitive data (journal text, cycle narratives, intimate-activity notes) is **sealed/encrypted**
  out of the synced blob via `ColumnCrypto` + the narrative repositories and `FernletLockService`
  (keychain-backed lock). HealthKit holds the clinical samples; the encrypted store holds the notes.
- The `Proximity/` subtree is a self-contained signed/sealed peer-to-peer subsystem (identity
  envelopes, mesh transport, trust vault, ranging, recipe-share + friend-photo flows).

**Build / test:**
```
xcodebuild build-for-testing -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test-without-building -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FernletTests
```
Targets: `Fernlet` (app), `FernletTests` (unit), `FernletUITests`, `FernletShareExtension` (recipe share).

## Index & reference files

Consult these before adding code so existing behavior is reused, not duplicated:

| File | What it covers |
| --- | --- |
| [Docs/FileIndex.md](Docs/FileIndex.md) | Map of every main source file to its responsibility, grouped by feature area. Start here for orientation. |
| [Docs/StoreRepositoryFunctionIndex.md](Docs/StoreRepositoryFunctionIndex.md) | Store / repository / persistence / derived-signals function index + duplication hotspots. Read before any data-mutation, save/load, or storage-preference work. |
| [Docs/ProximityFunctionIndex.md](Docs/ProximityFunctionIndex.md) | Proximity & mesh subsystem function index (identity, transport, trust, recipe-share, friend-photo) + duplication hotspots. |
| [Docs/FernletSpecificationV3.md](Docs/FernletSpecificationV3.md) | Canonical product & architecture spec (privacy-first, module-enforced boundaries). The source of truth for intended behavior. |
| [Docs/ImplementationPlan.md](Docs/ImplementationPlan.md) | Phased implementation plan and planning assumptions (iOS 26, AI fallbacks, privacy-before-features). |
| [Docs/CODE_REVIEW_2026-06-12.md](Docs/CODE_REVIEW_2026-06-12.md) | Full multi-agent code review: 193 confirmed findings, resolutions, and author design decisions. |
| `Docs/Completed Implemtations/` | Per-feature implementation plans that have already shipped (HealthKit, mesh, period/intimacy, startup/biometric, etc.). |
