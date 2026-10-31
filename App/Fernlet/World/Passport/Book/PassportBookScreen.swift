import FernletDomainModel
import FernletUI
import SwiftUI
import WorldMapStore

/// Sprout's passport as it lies open over the map (World-Passport-Spec §1–§3): the veil over whatever is behind,
/// the ✕ top right (a status chip or ‹ Index top left), the book, and the page bar under it. Presented full screen
/// over the root by ``WorldPassportBookHost``, inside a NavigationStack so page 1 can push its slot pages (their
/// Back reads "Passport").
///
/// It reads only the sealed passport (`store.worldFog.atlas.book`, empty in a decoy) or the presenter's in-memory
/// demo, and keeps nothing.
struct PassportBookScreen: View {
    let presenter: WorldPassportPresenter
    let store: FernletStore
    @State var library: PassportLibrary
    @State var page = 1
    @State var detail: PassportIndexDetail?
    @State var turn: PassportTurn?
    @State var showsContents = false
    @State var showsWorld = false
    /// Where Your world opens: a tapped flight's arc, or home (nil).
    @State var worldCentre: GeoPoint?
    /// The Flighty import, from the Flights page's "Add past flights".
    @State var importFlow: FlightyImportFlow
    /// Calendar's look, the Flights page button's second source (World-Airports-Spec §10.1).
    @State var calendarFlow: CalendarFlightsFlow
    /// Whether the Flights page button is asking "A Flighty file or Calendar?".
    @State var picksSource = false
    @State var wiggle: PassportWiggle?
    @State var landing: PassportStampEntry?
    @State var pageOnTop = true
    @State var motion = PassportBookMotion()
    /// Whether the Creation Studio, pushed from page 1, holds an unsaved drawing: the book won't close then.
    @State var isStudioDraftDirty = false
    @AccessibilityFocusState var pageFocused: Bool
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    init(presenter: WorldPassportPresenter, store: FernletStore) {
        self.presenter = presenter
        self.store = store
        _library = State(initialValue: PassportLibrary(openAtlas: { store.worldFog.atlas.openedAtlas },
                                                       seaNeighbours: { store.worldFog.atlas.seaNeighbours() },
                                                       airports: { store.worldLocation.flights.airportsShelf.pack() }))
        _importFlow = State(initialValue: FlightyImportFlow(store: store))
        _calendarFlow = State(initialValue: CalendarFlightsFlow(store: store))
    }

    var body: some View {
        let flights = flightsModel
        let book = PassportBookModel(entries: entries, flightPageCount: flights?.pages.count ?? 0)
        NavigationStack {
            GeometryReader { proxy in
                ZStack {
                    PassportBookPalette.veil.ignoresSafeArea().opacity(motion.veil)
                    VStack(spacing: 0) {
                        topBar(book).frame(height: 48).padding(.horizontal, 16).opacity(motion.chrome)
                        stage(book, flights: flights)
                            .frame(height: Self.bookHeight(in: proxy.size.height))
                            .padding(EdgeInsets(top: 6, leading: 30, bottom: 16, trailing: 30))
                            .modifier(PassportRiseEffect(lift: motion.lift, anchor: presenter.anchor, in: proxy))
                        bar(book).opacity(motion.chrome)
                        Spacer(minLength: 0)
                    }
                    if showsContents { contents(book) }
                }
                .opacity(motion.fade)
            }
            // Page 1 names the stack "Passport" itself (its pushed pages' Back); the root's bar stays hidden.
            .toolbar(.hidden, for: .navigationBar)
            .containerBackground(.clear, for: .navigation)
        }
        .flightyImport(importFlow)
        .calendarFlightsImport(calendarFlow)
        .modifier(PassportFlightSourcePicker(isPresented: $picksSource, onFile: { importFlow.pick() },
                                             onCalendar: { calendarFlow.setOn(true) }))
        .overlay {
            if showsWorld {
                WorldYourWorldPage(source: worldSource, initialCentre: worldCentre, onBack: { showsWorld = false },
                                   onClose: { showsWorld = false; presenter.close() },
                                   onOpenCity: { showsWorld = false; presenter.openCity($0) })
                    .background(WorldPalette.page.ignoresSafeArea())
                    .transition(.opacity)
            }
        }
        .onAppear { start(book) }
        .onChange(of: presenter.isClosing) { _, closing in if closing { finish() } }
    }

