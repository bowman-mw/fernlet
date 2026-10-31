import FernletUI
import SwiftUI
import WorldMapStore

/// Home's airport moments (World-Airports-Spec §3, §6.3), held by Home for as long as its map lives: the airport
/// banner waiting or showing over the map, chosen when the passport stamps an airport (``noteStamp(token:at:find:airport:book:atlas:companion:)``).
/// Main actor; nothing here is written anywhere.
@MainActor
@Observable
final class WorldAirportHomeState {
    /// The airport banner to show, until it has had its window or was tapped.
    var banner: WorldAirportBannerModel?
    /// The banners that have played their haptic (a landing's one firm tap, once even if the banner comes back).
    @ObservationIgnored private var buzzed: Set<String> = []

    /// An airport stamp from the passport (a first visit or a new trip at `date`): its banner, as `find` (the gate's
    /// latest) tells how it was found. Nothing for an airport the list doesn't hold.
    func noteStamp(token: String, at date: Date, find: WorldAirportFind?, airport: WorldAirport?, book: PassportBook,
                   atlas: WorldAtlas?, companion: String) {
        guard let airport else { return }
        let how = WorldAirportMoments.how(token: token, at: date, latest: find)
        let continent = how == .landing ? WorldAirportMoments.waitingContinent(of: airport, book: book, atlas: atlas) : nil
        let country = how == .landing ? WorldAirportMoments.waitingCountry(of: airport, book: book) : nil
        banner = WorldAirportBannerModel.make(airport: airport, how: how, at: date, continent: continent.map { String(localized: $0.passportName) },
                                              countryCode: country, companion: companion)
    }

    /// Whether `banner` should buzz now: a landing's, the first time it shows.
    func takesHaptic(_ banner: WorldAirportBannerModel) -> Bool {
        guard banner.isLanding, !buzzed.contains(banner.id) else { return false }
        if buzzed.count >= 32 { buzzed.removeAll() }
        buzzed.insert(banner.id)
        return true
    }
}

/// The pure parts of Home's airport moments: how a stamp was found, which stamps a landing leaves waiting, and
/// which landing line is next.
nonisolated enum WorldAirportMoments {
    /// The most flights Home counts for the landing line's turn (a bound on the count).
    static let maxFlightsCounted = 10_000

    /// How the airport stamped at `date` was found: the gate's latest find when it is the same airport at the same
    /// reading (a landing's stamp carries the landing's time), else unknown.
    static func how(token: String, at date: Date, latest: WorldAirportFind?) -> FlightFinding? {
        guard let latest, latest.token == token, abs(latest.at.timeIntervalSince(date)) < 1 else { return nil }
        return latest.how
    }

    /// The airport's country, when the passport doesn't hold it yet (it stamps when the person leaves the grounds).
    static func waitingCountry(of airport: WorldAirport, book: PassportBook) -> String? {
        let code = airport.countryCode.uppercased()
        guard !code.isEmpty, book.firstVisit(.country, token: code) == nil else { return nil }
        return code
    }

    /// The airport's continent, when the passport doesn't hold it yet.
    static func waitingContinent(of airport: WorldAirport, book: PassportBook, atlas: WorldAtlas?) -> AtlasContinent? {
        guard let continent = atlas?.continent(at: airport.point),
              book.firstVisit(.continent, token: continent.rawValue) == nil else { return nil }
        return continent
    }

    /// The landing line's turn: Fernlet's own flights so far, counting this one, take the three lines in turn.
    static func landingTurn(fernletFlights: Int) -> Int {
        max(fernletFlights - 1, 0) % WorldDiscoveryLine.linesPerCategory
    }

    /// Sprout's line for `find`, when it is a landing: the next landing line, dated by the landing (so it beats the
    /// new-airport line of the same reading).
    static func landingLine(for find: WorldAirportFind?, fernletFlights: Int) -> WorldDiscoveryLine? {
        guard let find, find.how == .landing else { return nil }
        return WorldDiscoveryLine(category: .landing, index: landingTurn(fernletFlights: fernletFlights), name: "", at: find.at)
    }
}

/// One airport banner (§3, §6.3), its words fixed when it was made.
struct WorldAirportBannerModel: Identifiable, Equatable {
    let token: String
    let at: Date
    /// "New stamp: Portland International", "Landed at Heathrow".
    let title: String
    /// Its second line.
    let detail: String
    /// Whether it greets a landing (one firm haptic).
    let isLanding: Bool
    var id: String { "\(token)@\(at.timeIntervalSince1970)" }

