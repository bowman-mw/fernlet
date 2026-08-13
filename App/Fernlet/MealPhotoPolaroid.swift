#if canImport(UIKit)
import SwiftUI
import FernletUI

/// A logged meal's photo as a classic polaroid — the #11 look the user picked: cream frame, rounded
/// photo, the meal name on the strip, a soft shadow and a gentle tilt. Loads its bytes lazily off the
/// sealed `MealPhotoStore` so the Home strip doesn't decode every photo up front.
struct MealPhotoPolaroid: View {
    let name: String
    let rotation: Double
    let loadData: () -> Data?
    /// Existence-only probe (no decrypt) used to tell a photo that never synced here (no file → "on your
    /// other device") from one that's here but won't open (corrupt → "couldn't open this photo").
    let hasSealedData: () -> Bool
    var placeholderColor: Color = .goldenrod.opacity(0.45)
    var width: CGFloat = 128

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    /// nil until the sealed read runs; false once it comes back empty (no openable bytes on this device).
    @State private var bytesAvailable: Bool?
    /// Whether a sealed file for this photo exists on disk — only consulted once `bytesAvailable == false`
    /// to split "on your other device" (no file) from "couldn't open this photo" (file here but broken).
    @State private var sealedFileExists: Bool = false

    /// These tiles are only ever built for a meal that HAS a photo, so the read outcome alone decides
    /// whether the picture is here, on another device, or here-but-unreadable (see MealPhotoPresence).
    private var presence: MealPhotoPresence {
        MealPhotoPresence.classify(
            hasPhoto: true, sealedFileExists: sealedFileExists, bytesAvailable: bytesAvailable ?? true)
    }

    private var accessibilityText: String {
        switch presence {
        case .onOtherDevice: return "Photo of \(name), on your other device"
        case .unavailable: return "Photo of \(name), couldn't be opened"
        default: return "Photo of \(name)"
        }
    }