    /// The book's height: 644 pt, or less on a shorter screen (the book never grows past the screen).
    static func bookHeight(in height: CGFloat) -> CGFloat {
        max(min(644, height - 48 - 6 - 16 - 46 - 8), 320)
    }

    /// The stamps to show: the presenter's demo, or the person's passport (empty in a decoy).
    private var entries: [PassportStampEntry] {
        presenter.demo?.entries ?? PassportStampEntry.entries(of: store.worldFog.atlas.book)
    }

    /// The Flights pages' model: the person's flights (World-Airports-Spec §8), or nil in a decoy and the demo,
    /// which show no Flights page (§11: a decoy shows no flights).
    private var flightsModel: PassportFlightsModel? {
        let flights: [PassportFlight]
        if let demo = presenter.demo {
            guard let demoFlights = demo.flights, !demo.isDecoy else { return nil }
            flights = demoFlights
        } else {
            guard !store.worldFog.isDecoy else { return nil }
            flights = store.worldFog.atlas.book.flights
        }
        let pack = store.worldLocation.flights.airportsShelf.pack()
        return PassportFlightsModel(flights: flights) { pack?.point(iata: $0)?.point }
    }

    /// An airport's city in the app's language, by IATA code (nil for a points-only code).
    private func airportCity(_ code: String) -> String? {
        store.worldLocation.flights.airportsShelf.pack()?.airport(code: code)?.city(spanish: FernletLanguage.app == .spanish)
    }

    /// Opens Your world on `trip`'s arc (a stub tapped).
    private func openWorld(on trip: PassportFlightTrip) {
        let pack = store.worldLocation.flights.airportsShelf.pack()
        guard let from = trip.codes.first.flatMap({ pack?.point(iata: $0)?.point }),
              let to = trip.codes.last.flatMap({ pack?.point(iata: $0)?.point }) else { return }
        worldCentre = PassportFlightsModel.midpoint(from, to)
        showsWorld = true
    }

    /// "Add past flights" (§9.1, §10.1): a Flighty file, or Calendar while its switch is off; nil (no button) while
    /// "Airports and flights" is off, which keeps no new flights.
    private var addPastFlightsAction: (() -> Void)? {
        guard presenter.demo != nil || store.keepsWorldAirportsAndFlights() else { return nil }
        return {
            calendarFlow.refresh()
            if calendarFlow.isOn { importFlow.pick() } else { picksSource = true }
        }
    }

    /// The world map's source: the demo's content, or the person's passport and fog.
    private var worldSource: WorldAtlasMapView.Source {
        presenter.demo?.world.map { .content($0) } ?? .store(store)
    }

    /// Closes the book unless the Studio holds an unsaved drawing (the ✕ and the swipe down).
    func requestClose() {
        guard !isStudioDraftDirty else { return }
        presenter.close()
    }

    // MARK: Parts

