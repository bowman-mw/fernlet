#if canImport(UIKit)
import SwiftUI

/// A logged meal's photo as a classic polaroid — the #11 look the user picked: cream frame, rounded
/// photo, the meal name on the strip, a soft shadow and a gentle tilt. Loads its bytes lazily off the
/// sealed `MealPhotoStore` so the Home strip doesn't decode every photo up front.
struct MealPhotoPolaroid: View {
    let name: String
    let rotation: Double
    let loadData: () -> Data?
    var width: CGFloat = 128

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.cream)
                .frame(width: width, height: width * 0.86)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "fork.knife")
                            .font(.title3)
                            .foregroundStyle(Color.slate.opacity(0.45))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(name)
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark.opacity(0.72))
                .lineLimit(1)
                .frame(maxWidth: width)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .background(Color.cream.opacity(0.92), in: RoundedRectangle(cornerRadius: 5))
        // `barkShadow` is the fixed dark-brown shadow token; the adaptive `bark` text token resolves
        // near-white under the forced dark appearance and would read as a pale halo, not a shadow.
        .shadow(color: Color.barkShadow.opacity(0.10), radius: 10, x: 0, y: 5)
        .rotationEffect(.degrees(rotation))
        .task {
            // Decode off the main thread, straight to the polaroid's own pixel size — the sealed bytes
            // are ~1600px, and `byPreparingForDisplay` would retain that full bitmap (~8MB apiece,
            // ~50MB across a scrolled strip) behind a 128pt thumbnail. Only the finished image is
            // assigned back on the MainActor.
            guard image == nil, let data = loadData() else { return }
            let pixelSize = CGSize(width: width * displayScale, height: width * 0.86 * displayScale)
            image = await UIImage(data: data)?.byPreparingThumbnail(ofSize: pixelSize)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Photo of \(name)")
    }
}

/// A light tap-through for a "Recent bites" polaroid: the meal's photo shown larger, with its name and
/// the day it was logged, dismissible. Mirrors the progress-photo detail's shape but deliberately WITHOUT
/// any lock/snapshot gating — meal photos aren't private the way body photos are. Loads the sealed bytes
/// lazily off the passed closure; never fetches anything over the network.
struct MealPhotoDetailView: View {
    let name: String
    let loggedAt: Date
    let loadData: () -> Data?

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Group {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        } else {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.cream)
                                .frame(height: 320)
                                .overlay {
                                    Image(systemName: "fork.knife")
                                        .font(.largeTitle)
                                        .foregroundStyle(Color.slate.opacity(0.4))
                                }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(name)
                            .font(.fernlet(.displayMedium))
                            .foregroundStyle(Color.bark)
                        Text(loggedAt.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.slate)
                    }
                }
                .padding(20)
            }
            .background(Color.parchment)
            .navigationTitle("Meal photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            // Decode off the main thread; only the finished image lands back on the MainActor.
            guard image == nil, let data = loadData() else { return }
            image = await UIImage(data: data)?.byPreparingForDisplay()
        }
    }
}
#endif
