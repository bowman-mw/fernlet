// R8: the one custom condition (Docs/Power-of-10-Swift.md §R8) — compiled only into the `Demo`
// build configuration (`Fernlet Demo` scheme). Normal builds carry none of this file.
#if FERNLET_DEMO
import CryptoKit
import Foundation
import FernletDomainModel
import FernletFoundation
import FernletLock

/// The App Review demo mode: a fresh install can fill Fernlet with sample data, a pretend friend and a
/// fixed passcode, so a reviewer (or anyone on the public TestFlight link) can see every screen without
/// an account — Fernlet has none — and without a second iPhone in the room.
///
/// **Demo builds only.** Every demo file is wrapped whole in `#if FERNLET_DEMO`, the condition only the
/// `Demo` build configuration sets (owner's call, 2026-10-29): a normal build shows no demo button and
/// carries no sample data.
///
/// **Never mixes with real data.** It starts only from the Welcome screen of a fresh install, before
/// anything is stored; it keeps storage on this iPhone (no iCloud) and never turns Apple Health on, so
/// sample data reaches neither (``blocksCloudAndHealth``); and leaving erases everything it planted and
/// returns to the Welcome screen to set up for real (``leave(store:lockService:)``).
///
/// **Never fakes the system age check.** Nearby chat opens only on Apple's own age-range answer, and
/// the demo build is public, so the demo persona opens the intimacy section through the same manual
/// confirmation a person uses and leaves chat exactly as the device's own answer leaves it.
@MainActor
enum ReviewDemo {
    /// The demo's Private-hub passcode, shown under the passcode screen while the demo runs and given
    /// to App Review in the review notes. Sample data only — never a real person's passcode.
    static let passcode = "246810"

    /// The `UserDefaults` bit that says this install is running the demo.
    static let isActiveKey = "reviewDemo.isActive"

    /// The demo persona's nearby-display name.
    static let personaName = "Alex"

    /// Whether this install is running the demo.
    static var isActive: Bool { UserDefaults.standard.bool(forKey: isActiveKey) }

    /// Whether the switches that would send data off this iPhone (iCloud sync, Apple Health) are held
    /// off: true for as long as the demo runs.
    static var blocksCloudAndHealth: Bool { isActive }

    /// What a held-off switch says instead of turning on.
    static let cloudAndHealthBlockedMessage = String(
        localized: "reviewDemo.blocked",
        defaultValue: "Not in demo mode: sample data stays on this iPhone. Leave the demo in Settings to set Fernlet up for real.",
        comment: "Demo mode: shown when someone tries to turn on iCloud sync or Apple Health while looking at sample data."
    )

    /// The persona onboarding commits: a 30-year-old woman, so the cycle section is on by default the
    /// way it is for anyone who answers Female, with today's defaults for everything else.
    static func persona(from profile: UserNutritionProfile) -> UserNutritionProfile {
        var persona = profile
        persona.age = 30
        persona.sex = .female
        persona.weightPounds = 145
        persona.heightInches = 66
        persona.activityLevel = .moderate
        return persona
    }

    /// Sets the demo passcode up for the Private hub, which also opens it, so the seeders can seal the
    /// cycle and intimacy entries with its content key.
    ///
    /// - Returns: the hub's content key, or nil when the lock could not be configured (logged).
    static func configureLock(_ lockService: FernletLockService) async -> SymmetricKey? {
        do {
            if lockService.isLockConfigured { try lockService.reset() }
            try await lockService.configure(credential: .pin6(passcode), grantingScope: .privateHub)
        } catch {
            FernletAuditLog.log("reviewDemo.lock.failed", context: ["error": "\(type(of: error))"])
            return nil
        }
        guard let key = lockService.contentKey(for: .privateHub) else {
            FernletAuditLog.log("reviewDemo.lock.noContentKey")
            return nil
        }
        return key
    }

    /// Plants the sample data and the pretend friend, closes the hub again so the passcode screen is
    /// the first thing the Private tab shows, and marks the demo running.
    static func seed(store: FernletStore, lockService: FernletLockService, key: SymmetricKey) async {
        await store.seedReviewDemo(privateHubKey: key)
        store.seedReviewDemoFriend()
        lockService.lock(reason: .manual)
        UserDefaults.standard.set(true, forKey: isActiveKey)
        FernletAuditLog.log("reviewDemo.started")
    }

    /// Leaves the demo: removes the pretend friend, erases everything the demo planted through the
    /// app's own delete-everything funnel, drops the demo passcode, and returns to the Welcome screen.
    ///
    /// The friend goes first: the delete-everything funnel deliberately keeps the photo wall (it is
    /// curated one photo at a time), so the friend's photos are removed by their own path.
    ///
    /// - Returns: whether the erase finished cleanly. On a partial erase the demo stays on, so the
    ///   person can try again rather than set up for real over leftover sample data.
    static func leave(store: FernletStore, lockService: FernletLockService) async -> Bool {
        store.removeReviewDemoFriend()
        let outcome = await store.deleteAllData(includingHealthKitSamples: false)
        guard outcome.isComplete else {
            FernletAuditLog.log("reviewDemo.leave.incomplete")
            return false
        }
        do {
            try lockService.reset()
        } catch {
            FernletAuditLog.log("reviewDemo.leave.lockReset.failed", context: ["error": "\(type(of: error))"])
        }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: isActiveKey)
        defaults.removeObject(forKey: OnboardingDefaults.lockSetupDeferredKey)
        // Last: `FernletApp` swaps back to onboarding on this key.
        defaults.removeObject(forKey: OnboardingDefaults.hasCompletedOnboardingKey)
        FernletAuditLog.log("reviewDemo.left")
        return true
    }
}
#endif
