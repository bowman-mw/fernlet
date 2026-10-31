import FernletFoundation
import Foundation
import Observation
import WorldMapStore

/// One Flighty file read and planned (World-Airports-Spec §9.4): what the summary sheet shows before anything is
/// added. The file's bytes are gone by now; only its name (for "From FlightyExport.csv"), the counts and the
/// flights' dates, airports and times are held, in memory, until the sheet closes.
nonisolated struct FlightyImportFound: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// The file's name, as the picker gave it.
    let fileName: String
    let summary: FlightyImportSummary
    let plan: FlightImportPlan
}

/// Why a picked file isn't imported: a refusal of the whole file (spec §9.1, "a wrong or huge file is turned away
/// with a message"), or the passport not taking the flights right now.
nonisolated enum FlightyImportProblem: Error, Equatable, Sendable {
    case refused(FlightyImportRefusal)
    /// The picker's file couldn't be opened or read.
    case unreadable
    /// The bundled airport list is missing, so no code can be checked.
    case noAirportList
    /// The passport couldn't be read or saved (the phone is locked, or a save failed).
    case passportClosed
    /// "Airports and flights" is off in Privacy & data, so no new flights are kept (spec §11).
    case switchedOff
}

/// The Flighty import (World-Airports-Spec §9, screens 19–24): "Add past flights" opens iOS's own file picker
/// (CSV only); the picked file is read once, off the main actor, by ``FlightyImport`` (only the date, airports,
/// cancelled and diverted flags, gate times and Flighty's ID are ever decoded) and planned against the passport;
/// the summary sheet's "Add N flights" adds them as records, and the toast's Undo takes that import back.
///
/// **Never on the network** (spec §9.1): no sign-in, no server, no share-sheet "Open in". The file isn't kept; the
/// airline, flight number and aircraft are never read into memory as text. **A decoy** offers no import (the
/// entry points hide it) and the keeper keeps nothing in one. **"Airports and flights" off** (spec §11) keeps no
/// new flights: the picker doesn't open and a confirm adds nothing, each with a message.
@MainActor
@Observable
final class FlightyImportFlow {
    /// Whether iOS's file picker is up.
    var isPicking = false
    /// The file read and planned, while its summary sheet is open.
    var found: FlightyImportFound?
    /// What went wrong with the last pick or confirm, while its alert is up.
    var problem: FlightyImportProblem?
    /// The flights just added, while the toast with Undo shows.
    private(set) var added: FlightyImportAdded?
    /// Whether a file is being read.
    private(set) var isReading = false

    @ObservationIgnored private let atlas: WorldAtlasKeeper
    @ObservationIgnored private let airports: () -> WorldAirports?
    /// Whether "Airports and flights" is on.
    @ObservationIgnored private let keepsFlights: () -> Bool
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    /// How long the toast stays (the longer window gives assistive tech time to reach Undo).
    static let toastSeconds: Double = 6

    /// A flow adding to `atlas`'s passport and checking codes in `airports` (the bundled pack), while
    /// `keepsFlights` says "Airports and flights" is on.
    init(atlas: WorldAtlasKeeper, airports: @escaping () -> WorldAirports?,
         keepsFlights: @escaping () -> Bool = { WorldMapPreferences.keepsAirportsAndFlights() }) {
        self.atlas = atlas
        self.airports = airports
        self.keepsFlights = keepsFlights
    }

    /// The store's flow: its passport and the flight gate's bundled airport list.
    convenience init(store: FernletStore) {
        let shelf = store.worldLocation.flights.airportsShelf
        self.init(atlas: store.worldFog.atlas, airports: { shelf.pack() })
    }

    /// The toast's timer ends with the flow (a screen that closes mid-toast).
    isolated deinit {
        toastTask?.cancel()
    }

    /// "Add past flights": opens the picker, or says why not while "Airports and flights" is off.
    func pick() {
        guard !isReading else { return }
        guard keepsFlights() else {
            problem = .switchedOff
            return
        }
        isPicking = true
    }

    /// The picker's answer: reads and plans the file, then opens its summary.
    func picked(_ result: Result<URL, any Error>) {
        guard case .success(let url) = result else { return }
        guard let pack = airports() else {
            problem = .noAirportList
            return
        }
        let book = atlas.book
        isReading = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.read(url, airports: pack, book: book)
            }.value
            isReading = false
            switch outcome {
            case .success(let found): self.found = found
            case .failure(let problem): self.problem = problem
            }
        }
    }

    /// "Add N flights": adds the planned flights and shows the toast; the sheet closes either way.
    func confirm() {
        guard let found else { return }
        self.found = nil
        guard keepsFlights() else {
            problem = .switchedOff
            return
        }
        guard atlas.importFlights(found.plan.flights) else {
            problem = .passportClosed
            return
        }
        FernletAuditLog.log("worldMap.flights.imported")
        show(FlightyImportAdded(count: found.plan.flights.count, undo: found.plan.undoFlights, source: found.plan.source))
    }

    /// The toast's Undo: takes the whole import back (flights the passport held before keep their sources).
    func undo() {
        guard let added else { return }
        dismissToast()
        guard atlas.undoImport(added.source, flights: added.undo) else {
            problem = .passportClosed
            return
        }
    }

    /// Closes the toast.
    func dismissToast() {
        toastTask?.cancel()
        added = nil
    }

    private func show(_ added: FlightyImportAdded) {
        toastTask?.cancel()
        self.added = added
        toastTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.toastSeconds))
            } catch {
                return
            }
            self?.added = nil
        }
    }

    /// Reads and plans the file at `url` off the main actor: at most ``FlightyImport/maxFileBytes`` are read.
    nonisolated static func read(_ url: URL, airports: WorldAirports,
                                 book: PassportBook) -> Result<FlightyImportFound, FlightyImportProblem> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= FlightyImport.maxFileBytes else { return .failure(.refused(.tooLarge)) }
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            return .failure(.unreadable)
        }
        do throws(FlightyImportRefusal) {
            let file = try FlightyImport(data: data, airports: airports)
            let plan = FlightImportPlan(records: file.flights, source: .flighty, airports: airports, book: book)
            return .success(FlightyImportFound(fileName: url.lastPathComponent, summary: file.summary, plan: plan))
        } catch {
            return .failure(.refused(error))
        }
    }
}

/// Flights just added from a file, for the toast and its Undo.
nonisolated struct FlightyImportAdded: Equatable, Sendable {
    /// How many flights the file added (the toast's number).
    let count: Int
    /// What Undo takes `source` off (``FlightImportPlan/undoFlights``).
    let undo: [PassportFlight]
    let source: PassportFlight.Sources
}
