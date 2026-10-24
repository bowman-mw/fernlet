// FernletLockFramedChrome.swift
// Fernlet
//
// The World look of the lock screens (World Review Batch 2: `b2-private-gate`, the no-passcode
// Private gate, and `b2-private-pin`, the passcode pad): a framed pixel lock, Fraunces headings, the
// dotted page, framed keys and dots. Every piece falls back to today's look when no framed look is
// in the environment, so the lock reads exactly as before outside the World build.

import SwiftUI
import FernletUI

/// The page under a lock screen: the World's dotted page under the framed look, today's parchment
/// without it. Full bleed, beneath the status bar too.
struct FernletLockPageBackground: View {
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        if look != nil {
            FernletDottedPage().ignoresSafeArea()
        } else {
            Color.parchment.ignoresSafeArea()
        }
    }
}

/// The decorative lock above a lock screen's heading: a framed paper tile holding the pixel lock
/// under the framed look, or today's SF Symbol in a moss circle. Hidden from assistive technology
/// (the heading below names the screen).
struct FernletLockGlyph: View {
    /// Today's symbol (the tap gate draws an open lock, the pad a closed one).
    let systemName: String
    /// Today's symbol size and circle diameter.
    var symbolSize: CGFloat = 44
    var diameter: CGFloat = 88
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        Group {
            if look != nil {
                FernletIconTile(size: 84) { FernletIcon(.lock, scale: 5) }
            } else {
                Image(systemName: systemName)
                    .font(.system(size: symbolSize, weight: .semibold))
                    .foregroundStyle(Color.moss)
                    .frame(width: diameter, height: diameter)
                    .background(Color.moss.opacity(0.10), in: Circle())
            }
        }
        .accessibilityHidden(true)
    }
}

/// A lock screen's heading ("Private", "Fernlet Lock"): Fraunces 30 in the look's ink under the
/// framed look, today's header face without it.
struct FernletLockTitle: View {
    let text: Text
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        text
            .font(look != nil ? FernletFramedFont.sheetTitle : .fernlet(.header))
            .foregroundStyle(look?.text ?? Color.bark)
            .multilineTextAlignment(.center)
    }
}

/// A lock screen's supporting line: the look's ink (`primary`) or dim ink (secondary) in DM Sans under
/// the framed look; today's faces and colours without it.
struct FernletLockLine: View {
    let text: Text
    /// Whether this is the screen's main line (ink) or a quieter one (dim).
    var isPrimary: Bool = false
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        text
            .font(look != nil ? (isPrimary ? FernletFramedFont.field : FernletFramedFont.body)
                  : .fernlet(isPrimary ? .body : .bodySmall))
            .foregroundStyle(isPrimary ? (look?.text ?? Color.bark) : (look?.dim ?? Color.slate))
            .multilineTextAlignment(.center)
            .fernletWrappingText()
    }
}

/// The unlock screen's "Enter your 6-digit PIN to continue." line: DM Sans in the look's dim ink under
/// the framed look, today's bubble face in slate without it.
struct FernletLockPrompt: View {
    let text: Text
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        text
            .font(look != nil ? FernletFramedFont.field : .fernlet(.bubble))
            .foregroundStyle(look?.dim ?? Color.slate)
            .multilineTextAlignment(.center)
            .fernletWrappingText()
    }
}

/// The unlock screen's Face ID / Touch ID offer: the symbol and the word in the look's moss link ink,
/// bold, under the framed look; today's moss label without it. The pixel face of the mockup lives in
/// the app's sprite set, out of this module's reach, so the system symbol stays.
struct FernletBiometricLabel: View {
    let title: String
    let systemImage: String
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(look != nil ? FernletFramedFont.button : .fernlet(.label))
            .foregroundStyle(look?.link ?? Color.moss)
            .frame(minHeight: 44)
    }
}

/// The tap gate's one button, dressed: under the framed look the framed moss primary with the pixel
/// lock beside "Unlock" (`b2-private-gate`); without it today's moss capsule. Applied to the button
/// itself, so the button stays the gate's ONE interactive element.
struct FernletTapGateUnlockChrome: ViewModifier {
    /// While a tap is being answered the button dims (and is disabled by the caller).
    let isWorking: Bool
    @Environment(\.fernletFramedLook) private var look

    func body(content: Content) -> some View {
        if look != nil {
            content
                .buttonStyle(ActionPillButtonStyle(.primary))
                .opacity(isWorking ? 0.55 : 1)
        } else {
            content
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                .foregroundStyle(Color.onMoss)
                .padding(.horizontal, 36)
                .padding(.vertical, 16)
                .background(Color.mossFill.opacity(isWorking ? 0.55 : 1), in: RoundedRectangle(cornerRadius: 16))
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// One key face of ``FernletNumericPad``: under the framed look a 72-pt paper tile with the 2.5-pt ink
/// frame and the kit's 3-pt shadow (`b2-private-pin`); without it today's cream tile. The size is a
/// floor, so a digit grown by Dynamic Type pushes the tile out rather than clipping.
struct FernletPadKeyChrome: ViewModifier {
    /// Today's minimum box (the framed look uses 72 × 72).
    let minWidth: CGFloat
    let minHeight: CGFloat
    @Environment(\.fernletFramedLook) private var look

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        if let look {
            content
                .frame(minWidth: 72, minHeight: 72)
                // The paper first, then the shadow behind it: the other order paints the 22% ink
                // shadow over the whole face.
                .background(look.raised, in: shape)
                .background(shape.fill(look.shadow).offset(y: 3))
                .overlay(shape.strokeBorder(look.ink, lineWidth: 2.5))
                .contentShape(shape)
        } else {
            content
                .frame(minWidth: minWidth, minHeight: minHeight)
                .background(Color.cream, in: shape)
                .overlay(shape.stroke(Color.bark.opacity(0.08), lineWidth: 1))
        }
    }
}

/// The masked PIN progress: under the framed look, `total` framed squares with the first `entered`
/// filled in ink (`b2-private-pin`); without it today's circles. The caller makes the row one
/// accessibility element with a spoken count.
struct FernletPinDots: View {
    let entered: Int
    let total: Int
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        HStack(spacing: look != nil ? 14 : 16) {
            ForEach(0..<total, id: \.self) { index in
                if let look {
                    RoundedRectangle(cornerRadius: 5)
                        // Entered digits in the text ink: dark on light paper, cream on dark.
                        .fill(index < entered ? look.text : look.raised)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(look.ink, lineWidth: 2.5))
                        .frame(width: 22, height: 22)
                } else {
                    Circle()
                        .fill(index < entered ? Color.bark : Color.clear)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.bark.opacity(0.35), lineWidth: 1.5))
                }
            }
        }
    }
}

/// The tap gate button's label: the pixel lock and "Unlock" under the framed look, the word alone
/// without it. The lock is decorative; the button's name is the word.
struct FernletTapGateUnlockLabel: View {
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        HStack(spacing: 8) {
            if let look {
                FernletIcon(.lock, scale: 2, tint: look.onAccent)
                    .accessibilityHidden(true)
            }
            Text(GateCopy.Tap.unlock)
                .font(look != nil ? FernletFramedFont.button : .fernlet(.label))
        }
        .padding(.horizontal, look != nil ? 14 : 0)
    }
}
