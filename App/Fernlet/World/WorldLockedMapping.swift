import FernletFoundation
import Foundation
import WorldMapStore

/// Background mapping before the store (owner 2026-11-09, "Fix it next": trips dropped when iOS relaunched a closed
/// Fernlet with the phone locked).
///
/// The store can't load while the phone is locked (`FernletStoreAccess` refuses: most of Fernlet's files are sealed
/// with Complete protection). So when iOS relaunched a closed Fernlet in the background with the phone locked, for the
/// leaving fence, a significant change or a Focus filter, no store was built, and background mapping did nothing
/// until the person unlocked and opened the app. This starts just the map's location, at launch, before the store:
///
/// - **Only when** the phone is locked at launch and background mapping's marker is there
///   (`WorldMapPreferences.backgroundMappingMarked()`, a file readable whatever the lock); the source answers "is
///   background mapping on?" from the marker too.
/// - **What runs:** a ``WorldLocationSource`` with its flight gate and car and bike detection, and a ``WorldFogKeeper``
///   that is never loaded, so every lift goes into the locked-phone buffer, written under the buffer key the phone
///   allows after its first unlock, and merges at the store's next load. Motion is read when allowed. The car book
///   learns nothing (it may have read nothing). A road trip's book is read (the buffer key): a passenger traces no
///   drive, and the iPhone that maps keeps appending its line (``RoadTripKeeper``).
/// - **What waits:** visits for Where you've been, bike-ride logging, flights and the passport, which all need the
///   store (the motion history's catch-up still finds the rides; the airport gate re-hands a missed find).
/// - **Hand-over:** the store's own location source is this one (``handOver()``), wired to everything once the phone
///   unlocks and the store loads, so there is only ever one location manager and a drive, a fence or a listen under
///   way carries on.
@MainActor
final class WorldLockedMappingHolder {
    /// The source running before the store; nil until a locked launch starts one, and after the hand-over.
    private(set) var source: WorldLocationSource?
    /// Its fog keeper, which only buffers.
    private var fog: WorldFogKeeper?
    /// Whether background mapping's marker is there (the file by default; tests answer for it).
    private let isMarked: @MainActor () -> Bool
    /// The vault the fog keeper buffers into (the app's by default; tests pass an ephemeral one).
    private let vault: @MainActor () -> WorldMapVault

    /// A holder reading `isMarked` and buffering into `vault` (the app's marker and vault when nil).
    init(isMarked: (@MainActor () -> Bool)? = nil, vault: (@MainActor () -> WorldMapVault)? = nil) {
        self.isMarked = isMarked ?? { WorldMapPreferences.backgroundMappingMarked() }
        self.vault = vault ?? { WorldMapVault.production() }
    }

    /// Starts the map's location before the store when the phone is locked at launch (`protectedData` false); a
    /// no-op otherwise.
    func startIfLocked(protectedData: Bool) {
        guard !protectedData else { return }
        start()
    }

    /// Starts it whatever the lock (a drive hint that found no store), and returns it; nil without background
    /// mapping's marker. A no-op returning the running one when it has already started.
    @discardableResult
    func start() -> WorldLocationSource? {
        if let source { return source }
        guard isMarked() else { return nil }
        let mapVault = vault()
        let keeper = WorldFogKeeper(vault: mapVault)
        let marked = isMarked
        let started = WorldLocationSource(backgroundMapping: { marked() })
        started.onFix = { [weak keeper, weak started] fix in
            keeper?.handle(fix, saveNow: true, thinLine: started?.rides.isDriving ?? false)
        }
        started.rides.usesMotion = started.rides.motion.permission == .allowed
        started.cars.isDecoy = true
        started.flights.attach(vault: mapVault)
        // A road trip's book and line are under the buffer key: a passenger traces no drive, and the iPhone that maps
        // keeps its line through the fog keeper (owner-approved 2026-11-10).
        keeper.roadTrip.load()
        keeper.roadTrip.onPassengerChanged = { [weak started] passenger in started?.setRoadTripPassenger(passenger) }
        started.setRoadTripPassenger(keeper.roadTrip.isPassenger)
        fog = keeper
        source = started
        FernletAuditLog.log("worldMap.lockedLaunch.started")
        return started
    }

    /// Hands the running source to the store, which wires it to everything and lets its car book learn again; the
    /// buffering fog keeper goes (what it buffered merges at the store's next load), after writing a road trip's
    /// unsaved points for the store's keeper to read. Nil when none was started.
    func handOver() -> WorldLocationSource? {
        guard let handed = source else { return nil }
        fog?.roadTrip.flush()
        source = nil
        fog = nil
        FernletAuditLog.log("worldMap.lockedLaunch.handedOver")
        return handed
    }
}

/// The app's one holder: the launch starts it, the store's location source is taken from it.
@MainActor
enum WorldLockedMapping {
    /// The holder the launch and the store share.
    static let shared = WorldLockedMappingHolder()
}
