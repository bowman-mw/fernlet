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

    /// `Text`, not `String` (review T2-1). A `String` handed to `.accessibilityLabel(_:)` lands on
    /// the `StringProtocol` overload, which renders it verbatim — so this sentence was frozen
    /// English and was never even harvested into the catalog.
    private var accessibilityText: Text {
        switch presence {
        case .onOtherDevice: Text("Photo of \(name), on your other device")
        case .unavailable: Text("Photo of \(name), couldn't be opened")
        default: Text("Photo of \(name)")
        }
    }

    var body: some View {
        VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(photoFill)
                .frame(width: width, height: width * 0.86)
                .overlay { photoOverlay }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(name)
                .font(.fernlet(.bubble))
                // Full-strength slate, not 58%: the faded caption measured 1.9:1 on the cream frame
                // (matching the shared `PolaroidTile`, which was corrected the same way).
                .foregroundStyle(Color.slate)
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
        .task { await loadThumbnail() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// What sits inside the photo window: the decoded image, or the placeholder that says where the
    /// picture actually is.
    @ViewBuilder
    private var photoOverlay: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else if presence == .onOtherDevice {
            // The meal synced here, but its photo bytes stayed on the device it was taken on.
            // A soft, deliberate placeholder — clearly intentional, not a broken image.
            MealPhotoPlaceholder(systemImage: "iphone.and.arrow.forward", text: "On your other device")
        } else if presence == .unavailable {
            // The sealed file IS here but wouldn't open (corrupt / undecryptable). Say so
            // plainly rather than claiming it's on another device where it isn't.
            MealPhotoPlaceholder(systemImage: "photo.badge.exclamationmark", text: "Couldn't open this photo")
        } else {
            EmptyView()
        }
    }

    /// Decodes the sealed bytes off the main thread, straight to the polaroid's own pixel size — the
    /// sealed bytes are ~1600px, and `byPreparingForDisplay` would retain that full bitmap (~8MB
    /// apiece, ~50MB across a scrolled strip) behind a 128pt thumbnail. Only the finished image is
    /// assigned back on the MainActor.
    private func loadThumbnail() async {
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

    private var photoFill: Color {
        if image == nil && presence == .onThisDevice {
            return placeholderColor
        }
        return Color.cream
    }
}

/// The small in-frame placeholder a polaroid shows when its picture isn't displayable here — one icon
/// over one short line. Shared by the "on your other device" and "couldn't open this photo" states so
/// the two read identically apart from their wording.
private struct MealPhotoPlaceholder: View {
    let systemImage: String
    let text: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.slate.opacity(0.5))
            Text(text)
                .font(.fernlet(.labelSmall))
                // Full-strength slate: this 11pt line explains where the picture went, so it has to
                // be readable on the cream frame.
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 6)
        }
    }
}

/// The full-width 320pt card the meal-photo detail shows in place of a picture it can't display: icon,
/// title, and one calm sentence of explanation. Shared by the "on your other device" and "couldn't
/// open this photo" states.
private struct MealPhotoUnavailableCard: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.cream)
            .frame(height: 320)
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.largeTitle)
                        .foregroundStyle(Color.slate.opacity(0.5))
                    Text(title)
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.slate)
                    Text(detail)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .multilineTextAlignment(.center)
                        .fernletWrappingText()
                        .padding(.horizontal, 24)
                }
            }
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
                    photoArea
                        .frame(maxWidth: .infinity)

                    captionBlock
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
        .task { await loadImage() }
    }

    /// The picture itself, or the card explaining where it is. `Group` keeps the four branches one
    /// view for the shared frame the caller applies.
    @ViewBuilder
    private var photoArea: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else if presence == .onOtherDevice {
                // The photo bytes stayed on the device this meal was snapped on; day data
                // synced here, the picture didn't. A calm, deliberate state.
                MealPhotoUnavailableCard(
                    systemImage: "iphone.and.arrow.forward",
                    title: "On your other device",
                    detail: "This photo lives on the device you took it on. Its details are here; the picture stays where it was snapped."
                )
            } else if presence == .unavailable {
                // The sealed file is on this device but couldn't be opened (corrupt /
                // undecryptable). Say so gently — it's here and broken, not elsewhere.
                MealPhotoUnavailableCard(
                    systemImage: "photo.badge.exclamationmark",
                    title: "Couldn't open this photo",
                    detail: "This photo is saved on this device but couldn't be opened. Its details are still here."
                )
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
    }

    /// The meal's name and the day it was logged, under the photo.
    private var captionBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .font(.fernlet(.displayMedium))
                .foregroundStyle(Color.bark)
            Text(loggedAt.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
        }
    }

    /// Decodes the sealed bytes off the main thread; only the finished image lands back on the
    /// MainActor. A nil read with no file present is the "on your other device" case; a nil read with a
    /// file present is a photo that's here but couldn't be opened.
    private func loadImage() async {
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
#endif
