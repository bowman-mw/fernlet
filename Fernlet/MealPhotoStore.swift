import Foundation
import FernletDomainModel

struct MealPhotoStore {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func save(_ data: Data) -> UUID? {
        let id = UUID()
        do {
            try data.write(to: url(for: id), options: [.atomic, .completeFileProtection])
            return id
        } catch {
            return nil
        }
    }

    func imageData(for id: UUID) -> Data? {
        try? Data(contentsOf: url(for: id))
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).jpg")
    }
}
