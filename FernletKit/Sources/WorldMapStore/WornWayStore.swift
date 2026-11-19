import Foundation

/// The binary format of the worn-way counter and its locked-phone buffer: a version byte, the record count as a
/// little-endian `UInt32`, then fixed-size little-endian records.
///
/// - The counter's record (13 bytes): cell id `Int64`, kind `UInt8`, count `UInt16`, last day `UInt16`.
/// - The buffer's record (11 bytes): cell id `Int64`, kind `UInt8`, day `UInt16`.
///
/// Decoding rejects a wrong version, a size that doesn't match the count, an unknown kind, a cell id outside the grid,
/// a repeated key and more records than the limit.
public nonisolated enum WornWayCodec {
    /// The format's version byte (both files).
    static let version: UInt8 = 1
    /// Bytes before the first record: the version and the count.
    static let headerSize = 5
    /// Bytes in one counter record.
    static let recordSize = 13
    /// Bytes in one buffer record.
    static let pendingRecordSize = 11

    /// The counter's bytes for `tallies`, sorted by key so the same tallies always make the same bytes.
    public static func encode(_ tallies: [WornWayKey: WornTally]) -> Data {
        var data = header(count: tallies.count, recordSize: recordSize)
        for key in tallies.keys.sorted() {
            guard let tally = tallies[key] else { continue }
            append(key.cell.id, to: &data)
            data.append(key.kind.rawValue)
            append(tally.count, to: &data)
            append(tally.lastDay, to: &data)
        }
        return data
    }

    /// The tallies in `data`, or nil when the bytes are not this format or hold more than `limit` records.
    public static func decode(_ data: Data, limit: Int) -> [WornWayKey: WornTally]? {
        guard let count = recordCount(data, recordSize: recordSize, limit: limit) else { return nil }
        let bytes = [UInt8](data)
        var tallies: [WornWayKey: WornTally] = [:]
        tallies.reserveCapacity(count)
        // Bounded: `count` ≤ `limit`, checked above.
        for index in 0..<count {
            let start = headerSize + index * recordSize
            guard let key = key(bytes, at: start), tallies[key] == nil else { return nil }
            tallies[key] = WornTally(count: readUInt16(bytes, at: start + 9), lastDay: readUInt16(bytes, at: start + 11))
        }
        return tallies
    }

    /// The buffer's bytes for `records` (a way and the day it was passed), in the order given.
    public static func encodePending(_ records: [(WornWayKey, UInt16)]) -> Data {
        var data = header(count: records.count, recordSize: pendingRecordSize)
        for (key, day) in records {
            append(key.cell.id, to: &data)
            data.append(key.kind.rawValue)
            append(day, to: &data)
        }
        return data
    }

    /// The buffer's records in `data`, or nil when the bytes are not this format or hold more than `limit` records.
    public static func decodePending(_ data: Data, limit: Int) -> [(WornWayKey, UInt16)]? {
        guard let count = recordCount(data, recordSize: pendingRecordSize, limit: limit) else { return nil }
        let bytes = [UInt8](data)
        var records: [(WornWayKey, UInt16)] = []
        records.reserveCapacity(count)
        // Bounded: `count` ≤ `limit`, checked above.
        for index in 0..<count {
            let start = headerSize + index * pendingRecordSize
            guard let key = key(bytes, at: start) else { return nil }
            records.append((key, readUInt16(bytes, at: start + 9)))
        }
        return records
    }

    /// The version and `count`, with room for the records.
    private static func header(count: Int, recordSize: Int) -> Data {
        var data = Data([version])
        data.reserveCapacity(headerSize + count * recordSize)
        append(UInt32(clamping: count), to: &data)
        return data
    }

    /// The record count `data`'s header states, when the version is right, the size matches and it is within `limit`.
    private static func recordCount(_ data: Data, recordSize: Int, limit: Int) -> Int? {
        guard data.count >= headerSize, data.first == version, limit >= 0 else { return nil }
        let bytes = [UInt8](data.prefix(headerSize))
        var count = 0
        for shift in 0..<4 { count |= Int(bytes[1 + shift]) << (8 * shift) }
        guard count <= limit, data.count == headerSize + count * recordSize else { return nil }
        return count
    }

    /// The key at `start`: a cell id and a known kind.
    private static func key(_ bytes: [UInt8], at start: Int) -> WornWayKey? {
        var id: UInt64 = 0
        for shift in 0..<8 { id |= UInt64(bytes[start + shift]) << (8 * UInt64(shift)) }
        guard let cell = HexCell(id: Int64(bitPattern: id)), let kind = WornWayKind(rawValue: bytes[start + 8]) else { return nil }
        return WornWayKey(cell: cell, kind: kind)
    }

    /// The little-endian `UInt16` at `start`.
    private static func readUInt16(_ bytes: [UInt8], at start: Int) -> UInt16 {
        UInt16(bytes[start]) | UInt16(bytes[start + 1]) << 8
    }

    /// Appends `value` little-endian.
    private static func append<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
        // Bounded: at most 8 bytes.
        for index in 0..<(Value.bitWidth / 8) { data.append(UInt8(truncatingIfNeeded: value >> (8 * index))) }
    }
}

