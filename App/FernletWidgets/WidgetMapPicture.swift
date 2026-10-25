// WidgetMapPicture.swift
// FernletWidgets
//
// The map widget's picture (owner's Q36, `b4-new-map`, round 6b), as the app hands it over in the app
// group: the map around the person with their marked places and saved trails already drawn on it, light
// and dark, and when it was taken. The app writes it with complete file protection, never in a backup,
// and deletes it with the map history and when a decoy opens (World/Widget/WorldWidgetMapFile.swift).

import Foundation
import os

/// Subsystem log for the map widget's picture: an unreadable or undecodable file is named, not swallowed.
private let widgetMapLog = Logger(subsystem: "com.fernlet", category: "widget-map")

/// The map widget's picture: byte-format twin of the app's `WorldWidgetMapPicture` (the property-list
/// keys are the contract; `WidgetMapTests` pins them). No coordinate rides in it — only a picture.
struct WidgetMapPicture: Codable, Equatable {
    /// The only format this build reads.
    static let currentVersion = 1

    /// The format version.
    var version: Int
    /// When the picture was taken ("Map from 9:40").
    var takenAt: Date
    /// The light picture, PNG.
    var light: Data
    /// The dark picture, PNG.
    var dark: Data
}

/// What reading the map widget's picture found.
enum WidgetMapPictureRead: Equatable {
    /// A picture to draw.
    case picture(WidgetMapPicture)
    /// None: the map was never drawn for the widget, a decoy is open, or the map history was deleted.
    case none
    /// One is there but can't be read now: the phone is locked (complete file protection).
    case locked
}

/// Widget-side reader of the map widget's picture (`WidgetMap.plist` in the app group's widget folder).
///
/// The picture opens only while the phone is unlocked, so a file that is there but won't open reads as
/// ``WidgetMapPictureRead/locked``, never as none. A file too large or of another format reads as none.
/// Directory injectable, as the snapshot store's.
struct WidgetMapPictureStore {
    /// The picture's file name (the app's `WorldWidgetMap.fileName`).
    static let fileName = "WidgetMap.plist"
    /// The largest file read (the app writes about 2 MB, and never more than 8 MB of pictures).
    static let maxBytes = 8 * 1_024 * 1_024 + 4_096

    private let fileURL: URL

    init(fileManager: FileManager = .default, directory: URL? = nil) {
        fileURL = (directory ?? WidgetBridgeFiles.containerDirectory(fileManager: fileManager))
            .appendingPathComponent(Self.fileName)
    }

    /// The picture, none, or locked away.
    func read() -> WidgetMapPictureRead {
        var result = WidgetMapPictureRead.none
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: .withoutChanges, error: &coordinatorError) { url in
            result = Self.decode(at: url)
        }
        guard coordinatorError == nil else {
            widgetMapLog.error("map picture coordination failed")
            return .locked
        }
        return result
    }

    /// Whether the map widget may reload now: there is no picture, or it opens. A picture locked away
    /// with the phone is left as last drawn rather than reloaded without its map.
    var mayReload: Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            try handle.close()
            return true
        } catch {
            return false
        }
    }

    /// Opens and decodes the file at `url`.
    private static func decode(at url: URL) -> WidgetMapPictureRead {
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .locked
        }
        guard data.count <= maxBytes else { return .none }
        do {
            let picture = try PropertyListDecoder().decode(WidgetMapPicture.self, from: data)
            return picture.version == WidgetMapPicture.currentVersion ? .picture(picture) : .none
        } catch {
            widgetMapLog.error("map picture undecodable")
            return .none
        }
    }
}
