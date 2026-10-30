import Foundation
import WorldMapStore

/// The one reader of the passport's discoveries (World-Exploration-Spec §4; `WorldAtlasKeeper.discoveries()` allows
/// one reader, and a second subscription would end the first). Held by Home for as long as Home's map lives, it
/// listens once and fans each ``PassportEvent`` out:
///
/// - **Sprout's lines** from first visits only (``line``, ``WorldLinePicker``): one line at a time, the best of one
///   fix's finds (``WorldLinePicker/better(_:_:)``: a city beats the ground under it). A new trip says nothing.
///   Landmark lines come from here and only here: `WorldExploreState.onLandmarkFound` (the cities piece's seam)
///   stays unattached, so a landmark's line plays once.
/// - **New stamps** (``onNewStamp``): every first-visit country, continent, ocean and sea stamp, the two specials on
///   the visit that completes them, and each ``PassportEvent/newTrip(_:)``. The passport book attaches here (the
///   next wave); nil drops them.
///
/// A decoy hears nothing: the keeper announces nothing in one, and the router checks again.
@MainActor
@Observable
final class WorldDiscoveryRouter {
    /// The line Sprout says now, until Home has shown it (``clearLine()``).
    private(set) var line: WorldDiscoveryLine?
    /// When ``line`` arrived, so a line that waited too long behind a panel is dropped rather than said late.
    @ObservationIgnored private(set) var lineArrived: Date?
    /// **The new-stamp hook** for the passport book: called once per stamp a discovery earns, in the order earned.
    /// Nil-safe: nothing listens yet.
    @ObservationIgnored var onNewStamp: ((PassportStamp) -> Void)?
    /// Whether ``listen(to:places:isDecoy:)`` is running (a second call returns at once).
    @ObservationIgnored private var isListening = false

    /// How long a line may wait to be said before it goes stale (a panel was up when the place was found).
    static let staleAfter: TimeInterval = 15 * 60

    /// Reads `keeper`'s discoveries until the task is cancelled, routing each (``route(_:book:places:isDecoy:)``).
    /// One listener at a time; ends the stream when it stops.
    func listen(to keeper: WorldAtlasKeeper, places: WorldDiscoveryPlaces, isDecoy: @escaping @MainActor () -> Bool) async {
        guard !isListening else { return }
        isListening = true
        defer {
            isListening = false
            keeper.endDiscoveries()
        }
        for await event in keeper.discoveries() {
            route(event, book: keeper.book, places: places, isDecoy: isDecoy())
        }
    }

    /// Routes one event: a first visit's line (kept when it beats the line of the same fix) and stamps, or a new
    /// trip's stamp. Nothing in a decoy.
    func route(_ event: PassportEvent, book: PassportBook, places: WorldDiscoveryPlaces, isDecoy: Bool,
               now: Date = Date()) {
        guard !isDecoy else { return }
        if let trip = event.trip {
            onNewStamp?(trip)
            return
        }
        guard let discovery = event.discovery else { return }
        for stamp in WorldLinePicker.stamps(for: discovery, in: book) { onNewStamp?(stamp) }
        guard let next = WorldLinePicker.line(for: discovery, in: book, places: places, isDecoy: isDecoy) else { return }
        let chosen = WorldLinePicker.better(line, next)
        guard chosen != line else { return }
        line = chosen
        lineArrived = now
    }

    /// The line has been said (or went stale): Sprout's usual line comes back.
    func clearLine() {
        line = nil
        lineArrived = nil
    }

    /// Whether the waiting line is too old to say at `now`.
    func isStale(at now: Date = Date()) -> Bool {
        guard let lineArrived else { return false }
        return now.timeIntervalSince(lineArrived) > Self.staleAfter
    }

    /// DEBUG: puts `line` up as if a discovery had found it (the lines shots).
    func stage(_ line: WorldDiscoveryLine) {
        self.line = line
        lineArrived = Date()
    }
}
