//
//  ExerciseAnimationPalette.swift
//  Fernlet
//
//  The approved renderer's colours (`COLORS`, the female overrides, `tint` and `pixelColor`), ported
//  so a colour string resolves to the same packed pixel the JavaScript canvas writes.
//

import Foundation

/// A resolved colour: the packed canvas pixel (`0xAABBGGRR`, which is R, G, B, A in memory) and, when
/// the string was a `#rrggbb` hex, its three channels so `tint` can scale them.
nonisolated struct ExerciseAnimationInk: Equatable, Sendable {
    /// The packed pixel `pixelColor` returns for this colour string.
    let pixel: UInt32
    /// Red, green and blue (0...255) when the string matched `/^#[0-9a-f]{6}$/i`; nil otherwise,
    /// and then `tint` leaves the colour as it is.
    let channels: (Double, Double, Double)?

    /// Two inks are equal when they write the same pixel and tint alike.
    static func == (lhs: ExerciseAnimationInk, rhs: ExerciseAnimationInk) -> Bool {
        guard lhs.pixel == rhs.pixel else { return false }
        switch (lhs.channels, rhs.channels) {
        case (nil, nil): return true
        case let (l?, r?): return l == r
        default: return false
        }
    }

    /// The ink for a colour string, as `pixelColor(hex)` (and `tint`'s hex test) would read it.
    init(colorString: String) {
        pixel = ExerciseAnimationPalette.pixelColor(colorString)
        channels = ExerciseAnimationPalette.hexChannels(colorString)
    }

    /// The ink for three in-range channels (what `tint` produces).
    init(red: Double, green: Double, blue: Double) {
        channels = (red, green, blue)
        let packed = UInt32(blue) << 16 | UInt32(green) << 8 | UInt32(red)
        pixel = 0xFF00_0000 | packed
    }

    /// `tint(hex, factor)`: each channel becomes `Math.round(Math.min(255, channel × factor))`; a
    /// colour that is not a `#rrggbb` hex comes back unchanged.
    func tinted(_ factor: Double) -> ExerciseAnimationInk {
        guard let (red, green, blue) = channels else { return self }
        let scaled = { (channel: Double) in ExerciseAnimationMath.jsRound(ExerciseAnimationMath.jsMin(255, channel * factor)) }
        return ExerciseAnimationInk(red: scaled(red), green: scaled(green), blue: scaled(blue))
    }
}

/// The approved palette, per character, and the colour-string parsing the renderer relies on.
nonisolated enum ExerciseAnimationPalette {
    /// The renderer's `COLORS`, verbatim.
    static let colors: [String: String] = [
        "paper": "#F7EEDC", "floor": "#E8DDC6", "ink": "#392F26", "shirt": "#71815B", "shirtSide": "#596947",
        "skin": "#C98E68", "skinSide": "#AE7659", "pants": "#54616A", "hair": "#47372D", "shoe": "#F1E8D4",
        "metal": "#8A9388", "machine": "#657366", "pad": "#596947", "grip": "#4A4C43", "mat": "#B7B591",
        "wood": "#B58960", "wall": "#C9C8B1", "cable": "#545E53", "band": "#BB654E", "rope": "#956D48",
        "assistance": "#8D9E74", "console": "#53686C", "ball": "#99A36E",
    ]

    /// The female character's overrides of `COLORS`.
    static let femaleOverrides: [String: String] = [
        "shirt": "#B16F59", "shirtSide": "#915646", "pants": "#4D505D", "hair": "#6A4435",
    ]

    /// `{...COLORS, ...(female ? overrides : {})}`.
    static func palette(for character: ExerciseAnimationCharacter) -> [String: String] {
        guard character == .female else { return colors }
        return colors.merging(femaleOverrides) { _, override in override }
    }

    /// The red, green and blue of a string that matches `/^#[0-9a-f]{6}$/i`, else nil.
    static func hexChannels(_ string: String) -> (Double, Double, Double)? {
        let scalars = Array(string.unicodeScalars)
        guard scalars.count == 7, scalars[0] == "#" else { return nil }
        let digits = scalars.dropFirst().compactMap { hexDigit($0) }
        guard digits.count == 6 else { return nil }
        let channel = { (index: Int) in Double(digits[index] * 16 + digits[index + 1]) }
        return (channel(0), channel(2), channel(4))
    }

    /// `pixelColor(hex)`: `parseInt(hex.slice(1), 16)` (a NaN parse packs as 0) folded into
    /// `0xff000000 | (n&255)<<16 | (n&0xff00) | (n>>>16)&255`. Exact for up to 13 hex digits, the
    /// most a JavaScript number holds exactly; the approved data's longest is six.
    static func pixelColor(_ string: String) -> UInt32 {
        let bits = parseIntHexBits(String(string.unicodeScalars.dropFirst()))
        return 0xFF00_0000 | (bits & 255) << 16 | (bits & 0xFF00) | (bits >> 16) & 255
    }

    /// `ToInt32(parseInt(string, 16))` as raw bits: skips leading white space, takes a sign and an
    /// optional `0x`, then the longest run of hex digits; no digits is NaN, which is 0.
    static func parseIntHexBits(_ string: String) -> UInt32 {
        var scalars = Substring(string).unicodeScalars.drop { isJavaScriptWhiteSpace($0) }
        var negative = false
        if let sign = scalars.first, sign == "-" || sign == "+" {
            negative = sign == "-"
            scalars = scalars.dropFirst()
        }
        let prefix = Array(scalars.prefix(2))
        if prefix.count == 2, prefix[0] == "0", prefix[1] == "x" || prefix[1] == "X" {
            scalars = scalars.dropFirst(2)
        }
        var value: UInt32 = 0
        for scalar in scalars {
            guard let digit = hexDigit(scalar) else { break }
            value = value &* 16 &+ UInt32(digit)
        }
        return negative ? 0 &- value : value
    }

    /// One hex digit's value, or nil.
    static func hexDigit(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar {
        case "0"..."9": return Int(scalar.value) - 48
        case "a"..."f": return Int(scalar.value) - 87
        case "A"..."F": return Int(scalar.value) - 55
        default: return nil
        }
    }

    /// JavaScript's `StrWhiteSpaceChar`: the white space and line terminators `parseInt` skips.
    static func isJavaScriptWhiteSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0xFEFF, 0x2028, 0x2029: return true
        default: return scalar.properties.generalCategory == .spaceSeparator
        }
    }
}
