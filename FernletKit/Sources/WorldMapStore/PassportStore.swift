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
/// written at once whenever a visit adds a first visit (they are rare), so nothing waits in memory, and a
/// save that fails leaves the book as it was, so the same first visit is found again on a later fix.
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

    private let vault: WorldMapVault

    /// A store over `vault`. Call ``load()`` before recording.
    public init(vault: WorldMapVault) {
        self.vault = vault
    }

    /// Reads the passport. An unopenable or unreadable file is removed and the book starts empty. Throws only
    /// when the key can't be read right now (the phone is locked: try again after unlock).
    public func load() throws {
        do {
            book = try vault.read(.passport).map(PassportBook.init(data:)) ?? PassportBook()
        } catch WorldMapVault.VaultError.keyUnavailable {
            throw WorldMapVault.VaultError.keyUnavailable
        } catch {
            vault.remove(.passport)
            book = PassportBook()
            FernletAuditLog.log("worldMap.passport.unopenableRemoved")
        }
        isLoaded = true
    }

    /// Records `visit` at `date`, saves when it added anything, and returns only its first visits in the fixed
    /// order (``PassportBook/record(_:at:)``). Nothing before ``load()``. When the save fails the book is left
    /// as it was and the error is thrown, so a discovery is reported only once it is on disk.
    public func record(_ visit: AtlasVisit, at date: Date) throws -> [AtlasDiscovery] {
        guard isLoaded, !book.newDiscoveries(in: visit, at: date).isEmpty else { return [] }
        let before = book
        let found = book.record(visit, at: date)
        guard !found.isEmpty else { return [] }
        do {
            try write()
        } catch {
            book = before
            throw error
        }
        return found
    }

    /// Merges a passport restored from the sealed backup into this one (by token, the earliest date kept) and
    /// saves; returns how many entries were added or moved earlier. Loads first when needed. A failed save
    /// leaves the book as it was and throws.
    public func restore(_ restored: PassportBook) throws -> Int {
        if !isLoaded { try load() }
        let before = book
        let changed = book.merge(restored)
        guard changed > 0 else { return 0 }
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
        return vault.remove(.passport)
    }

    /// Seals the book as the passport file.
    private func write() throws {
        try vault.write(try book.encoded(), to: .passport)
    }
}
