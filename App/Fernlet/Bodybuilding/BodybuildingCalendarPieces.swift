//
//  BodybuildingCalendarPieces.swift
//  Fernlet
//
//  The Day calendar's small drawn pieces (World round 7, piece C; approved drawings `bb-month`, `bb-week`,
//  `bb-signals`, `bb-day`): its pixel icons, the free-meal F, the soft deload stripes, the sleep and
//  macro bars and the bathroom dots. Pixel art for icons only; marks are plain shapes in the World ink.
//

import FernletDomainModel
import FernletUI
import SwiftUI

/// The calendar's own pixel icons (the approved page's `ROLL`, and the grid on the Move link card).
nonisolated enum BodybuildingCalendarSprites {
    /// The bathroom count's roll (`bb-signals`, `bb-week`, `bb-day`).
    static let roll = WorldSprite(rows: [".kkkkkk..", "kwwwwwwk.", "kw.kk.wk.", "kw.kk.wkk", "kwwwwwwkw", "kwwwwwwkw",
                                         "kwwwwwwkw", "kwwwwwwk.", ".kkkkkk.."],
                                  palette: ["k": 0x4A2E1C, "w": 0xFFF6E2])
    /// A month grid, for the Move root's Day calendar card (one-colour ink, so it follows dark mode).
    static let grid = WorldSprite(rows: ["kkkkkkkkk", "kkkkkkkkk", "k.......k", "k.k.k.k.k", "k.......k", "k.k.k.k.k",
                                         "k.......k", "kkkkkkkkk"],
                                  palette: ["k": WorldSprite.ink])
}

/// The calendar's colours beyond the look's tokens: the sleep bar's blue, the steps bar's moss and the
/// free-meal F's gold, each a non-text mark at 3:1 or better on the cell's paper in both modes.
enum BodybuildingPalette {
    /// The sleep bar (`.bbsl`).
    static let sleep = WorldPalette.adaptive(light: 0x6F7FB5, dark: 0x9AAAE0, lightHC: 0x4A5A94, darkHC: 0xB8C4F0)
    /// The steps bar.
    static let steps = WorldPalette.moss
    /// The free-meal F's fill (`.bbfree`); its letter stays dark ink in both modes.
    static let freeMealFill = WorldPalette.rgb(0xF2C75C)
    /// The F's letter and frame on its gold fill.
    static let freeMealInk = WorldPalette.rgb(0x3A2414)
}

/// The small F for a free meal (`.bbfree`): a gold square in an ink frame with the letter in dark ink.
/// Decorative: the cell or row it sits in says "free meal".
struct BodybuildingFreeMealMark: View {
    @ScaledMetric(relativeTo: .caption2) private var side: CGFloat = 13

    var body: some View {
        Text(verbatim: String(localized: "bodybuilding.freeMeal.mark", defaultValue: "F",
                    comment: "Day calendar: the one-letter mark for a free meal, drawn in a small square on a day. The first letter of the translation of 'Free meal'."))
            .font(.custom(FernletFontName.dmSansBold, size: 9, relativeTo: .caption2))
            .foregroundStyle(BodybuildingPalette.freeMealInk)
            .frame(minWidth: side, minHeight: side)
            .background(BodybuildingPalette.freeMealFill, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(BodybuildingPalette.freeMealInk, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// Soft diagonal stripes (`.dl`): a deload week, or fainter, the suggested week. Stronger under
/// Increase Contrast so the planned week still reads.
struct BodybuildingStripes: View {
    /// Faint: the suggested week before it is chosen.
    var isFaint = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        let ink = look?.text ?? Color.bark
        let strength = (isFaint ? 0.08 : 0.14) * (contrast == .increased ? 2 : 1)
        Canvas { context, size in
            var path = Path()
            let step: CGFloat = 7
            let lines = Int((size.width + size.height) / step) + 1
            for index in 0..<min(lines, 200) {
                let x = CGFloat(index) * step
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x - size.height, y: size.height))
            }
            context.stroke(path, with: .color(ink.opacity(strength)), lineWidth: 3)
        }
        .accessibilityHidden(true)
    }
}

/// A thin bar filled to `fraction` (the sleep bar, full at 8 h; the steps bar; one macro).
struct BodybuildingBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 3
    /// Draws the empty part as a framed track (the week list's macro bars).
    var showsTrack = false
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        ZStack(alignment: .leading) {
            if showsTrack {
                Capsule().fill(WorldPalette.barEmpty)
            }
            Capsule().fill(color)
                .scaleEffect(x: clamped, y: 1, anchor: .leading)
        }
        .frame(height: height)
        .overlay { if showsTrack { Capsule().strokeBorder(look?.ink ?? Color.bark, lineWidth: 1) } }
        .accessibilityHidden(true)
    }
}

/// Bathroom visits as dots (`.bbdot`): one small square a visit, up to five, then a plus.
struct BodybuildingDots: View {
    let count: Int
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<min(max(count, 0), 5), id: \.self) { _ in
                Rectangle().fill(look?.dim ?? Color.slate).frame(width: 3, height: 3)
            }
            if count > 5 {
                Text(verbatim: "+")
                    .font(.custom(FernletFontName.dmSansBold, size: 8, relativeTo: .caption2))
                    .foregroundStyle(look?.dim ?? Color.slate)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A signal's icon (`bb-signals`, `bb-day`): its pixel sprite, or the F for free meals.
struct BodybuildingSignalIcon: View {
    let signal: BodybuildingSignal
    var scale: CGFloat = 2
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        Group {
            switch signal {
            case .training: WorldSpriteView(sprite: WorldSprites.dumbbell, scale: scale, tint: look?.text ?? Color.bark)
            case .sleep: WorldSpriteView(sprite: WorldSprites.moon, scale: scale)
            case .bathroom: WorldSpriteView(sprite: BodybuildingCalendarSprites.roll, scale: scale)
            case .freeMeals: BodybuildingFreeMealMark()
            case .weight: WorldSpriteView(sprite: WorldSprites.target, scale: scale)
            case .steps: WorldSpriteView(sprite: WorldSprites.shoe, scale: scale)
            case .macros: WorldSpriteView(sprite: WorldSprites.onigiri, scale: scale)
            case .dayFelt: WorldSpriteView(sprite: WorldSprites.heartSm, scale: scale)
            }
        }
        .accessibilityHidden(true)
    }
}
