import FernletFoundation
import Foundation
import WidgetKit

/// The small drive widget's file (owner's pick 2026-11-13, "Small widget: new tiles"): how many tiles the drive under
/// way, or the last one, uncovered, when it started, and when the count last moved. iOS 26 shows small Home Screen
/// widgets in CarPlay with no CarPlay app, so this is what the car's screen shows.
///
/// Byte-format twin of the widget's `WidgetDriveState` (`App/FernletWidgets/DriveWidget.swift`): the JSON keys are the
/// contract between the two processes (`WorldDriveWidgetTests` pins them). **A count and two times only**: no place, no
/// line, no cell. Concurrency: a `Sendable` value type.
nonisolated struct WorldDriveWidgetState: Codable, Equatable, Sendable {
    /// The format this build writes; a widget that finds another shows Sprout.
    static let currentVersion = 1

    /// The format version.
    var version = Self.currentVersion
    /// New tiles the drive uncovered (seen-through fog, never walked before).
    var tiles: Int
    /// When the drive started.
    var startedAt: Date
    /// When the drive was last heard from (a reading during it, or its end).
    var updatedAt: Date
    /// Whether it is still under way (as of ``updatedAt``).
    var isDriving: Bool
}

/// The drive widget's constants: its kind, its file, and how often the count is handed over.
nonisolated enum WorldDriveWidget {
    /// The drive widget's WidgetKit kind: twin of the extension's `FernletWidgetKind.drive` (persisted identity: never
    /// change it once shipped).
    static let kind = "FernletDrive"
    /// Its file in the app group's `FernletWidgets/` folder.
    static let fileName = "WidgetDrive.json"
    /// The least time between two hand-overs of a moving count: WidgetKit allows a widget a few dozen reloads a day.
    static let writeEvery: TimeInterval = 5 * 60
    /// The least time between two hand-overs with nothing new, so the widget knows the drive goes on.
    static let heartbeat: TimeInterval = 20 * 60
    /// The most tiles one drive counts.
    static let maxTiles = 1_000_000
    /// The most cells counted while the phone is locked, before the next unlock merges them.
    static let maxLockedCells = 200_000
}

/// The count's pure half: what one reading changes, and whether to hand it over now. A reading taken while driving
/// starts a drive (the first) or adds its new tiles; one on foot ends it.
nonisolated struct WorldDriveTally: Equatable, Sendable {
    /// The drive under way or last ended; nil before the first.
    private(set) var state: WorldDriveWidgetState?
    /// When it was last handed over.
    private(set) var writtenAt: Date?

    /// A reading at `at`, `driving` or not, that uncovered `newTiles`: whether the state should be written now.
    mutating func note(driving: Bool, newTiles: Int, at: Date) -> Bool {
        guard driving else { return end(at: at) }
        guard var current = state, current.isDriving else {
            state = WorldDriveWidgetState(tiles: min(max(0, newTiles), WorldDriveWidget.maxTiles), startedAt: at,
                                          updatedAt: at, isDriving: true)
            return wrote(at)
        }
        let before = current.tiles
        current.tiles = min(WorldDriveWidget.maxTiles, current.tiles + max(0, newTiles))
        current.updatedAt = max(current.updatedAt, at)
        state = current
        let since = at.timeIntervalSince(writtenAt ?? .distantPast)
        let due = current.tiles != before ? since >= WorldDriveWidget.writeEvery : since >= WorldDriveWidget.heartbeat
        return due ? wrote(at) : false
    }

    /// The drive ended at `at` (a reading on foot): whether to write.
    private mutating func end(at: Date) -> Bool {
        guard var current = state, current.isDriving else { return false }
        current.isDriving = false
        current.updatedAt = max(current.updatedAt, at)
        state = current
        return wrote(at)
    }

    /// Notes a hand-over at `at`.
    private mutating func wrote(_ at: Date) -> Bool {
        writtenAt = at
        return true
    }

    /// Forgets the drive (a wipe, a decoy).
    mutating func clear() {
        state = nil
        writtenAt = nil
    }
}

