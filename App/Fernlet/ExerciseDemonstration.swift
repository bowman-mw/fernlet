//
//  ExerciseDemonstration.swift
//  Fernlet
//
//  Which demonstration the exercise how-to sheet shows (comparison report idea 8): a looping GIF, a
//  still illustration, a GIF's frozen first frame, or a placeholder tile. The media are licensed from
//  Gym Visual and are NEVER in the repository: the owner drops them into the gitignored
//  `App/Fernlet/ExerciseMedia/` folder, the synchronized app target copies whatever is there into the
//  bundle, and `ExerciseDemonstrations.json` (committed, Gym Visual IDs only) says which file belongs
//  to which exercise. Only files actually in the bundle count, so a build from a clean clone shows
//  placeholders everywhere.
//
//  The licence forbids AI use. Nothing on the AI path may read this file's types, the mapping or the
//  media folder; `ExerciseDemonstrationTests` scans every prompt builder and on-device model caller
//  and fails if one does.
//

import Foundation
import FernletDomainModel
import FernletFoundation

/// One catalog exercise's Gym Visual media IDs, as committed in `ExerciseDemonstrations.json`.
///
/// Each field is the ID Gym Visual sells the file under, or nil when it has no such version (13 of
/// the 118 exercises exist for one sex only). An ID names a file in the drop folder,
/// `<ID>.gif` for a GIF and `<ID>.png` or `<ID>.jpg` for an illustration; the ID alone is not media.
nonisolated struct ExerciseDemonstrationIDs: Codable, Equatable, Sendable {
    var gifMale: String?
    var gifFemale: String?
    var illustrationMale: String?
    var illustrationFemale: String?

    /// The GIF IDs, the given sex's first, then the other's; missing versions dropped.
    func gifIDs(preferring sex: BiologicalSex) -> [String] {
        switch sex {
        case .female: [gifFemale, gifMale].compactMap { $0 }
        case .male: [gifMale, gifFemale].compactMap { $0 }
        }
    }

    /// The illustration IDs, the given sex's first, then the other's; missing versions dropped.
    func illustrationIDs(preferring sex: BiologicalSex) -> [String] {
        switch sex {
        case .female: [illustrationFemale, illustrationMale].compactMap { $0 }
        case .male: [illustrationMale, illustrationFemale].compactMap { $0 }
        }
    }
}

/// What the how-to sheet's demonstration slot draws, by bundle file name.
nonisolated enum ExerciseDemonstration: Equatable, Sendable {
    /// An animated GIF, played in a loop.
    case animation(fileName: String)
    /// A GIF's first frame held still: Reduce Motion is on and no illustration is bundled.
    case firstFrame(fileName: String)
    /// A still illustration (PNG or JPEG).
    case illustration(fileName: String)
    /// Nothing licensed is bundled for this exercise: the calm equipment tile.
    case placeholder

    /// The bundle file this demonstration draws, or nil for the placeholder.
    var fileName: String? {
        switch self {
        case .animation(let name), .firstFrame(let name), .illustration(let name): name
        case .placeholder: nil
        }
    }

    /// Whether the file plays as an animation rather than drawing one still image.
    var animates: Bool {
        if case .animation = self { return true }
        return false
    }
}

