import Foundation

/// A compact, bounded encoding for a set of fog cells: a version byte, then the cells' `Int64` ids
/// sorted ascending as unsigned LEB128 deltas. Lifted cells cluster (a neighbourhood, a walk), so most
/// deltas are small: a full store of ``FogCellStore/maxCells`` cells is about 2 MB, a usual one a few KB.
public nonisolated enum FogCellCodec {
    /// The format's version byte.
    static let version: UInt8 = 1

    /// The bytes for `cells`.
    public static func encode(_ cells: Set<HexCell>) -> Data {
        var data = Data([version])
        data.reserveCapacity(cells.count * 3 + 1)
        var previous: Int64 = 0
        for id in cells.map(\.id).sorted() {
            var delta = UInt64(bitPattern: id &- previous)
            previous = id
            for _ in 0..<10 {
                let low = UInt8(delta & 0x7F)
                delta >>= 7
                data.append(delta == 0 ? low : low | 0x80)
                if delta == 0 { break }
            }
        }
        return data
    }

    /// The cells in `data`, or nil when the bytes are not this format or would hold more than `limit`.
    public static func decode(_ data: Data, limit: Int) -> Set<HexCell>? {
        guard let first = data.first, first == version, limit >= 0 else { return nil }
        var cells = Set<HexCell>()
        var previous: Int64 = 0, value: UInt64 = 0, shift: UInt64 = 0
        for byte in data.dropFirst() {
            guard shift < 64 else { return nil }
            value |= UInt64(byte & 0x7F) << shift
            guard byte & 0x80 == 0 else { shift += 7; continue }
            previous = previous &+ Int64(bitPattern: value)
            guard let cell = HexCell(id: previous), cells.count < limit else { return nil }
            cells.insert(cell)
            value = 0
            shift = 0
        }
        return shift == 0 ? cells : nil
    }
}

/// The lifted fog: every coarse cell the World Home has uncovered, kept on this iPhone only (World app
/// plan step 5a; design page answers 4 and 21).
///
/// The cells live sealed in the ``WorldMapVault``; this type holds them in memory, adds to them, and
/// saves. While the phone is locked the store's key can't be used, so newly lifted cells go into the
/// locked-phone buffer (``appendPending(_:)``) and are merged on the next unlock (``drainPending()``).
///
/// Bounded (Power of 10): at most ``maxCells`` cells (a lifetime of walking around one city) and at most
/// ``maxPendingCells`` waiting in the buffer. Past either cap, new cells are refused and the refusal is
/// counted, never an eviction of old history.
///
/// It never decides whether to lift: the app's fog keeper does (location allowed, precise, "Uncover the
/// map as you go" on, no decoy session).
@MainActor
public final class FogCellStore {
    /// The most cells the store keeps.
    public static let maxCells = 250_000
    /// The most cells waiting in the locked-phone buffer.
    public static let maxPendingCells = 20_000

    /// The lifted cells.
    public private(set) var cells: Set<HexCell> = []
    /// Whether ``load()`` has read the store this session.
    public private(set) var isLoaded = false
    /// Cells refused because a cap was reached (an audit count; never shown).
    public private(set) var refusedCount = 0
    /// Whether ``cells`` has changes ``save()`` hasn't written yet.
    public private(set) var hasUnsavedChanges = false

    private let vault: WorldMapVault

    /// A store over `vault`. Call ``load()`` before using it.
    public init(vault: WorldMapVault) {
        self.vault = vault
    }

    /// Reads the store and merges any cells waiting in the buffer. A file that can't be opened (its key
    /// is gone, or it was damaged) is removed rather than kept forever as noise; the map just starts
    /// fresh. Throws only while the phone is locked (try again after unlock).
    public func load() throws {
        do {
            if let data = try vault.read(.fog) {
                cells = FogCellCodec.decode(data, limit: Self.maxCells) ?? []
            }
        } catch WorldMapVault.VaultError.keyUnavailable {
            throw WorldMapVault.VaultError.keyUnavailable
        } catch {
            vault.remove(.fog)
            cells = []
        }
        isLoaded = true
        try drainPending()
    }

    /// Adds `newCells`; returns how many were new. Refuses (and counts) what would pass ``maxCells``.
    @discardableResult
    public func lift(_ newCells: [HexCell]) -> Int {
        guard isLoaded else { return 0 }
        var added = 0
        for cell in newCells.prefix(Self.maxCells) where !cells.contains(cell) {
            guard cells.count < Self.maxCells else {
                refusedCount += 1
                continue
            }
            cells.insert(cell)
            added += 1
        }
        if added > 0 { hasUnsavedChanges = true }
        return added
    }

    /// Writes the cells to the vault (a no-op when nothing changed).
    public func save() throws {
        guard isLoaded, hasUnsavedChanges else { return }
        try vault.write(FogCellCodec.encode(cells), to: .fog)
        hasUnsavedChanges = false
    }

    /// Adds `newCells` to the locked-phone buffer, which works after the first unlock since boot even
    /// while the phone is locked. Refuses (and counts) what would pass ``maxPendingCells``.
    public func appendPending(_ newCells: [HexCell]) throws {
        guard !newCells.isEmpty else { return }
        var pending = try readPending()
        for cell in newCells.prefix(Self.maxPendingCells) {
            guard pending.count < Self.maxPendingCells else {
                refusedCount += 1
                continue
            }
            pending.insert(cell)
        }
        try vault.write(FogCellCodec.encode(pending), to: .pendingFog)
    }

    /// Merges the buffer into the store, saves, and empties the buffer; returns how many cells were new.
    /// Needs the store loaded (the phone unlocked).
    @discardableResult
    public func drainPending() throws -> Int {
        guard isLoaded else { return 0 }
        let pending = try readPending()
        guard !pending.isEmpty else {
            vault.remove(.pendingFog)
            return 0
        }
        let added = lift(Array(pending))
        try save()
        vault.remove(.pendingFog)
        return added
    }

    /// Forgets the cells in memory (the vault's ``WorldMapVault/clearAll()`` removes the files).
    public func forget() {
        cells = []
        hasUnsavedChanges = false
    }

    /// The buffer's cells (empty when there is none, or it can't be opened).
    private func readPending() throws -> Set<HexCell> {
        do {
            guard let data = try vault.read(.pendingFog) else { return [] }
            return FogCellCodec.decode(data, limit: Self.maxPendingCells) ?? []
        } catch WorldMapVault.VaultError.keyUnavailable {
            throw WorldMapVault.VaultError.keyUnavailable
        } catch {
            vault.remove(.pendingFog)
            return []
        }
    }
}