/// Coordinated write and delete of the drive widget's file in the app group.
///
/// **Readable while locked:** a car's screen shows the widget with the phone locked in a pocket, so the file is
/// protected until the first unlock after a restart only, which a count and two times can bear (nothing of the map).
/// **Never in a backup:** every write sets `isExcludedFromBackup` (a file the flag can't be set on is deleted). The
/// wipes, Delete map history and a decoy delete it (``WorldFogKeeper``). Directory injectable for tests.
struct WorldDriveWidgetFile {
    /// Where the file lives.
    let fileURL: URL

    /// The file in `directory`, or in the app group's widget folder (nil, as the app runs).
    init(directory: URL? = nil) {
        fileURL = (directory ?? WidgetBridgeFiles.containerDirectory()).appendingPathComponent(WorldDriveWidget.fileName)
    }

    /// Writes `state` atomically, kept out of backups. Whether it landed.
    func write(_ state: WorldDriveWidgetState) -> Bool {
        let data: Data
        do {
            data = try JSONEncoder().encode(state)
        } catch {
            FernletAuditLog.log("widgetDrive.encodeFailed")
            return false
        }
        var written = false
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinatorError) { url in
            written = Self.writeExcluded(data, to: url)
        }
        return written && coordinatorError == nil
    }

    /// The state on disk, or nil.
    func read() -> WorldDriveWidgetState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            guard data.count <= 4_096 else { return nil }
            return try JSONDecoder().decode(WorldDriveWidgetState.self, from: data)
        } catch {
            FernletAuditLog.log("widgetDrive.readFailed")
            return nil
        }
    }

    /// Deletes the file. Whether it is gone (a missing file counts).
    func delete() -> Bool {
        var removed = false
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forDeleting, error: &coordinatorError) { url in
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                removed = true
            } catch {
                FernletAuditLog.log("widgetDrive.deleteFailed")
            }
        }
        return removed && coordinatorError == nil
    }

    /// Writes `data` to `url`, protected until the first unlock, then keeps it out of backups. Whether it is there.
    private static func writeExcluded(_ data: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = url
            try excluded.setResourceValues(values)
            return true
        } catch {
            FernletAuditLog.log("widgetDrive.writeFailed", context: ["errorType": "\(type(of: error))"])
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } catch {
                FernletAuditLog.log("widgetDrive.removeAfterFailedWriteFailed")
            }
            return false
        }
    }
}

/// The keeper's drive count (``WorldFogKeeper/driveWidget``): takes each reading's new tiles, writes the file when
/// the tally says so, and reloads the drive widget. Main-actor confined, like its keeper.
@MainActor
final class WorldDriveWidgetKeeper {
    private var tally = WorldDriveTally()
    /// The file (tests point it at their own folder).
    var file: WorldDriveWidgetFile
    /// Reloads the widget (tests count the calls).
    var reload: @MainActor () -> Void

    /// The keeper over the app group's file, reloading the drive widget.
    init() {
        file = WorldDriveWidgetFile()
        reload = { WidgetCenter.shared.reloadTimelines(ofKind: WorldDriveWidget.kind) }
    }

    /// The keeper over `file`, calling `reload` after each write (tests).
    init(file: WorldDriveWidgetFile, reload: @escaping @MainActor () -> Void) {
        self.file = file
        self.reload = reload
    }

    /// The drive under way or last ended, as last noted.
    var state: WorldDriveWidgetState? { tally.state }

    /// A reading at `at`: `driving` or not, uncovering `newTiles`.
    func note(driving: Bool, newTiles: Int, at: Date) {
        guard tally.note(driving: driving, newTiles: newTiles, at: at), let state = tally.state else { return }
        if file.write(state) { reload() }
    }

    /// Forgets the drive and deletes the file (a wipe, Delete map history, a decoy). Whether it is gone.
    func clear() -> Bool {
        tally.clear()
        let removed = file.delete()
        reload()
        return removed
    }
}
