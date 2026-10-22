import SwiftUI

/// The photo wall as the owner picked it: four overlapping friend prints just under the status bar,
/// with no captions, so the photos speak for themselves. Tap it for the full wall.
struct PhotoStrip: View {
    let photos: [FixturePhoto]
    let action: () -> Void

    /// Each print's left edge and tilt, from the design page's strip.
    private let layout: [(x: CGFloat, angle: Double)] = [(0, -6), (36, 4), (74, -3), (112, 5)]

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(photos.prefix(4).enumerated()), id: \.element.id) { index, photo in
                    PhotoPrint(photo: photo, width: 50)
                        .rotationEffect(.degrees(layout[index].angle))
                        .offset(x: layout[index].x)
                        .zIndex(Double(index))
                }
            }
            .frame(width: 170, height: 66, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Photo wall")
        .accessibilityHint("Opens the full wall")
    }
}

/// One instant-print: a white frame around a fixture photo (a wash and a symbol), with an optional
/// caption for the full wall.
struct PhotoPrint: View {
    let photo: FixturePhoto
    var width: CGFloat = 50
    var caption = false

    var body: some View {
        VStack(spacing: 3) {
            LinearGradient(colors: [FernColors.rgb(photo.top), FernColors.rgb(photo.bottom)], startPoint: .top, endPoint: .bottom)
                .overlay {
                    Image(systemName: photo.symbol)
                        .font(.system(size: width * 0.34, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(height: width * 0.84)
                .clipShape(RoundedRectangle(cornerRadius: 1))
            if caption {
                Text(photo.id)
                    .font(.caption)
                    .foregroundStyle(FernColors.dim)
                    .lineLimit(1)
            }
        }
        .padding(EdgeInsets(top: width * 0.06, leading: width * 0.06, bottom: caption ? 6 : width * 0.18, trailing: width * 0.06))
        .frame(width: width)
        .background(FernColors.rgb(0xFFFDF8), in: RoundedRectangle(cornerRadius: 2))
        .shadow(color: FernColors.ink.opacity(0.3), radius: 2, x: 0, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Photo: \(photo.id)")
    }
}
