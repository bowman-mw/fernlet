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
    func saveSnapshot(_ snapshot: SanitizedSnapshot) -> Bool
    /// Persists a single (past) day. Takes a `SanitizedDay` for the same reason as `saveSnapshot`.
    func updateDay(_ day: SanitizedDay, for dateKey: String, todayKey: String) -> Bool
    /// A short, human-readable description of the backing store, surfaced for diagnostics.
    func storageDescription() -> String
    /// Every persisted day keyed by date key — the authoritative, uncapped history the store
    /// rehydrates on launch.
    func loadAllDays() -> [String: FernletDay]
    /// Every persisted day like ``loadAllDays()`` — or nil when this read cannot be trusted to be
    /// COMPLETE: the store is in read-only recovery, a day-row fetch failed, or a stored day would not
    /// decode. ``loadAllDays()`` answers each of those as missing days, which suits a screen and is
    /// wrong for a caller that reads an absent day as "nothing here": the journal Sealed backup's
    /// snapshot would publish a truncated set over the full one (journal and intimacy Sealed backup v2
    /// design 2026-09-30, §7.1, review B3 fix round 1). Fail closed — nil, never a partial history.
    func loadAllDaysIfComplete() -> [String: FernletDay]?
    /// Loads the persisted Tier-2 behavioral memory records that seed the inference base.
    ///
    /// Tier-2 is DEVICE-LOCAL (owner decision 2026-09-23): conformers keep it out of the snapshot blob
    /// entirely — both real conformers read a never-synced, backup-excluded sidecar — so an
    /// implementation must never source these records from, or write them into, anything that syncs.
    /// There is deliberately no replace/restore requirement: the retired sensitive-notes sealed backup
    /// was the only outside writer, and a conformer's own save path is now the only one.
    func loadTierTwoMemories() -> [TierTwoMemoryRecord]
    /// Loads a single persisted day by its date key (defaulted below in terms of ``loadSnapshot(todayKey:)``).
    func loadDay(for dateKey: String, todayKey: String) -> FernletDay
    /// Erases every persisted day and the snapshot blob. Distinct from resetting the in-memory diary:
    /// the per-row day store is the authoritative, uncapped source of truth, so clearing memory alone
    /// leaves the full history on disk to be reloaded by `loadAllDays()` on the next launch — and
    /// re-uploaded to iCloud. "Reset everything" was doing exactly that.
    func purgeAllPersistedData() -> Bool
}

public extension FernletRepository {
    func loadDay(for dateKey: String, todayKey: String) -> FernletDay {
        loadSnapshot(todayKey: dateKey).day
    }

    // INVARIANT for the default below: a conformer with ANY persistent state MUST override it.
    // The default is correct ONLY for doubles that hold none — for such a double "everything was
    // purged" is `true` (there was nothing to purge). A real store that inherits
    // `purgeAllPersistedData` would report a complete wipe of data it never touched, in the one
    // flow where a false success is directly user-visible.
    func purgeAllPersistedData() -> Bool { true }

    // INVARIANT for the default below, as for `purgeAllPersistedData`: a conformer with ANY persistent
    // state MUST override it. The default calls every ``loadAllDays()`` complete, which is true only for
    // a double whose read cannot fail; a real store that inherited it would hand a truncated history to
    // the one caller that asked to be told.
    func loadAllDaysIfComplete() -> [String: FernletDay]? { loadAllDays() }
}
