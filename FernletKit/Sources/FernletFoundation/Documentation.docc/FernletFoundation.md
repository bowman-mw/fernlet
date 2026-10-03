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
  and sealed-backup choices. New fields must stay additive. The Phase-6 corollary: a behavior
  flip must never ride those decode defaults either — the fresh-install backup-exclusion default
  is carried by the additive `backupExclusionChoiceMade` tri-state plus the app's launch gate,
  while `localBackupExcludedFromiOSBackup` keeps `false` as its absent-key default forever so an
  existing user's stored choice decodes unchanged.
- **Privacy choices live in the keychain, not the synced blob.** ``StoragePreferencesStore``
  persists the preferences JSON via ``KeychainItem``; resetting deletes the keychain row outright
  so "delete everything" leaves no trace of use. The blob is `AfterFirstUnlockThisDeviceOnly`,
  and the store's one-shot `init` load tolerantly collapses ANY read failure to fresh defaults —
  so a pre-first-unlock (prewarmed) process holds defaults for its whole lifetime. Launch-time
  consumers that must not act on that fallback use the fail-closed pair added for the Phase-6
  backup-exclusion gate: ``StoragePreferencesBlobState`` /
  ``StoragePreferencesStore/persistedBlobState(service:)`` (a four-way read distinguishing
  decoded / absent / undecodable / unreadable) and
  ``StoragePreferencesStore/refreshFromPersistedBlob()`` (re-syncs the in-memory copy so a
  launch-time write cannot persist the frozen defaults over the real blob).
- **Keychain sync scope is part of the primary key.** ``KeychainItem`` exposes
  ``KeychainItem/SynchronizableScope`` because an iCloud-synced item and a `ThisDeviceOnly` item
  coexist as distinct rows under one service + account; ProximityKit's backup-escrow
  reconciliation, which it was written for, depends on telling them apart, and the
  delete-before-add in `store` must sometimes target only one variant. The same type also owns the
  two shared read/mint idioms that used to be per-caller copies: ``KeychainItem/ReadResult`` +
  `loadDistinguishingAbsence` (a three-way read for stores whose mint-on-absence path must fail
  closed on an unreadable row rather than mint over it — the private-media keys, the
  pending-narrative buffer's key, the lock — and for the storage-preferences launch gate), its
  enumeration sibling ``KeychainItem/EnumerationResult`` + `loadAllDistinguishingFailure` (for
  callers that PROMISE a slot was cleared, where `loadAll`'s error-collapse-to-empty would report a
  clean clear over rows it never saw; `errSecItemNotFound` stays a legitimate empty), and
  `loadOrCreateSymmetricKey` (the device-bound journal and Worry Box keys), which fails closed on an
  unreadable row exactly like the media-key provider — it returns nil rather than minting over a
  key it could not read, because `store` is delete-then-add and a mint there would destroy every
  sealed journal entry and worry.
- **ProximityKit keeps its own copy of the keychain mechanism.** Since ProximityKit plan step
  A0.2.11 its key stores — the device identity and its backup-escrow rows, the mesh seal keys, the
  heart-drop prekey blob and sidecar seal key — reach the keychain through `ProximityKeychainItem`,
  a member-for-member copy that issues these same query dictionaries
  (`ProximityNamespaceGoldenTests` reads them out of `KeychainHelpers.swift` and holds the two
  equal), so their rows read back through either type and Fernlet's tests still read and clear
  those services with ``KeychainItem``. The escrow was the shipping caller of `loadAll`, which now
  has none (only tests); it stays. FernletSocial's moderation ban store, outside ProximityKit,
  calls ``KeychainItem`` itself: its rows, and its delete-everything peer-ban clear through
  `loadAllDistinguishingFailure` and `enumerationResult(status:matches:)`.
- **Backup exclusion is applied in one place.** ``BackupExclusion`` toggles
  `isExcludedFromBackupKey` across a store file, its `-wal`/`-shm` sidecars, and the external
  binary `_SUPPORT` directory, shared by the sealed and synced persistence controllers so the
  two loops cannot drift; the single-file variant (`apply(fileURL:excluded:)`) covers sidecar-less
  stores — today `LocalPersistence`'s JSON day blob — without logging permanent failures for
  sidecars that can never exist. The same two controllers share the package-scope
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
  ProximityKit's lines arrive here through a sink rather than a call: since ProximityKit plan step
  A0.2.10 it logs through its own `ProximityAudit` to the sink its host installs, and Fernlet's,
  `FernletAuditBridge` (FernletConnections, installed by `FernletApp.init`), forwards each line to
  ``FernletAuditLog/log(_:context:)`` unchanged and in line, so the capture handlers see it as
  before.
- **An environmental persistence failure is audited, never trapped.** ``PersistenceFailureAudit``
  is the one seam for a failed Core Data fetch/save/delete, file write/remove, or the payload
  encode that feeds one. Those failures are runtime conditions, not violated invariants — the
  stores load with `FileProtectionType.complete` and nothing defers a day write while the device
  is locked — so the per-row repositories in `CloudKitSync`, the local blob in `LocalPersistence`
  and `DiaryStore`'s past-day write record here and return their existing `false`/empty result
  instead of asserting (P9 item 1; a DEBUG build used to die on an ordinary locked-device write).
  The record carries the frozen dotted token plus the error's `NSError` domain and code ONLY —
  never `localizedDescription` (an `EncodingError`'s embeds the coding path, which can name a day
  key), never `userInfo` (Cocoa file errors carry `NSFilePath`), and nothing user-derived: the
  past-day write's old log carried the day key in its context and no longer does. Programmer-error
  guards — an empty day key, an unreachable enum case — keep their `assertionFailure`.

  One shape does NOT propagate a failure result: a batch row whose payload will not encode (a
  non-finite number reaching JSON) is skipped and audited, and the batch still reports `true`, in
  `AppendOnlyRowStore.append`, `DayRecordRepository.upsert`, and `SavedRecipeRepository`'s
  structured blob. Returning `false` there would make the caller retry the same un-encodable value
  forever, so the audit record is the only trace of the dropped row — which is why the saved-recipe
  site also CLEARS `payloadData` rather than leaving the previous save's blob to out-vote the fresh
  legacy columns.

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
- ``StoragePreferencesBlobState``

### Keychain Access

- ``KeychainItem``

### Backup Control

- ``BackupExclusion``

### Persisted-JSON Coding

- ``RowPayloadCoders``

### Auditing and Instrumentation

- ``FernletAuditLog``
- ``PersistenceFailureAudit``
- ``StartupTiming``

### Time Sources

- ``MonotonicClock``
- ``SystemMonotonicClock``

### App-Lock Errors

- ``FernletLockError``
- ``FernletLockPromptCopy``
