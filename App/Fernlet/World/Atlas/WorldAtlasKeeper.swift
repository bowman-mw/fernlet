import FernletFoundation
import Foundation
import WorldMapStore

/// Keeps the World passport (round 7, idea 4; owner 2026-10-29): reads each fix the fog keeper accepted
/// against the bundled atlas and records the first visits and each country's trips in the sealed
/// ``PassportStore``.
///
/// **Which fixes.** `WorldFogKeeper` owns this keeper and calls ``observe(point:at:)`` only for fixes it
/// accepted (precise, accurate to 65 m, "Uncover the map as you go" on), only while the phone is unlocked,
/// and never in a decoy. A fix closer than ``minimumSpacing`` to the last one read is not read against the atlas
/// again, since a border, a coast or a city edge is never that close to two answers: it counts as the same visit
/// at its own time, so a week at home still keeps home's trip clock going (owner 2026-10-29, "Stamp each trip":
/// a new country stamp needs 7 days away from it).
///
/// **The atlas** is the bundled `WorldAtlas.pack`, opened once, the first time a fix arrives
/// (``bundledPack(in:open:)``). A missing or unreadable pack means the passport records nothing this session
/// and `FernletAuditLog` notes it once; the map and the fog carry on. The app opens it off the main actor while
/// the launch screen is up (``beginOpening()``): reading the pack's layers held Home's first frame for 2.6 s on
/// 2026-10-30 (a Debug build on an iPhone 17 Pro Max). Until that ends every reader is answered as if there
/// were no atlas, the newest fix waits and is read once it is open, and views that asked draw again then.
///
/// **Landmarks** (World-Exploration-Spec §2). The hand-written `WorldLandmarks.json` beside the pack is opened
/// once, on first use (``bundledLandmarks(in:)``); a missing or malformed file is logged once and means no
/// landmarks, and the atlas still works. With a list open, each fix is read through `AtlasWithLandmarks`, so a
/// fix within a landmark's find radius records it (kind `landmark`) like any other first visit, announced once.
/// ``landmarks`` is the whole list, for drawing the unfound ones grey and unnamed through the fog; whether
/// one is found comes from ``book`` (``isFound(_:)``). In a decoy the book is empty, so nothing is found, but
/// the grey art may still be drawn: the list is public data that ships in the app, not the person's.
///
/// **Duress.** A decoy (``setDecoy(_:)``) shows an empty passport and keeps nothing: no fix is read, nothing
/// is written and no discovery is announced. Every wipe reaches ``clearAll()`` through
/// `WorldFogKeeper.clearAll()` (Delete everything and the silent wipe via `FernletStore.resetAll()`, the
/// recovery lock's purge hook, and "Delete map history"), and the file lives in the vault's folder, which
/// `WorldMapVault.clearAll()` removes with its keys.
///
/// **The sealed iCloud backup** (owner 2026-10-29: "so a new phone gets it back", with "its own switch").
/// The passport is a Sealed backup payload of its own (`.worldPassport`, `PassportBackupAdapter`), sealed
/// like the journal's text and behind its own switch (`sealedBackupPassportEnabled`): ``bookForBackup()``
/// hands it out (never in a decoy, never an empty stand-in for one that can't be read), ``restore(_:)``
/// merges a restored one by token keeping the earliest date (a country's trips each once), and
/// ``onPassportChanged`` tells the store
/// the passport's backup owes an upload.
///
/// **Discoveries for Sprout** (idea B) and new stamps for the passport. ``discoveries()`` is a stream of
/// ``PassportEvent``s: each first visit, and each new trip to a country visited before (owner 2026-10-29, "Stamp
/// each trip": a return trip is a new stamp, and the passport opens on its page). Each is announced once, only
/// after it is saved, only for an accepted fix (never in a decoy, never for a restore), at most
/// ``eventBufferSize`` held for a slow reader (the newest kept). Nothing in the app reads it yet.
@MainActor
@Observable
final class WorldAtlasKeeper {
    /// The bundled pack's resource name (a frozen file name: `WorldAtlas.pack`).
    static let packResource = "WorldAtlas"
    /// The bundled pack's file extension.
    static let packExtension = "pack"
    /// The bundled landmark list's resource name (a frozen file name: `WorldLandmarks.json`).
    static let landmarksResource = "WorldLandmarks"
    /// The bundled landmark list's file extension.
    static let landmarksExtension = "json"
    /// The least distance from the last fix read before another is read, in metres.
    static let minimumSpacing = 50.0
    /// The most discoveries a stream holds for a reader that hasn't caught up (the newest kept).
    static let eventBufferSize = 16