/// Picks an exercise's demonstration from its IDs, the profile's sex, Reduce Motion and the files
/// actually bundled. Pure: every input is a parameter, so the order is testable without media.
///
/// Without Reduce Motion: the preferred sex's GIF, the other sex's GIF, an illustration (preferred
/// sex first), then the placeholder. With Reduce Motion: an illustration (preferred sex first), a
/// GIF's first frame held still (preferred sex first), then the placeholder.
nonisolated enum ExerciseDemonstrationResolver {
    /// The animated GIF extension.
    static let gifExtension = "gif"
    /// The still illustration extensions, in the order a file is looked for.
    static let illustrationExtensions = ["png", "jpg"]
    /// Every extension the drop folder takes.
    static let mediaExtensions = [gifExtension] + illustrationExtensions
    /// Longest Gym Visual ID accepted (the mapping's longest is 7 digits).
    static let maxIDLength = 10

    static func resolve(
        _ ids: ExerciseDemonstrationIDs?,
        sex: BiologicalSex,
        reduceMotion: Bool,
        bundled: Set<String>
    ) -> ExerciseDemonstration {
        guard let ids, !bundled.isEmpty else { return .placeholder }
        let gif = firstBundled(ids.gifIDs(preferring: sex), extensions: [gifExtension], in: bundled)
        let still = firstBundled(ids.illustrationIDs(preferring: sex), extensions: illustrationExtensions, in: bundled)
        if reduceMotion {
            if let still { return .illustration(fileName: still) }
            if let gif { return .firstFrame(fileName: gif) }
            return .placeholder
        }
        if let gif { return .animation(fileName: gif) }
        if let still { return .illustration(fileName: still) }
        return .placeholder
    }

    /// The first `<id>.<extension>` in `bundled`, trying the IDs in order and, for each, the
    /// extensions in order. IDs that are not Gym Visual IDs are skipped, so a malformed mapping
    /// entry can never name a path.
    static func firstBundled(_ ids: [String], extensions: [String], in bundled: Set<String>) -> String? {
        guard !ids.isEmpty, !extensions.isEmpty else { return nil }
        // Bounded: at most two IDs (one per sex) times the media extensions.
        for id in ids where isGymVisualID(id) {
            for fileExtension in extensions where bundled.contains("\(id).\(fileExtension)") {
                return "\(id).\(fileExtension)"
            }
        }
        return nil
    }

    /// Whether `id` looks like a Gym Visual ID: ASCII digits only, 1 to ``maxIDLength`` of them.
    static func isGymVisualID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= maxIDLength else { return false }
        return id.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Whether `fileName` follows the drop folder's naming scheme, `<GymVisualID>.gif|png|jpg`.
    static func isMediaFileName(_ fileName: String) -> Bool {
        let parts = fileName.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return isGymVisualID(String(parts[0])) && mediaExtensions.contains(String(parts[1]))
    }
}

/// The app's demonstration library: the committed mapping and the media files this build carries.
///
/// Both are read from `Bundle.main` once. An absent mapping is legitimate where the hosting bundle
/// is not the app; a present but unreadable one is logged and treated as empty, so every exercise
/// shows its placeholder rather than the sheet failing.
nonisolated enum ExerciseDemonstrationLibrary {
    /// The mapping's bundle resource name (`ExerciseDemonstrations.json`).
    static let mappingResource = "ExerciseDemonstrations"

    /// Gym Visual IDs keyed by the FROZEN catalog exercise name.
    static let mapping: [String: ExerciseDemonstrationIDs] = loadMapping()

    /// The drop-folder media this build carries, by file name (`002513.gif`). Empty in a build from
    /// a clean clone.
    static let bundledFiles: Set<String> = scanBundledMedia()

    /// The demonstration to draw for `exerciseName` (the frozen catalog name).
    static func demonstration(for exerciseName: String, sex: BiologicalSex, reduceMotion: Bool) -> ExerciseDemonstration {
        ExerciseDemonstrationResolver.resolve(
            mapping[exerciseName], sex: sex, reduceMotion: reduceMotion, bundled: bundledFiles)
    }

    /// The bundle URL of a demonstration file, or nil when this build does not carry it.
    static func url(for fileName: String) -> URL? {
        guard bundledFiles.contains(fileName) else { return nil }
        return Bundle.main.url(forResource: fileName, withExtension: nil)
    }

    /// Decodes the mapping's JSON. Shared with the tests, which decode the committed file.
    static func decodeMapping(_ data: Data) throws -> [String: ExerciseDemonstrationIDs] {
        try JSONDecoder().decode([String: ExerciseDemonstrationIDs].self, from: data)
    }

    private static func loadMapping() -> [String: ExerciseDemonstrationIDs] {
        guard let url = Bundle.main.url(forResource: mappingResource, withExtension: "json") else {
            return [:]
        }
        do {
            return try decodeMapping(Data(contentsOf: url))
        } catch {
            FernletAuditLog.log("exercise.demonstrations.load.failed",
                                context: ["error": error.localizedDescription])
            return [:]
        }
    }

    /// Every bundle-root file whose name follows the drop folder's scheme. The synchronized app
    /// target copies the drop folder's files flat into the bundle root.
    private static func scanBundledMedia() -> Set<String> {
        var names = Set<String>()
        // Bounded: three extensions, each over the bundle's finite resource list.
        for fileExtension in ExerciseDemonstrationResolver.mediaExtensions {
            let paths = Bundle.main.paths(forResourcesOfType: fileExtension, inDirectory: nil)
            for path in paths {
                let name = URL(fileURLWithPath: path).lastPathComponent
                guard ExerciseDemonstrationResolver.isMediaFileName(name) else { continue }
                names.insert(name)
            }
        }
        return names
    }
}
