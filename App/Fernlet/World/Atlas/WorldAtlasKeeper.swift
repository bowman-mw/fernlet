import FernletFoundation
import Foundation
import WorldMapStore

/// Keeps the World passport (round 7, idea 4; owner 2026-10-29): reads each fix the fog keeper accepted
/// against the bundled atlas and records the first visits in the sealed ``PassportStore``.
///
/// **Which fixes.** `WorldFogKeeper` owns this keeper and calls ``observe(point:at:)`` only for fixes it
/// accepted (precise, accurate to 65 m, "Uncover the map as you go" on), only while the phone is unlocked,
/// and never in a decoy. Fixes closer than ``minimumSpacing`` to the last one read are skipped, since a
/// border, a coast or a city edge is never that close to two answers.
///
/// **The atlas** is the bundled `WorldAtlas.pack`, opened once, the first time a fix arrives
/// (``bundledPack(in:open:)``). A missing or unreadable pack means the passport records nothing this session
/// and `FernletAuditLog` notes it once; the map and the fog carry on.
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
/// merges a restored one by token keeping the earliest date, and ``onPassportChanged`` tells the store
/// the passport's backup owes an upload.
///
/// **Discoveries for Sprout** (idea B). ``discoveries()`` is a stream of each first visit, announced only
/// after it is saved, at most ``eventBufferSize`` held for a slow reader (the newest kept). The companion
/// hooks in later; nothing reads it yet.
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
    @ObservationIgnored private let openLandmarks: @MainActor () -> WorldLandmarks
    @ObservationIgnored private var atlas: AtlasState = .notOpened
    @ObservationIgnored private var openedLandmarks: WorldLandmarks?
    @ObservationIgnored private var lastRead: GeoPoint?
    @ObservationIgnored private var subscriber: AsyncStream<AtlasDiscovery>.Continuation?
    /// Runs after the passport on disk changed for the sealed backup's sake: a first visit was saved, or
    /// ``clearAll()`` removed it. The store sets it to mark the passport's own backup owed
    /// (`markSealedBackupDirty(.worldPassport)`), so the next export writes the new passport, or an empty
    /// one over a deleted one. A restore does not run it (the restore marks the payload owed itself). Nil
    /// (tests) does nothing.
    @ObservationIgnored var onPassportChanged: (@MainActor () -> Void)?

    /// A keeper over `vault`, opening the atlas with `openAtlas` when the first fix arrives (the app passes
    /// ``bundledPack(in:open:)``; tests pass a fake). `openAtlas` returns nil when there is no atlas.
    /// `openLandmarks` opens the landmark list on first use (the app passes ``bundledLandmarks(in:)``); the
    /// default is no landmarks.
    init(vault: WorldMapVault, openAtlas: @escaping @MainActor () -> (any AtlasVisitResolving)?,
         openLandmarks: @escaping @MainActor () -> WorldLandmarks = { .empty }) {
        self.store = PassportStore(vault: vault)
        self.openAtlas = openAtlas
        self.openLandmarks = openLandmarks
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

    // MARK: The fog keeper's calls

    /// Reads the passport when no decoy is showing and it hasn't been read yet (the fog keeper's `load()`,
    /// which runs only while the phone is unlocked).
    func load() {
        guard !isDecoy, !store.isLoaded else { return }
        guard loadStore() else { return }
        book = store.book
    }

    /// Reads one accepted fix at `point`, taken at `date`, and records its first visits; each is announced
    /// on ``discoveries()`` once saved. Nothing in a decoy, before the passport can be read, or without an atlas.
    func observe(point: GeoPoint, at date: Date) {
        guard !isDecoy, point.isValid else { return }
        if let last = lastRead, last.distance(to: point) < Self.minimumSpacing { return }
        guard let resolver = resolver(), loadStore() else { return }
        let found: [AtlasDiscovery]
        do {
            found = try store.record(resolver.visit(at: point), at: date)
        } catch {
            FernletAuditLog.log("worldMap.passport.saveDeferred")
            return
        }
        lastRead = point
        guard !found.isEmpty else { return }
        book = store.book
        onPassportChanged?()
        announce(found)
    }

    /// Enters or leaves a decoy session: entering shows an empty passport, leaving shows the person's again.
    func setDecoy(_ on: Bool) {
        guard on != isDecoy else { return }
        isDecoy = on
        lastRead = nil
        book = on ? PassportBook() : store.book
    }

    /// The wipe: forgets the passport and removes its file, then runs ``onPassportChanged`` so the
    /// passport's backup drops its copy at the next export (a wipe that deletes the backup itself owes
    /// nothing: the store's dirty mark is a no-op during Delete everything). Whether the file is gone.
    func clearAll() -> Bool {
        lastRead = nil
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

    /// A stream of each first visit, announced once it is saved, holding at most ``eventBufferSize`` for a
    /// slow reader. One reader at a time (Sprout's lines): asking again ends the previous stream.
    func discoveries() -> AsyncStream<AtlasDiscovery> {
        subscriber?.finish()
        let (stream, continuation) = AsyncStream<AtlasDiscovery>.makeStream(
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

    private func resolver() -> (any AtlasVisitResolving)? {
        switch atlas {
        case .ready(let resolver):
            return resolver
        case .unavailable:
            return nil
        case .notOpened:
            guard let opened = openAtlas() else {
                atlas = .unavailable
                return nil
            }
            let list = landmarks
            let resolver: any AtlasVisitResolving = list.isEmpty
                ? opened : AtlasWithLandmarks(atlas: opened, landmarks: list)
            atlas = .ready(resolver)
            return resolver
        }
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

    /// Announces `found` to the current reader, in order.
    private func announce(_ found: [AtlasDiscovery]) {
        guard let subscriber else { return }
        for discovery in found.prefix(PassportBook.maxDiscoveriesPerVisit) {
            subscriber.yield(discovery)
        }
    }
}
