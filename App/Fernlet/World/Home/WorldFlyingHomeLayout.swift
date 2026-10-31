import CoreGraphics
import Foundation

/// The geometry of Home in the air (World-Airports-Spec §6.2, screen 8, approved at draft 6; the mockup's `flying()`):
/// a close-up of a 737's tube seen from outside, filling the scene's width, a row of its rounded-rectangle windows
/// one every ``pitch``, Sprout's face pressed to the one at ``sproutX``, and two small clouds drifting past.
///
/// Two sizes: the standard one and the largest text's (`large`), where the tube, its windows and Sprout shrink so the
/// grown bubble keeps its room. Every length is in points, measured from the tube's top-left corner unless a member
/// says the glass's.
nonisolated struct WorldFlyingLayout: Equatable, Sendable {
    /// The tube's height: 236 pt, 196 at the largest text.
    let tubeHeight: CGFloat
    /// Points per sprite pixel for Sprout: its regular size, 7 (6 at the largest text), as the location-off Home.
    let pixelScale: CGFloat
    /// One window's glass: 140 × 172 pt (128 × 150 at the largest text).
    let glassSize: CGSize
    /// The glass's top edge below the tube's top.
    let glassTop: CGFloat
    /// The breath mist's half-width and half-height.
    let mistRadii: CGSize
    /// How far above the tube's top the upper cloud flies.
    let upperCloudLift: CGFloat
    /// How far below the tube's bottom the lower cloud flies.
    let lowerCloudDrop: CGFloat
    /// The open scene's height on the location-off Home while flying (330 pt, 300 at the largest text).
    let sceneHeight: CGFloat

    /// One window every 236 pt.
    static let pitch: CGFloat = 236
    /// The centre of Sprout's window, from the scene's leading edge.
    static let sproutX: CGFloat = 150
    /// The ink edges along the tube's top and bottom.
    static let edge: CGFloat = 3
    /// How far the grey frame stands out round the glass.
    static let frameInset: CGFloat = 9
    /// The frame's corner radius.
    static let frameCorner: CGFloat = 30
    /// The glass's corner radius.
    static let glassCorner: CGFloat = 22
    /// The most windows (and seams) drawn across any phone's width.
    static let maxWindows = 6
    /// The companion sprite's body footprint in sprite pixels (``WorldCompanionGrid``'s 20 × 22, plus its top row).
    static let spriteColumns: CGFloat = 20

    /// The layout at the standard sizes, or at the largest text's.
    init(large: Bool) {
        tubeHeight = large ? 196 : 236
        pixelScale = large ? 6 : 7
        glassSize = large ? CGSize(width: 128, height: 150) : CGSize(width: 140, height: 172)
        glassTop = large ? 20 : 26
        mistRadii = large ? CGSize(width: 16, height: 7) : CGSize(width: 19, height: 8)
        upperCloudLift = large ? 40 : 52
        lowerCloudDrop = large ? 4 : 10
        sceneHeight = large ? 300 : 330
    }

    /// The centres of the windows any part of whose frame shows across `width`, Sprout's among them, left to right.
    func windowCentres(width: CGFloat) -> [CGFloat] {
        let half = glassSize.width / 2 + Self.frameInset
        var centres: [CGFloat] = []
        // Bounded: at most `maxWindows` steps, from two windows before Sprout's.
        for step in 0..<Self.maxWindows {
            let centre = Self.sproutX + CGFloat(step - 2) * Self.pitch
            if centre + half > 0, centre - half < width { centres.append(centre) }
        }
        return centres
    }

    /// The faint panel seams across `width`: halfway between each pair of windows.
    func seams(width: CGFloat) -> [CGFloat] {
        var seams: [CGFloat] = []
        // Bounded: at most `maxWindows` seams, from two before Sprout's window.
        for step in 0..<Self.maxWindows {
            let x = Self.sproutX + (CGFloat(step - 2) + 0.5) * Self.pitch
            if x >= 0, x < width { seams.append(x) }
        }
        return seams
    }

    /// The glass of the window centred at `centre`.
    func glass(centre: CGFloat) -> CGRect {
        CGRect(x: centre - glassSize.width / 2, y: glassTop, width: glassSize.width, height: glassSize.height)
    }

    /// The grey frame round the window centred at `centre`.
    func frame(centre: CGFloat) -> CGRect {
        glass(centre: centre).insetBy(dx: -Self.frameInset, dy: -Self.frameInset)
    }

    /// The red cheat line under the windows, across `width`.
    func cheatLine(width: CGFloat) -> CGRect {
        CGRect(x: 0, y: glassTop + glassSize.height + 12, width: width, height: 10)
    }

    /// The yellow pinstripe under the cheat line, across `width`.
    func pinstripe(width: CGFloat) -> CGRect {
        CGRect(x: 0, y: glassTop + glassSize.height + 22, width: width, height: 4)
    }

    /// The faint diagonal shine across the glass centred at `centre`: a slim parallelogram from the top right
    /// corner down to the bottom left, clipped to the glass where it's drawn.
    func shine(centre: CGFloat) -> [CGPoint] {
        let top = glassTop + 6, right = centre + glassSize.width / 2 - 12
        let drop = CGSize(width: glassSize.width - 10, height: glassSize.height - 12)
        return [CGPoint(x: right - 22, y: top), CGPoint(x: right, y: top),
                CGPoint(x: right - drop.width, y: top + drop.height), CGPoint(x: right - drop.width - 22, y: top + drop.height)]
    }

    /// Where Sprout's sprite stands in its window's glass (the glass's own coordinates): the body centred, the
    /// face at the glass's middle, the rest clipped by the glass's bottom edge.
    var spriteOrigin: CGPoint {
        CGPoint(x: ((glassSize.width - Self.spriteColumns * pixelScale) / 2).rounded(),
                y: (glassSize.height * 0.5 - 12 * pixelScale).rounded())
    }

    /// The breath mist's centre in Sprout's window's glass, at mouth height.
    var mistCentre: CGPoint {
        CGPoint(x: glassSize.width / 2 + 4, y: glassSize.height * 0.66)
    }
}

