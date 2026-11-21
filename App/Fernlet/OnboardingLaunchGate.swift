import Foundation

/// Decides whether the ready scene shows the app, onboarding, or a "unlock your iPhone" wait, so
/// a launch that cannot read its own records never reads as a new person.
///
/// **Why it exists (owner's bug, 2026-11-20: "every so often, the onboarding screen shows up
/// instead of the app").** The completion bit lives in `UserDefaults.standard`, whose file iOS
/// keeps closed until the first unlock after a restart. A process iOS starts before that unlock —
/// a location relaunch for drives (#141), a background refresh, a prewarm — reads the whole domain
/// as empty, and `@AppStorage` holds that `false` for the life of the process. When the person
/// later taps the icon, that same process is brought forward and shows onboarding.
///
/// The store carries the same fact in its own settings (`FernletSettings.hasCompletedOnboarding`,
/// stamped by `completeOnboarding` since the first build), and the store loads only with protected
/// data available (`FernletStoreLoader.wasRefusedWhileLocked`), so it is the durable second
/// witness. Either witness saying "finished" shows the app; neither saying so while the phone is
/// still locked waits rather than guessing.
///
/// **A decision, once made from a real read, holds** (``settle(current:next:)``): an iCloud pull
/// that lands while a genuinely new person is mid-onboarding must not yank them into the app, and a
/// person in the app must never be dropped into onboarding by a later read.
nonisolated struct OnboardingLaunchGate {
    /// What the ready scene shows.
    enum Decision: Equatable {
        /// The app (`ContentView`).
        case app
        /// Onboarding. `existingSetup` is true when a Fernlet passcode already exists on this phone
        /// though nothing says onboarding finished: the flow then offers "Continue to Fernlet" and
        /// skips its lock step, so it can never be asked to replace that lock.
        case onboarding(existingSetup: Bool)
        /// Neither witness says "finished" and the phone is still locked, so nothing can be told
        /// yet: the launch screen asks for an unlock and the next unlock edge decides again.
        case waitForUnlock
    }

    /// The facts one launch edge read.
    struct Evidence: Equatable {
        /// `UserDefaults.standard`'s `hasCompletedOnboarding` — `false` both when never set and when
        /// the domain was unreadable at the read, which is why it never decides "new person" alone.
        var defaultsSayFinished: Bool
        /// The loaded store's `settings.hasCompletedOnboarding`.
        var settingsSayFinished: Bool
        /// `UIApplication.isProtectedDataAvailable` at the edge.
        var protectedDataAvailable: Bool
        /// Whether a Fernlet passcode exists, read after `refreshStateFromKeychain()`.
        var passcodeConfigured: Bool
    }

    /// The pure decision table.
    ///
    /// - Parameter evidence: What this edge read.
    /// - Returns: `.app` when either witness says finished; `.waitForUnlock` when neither does and
    ///   protected data is unavailable; otherwise `.onboarding`, marked as an existing setup when a
    ///   passcode exists.
    static func decide(_ evidence: Evidence) -> Decision {
        if evidence.defaultsSayFinished || evidence.settingsSayFinished { return .app }
        guard evidence.protectedDataAvailable else { return .waitForUnlock }
        return .onboarding(existingSetup: evidence.passcodeConfigured)
    }

    /// Folds a fresh decision into the one on screen.
    ///
    /// No decision yet, or a wait: the fresh one takes over. `.app` holds against anything — only
    /// an explicit reset (``FernletApp``'s completion-flag drop, the Review demo's "Leave") starts
    /// over, and it passes `current: nil`. `.onboarding` gives way to `.app` alone, and only when
    /// the device's own completion bit says so — which onboarding's own finish writes — never to an
    /// iCloud settings pull arriving mid-flow.
    ///
    /// - Parameters:
    ///   - current: The decision on screen, or `nil` before the first one.
    ///   - next: The fresh decision.
    ///   - evidence: The facts `next` was made from.
    /// - Returns: The decision to show.
    static func settle(current: Decision?, next: Decision, evidence: Evidence) -> Decision {
        switch current {
        case nil, .waitForUnlock?:
            return next
        case .app?:
            return .app
        case .onboarding(let existingSetup)?:
            return evidence.defaultsSayFinished ? .app : .onboarding(existingSetup: existingSetup)
        }
    }

    /// Whether this edge should rewrite the device's completion bit: the store says onboarding
    /// finished, the bit read `false`, and the phone is unlocked so the write can land. Heals a
    /// domain a locked launch saw as empty, so the next cold launch decides on its first witness.
    ///
    /// - Parameter evidence: What this edge read.
    /// - Returns: `true` when the bit should be set.
    static func shouldHealDefaults(_ evidence: Evidence) -> Bool {
        evidence.settingsSayFinished && !evidence.defaultsSayFinished && evidence.protectedDataAvailable
    }
}
