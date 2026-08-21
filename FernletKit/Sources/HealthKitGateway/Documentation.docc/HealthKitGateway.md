# ``HealthKitGateway``

Fernlet's platform shim over Apple HealthKit: authorization, observation, daily-context reads, sample writes, workout two-way sync, and the fail-closed integration disable.

## Overview

HealthKitGateway is the one module in FernletKit that talks to `HKHealthStore`. Everything the rest of the app knows about Apple Health flows through the ``HealthKitServicing`` protocol, whose production conformer is ``HealthKitService`` — a `@MainActor` class that requests authorization per ``HealthCapability`` (seven per-feature permission bundles: body profile, cycle tracking, body context, workout logging, activity context, mindfulness, intimate logging), runs long-lived anchored observation queries, assembles the day's `HealthDailyContext`, and writes app-authored samples (workouts, cycle events, intimacy events, mindful sessions). Consumers inject the protocol, never the class, so tests and previews run without a live Health store; ``HealthKitStoreControlling`` is the inner seam that makes the store itself substitutable (the internal `SystemHealthKitStoreController` is the pass-through production conformer).

In the `Package.swift` dependency DAG this is a layer-6 platform shim ([S]) with edges to `PrivateHealthStore`, `FernletDomainModel`, and `FernletFoundation`. The `PrivateHealthStore` edge exists for exactly one thing: the `extension HealthKitService: PeriodHealthKitServicing` conformance at the bottom of `HealthKitService.swift`, which lets the sealed `PeriodTrackerStore` read and write cycle samples through a narrow seam. That edge is **wall-legal** — the S3 privacy wall only forbids `AIProviders` and `CloudKitSync` from reaching the sealed `Private*` stores, and neither of those imports this module. The division of custody is the module's central privacy invariant: HealthKit holds the clinical samples; the sealed, encrypted stores hold the narratives; the two are correlated only by an `HKMetadataKeyExternalUUID` stamped on each written sample. Nothing in this module caches health data of its own.

The workout half is a genuine two-way sync, and its central correctness question is *whose sample is this*. Outbound, ``HealthKitService/saveWorkout(_:)`` writes via `HKWorkoutBuilder` and stamps every app-authored sample with `fernlet.*` metadata (``HealthKitService/makeMetadata(for:)``): id, name, mode, intensity, muscle groups, exercises, notes, effort, planned-workout link, and activity type, plus the standard sync identifier. That metadata is the *payload* of authorship and never the *proof* of it. Any co-installed app holding workout share access can write those exact keys — `HKMetadataKeySyncIdentifier` included — so the one piece of provenance HealthKit stamps and nobody else can forge is `sourceRevision.source.bundleIdentifier`, surfaced here as ``HealthWorkoutSample/sourceBundleID``. Recognition therefore takes BOTH halves: `WorkoutHealthKitSync.ownWorkoutID(from:ownBundleID:)` yields a workout id only when the writing bundle is this app AND the sample carries `fernlet.workoutID`, and it fails closed — an unresolvable `Bundle.main` degrades to an empty `ownBundleID`, which equals no real sample, so the failure mode is "never claim authorship" rather than "trust everything". Only a proven-own sample has its `fernlet.*` contents read at all: on any other sample that namespace is entirely attacker-controlled and no legitimate third-party app writes it, so it is ignored outright rather than sanitized — which keeps forged names, notes, and exercises out of the synced blob and out of the on-device AI prompt entirely. Deletion follows the same rule from the other end: ``HealthKitService/ownAuthoredSamples(_:ownBundleID:)`` filters the fetched samples in Swift rather than AND-ing the source into the fetch predicate (an all-or-nothing predicate would let a planted impostor hide OUR sample from the fetch), and ``HealthKitService/deleteAllAuthoredSamples()`` scopes its query with `HKQuery.predicateForObjects(from: HKSource.default())`. Without that filter a single planted sample carrying our metadata fails the whole batch with `errorAuthorizationDenied` and takes the real sample down with it. One consequence worth stating for the localization pass: the values inside `fernlet.mode`, `fernlet.intensity`, `fernlet.muscleGroups`, and `fernlet.activityType` are enum raw values re-parsed on the way back in (``WorkoutHealthKitSync/parseFernletMetadata(_:)`` `compactMap`s the muscle groups; a missing intensity falls back to `.moderate`), so they are frozen English tokens on a cross-device wire — translating one silently resets intensity and drops muscle groups on an otherwise legitimate rebuild.

