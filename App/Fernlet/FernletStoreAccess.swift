//
//  FernletStoreAccess.swift
//  Fernlet
//
//  The one process-global store-acquisition cache, lifted out of `ExchangeIntentService.swift`
//  by P10 item 1: same `shared` singleton, same single-in-flight `loadingStore`, same
//  protected-data guard. That item's fix round then retired the one member that had come across
//  with no caller — it was born callerless and its only reachable path was itself dead — so
//  `load()` is the sole writer of `store`, and no future caller may hand this cache a
//  `FernletStore` it did not build.
//
//  WHY IT LIVES ALONE. It was already shared by two callers that are not each other's dependency —
//  the scene loader (`FernletStoreLoader` -> `ExchangeIntentService.loadStoreForUI`) and the
//  background App Intents — and a later P10 item adds a third, the companion background-refresh
//  handler, whose first step is to acquire the store that already exists. A lifecycle service that
//  three unrelated entry points coalesce through should not be reachable only by opening the App
//  Intents file, or the next caller writes its own instead of sharing this one — and two
//  `FernletStore`s over one set of repositories is exactly what the coalescing prevents.
//

import Foundation
import HealthKitGateway
import UIKit

/// The only store acquisition path used by both the UI loader and background exchange intents.
///
/// Main-actor isolation serializes exchange mutations with normal UI mutations. It also coalesces a
/// cold background launch and the scene loader, so they cannot build competing `FernletStore`s over
/// the same repositories.
@MainActor
final class FernletStoreAccess: @unchecked Sendable {
    /// The process-wide cache every caller shares. A second instance would defeat the coalescing,
    /// so there is deliberately no other way to get one.
    static let shared = FernletStoreAccess()

    /// The store once a `load()` has built one, and the only thing this type caches. `load()` is
    /// its sole writer: nothing can seed it with an instance built elsewhere.
    private var store: FernletStore?

    /// The single in-flight `load()`, held only while that load is running so later callers await
    /// it instead of starting a second one. `nil` whenever no load is in flight.
    private var loadingStore: Task<FernletStore, Error>?

    /// Returns the one `FernletStore`, building it on the first call and handing back that same
    /// instance on every call after it.
    ///
    /// Four clauses, in the order the body applies them:
    /// - It throws `ExchangeIntentServiceError.deviceLocked` before touching anything else when
    ///   protected data is unavailable, so a background intent that woke before first unlock fails
    ///   fast instead of opening files it cannot read.
    /// - It returns the cached store when one already exists, without rebuilding.
    /// - Concurrent callers coalesce onto the one in-flight load and await its result, so a cold
    ///   background launch and the scene loader cannot build competing stores over the same
    ///   repositories.
    /// - `loadingStore` is cleared on BOTH the success and the throwing path, so a failed load
    ///   leaves no handle behind and the next caller starts a fresh one.
    ///
    /// The last two clauses are the ML1 invariant `MemoryLifecycleBoundaryTests` allowlists this
    /// file under; keep the two wordings saying the same thing.
    func load(
        healthKitService: (any HealthKitServicing)? = nil,
        statusUpdate: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> FernletStore {
        try requireProtectedData()
        if let store { return store }
        if let loadingStore { return try await loadingStore.value }
        let task = Task { @MainActor [weak self] () throws -> FernletStore in
            guard let self else { throw ExchangeIntentServiceError.storeUnavailable }
            let store = try await FernletStore.load(
                healthKitService: healthKitService,
                statusUpdate: statusUpdate
            )
            await store.loadBundledFoodItemsForLaunch()
            self.store = store
            return store
        }
        loadingStore = task
        do {
            let loaded = try await task.value
            loadingStore = nil
            return loaded
        } catch {
            loadingStore = nil
            throw error
        }
    }

    /// The gate `load()` runs first: throws `ExchangeIntentServiceError.deviceLocked` while
    /// protected data is sealed — a background wake before first unlock, or a locked device — which
    /// is a "try again once unlocked" condition, not a broken store.
    private func requireProtectedData() throws {
        guard UIApplication.shared.isProtectedDataAvailable else {
            throw ExchangeIntentServiceError.deviceLocked
        }
    }
}
