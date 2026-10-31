import FernletUI
import SwiftUI
import WorldMapStore

/// Home's Take a trip moments (World-Airports-Spec §5, §7, §10.7), held by Home for as long as its map lives: the
/// ticket or the boarding pass over the map, and today's calendar flight at the airport the person is at. Main
/// actor; in memory only (the destination itself is the keeper's, sealed).
@MainActor
@Observable
final class WorldTripHomeState {
    /// Fernlet's ticket, while it is open.
    var ticket: WorldTripTicketRequest?
    /// Sprout's boarding pass, while it is open.
    var pass: WorldBoardingPass?
    /// Today's calendar flight from this airport, while the person is at it and no trip is on.
    private(set) var today: WorldTripToday?
    /// The calendar flights Sprout has spoken of this run ("Honolulu today? Your ticket's ready!" once).
    @ObservationIgnored private var spoken: Set<String> = []

    /// The most flights remembered as spoken (a bound).
    static let maxSpoken = 32

    /// "Trip to Honolulu", for the blue button's label, while today's flight applies.
    var todayLabel: String? { today.map { WorldTripCopy.tripTo($0.city) } }

    /// Take a trip: the ticket, with what today's calendar flight fills in (never in a decoy).
    func openTicket(_ store: FernletStore) {
        guard store.worldMayTakeTrip else { return }
        pass = nil
        ticket = store.worldTicketRequest(today: today)
    }

    /// A found airport's tower: Sprout's boarding pass for it.
    func openPass(_ store: FernletStore, at airport: WorldAirport) {
        guard ticket == nil else { return }
        pass = store.worldBoardingPass(at: airport)
    }

    /// Start trip: the trip starts with `destination`, the ticket closes, and VoiceOver hears it.
    func start(_ store: FernletStore, to destination: WorldTripDestination?) {
        ticket = nil
        guard store.startWorldTrip(to: destination) else { return }
        today = nil
        FernletFeedback.system.play(.done)
        FernletAnnouncer.system.announce(.success, resolved: String(localized: WorldTripCopy.started))
    }

    /// End trip.
    func end(_ store: FernletStore) {
        store.endWorldTrip()
        FernletAnnouncer.system.announce(.status, resolved: String(localized: WorldTripCopy.ended))
    }

    /// Reads today's calendar flight again; returns Sprout's line when it is one not spoken of yet.
    func readToday(_ store: FernletStore) -> String? {
        let next = store.worldTripToday()
        if today != next { today = next }
        guard let next else { return nil }
        let key = "\(next.destination)@\(next.departure.timeIntervalSince1970)"
        guard !spoken.contains(key) else { return nil }
        if spoken.count >= Self.maxSpoken { spoken.removeAll() }
        spoken.insert(key)
        return WorldTripCopy.todayLine(next.city)
    }

    /// A decoy began or ended: whatever was open goes.
    func closeAll() {
        ticket = nil
        pass = nil
    }
}

/// Runs Home's Take a trip moments (§5, §7, §10.7): draws the ticket and the boarding pass over Home, reads today's
/// calendar flight when the airport or the trip changes (Sprout's line once, through Home's greeting slot), takes the
/// Home Screen quick action once Home is in front, and keeps that quick action installed while "Airports and
/// flights" is on. Nothing in a decoy. DEBUG `FERNLET_UI_TEST_TRIP` stages screens 6, 16, 17 and 29.
struct WorldTripHomeDriver: ViewModifier {
    let store: FernletStore
    let trip: WorldTripHomeState
    /// Home's greeting slot: Sprout's "Honolulu today? Your ticket's ready!" goes there once.
    @Binding var greeting: String?
    /// Whether the map is what the person sees.
    let isFrontmost: Bool
    /// Opens the blue button's card (the DEBUG card scenes).
    let openCard: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay { overlays }
            .onChange(of: todaySource, initial: true) { readToday() }
            .onChange(of: isFrontmost) { _, front in if front { takeShortcut() } }
            .onChange(of: store.duressSessionActive) { trip.closeAll() }
            .onReceive(NotificationCenter.default.publisher(for: WorldTripShortcutInbox.notification)) { _ in takeShortcut() }
            .onAppear(perform: appeared)
            .task { await applyTestScene() }
    }

    @ViewBuilder
    private var overlays: some View {
        if !store.duressSessionActive {
            if let ticket = trip.ticket {
                WorldTripTicketOverlay(request: ticket, companion: WorldRecenterCopy.companionName(store),
                                       search: { store.worldTripSuggestions($0, limit: $1) },
                                       onStart: { trip.start(store, to: $0) }, onCancel: { trip.ticket = nil })
                    .id(ticket.id)
                    .transition(.opacity)
            } else if let pass = trip.pass {
                WorldBoardingPassOverlay(pass: pass, companion: WorldRecenterCopy.companionName(store)) { trip.pass = nil }
                    .transition(.opacity)
            }
        }
    }

    /// What today's calendar flight depends on: the airport, the trip, the flight and the map in front.
    private var todaySource: [String] {
        let flights = store.worldLocation.flights
        return [flights.currentAirport ?? "", flights.isOnTrip ? "trip" : "", flights.isFlying ? "air" : "",
                isFrontmost ? "front" : "", store.duressSessionActive ? "decoy" : ""]
    }

    /// Home appeared: the quick action's install, and any request that launched the app.
    private func appeared() {
        if !store.duressSessionActive { WorldTripShortcut.install(enabled: store.keepsWorldAirportsAndFlights()) }
        takeShortcut()
    }

    /// Today's flight again; Sprout's line once, while the map is in front.
    private func readToday() {
        guard isFrontmost, let line = trip.readToday(store) else { return }
        greeting = line
    }

    /// The quick action's request, once Home is in front: the ticket (never in a decoy).
    private func takeShortcut() {
        guard isFrontmost, !store.duressSessionActive, WorldTripShortcutInbox.shared.take() else { return }
        trip.openTicket(store)
    }

    /// DEBUG `FERNLET_UI_TEST_TRIP`: the card, the ticket with "Lon" typed, or the pass at the airport, a few seconds
    /// after Home opens (the airport scene's state is in by then). Display only; nothing in Release or a decoy.
    private func applyTestScene() async {
        guard let scene = UITestSupport.tripScene, !store.duressSessionActive else { return }
        do {
            try await Task.sleep(for: .seconds(4))
        } catch {
            return
        }
        switch scene {
        case "card", "endcard":
            openCard()
        case "ticket":
            var request = store.worldTicketRequest(today: nil)
            request.text = "Lon"
            trip.ticket = request
        case "pass":
            if let airport = store.worldCurrentAirport { trip.openPass(store, at: airport) }
        default:
            break
        }
    }
}
