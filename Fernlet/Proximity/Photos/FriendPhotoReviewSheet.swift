import SwiftUI
import Photos
import UIKit

struct FriendPhotoTile: View {
    let photo: FriendPhotoPayload
    let selected: Bool
    var loadImageData: (() -> Data?)? = nil

    @State private var loadedImageData: Data?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let data = photo.imageData ?? loadedImageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.cream)
                    .frame(height: 112)
                    .overlay(Image(systemName: "photo").foregroundStyle(Color.slate))
            }

            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.moss)
                    .background(Color.cream, in: Circle())
                    .padding(6)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.moss : Color.bark.opacity(0.08), lineWidth: selected ? 2 : 1)
        )
        .task(id: photo.id) {
            guard photo.imageData == nil else { return }
            loadedImageData = loadImageData?()
        }
    }
}

struct FriendPhotoReviewSheet: View {
    let photos: [FriendPhotoPayload]
    @Binding var selectedIDs: Set<UUID>
    let saveSelected: () async -> Void
    let discardAll: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Review pictures")
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(Color.bark)

                    Text("Choose which shared pictures to save. Everything else is deleted from this device's temporary cache.")
                        .font(.callout)
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                        ForEach(photos) { photo in
                            Button {
                                toggle(photo.id)
                            } label: {
                                FriendPhotoTile(photo: photo, selected: selectedIDs.contains(photo.id))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            HStack(spacing: 10) {
                Button("Delete all", role: .destructive, action: discardAll)
                    .buttonStyle(ChipButtonStyle(selected: false))
                Button("Save selected") {
                    Task { await saveSelected() }
                }
                .buttonStyle(ChipButtonStyle(selected: true))
                .disabled(selectedIDs.isEmpty)
            }
            .padding(16)
            .background(Color.parchment)
        }
        .background(Color.parchment)
    }

    private func toggle(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}

enum FriendPhotoLibrarySaver {
    static func save(_ photos: [FriendPhotoPayload]) async throws {
        guard !photos.isEmpty else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw CocoaError(.userCancelled)
        }

        try await PHPhotoLibrary.shared().performChanges {
            for photo in photos {
                guard let imgData = photo.imageData, let image = UIImage(data: imgData) else { continue }
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
        }
    }
}
