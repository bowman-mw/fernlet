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

public protocol FernletRepository {
    func loadSnapshot(todayKey: String) -> FernletSnapshot
    /// Persists a snapshot to the (potentially iCloud-synced) blob. Takes a `SanitizedSnapshot` — a
    /// snapshot that can ONLY be produced by the storage privacy strip — so an un-stripped snapshot can
    /// never reach the synced blob by accident (the data-side analogue of the compiler import-wall).
    @discardableResult func saveSnapshot(_ snapshot: SanitizedSnapshot) -> Bool
    /// Persists a single (past) day. Takes a `SanitizedDay` for the same reason as `saveSnapshot`.
    @discardableResult func updateDay(_ day: SanitizedDay, for dateKey: String, todayKey: String) -> Bool
    func storageDescription() -> String
    func loadAllDays() -> [String: FernletDay]
    func loadTierTwoMemories() -> [TierTwoMemoryRecord]
    /// Overwrites the persisted Tier-2 behavioral memories. Used by sealed-backup restore on a
    /// fresh install to seed the inference base from an encrypted iCloud backup. Returns whether
    /// the write succeeded.
    @discardableResult func replaceTierTwoMemories(_ records: [TierTwoMemoryRecord]) -> Bool
    func loadDay(for dateKey: String, todayKey: String) -> FernletDay
}

public extension FernletRepository {
    func loadDay(for dateKey: String, todayKey: String) -> FernletDay {
        loadSnapshot(todayKey: dateKey).day
    }

    // Default no-op so lightweight test doubles need not implement persistence. The two real
    // repositories (`LocalFernletRepository`, `CoreDataFernletRepository`) override this.
    @discardableResult func replaceTierTwoMemories(_ records: [TierTwoMemoryRecord]) -> Bool { false }
}
