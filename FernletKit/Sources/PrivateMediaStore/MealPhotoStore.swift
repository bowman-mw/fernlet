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

    /// Deletes every stored photo file.
    ///
    /// Ownership lives in `Meal.photoID`, scattered across day records — so once the days are cleared
    /// there is nothing left that knows these files exist, and per-id deletion can no longer reach them.
    /// A "delete everything" that skipped this would strand the user's food photos on disk permanently,
    /// unreferenced and invisible. Removing the directory itself also takes any stray non-.jpg contents.
    @discardableResult public func deleteAll() -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return true }
        do {
            try FileManager.default.removeItem(at: directory)
            // Recreate so the store stays usable for the rest of the session without a relaunch.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).jpg")
    }
}
