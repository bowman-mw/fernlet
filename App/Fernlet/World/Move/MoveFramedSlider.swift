import SwiftUI
import FernletUI

/// A framed slider with a wooden handle (`b3-workout-activity`: "Effort is a framed slider with a wooden
/// handle"): a raised track in a 2-pt ink frame filled with the accent up to the value, and a square wood
/// handle. Whole steps only. VoiceOver and Voice Control get the system slider it stands for, so it adjusts
/// with a swipe and reads its value.
struct MoveFramedSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: Text
    let valueText: Text
    @Environment(\.fernletFramedLook) private var look

    /// The handle's side.
    private static let handle: CGFloat = 26

    var body: some View {
        if let look {
            GeometryReader { proxy in track(look, width: proxy.size.width) }
                .frame(height: 44)
                .accessibilityRepresentation { system }
        } else {
            system.tint(Color.moss)
        }
    }

    /// The system slider: the fallback, and what assistive technology reads.
    private var system: some View {
        Slider(value: $value, in: range, step: 1)
            .accessibilityLabel(label)
            .accessibilityValue(valueText)
    }

    /// Where along the track the value sits, 0…1.
    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span)
    }

    private func track(_ look: FernletFramedLook, width: CGFloat) -> some View {
        let usable = max(width - Self.handle, 1)
        let centre = Self.handle / 2 + usable * fraction
        return ZStack(alignment: .leading) {
            Rectangle().fill(look.raised)
                .overlay(alignment: .leading) { Rectangle().fill(look.accent).frame(width: centre) }
                .overlay(Rectangle().strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
                .frame(height: 14)
            RoundedRectangle(cornerRadius: 6)
                .fill(look.wood)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
                .frame(width: Self.handle, height: Self.handle)
                .offset(x: centre - Self.handle / 2)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            let share = min(max((drag.location.x - Self.handle / 2) / usable, 0), 1)
            let raw = range.lowerBound + Double(share) * (range.upperBound - range.lowerBound)
            let stepped = raw.rounded()
            if stepped != value { value = stepped }
        })
    }
}
