// LiveActivityParts.swift
// FernletWidgets
//
// The pieces both Live Activities share in the World look (World Review Batch 4): the framed button
// faces (the card's and the island's), the header line, the pixel progress squares and the paused
// card. Buttons stay `Button(intent:)` at their call sites with `.buttonStyle(.plain)`; only the face
// is drawn here, so the system keeps running each intent in the app's process exactly as before.

import SwiftUI
import WidgetKit

/// Which framed button: the filled moss one that moves the run, or the paper one beside it.
enum LiveActivityButtonRole {
    /// Done set, Next, Finish, Skip rest.
    case primary
    /// −15 s and +15 s.
    case secondary
}

/// A framed button's face on the Lock Screen card (`.pxbtn` in the card): a 3-point edge, 10-point
/// corners, the shaded lower lip and a small drop under it, an optional pixel icon in the word's ink.
struct LiveActivityButtonFace: View {
    let title: Text
    var icon: LiveActivitySprite? = nil
    var role: LiveActivityButtonRole = .primary
    /// Fill the row's width (the primary) or hug the word (−15 s, +15 s).
    var fillsWidth = true
    @Environment(\.liveActivityLook) private var look

    var body: some View {
        let ink = role == .primary ? look.buttonInk : look.secondaryInk
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 7) {
            if let icon {
                LiveActivitySpriteView(sprite: icon, scale: 2, tint: ink)
            }
            title
                .font(LiveActivityFont.button)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 40)
        .background(role == .primary ? look.buttonFill : look.secondaryFill)
        .overlay(alignment: .bottom) { Color.black.opacity(0.18).frame(height: 4) }
        .clipShape(shape)
        .overlay(shape.strokeBorder(look.buttonEdge, lineWidth: 3))
        .background(shape.fill(look.frame.opacity(0.22)).offset(y: 3))
        .contentShape(shape)
    }
}

/// A framed button's face in the expanded Dynamic Island (`.wb4`): a 2-point edge and 14-point corners
/// on the island's black, the primary in leaf green.
struct LiveActivityIslandButtonFace: View {
    let title: Text
    var role: LiveActivityButtonRole = .primary
    var fillsWidth = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let primary = role == .primary
        title
            .font(LiveActivityFont.button)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(primary ? LiveActivityIslandLook.buttonInk : LiveActivityIslandLook.secondaryInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 36)
            .background(shape.fill(primary ? LiveActivityIslandLook.buttonFill : LiveActivityIslandLook.secondaryFill))
            .overlay(shape.strokeBorder(primary ? LiveActivityIslandLook.buttonEdge : LiveActivityIslandLook.secondaryEdge,
                                        lineWidth: 2))
            .contentShape(shape)
    }
}

/// The Lock Screen card's header (`.lah`): a pixel icon and the workout's or recipe's name, in the
/// soft bold face, dimmed when the run is paused.
struct LiveActivityHeaderLabel: View {
    let icon: LiveActivitySprite
    let title: String
    var isDimmed = false
    @Environment(\.liveActivityLook) private var look

    var body: some View {
        HStack(spacing: 6) {
            LiveActivitySpriteView(sprite: icon, scale: 2, tint: look.icon)
                .opacity(isDimmed ? 0.5 : 1)
            Text(verbatim: title)
                .font(LiveActivityFont.header)
                .foregroundStyle(look.soft)
                .lineLimit(1)
        }
    }
}

/// "Exercise 3 of 6" and the pixel progress squares (`.pdot`): 8-point squares in a 1.5-point ink
/// edge, done and current in moss, the rest in pale wheat.
///
/// The squares cap at 8 so a long session can't overflow the header, while the words report the true,
/// uncapped place ("Exercise 10 of 10"). The squares are hidden from VoiceOver; the words say it.
struct LiveActivityProgressSquares: View {
    let index: Int
    let total: Int
    @Environment(\.liveActivityLook) private var look

    private var squareTotal: Int { max(1, min(total, 8)) }
    private var squareIndex: Int { max(0, min(index, squareTotal - 1)) }
    private var labelTotal: Int { max(1, total) }
    private var labelIndex: Int { max(0, min(index, labelTotal - 1)) }

    var body: some View {
        HStack(spacing: 6) {
            Text("Exercise \(labelIndex + 1) of \(labelTotal)")
                .font(LiveActivityFont.progress)
                .foregroundStyle(look.soft)
                .lineLimit(1)
            HStack(spacing: 4) {
                ForEach(0..<squareTotal, id: \.self) { square in
                    Rectangle()
                        .fill(square <= squareIndex ? LiveActivityLook.squareOn : LiveActivityLook.squareOff)
                        .frame(width: 8, height: 8)
                        .overlay(Rectangle().stroke(LiveActivityLook.squareEdge, lineWidth: 1.5))
                }
            }
            .padding(.horizontal, 1)
            .accessibilityHidden(true)
        }
    }
}

extension View {
    /// A countdown's own slot: one line, a fixed width, shrinking rather than truncating.
    ///
    /// A `Text(timerInterval:)` sizes itself to its widest possible value, and a sized-to-fit timer
    /// (`fixedSize`) in a Fraunces face broke the whole Lock Screen card on iOS 26.5 (the card dropped its
    /// padding, frame, countdown and buttons). A fixed slot is the shape WidgetKit lays out reliably;
    /// past an hour, or at the largest text, the digits scale down to fit it.
    func countdownSlot(width: CGFloat, alignment: Alignment) -> some View {
        lineLimit(1)
            .minimumScaleFactor(0.5)
            .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
            .frame(width: width, alignment: alignment)
    }
}

/// The paused card (Fernlet was closed mid-run, so the snapshot went stale): the dimmed header,
/// "Paused" in Fraunces, "Open Fernlet to pick it back up", and pixel pause bars. No timer and no
/// buttons — nothing on it would still be true.
struct LiveActivityPausedCard: View {
    let icon: LiveActivitySprite
    let title: String
    @Environment(\.liveActivityLook) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LiveActivityHeaderLabel(icon: icon, title: title, isDimmed: true)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Paused")
                        .font(LiveActivityFont.title)
                        .foregroundStyle(look.soft)
                    Text("Open Fernlet to pick it back up")
                        .font(LiveActivityFont.line)
                        .foregroundStyle(look.soft)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                // "Paused" is already written beside it, so the bars stay silent.
                LiveActivitySpriteView(sprite: LiveActivitySprites.pause, scale: 5, tint: look.icon)
                    .opacity(0.6)
            }
        }
    }
}
