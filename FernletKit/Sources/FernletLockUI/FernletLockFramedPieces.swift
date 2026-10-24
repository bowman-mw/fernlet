//
//  FernletLockFramedPieces.swift
//  FernletLockUI
//
//  The lock screens' pieces in the World's one design language (World Review Batch 3, approved
//  2026-10-24: `b3-lock-kind`, `b3-lock-pin`, `b3-lock-disclosure`): a
//  framed radio card, and the two pixel glyphs the pad and the disclosure draw. Each reads
//  `fernletFramedLook` and falls back to today's look when it is unset. Drawing only: nothing here
//  reads, holds or compares a passcode.
//

import FernletUI
import SwiftUI

/// The two one-colour pixel glyphs the lock screens draw: the pad's delete key and the disclosure's
/// flag. Drawn here rather than through the app's sprite renderer because the renderer only draws the
/// framed primitives' icons; both take the look's ink, so they stay visible on dark paper.
enum LockPixelGlyph {
    case backspace, flag

    /// Rows of the glyph, `k` inked and `.` clear (the design page's sprites, key for key).
    var rows: [String] {
        switch self {
        case .backspace: ["...kkkkkkkk", "..k.......k", ".k..k...k.k", "k....k.k..k", "k.....k...k",
                          "k....k.k..k", ".k..k...k.k", "..k.......k", "...kkkkkkkk"]
        case .flag: ["k.......", "kkkkkkk.", "kkkkkk..", "kkkkkkk.", "k.......", "k.......", "k.......", "k......."]
        }
    }
}

/// Draws a ``LockPixelGlyph`` at a whole-number scale in one ink. Decorative.
struct LockPixelGlyphView: View {
    let glyph: LockPixelGlyph
    var scale: CGFloat = 2
    let ink: Color

    var body: some View {
        let rows = glyph.rows
        let width = rows.map(\.count).max() ?? 0
        Canvas { context, _ in
            for (y, row) in rows.enumerated() {
                for (x, key) in row.enumerated() where key == "k" {
                    let rect = CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale)
                    context.fill(Path(rect), with: .color(ink))
                }
            }
        }
        .frame(width: CGFloat(width) * scale, height: CGFloat(rows.count) * scale)
        .accessibilityHidden(true)
    }
}

/// A framed radio card's chrome (`.rc3`, `b3-lock-kind`): paper in a 2-pt ink frame with the solid
/// shadow, a 3-pt moss ring outside the frame when chosen, and the framed tick box top right.
public struct LockRadioCardChrome: ViewModifier {
    let isSelected: Bool
    let look: FernletFramedLook

    /// - Parameters:
    ///   - isSelected: Whether this card is the chosen one (the moss ring and the filled tick).
    ///   - look: The framed look the card draws in.
    public init(isSelected: Bool, look: FernletFramedLook) {
        self.isSelected = isSelected
        self.look = look
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: FernletFramedLook.cardRadius, style: .continuous)
        HStack(alignment: .top, spacing: 12) {
            content.frame(maxWidth: .infinity, alignment: .leading)
            tickBox
        }
        .padding(EdgeInsets(top: 14, leading: 15, bottom: 14, trailing: 15))
        .background(look.paper, in: shape)
        .overlay(shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
        .background { shape.fill(look.shadow).offset(y: 3) }
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: FernletFramedLook.cardRadius + 3, style: .continuous)
                    .strokeBorder(look.mark, lineWidth: 3)
                    .padding(-3)
            }
        }
        // Room for the ring either way, so choosing never shifts the cards.
        .padding(3)
    }

    /// The 26-pt tick box: the accent with a white tick when chosen. Decorative; the card's button
    /// carries the selected trait.
    private var tickBox: some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        return ZStack {
            shape.fill(isSelected ? look.accent : look.raised)
            if isSelected { FernletIcon(.check, scale: 2, tint: look.onAccent) }
        }
        .frame(width: 26, height: 26)
        .overlay(shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
        .accessibilityHidden(true)
    }
}
