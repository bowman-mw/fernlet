import SwiftUI

/// The World build's "one design language" for cards (owner-approved 2026-10-23, `b1-language`):
/// every container is paper in a 2-pt ink frame with a solid drop shadow, section labels carry a small
/// framed square, and chips, tiles and switches share the frame.
///
/// An environment value, unset by default, so nothing changes until a surface opts in: the World's
/// Today panel sets it, and each other panel sets it as its own redesign lands. ``FernletCard`` and
/// ``SectionLabel`` read it here; app views read it for their own inner pieces (the unwell row, the
/// First aid card, chips). The colours come from the caller's theme, so this module owns the shape
/// of the look and none of its palette.
public struct FernletFramedLook: Sendable {
    /// A card's fill.
    public var paper: Color
    /// Recessed surfaces inside a card: a bar's track, a switch that is off.
    public var paperLow: Color
    /// Raised pieces on a card: chips, icon tiles.
    public var raised: Color
    /// Every frame.
    public var ink: Color
    /// Titles and labels on the look's paper: dark ink in light mode, cream in dark mode (a frame's
    /// ink would vanish on dark paper).
    public var text: Color
    /// The solid drop shadow under a card (drawn 3 pt down).
    public var shadow: Color
    /// The calm card's fill (First aid).
    public var sage: Color
    /// The gentle-day row's fill ("I'm unwell today").
    public var rose: Color
    /// The small square before a section label.
    public var mark: Color

    public init(paper: Color, paperLow: Color, raised: Color, ink: Color, text: Color, shadow: Color,
                sage: Color, rose: Color, mark: Color) {
        self.paper = paper
        self.paperLow = paperLow
        self.raised = raised
        self.ink = ink
        self.text = text
        self.shadow = shadow
        self.sage = sage
        self.rose = rose
        self.mark = mark
    }

    /// A card's corner radius in this look.
    public static let cardRadius: CGFloat = 12
    /// A frame's width on cards and inner pieces.
    public static let frameWidth: CGFloat = 2
}

public extension EnvironmentValues {
    /// The framed look, when a surface has opted in; nil draws every card as it always has.
    @Entry var fernletFramedLook: FernletFramedLook? = nil
}

public extension View {
    /// Frames this view as one of the look's raised pieces (a chip, an icon tile): the raised fill,
    /// a 2-pt ink frame and a 2-pt solid shadow, in `cornerRadius` corners.
    func fernletFramed(_ look: FernletFramedLook, fill: Color? = nil, cornerRadius: CGFloat = 8) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(fill ?? look.raised, in: shape)
            .overlay(shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
            .background { shape.fill(look.shadow).offset(y: 2) }
    }
}
