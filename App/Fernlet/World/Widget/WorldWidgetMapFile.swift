import FernletFoundation
import Foundation
import UIKit
import WidgetKit

/// The map widget's picture as the app hands it over (owner's Q36, `b4-new-map`, round 6b): the map
/// around the person with their marked places and saved trails drawn on it, light and dark, and when it
/// was taken ("Map from 9:40").
///
/// Byte-format twin of the widget's `WidgetMapPicture` (`App/FernletWidgets/WidgetSharedModels.swift`):
/// the property-list keys are the contract between the two processes (`WidgetMapTests` pins them). No
/// coordinate rides in it, and nothing of Private: no visit count, no day, no history — only a picture.
struct WorldWidgetMapPicture: Codable, Equatable {
    /// The format this build writes; a widget that finds another skips the picture.
    static let currentVersion = 1

    /// The format version.
    var version: Int
    /// When the picture was taken.
    var takenAt: Date
    /// The light picture, PNG.
    var light: Data
    /// The dark picture, PNG.
    var dark: Data
}

/// The map widget's constants: its kind, the file it reads, and the picture's size and zoom.
enum WorldWidgetMap {
    /// The map widget's WidgetKit kind — twin of the extension's `FernletWidgetKind.map` (persisted
    /// identity: never change it once shipped).
    static let kind = "FernletMap"
    /// The picture's file in the app group's `FernletWidgets/` folder.
    static let fileName = "WidgetMap.plist"
    /// The largest picture file the widget reads (both PNGs together are about 2 MB).
    static let maxBytes = 8 * 1_024 * 1_024
    /// The picture's size in points: the largest large widget, whose shape every large widget shares, so
    /// the picture fills any of them without cutting Apple's credit off.
    static let pictureSize = CGSize(width: 364, height: 382)
    /// Pixels per point.
    static let pictureScale: CGFloat = 3
    /// Metres on the ground per point: Home's own zoom (`b4-new-map`: "Home in miniature").
    static let metresPerPoint = 1.1

    /// Reloads the map widget's timeline — only while the phone is unlocked: the picture is written with
    /// complete file protection, so a reload while locked would find it unreadable and draw no map, and
    /// iOS keeps the last render meanwhile.
    static func reload() {
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
}

/// Coordinated write, read and delete of the map widget's picture in the app group.
///
/// **Never in a backup:** every write sets `isExcludedFromBackup` on the file it just wrote (an atomic
/// write replaces the file and drops the flag), and a file the flag could not be set on is deleted rather
/// than left to reach a backup. **Locked away:** written with complete file protection, so neither the
/// widget nor anything else can read it while the phone is locked. The wipes, a decoy and "Delete map
/// history" delete it (`WorldFogKeeper`). Directory injectable for tests.
struct WorldWidgetMapFile {
    /// Where the picture lives.
    let fileURL: URL

    /// The picture's file in `directory`, or in the app group's widget folder (nil, as the app runs).
    init(directory: URL? = nil) {
        fileURL = (directory ?? WidgetBridgeFiles.containerDirectory()).appendingPathComponent(WorldWidgetMap.fileName)
    }

    /// Whether a picture file is there.
    var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    /// Writes `picture` atomically with complete file protection, kept out of backups. Whether it landed.
    func write(_ picture: WorldWidgetMapPicture) -> Bool {
        guard picture.version == WorldWidgetMapPicture.currentVersion, !picture.light.isEmpty, !picture.dark.isEmpty,
              picture.light.count + picture.dark.count <= WorldWidgetMap.maxBytes else { return false }
        let data: Data
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            data = try encoder.encode(picture)
        } catch {
            FernletAuditLog.log("widgetMap.encodeFailed")
            return false
        }
        var written = false
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinatorError) { url in
            written = Self.writeExcluded(data, to: url)
        }
        return written && coordinatorError == nil
    }

    /// The picture on disk, or nil when there is none or it can't be read now.
    func read() -> WorldWidgetMapPicture? {
        var picture: WorldWidgetMapPicture?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: .withoutChanges, error: &coordinatorError) { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= WorldWidgetMap.maxBytes + 4_096 else { return }
                picture = try PropertyListDecoder().decode(WorldWidgetMapPicture.self, from: data)
            } catch {
                FernletAuditLog.log("widgetMap.readFailed")
            }
        }
        return coordinatorError == nil ? picture : nil
    }

    /// Deletes the picture. Whether it is gone (a missing file counts).
    func delete() -> Bool {
        var removed = false
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forDeleting, error: &coordinatorError) { url in
            removed = Self.remove(url)
        }
        return removed && coordinatorError == nil
    }

    /// Writes `data` to `url` with complete protection, then keeps it out of backups; a file the flag can't
    /// be set on is removed again. Whether a backup-excluded file is there.
    private static func writeExcluded(_ data: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            FernletAuditLog.log("widgetMap.writeFailed", context: ["errorType": "\(type(of: error))"])
            return false
        }
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var target = url
            try target.setResourceValues(values)
            return true
        } catch {
            // Never leave a copy that could reach a backup: take it away again.
            FernletAuditLog.log("widgetMap.backupFlagFailed", context: ["removed": remove(url) ? "yes" : "no"])
            return false
        }
    }

    /// Removes the file at `url`; whether it is gone.
    private static func remove(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            FernletAuditLog.log("widgetMap.deleteFailed")
            return false
        }
    }
}
