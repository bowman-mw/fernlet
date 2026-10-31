import FernletFoundation
import Foundation
import SwiftUI
import WorldMapStore

/// Keeps watching the calendar while "Flights from Calendar" is on (World-Airports-Spec §10.6, the owner's
/// "keep watching; option a"): each time Fernlet opens, and each time the calendar changes while it's open
/// (`EKEventStoreChanged`), one look from 2 days ago to 60 days ahead (``CalendarFlightLooker/keepWatching(now:)``).
/// A passed upcoming flight joins the Flights page; a moved or cancelled one is followed.
///
/// - **One look at a time:** an open while a look runs adds nothing.
/// - **Access taken away** in iOS Settings turns the switch back off (spec §10.2); flights already found stay.
/// - **Nothing is made until it's needed:** the EventKit source (and its event store) is made on the first look
///   the gates allow, so a person who never turns Calendar on never has one.
/// - **A decoy** never reads the calendar (the looker's gate), and nothing here reaches a widget or notification.
@MainActor
final class CalendarFlightWatcher {
    private let mayRead: () -> Bool
    private let makeLooker: () -> CalendarFlightLooker?
    private let defaults: UserDefaults
    private var looker: CalendarFlightLooker?
    private var task: Task<Void, Never>?

    /// A watcher that looks when `mayRead` says it may, through the looker `makeLooker` makes on first use (nil
    /// once there's no store to look for).
    init(mayRead: @escaping () -> Bool, makeLooker: @escaping () -> CalendarFlightLooker?,
         defaults: UserDefaults = .standard) {
        self.mayRead = mayRead
        self.makeLooker = makeLooker
        self.defaults = defaults
    }

    /// The store's watcher: its gates, and EventKit.
    convenience init(store: FernletStore) {
        self.init(mayRead: { [weak store] in store?.mayReadWorldCalendar() ?? false },
                  makeLooker: { [weak store] in store?.worldCalendarLooker(source: EventKitCalendarSource()) })
    }

    /// A look that's still running ends with the watcher.
    isolated deinit {
        task?.cancel()
    }

    /// Whether a look is running.
    var isLooking: Bool { task != nil }

    /// Looks now, unless one is running or the gates are shut.
    func look(now: Date = Date()) {
        guard task == nil, mayRead(), let looker = looker ?? makeLooker() else { return }
        self.looker = looker
        task = Task { [weak self] in
            let problem = await looker.keepWatching(now: now)
            self?.finished(problem)
        }
    }

    /// Waits for the running look (tests).
    func settle() async {
        await task?.value
    }

    private func finished(_ problem: CalendarLookProblem?) {
        task = nil
        guard problem == .notAllowed else { return }
        WorldMapPreferences.setReadsCalendarFlights(false, in: defaults)
        FernletAuditLog.log("worldMap.calendar.accessGone")
    }
}

extension View {
    /// Keeps watching the calendar for flights (spec §10.6) from the app's root: a look once the launch screen has
    /// lifted (`isReady`), each time the app comes back to the front, and each time the calendar changes while
    /// it's in front. Every look passes the store's gates (both switches on, no decoy).
    func worldCalendarFlights(store: FernletStore, isReady: Bool) -> some View {
        modifier(CalendarFlightsWatch(store: store, isReady: isReady))
    }
}

/// Implements ``SwiftUI/View/worldCalendarFlights(store:isReady:)``; holds the app's one watcher.
private struct CalendarFlightsWatch: ViewModifier {
    let store: FernletStore
    let isReady: Bool
    @State private var watcher: CalendarFlightWatcher?
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: isReady, initial: true) { _, ready in
                if ready { look() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { look() }
            }
            .onReceive(NotificationCenter.default.publisher(for: EventKitCalendarSource.changedNotification)) { _ in
                if scenePhase == .active { look() }
            }
    }

    private func look() {
        guard isReady else { return }
        let watcher = watcher ?? CalendarFlightWatcher(store: store)
        self.watcher = watcher
        watcher.look()
    }
}
