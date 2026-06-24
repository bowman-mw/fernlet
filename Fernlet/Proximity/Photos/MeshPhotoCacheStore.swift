import Foundation
import UIKit
import ImageIO

struct MeshPhotoCacheStore {
    private let indexURL: URL
    private let imageDirectoryURL: URL
    private let thumbnailDirectoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // Reject incoming photos larger than this to prevent decompression-bomb OOM.
    private static let maxIncomingPhotoBytes = 10 * 1024 * 1024  // 10 MB
    private static let thumbnailMaxPixelSize = 400
    // A small, highly-compressed JPEG can decode to a multi-gigabyte bitmap, so the byte cap
    // above is not sufficient. Reject by pixel dimensions/area before the full-resolution bytes
    // are ever persisted (and therefore before any display/library-save sink decodes them).
    // Legitimately shared photos are downscaled to <=1400px, so these bounds leave wide headroom.
    private static let maxImagePixelDimension = 6_000
    private static let maxImagePixelCount = 24_000_000  // ~24 MP
    // Spec §11: cap the on-device photo cache at 1000 (FIFO by recency), with a soft warning near 900.
    // Newest photos are kept; oldest are evicted.
    static let maxCachedPhotos = 1000
    static let cacheWarningThreshold = 900

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
        let capped = Array(photos.sorted { $0.addedAt > $1.addedAt }.prefix(Self.maxCachedPhotos))
        createDirectories()
        for photo in capped {
            guard let imageData = photo.imageData else { continue }
            guard imageData.count <= Self.maxIncomingPhotoBytes else {
                print("[Fernlet] Dropped oversized peer photo (\(imageData.count) bytes)")
                continue
            }
            guard Self.isWithinSafePixelBounds(imageData) else {
                print("[Fernlet] Dropped peer photo exceeding safe pixel dimensions")
                continue
            }
            try? imageData.write(to: imageURL(for: photo.id), options: [.atomic, .completeFileProtection])
            if let thumbnailData = Self.safeThumbnailData(from: imageData) {
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
              let thumbnailData = Self.safeThumbnailData(from: data) else { return nil }
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

    /// Reads pixel dimensions via ImageIO (without decoding the pixels) and rejects images whose
    /// dimensions or total area would decompress to an unreasonable bitmap, independent of the
    /// on-the-wire byte size. Undeterminable dimensions are treated as unsafe.
    static func isWithinSafePixelBounds(_ imageData: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return false
        }
        return width <= maxImagePixelDimension
            && height <= maxImagePixelDimension
            && width * height <= maxImagePixelCount
    }

    // MARK: - Safe thumbnail generation

    /// Generates a thumbnail using ImageIO to avoid fully decompressing untrusted image data.
    /// Checks pixel dimensions before decode and caps output at thumbnailMaxPixelSize.
    private static func safeThumbnailData(from imageData: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }

        // Check dimensions without full decode.
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            // Reject unreasonably large images that would OOM even as thumbnails.
            if width > 20_000 || height > 20_000 { return nil }
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: 0.7)
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
