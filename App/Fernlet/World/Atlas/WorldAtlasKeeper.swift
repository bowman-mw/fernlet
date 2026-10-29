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
/// **Duress.** A decoy (``setDecoy(_:)``) shows an empty passport and keeps nothing: no fix is read, nothing
/// is written and no discovery is announced. Every wipe reaches ``clearAll()`` through
/// `WorldFogKeeper.clearAll()` (Delete everything and the silent wipe via `FernletStore.resetAll()`, the
/// recovery lock's purge hook, and "Delete map history"), and the file lives in the vault's folder, which
/// `WorldMapVault.clearAll()` removes with its keys.
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
    @ObservationIgnored private var atlas: AtlasState = .notOpened
    @ObservationIgnored private var lastRead: GeoPoint?
    @ObservationIgnored private var subscriber: AsyncStream<AtlasDiscovery>.Continuation?

    /// A keeper over `vault`, opening the atlas with `openAtlas` when the first fix arrives (the app passes
    /// ``bundledPack(in:open:)``; tests pass a fake). `openAtlas` returns nil when there is no atlas.
    init(vault: WorldMapVault, openAtlas: @escaping @MainActor () -> (any AtlasVisitResolving)?) {
        self.store = PassportStore(vault: vault)
        self.openAtlas = openAtlas
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
        announce(found)
    }

    /// Enters or leaves a decoy session: entering shows an empty passport, leaving shows the person's again.
    func setDecoy(_ on: Bool) {
        guard on != isDecoy else { return }
        isDecoy = on
        lastRead = nil
        book = on ? PassportBook() : store.book
    }

    /// The wipe: forgets the passport and removes its file. Whether the file is gone.
    func clearAll() -> Bool {
        lastRead = nil
        book = PassportBook()
        return store.removeAll()
    }

    // MARK: The sealed backup

    /// The passport to put in the sealed iCloud backup, or nil in a decoy or while it can't be read.
    func bookForBackup() -> PassportBook? {
        guard !isDecoy, loadStore() else { return nil }
        return store.book
    }

    /// Merges a passport restored from the sealed backup into this one (by token, the earliest date kept).
    /// Whether it was merged and saved; never in a decoy. A restore announces nothing.
    func restore(_ restored: PassportBook) -> Bool {
        guard !isDecoy else { return false }
        do {
            _ = try store.restore(restored)
        } catch {
            FernletAuditLog.log("worldMap.passport.restoreFailed")
            return false
        }
        book = store.book
        return true
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

    /// The atlas, opened on first use; nil when it is missing or unreadable (the opener logs that, once).
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
            atlas = .ready(opened)
            return opened
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
        for discovery in found.prefix(AtlasDiscoveryKind.allCases.count) {
            subscriber.yield(discovery)
        }
    }
}
