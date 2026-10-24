import FernletUI
import SwiftUI

/// The framed terracotta minus that removes a row (`b2-settings-care`): a 26-pt box in a 2-pt
/// terracotta frame with a bold minus, inside a 44-pt tap target supplied by the caller's
/// `fernletIconButton`. Decorative to VoiceOver; the button carries the name ("Remove Shower").
/// Without the framed look it is today's minus-in-a-circle.
struct RemoveMinusTile: View {
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        Group {
            if look != nil {
                let shape = RoundedRectangle(cornerRadius: 7)
                Text(verbatim: "\u{2212}")
                    .font(FernletFramedFont.stepperGlyph)
                    .foregroundStyle(Color.terracottaInk)
                    .frame(width: 26, height: 26)
                    .overlay(shape.strokeBorder(Color.terracottaInk, lineWidth: FernletFramedLook.frameWidth))
            } else {
                Image(systemName: "minus.circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.terracottaInk)
                    .frame(width: 32, height: 32)
            }
        }
        .accessibilityHidden(true)
    }
}
