import FernletFoundation
import Foundation
import Observation
import WorldMapStore

/// The first look back, read and planned (World-Airports-Spec §10.5, screen 28): what the summary sheet shows
/// before anything is added. In memory only, until the sheet closes.
nonisolated struct CalendarFlightsFound: Identifiable, Sendable {
    let id = UUID()
    let look: CalendarFlightLook
    /// The flown flights as an import against the passport.
    let plan: FlightImportPlan
    /// How many the passport already holds from a Flighty file, and as flights Fernlet saw.
    let fromFlighty: Int
    let fernletSaw: Int
}

/// "Flights from Calendar" in Privacy & data (World-Airports-Spec §10.1, §10.2, §10.5; screens 25, 26, 28).
///
/// - **Turning it on** asks iOS for full access (iOS's own prompt, with Fernlet's usage string). Don't Allow turns
///   the switch back off with a note on where to allow it later. Allowed, the switch is on and Fernlet looks back
///   once, to 2019 (``CalendarFlightLook/firstLookWindow(now:)``), off the main actor; the upcoming flights are
///   kept for their day at once, and the summary sheet's "Add 23 flights" adds the flown ones as an import
///   (source calendar, each with its salted event hash), with Undo.
/// - **Turning it off** stops all reading at once (a look under way keeps nothing); the flights already found
///   stay, and iOS keeps Fernlet's access until it's changed in iOS Settings (the switch's note says where).
/// - **"Airports and flights" off** turns this off too, and it can't be turned on until that's back on.
/// - **A decoy** never asks, never reads and shows no results (the card isn't shown in one either).
@MainActor
@Observable
final class CalendarFlightsFlow {
    /// Whether the switch is on.
    private(set) var isOn: Bool
    /// Whether iOS refuses Fernlet's access (the note under the switch says where to allow it).
    private(set) var isRefused: Bool
    /// Whether the first look is running.
    private(set) var isLooking = false
    /// The first look, while its summary sheet is open.
    var found: CalendarFlightsFound?
    /// What went wrong with the last look or confirm, while its alert is up.
    var problem: CalendarLookProblem?
    /// The flights just added, while the note with Undo shows.
    private(set) var added: FlightyImportAdded?

    @ObservationIgnored private let atlas: WorldAtlasKeeper
    @ObservationIgnored private let makeLooker: () -> CalendarFlightLooker?
    @ObservationIgnored private let currentAccess: () -> CalendarAccess
    @ObservationIgnored private let isDecoy: () -> Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var looker: CalendarFlightLooker?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var noteTask: Task<Void, Never>?

    /// A flow adding to `atlas`'s passport through the looker `makeLooker` makes on first use (nil once there's no
    /// store to look for); `currentAccess` says where iOS stands without making an event store.
    init(atlas: WorldAtlasKeeper, makeLooker: @escaping () -> CalendarFlightLooker?,
         currentAccess: @escaping () -> CalendarAccess, isDecoy: @escaping () -> Bool, defaults: UserDefaults = .standard) {
        self.atlas = atlas
        self.makeLooker = makeLooker
        self.currentAccess = currentAccess
        self.isDecoy = isDecoy
        self.defaults = defaults
        isOn = WorldMapPreferences.readsCalendarFlights(in: defaults)
        isRefused = false
        refresh()
    }

    /// The store's flow: its passport and gates, and EventKit.
    convenience init(store: FernletStore) {
        let looker: () -> CalendarFlightLooker? = { [weak store] in store?.worldCalendarLooker(source: EventKitCalendarSource()) }
        self.init(atlas: store.worldFog.atlas, makeLooker: looker, currentAccess: { EventKitCalendarSource.currentAccess() },
                  isDecoy: { [weak store] in store?.duressSessionActive ?? true })
    }

    /// A look and the note's timer end with the flow (a screen that closes mid-look keeps what it kept).
    isolated deinit {
        task?.cancel()
        noteTask?.cancel()
    }