    /// The passport the screens show: the person's whole passport, or an empty one in a decoy.
    private(set) var book = PassportBook()
    /// Whether a decoy session is showing.
    private(set) var isDecoy = false

    /// Where the atlas stands this session.
    private enum AtlasState {
        /// Not opened yet.
        case notOpened
        /// Open and answering.
        case ready(any AtlasVisitResolving)
        /// Missing or unreadable: the passport records nothing this session.
        case unavailable
    }

    @ObservationIgnored private let store: PassportStore
    @ObservationIgnored private let openAtlas: @MainActor () -> (any AtlasVisitResolving)?
    /// The opener ``beginOpening()`` runs off the main actor; nil (tests) opens on the main actor on first use.
    @ObservationIgnored private let openAtlasOffMain: (@Sendable () -> (any AtlasVisitResolving)?)?
    @ObservationIgnored private let openLandmarks: @MainActor () -> WorldLandmarks
    @ObservationIgnored private var atlas: AtlasState = .notOpened
    /// Whether ``beginOpening()``'s background open is running: readers get nil meanwhile. Observed, so a view
    /// that read ``openedAtlas`` while it ran draws again when it ends.
    private(set) var isOpeningAtlas = false
    /// The newest fix that arrived while the atlas was opening, read once it is open.
    @ObservationIgnored private var pendingFix: (point: GeoPoint, date: Date)?
    /// Which of the atlas's seas touch (``seaNeighbours()``), once worked out this session.
    @ObservationIgnored private var seaNeighbourTable: [String: Set<String>]?
    /// The session's one background pass that fills ``seaNeighbourTable``, started when the atlas opens.
    @ObservationIgnored private var seaNeighbourPass: Task<Void, Never>?
    @ObservationIgnored private var openedLandmarks: WorldLandmarks?
    @ObservationIgnored private var lastRead: GeoPoint?
    /// What the atlas said about ``lastRead``.
    @ObservationIgnored private var lastVisit: AtlasVisit?
    @ObservationIgnored private var subscriber: AsyncStream<PassportEvent>.Continuation?
    /// Runs after the passport on disk changed for the sealed backup's sake: a first visit or a trip was saved,
    /// or ``clearAll()`` removed it (a fix that only moved a country's clock on does not run it; the backup
    /// carries the clock with the next change). The store sets it to mark the passport's own backup owed
    /// (`markSealedBackupDirty(.worldPassport)`), so the next export writes the new passport, or an empty
    /// one over a deleted one. A restore does not run it (the restore marks the payload owed itself). Nil
    /// (tests) does nothing.
    @ObservationIgnored var onPassportChanged: (@MainActor () -> Void)?

    /// A keeper over `vault`, opening the atlas with `openAtlas` when the first fix arrives (the app passes
    /// ``bundledPack(in:open:)``; tests pass a fake). `openAtlas` returns nil when there is no atlas.
    /// `openLandmarks` opens the landmark list on first use (the app passes ``bundledLandmarks(in:)``); the
    /// default is no landmarks. `openAtlasOffMain` is the same opener for ``beginOpening()`` to run off the main
    /// actor (the app passes ``bundledPackOffMain(in:open:)``); the default has none.
    init(vault: WorldMapVault, openAtlas: @escaping @MainActor () -> (any AtlasVisitResolving)?,
         openAtlasOffMain: (@Sendable () -> (any AtlasVisitResolving)?)? = nil,
         openLandmarks: @escaping @MainActor () -> WorldLandmarks = { .empty }) {
        self.store = PassportStore(vault: vault)
        self.openAtlas = openAtlas
        self.openAtlasOffMain = openAtlasOffMain
        self.openLandmarks = openLandmarks
    }

