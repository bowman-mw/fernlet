import Foundation
import FernletDomainModel

public struct MealPhotoStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func save(_ data: Data) -> UUID? {
        let id = UUID()
        do {
            try data.write(to: url(for: id), options: [.atomic, .completeFileProtection])
            return id
        } catch {
            return nil
        }
    }

    public func imageData(for id: UUID) -> Data? {
        try? Data(contentsOf: url(for: id))
    }

    public func delete(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).jpg")
    }
}
