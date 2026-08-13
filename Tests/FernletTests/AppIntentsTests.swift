import Foundation
import Testing
@testable import Fernlet

/// Tail #6 — App Intents. The Siri/Spotlight actions themselves run out-of-process, but the foreground
/// intents' deep-link (which sheet the app should open when it becomes active) is a plain persisted
/// hand-off worth pinning: it must be honored exactly once, and only for a short window.
///
/// A `final class` (not a struct) so `deinit` can act as teardown: the token is backed by the host's real
/// `UserDefaults.standard`, so a token left behind by a failing test would otherwise leak into a later
/// test or run. `init`/`deinit` drain it before and after every test to keep the suite hermetic.
@MainActor
final class AppIntentsTests {
    init() { _ = PendingIntentSheet.consume() }
    deinit { _ = PendingIntentSheet.consume() }  // nonisolated static func — safe from deinit

    @Test func pendingIntentSheetRoundTripsAndIsConsumedOnce() {
        PendingIntentSheet.request(.meal)
        #expect(PendingIntentSheet.consume() == .meal)
        // Consumed once — a second read finds nothing (so a stale request can't reopen the sheet later).
        #expect(PendingIntentSheet.consume() == nil)

        PendingIntentSheet.request(.journal)
        #expect(PendingIntentSheet.consume() == .journal)
        #expect(PendingIntentSheet.consume() == nil)
    }

    /// A token stranded past the expiry window (onboarding still up, app killed under a covering sheet,
    /// …) must be discarded rather than misfiring arbitrarily far in the future. Against the old
    /// timestamp-less token this would have returned `.meal` regardless of age.
    @Test func expiredPendingIntentSheetIsDiscarded() {
        // Just past the 120s window.
        PendingIntentSheet.request(.meal, createdAt: Date().addingTimeInterval(-125))
        #expect(PendingIntentSheet.consume() == nil)
        // Discarding still clears the slot, so a later request isn't shadowed by the stale one.
        #expect(PendingIntentSheet.consume() == nil)

        // A token comfortably within the window is still honored.
        PendingIntentSheet.request(.journal, createdAt: Date().addingTimeInterval(-30))
        #expect(PendingIntentSheet.consume() == .journal)
    }
}