    var body: some View {
        VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(photoFill)
                .frame(width: width, height: width * 0.86)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else if presence == .onOtherDevice {
                        // The meal synced here, but its photo bytes stayed on the device it was taken on.
                        // A soft, deliberate placeholder — clearly intentional, not a broken image.
                        VStack(spacing: 5) {
                            Image(systemName: "iphone.and.arrow.forward")
                                .font(.title3)
                                .foregroundStyle(Color.slate.opacity(0.5))
                            Text("On your other device")
                                .font(.fernlet(.labelSmall))
                                .foregroundStyle(Color.slate.opacity(0.75))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                                .padding(.horizontal, 6)
                        }
                    } else if presence == .unavailable {
                        // The sealed file IS here but wouldn't open (corrupt / undecryptable). Say so
                        // plainly rather than claiming it's on another device where it isn't.
                        VStack(spacing: 5) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.title3)
                                .foregroundStyle(Color.slate.opacity(0.5))
                            Text("Couldn't open this photo")
                                .font(.fernlet(.labelSmall))
                                .foregroundStyle(Color.slate.opacity(0.75))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                                .padding(.horizontal, 6)
                        }
                    } else {
                        EmptyView()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(name)
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.slate.opacity(0.58))
                .lineLimit(1)
                .frame(maxWidth: width)
        }
        .padding(.horizontal, 7)
        .padding(.top, 7)
        .padding(.bottom, 14)
        .background(Color.cream.opacity(0.82), in: RoundedRectangle(cornerRadius: 4))
        // `barkShadow` is the fixed dark-brown shadow token; the adaptive `bark` text token resolves
        // near-white under the forced dark appearance and would read as a pale halo, not a shadow.
        .shadow(color: Color.barkShadow.opacity(0.10), radius: 10, x: 0, y: 5)
        .rotationEffect(.degrees(rotation))
        .task {
            // Decode off the main thread, straight to the polaroid's own pixel size — the sealed bytes
            // are ~1600px, and `byPreparingForDisplay` would retain that full bitmap (~8MB apiece,
            // ~50MB across a scrolled strip) behind a 128pt thumbnail. Only the finished image is
            // assigned back on the MainActor.
            guard image == nil else { return }
            guard let data = loadData() else {
                // No openable bytes: record whether a file is nonetheless present, then flip the flag
                // that reveals the placeholder (order matters — presence reads sealedFileExists).
                sealedFileExists = hasSealedData()
                bytesAvailable = false
                return
            }
            bytesAvailable = true
            let pixelSize = CGSize(width: width * displayScale, height: width * 0.86 * displayScale)
            image = await UIImage(data: data)?.byPreparingThumbnail(ofSize: pixelSize)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var photoFill: Color {
        if image == nil && presence == .onThisDevice {
            return placeholderColor
        }
        return Color.cream
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
    /// Existence-only probe (no decrypt): distinguishes a photo that never synced here from one that's
    /// here but won't open. See `MealPhotoPolaroid.hasSealedData`.
    let hasSealedData: () -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    /// nil until the sealed read runs; false once it comes back empty (no openable bytes on this device).
    @State private var bytesAvailable: Bool?
    /// Consulted only when `bytesAvailable == false` — splits "on your other device" (no file) from
    /// "couldn't open this photo" (file present but broken).
    @State private var sealedFileExists: Bool = false

    private var presence: MealPhotoPresence {
        MealPhotoPresence.classify(
            hasPhoto: true, sealedFileExists: sealedFileExists, bytesAvailable: bytesAvailable ?? true)
    }

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
                        } else if presence == .onOtherDevice {
                            // The photo bytes stayed on the device this meal was snapped on; day data
                            // synced here, the picture didn't. A calm, deliberate state.
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.cream)
                                .frame(height: 320)
                                .overlay {
                                    VStack(spacing: 10) {
                                        Image(systemName: "iphone.and.arrow.forward")
                                            .font(.largeTitle)
                                            .foregroundStyle(Color.slate.opacity(0.5))
                                        Text("On your other device")
                                            .font(.fernlet(.body))
                                            .foregroundStyle(Color.slate)
                                        Text("This photo lives on the device you took it on. Its details are here; the picture stays where it was snapped.")
                                            .font(.fernlet(.bodySmall))
                                            .foregroundStyle(Color.slate.opacity(0.8))
                                            .multilineTextAlignment(.center)
                                            .fernletWrappingText()
                                            .padding(.horizontal, 24)
                                    }
                                }
                        } else if presence == .unavailable {
                            // The sealed file is on this device but couldn't be opened (corrupt /
                            // undecryptable). Say so gently — it's here and broken, not elsewhere.
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.cream)
                                .frame(height: 320)
                                .overlay {
                                    VStack(spacing: 10) {
                                        Image(systemName: "photo.badge.exclamationmark")
                                            .font(.largeTitle)
                                            .foregroundStyle(Color.slate.opacity(0.5))
                                        Text("Couldn't open this photo")
                                            .font(.fernlet(.body))
                                            .foregroundStyle(Color.slate)
                                        Text("This photo is saved on this device but couldn't be opened. Its details are still here.")
                                            .font(.fernlet(.bodySmall))
                                            .foregroundStyle(Color.slate.opacity(0.8))
                                            .multilineTextAlignment(.center)
                                            .fernletWrappingText()
                                            .padding(.horizontal, 24)
                                    }
                                }
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
            // Decode off the main thread; only the finished image lands back on the MainActor. A nil read
            // with no file present is the "on your other device" case; a nil read with a file present is a
            // photo that's here but couldn't be opened.
            guard image == nil else { return }
            guard let data = loadData() else {
                sealedFileExists = hasSealedData()
                bytesAvailable = false
                return
            }
            bytesAvailable = true
            image = await UIImage(data: data)?.byPreparingForDisplay()
        }
    }
}
#endif
