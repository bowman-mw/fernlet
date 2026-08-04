//
//  FernletRepository.swift
//  FernletPersistence
//
//  The persistence contract: the abstract `FernletRepository` protocol that both
//  the local JSON repository and the Core Data + iCloud repository implement.
//  Extracted out of the app target's `LocalFernletRepository.swift` into the
//  nonisolated `FernletPersistence` module (SPM carve-up, plan §6).
//

import Foundation
import FernletDomainModel

/// The abstract persistence contract for the diary snapshot blob and its per-day history, implemented
/// by both the local JSON repository and the Core Data + iCloud repository.
///
/// This protocol is the seam the ``FernletPersistence`` module exists to define. Two real conformers
/// implement it — `LocalFernletRepository` (in `LocalPersistence`, local JSON) and
/// `CoreDataFernletRepository` (in `CloudKitSync`, Core Data + iCloud) — and the app's `FernletStore`
/// selects between them via `StoragePreferences`, so everything above this seam is backing-store
/// agnostic. `SnapshotSaveCoordinator` (in `StoreCore`) drives the write side; lightweight test
/// doubles conform for store-level tests, aided by the default no-op extension methods.
///
/// The write boundary enforces the storage privacy strip **by type**: ``saveSnapshot(_:)`` and
/// ``updateDay(_:for:todayKey:)`` accept only ``SanitizedSnapshot`` / ``SanitizedDay`` — wrappers that
/// can be minted solely through the sanitizing factories — so an un-stripped snapshot can never reach a
/// (potentially iCloud-synced) blob no matter which conformer is active. The protocol itself is
/// nonisolated (this module declares no default actor isolation); each conformer defines its own
/// threading, and the synchronous API mirrors the original app-target call sites. The
/// ``RemoteChangePublishingRepository`` refinement adds remote-change notification for synced conformers.
public protocol FernletRepository {
    /// Loads the persisted aggregate for the given date key, substituting a fresh empty day when no
    /// day row exists for that key yet.
    func loadSnapshot(todayKey: String) -> FernletSnapshot
    /// Persists a snapshot to the (potentially iCloud-synced) blob. Takes a `SanitizedSnapshot` — a
    /// snapshot that can ONLY be produced by the storage privacy strip — so an un-stripped snapshot can
    /// never reach the synced blob by accident (the data-side analogue of the compiler import-wall).
    @discardableResult func saveSnapshot(_ snapshot: SanitizedSnapshot) -> Bool
    /// Persists a single (past) day. Takes a `SanitizedDay` for the same reason as `saveSnapshot`.
    @discardableResult func updateDay(_ day: SanitizedDay, for dateKey: String, todayKey: String) -> Bool
    /// A short, human-readable description of the backing store, surfaced for diagnostics.
    func storageDescription() -> String
    /// Every persisted day keyed by date key — the authoritative, uncapped history the store
    /// rehydrates on launch.
    func loadAllDays() -> [String: FernletDay]
    /// Loads the persisted Tier-2 behavioral memory records that seed the inference base.
    func loadTierTwoMemories() -> [TierTwoMemoryRecord]
    /// Overwrites the persisted Tier-2 behavioral memories. Used by sealed-backup restore on a
    /// fresh install to seed the inference base from an encrypted iCloud backup. Returns whether
    /// the write succeeded.
    @discardableResult func replaceTierTwoMemories(_ records: [TierTwoMemoryRecord]) -> Bool
    /// Loads a single persisted day by its date key (defaulted below in terms of ``loadSnapshot(todayKey:)``).
    func loadDay(for dateKey: String, todayKey: String) -> FernletDay
    /// Erases every persisted day and the snapshot blob. Distinct from resetting the in-memory diary:
    /// the per-row day store is the authoritative, uncapped source of truth, so clearing memory alone
    /// leaves the full history on disk to be reloaded by `loadAllDays()` on the next launch — and
    /// re-uploaded to iCloud. "Reset everything" was doing exactly that.
    @discardableResult func purgeAllPersistedData() -> Bool
}

public extension FernletRepository {
    func loadDay(for dateKey: String, todayKey: String) -> FernletDay {
        loadSnapshot(todayKey: dateKey).day
    }

    // Default no-op so lightweight test doubles need not implement persistence. The two real
    // repositories (`LocalFernletRepository`, `CoreDataFernletRepository`) override this.
    @discardableResult func replaceTierTwoMemories(_ records: [TierTwoMemoryRecord]) -> Bool { false }

    // Same contract as above — the two real repositories override; doubles hold nothing to purge.
    @discardableResult func purgeAllPersistedData() -> Bool { true }
}