    isolated deinit {
        seaNeighbourPass?.cancel()
    }

    /// The opener for the landmark list bundled in `bundle`: reads `WorldLandmarks.json`. A missing file or
    /// one ``WorldLandmarks`` refuses is logged and answers an empty list (the keeper opens it once).
    static func bundledLandmarks(in bundle: Bundle = .main) -> @MainActor () -> WorldLandmarks {
        {
            guard let url = bundle.url(forResource: landmarksResource, withExtension: landmarksExtension) else {
                FernletAuditLog.log("worldMap.landmarks.fileMissing")
                return .empty
            }
            do {
                return try WorldLandmarks(data: Data(contentsOf: url))
            } catch {
                FernletAuditLog.log("worldMap.landmarks.fileUnreadable")
                return .empty
            }
        }
    }

    // MARK: Landmarks

    /// Every bundled landmark, opened on first use (empty when the file is missing or refused). The screens
    /// draw the unfound ones grey and unnamed through the fog, also in a decoy: the list is public data.
    var landmarks: WorldLandmarks {
        if let openedLandmarks { return openedLandmarks }
        let opened = openLandmarks()
        openedLandmarks = opened
        return opened
    }

    /// Whether `landmark` is found in the passport the screens show (never in a decoy, whose book is empty).
    func isFound(_ landmark: AtlasLandmark) -> Bool {
        book.isFound(landmark)
    }

    /// The opener for the pack bundled in `bundle`: reads `WorldAtlas.pack` and hands its bytes to `open`
    /// (the atlas reader). A missing file or one `open` refuses is logged and answers nil.
    static func bundledPack(in bundle: Bundle = .main,
                            open: @escaping @MainActor (Data) throws -> any AtlasVisitResolving)
        -> @MainActor () -> (any AtlasVisitResolving)? {
        {
            guard let url = bundle.url(forResource: packResource, withExtension: packExtension) else {
                FernletAuditLog.log("worldMap.atlas.packMissing")
                return nil
            }
            do {
                return try open(Data(contentsOf: url, options: .mappedIfSafe))
            } catch {
                FernletAuditLog.log("worldMap.atlas.packUnreadable")
                return nil
            }
        }
    }

    /// The opener ``beginOpening()`` runs off the main actor: reads the pack bundled in `bundle` and hands its bytes
    /// to `open`; it answers nil when they can't be read (``beginOpening()`` logs that). Nil when the pack is
    /// missing, so the keeper opens on the main actor instead and ``bundledPack(in:open:)`` logs it.
    static func bundledPackOffMain(in bundle: Bundle = .main,
                                   open: @escaping @Sendable (Data) throws -> any AtlasVisitResolving)
        -> (@Sendable () -> (any AtlasVisitResolving)?)? {
        guard let url = bundle.url(forResource: packResource, withExtension: packExtension) else { return nil }
        return {
            do {
                return try open(Data(contentsOf: url, options: .mappedIfSafe))
            } catch {
                return nil
            }
        }
    }

    /// Starts opening the atlas off the main actor (the app calls it while the launch screen is up). Once, and
    /// only before anything opened it; nothing without an off-main opener.
    func beginOpening() {
        guard case .notOpened = atlas, !isOpeningAtlas, let openOffMain = openAtlasOffMain else { return }
        isOpeningAtlas = true
        Task { [weak self] in
            let opened = await Task.detached(priority: .userInitiated) { openOffMain() }.value
            self?.finishOpening(opened)
        }
    }

