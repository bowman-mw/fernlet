// WidgetSceneCard.swift
// FernletWidgets
//
// The person's background scene (G8, Customize › Background) as the whole card behind Sprout (owner's
// pick A, 2026-11-18): the scene fills the companion cards and "Your drive", Sprout stands on its ground,
// and every line of text sits on a framed paper plate so it keeps the paper's contrast on any scene. The
// map widget keeps its map and takes the scene's ground as a strip along its bottom edge. The water and
// stamp cards, which have no Sprout, keep their plain paper. Colour only: in one colour (the Lock Screen,
// the tinted and clear Home Screens) iOS drops the background and the cards draw as before.

import SwiftUI
import WidgetKit

/// Where things stand on a scene that fills a card: the scene is cover-cropped and anchored at the
/// bottom centre (the twin of the app's `WorldCompanionSceneBackdrop`), so its ground always runs along
/// the card's bottom edge.
enum WidgetSceneLayout {
    /// Points per scene cell for a scene covering `size`.
    static func cell(in size: CGSize) -> CGFloat {
        max(size.width / CGFloat(WidgetCompanionScene.width), size.height / CGFloat(WidgetCompanionScene.height))
    }

    /// The ground's top edge, in points from the card's top.
    static func groundY(in size: CGSize) -> CGFloat {
        size.height - CGFloat(WidgetCompanionScene.height - WidgetCompanionScene.ground) * cell(in: size)
    }

    /// How far below the ground's top edge Sprout's sprite frame ends: its feet (the frame's row 23)
    /// stand one sprite pixel into the ground, the frame's last row below them.
    static func frameBottomBelowGround(scale: CGFloat) -> CGFloat {
        2 * scale
    }

    /// The y of Sprout's sprite centre so its feet stand on the ground of a card of `size`.
    static func spriteCentreY(in size: CGSize, scale: CGFloat) -> CGFloat {
        let height = WidgetCompanionSprite.size(scale: scale).height
        return groundY(in: size) + frameBottomBelowGround(scale: scale) - height / 2
    }
}

/// The scene filling its frame with hard-edged cells, cover-cropped and anchored at the bottom centre;
/// with `cellWidth` set, cells of that size anchored at the bottom (the map's strip). Decorative.
struct WidgetSceneBackdrop: View {
    /// The scene's cells, ``WidgetCompanionScene/width`` × ``WidgetCompanionScene/height``, row-major.
    let cells: [UInt32]
    /// A fixed cell size, or nil to cover the frame.
    var cellWidth: CGFloat? = nil

    var body: some View {
        Canvas { context, size in
            let width = WidgetCompanionScene.width, height = WidgetCompanionScene.height
            guard cells.count == width * height else { return }
            let cell = cellWidth ?? WidgetSceneLayout.cell(in: size)
            let originX = (size.width - cell * CGFloat(width)) / 2, originY = size.height - cell * CGFloat(height)
            for y in 0..<height {
                let top = originY + CGFloat(y) * cell
                guard top + cell > 0 else { continue }
                for x in 0..<width {
                    // A hair over each cell, so no seam shows between neighbours at fractional sizes.
                    let rect = CGRect(x: originX + CGFloat(x) * cell, y: top, width: cell + 0.5, height: cell + 0.5)
                    context.fill(Path(rect), with: .color(Color(widgetRGB: cells[y * width + x])))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A framed paper plate behind a card's text on a scene, as the map widget's status plate draws it:
/// the widget's paper in a 3-point ink frame with a small shade, so text keeps the paper's measured
/// contrast (``WidgetTheme``) whatever the scene behind it.
struct WidgetScenePlate: ViewModifier {
    let theme: WidgetTheme
    var padding = EdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 9)

    /// The plate's corner radius.
    static let cornerRadius: CGFloat = 9

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(theme.paper, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius).strokeBorder(theme.frame, lineWidth: 3))
            .background { RoundedRectangle(cornerRadius: Self.cornerRadius).fill(WidgetFixedInk.shade).offset(y: 3) }
    }
}

extension View {
    /// Puts the content on a framed paper plate (``WidgetScenePlate``).
    func widgetScenePlate(_ theme: WidgetTheme,
                          padding: EdgeInsets = EdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 9)) -> some View {
        modifier(WidgetScenePlate(theme: theme, padding: padding))
    }
}

/// A Home Screen card's ground: the person's scene where it fills the card, else the widget's paper.
/// The container background, so iOS drops it on the tinted and clear Home Screens as it drops the paper.
struct WidgetCardGround: View {
    /// The scene's cells, or nil for the plain paper.
    let scene: [UInt32]?
    let paper: Color

    var body: some View {
        if let scene {
            WidgetSceneBackdrop(cells: scene)
        } else {
            paper
        }
    }
}

extension FernletCompanionEntry {
    /// The scene a colour Home Screen card fills itself with (owner's pick A): the person's background,
    /// night while Sprout sleeps, dimmed in dark mode; nil in one colour, on the plain background, before
    /// the first snapshot, or for a token this build does not know.
    func cardScene(dark: Bool, mono: Bool) -> [UInt32]? {
        guard !mono else { return nil }
        return homeScreenScene(dark: dark)
    }
}
