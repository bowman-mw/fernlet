import FernletCrypto
import FernletFoundation
import Foundation

/// The week's corner as kept on disk (round 7, spec §5): which week it was picked for, the cell, and whether
/// the person walked into it. Nothing else: no history of past corners, no count, no streak.
///
/// Frozen at rest (``encoded()``): a version byte (1), the week start as a big-endian `Double` of seconds
/// since 1970, the cell's ``HexCell/id`` as a big-endian `Int64`, and a reached byte (0 or 1): 18 bytes.
public nonisolated struct FogCornerState: Equatable, Sendable {
    /// The format's version byte.
    static let version: UInt8 = 1
    /// The encoded length in bytes.
    static let encodedLength = 18

    /// The Monday 00:00 the week began (``FogCornerNudge/weekStart(for:calendar:)``).
    public var weekStart: Date
    /// The corner.
    public var cell: HexCell
    /// Whether the person walked into it (the fog keeper lifted it).
    public var reached: Bool

    /// A corner `cell` for the week starting `weekStart`.
    public init(weekStart: Date, cell: HexCell, reached: Bool = false) {
        self.weekStart = weekStart
        self.cell = cell
        self.reached = reached
    }

    /// The state's bytes.
    public func encoded() -> Data {
        var data = Data([Self.version])
        var seconds = weekStart.timeIntervalSince1970.bitPattern.bigEndian
        data.append(Data(bytes: &seconds, count: 8))
        var id = cell.id.bigEndian
        data.append(Data(bytes: &id, count: 8))
        data.append(reached ? 1 : 0)
        return data
    }

    /// The state in `data`, or nil when the bytes are not this format (wrong length or version, a date that
    /// is not finite, a cell id off the grid, a reached byte other than 0 or 1).
    public init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == Self.encodedLength, bytes[0] == Self.version, bytes[17] <= 1 else { return nil }
        let seconds = Double(bitPattern: Self.uint64(bytes, at: 1))
        guard seconds.isFinite,
              let cell = HexCell(id: Int64(bitPattern: Self.uint64(bytes, at: 9))) else { return nil }
        self.init(weekStart: Date(timeIntervalSince1970: seconds), cell: cell, reached: bytes[17] == 1)
    }

    /// The big-endian 64-bit value at `offset` (eight bytes, the loop's bound).
    private static func uint64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= bytes.count else { return 0 }
        var value: UInt64 = 0
        for byte in bytes[offset..<(offset + 8)] { value = value << 8 | UInt64(byte) }
        return value
    }
}

/// The week's corner on this iPhone, so a pick survives relaunches (round 7, spec §5).
///
/// One tiny sealed file in the ``WorldMapVault`` (``WorldMapVault/File/corner``, `corner.bin`,
/// `AEAD.worldMapCornerV1`, the vault's when-unlocked store key) holding one ``FogCornerState``, read afresh
/// on each ``load()`` (18 bytes). Like ``PassportStore``: a key that can't be read right now is an error,
/// never a reason to mint a new one over it; a file that can't be opened (its key gone, its bytes damaged, a
/// version this build does not read) is removed, and there is no corner until the next pick. It never
/// decides anything: the app's `WorldCornerNudgeKeeper` picks (``FogCornerNudge``), never in a decoy.
@MainActor
public final class FogCornerStore {
    private let vault: WorldMapVault

    /// A store over `vault`; nothing is read until ``load()``.
    public init(vault: WorldMapVault) {
        self.vault = vault
    }

    /// The kept corner, or nil when there is none. An unopenable or unreadable file is removed and reads as
    /// none. Throws only when the key can't be read right now (the phone is locked: try again after unlock).
    public func load() throws -> FogCornerState? {
        do {
            guard let data = try vault.read(.corner) else { return nil }
            guard let state = FogCornerState(data: data) else { throw WorldMapVault.VaultError.unopenable }
            return state
        } catch WorldMapVault.VaultError.keyUnavailable {
            throw WorldMapVault.VaultError.keyUnavailable
        } catch {
            vault.remove(.corner)
            FernletAuditLog.log("worldMap.corner.unopenableRemoved")
            return nil
        }
    }

    /// Seals `state` as the corner file, replacing any before it.
    public func save(_ state: FogCornerState) throws {
        try vault.write(state.encoded(), to: .corner)
    }

    /// Removes the corner file; whether it is gone. (Every wipe also reaches it through
    /// ``WorldMapVault/clearAll()``, which removes the whole folder and both keys.)
    public func removeAll() -> Bool {
        vault.remove(.corner)
    }
}
