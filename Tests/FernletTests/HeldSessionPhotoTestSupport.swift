// HeldSessionPhotoTestSupport.swift
// FernletTests
//
// Shared helpers for the 2026-09-30 held-photo change: session photos — taken here or received —
// are HELD in the sealed pending corpus (`PendingSessionPhotoStore`) until the person's answer and
// never reach the friend wall before it. Cells that used to read "the photo reached the wall" off
// `meshPhotos` now read "the photo is held" off the two memory projections, and every cell that
// ANSWERS pushes an open routed access gate first, because the answer reads plaintext and runs only
// where the gate is open (unlocked, foreground, no duress) — the manager's default is `.closed`.

import Foundation
@testable import FernletCrypto
import FernletDomainModel
import PrivateMediaStore
@testable import ProximityKit
@testable import Fernlet

/// Test-side reads of what a manager holds for review.
@MainActor
enum HeldPhotos {

    /// Every photo `manager` holds for the person's review: the live roll plus the awaiting batch,
    /// metadata only, each id the photo's LOCAL id.
    static func all(_ manager: MeshNetworkManager) -> [FriendPhotoPayload] {
        manager.sessionPhotos + (manager.pendingFriendReview?.photos ?? [])
    }

    /// The local ids ``all(_:)`` lists.
    static func ids(_ manager: MeshNetworkManager) -> Set<UUID> {
        Set(all(manager).map(\.id))
    }

    /// The gate every answering cell pushes: unlocked, foreground, not under duress.
    static let openGate = MeshRoutedAccessGate(
        protectedDataAvailable: true, appIsForeground: true, duressActive: false
    )

    /// Pushes ``openGate`` into `manager` under the pinned install binding (the re-entry pass the
    /// rising edge runs may touch the sealed session context).
    static func openGate(on manager: MeshNetworkManager, now: Date = Date()) {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = manager.applyRoutedAccessGate(openGate, now: now)
        }
    }

    /// The pending corpus's sealed index as a fresh store reads it straight off disk, through the
    /// same process-wide key the manager's default provider uses — a claim about the durable truth,
    /// not the manager's memory. Nil when the index is not `.loaded`.
    static func persistedIndex(_ store: FernletStore) -> PendingSessionPhotoIndex? {
        let pending = PendingSessionPhotoStore(
            directory: store.proximitySupportDirectory
                .appendingPathComponent(PendingSessionPhotoStore.directoryName, isDirectory: true)
        )
        guard case .loaded(let index) = pending.load(now: Date()) else { return nil }
        return index
    }

    /// The photo ids the WALL's persisted index names, read straight off disk (nil when unreadable).
    static func persistedWallIDs(_ store: FernletStore) -> Set<UUID>? {
        let index = PrivateMediaStore(
            indexURL: store.proximitySupportDirectory.appendingPathComponent("MeshPhotoCache.json")
        )
        guard case .entries(let photos) = index.loadIndex() else { return nil }
        return Set(photos.map(\.id))
    }
}
