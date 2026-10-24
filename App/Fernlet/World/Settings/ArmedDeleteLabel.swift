import FernletUI
import SwiftUI

/// The face of a typed-gate delete button (Delete everything, Delete iCloud data): solid terracotta
/// with white words once the typed word arms it — the one place the destructive token allows a solid
/// fill — and a faded fill with full-strength ink before, so the words stay readable while the person
/// types. Under the framed look it takes the kit's 2-pt ink frame and solid shadow
/// (`b3-delete-everything`, `b3-icloud-off`). The button around it disables itself; this only draws.
struct ArmedDeleteLabel: View {
    let title: LocalizedStringKey
    let isArmed: Bool
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: look == nil ? 14 : 10)
        Text(title)
            .font(look == nil ? .fernlet(.label) : FernletFramedFont.button)
            .foregroundStyle(isArmed ? Color.onTerracotta : (look?.text ?? Color.bark))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .background(Color.terracotta.opacity(isArmed ? 1 : 0.55), in: shape)
            .overlay { if let look { shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth) } }
            .background { if let look { shape.fill(look.shadow).offset(y: 3) } }
            .contentShape(shape)
    }
}
