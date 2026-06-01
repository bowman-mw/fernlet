import SwiftUI
import Photos
import UIKit

struct FriendPhotoPayload: Codable, Equatable, Identifiable {
    let id: UUID
    let imageData: Data?               // non-nil for epoch-0 unencrypted or locally-decrypted photos
    let encryptedImageData: Data?      // AES-256-GCM ciphertext + 16-byte tag; non-nil when transmitted encrypted
    let nonce: Data?                   // 12-byte GCM nonce; paired with encryptedImageData
    let keyEpoch: Int                  // 0 = unencrypted legacy; ≥1 = encrypted
    let addedAt: Date
    let senderName: String
    let senderFingerprint: String?
    let senderSigningPublicKey: Data?
    let session: FriendPhotoSessionMetadata?

    // Epoch-0 / already-decrypted initialiser
    init(id: UUID = UUID(), imageData: Data, addedAt: Date = Date(), senderName: String,
         senderFingerprint: String? = nil, senderSigningPublicKey: Data? = nil,
         session: FriendPhotoSessionMetadata? = nil) {
        self.id = id
        self.imageData = imageData
        self.encryptedImageData = nil
        self.nonce = nil
        self.keyEpoch = 0
        self.addedAt = addedAt
        self.senderName = senderName
        self.senderFingerprint = senderFingerprint
        self.senderSigningPublicKey = senderSigningPublicKey
        self.session = session
    }

    // Encrypted initialiser (epoch ≥ 1); used when transmitting over the wire
    init(id: UUID = UUID(), encryptedImageData: Data, nonce: Data, keyEpoch: Int,
         addedAt: Date = Date(), senderName: String,
         senderFingerprint: String? = nil, senderSigningPublicKey: Data? = nil,
         session: FriendPhotoSessionMetadata? = nil) {
        self.id = id
        self.imageData = nil
        self.encryptedImageData = encryptedImageData
        self.nonce = nonce
        self.keyEpoch = keyEpoch
        self.addedAt = addedAt
        self.senderName = senderName
        self.senderFingerprint = senderFingerprint
        self.senderSigningPublicKey = senderSigningPublicKey
        self.session = session
    }

    // Returns a copy with imageData set and encryption fields cleared, for local caching after decryption.
    func withDecryptedImageData(_ data: Data) -> FriendPhotoPayload {
        return FriendPhotoPayload(
            id: id,
            imageData: data,
            addedAt: addedAt,
            senderName: senderName,
            senderFingerprint: senderFingerprint,
            senderSigningPublicKey: senderSigningPublicKey,
            session: session
        )
    }

    func withSession(_ session: FriendPhotoSessionMetadata) -> FriendPhotoPayload {
        FriendPhotoPayload(
            id: id,
            imageData: imageData,
            encryptedImageData: encryptedImageData,
            nonce: nonce,
            keyEpoch: keyEpoch,
            addedAt: addedAt,
            senderName: senderName,
            senderFingerprint: senderFingerprint,
            senderSigningPublicKey: senderSigningPublicKey,
            session: session
        )
    }

    func withoutImageData() -> FriendPhotoPayload {
        FriendPhotoPayload(
            id: id,
            imageData: nil,
            encryptedImageData: encryptedImageData,
            nonce: nonce,
            keyEpoch: keyEpoch,
            addedAt: addedAt,
            senderName: senderName,
            senderFingerprint: senderFingerprint,
            senderSigningPublicKey: senderSigningPublicKey,
            session: session
        )
    }

    private init(
        id: UUID,
        imageData: Data?,
        encryptedImageData: Data?,
        nonce: Data?,
        keyEpoch: Int,
        addedAt: Date,
        senderName: String,
        senderFingerprint: String?,
        senderSigningPublicKey: Data?,
        session: FriendPhotoSessionMetadata?
    ) {
        self.id = id
        self.imageData = imageData
        self.encryptedImageData = encryptedImageData
        self.nonce = nonce
        self.keyEpoch = keyEpoch
        self.addedAt = addedAt
        self.senderName = senderName
        self.senderFingerprint = senderFingerprint
        self.senderSigningPublicKey = senderSigningPublicKey
        self.session = session
    }
}

struct FriendPhotoSessionParticipant: Codable, Equatable, Identifiable {
    var id: String { fingerprint }

    let fingerprint: String
    let displayName: String
}

struct FriendPhotoSessionMetadata: Codable, Equatable, Identifiable {
    let id: UUID
    let meshID: UUID?
    let meshName: String?
    let startedAt: Date
    let participants: [FriendPhotoSessionParticipant]
}

