//
//  FernletStoreAccess.swift
//  Fernlet
//
//  The one process-global store-acquisition cache, lifted out of `ExchangeIntentService.swift`
//  by P10 item 1. Nothing about it changed in the move: same `shared` singleton, same
//  single-in-flight `loadingStore`, same protected-data guard.
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
    static let shared = FernletStoreAccess()

    private var store: FernletStore?
    private var loadingStore: Task<FernletStore, Error>?

    /// Seeds the cache with a store the caller already built, so a later `load()` returns that
    /// instance instead of building a second one over the same repositories.
    ///
    /// **No caller at HEAD, deliberately kept.** Its one reachable path was
    /// `ExchangeIntentService.install(store:)`, which was itself callerless and which P10 item 1
    /// deleted; the UI path fills the cache through `load()` instead, which caches what it builds.
    /// That item moved this type between files and changed nothing about it, so retiring a member
    /// of its surface was out of scope — and the decision is a real one, not a formality: whoever
    /// deletes it is deciding that no future caller may hand this cache a store it did not build.
    func install(_ store: FernletStore) {
        self.store = store
    }

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

    private func requireProtectedData() throws {
        guard UIApplication.shared.isProtectedDataAvailable else {
            throw ExchangeIntentServiceError.deviceLocked
        }
    }
}
