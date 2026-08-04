import Foundation
import AIContext

/// The device-local, NON-SYNCED daily AI-call counter (Ladder §3.2), backed by `UserDefaults`
/// exactly like `WorkoutTombstoneStore` and the other per-device ledgers. It deliberately lives in
/// the app target, not in any module `AIProviders` imports: the walled AI module can only reach the
/// counter through the injected `AICallQuotaStore` protocol (declared in `AIContext`), never by
/// naming this type.
///
/// The counter never enters `FernletSnapshot`, the sealed stores, or CloudKit — it is plain
/// `UserDefaults.standard`, so device A's usage can never throttle device B.
///
/// Concurrency: `@unchecked Sendable`, made safe by serializing every read-modify-write behind an
/// `NSLock` (the protocol is `Sendable`, so callers may arrive off the main actor). Drives the
/// derived `.sleepy`/`.resting` overlay on `FernletStore.effectiveAIStatus`.
final class UserDefaultsAICallQuotaStore: AICallQuotaStore, @unchecked Sendable {
    private let defaults: UserDefaults
    /// ONE defaults key holding the (dayKey, count) PAIR. Writing them as two separate keys made the
    /// persist non-atomic: a kill between the two writes could pair a fresh dayKey with the previous
    /// day's count (a user who started the day near the resting threshold), so the pair is stored as
    /// a single dictionary value that lands (or not) as a unit. See review finding #3 (Seam-core).
    private let pairDefaultsKey: String
    /// `recordCall` is a read-modify-write; the protocol is `Sendable`, so serialize concurrent
    /// callers to avoid a lost increment. `NSLock` is enough — the critical section is tiny and
    /// UserDefaults is itself thread-safe.
    private let lock = NSLock()

    private static let dayKeyField = "d"
    private static let countField = "c"

    init(
        defaults: UserDefaults = .standard,
        pairDefaultsKey: String = "fernlet.ai.quota.pair"
    ) {
        self.defaults = defaults
        self.pairDefaultsKey = pairDefaultsKey
    }

    func currentQuota() -> AICallQuota {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    @discardableResult
    func recordCall() -> AICallQuota {
        lock.lock()
        defer { lock.unlock() }
        let updated = loadLocked().recordingCall()
        persistLocked(updated)
        return updated
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: pairDefaultsKey)
    }

    // MARK: - Locked helpers (call only while `lock` is held)

    private func loadLocked() -> AICallQuota {
        if let pair = defaults.dictionary(forKey: pairDefaultsKey),
           let dayKey = pair[Self.dayKeyField] as? String {
            let count = pair[Self.countField] as? Int ?? 0
            return AICallQuota(dayKey: dayKey, count: count)
        }
        // No stored pair yet → an empty counter anchored to today.
        return AICallQuota(dayKey: AICallQuota.dayKey(for: Date()), count: 0)
    }

    private func persistLocked(_ quota: AICallQuota) {
        defaults.set(
            [Self.dayKeyField: quota.dayKey, Self.countField: quota.count] as [String: Any],
            forKey: pairDefaultsKey
        )
    }
}
