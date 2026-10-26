import FernletCrypto
import Foundation

/// Where the person's workout spaces are, for the World map's blue button (World app plan step 6a):
/// one point per space, keyed by the space's `WorkoutLocation.id`, sealed in the map's vault and never
/// in the synced settings. A space's name and setup stay in Fernlet's settings as they always have; only
/// its place on the map lives here, on this iPhone.
///
/// One small sealed file (`AEAD.worldMapPinsV1`, the vault's when-unlocked key): a count, then each pin
/// as its id and two coordinates, read afresh on every use (it is a few kilobytes at most), so nothing
/// held in memory can outlive a wipe of the vault. Bounded: at most ``maxPins`` pins; matching looks at
/// each pin once.
@MainActor
public final class SpacePinStore {
    /// The most pins kept.
    public static let maxPins = 200
    /// How near a reading must be to a pin to count as being at that space, in metres.
    public static let matchRadius = 100.0
    /// The pins file.
    static let file = WorldMapVault.File(name: "pins.bin", purpose: FernletCryptoPurpose.AEAD.worldMapPinsV1, role: .store)

    private let vault: WorldMapVault

    /// A store over `vault`; nothing is read until a pin is asked for.
    public init(vault: WorldMapVault) {
        self.vault = vault
    }

    /// The pin of space `id`, or nil when it has none.
    public func pin(for id: UUID) throws -> GeoPoint? {
        try loaded()[id]
    }

    /// Every pin (the map's markers and Settings' list).
    public func all() throws -> [UUID: GeoPoint] {
        try loaded()
    }

    /// Pins space `id` at `point` (replacing any pin it had). Whether it was kept.
    @discardableResult
    public func setPin(_ point: GeoPoint, for id: UUID) throws -> Bool {
        var current = try loaded()
        guard point.isValid, current[id] != nil || current.count < Self.maxPins else { return false }
        current[id] = point
        try save(current)
        return true
    }

    /// Removes the pin of space `id` (deleting a space deletes its pin). Whether it is gone.
    @discardableResult
    public func remove(for id: UUID) throws -> Bool {
        var current = try loaded()
        guard current.removeValue(forKey: id) != nil else { return true }
        try save(current)
        return true
    }

    /// The space whose pin is nearest `point` within ``matchRadius``, or nil when none is that near.
    public func space(at point: GeoPoint) throws -> UUID? {
        let near = try loaded().map { (id: $0.key, metres: $0.value.distance(to: point)) }
            .filter { $0.metres <= Self.matchRadius }
        return near.min { $0.metres < $1.metres }?.id
    }

    /// Removes every pin ("Forget workout-space locations"). Whether the file is gone.
    @discardableResult
    public func removeAll() -> Bool {
        vault.remove(Self.file)
    }

    /// The pins on disk now (a file that is not this format reads as none).
    private func loaded() throws -> [UUID: GeoPoint] {
        try vault.read(Self.file).flatMap(Self.decode) ?? [:]
    }

    /// Seals `current` as the pins file.
    private func save(_ current: [UUID: GeoPoint]) throws {
        try vault.write(Self.encode(current), to: Self.file)
    }

    /// The file's bytes: a 16-bit count, then each pin's id and its latitude and longitude as doubles.
    public static func encode(_ pins: [UUID: GeoPoint]) -> Data {
        var data = Data()
        let kept = pins.prefix(maxPins)
        var count = UInt16(kept.count).bigEndian
        data.append(Data(bytes: &count, count: 2))
        for (id, point) in kept {
            let uuid = id.uuid
            data.append(contentsOf: [uuid.0, uuid.1, uuid.2, uuid.3, uuid.4, uuid.5, uuid.6, uuid.7,
                                     uuid.8, uuid.9, uuid.10, uuid.11, uuid.12, uuid.13, uuid.14, uuid.15])
            for value in [point.latitude, point.longitude] {
                var bits = value.bitPattern.bigEndian
                data.append(Data(bytes: &bits, count: 8))
            }
        }
        return data
    }

    /// The pins in `data`, or nil when the bytes are not this format.
    public static func decode(_ data: Data) -> [UUID: GeoPoint]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        let count = Int(bytes[0]) << 8 | Int(bytes[1])
        guard count <= maxPins, bytes.count == 2 + count * 32 else { return nil }
        var pins: [UUID: GeoPoint] = [:]
        for index in 0..<count {
            let base = 2 + index * 32
            let id = UUID(uuid: (bytes[base], bytes[base + 1], bytes[base + 2], bytes[base + 3], bytes[base + 4],
                                 bytes[base + 5], bytes[base + 6], bytes[base + 7], bytes[base + 8], bytes[base + 9],
                                 bytes[base + 10], bytes[base + 11], bytes[base + 12], bytes[base + 13], bytes[base + 14],
                                 bytes[base + 15]))
            let point = GeoPoint(double(bytes, at: base + 16), double(bytes, at: base + 24))
            guard point.isValid else { return nil }
            pins[id] = point
        }
        return pins
    }

    /// The big-endian double at `offset`.
    private static func double(_ bytes: [UInt8], at offset: Int) -> Double {
        var bits: UInt64 = 0
        for byte in bytes[offset..<(offset + 8)] { bits = bits << 8 | UInt64(byte) }
        return Double(bitPattern: bits)
    }
}
