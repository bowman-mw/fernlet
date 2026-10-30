import CoreGraphics

/// Every colour the nature fog paints, by role: the mockup's `pal()` keys in its order.
nonisolated enum NaturePaint: Int, CaseIterable {
    case grassA, grassB, grassC, edge, woods, long, seam, speck
    case bladeDark, bladeMid, bladeLight, bladeTip
    case petalPink, petalYellow, petalWhite, petalLilac, centre, centreOnYellow
    case outline, leafDark, leafMid, leafLight, leafHighlight, trunkLight, trunkDark, shadow
    case pineOutline, pineDark, pineMid, pineLight
    case water, ripple, shore, lily, cattail
    case rockDark, rock, rockLight, rockHighlight

    /// The three grass greens a plain hex picks from.
    static let grasses: [NaturePaint] = [.grassA, .grassB, .grassC]
    /// The four petal colours, as the mockup's `fp`.
    static let petals: [NaturePaint] = [.petalPink, .petalYellow, .petalWhite, .petalLilac]

    /// How far Dark Mode mixes this colour toward the night ground: grass greens 42 %, seam and edge 50 %,
    /// petals and `fc` centres 22 %, everything else (the centre on yellow included, as the file has it) 34 %.
    var darkShare: Double {
        switch self {
        case .grassA, .grassB, .grassC: 0.42
        case .seam, .edge: 0.5
        case .petalPink, .petalYellow, .petalWhite, .petalLilac, .centre: 0.22
        default: 0.34
        }
    }
}

/// The nature fog's colours for one appearance (spec "Colours"): the light palette, Dark Mode's mix toward
/// `#141C12`, and Increase Contrast's darker seams (1.8 pt) and tree outlines.
///
/// A terrain ``TerrainLook`` lays its set's and season's light colours over the approved ones first
/// (``TerrainPalettes``), then Dark Mode mixes with the same shares and Increase Contrast darkens the same roles,
/// as the mockup's `palFor` does; the approved look (the meadow and forest in summer) is today's palette exactly.
nonisolated struct NatureFogPalette: Equatable, Hashable {
    /// Dark Mode.
    let dark: Bool
    /// Increase Contrast.
    let highContrast: Bool
    /// The terrain set and season painted.
    let look: TerrainLook
    private let values: [UInt32]

    /// The palette for an appearance, in `look`'s colours (by default the approved nature fog's).
    init(dark: Bool, highContrast: Bool, look: TerrainLook = .approved) {
        self.dark = dark
        self.highContrast = highContrast
        self.look = look
        let overrides = look == .approved ? [:] : TerrainPalettes.overrides(look)
        var values = NaturePaint.allCases.map { paint in
            let light = overrides[paint] ?? Self.light[paint.rawValue]
            return dark ? Self.mix(light, toward: Self.night, by: paint.darkShare) : light
        }
        if highContrast {
            values[NaturePaint.seam.rawValue] = dark ? 0xD7E8C4 : 0x2F4A24
            values[NaturePaint.outline.rawValue] = dark ? 0x060B06 : 0x14281A
            values[NaturePaint.pineOutline.rawValue] = dark ? 0x060B06 : 0x14281A
        }
        self.values = values
    }

    /// The colour of `paint` as 0xRRGGBB.
    func rgb(_ paint: NaturePaint) -> UInt32 {
        values[paint.rawValue]
    }

    /// The colour of `paint`, opaque sRGB.
    func color(_ paint: NaturePaint) -> CGColor {
        Self.color(rgb: rgb(paint))
    }

    /// The colour of `ink` as 0xRRGGBB: a role from this palette, or a fixed colour (mixed 30 % toward the night
    /// ground in Dark Mode), or the light or dark one of a pair.
    func rgb(_ ink: NatureInk) -> UInt32 {
        switch ink {
        case .paint(let paint): rgb(paint)
        case .fixed(let value): dark ? Self.mix(value, toward: Self.night, by: NatureInk.fixedDarkShare) : value
        case .pair(let light, let night): dark ? night : light
        }
    }

    /// The colour of `ink`, opaque sRGB.
    func color(_ ink: NatureInk) -> CGColor {
        Self.color(rgb: rgb(ink))
    }

    /// The same appearance in `look`'s colours.
    func with(_ look: TerrainLook) -> NatureFogPalette {
        look == self.look ? self : NatureFogPalette(dark: dark, highContrast: highContrast, look: look)
    }

    /// `value` (0xRRGGBB) as an opaque sRGB colour.
    static func color(rgb value: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// The seam between hexes: 1 pt, 1.8 pt with Increase Contrast.
    var seamWidth: CGFloat { highContrast ? 1.8 : 1 }

    /// The night ground every Dark Mode colour mixes toward.
    static let night: UInt32 = 0x141C12

    /// The light palette, in ``NaturePaint`` order (the mockup's hex values).
    static let light: [UInt32] = [
        0x9DC27A, 0x94BB71, 0xA5C883, 0xB9D69B, 0x89B06A, 0x86B064, 0x7FA762, 0x88B06B,
        0x4E7E3B, 0x62984A, 0x8BC066, 0xAAD584,
        0xE58FA6, 0xEBC24F, 0xFFF6E0, 0xB59AE0, 0xF2B33D, 0xC9771F,
        0x2E5230, 0x3D6B39, 0x548E45, 0x73AE58, 0x97CC72, 0x9A6438, 0x74482A, 0x6F9B57,
        0x21402A, 0x2B5534, 0x3A6B40, 0x4F8550,
        0x6FA8D0, 0xA9D3EC, 0x4F84AE, 0x5E9A48, 0x7A4B2A,
        0x5E5850, 0x9A948C, 0xC3BDB4, 0xDAD5CC,
    ]

    /// The mockup's `mix(a, b, f)`: each channel moved `share` of the way to `target`, rounded as JavaScript does.
    static func mix(_ color: UInt32, toward target: UInt32, by share: Double) -> UInt32 {
        var mixed: UInt32 = 0
        for shift in [16, 8, 0] {
            let from = Double((color >> UInt32(shift)) & 0xFF), to = Double((target >> UInt32(shift)) & 0xFF)
            let channel = UInt32(max(0, min(255, NatureFogNoise.jsRound(from + (to - from) * share))))
            mixed |= channel << UInt32(shift)
        }
        return mixed
    }
}
