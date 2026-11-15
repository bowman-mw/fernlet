import Foundation

/// How one stamp sits on a stamp page, as if pressed by hand (owner 2026-11-15: "a little rotation and +- some
/// movement in the x and y directions"): a turn of −8…+8° and a shift of −4…+4 pt across and −3…+3 pt down.
///
/// Seeded from the stamp's identity on the page (its kind, token and trip, ``PassportStampKey``), never from
/// `random()`, so a stamp sits the same on every launch, redraw and device, and each trip of a country lands at its
/// own angle, as a fresh press would. The hash is 64-bit FNV-1a over the identity's UTF-8, finished with the
/// SplitMix64 mixer so near-identical tokens ("us", "uz") still land far apart. Nothing here animates.
nonisolated struct PassportStampHand: Equatable, Sendable {
    /// The largest turn either way, in degrees.
    static let maxDegrees = 8.0
    /// The largest shift across either way, in points.
    static let maxAcross = 4.0
    /// The largest shift down either way, in points.
    static let maxDown = 3.0
    /// The most UTF-8 bytes of the identity hashed (a token is short).
    static let maxBytes = 128

    /// The turn, −8…+8°.
    let degrees: Double
    /// The shift across, −4…+4 pt.
    let across: Double
    /// The shift down, −3…+3 pt.
    let down: Double

    /// The hand placement of the stamp `key` names.
    init(_ key: PassportStampKey) {
        let hash = Self.hash("\(key.kind.rawValue)|\(key.token.uppercased())|\(key.trip)")
        degrees = Self.unit(hash) * Self.maxDegrees
        across = Self.unit(hash >> 21) * Self.maxAcross
        down = Self.unit(hash >> 42) * Self.maxDown
        assert(abs(degrees) <= Self.maxDegrees && abs(across) <= Self.maxAcross && abs(down) <= Self.maxDown)
    }

    /// The hand placement of `entry`.
    init(_ entry: PassportStampEntry) {
        self.init(PassportStampKey(entry))
    }

    /// FNV-1a (64-bit) over `text`'s first ``maxBytes`` UTF-8 bytes, then the SplitMix64 finaliser.
    static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8.prefix(maxBytes) {
            value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// The low 21 bits of `bits` as a value in −1…+1.
    private static func unit(_ bits: UInt64) -> Double {
        let mask: UInt64 = (1 << 21) - 1
        let value = Double(bits & mask) / Double(mask) * 2 - 1
        assert((-1 ... 1).contains(value))
        return value
    }
}
