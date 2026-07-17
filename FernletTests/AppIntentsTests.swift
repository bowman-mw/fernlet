import Foundation
import Testing
@testable import Fernlet

/// Tail #6 — App Intents. The Siri/Spotlight actions themselves run out-of-process, but the foreground
/// intents' deep-link (which sheet the app should open when it becomes active) is a plain persisted
/// hand-off worth pinning: it must be honored exactly once.
@MainActor
struct AppIntentsTests {
    @Test func pendingIntentSheetRoundTripsAndIsConsumedOnce() {
        PendingIntentSheet.request(.meal)
        #expect(PendingIntentSheet.consume() == .meal)
        // Consumed once — a second read finds nothing (so a stale request can't reopen the sheet later).
        #expect(PendingIntentSheet.consume() == nil)

        PendingIntentSheet.request(.journal)
        #expect(PendingIntentSheet.consume() == .journal)
        #expect(PendingIntentSheet.consume() == nil)
    }
}