Inbound, ``WorkoutHealthKitSync`` (owned by the app's `HealthSyncCoordinator`) observes additions and deletions and reconciles them into local rows through the ``WorkoutSyncContext`` host protocol, which the app's `FernletStore` conforms to. Reconciliation handles the hard races: tombstoned rows whose in-flight save resurfaces after removal are deleted-and-skipped; missing app-authored rows are rebuilt under their original id (`WorkoutHealthKitSync.makeWorkout(from:authoredFernletID:)`) so they stay editable; foreign samples import as read-only rows; and Health-app-side deletions are honored immediately, with a cross-device edit healing itself when the replacement sample arrives. ``ActivityTypeCatalog`` supplies the two-way activity-type mapping, and ``HealthWorkoutSample`` abstracts `HKWorkout` for tests.

> Warning: Until 2026-08-20 this page said the `fernlet.*` metadata is what makes a sample "recognizable as *ours* later". That is precisely the model a security review replaced, and it is not how the code has worked since: metadata alone proves nothing. Anything built on the old sentence — matching, repointing, rebuilding, or deleting a row on metadata alone — would let any co-installed app with workout share access claim, rewrite, or hide a Fernlet workout. If you touched this seam on the strength of the old text, re-check it against `WorkoutHealthKitSync.ownWorkoutID(from:ownBundleID:)`.

State that must survive relaunches or cross service instances lives outside the class. Query anchors are keychain items via ``HealthKitAnchorKeychain`` (device-only accessibility — anchors never roam). The master toggle and per-capability opt-ins live in the keychain-backed `StoragePreferencesStore`, and the service's gate re-reads them **live** on every call because multiple `HealthKitService` instances coexist (the app store's, the Privacy screen's) and a toggle flipped on one must gate the others immediately. Disabling the integration is fail-closed: ``HealthKitService/disableIntegration()`` refuses to run unless a ``HealthKitCacheClearing`` conformer is available to purge Fernlet's cached HealthKit-derived values — the real cleaner (`CoreDataHealthKitCacheCleaner`) lives app-side because it needs CloudKitSync and LocalPersistence, and is installed into ``HealthKitService/defaultCacheClearer`` at launch. The "delete everything" funnel uses ``HealthKitService/deleteAllAuthoredSamples()``, whose ``AuthoredSampleDeleteOutcome`` distinguishes retryable failures from revoked-access states that only the Health app can fix. That sweep is gated on nothing at all — not the master toggle, not even device availability (an absent Health store surfaces as an expected skip) — which is what lets the wipe offer Health deletion to a user who has since turned the integration off.

The third piece of outside-the-class state is ``HealthCapabilityRequestLedger``, the record of which ``HealthCapability`` prompts have ever been shown — the app's own memory, because HealthKit never reveals whether a prompt was presented. It was a plaintext `UserDefaults` array until 2026-08-20: readable with `defaults read`, carried into unencrypted device backups, and cleared by nothing, so a wiped phone still held a record that the user had once enabled intimate logging. It is now a keychain row (after-first-unlock, this-device-only, filed in the ``HealthKitAnchorKeychain/service`` slot) that ``HealthKitService/disableIntegration()`` and the "delete everything" funnel both clear, and reading it drains and deletes any surviving plaintext copy. Two invariants make the clear stick: **nothing caches the ledger** — every accessor, including ``HealthKitAuthorizationViewModel/requestedCapabilities``, reads the row fresh, because a cached `Set` in one of the coexisting instances would re-persist the whole pre-wipe union on the next prompt — and its storage token plus the `\n`-joined raw-value encoding are **frozen**. ``HealthCapabilityRequestLedger/hasEverRequestedWritableCapability(keychainService:legacyDefaults:)`` answers the wipe's "did Fernlet ever write samples?" question from that persisted row, classifying capabilities through ``HealthKitService/writesSamplesToHealth(_:)`` (derived from the share type sets, never an enumerated list) so it stays correct with the master toggle off and with no service instance alive.

Concurrency: the target compiles with `defaultIsolation(MainActor.self)` but in **Swift 5 language mode** — deliberately, so HealthKit's `@Sendable` query completion handlers may capture the non-Sendable observation handlers exactly as the code did in the app target; every callback hops to the main actor via `Task { @MainActor in … }` before touching state, and the pure type-lookup/metadata/sample-construction statics are `nonisolated`. Failure modes are ``HealthKitServiceError`` for closed gates and missing types; observation and outbound-sync failures are logged to `FernletAuditLog` and never thrown at the UI.

## Topics

### The service and its seams

- ``HealthKitServicing``
- ``HealthKitService``
- ``HealthKitStoreControlling``
- ``HealthKitCacheClearing``

### Authorization and capabilities

- ``HealthCapability``
- ``AuthorizationSnapshot``
- ``AuthorizationOutcome``
- ``HealthAuthorizationPresentation``
- ``HealthKitAuthorizationViewModel``

### Workout sync

- ``WorkoutHealthKitSync``
- ``WorkoutSyncContext``
- ``HealthWorkoutSample``
- ``WorkoutHealthKitMetadata``
- ``ActivityTypeCatalog``

### Daily context and body profile

- ``HealthBodyProfile``
- ``StressMetricDay``

### Persistence, outcomes, and errors

- ``HealthKitAnchorKeychain``
- ``HealthCapabilityRequestLedger``
- ``AuthoredSampleDeleteOutcome``
- ``HealthKitServiceError``