    /// Reads the switch again (after "Airports and flights" changed, or the page came back), and whether iOS
    /// refuses access: a refusal found here turns the switch off (spec §10.2, "or later revoked").
    func refresh() {
        let refused = currentAccess() == .refused
        if refused, WorldMapPreferences.readsCalendarFlights(in: defaults) {
            WorldMapPreferences.setReadsCalendarFlights(false, in: defaults)
        }
        isOn = WorldMapPreferences.readsCalendarFlights(in: defaults)
        isRefused = refused && !isOn
    }

    /// The switch: on asks and looks back (``turnOn(now:)``), off stops reading.
    func setOn(_ on: Bool) {
        guard on else {
            turnOff()
            return
        }
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.turnOn(now: Date())
            self?.task = nil
        }
    }

    /// Asks iOS, and with access turns the switch on and looks back once; the summary opens with what was found.
    func turnOn(now: Date) async {
        guard !isOn, !isDecoy(), WorldMapPreferences.keepsAirportsAndFlights(in: defaults) else { return }
        guard let looker = looker ?? makeLooker() else { return }
        self.looker = looker
        isLooking = true
        defer { isLooking = false }
        guard await looker.source.requestAccess() == .allowed else {
            refuse()
            return
        }
        WorldMapPreferences.setReadsCalendarFlights(true, in: defaults)
        isOn = true
        isRefused = false
        switch await looker.look(CalendarFlightLook.firstLookWindow(now: now), now: now) {
        case .success(let look): present(look, now: now)
        case .failure(.notAllowed): refuse()
        case .failure(.switchedOff): return
        case .failure(let other): problem = other
        }
    }

    /// Keeps the first look's upcoming flights and opens its summary.
    private func present(_ look: CalendarFlightLook, now: Date) {
        guard atlas.keepCalendarLook(flown: [], upcoming: look.upcoming, now: now) else {
            problem = .passportClosed
            return
        }
        let book = atlas.book, held = look.alreadyHeld(in: book)
        found = CalendarFlightsFound(look: look, plan: look.plan(against: book), fromFlighty: held.fromFlighty,
                                     fernletSaw: held.fernletSaw)
    }

    /// Don't Allow (or access taken away): the switch goes back off, with the note.
    private func refuse() {
        WorldMapPreferences.setReadsCalendarFlights(false, in: defaults)
        isOn = false
        isRefused = true
    }

    /// Off: no more reading; what was found stays.
    func turnOff() {
        task?.cancel()
        task = nil
        isLooking = false
        found = nil
        WorldMapPreferences.setReadsCalendarFlights(false, in: defaults)
        isOn = false
    }

    /// "Add N flights": adds the flown flights as an import and shows the note with Undo; the sheet closes
    /// either way.
    func confirm() {
        guard let found else { return }
        self.found = nil
        guard isOn, atlas.importFlights(found.plan.flights) else {
            if isOn { problem = .passportClosed }
            return
        }
        FernletAuditLog.log("worldMap.flights.calendarImported")
        show(FlightyImportAdded(count: found.plan.flights.count, undo: found.plan.undoFlights, source: .calendar))
    }

    /// The note's Undo: takes the whole import back (flights the passport held before keep their sources).
    func undo() {
        guard let added else { return }
        dismissNote()
        if !atlas.undoImport(added.source, flights: added.undo) { problem = .passportClosed }
    }

    /// Closes the note.
    func dismissNote() {
        noteTask?.cancel()
        added = nil
    }

    private func show(_ added: FlightyImportAdded) {
        noteTask?.cancel()
        self.added = added
        noteTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(FlightyImportFlow.toastSeconds))
            } catch {
                return
            }
            self?.added = nil
        }
    }

    #if DEBUG
    /// Opens the summary on `found` (the screenshots' made-up look), as a first look would.
    func showDemo(_ found: CalendarFlightsFound) {
        self.found = found
    }
    #endif
}
