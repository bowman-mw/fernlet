//
//  SealedBackupGenerationStore.swift
//  Fernlet
//
//  The device-local high-water mark for sealed-backup generations — the state half of the
//  rollback defense (code review 2026-06-12 finding 14, fixed 2026-08-09). The crypto half is
//  the generation binding in `SealedBackupCrypto.authenticatedData`.
//

import Foundation
import CloudKitSync

/// Remembers the highest sealed-backup generation this device has written or accepted, per payload
/// type, so a restore can refuse an older-but-validly-sealed backup.
///
/// **Why this is needed at all.** Binding the generation into the GCM AAD stops an attacker from
/// *editing* the counter, but not from *substituting* a whole earlier generation that this device
/// legitimately sealed in the past — every byte of it authenticates. Rollback is only detectable by
/// remembering what we have already seen, which is what this type does.
///
/// **Device-local and never synced, by construction.** It follows the established per-device ledger
/// pattern (`UserDefaultsAICallQuotaStore`, `WorkoutTombstoneStore`): plain `UserDefaults`, never a
/// `FernletSettings` field, never in `FernletSnapshot`, never in CloudKit. Syncing it would defeat
/// the purpose — an attacker who can rewrite the backup can rewrite a synced high-water mark too.
///
/// **Divergence across devices is expected and safe.** Counters are minted per device, so two
/// devices that both write backups can mint the same number, and a device that has never restored
/// starts at zero and accepts whatever it first finds (correct — it has no history to contradict).
/// The invariant is only ever "never accept older than what *I* have already seen".
///
/// - Important: Not thread-safe on its own; callers are main-actor confined, matching
///   `WorkoutTombstoneStore`. `UserDefaults` itself is thread-safe, but the read-modify-write in
///   ``mintNext(for:)`` is not atomic.
@MainActor
struct SealedBackupGenerationStore {
    private let defaults: UserDefaults

    /// Injectable for tests; production uses `.standard`.
    ///
    /// - Important: This type is main-actor isolated, so it cannot be used as a *default argument*
    ///   value — in the Swift 5 language mode default-argument expressions are evaluated in a
    ///   nonisolated context. Callers that want the production store take an optional and construct
    ///   it inside their own isolated body; see
    ///   `SealedBackupService.init(cloudDataService:identityService:generationStore:)`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The highest generation written or accepted for this payload type; `0` when none.
    ///
    /// Zero is deliberately "no history" rather than a real generation: minted generations start at
    /// 1, so a fresh device accepts any authentic backup, and no authentic backup can ever compare
    /// as stale against a device that has never seen one.
    func lastSeen(for payloadType: SealedBackupPayloadType) -> Int64 {
        Int64(defaults.integer(forKey: Self.key(for: payloadType)))
    }

    /// Mints the next generation for a write and persists it immediately.
    ///
    /// Persisting *before* the upload is the fail-safe direction: if the upload then fails, this
    /// device has burned a number and the next write skips it — harmless, since the counter only
    /// has to be monotonic, not gapless. Persisting after a successful upload would be worse: a
    /// crash between the two would let the next write reuse a number that is already in the cloud,
    /// and the rollback check would then accept a substitution of the earlier one.
    mutating func mintNext(for payloadType: SealedBackupPayloadType) -> Int64 {
        let next = lastSeen(for: payloadType) + 1
        defaults.set(Int(next), forKey: Self.key(for: payloadType))
        return next
    }

    /// Raises the high-water mark after a restore has authenticated a generation.
    ///
    /// Only ever moves forward — a legitimate cross-device restore can hand this device a *newer*
    /// generation than it has minted itself, and that must become the new floor.
    mutating func recordAccepted(_ generation: Int64, for payloadType: SealedBackupPayloadType) {
        guard generation > lastSeen(for: payloadType) else { return }
        defaults.set(Int(generation), forKey: Self.key(for: payloadType))
    }

    /// Clears every payload type's mark. Wired into the delete-all path: leaving a stale high-water
    /// mark behind would make a legitimate post-wipe restore look like a rollback attack.
    mutating func reset() {
        for payloadType in SealedBackupPayloadType.allCases {
            defaults.removeObject(forKey: Self.key(for: payloadType))
        }
    }

    private static func key(for payloadType: SealedBackupPayloadType) -> String {
        "fernlet.sealedBackup.generation.\(payloadType.rawValue)"
    }
}