    /// Top left: ‹ Index in an A to Z view, the new-stamp chip on its page, the full passport's chip; ✕ top right.
    private func topBar(_ book: PassportBookModel) -> some View {
        HStack(spacing: 10) {
            if detail != nil {
                FernletBackButton(verbatim: String(localized: PassportBookCopy.index)) { stepDetail(nil) }
                    .accessibilityLabel(Text(PassportPageCopy.backToIndex))
            } else if let landing, book.pageNumber(of: landing) == page, let kind = landing.stampKind {
                PassportStatusChip(text: Text(PassportBookCopy.newStampChip(library.name(of: kind, onPage: true)))) {
                    WorldSpriteView(sprite: WorldSprites.stampMed, scale: 2, tint: nil)
                }
                .accessibilityElement(children: .combine)
            } else if isFull(book), page == book.stampPageNumbers.upperBound {
                PassportStatusChip(text: Text(PassportBookCopy.everyStamp)) {
                    WorldSpriteView(sprite: WorldSprites.heartSm, scale: 2, tint: PassportBookPalette.gold)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
            PassportCloseButton { requestClose() }
        }
    }

    private func stage(_ book: PassportBookModel, flights: PassportFlightsModel?) -> some View {
        PassportBookStage(shown: page, turn: turn, ribbonPage: book.ribbonPage, coverAngle: motion.cover,
                          turnedPages: motion.turnedPages, onRibbon: { go(to: $0, in: book) },
                          onTurnDone: { finishTurn($0) }) { number in
            if book.page(at: number) == .sprout {
                // Page 1 scrolls itself and draws its own insets; the book adds only the page number.
                PassportPageNumber(number: number) { sproutPage }
            } else {
                PassportPageScroll(number: number, content: { content(number, in: book, flights: flights) },
                                   onTop: { pageOnTop = $0 })
            }
        }
        .id(reduceMotion ? "\(page)-\(detail.map { "\($0)" } ?? "")" : "book")
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(pageLabel(book)))
        .accessibilityFocused($pageFocused)
        .accessibilityScrollAction { edge in
            switch edge {
            case .trailing: step(1, in: book)
            case .leading: step(-1, in: book)
            default: break
            }
        }
        .simultaneousGesture(swipe(book))
    }

    /// The page bar, or the continent bar in an A to Z view.
    @ViewBuilder
    private func bar(_ book: PassportBookModel) -> some View {
        if let detail {
            PassportContinentBar(detail: detail) { stepDetail($0) }
        } else {
            PassportPageBar(number: page, count: book.pageCount, name: String(localized: PassportBookCopy.name(of: book.page(at: page))),
                            onPrevious: { step(-1, in: book) }, onContents: { showsContents.toggle() },
                            onNext: { step(1, in: book) })
        }
    }

    private func contents(_ book: PassportBookModel) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.001).ignoresSafeArea().onTapGesture { showsContents = false }
                .accessibilityHidden(true)
            PassportContents(book: book, current: page) { number in
                showsContents = false
                go(to: number, in: book)
            }
            .frame(maxWidth: 280)
            .padding(.bottom, 70)
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    /// Page `number`'s content.
    @ViewBuilder
    private func content(_ number: Int, in book: PassportBookModel, flights: PassportFlightsModel?) -> some View {
        switch book.page(at: number) {
        case .sprout:
            sproutPage
        case .world:
            PassportWorldPage(book: book, progress: progress(book), world: worldSource) { worldCentre = nil; showsWorld = true }
        case .flights(let index):
            if let flights {
                PassportFlightsPage(flights: flights, index: index, city: airportCity, onOpenTrip: { openWorld(on: $0) },
                                    onAddPastFlights: addPastFlightsAction)
            }
        case .stamps(let index):
            PassportStampsPage(book: book, index: index, library: library, landing: landing, wiggle: wiggle,
                               full: isFull(book))
        case .index:
            if let detail {
                PassportContinentPage(detail: detail, book: book, index: indexModel(book, flights: flights),
                                      library: library) {
                    turnFromIndex(to: $0, kind: $1, token: $2, in: book)
                }
            } else {
                PassportIndexPage(index: indexModel(book, flights: flights), library: library, onTurn: {
                    turnFromIndex(to: $0, kind: $1, token: $2, in: book)
                }, onOpen: { stepDetail($0) }, onGo: { go(to: $0, in: book) })
            }
        }
    }

    /// Page 1, Sprout's own page (`PassportSproutPage`). No body signal: the book has none of Home's stress
    /// reading, so Sprout shows without it here.
    private var sproutPage: some View {
        PassportSproutPage(store: store, bodySignal: nil, isStudioDraftDirty: $isStudioDraftDirty, onTop: { pageOnTop = $0 })
    }

    // MARK: Reading

    private func progress(_ book: PassportBookModel) -> PassportProgress {
        PassportProgress(entries: book.ordered, table: library.countryTable)
    }

    /// The index: places named as the index names them (an airport without "International"), with the Flights row.
    private func indexModel(_ book: PassportBookModel, flights: PassportFlightsModel?) -> PassportIndexModel {
        PassportIndexModel(book: book, table: library.countryTable, flights: flights) { library.indexName(of: $0) }
    }

    /// Every stamp found: all 194 countries, the seven continents and the five oceans.
    private func isFull(_ book: PassportBookModel) -> Bool {
        let counts = progress(book)
        return counts.countryCount >= PassportProgress.countryTotal && counts.hasAllContinents && counts.hasAllOceans
    }

    /// "Sprout's passport, page 3 of 6, Stamps".
    private func pageLabel(_ book: PassportBookModel) -> LocalizedStringResource {
        PassportBookCopy.page(page, of: book.pageCount, named: String(localized: PassportBookCopy.name(of: book.page(at: page))))
    }
}