    /// Takes the atlas ``beginOpening()`` opened (nil: unreadable, logged) and reads the fix that waited for it.
    private func finishOpening(_ opened: (any AtlasVisitResolving)?) {
        isOpeningAtlas = false
        guard case .notOpened = atlas else { return }
        if opened == nil { FernletAuditLog.log("worldMap.atlas.packUnreadable") }
        _ = adopt(opened)
        guard let fix = pendingFix else { return }
        pendingFix = nil
        observe(point: fix.point, at: fix.date)
    }

    // MARK: The fog keeper's calls

    /// Reads the passport when no decoy is showing and it hasn't been read yet (the fog keeper's `load()`,
    /// which runs only while the phone is unlocked).
    func load() {
        guard !isDecoy, !store.isLoaded else { return }
        guard loadStore() else { return }
        book = store.book
    }

    /// Reads one accepted fix at `point`, taken at `date`, and records its first visits and any trip it starts;
    /// each first visit and new trip is announced on ``discoveries()`` once saved. A fix within ``minimumSpacing`` of the last
    /// one read records that visit again at `date` without asking the atlas. Nothing in a decoy, before the
    /// passport can be read, or without an atlas; while the atlas is opening, the newest fix waits for it.
    func observe(point: GeoPoint, at date: Date) {
        guard !isDecoy, point.isValid else { return }
        guard !isOpeningAtlas else {
            pendingFix = (point, date)
            return
        }
        let nearby = lastRead.map { $0.distance(to: point) < Self.minimumSpacing } ?? false
        guard let resolver = resolver(), loadStore() else { return }
        let visit = nearby ? (lastVisit ?? resolver.visit(at: point)) : resolver.visit(at: point)
        let tripsBefore = store.book.returnCount
        let found: [AtlasDiscovery]
        do {
            found = try store.record(visit, at: date)
        } catch {
            FernletAuditLog.log("worldMap.passport.saveDeferred")
            return
        }
        if !nearby {
            lastRead = point
            lastVisit = visit
        }
        let trip = store.book.returnCount != tripsBefore ? newTrip(in: visit) : nil
        guard !found.isEmpty || trip != nil else { return }
        book = store.book
        onPassportChanged?()
        announce(found, trip: trip)
    }

    // MARK: Airports and flights (the flight gate, World-Airports-Spec §3, §4.2, §6)

    /// Whether the flight gate's finds can be taken now: the passport reads (the phone is unlocked), or a decoy is
    /// showing (which keeps nothing, so they are dropped).
    func opensForFlights() -> Bool {
        isDecoy || loadStore()
    }

    /// Records the person at the airport `token` at `date`, found by `find`, and announces a first visit or a new
    /// trip on ``discoveries()`` once saved. Nothing in a decoy or before the passport can be read.
    func recordAirport(token: String, at date: Date, by find: PassportBook.AirportFind) {
        guard !isDecoy, loadStore() else { return }
        do {
            let event = try store.recordAirport(token: token, at: date, by: find)
            book = store.book
            onPassportChanged?()
            if let event { subscriber?.yield(event) }
        } catch {
            FernletAuditLog.log("worldMap.passport.saveDeferred")
        }
    }

    /// Keeps a flight Fernlet saw (its two airports and times, nothing else) under the one-flight rule. Nothing in
    /// a decoy or before the passport can be read.
    func recordFlight(_ flight: PassportFlight) {
        update { $0.addFlights([flight]) > 0 }
    }

    /// Marks the latest trip through the airport `token` as a layover: its stamp says TRANSIT. Nothing in a decoy.
    func markTransit(atAirport token: String) {
        update { book in
            guard let start = book.trips(atAirport: token).last else { return false }
            return book.setTransit(true, atAirport: token, trip: start)
        }
    }

