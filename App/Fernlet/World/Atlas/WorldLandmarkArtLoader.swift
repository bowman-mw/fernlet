import FernletFoundation
import Foundation
import WorldMapStore

/// Opens the bundled landmark art (`WorldLandmarkArt.json`, the design session's approved sprites; World-Exploration-
/// Spec §2) for the map's screens. A missing or refused file is logged and answers nil, so the map draws no
/// landmark art rather than wrong art; the landmarks themselves still count.
enum WorldLandmarkArtLoader {
    /// The bundled file's resource name (a frozen file name).
    static let resource = "WorldLandmarkArt"
    /// The bundled file's extension.
    static let fileExtension = "json"

    /// The art bundled in `bundle`, or nil (logged).
    static func bundled(in bundle: Bundle = .main) -> WorldLandmarkArt? {
        guard let url = bundle.url(forResource: resource, withExtension: fileExtension) else {
            FernletAuditLog.log("worldMap.landmarkArt.fileMissing")
            return nil
        }
        do {
            return try WorldLandmarkArt(data: Data(contentsOf: url))
        } catch {
            FernletAuditLog.log("worldMap.landmarkArt.fileUnreadable")
            return nil
        }
    }
}