/// The two small pixel clouds drifting past the plane (World-Airports-Spec §6.2): one above the tube, one below it,
/// sliding slowly leftward and coming round again from the right. Reduce Motion holds them at their places.
nonisolated enum WorldFlyingClouds {
    /// The cloud's rows (the mockup's `CLOUD`): `w` its white, `c` its shaded underside.
    static let rows = [".....wwww.......", "...wwwwwwww.ww..", ".wwwwwwwwwwwwwww", "wwwwwwwwwwwwwwww", ".cccccccccccccc."]
    /// Points per cloud pixel.
    static let scale: CGFloat = 3
    /// How fast they drift, in points per second: slowly.
    static let speed: CGFloat = 6
    /// The upper cloud's place from the scene's leading edge before it drifts.
    static let upperX: CGFloat = 250
    /// The lower cloud's place.
    static let lowerX: CGFloat = 18

    /// One cloud's size in points (48 × 15).
    static var size: CGSize {
        CGSize(width: CGFloat(rows.first?.count ?? 0) * scale, height: CGFloat(rows.count) * scale)
    }

    /// A cloud's leading edge `elapsed` seconds after it stood at `start`, across a scene `width` wide: drifting left
    /// at ``speed``, a whole cloud pixel at a time so it stays crisp, wrapping round to the trailing edge once it has
    /// left the leading one.
    static func x(start: CGFloat, elapsed: TimeInterval, width: CGFloat) -> CGFloat {
        let cloud = size.width, span = Double(max(width + cloud, 1))
        let drift = (Double(speed) * max(elapsed, 0) / Double(scale)).rounded(.down) * Double(scale)
        var lap = (Double(start + cloud) - drift).truncatingRemainder(dividingBy: span)
        if lap < 0 { lap += span }
        return CGFloat(lap) - cloud
    }
}
