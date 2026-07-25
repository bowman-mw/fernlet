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
final class UserDefaultsAICallQuotaStore: AICallQuotaStore {
    private let defaults: UserDefaults
    private let dayKeyDefaultsKey: String
    private let countDefaultsKey: String

    init(
        defaults: UserDefaults = .standard,
        dayKeyDefaultsKey: String = "fernlet.ai.quota.dayKey",
        countDefaultsKey: String = "fernlet.ai.quota.count"
    ) {
        self.defaults = defaults
        self.dayKeyDefaultsKey = dayKeyDefaultsKey
        self.countDefaultsKey = countDefaultsKey
    }

    func currentQuota() -> AICallQuota {
        let dayKey = defaults.string(forKey: dayKeyDefaultsKey) ?? AICallQuota.dayKey(for: Date())
        let count = defaults.integer(forKey: countDefaultsKey)
        return AICallQuota(dayKey: dayKey, count: count)
    }

    @discardableResult
    func recordCall() -> AICallQuota {
        let updated = currentQuota().recordingCall()
        persist(updated)
        return updated
    }

    func reset() {
        defaults.removeObject(forKey: dayKeyDefaultsKey)
        defaults.removeObject(forKey: countDefaultsKey)
    }

    private func persist(_ quota: AICallQuota) {
        defaults.set(quota.dayKey, forKey: dayKeyDefaultsKey)
        defaults.set(quota.count, forKey: countDefaultsKey)
    }
}