    /// Changes the saved passport by `change` (which says whether anything changed), never in a decoy.
    private func update(_ change: (inout PassportBook) -> Bool) {
        guard !isDecoy, loadStore() else { return }
        do {
            guard try store.update(change) == true else { return }
            book = store.book
            onPassportChanged?()
        } catch {
            FernletAuditLog.log("worldMap.passport.saveDeferred")
        }
    }

    /// Enters or leaves a decoy session: entering shows an empty passport, leaving shows the person's again.
    func setDecoy(_ on: Bool) {
        guard on != isDecoy else { return }
        isDecoy = on
        lastRead = nil
        lastVisit = nil
        pendingFix = nil
        book = on ? PassportBook() : store.book
    }

    /// The wipe: forgets the passport and removes its file, then runs ``onPassportChanged`` so the
    /// passport's backup drops its copy at the next export (a wipe that deletes the backup itself owes
    /// nothing: the store's dirty mark is a no-op during Delete everything). Whether the file is gone.
    func clearAll() -> Bool {
        lastRead = nil
        lastVisit = nil
        pendingFix = nil
        book = PassportBook()
        let removed = store.removeAll()
        onPassportChanged?()
        return removed
    }

    // MARK: The sealed backup

    /// Why the sealed backup can't have the passport right now (it then writes and merges nothing).
    enum BackupRefusal: Error, Equatable {
        /// A decoy session is showing: nothing real is handed out or written.
        case decoy
        /// The passport can't be read right now (the phone is locked): try again later.
        case unreadable
    }

    /// The passport to put in its sealed iCloud backup (`PassportBackupAdapter`): the person's whole
    /// passport, empty when nothing has been visited. Throws ``BackupRefusal`` in a decoy and while it
    /// can't be read, never an empty book in its place, so a backup is never written without it.
    func bookForBackup() throws -> PassportBook {
        guard !isDecoy else { throw BackupRefusal.decoy }
        guard loadStore() else { throw BackupRefusal.unreadable }
        return store.book
    }

    /// Merges a passport restored from the sealed backup into this one (by token, the earliest date kept,
    /// nothing local removed) and saves it; a restore announces nothing. Returns how many entries were
    /// added or moved earlier. Throws ``BackupRefusal/decoy`` in a decoy, and the store's error when it
    /// could not be read or saved (the book is then as it was).
    @discardableResult
    func restore(_ restored: PassportBook) throws -> Int {
        guard !isDecoy else { throw BackupRefusal.decoy }
        let changed: Int
        do {
            changed = try store.restore(restored)
        } catch {
            FernletAuditLog.log("worldMap.passport.restoreFailed")
            throw error
        }
        book = store.book
        return changed
    }

    // MARK: Discoveries

