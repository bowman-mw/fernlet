import Foundation
import WorldMapStore

/// Holds the base map's reports back while SwiftUI is making or updating the map's view (issue desk W-15).
///
/// MapKit answers some writes at once: a camera it can apply without animating (a jump with Reduce Motion
/// on, or a camera it already shows, as when a panel closes while the map follows) calls the region
/// delegates before `setCamera` returns, and a style or margin change can start a tile load. Every such
/// write comes from `makeUIView` or `updateUIView`, so a report raised inside them would write SwiftUI
/// state (the stack's viewport, the tile status, the camera binding) while SwiftUI is still applying the
/// update ("Modifying state during view update"). Inside that stretch (``updating(_:)``) each report is
/// held and delivered on the next main-queue turn instead: the latest of each ``Channel`` only, and a
/// viewport only when it differs from the last one delivered. Outside it (a gesture, an animation's
/// frames) every report goes through at once, so the fog never lags the tiles.
@MainActor
final class WorldMapReportGate {
    /// What a report changes. One held report of each, the latest.
    enum Channel: CaseIterable {
        /// The visible area the layers draw from.
        case viewport
        /// The tiles' progress.
        case tiles
        /// The person's move written back to Fernlet's camera.
        case camera
    }

    /// Whether SwiftUI is making or updating the map's view now.
    private(set) var isUpdating = false
    /// The reports held during the update, by what they change: at most one per channel.
    private var held: [Channel: @MainActor () -> Void] = [:]
    /// Whether the held reports' delivery is already queued.
    private var flushQueued = false
    /// The last viewport delivered.
    private var lastViewport: MapViewport?
    /// Runs work on the next main-queue turn (a test steps it by hand).
    private let later: (@escaping @MainActor () -> Void) -> Void

    /// A gate delivering held reports through `later` (by default, the main queue's next turn).
    init(later: @escaping (@escaping @MainActor () -> Void) -> Void = { work in DispatchQueue.main.async { work() } }) {
        self.later = later
    }

    /// Runs `writes` (the map view's make or update) with every report raised inside it held.
    func updating(_ writes: () -> Void) {
        let outer = isUpdating
        isUpdating = true
        writes()
        isUpdating = outer
    }

    /// Hands `viewport` to `deliver`: now, or after the update when it is unchanged by then.
    func report(_ viewport: MapViewport, to deliver: @escaping @MainActor (MapViewport) -> Void) {
        let isHeld = isUpdating
        send(.viewport) { [weak self] in
            guard let self else { return }
            if isHeld, viewport == self.lastViewport { return }
            self.lastViewport = viewport
            deliver(viewport)
        }
    }

    /// Runs `work`, a report on `channel`: now outside an update (dropping any older one still held there),
    /// or held as that channel's latest until the next main-queue turn.
    func send(_ channel: Channel, _ work: @escaping @MainActor () -> Void) {
        guard isUpdating else {
            held[channel] = nil
            work()
            return
        }
        held[channel] = work
        queueFlush()
    }

    /// Queues one delivery of everything held.
    private func queueFlush() {
        guard !flushQueued else { return }
        flushQueued = true
        later { [weak self] in self?.flush() }
    }

    /// Delivers the held reports, one per channel in a fixed order; if an update is somehow under way
    /// again, waits for the turn after.
    private func flush() {
        flushQueued = false
        guard !isUpdating else {
            queueFlush()
            return
        }
        let waiting = held
        held = [:]
        for channel in Channel.allCases { waiting[channel]?() }
    }
}
