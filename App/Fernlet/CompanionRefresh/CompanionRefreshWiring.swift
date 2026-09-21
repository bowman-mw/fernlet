//
//  CompanionRefreshWiring.swift
//  Fernlet
//
//  Network migration P10 item 4 (plan §17.2): the ONE place ``CompanionRefreshPipeline``'s abstract
//  steps are bound to the real app — and therefore the one file in the refresh directory that names
//  anything of the app's at all.
//
//  Deliberately tiny, and deliberately separate from the pipeline. Everything interesting about the
//  handler — the order, the diff, the cancellation, the completion table — is exercised in tier 1
//  against fakes; what is left here is five bindings, each a single expression, and each one a name
//  from `BackgroundRefreshBoundaryTests`' PERMITTED list. A reviewer can read this file's body in
//  one screen and decide whether the handler reaches anything it must not, which is a property a
//  wall can support but not supply.
//
//  **Every name below, and why it is allowed.**
//  - `FernletStoreAccess.shared.load()` — §17.2's one sanctioned acquisition. It throws
//    `ExchangeIntentServiceError.deviceLocked` BEFORE opening anything when protected data is
//    unavailable, and returns the CACHED store when the process already has one, so the handler
//    never creates a second store over the same repositories. Its `healthKitService` parameter
//    defaults to `nil` and is left at that default: a store built on a cold background wake gets no
//    Health gateway at all, which is why this file names no HealthKit spelling anywhere. The scene
//    attaches its own gateway to such a store when it arrives — that repair lives in
//    `FernletStoreAccess`, on purpose, because the handler may not speak the word.
//  - `hasUndrainedWidgetActions` — the widget action queue's non-destructive read, behind one store
//    property so the handler never touches the queue type itself. Reading it CLAIMS nothing.
//  - `refreshCurrentDayIfNeeded()` — the app's day roll, the same internal call the foreground
//    scene makes at `.active`.
//  - `companionState` — a COMPUTED property: reading it IS the recompute, and it is a pure function
//    of the rolled day, the goal weights, the derived signals and the two pre-gated adjustments.
//  - `ensureWidgetSnapshotMirror()` / `currentWidgetSnapshot()` / `publishIfContentChanged(_:)` —
//    the publish step, through `WidgetSnapshotMirror`, which owns the snapshot file and the
//    timeline-reload closure.
//
//  **What the day roll was traced to touch, written down because the wall cannot see inside it.**
//  `FernletStore.refreshCurrentDayIfNeeded(now:)` flushes the outgoing day under its OLD key
//  (`SnapshotSaveCoordinator.flushPending()`, a no-op when nothing is pending — which is always
//  true of a store a background wake just built), re-keys the diary, rebuilds the derived signals,
//  reconciles the coin and milestone ledgers, and calls the store's own `publishWidgetSnapshot()`.
//  Every one of those is a read or a write of the app's OWN repositories. None of them calls
//  HealthKit, none reaches a radio, and none forces a CloudKit sync. What they do reach is the
//  Core Data stack, whose production container mirrors to the user's private CloudKit database on
//  its own schedule — the ambient mirroring of any save the app makes, not a sync this handler
//  asks for. The same is true of the recompute: `companionState` reads `day.healthContext`, which
//  holds values HealthKit wrote into the diary on some earlier foreground, never the gateway.
//
//  **Why the mirror is ensured at PUBLISH time and not at acquire time.** `activateWidgetBridge()`
//  runs from `ContentView` at store-ready, and a cold BACKGROUND launch has no scene: the mirror is
//  nil, and the day roll's own internal publish is therefore a no-op. Ensuring the mirror after the
//  roll keeps it that way, so every timeline reload a cold refresh causes is decided by the diff
//  below and by nothing else. On a WARM process the mirror already exists and a day roll does
//  publish through the store's own path — which is correct rather than a leak: a roll always
//  changes `dateKey`, so that reload is one the diff would have made anyway.
//

// `FernletDomainModel` is imported for ONE member: `CompanionState.rawValue`, the spelling the
// snapshot carries. The app target builds with `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`,
// so a member of a package type is unreachable through a value the store handed over unless this
// file says so — which is the wall working, not a loophole: it is on the permitted list because
// §17.2's recompute step speaks exactly these pure value types.
import FernletDomainModel
import Foundation

// MARK: - CompanionRefreshWiring

/// Binds ``CompanionRefreshPipeline`` to the running app.
///
/// A caseless `enum` namespace rather than a type with state: there is nothing to hold between
/// refreshes, and the whole point of item 4 is that a refresh owns nothing that outlives it.
///
/// ## Concurrency
///
/// `@MainActor`, because the store and the mirror are.
@MainActor
enum CompanionRefreshWiring {

    /// The pipeline the coordinator runs in production.
    ///
    /// The closure body is the entire binding. Note what it does NOT do: it does not drain the
    /// widget's pending-action queue (that path mutates the diary and republishes unconditionally),
    /// does not activate the widget bridge's notification observer, and does not touch the Messages
    /// catalog. Those are the foreground's work; §17.2's steps are all that runs here.
    ///
    /// - Returns: A pipeline whose steps are the live store's.
    static func productionPipeline() -> CompanionRefreshPipeline {
        CompanionRefreshPipeline(acquire: { steps(for: try await FernletStoreAccess.shared.load()) })
    }

    /// The five bindings, over a store the caller already holds.
    ///
    /// Split from ``productionPipeline()`` so the BINDINGS themselves are reachable from a test
    /// over an ordinary test store — `CompanionRefreshPipelineTests` runs exactly these five
    /// expressions against a real `FernletStore` and asserts the trace, the publication and the
    /// undrained-queue skip. Without the split the only way to reach them would be through the
    /// process-global acquisition cache, and they would be the one part of item 4 that nothing
    /// exercised. What stays untested here is `FernletStoreAccess.shared.load()` itself, which is
    /// its own file's subject.
    ///
    /// - Parameter store: The acquired store.
    /// - Returns: The steps bound to it.
    static func steps(for store: FernletStore) -> CompanionRefreshSteps {
        CompanionRefreshSteps(
            hasUndrainedWidgetActions: { store.hasUndrainedWidgetActions },
            rollDay: { store.refreshCurrentDayIfNeeded() },
            recompute: { store.companionState.rawValue },
            makeSnapshot: { store.currentWidgetSnapshot() },
            publish: { store.ensureWidgetSnapshotMirror().publishIfContentChanged($0) }
        )
    }
}
