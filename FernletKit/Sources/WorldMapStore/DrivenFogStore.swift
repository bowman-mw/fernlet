import Foundation

/// The cells only driven past, never walked (owner 2026-11-09: "driven should be mostly transparent but still there,
/// then you fully unlock when you walk"). Kept beside ``FogCellStore``, which still holds every uncovered cell, so
/// what counts a drive (the passport, the city card, furthest from home) is unchanged; the map draws these as
/// see-through fog, and the week's corner leaves them to be walked.
///
/// - **A drive** adds the cells it newly uncovered (``add(_:)``); one already walked never becomes driven.
/// - **A walk** (or a bike ride) takes the cells it reaches out (``remove(_:)``): walked is walked for good.
/// - **The history from before** has no driven cells: everything uncovered so far stays clear (owner's pick).
/// - **While the phone is locked** a drive's cells go into this store's own locked-phone buffer
///   (``appendPending(_:)``), and ``takePending()`` hands them over at the next unlock, when the fog keeper merges
///   them knowing what was walked meanwhile.
///
/// Sealed in the ``WorldMapVault`` (`fog-driven.bin`, the fog's purpose and key under its own context; the buffer
/// `fog-pending-driven.bin` under the buffer's). Bounded (Power of 10): at most ``FogCellStore/maxCells`` cells and
/// ``FogCellStore/maxPendingCells`` waiting; past a cap new cells are refused and counted.
@MainActor
public final class DrivenFogStore {
    /// The cells only driven past.
    public private(set) var cells: Set<HexCell> = []
    /// Whether ``load()`` has read the store this session.
    public private(set) var isLoaded = false
    /// Cells refused because a cap was reached (an audit count; never shown).
    public private(set) var refusedCount = 0
    private var hasUnsavedChanges = false
    private let vault: WorldMapVault

    /// A store over `vault`. Call ``load()`` before using it.
    public init(vault: WorldMapVault) {
        self.vault = vault
    }

    /// Reads the store (the buffer waits for ``takePending()``). A file that can't be opened is removed, and the
    /// driven cells simply show as walked. Throws only while the phone is locked.
    public func load() throws {
        do {
            if let data = try vault.read(.drivenFog) {
                cells = FogCellCodec.decode(data, limit: FogCellStore.maxCells) ?? []
            }
        } catch WorldMapVault.VaultError.keyUnavailable {
            throw WorldMapVault.VaultError.keyUnavailable
        } catch {
            vault.remove(.drivenFog)
            cells = []
        }
        isLoaded = true
    }

    /// Marks `newCells` as only driven past; returns how many were new.
    @discardableResult
    public func add(_ newCells: [HexCell]) -> Int {
        guard isLoaded else { return 0 }
        var added = 0
        for cell in newCells.prefix(FogCellStore.maxCells) where !cells.contains(cell) {
            guard cells.count < FogCellStore.maxCells else {
                refusedCount += 1
                continue
            }
            cells.insert(cell)
            added += 1
        }
        if added > 0 { hasUnsavedChanges = true }
        return added
    }

    /// Takes `walked` out (walked or ridden through); returns how many were driven.
    @discardableResult
    public func remove(_ walked: some Sequence<HexCell>) -> Int {
        guard isLoaded, !cells.isEmpty else { return 0 }
        let before = cells.count
        cells.subtract(walked)
        let removed = before - cells.count
        if removed > 0 { hasUnsavedChanges = true }
        return removed
    }

    /// Writes the cells (a no-op when nothing changed).
    public func save() throws {
        guard isLoaded, hasUnsavedChanges else { return }
        try vault.write(FogCellCodec.encode(cells), to: .drivenFog)
        hasUnsavedChanges = false
    }

    /// Adds a drive's `newCells` to the locked-phone buffer (works after the first unlock since boot, even locked).
    public func appendPending(_ newCells: [HexCell]) throws {
        guard !newCells.isEmpty else { return }
        var pending = try readPending()
        for cell in newCells.prefix(FogCellStore.maxPendingCells) {
            guard pending.count < FogCellStore.maxPendingCells else {
                refusedCount += 1
                continue
            }
            pending.insert(cell)
        }
        try vault.write(FogCellCodec.encode(pending), to: .pendingDriven)
    }

    /// The cells driven past while the phone was locked, emptying the buffer.
    public func takePending() throws -> Set<HexCell> {
        let pending = try readPending()
        vault.remove(.pendingDriven)
        return pending
    }

    /// Forgets the cells in memory (the vault's ``WorldMapVault/clearAll()`` removes the files).
    public func forget() {
        cells = []
        hasUnsavedChanges = false
    }

    /// The buffer's cells (empty when there is none, or it can't be opened).
    private func readPending() throws -> Set<HexCell> {
        do {
            guard let data = try vault.read(.pendingDriven) else { return [] }
            return FogCellCodec.decode(data, limit: FogCellStore.maxPendingCells) ?? []
        } catch WorldMapVault.VaultError.keyUnavailable {
            throw WorldMapVault.VaultError.keyUnavailable
        } catch {
            vault.remove(.pendingDriven)
            return []
        }
    }
}
