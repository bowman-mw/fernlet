import FernletUI
import SwiftUI

/// The busy card over a dimmed page while Settings does something long and irreversible
/// (`b3-deleting`, approved 2026-10-24): "Deleting everything…" or "Updating storage settings…" on
/// paper in a 2-pt ink frame with the solid shadow, after a pixel spinner. Without the framed look
/// it is today's cream card with the system spinner.
///
/// The spinner is decorative (hidden from VoiceOver): the sentence is the label, and on the app's
/// most consequential busy state a doubled or empty utterance is least welcome.
struct SettingsBusyCard: View {
    let text: LocalizedStringKey
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        if let look {
            let shape = RoundedRectangle(cornerRadius: FernletFramedLook.cardRadius, style: .continuous)
            HStack(spacing: 14) {
                PixelSpinner(ink: look.text)
                Text(text)
                    .font(FernletFramedFont.rowTitle.weight(.semibold))
                    .foregroundStyle(look.text)
                    .fernletWrappingText()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .background(look.paper, in: shape)
            .overlay(shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
            .background { shape.fill(look.shadow).offset(y: 3) }
            .padding(.horizontal, 32)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                    .tint(Color.moss)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
            }
            .padding(20)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

/// A pixel spinner: eight ink squares around a 3 × 3 ring, a bright head chasing round with a fading
/// tail, one step every 0.12 s. Reduce Motion holds it still (the head at the top left). Decorative.
struct PixelSpinner: View {
    let ink: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The ring's eight cells, clockwise from the top left, as (column, row) in a 3 × 3 grid.
    static let ring: [(Int, Int)] = [(0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1)]

    /// How strongly cell `index` is inked when the head is at `head`: 1 at the head, fading over the
    /// three cells behind it, a faint floor elsewhere.
    static func opacity(cell index: Int, head: Int) -> Double {
        let behind = (head - index + ring.count) % ring.count
        return behind < 4 ? 1 - Double(behind) * 0.25 : 0.15
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { context in
            let head = reduceMotion ? 0 : Int(context.date.timeIntervalSinceReferenceDate / 0.12) % Self.ring.count
            Canvas { canvas, _ in
                for (index, cell) in Self.ring.enumerated() {
                    let rect = CGRect(x: CGFloat(cell.0) * 9, y: CGFloat(cell.1) * 9, width: 7, height: 7)
                    canvas.fill(Path(rect), with: .color(ink.opacity(Self.opacity(cell: index, head: head))))
                }
            }
        }
        .frame(width: 25, height: 25)
        .accessibilityHidden(true)
    }
}