/// The frequent-roads counter (Docs/World-Frequent-Paths-Exploration-2026-11-15.md §8, option B): for each cell a
/// drive passed along, how many trips and the day of the last, keyed by (cell, ``WornWayKind``) so rail and ferry can
/// join later. Only ``WornWayKind/road`` is written today. The map draws a road's look from ``WornTally``.
///
/// - **One trip** counts a cell once (``record(_:kind:on:)``); the fog keeper decides what a trip is.
/// - **While the phone is locked** a trip's cells go into this store's own locked-phone buffer
///   (``appendPending(_:kind:on:)``) with their day, and ``pending()`` hands them over at the next unlock (``clearPending()`` empties the buffer once they are saved).
///
/// Sealed in the ``WorldMapVault`` (`fog-ways.bin`, the fog's purpose and key under its own context; the buffer
/// `fog-pending-ways.bin` under the buffer's): device-only, excluded from backup, never synced, exported, given to the
/// AI or sent to friends, and removed with the vault's folder by ``WorldMapVault/clearAll()``. Bounded (Power of 10):
/// at most ``FogCellStore/maxCells`` ways and ``FogCellStore/maxPendingCells`` waiting; past a cap new ones are
/// refused and counted, never an eviction.
@MainActor
public final class WornWayStore {
    /// Each way's tally.
    public private(set) var tallies: [WornWayKey: WornTally] = [:]
    /// Whether ``load()`` has read the store this session.
    public private(set) var isLoaded = false
    /// Ways refused because a cap was reached (an audit count; never shown).
    public private(set) var refusedCount = 0
    private var hasUnsavedChanges = false
    private let vault: WorldMapVault

    /// A store over `vault`. Call ``load()`` before using it.
    public init(vault: WorldMapVault) {
        self.vault = vault
    }

    /// Reads the counter (the buffer waits for ``pending()``). A file that can't be opened is removed, and the
    /// counting starts again. Throws only while the phone is locked.
    public func load() throws {
        do {
            if let data = try vault.read(.wornWays) {
                tallies = WornWayCodec.decode(data, limit: FogCellStore.maxCells) ?? [:]
            }
        } catch let error as WorldMapVault.VaultError where error.isTryAgainLater {
            throw error
        } catch {
            vault.remove(.wornWays)
            tallies = [:]
        }
        isLoaded = true
    }

    /// Counts one trip of `kind` on `day` through each of `cells` (a cell named twice counts once); returns how many
    /// were counted. A new way past ``FogCellStore/maxCells`` is refused. Nothing before ``load()``.
    @discardableResult
    public func record(_ cells: some Sequence<HexCell>, kind: WornWayKind, on day: UInt16) -> Int {
        guard isLoaded else { return 0 }
        let thresholds = WornThresholds.forKind(kind)
        var counted = 0
        // Bounded: at most FogCellStore.maxCells distinct cells.
        for cell in Set(cells.prefix(FogCellStore.maxCells)) {
            let key = WornWayKey(cell: cell, kind: kind)
            if var tally = tallies[key] {
                tally.pass(on: day, thresholds: thresholds)
                tallies[key] = tally
            } else {
                guard tallies.count < FogCellStore.maxCells else {
                    refusedCount += 1
                    continue
                }
                tallies[key] = .first(on: day)
            }
            counted += 1
        }
        if counted > 0 { hasUnsavedChanges = true }
        return counted
    }

