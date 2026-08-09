# ``HealthKitGateway``

Fernlet's platform shim over Apple HealthKit: authorization, observation, daily-context reads, sample writes, workout two-way sync, and the fail-closed integration disable.

## Overview

HealthKitGateway is the one module in FernletKit that talks to `HKHealthStore`. Everything the rest of the app knows about Apple Health flows through the ``HealthKitServicing`` protocol, whose production conformer is ``HealthKitService`` — a `@MainActor` class that requests authorization per ``HealthCapability`` (seven per-feature permission bundles: body profile, cycle tracking, body context, workout logging, activity context, mindfulness, intimate logging), runs long-lived anchored observation queries, assembles the day's `HealthDailyContext`, and writes app-authored samples (workouts, cycle events, intimacy events, mindful sessions). Consumers inject the protocol, never the class, so tests and previews run without a live Health store; ``HealthKitStoreControlling`` is the inner seam that makes the store itself substitutable (the internal `SystemHealthKitStoreController` is the pass-through production conformer).

In the `Package.swift` dependency DAG this is a layer-6 platform shim ([S]) with edges to `PrivateHealthStore`, `FernletDomainModel`, and `FernletFoundation`. The `PrivateHealthStore` edge exists for exactly one thing: the `extension HealthKitService: PeriodHealthKitServicing` conformance at the bottom of `HealthKitService.swift`, which lets the sealed `PeriodTrackerStore` read and write cycle samples through a narrow seam. That edge is **wall-legal** — the S3 privacy wall only forbids `AIProviders` and `CloudKitSync` from reaching the sealed `Private*` stores, and neither of those imports this module. The division of custody is the module's central privacy invariant: HealthKit holds the clinical samples; the sealed, encrypted stores hold the narratives; the two are correlated only by an `HKMetadataKeyExternalUUID` stamped on each written sample. Nothing in this module caches health data of its own.

The workout half is a genuine two-way sync. Outbound, ``HealthKitService/saveWorkout(_:)`` writes via `HKWorkoutBuilder` and stamps every app-authored sample with `fernlet.*` provenance metadata (``HealthKitService/makeMetadata(for:)``) — the id, name, intensity, muscle groups, and planned-workout link that make the sample recognizable as *ours* later. Inbound, ``WorkoutHealthKitSync`` (owned by the app's `HealthSyncCoordinator`) observes additions and deletions and reconciles them into local rows through the ``WorkoutSyncContext`` host protocol, which the app's `FernletStore` conforms to. Reconciliation handles the hard races: tombstoned rows whose in-flight save resurfaces after removal are deleted-and-skipped; missing app-authored rows are rebuilt under their original id (`WorkoutHealthKitSync.makeWorkout(from:authoredFernletID:)`) so they stay editable; foreign samples import as read-only rows; and Health-app-side deletions are honored immediately, with a cross-device edit healing itself when the replacement sample arrives. ``ActivityTypeCatalog`` supplies the two-way activity-type mapping, and ``HealthWorkoutSample`` abstracts `HKWorkout` for tests.

State that must survive relaunches or cross service instances lives outside the class. Query anchors are keychain items via ``HealthKitAnchorKeychain`` (device-only accessibility — anchors never roam). The master toggle and per-capability opt-ins live in the keychain-backed `StoragePreferencesStore`, and the service's gate re-reads them **live** on every call because multiple `HealthKitService` instances coexist (the app store's, the Privacy screen's) and a toggle flipped on one must gate the others immediately. Disabling the integration is fail-closed: ``HealthKitService/disableIntegration()`` refuses to run unless a ``HealthKitCacheClearing`` conformer is available to purge Fernlet's cached HealthKit-derived values — the real cleaner (`CoreDataHealthKitCacheCleaner`) lives app-side because it needs CloudKitSync and LocalPersistence, and is installed into ``HealthKitService/defaultCacheClearer`` at launch. The "delete everything" funnel uses ``HealthKitService/deleteAllAuthoredSamples()``, whose ``AuthoredSampleDeleteOutcome`` distinguishes retryable failures from revoked-access states that only the Health app can fix.

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
- ``AuthoredSampleDeleteOutcome``
- ``HealthKitServiceError``
