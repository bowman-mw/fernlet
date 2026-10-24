import FernletUI
import SwiftUI

/// A worry card and the "Released — Keep it" strip in the World look (`b2-worry-box`): the paper card
/// in the kit's ink frame with its 3-pt shadow; today's cream card with a soft shadow without it.
struct WorryCardFrame: ViewModifier {
    @Environment(\.fernletFramedLook) private var look

    func body(content: Content) -> some View {
        if let look {
            content
                // The frame rule (ref-frames-rule): pieces inside this card draw flat.
                .environment(\.fernletInFramedSection, true)
                .fernletFramed(look, fill: look.paper, cornerRadius: FernletFramedLook.cardRadius)
        } else {
            content
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .fernletSmallShadow()
        }
    }
}

/// "Let it go" with the pixel box (`b2-worry-box`, `b3-worry-write`): the label of the framed moss
/// primary that seals a worry, filling the button's width. The box is decorative.
struct WorryLetGoLabel: View {
    var body: some View {
        HStack(spacing: 8) {
            WorldSpriteView(sprite: WorldSprites.box, scale: 2)
                .accessibilityHidden(true)
            Text("Let it go")
                .font(FernletFramedFont.button)
        }
        .frame(maxWidth: .infinity)
    }
}
