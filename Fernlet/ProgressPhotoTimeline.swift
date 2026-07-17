#if canImport(UIKit)
import SwiftUI
import PrivateMediaStore

/// The gym progress-photo timeline that lives under the Move tab (#11 piece 3). A private, at-rest-sealed
/// strip of the user's own body photos, newest first, with an add affordance and a tap-through to a
/// detail view for each. Body photos, so nothing here decodes a picture until it scrolls into view, and
/// the whole store (bytes + dates + captions) is sealed — see `ProgressPhotoStore`.
struct ProgressPhotoSection: View {
    var records: [ProgressPhotoRecord]
    /// Loads a photo's sealed bytes on demand (off `FernletStore.progressPhotoData`).
    var loadData: (UUID) -> Data?
    /// A freshly captured photo (camera or library). The parent seals it and refreshes `records`.
    var onCapture: (UIImage) -> Void
    var onOpen: (ProgressPhotoRecord) -> Void

    var body: some View {
        FernletScrollSection("Progress photos") {
            if records.isEmpty {
                VStack(spacing: 16) {
                    EmptyState(text: "See how you're changing. Add a progress photo and it'll build a private timeline here — sealed on your device.")
                    PhotoCaptureControl(onCameraCapture: onCapture) {
                        addLabel(prominent: true)
                    }
                    .accessibilityIdentifier("move.progressPhotos.addFirst")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        PhotoCaptureControl(onCameraCapture: onCapture) {
                            addTile
                        }
                        .accessibilityIdentifier("move.progressPhotos.add")
                        ForEach(records) { record in
                            Button {
                                onOpen(record)
                            } label: {
                                ProgressPhotoCard(record: record, loadData: { loadData(record.id) })
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 2)
                }
                .accessibilityIdentifier("move.progressPhotos")
            }
        }
    }

    private func addLabel(prominent: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.fill")
                .font(.system(size: 16, weight: .semibold))
            Text("Add progress photo")
                .font(.fernlet(.label))
        }
        .foregroundStyle(Color.cream)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.moss, in: Capsule())
        .fernletSmallShadow()
    }

    /// The leading "＋" tile in the populated strip — same footprint as a photo card.
    private var addTile: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.moss.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .frame(width: 132, height: 168)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 22, weight: .semibold))
                        Text("Add")
                            .font(.fernlet(.label))
                    }
                    .foregroundStyle(Color.moss)
                }
            Text(" ")
                .font(.fernlet(.labelSmall))
                .hidden()
        }
    }
}

/// One dated photo in the timeline. Loads its sealed bytes lazily (like the meal polaroid) so a long
/// history doesn't decode every image up front. Deliberately plainer than the playful meal polaroid —
/// no tilt, a calm frame — because these are body photos.
struct ProgressPhotoCard: View {
    let record: ProgressPhotoRecord
    let loadData: () -> Data?
    var body_width: CGFloat = 132

    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.parchment)
                .frame(width: body_width, height: 168)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .font(.title2)
                            .foregroundStyle(Color.slate.opacity(0.4))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.bark.opacity(0.10), lineWidth: 1)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(record.capturedAt.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
                if let caption = record.caption {
                    Text(caption)
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                        .lineLimit(1)
                }
            }
            .frame(width: body_width, alignment: .leading)
        }
        .task {
            // Decode off the main thread (`byPreparingForDisplay`) so scrolling a long strip doesn't
            // jank; only the finished image is assigned back on the MainActor.
            guard image == nil, let data = loadData() else { return }
            image = await UIImage(data: data)?.byPreparingForDisplay()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress photo from \(record.capturedAt.formatted(.dateTime.month(.wide).day().year()))")
    }
}

/// Full-screen view of a single progress photo: the picture, its date, an editable note, and delete.
/// No share affordance by design — these are private body photos and the app never offers to send them.
struct ProgressPhotoDetailView: View {
    var store: FernletStore
    let record: ProgressPhotoRecord
    /// Called right after any persisted change (caption save / delete) so the parent timeline refreshes
    /// from the store deterministically — NOT via a second racing `onDisappear`.
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var caption: String
    @State private var showingDeleteConfirm = false
    @FocusState private var captionFocused: Bool

    init(store: FernletStore, record: ProgressPhotoRecord, onChanged: @escaping () -> Void) {
        self.store = store
        self.record = record
        self.onChanged = onChanged
        _caption = State(initialValue: record.caption ?? "")
    }

    var body: some View {
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
                            .fill(Color.parchment)
                            .frame(height: 360)
                            .overlay {
                                Image(systemName: "figure.strengthtraining.traditional")
                                    .font(.largeTitle)
                                    .foregroundStyle(Color.slate.opacity(0.4))
                            }
                    }
                }
                .frame(maxWidth: .infinity)

                Text(record.capturedAt.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                    .font(.fernlet(.displayMedium))
                    .foregroundStyle(Color.bark)

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Note")
                    TextField("A word about this one — optional", text: $caption, axis: .vertical)
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                        .lineLimit(1...4)
                        .focused($captionFocused)
                        .padding(12)
                        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.bark.opacity(0.10), lineWidth: 1)
                        )
                        // No `.onSubmit` here: a multiline (axis: .vertical) TextField treats Return as a
                        // newline and never fires onSubmit, so the save affordance is the keyboard-toolbar
                        // "Done" below (plus the onDisappear backstop).
                        .accessibilityIdentifier("progressPhoto.caption")
                }

                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("Delete this photo", systemImage: "trash")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.dustyRose)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.dustyRose.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("progressPhoto.delete")
            }
            .padding(20)
        }
        .background(Color.parchment)
        .navigationTitle("Progress photo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if captionFocused {
                ToolbarItem(placement: .keyboard) {
                    Button("Done") {
                        captionFocused = false
                        saveCaption()
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .task {
            // Decode off-main; only the finished image lands back on the MainActor.
            guard image == nil, let data = store.progressPhotoData(for: record.id) else { return }
            image = await UIImage(data: data)?.byPreparingForDisplay()
        }
        // Backstop for the caption if the user leaves without tapping Done (e.g. taps back with the
        // keyboard still up). Idempotent with the Done save. `saveCaption` refreshes the parent itself,
        // so ordering vs the parent no longer matters.
        .onDisappear { saveCaption() }
        .confirmationDialog(
            "Delete this progress photo?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                store.deleteProgressPhoto(id: record.id)
                onChanged()
                dismiss()
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("This removes it from your timeline and your device. Fernlet can't undo this.")
        }
    }

    /// Persists the caption, then refreshes the parent timeline in the SAME step (save → refresh), so the
    /// card never shows a stale caption regardless of view-teardown ordering.
    private func saveCaption() {
        store.updateProgressPhotoCaption(id: record.id, caption: caption)
        onChanged()
    }
}
#endif
