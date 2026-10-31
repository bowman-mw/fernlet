import Foundation
import UIKit

/// The Home Screen quick action "Take a trip" (World-Airports-Spec §7): hold Fernlet's icon, choose Take a trip, and
/// Home opens Fernlet's ticket. A dynamic shortcut (no Info.plist entry), installed by Home while "Airports and
/// flights" is on and removed while it is off; a decoy leaves it as it is and never opens the ticket. The action
/// carries nothing but its type: no destination, airport or place.
///
/// The path: iOS hands the item to ``FernletShortcutAppDelegate`` (a cold launch) or ``FernletShortcutSceneDelegate``
/// (a running app), ``handle(_:)`` asks the root for Home (`PendingIntentSheet.request(.home)`) and notes the request
/// in ``WorldTripShortcutInbox``, and Home's trip driver takes it once Home is in front (``WorldTripHomeDriver``).
enum WorldTripShortcut {
    /// The quick action's type (a token).
    static let type = "com.fernlet.world.takeATrip"

    /// Installs the quick action, or removes it with `enabled` false. Only Fernlet's own item is touched.
    static func install(enabled: Bool) {
        let others = (UIApplication.shared.shortcutItems ?? []).filter { $0.type != type }
        guard enabled else {
            if others.count != UIApplication.shared.shortcutItems?.count { UIApplication.shared.shortcutItems = others }
            return
        }
        let item = UIApplicationShortcutItem(type: type, localizedTitle: String(localized: WorldTripCopy.takeATrip),
                                             localizedSubtitle: nil,
                                             icon: UIApplicationShortcutIcon(systemImageName: "suitcase.rolling"), userInfo: nil)
        UIApplication.shared.shortcutItems = others + [item]
    }

    /// Takes a quick action iOS handed over; whether it was Take a trip.
    @discardableResult
    static func handle(_ item: UIApplicationShortcutItem) -> Bool {
        handle(type: item.type)
    }

    /// Takes a quick action by its type; whether it was Take a trip.
    @discardableResult
    static func handle(type itemType: String) -> Bool {
        guard itemType == type else { return false }
        PendingIntentSheet.request(.home)
        WorldTripShortcutInbox.shared.request()
        return true
    }
}

/// The one pending Take a trip request, in memory until Home takes it (within ``expiry``, so a stale one never opens
/// the ticket later). Main actor.
final class WorldTripShortcutInbox {
    /// The app's one inbox.
    static let shared = WorldTripShortcutInbox()
    /// Posted when a request arrives, for a Home already on screen.
    static let notification = Notification.Name("fernlet.world.trip.shortcut")
    /// A request older than this is dropped.
    static let expiry: TimeInterval = 120

    private var requestedAt: Date?

    /// Notes a request now and tells Home.
    func request(at date: Date = Date()) {
        requestedAt = date
        NotificationCenter.default.post(name: Self.notification, object: nil)
    }

    /// Whether a fresh request waits; taking it clears it.
    func take(now: Date = Date()) -> Bool {
        guard let requestedAt else { return false }
        self.requestedAt = nil
        return now.timeIntervalSince(requestedAt) <= Self.expiry
    }
}

/// The app delegate, for the quick action only: a cold launch's shortcut item, and the scene delegate that hears a
/// running app's.
final class FernletShortcutAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem { WorldTripShortcut.handle(item) }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = FernletShortcutSceneDelegate.self
        return configuration
    }
}

/// Hears a quick action while Fernlet is running (SwiftUI keeps its own window). The item's type alone crosses to
/// the main actor.
final class FernletShortcutSceneDelegate: NSObject, UIWindowSceneDelegate {
    nonisolated func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem) async -> Bool {
        let type = shortcutItem.type
        return await MainActor.run { WorldTripShortcut.handle(type: type) }
    }
}
