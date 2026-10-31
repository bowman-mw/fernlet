import FernletFoundation
import Foundation

/// What the passport needs from the atlas: the visit one accepted fix makes, with the visit rules already
/// applied (ocean reach, Antarctica, the city boundary). The bundled `WorldAtlas` conforms; tests pass a fake.
public nonisolated protocol AtlasVisitResolving: Sendable {
    /// Everything the atlas says about a fix at `point`.
    func visit(at point: GeoPoint) -> AtlasVisit
    /// Whether the atlas puts water at `point` (the weekly corner skips water, owner 2026-10-29). The default
    /// reads ``visit(at:)``'s terrain; the bundled atlas answers from its land mask alone.
    func isWater(at point: GeoPoint) -> Bool
}

extension AtlasVisitResolving {
    /// Water when ``visit(at:)`` says the terrain is water.
    public func isWater(at point: GeoPoint) -> Bool {
        visit(at: point).terrain == .water
    }
}

/// The World passport on this iPhone (round 7, idea 4; owner 2026-10-29: sealed like journal text,
/// device-local, and also carried in Fernlet's encrypted sealed iCloud backup).
///
/// One sealed file in the ``WorldMapVault`` (``WorldMapVault/File/passport``, `passport.bin`,
/// `AEAD.worldMapPassportV1`, the vault's when-unlocked store key) holding a ``PassportBook``. The book is
/// written at once whenever a visit adds a first visit or starts a trip (they are rare), so no stamp waits in
/// memory, and a save that fails leaves the book as it was, so the same first visit or trip is found again on a
/// later fix. A fix that only moves a country's clock on (``PassportBook/lastSeen(inCountry:)``) is written at
/// most once per ``clockWriteInterval`` for that country, so a relaunch loses at most that much of it.
///
/// Like ``FogCellStore``: a key that can't be read right now is an error, never a reason to mint a new one
/// over it; a file that can't be opened (its key gone, its bytes damaged, a version this build does not read)
/// is removed, and the passport starts fresh. It never decides whether a fix counts: the app's
/// `WorldAtlasKeeper` does (fixes the fog keeper accepted, unlocked, never in a decoy).
@MainActor
public final class PassportStore {
    /// The passport as last read or saved.
    public private(set) var book = PassportBook()
    /// Whether ``load()`` has read the file this session.
    public private(set) var isLoaded = false
    /// The least advance of a country's clock that is written on its own: an hour, against the 7-day trip gap.
    public static let clockWriteInterval: TimeInterval = 60 * 60

    private let vault: WorldMapVault
    /// The book as last read or saved (its clocks are what a relaunch would read).
    private var written = PassportBook()

    /// A store over `vault`. Call ``load()`` before recording.
    public init(vault: WorldMapVault) {
        self.vault = vault
    }

    /// Reads the passport. An unopenable or unreadable file is removed and the book starts empty. Throws only
    /// when the key can't be read right now (the phone is locked: try again after unlock).
    public func load() throws {
        do {
            book = try vault.read(.passport).map(PassportBook.init(data:)) ?? PassportBook()
            written = book
        } catch WorldMapVault.VaultError.keyUnavailable {
            throw WorldMapVault.VaultError.keyUnavailable
        } catch {
            vault.remove(.passport)
            book = PassportBook()
            written = book
            FernletAuditLog.log("worldMap.passport.unopenableRemoved")
        }
        isLoaded = true
    }

    /// Records `visit` at `date` and returns only its first visits in the fixed order
    /// (``PassportBook/record(_:at:)``); a trip it starts shows in ``PassportBook/trips(inCountry:)``. Saves when
    /// it added a first visit or a trip, or moved its country's clock on by ``clockWriteInterval`` since the last
    /// save. Nothing before ``load()``. When the save fails the book is left as it was and the error is thrown, so
    /// a discovery or trip is reported only once it is on disk.
    public func record(_ visit: AtlasVisit, at date: Date) throws -> [AtlasDiscovery] {
        guard isLoaded else { return [] }
        let before = book, tripsBefore = book.returnCount
        let found = book.record(visit, at: date)
        guard !found.isEmpty || book.returnCount != tripsBefore || clockIsOwed(visit.countryCode) else { return found }
        do {
            try write()
        } catch {
            book = before
            throw error
        }
        return found
    }

    /// Records the person at the airport `token` at `date`, found by `find` (``PassportBook/recordAirport(token:at:by:)``,
    /// World-Airports-Spec §3), and returns what the passport announces, if anything. Saves whenever the book
    /// changed (airports are found and landed at rarely, so the clock is written with them). Nothing before
    /// ``load()``. When the save fails the book is left as it was and the error is thrown, so a find or trip is
    /// announced only once it is on disk.
    public func recordAirport(token: String, at date: Date, by find: PassportBook.AirportFind) throws -> PassportEvent? {
        try update { $0.recordAirport(token: token, at: date, by: find) } ?? nil
    }

    /// Applies `change` to the book (a layover mark, flights added or removed, the upcoming list) and saves it
    /// when it changed; returns what `change` returned. Nothing before ``load()`` (`change` is not applied and nil
    /// is returned). When the save fails the book is left as it was and the error is thrown.
    @discardableResult
    public func update<Result>(_ change: (inout PassportBook) -> Result) throws -> Result? {
        guard isLoaded else { return nil }
        let before = book
        let result = change(&book)
        guard book != before else { return result }
        do {
            try write()
        } catch {
            book = before
            throw error
        }
        return result
    }

    /// Whether the clock of the country `code` has moved on by ``clockWriteInterval`` since it was last saved
    /// (or was never saved).
    private func clockIsOwed(_ code: String?) -> Bool {
        guard let code, let now = book.lastSeen(inCountry: code) else { return false }
        guard let saved = written.lastSeen(inCountry: code) else { return true }
        return now.timeIntervalSince(saved) >= Self.clockWriteInterval
    }

    /// Merges a passport restored from the sealed backup into this one (by token, the earliest date kept; a
    /// country's trips each once, ``PassportBook/merge(_:)``) and saves; returns how many entries or trips were
    /// added or moved earlier. Loads first when needed. A failed save leaves the book as it was and throws.
    public func restore(_ restored: PassportBook) throws -> Int {
        if !isLoaded { try load() }
        let before = book
        let changed = book.merge(restored)
        guard book != before else { return 0 }
        do {
            try write()
        } catch {
            book = before
            throw error
        }
        return changed
    }

    /// Forgets the book in memory and removes the file; whether the file is gone. (Every wipe also reaches the
    /// file through ``WorldMapVault/clearAll()``, which removes the whole folder and both keys.)
    public func removeAll() -> Bool {
        book = PassportBook()
        written = book
        return vault.remove(.passport)
    }

    /// Seals the book as the passport file and notes the clocks it holds.
    private func write() throws {
        try vault.write(try book.encoded(), to: .passport)
        written = book
    }
}
