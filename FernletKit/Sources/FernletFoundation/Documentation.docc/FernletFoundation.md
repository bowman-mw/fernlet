# ``FernletFoundation``

Layer-0 cross-cutting primitives — canonical day keys, storage preferences, keychain access, audit logging, backup control, persisted-JSON coder configuration, and timing — that every higher FernletKit module may depend on.

## Overview

FernletFoundation is the bottom of the FernletKit dependency DAG (carve-up plan §2). It declares
no in-package dependencies and imports only system frameworks (Foundation, Security, Observation,
os, CoreData, CryptoKit); nearly every other target — the domain model, scoring, persistence, the
sealed `Private*` stores, the lock, the proximity mesh, and the walled `AIProviders`/`CloudKitSync`
consumers — reaches it directly or transitively. `FernletFoundation.swift` is a deliberately
empty doc anchor; every type lives in one of the sibling files.

Because it sits *below* the S3 privacy wall, this module is reachable from **both** sides: the
sealed stores use its keychain and error primitives, while the walled iCloud-sync module uses its
audit log, signposts, and preferences. The corollary is the module's central rule — nothing
sealed or sensitive may ever live here. FernletFoundation carries *mechanism only* (keychain
plumbing, an error vocabulary, day-key formatting, clocks, signposts, JSON coder configuration,
Core Data attribute building); anything that touches sealed content (such as the
pending-narrative buffer or the sealed CoreData stack) belongs in the
protected-side `PrivateStoreCore` target instead, precisely so the walled modules cannot reach it
through this shared layer. Nothing here may import HealthKit, CloudKit, or any higher FernletKit
target.

A few invariants in this module are load-bearing for the rest of the app:

- **Day keys are locale-pinned.** ``FernletDate`` produces the canonical `"yyyy-MM-dd"` key with
  an `en_US_POSIX`/Gregorian formatter. The key is the primary key for a day of user data across
  persistence, scoring, and sync — a locale-dependent format would split one user's history.
- **Preference decoding is tolerant by design.** ``StoragePreferences`` decodes every field
  `IfPresent` with a default; a synthesized decode would throw on the first field an update adds,
  and the loader maps a throw to fresh defaults — silently resetting the user's iCloud, HealthKit,
  and sealed-backup choices. New fields must stay additive.
- **Privacy choices live in the keychain, not the synced blob.** ``StoragePreferencesStore``
  persists the preferences JSON via ``KeychainItem``; resetting deletes the keychain row outright
  so "delete everything" leaves no trace of use.
- **Keychain sync scope is part of the primary key.** ``KeychainItem`` exposes
  ``KeychainItem/SynchronizableScope`` because an iCloud-synced item and a `ThisDeviceOnly` item
  coexist as distinct rows under one service + account; the backup-escrow reconciliation depends
  on telling them apart, and the delete-before-add in `store` must sometimes target only one
  variant. The same type also owns the two shared read/mint idioms that used to be per-caller
  copies: ``KeychainItem/ReadResult`` + `loadDistinguishingAbsence` (a three-way read for the
  heart-drop prekey blob and sidecar seal key, whose mint-on-absence path must fail closed on an
  unreadable row rather than mint over it) and `loadOrCreateSymmetricKey` (the device-bound
  journal and Worry Box keys).
- **Backup exclusion is applied in one place.** ``BackupExclusion`` toggles
  `isExcludedFromBackupKey` across a store file, its `-wal`/`-shm` sidecars, and the external
  binary `_SUPPORT` directory, shared by the sealed and synced persistence controllers so the
  two loops cannot drift. The same two controllers share the package-scope
  `CoreDataModelBuilding` attribute factory for their programmatic managed-object models, for
  the same reason.
- **Persisted JSON has one coder configuration.** ``RowPayloadCoders`` vends the canonical
  encoder/decoder pair — `.sortedKeys` plus ISO-8601 dates, with `prettyPrinted` opt-in for the
  files meant to be human-readable — used by `CloudKitSync`'s day, ledger, custom-item, and
  saved-recipe row stores and its aggregate blob, and by `LocalPersistence`'s local-only blob
  file. It sits here, below both, because it moved down from `CloudKitSync` when the local
  repository's private copy of the same configuration was folded into it. ISO-8601 truncates to
  whole seconds, which callers comparing dates across representations must account for.
- **Audit events fan out.** ``FernletAuditLog`` writes privacy-relevant events to the unified
  logger (context marked `.private`) and to a token-keyed registry of capture handlers, so
  parallel test suites can each observe every event without clobbering one another.

Concurrency: the target builds with `defaultIsolation(MainActor.self)` (SPM targets do not
inherit the app's default-isolation build setting), but most of the module opts out — the
primitives that must be callable from any executor (``FernletDate``, ``KeychainItem``,
``BackupExclusion``, ``FernletAuditLog``'s members, ``MonotonicClock``, ``RowPayloadCoders``,
`CoreDataModelBuilding`'s members, and ``StartupTiming``'s general-purpose members) are
explicitly `nonisolated`, and ``StoragePreferences`` is a `Sendable` value type. The one
genuinely main-actor type is
``StoragePreferencesStore`` (`@MainActor` `@Observable`, observed by SwiftUI settings surfaces),
which still offers the `nonisolated` ``StoragePreferencesStore/currentPreferences(service:)``
escape hatch for off-main readers that need the live persisted value.

## Topics

### Day Keys and Display Dates

- ``FernletDate``

### Storage and Privacy Preferences

- ``StoragePreferences``
- ``StoragePreferencesStore``

### Keychain Access

- ``KeychainItem``

### Backup Control

- ``BackupExclusion``

### Core Data Model Building

- ``CoreDataModelBuilding``

### Persisted-JSON Coding

- ``RowPayloadCoders``

### Auditing and Instrumentation

- ``FernletAuditLog``
- ``StartupTiming``

### Time Sources

- ``MonotonicClock``
- ``SystemMonotonicClock``

### App-Lock Errors

- ``FernletLockError``
