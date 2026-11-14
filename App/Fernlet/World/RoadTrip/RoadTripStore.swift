import FernletFoundation
import Foundation
import WorldMapStore

/// Seals the road trips in the map's vault (World-RoadTrip-Spec §2.9: "kept on each phone like a walk's line:
/// sealed, never synced, deleted with map history").
///
/// - **The book** (``RoadTripBook``) is `road-trips.bin` (`WorldMapVault/File/roadTrips`): the device side's purpose
///   and the buffer key, under its own context.
/// - **Each trip's line** is in pieces, `road-trip-line-<trip>-<piece>.bin` (`WorldMapVault/File/roadTripLine(trip:chunk:)`):
///   the walk lines' purpose and the buffer key, bound to the trip and the piece.
///
/// Both use the buffer key (`AfterFirstUnlockThisDeviceOnly`), because the iPhone that maps is in a pocket: the line
/// is appended, and a locked launch reads whether it maps, with the phone locked. A file that can't be opened (its
/// key gone, its bytes damaged) is removed, as every vault file is; a key that can't be read right now throws
/// `WorldMapVault/VaultError/keyUnavailable` (only before the first unlock since the phone started). Every wipe and
/// Delete map history remove every file with the vault's folder (`WorldFogKeeper.clearAll()`). Never in a decoy (the
/// keeper's gate). Nothing here is synced, backed up, exported or given to the AI.
@MainActor
final class RoadTripStore {
    private let vault: WorldMapVault

    /// A store over `vault`.
    init(vault: WorldMapVault) {
        self.vault = vault
    }

    /// The book: empty when none was written (or it can't be opened any more, when it is removed). Throws only when
    /// the key can't be read right now.
    func readBook() throws -> RoadTripBook {
        let file = WorldMapVault.File.roadTrips
        let data: Data?
        do {
            data = try vault.read(file)
        } catch WorldMapVault.VaultError.keyUnavailable {
            throw WorldMapVault.VaultError.keyUnavailable
        } catch {
            FernletAuditLog.log("worldMap.roadTrip.bookUnopenable")
            vault.remove(file)
            return .empty
        }
        guard let data else { return .empty }
        do {
            return try JSONDecoder().decode(RoadTripBook.self, from: data).validated()
        } catch {
            FernletAuditLog.log("worldMap.roadTrip.bookUnreadable")
            vault.remove(file)
            return .empty
        }
    }

    /// Seals `book`. Whether it was written.
    func saveBook(_ book: RoadTripBook) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try vault.write(try encoder.encode(book), to: .roadTrips)
            return true
        } catch {
            FernletAuditLog.log("worldMap.roadTrip.bookSaveFailed")
            return false
        }
    }

    /// The pieces of `trip`'s line on this iPhone, in order (at most ``RoadTripLine/maxChunks``).
    func chunks(of trip: UUID) throws -> [Int] {
        let prefix = WorldMapVault.File.roadTripLinePrefix(trip: trip)
        let names = try vault.fileNames(withPrefix: prefix, limit: RoadTripLine.maxChunks + 1)
        let indices = names.compactMap { name -> Int? in
            guard name.hasSuffix(".bin") else { return nil }
            return Int(name.dropFirst(prefix.count).dropLast(".bin".count))
        }
        return Array(indices.filter { (0..<RoadTripLine.maxChunks).contains($0) }.sorted().prefix(RoadTripLine.maxChunks))
    }

    /// Piece `chunk` of `trip`'s line: empty when it doesn't exist (or can't be opened, when it is removed). Throws
    /// only when the key can't be read right now.
    func readChunk(_ chunk: Int, of trip: UUID) throws -> [RoadTripPoint] {
        let file = WorldMapVault.File.roadTripLine(trip: trip, chunk: chunk)
        do {
            guard let data = try vault.read(file) else { return [] }
            guard let points = RoadTripLineCodec.decode(data) else {
                FernletAuditLog.log("worldMap.roadTrip.chunkUnreadable")
                vault.remove(file)
                return []
            }
            return points
        } catch WorldMapVault.VaultError.keyUnavailable {
            throw WorldMapVault.VaultError.keyUnavailable
        } catch {
            FernletAuditLog.log("worldMap.roadTrip.chunkUnopenable")
            vault.remove(file)
            return []
        }
    }

    /// Seals `points` as piece `chunk` of `trip`'s line. Whether it was written.
    func saveChunk(_ points: [RoadTripPoint], chunk: Int, of trip: UUID) -> Bool {
        guard !points.isEmpty, (0..<RoadTripLine.maxChunks).contains(chunk) else { return false }
        do {
            try vault.write(RoadTripLineCodec.encode(points), to: .roadTripLine(trip: trip, chunk: chunk))
            return true
        } catch {
            FernletAuditLog.log("worldMap.roadTrip.chunkSaveFailed")
            return false
        }
    }
}
