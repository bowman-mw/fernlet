import FernletFoundation
import Foundation

/// What the car file holds: this iPhone's salt and the car book whose tags were made with it, always together, so
/// neither can be read, written or lost without the other.
nonisolated struct WorldCarRecord: Codable, Equatable, Sendable {
    /// The per-install salt the book's tags are made with.
    var salt: String
    /// Which Bluetooth devices are the person's cars.
    var book: WorldCarBook
}

/// The car book's own file (2026-11-19, after release review F15): the salt and the book in one file whose
/// protection Fernlet sets itself, in place of the two `UserDefaults` keys they lived under.
///
/// - **Why a file:** before the phone's first unlock `UserDefaults` reads as empty with no error, so a reader can't
///   tell "nothing saved" from "can't be read", and a process started then is reported to go on reading empty after
///   the unlock. A file gives three different answers (``Held``): not there, read, or there but unreadable. Only the
///   first may ever lead to a new salt.
/// - **Where:** `Application Support/WorldCars/car-book.json`, written atomically with
///   `completeUntilFirstUserAuthentication` (a drive with the phone locked still links the car), in a folder kept out
///   of device backups. It is outside the World map vault's folder on purpose: Delete map history and the duress
///   recovery lock remove that folder with its keys, and the cars are a setting, not map history, so they stay
///   through both, as they did in `UserDefaults`.
/// - **Wiped by** Delete everything and the silent wipe: `WorldMapPreferences.clearAll` removes it, and
///   ``WorldCarKeeper/forgetAll()`` removes it with the book in memory.
/// - **Bounded** (Power of 10): a file larger than ``maxBytes`` is refused unread.
nonisolated struct WorldCarFile: Sendable {
    /// The folder's name in Application Support (a frozen token).
    static let folderName = "WorldCars"
    /// The file's name in that folder (a frozen token).
    static let fileName = "car-book.json"
    /// The largest file read: a full book is a few kilobytes.
    static let maxBytes = 256 * 1_024

    /// What a read found.
    enum Held: Equatable, Sendable {
        /// No file: nothing was ever saved here, or a wipe removed it.
        case absent
        /// The saved salt and book.
        case record(WorldCarRecord)
        /// The file is there but its bytes can't be read right now (the phone hasn't been unlocked since it
        /// restarted). Nothing is wrong with it: try again later, and never make a new salt or write over it.
        case unreadable
    }

    /// How the file's bytes are read: from disk in the app; tests inject a failure, the way a locked phone's file
    /// protection fails a read.
    typealias Reader = @Sendable (URL) throws -> Data

    /// The file's place on disk.
    let url: URL
    private let readFile: Reader

    /// A car file in `folder`, read with `readFile` (from disk unless a test injects one).
    init(folder: URL, readFile: @escaping Reader = { try Data(contentsOf: $0) }) {
        url = folder.appendingPathComponent(Self.fileName, isDirectory: false)
        self.readFile = readFile
    }

    /// The app's car file, in Application Support.
    static func production() -> WorldCarFile {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return WorldCarFile(folder: support.appendingPathComponent(folderName, isDirectory: true))
    }

    /// Reads the file. A file that is there but can't be read is ``Held/unreadable`` and is left alone. Bytes that
    /// were read but are not a record (another version's, too large, or an empty salt) can never be one later, so
    /// that file is removed and the answer is ``Held/absent``.
    func read() -> Held {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        let data: Data
        do {
            data = try readFile(url)
        } catch {
            FernletAuditLog.log("worldMap.cars.readDeferred", context: ["code": "\((error as NSError).code)"])
            return .unreadable
        }
        do {
            guard data.count <= Self.maxBytes else { throw CocoaError(.fileReadTooLarge) }
            let record = try JSONDecoder().decode(WorldCarRecord.self, from: data)
            guard !record.salt.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            return .record(record)
        } catch {
            FernletAuditLog.log("worldMap.cars.loadFailed")
            return remove() ? .absent : .unreadable
        }
    }

    /// Writes `record` in one atomic step, readable after the first unlock and kept out of backups; whether it was
    /// written. A failure is logged and leaves the file as it was.
    @discardableResult
    func write(_ record: WorldCarRecord) -> Bool {
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var flagged = folder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try flagged.setResourceValues(values)
            let data = try JSONEncoder().encode(record)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            FernletAuditLog.log("worldMap.cars.saveFailed")
            return false
        }
    }

    /// Removes the file (the wipe; a locked phone still allows it); whether it is gone.
    @discardableResult
    func remove() -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            FernletAuditLog.log("worldMap.cars.removeFailed")
            return false
        }
    }
}
