import Foundation
import UIKit

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