struct FriendPhotoManifestEntry: Codable, Equatable {
    let id: UUID
    let senderFingerprint: String
    let keyEpoch: Int   // receiver skips requesting photos from epochs it cannot decrypt

    init(id: UUID, senderFingerprint: String, keyEpoch: Int = 0) {
        self.id = id
        self.senderFingerprint = senderFingerprint
        self.keyEpoch = keyEpoch
    }
}

struct FriendPhotoManifestPayload: Codable, Equatable {
    let entries: [FriendPhotoManifestEntry]
}

struct FriendPhotoRequestPayload: Codable, Equatable {
    let missingPhotoIDs: [UUID]
}

struct MeshPhotoCacheStore {
    private let indexURL: URL
    private let imageDirectoryURL: URL
    private let thumbnailDirectoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(indexURL: URL) {
        self.indexURL = indexURL
        let baseURL = indexURL.deletingLastPathComponent()
        self.imageDirectoryURL = baseURL.appendingPathComponent("MeshPhotos", isDirectory: true)
        self.thumbnailDirectoryURL = baseURL.appendingPathComponent("MeshPhotoThumbnails", isDirectory: true)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> [FriendPhotoPayload] {
        guard let data = try? Data(contentsOf: indexURL), !data.isEmpty,
              let photos = try? decoder.decode([FriendPhotoPayload].self, from: data) else { return [] }
        save(photos)
        return photos.map { $0.withoutImageData() }
    }

    func save(_ photos: [FriendPhotoPayload]) {
        let capped = Array(photos.sorted { $0.addedAt > $1.addedAt }.prefix(200))
        createDirectories()
        for photo in capped {
            guard let imageData = photo.imageData else { continue }
            try? imageData.write(to: imageURL(for: photo.id), options: [.atomic, .completeFileProtection])
            if let thumbnailData = UIImage(data: imageData)?.friendPhotoThumbnailData() {
                try? thumbnailData.write(to: thumbnailURL(for: photo.id), options: [.atomic, .completeFileProtection])
            }
        }
        guard let data = try? encoder.encode(capped.map { $0.withoutImageData() }) else { return }
        try? data.write(to: indexURL, options: [.atomic, .completeFileProtection])
        removeOrphanedFiles(keeping: Set(capped.map(\.id)))
    }

    func imageData(for photo: FriendPhotoPayload) -> Data? {
        photo.imageData ?? (try? Data(contentsOf: imageURL(for: photo.id)))
    }

    func thumbnailData(for photo: FriendPhotoPayload) -> Data? {
        if let data = try? Data(contentsOf: thumbnailURL(for: photo.id)) {
            return data
        }
        guard let data = imageData(for: photo),
              let thumbnailData = UIImage(data: data)?.friendPhotoThumbnailData() else { return nil }
        try? thumbnailData.write(to: thumbnailURL(for: photo.id), options: [.atomic, .completeFileProtection])
        return thumbnailData
    }

    func hydrated(_ photo: FriendPhotoPayload) -> FriendPhotoPayload? {
        guard let data = imageData(for: photo) else { return nil }
        return FriendPhotoPayload(
            id: photo.id,
            imageData: data,
            addedAt: photo.addedAt,
            senderName: photo.senderName,
            senderFingerprint: photo.senderFingerprint,
            senderSigningPublicKey: photo.senderSigningPublicKey,
            session: photo.session
        )
    }

    private func createDirectories() {
        try? FileManager.default.createDirectory(at: imageDirectoryURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbnailDirectoryURL, withIntermediateDirectories: true)
    }

    private func imageURL(for id: UUID) -> URL {
        imageDirectoryURL.appendingPathComponent("\(id.uuidString).jpg")
    }

    private func thumbnailURL(for id: UUID) -> URL {
        thumbnailDirectoryURL.appendingPathComponent("\(id.uuidString).jpg")
    }

    private func removeOrphanedFiles(keeping ids: Set<UUID>) {
        for directoryURL in [imageDirectoryURL, thumbnailDirectoryURL] {
            guard let urls = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else { continue }
            for url in urls {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      !ids.contains(id) else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

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

extension UIImage {
    func resizedForFriendSharing(maxDimension: CGFloat = 1400) -> UIImage {
        let largestSide = max(size.width, size.height)
        guard largestSide > maxDimension else { return self }
        let scale = maxDimension / largestSide
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    func friendPhotoThumbnailData(maxDimension: CGFloat = 320) -> Data? {
        resizedForFriendSharing(maxDimension: maxDimension).jpegData(compressionQuality: 0.72)
    }
}
