import FernletUI
import SwiftUI

/// The PIN's progress in the app's own passcode sheets (change passcode, the shared verify sheet, the
/// duress code): square pixel dots under the framed look, inked once entered, paper in a 2-pt ink
/// frame while empty (`b3-lock-pin`, `b3-passcode-verify`, `b3-duress-entry`); today's round dots
/// without it. Drawing only: it is handed the count, never the digits.
struct SettingsPinDots: View {
    let entered: Int
    let total: Int
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        HStack(spacing: look == nil ? 16 : 14) {
            ForEach(0..<total, id: \.self) { index in
                if let look {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(index < entered ? look.text : look.raised)
                        .frame(width: 18, height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
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
