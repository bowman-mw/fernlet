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
///   next wave); nil drops them. Airport stamps never go there, whatever ``WorldLinePicker/stamps(for:in:)`` lists
///   (their banners are Home's own: one banner and one haptic for a landing).
/// - **Airport stamps** (``onAirportStamp``, World-Airports-Spec §3, §6.3): an airport's first visit and each new trip
///   through it, by token and date, for Home's airport banner (``WorldAirportHomeState``). An airport's first visit
///   also brings Sprout's new-airport line; a landing's line comes from Home through ``offer(_:)``.
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
    /// **The airport hook** for Home's airport banner: called once per airport stamp (a first visit or a new trip),
    /// with its token and date. Nil drops them.
    @ObservationIgnored var onAirportStamp: ((_ token: String, _ at: Date) -> Void)?
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
            if trip.kind == .airport { onAirportStamp?(trip.token, trip.date) } else { onNewStamp?(trip) }
            return
        }
        guard let discovery = event.discovery else { return }
        if discovery.kind == .airport { onAirportStamp?(discovery.token, discovery.at) }
        // An airport's stamp is Home's alone (one banner, one haptic: "Landed at Heathrow" never doubles as the
        // passport's "New stamp: Heathrow").
        for stamp in WorldLinePicker.stamps(for: discovery, in: book) where stamp.kind != .airport { onNewStamp?(stamp) }
        guard let next = WorldLinePicker.line(for: discovery, in: book, places: places, isDecoy: isDecoy) else { return }
        offer(next, now: now)
    }

    /// Puts `next` up as Sprout's line when it beats the waiting one (``WorldLinePicker/better(_:_:)``): a landing's
    /// line from Home (World-Airports-Spec §6.3) beats the new-airport line of the same reading.
    func offer(_ next: WorldDiscoveryLine, now: Date = Date()) {
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