    /// The banner for `airport` stamped at `date`, found `how`: a landing's ("Landed at Heathrow", with the
    /// continent's and country's stamps that wait, `continent` by name and `countryCode`), ten minutes' ("New stamp:
    /// Portland International", "Ten minutes at the airport found it. It's in Sprout's passport."), or any other
    /// find's ("It's in Sprout's passport.").
    static func make(airport: WorldAirport, how: FlightFinding?, at date: Date, continent: String?, countryCode: String?,
                     companion: String) -> WorldAirportBannerModel {
        let name = WorldAirportCopy.name(airport)
        switch how {
        case .landing:
            let country = countryCode.map { WorldAirportCopy.bannerCountry(code: $0, atStart: continent == nil) }
            return WorldAirportBannerModel(token: airport.token, at: date, title: WorldAirportCopy.landedTitle(name),
                                           detail: WorldAirportCopy.landedDetail(name, continent: country == nil ? nil : continent,
                                                                                 country: country, companion: companion),
                                           isLanding: true)
        case .dwell:
            return WorldAirportBannerModel(token: airport.token, at: date, title: String(localized: PassportNewStampCopy.title(name)),
                                           detail: WorldAirportCopy.dwellDetail(companion: companion), isLanding: false)
        default:
            return WorldAirportBannerModel(token: airport.token, at: date, title: String(localized: PassportNewStampCopy.title(name)),
                                           detail: String(localized: PassportNewStampCopy.detail(companion: companion)), isLanding: false)
        }
    }
}

/// Runs Home's airport moments (World-Airports-Spec §3, §6.3): hears every airport stamp from the passport's one
/// discovery reader (``WorldDiscoveryRouter/onAirportStamp``) and shows its banner in the stamp banner's slot (the
/// root's `b1-stamp-banner` place and rules: never over the camera, while riding along, under the root's own
/// stamp banner, while the passport is open, or in a decoy); and at each landing the gate reports
/// (``WorldFlightKeeper/latestFind``) offers Sprout's next landing line, which beats the new-airport line of the
/// same reading. DEBUG `FERNLET_UI_TEST_AIRPORT` stages screen 1's and screen 9's banner and line.
struct WorldAirportHomeDriver: ViewModifier {
    let store: FernletStore
    let router: WorldDiscoveryRouter
    let state: WorldAirportHomeState
    let passport: WorldPassportPresenter?
    /// Whether the banner waits: Home behind a panel, the camera or riding along, or the root's stamp banner up.
    let holdsBanner: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) { bannerSlot }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: shownBanner)
            .onAppear(perform: attach)
            .onChange(of: store.worldLocation.flights.latestFind) { _, find in offerLandingLine(find) }
            .task { await applyTestScene() }
    }

    /// The banner shown now, if any.
    private var shownBanner: WorldAirportBannerModel? {
        guard !holdsBanner, passport?.isPresented != true, !store.duressSessionActive else { return nil }
        return state.banner
    }

    @ViewBuilder
    private var bannerSlot: some View {
        if let banner = shownBanner {
            WorldAirportBanner(model: banner, onOpen: { open(banner) }, onShown: { shown(banner) },
                               onAppear: { if state.takesHaptic(banner) { FernletFeedback.system.play(.held) } })
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .frame(maxWidth: 352)
                .padding(.horizontal, 16)
                .padding(.top, dynamicTypeSize.isAccessibilitySize ? 150 : 112)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .id(banner.id)
        }
    }

    /// Listens for airport stamps on the one discovery reader (nothing reaches it in a decoy).
    private func attach() {
        let store = store, state = state
        router.onAirportStamp = { [weak state] token, date in
            guard !store.duressSessionActive else { return }
            let flights = store.worldLocation.flights
            state?.noteStamp(token: token, at: date, find: flights.latestFind,
                             airport: flights.airportsShelf.pack()?.airport(token: token),
                             book: WorldExploreState.book(store), atlas: store.worldFog.atlas.openedAtlas,
                             companion: WorldRecenterCopy.companionName(store))
        }
    }

    /// A landing just reported: Sprout's next landing line (never in a decoy).
    private func offerLandingLine(_ find: WorldAirportFind?) {
        guard !store.duressSessionActive else { return }
        let flights = WorldExploreState.book(store).flights.prefix(WorldAirportMoments.maxFlightsCounted)
        let own = flights.filter { $0.sources.contains(.fernlet) }.count
        if let line = WorldAirportMoments.landingLine(for: find, fernletFlights: own) { router.offer(line) }
    }

    /// The banner's tap: it goes, and the passport opens.
    private func open(_ banner: WorldAirportBannerModel) {
        shown(banner)
        passport?.open()
    }

    /// The banner had its window (or was tapped): it goes.
    private func shown(_ banner: WorldAirportBannerModel) {
        if state.banner == banner { state.banner = nil }
    }

    /// DEBUG `FERNLET_UI_TEST_AIRPORT=at` (screen 1) or `landed` (screen 9): the banner and Sprout's line, as if the
    /// passport had just stamped the airport. Display only; nothing in Release or a decoy.
    private func applyTestScene() async {
        guard let scene = UITestSupport.airportHomeScene, scene == "at" || scene == "landed", !store.duressSessionActive else { return }
        do {
            try await Task.sleep(for: .seconds(4))
        } catch {
            return
        }
        let flights = store.worldLocation.flights
        guard let find = flights.latestFind, let airport = flights.airportsShelf.pack()?.airport(token: find.token) else { return }
        let landing = find.how == .landing
        state.banner = WorldAirportBannerModel.make(airport: airport, how: find.how, at: find.at,
                                                    continent: landing ? String(localized: AtlasContinent.europe.passportName) : nil,
                                                    countryCode: landing ? airport.countryCode : nil,
                                                    companion: WorldRecenterCopy.companionName(store))
        router.stage(WorldDiscoveryLine(category: landing ? .landing : .airport, index: 0, name: "", at: find.at))
    }
}