    /// Takes one trip of `kind` back out of each of `cells` (a kept trip changed or forgotten, ferry and train build):
    /// the count drops by one and the last day stays; a way whose count reaches zero goes. A cell named twice counts
    /// once. Returns how many ways changed. Nothing before ``load()``.
    @discardableResult
    public func unrecord(_ cells: some Sequence<HexCell>, kind: WornWayKind) -> Int {
        guard isLoaded else { return 0 }
        var changed = 0
        // Bounded: at most FogCellStore.maxCells distinct cells.
        for cell in Set(cells.prefix(FogCellStore.maxCells)) {
            let key = WornWayKey(cell: cell, kind: kind)
            guard let tally = tallies[key] else { continue }
            tallies[key] = tally.count > 1 ? WornTally(count: tally.count - 1, lastDay: tally.lastDay) : nil
            changed += 1
        }
        if changed > 0 { hasUnsavedChanges = true }
        return changed
    }

    /// Moves one trip on `day` through each of `cells` from `kind` to `newKind` (a kept trip's kind changed).
    public func move(_ cells: some Sequence<HexCell>, from kind: WornWayKind, to newKind: WornWayKind, on day: UInt16) {
        guard kind != newKind else { return }
        let distinct = Set(cells.prefix(FogCellStore.maxCells))
        unrecord(distinct, kind: kind)
        record(distinct, kind: newKind, on: day)
    }

    /// Removes the way `key` whatever its count ("Forget this path" on a cell); whether it was there.
    @discardableResult
    public func remove(_ key: WornWayKey) -> Bool {
        guard isLoaded, tallies.removeValue(forKey: key) != nil else { return false }
        hasUnsavedChanges = true
        return true
    }

    /// Writes the counter (a no-op when nothing changed).
    public func save() throws {
        guard isLoaded, hasUnsavedChanges else { return }
        try vault.write(WornWayCodec.encode(tallies), to: .wornWays)
        hasUnsavedChanges = false
    }

    /// Adds a trip's `cells` of `kind` on `day` to the locked-phone buffer (works after the first unlock since boot,
    /// even locked). A (cell, kind, day) already waiting is kept once, so one trip still counts once.
    public func appendPending(_ cells: [HexCell], kind: WornWayKind, on day: UInt16) throws {
        guard !cells.isEmpty else { return }
        var pending = try readPending()
        var waiting = Set(pending.map { PendingRecord(key: $0.0, day: $0.1) })
        // Bounded: at most FogCellStore.maxPendingCells cells looked at.
        for cell in cells.prefix(FogCellStore.maxPendingCells) {
            let record = PendingRecord(key: WornWayKey(cell: cell, kind: kind), day: day)
            guard !waiting.contains(record) else { continue }
            guard pending.count < FogCellStore.maxPendingCells else {
                refusedCount += 1
                continue
            }
            waiting.insert(record)
            pending.append((record.key, day))
        }
        try vault.write(WornWayCodec.encodePending(pending), to: .pendingWornWays)
    }

    /// The ways passed while the phone was locked, each with its day, oldest day first. The buffer stays until
    /// ``clearPending()``, which the caller calls only once the counts are saved, so a failed save loses nothing.
    public func pending() throws -> [(WornWayKey, UInt16)] {
        try readPending().sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
    }

    /// Empties the locked-phone buffer (after its ways are counted and saved); whether it is gone.
    @discardableResult
    public func clearPending() -> Bool {
        vault.remove(.pendingWornWays)
    }

    /// Forgets the tallies in memory (the vault's ``WorldMapVault/clearAll()`` removes the files).
    public func forget() {
        tallies = [:]
        hasUnsavedChanges = false
    }

    /// The buffer's records (empty when there is none, or it can't be opened).
    private func readPending() throws -> [(WornWayKey, UInt16)] {
        do {
            guard let data = try vault.read(.pendingWornWays) else { return [] }
            return WornWayCodec.decodePending(data, limit: FogCellStore.maxPendingCells) ?? []
        } catch let error as WorldMapVault.VaultError where error.isTryAgainLater {
            throw error
        } catch {
            vault.remove(.pendingWornWays)
            return []
        }
    }

    /// One buffered pass, for de-duplicating.
    private struct PendingRecord: Hashable {
        let key: WornWayKey
        let day: UInt16
    }
}
