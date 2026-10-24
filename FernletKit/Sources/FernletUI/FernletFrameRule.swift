//
//  FernletFrameRule.swift
//  FernletUI
//
//  The frame rule (World Review Refinements, `ref-frames-rule`, approved by the owner on 2026-10-24):
//  one frame per section, 1-pt hairlines inside it, frames on controls only. Applied once here, in the
//  shared pieces, so every screen follows it without an edit of its own.
//

import SwiftUI

/// The frame rule's numbers and its one decision: which pieces keep a frame inside a section.
///
/// A *section* is one framed container: a ``FernletCard``, a ``FernletFramedSection`` or a framed
/// `Form` section. It has the only frame: 2 pt of ink, 12-pt corners, a 3-pt solid shadow and 14 × 15 pt
/// of padding. Inside it, rows are split by 1-pt full-width hairlines (ink at 16 %; cream at 16 % in
/// dark mode; 40 % under Increase Contrast), 10 pt above and below each row. Controls keep their frames
/// (buttons, chips, fields, steppers, switches, checkboxes, progress bars, photos and the Add photo drop
/// target); rows, tiles, icon squares and notes inside a section lose theirs, and notes and tiles keep
/// their tint. Sections sit 16 pt apart, each label 6 pt above its frame.
///
/// Pure values, so tests assert on them; the views read them (``FernletCard``, ``FernletFramedSection``,
/// ``FernletDottedRule``, ``FernletIconTile``, ``FernletNotice``, `fernletFrameRulePiece(_:fill:cornerRadius:)`).
nonisolated public struct FernletFrameRule: Sendable {
    /// A section's frame: 2 pt of ink.
    public static let frameWidth: CGFloat = 2
    /// A section's corners.
    public static let cornerRadius: CGFloat = 12
    /// How far down a section's solid shadow is drawn.
    public static let shadowOffset: CGFloat = 3
    /// A section's padding above and below its content.
    public static let verticalPadding: CGFloat = 14
    /// A section's padding before and after its content.
    public static let horizontalPadding: CGFloat = 15
    /// A hairline's thickness.
    public static let hairlineWidth: CGFloat = 1
    /// The air above and below each row inside a section.
    public static let rowSpacing: CGFloat = 10
    /// The space between two sections.
    public static let sectionSpacing: CGFloat = 16
    /// The space between a section's label and its frame.
    public static let labelGap: CGFloat = 6

    /// A section's padding, 14 pt above and below and 15 pt at the sides.
    public static var padding: EdgeInsets {
        EdgeInsets(top: verticalPadding, leading: horizontalPadding, bottom: verticalPadding, trailing: horizontalPadding)
    }

    /// The hairline's opacity over its ink (light mode) or cream (dark mode): 16 %, or 40 % under
    /// Increase Contrast.
    public static func hairlineOpacity(increasedContrast: Bool) -> Double {
        increasedContrast ? 0.4 : 0.16
    }

    /// A piece of a screen, as the rule sorts them.
    public enum Piece: CaseIterable, Sendable {
        /// A card or a framed section (nested inside another one, it is a nested card).
        case section
        /// Controls: they keep their frames everywhere.
        case button, chip, field, stepper, toggle, checkbox, progressBar, photo, addPhoto
        /// A row of a section.
        case row
        /// A tile (a macro tile, a step's number): keeps its tint inside a section.
        case tile
        /// The small square behind an icon: sits bare inside a section.
        case iconSquare
        /// A note or notice: keeps its tint inside a section.
        case note
    }

    /// How a piece is drawn.
    public enum Treatment: Sendable, Equatable {
        /// Its fill in a 2-pt ink frame.
        case framed
        /// Its fill (its tint) without a frame.
        case tintOnly
        /// Neither fill nor frame.
        case bare
    }

    /// How the rule draws `piece`, on its own or inside a section.
    public static func treatment(of piece: Piece, insideSection: Bool) -> Treatment {
        switch piece {
        case .button, .chip, .field, .stepper, .toggle, .checkbox, .progressBar, .photo, .addPhoto:
            return .framed
        case .row:
            return .bare
        case .section, .iconSquare:
            return insideSection ? .bare : .framed
        case .tile, .note:
            return insideSection ? .tintOnly : .framed
        }
    }

    /// Whether `piece` has a frame where it sits.
    public static func isFramed(_ piece: Piece, insideSection: Bool) -> Bool {
        treatment(of: piece, insideSection: insideSection) == .framed
    }
}

public extension EnvironmentValues {
    /// Whether this view sits inside a section's frame (a framed ``FernletCard``, a
    /// ``FernletFramedSection`` or a framed `Form` section): the frame rule's pieces read it to drop
    /// their own frames there. A hand-drawn section sets it on its content to join the rule;
    /// ``SwiftUI/View/fernletSheet()``, ``FernletFocusedFlow`` and the framed Form clear it, since a sheet
    /// presented from inside a card inherits the card's environment.
    @Entry var fernletInFramedSection: Bool = false
}

public extension View {
    /// Draws this view as one of the frame rule's pieces (a tile, an icon square, a note): `fill` in a
    /// 2-pt ink frame with `cornerRadius` corners on its own; inside a section, its tint without the frame
    /// (a tile, a note) or bare (an icon square), as ``FernletFrameRule/treatment(of:insideSection:)``
    /// says. Without the framed look it draws `fill` alone, as the pieces always have.
    func fernletFrameRulePiece(_ piece: FernletFrameRule.Piece, fill: Color?, cornerRadius: CGFloat) -> some View {
        modifier(FernletFrameRulePieceModifier(piece: piece, fill: fill, cornerRadius: cornerRadius))
    }
}

/// Implements ``SwiftUI/View/fernletFrameRulePiece(_:fill:cornerRadius:)``.
struct FernletFrameRulePieceModifier: ViewModifier {
    let piece: FernletFrameRule.Piece
    let fill: Color?
    let cornerRadius: CGFloat
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.fernletInFramedSection) private var inSection

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let treatment = look == nil ? .tintOnly : FernletFrameRule.treatment(of: piece, insideSection: inSection)
        content
            .background(treatment == .bare ? Color.clear : (fill ?? look?.raised ?? Color.cream), in: shape)
            .overlay {
                if let look, treatment == .framed {
                    shape.strokeBorder(look.ink, lineWidth: FernletFrameRule.frameWidth)
                }
            }
    }
}