    /// A stream of each first visit and each new trip, announced once it is saved, holding at most
    /// ``eventBufferSize`` for a slow reader. One reader at a time (Sprout's lines and the passport): asking again
    /// ends the previous stream.
    func discoveries() -> AsyncStream<PassportEvent> {
        subscriber?.finish()
        let (stream, continuation) = AsyncStream<PassportEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.eventBufferSize))
        subscriber = continuation
        return stream
    }

    /// Ends the current stream (the reader going away, and tests).
    func endDiscoveries() {
        subscriber?.finish()
        subscriber = nil
    }

    // MARK: Helpers

    /// The atlas, opened on first use and read together with ``landmarks`` when the list holds any; nil when
    /// the atlas is missing or unreadable (the opener logs that, once).
    /// Whether the atlas puts water under `cell`'s centre (the weekly corner skips water). False with no
    /// atlas, so a missing pack never hides every corner.
    func isWater(_ cell: HexCell) -> Bool {
        resolver()?.isWater(at: MercatorHexGrid.centreGeo(of: cell)) ?? false
    }

    /// The bundled atlas itself, for the screens that draw from it (the terrain under the fog, the world view,
    /// the city markers): opened on first use like the passport's reader. Nil with no atlas, or when the opener
    /// answered a stand-in that isn't a `WorldAtlas` (tests). Public data that ships in the app, so a decoy
    /// draws from it too; only the passport (``book``) is the person's.
    var openedAtlas: WorldAtlas? {
        switch resolver() {
        case let joined as AtlasWithLandmarks: joined.atlas as? WorldAtlas
        case let atlas as WorldAtlas: atlas
        default: nil
        }
    }

    /// Which of the atlas's seas touch (``WorldAtlas/seaNeighbours()``), for the passport's sea inks; empty with no
    /// atlas. One table a session for every passport screen: a background pass starts as soon as the atlas opens,
    /// and a screen that asks before it is done works the table out here and keeps it. The pass walks the atlas's
    /// whole sea raster (about 6.5 million cells): on 2026-10-30 each screen's own pass held the main thread for
    /// 476 ms on a passport page turn (a Debug build on an iPhone 17 Pro Max).
    func seaNeighbours() -> [String: Set<String>] {
        if let seaNeighbourTable { return seaNeighbourTable }
        guard let world = openedAtlas else { return [:] }
        let table = world.seaNeighbours()
        seaNeighbourTable = table
        return table
    }

    /// Starts the session's one background pass over `world`'s seas (``seaNeighbours()``). Public data that ships
    /// in the app, so it may run off the main actor; the first table kept wins.
    private func startSeaNeighbourPass(over world: WorldAtlas) {
        guard seaNeighbourTable == nil, seaNeighbourPass == nil else { return }
        seaNeighbourPass = Task { [weak self] in
            let table = await Task.detached(priority: .utility) { world.seaNeighbours() }.value
            guard let self, self.seaNeighbourTable == nil else { return }
            self.seaNeighbourTable = table
        }
    }

    private func resolver() -> (any AtlasVisitResolving)? {
        // Read before the state, so a view that asked during the background open draws again when it ends.
        guard !isOpeningAtlas else { return nil }
        switch atlas {
        case .ready(let resolver):
            return resolver
        case .unavailable:
            return nil
        case .notOpened:
            return adopt(openAtlas())
        }
    }

    /// Keeps `opened` as the session's atlas, read together with ``landmarks`` when the list holds any, and starts
    /// the sea pass; nil marks the atlas unavailable for the session.
    private func adopt(_ opened: (any AtlasVisitResolving)?) -> (any AtlasVisitResolving)? {
        guard let opened else {
            atlas = .unavailable
            return nil
        }
        if let world = opened as? WorldAtlas { startSeaNeighbourPass(over: world) }
        let list = landmarks
        let resolver: any AtlasVisitResolving = list.isEmpty
            ? opened : AtlasWithLandmarks(atlas: opened, landmarks: list)
        atlas = .ready(resolver)
        return resolver
    }

    /// Reads the passport if it hasn't been read; whether it is readable now.
    private func loadStore() -> Bool {
        guard !store.isLoaded else { return true }
        do {
            try store.load()
        } catch {
            FernletAuditLog.log("worldMap.passport.loadDeferred")
            return false
        }
        if !isDecoy { book = store.book }
        return true
    }

    /// The trip `visit`'s fix just started: its country's latest trip, with its number (a visit names one country,
    /// so a fix starts at most one trip).
    private func newTrip(in visit: AtlasVisit) -> PassportStamp? {
        guard let code = visit.countryCode else { return nil }
        let trips = store.book.trips(inCountry: code)
        guard trips.count > 1, let start = trips.last else { return nil }
        return PassportStamp(kind: .country, token: code, date: start, trip: trips.count)
    }

    /// Announces `trip` (the country comes first in the fixed order), then `found`, to the current reader.
    private func announce(_ found: [AtlasDiscovery], trip: PassportStamp?) {
        guard let subscriber else { return }
        if let trip { subscriber.yield(.newTrip(trip)) }
        for discovery in found.prefix(PassportBook.maxDiscoveriesPerVisit) {
            subscriber.yield(.firstVisit(discovery))
        }
    }
}
