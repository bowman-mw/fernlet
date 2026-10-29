import Foundation
import CoreGraphics
import CryptoKit
import JavaScriptCore
import Testing
import FernletDomainModel
@testable import Fernlet

/// The approved exercise animations' catalog (package revision r12, approved by the owner on
/// 2026-10-29).
///
/// Pinned here: every bundled catalog exercise has exactly one animation, keyed by its normalized
/// name, and a custom name has none; the 199 IDs are `exercise-001` through `exercise-199`; the
/// committed rows carry the app catalog's exact names and equipment and the bundled engine's own
/// loop lengths and holds; the character follows the profile's Sex; both stills of every exercise
/// are in the built app at 640 × 480; and every approved file in the repository and in the built app
/// is byte-identical to the package manifest.
struct ExerciseAnimationCatalogTests {

    static let catalogPath = "App/Fernlet/ExerciseAnimationCatalog.json"
    static let enginePath = "App/Fernlet/ExerciseAnimations.bundle"
    static let stillsPath = "App/Fernlet/ExerciseAnimationStills.bundle"
    static let manifestPath = "Tests/ExerciseAnimationReference/manifest.json"
    static let expectedIDs = (1...199).map { String(format: "exercise-%03d", $0) }

    /// The committed rows, decoded the way the app decodes them.
    static func committedRows() throws -> [ExerciseAnimationCatalogRow] {
        try ExerciseAnimationCatalog.decodeRows(Data(contentsOf: RepoRoot.url(catalogPath)))
    }

    /// The app catalog's rows, read from the repository.
    static func appCatalogRows() throws -> [ExerciseTarget] {
        let data = try Data(contentsOf: RepoRoot.url("App/Fernlet/WorkoutExercises.json"))
        return try JSONDecoder().decode([ExerciseTarget].self, from: data)
    }

    /// The package manifest's `files` map: packaged path to SHA-256 hex.
    static func manifestHashes() throws -> [String: String] {
        let data = try Data(contentsOf: RepoRoot.url(manifestPath))
        return try JSONDecoder().decode(ManifestFiles.self, from: data).files
    }

    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Lookup

    @Test func everyBundledExerciseHasAnAnimation() throws {
        let bundled = WorkoutExerciseCatalog.baseExercises
        #expect(bundled.count == 199, "the hosted app's catalog has \(bundled.count) exercises")
        #expect(ExerciseAnimationCatalog.entries.count == 199)
        var ids = Set<String>()
        for exercise in bundled {
            let entry = ExerciseAnimationCatalog.entry(forExerciseName: exercise.name)
            #expect(entry != nil, "\(exercise.name) has no animation")
            if let entry { ids.insert(entry.id) }
        }
        #expect(ids == Set(Self.expectedIDs), "the bundled exercises do not map one-to-one onto the 199 IDs")
    }

    @Test func lookupIgnoresCaseAndSpacingLikeTheCatalog() throws {
        let bench = try #require(ExerciseAnimationCatalog.entry(forExerciseName: "Bench press"))
        #expect(bench.id == "exercise-001")
        #expect(ExerciseAnimationCatalog.entry(forExerciseName: "  bench   PRESS \n") == bench)
    }

    @Test func aCustomOrUnknownNameHasNoAnimation() {
        for name in ["My garage sled push", "", "   ", "Bench press 2", "exercise-001"] {
            #expect(ExerciseAnimationCatalog.entry(forExerciseName: name) == nil, "\(name) matched an animation")
        }
    }

    @Test func theCharacterFollowsTheProfilesSex() {
        #expect(ExerciseAnimationCharacter(sex: .female) == .female)
        #expect(ExerciseAnimationCharacter(sex: .male) == .male)
        for sex in BiologicalSex.allCases where sex != .female {
            #expect(ExerciseAnimationCharacter(sex: sex) == .male)
        }
    }

    // MARK: - The committed rows

    @Test func theIDsAreTheNumbered199() throws {
        let ids = try Self.committedRows().map(\.id)
        #expect(ids == Self.expectedIDs)
        #expect(Set(ids).count == 199)
    }

    @Test func rowsCarryTheAppCatalogsExactNamesAndEquipment() throws {
        let rows = try Self.committedRows()
        let catalog = try Self.appCatalogRows()
        #expect(rows.count == catalog.count)
        let byName = Dictionary(catalog.map { (WorkoutExerciseCatalog.normalizedName($0.name), $0) },
                                uniquingKeysWith: { first, _ in first })
        for row in rows {
            let exercise = byName[WorkoutExerciseCatalog.normalizedName(row.name)]
            #expect(exercise?.name == row.name, "\(row.id) is named \(row.name), the catalog spells it otherwise")
            #expect(exercise?.equipment.rawValue == row.equipment, "\(row.id) \(row.name) equipment differs")
        }
        #expect(Set(rows.map { WorkoutExerciseCatalog.normalizedName($0.name) }).count == rows.count)
    }

    @Test func rowsAgreeWithTheBundledMovementsScript() throws {
        let movements = try Self.bundledMovements()
        let rows = try Self.committedRows()
        #expect(movements.map(\.id) == rows.map(\.id))
        for (movement, row) in zip(movements, rows) {
            #expect(movement.duration == row.duration, "\(row.id) loop length differs from movements.js")
            #expect(movement.hold == row.hold, "\(row.id) hold differs from movements.js")
            #expect(row.stillProgress == (row.hold ? 0 : 0.5), "\(row.id) still progress")
        }
        #expect(rows.filter(\.hold).count == 22)
    }

    /// `movements.js` evaluated as the renderer evaluates it, read back through its `movements` global.
    static func bundledMovements() throws -> [BundledMovement] {
        let script = try RepoRoot.source("\(enginePath)/movements.js")
        let context = try #require(JSContext() as JSContext?)
        context.evaluateScript(script)
        #expect(context.exception == nil, "movements.js threw: \(String(describing: context.exception))")
        let json = try #require(context.evaluateScript("JSON.stringify(movements)")?.toString())
        return try JSONDecoder().decode([BundledMovement].self, from: Data(json.utf8))
    }

    // MARK: - Stills

    @Test func everyAnimationHasBothStillsInTheBuiltAppAt640By480() throws {
        let rows = try Self.committedRows()
        for row in rows {
            for character in ExerciseAnimationCharacter.allCases {
                let still = ExerciseAnimationCatalog.still(for: row.entry, character: character)
                #expect(still?.width == 640 && still?.height == 480, "\(character) \(row.id) still is missing or not 640 × 480")
            }
        }
    }

    @Test func theStillsBundleKeepsOneFolderPerCharacterInTheBuiltApp() throws {
        let entry = try #require(ExerciseAnimationCatalog.entry(forExerciseName: "Bench press"))
        let url = try #require(ExerciseAnimationCatalog.stillURL(for: entry, character: .female))
        #expect(url.path.hasSuffix("Fernlet.app/ExerciseAnimationStills.bundle/female/exercise-001.png"))
        #expect(ExerciseAnimationCatalog.stillPath(for: entry, character: .male) == "male/exercise-001.png")
        let root = try #require(Bundle.main.resourceURL)
        let flattened = root.appendingPathComponent("exercise-001.png")
        #expect(!FileManager.default.fileExists(atPath: flattened.path), "a still was flattened into the app root")
    }

    // MARK: - Byte identity with the approved package

    @Test func theApprovedFilesInTheRepositoryMatchTheManifest() throws {
        let manifest = try Self.manifestHashes()
        let files = Self.approvedFiles()
        #expect(files.count == 3 + 398)
        for (packaged, repoPath) in files {
            let expected = try #require(manifest[packaged], "the manifest does not list \(packaged)")
            #expect(try Self.sha256(RepoRoot.url(repoPath)) == expected, "\(repoPath) differs from the approved \(packaged)")
        }
    }

    @Test func theBuiltAppCarriesTheApprovedFilesByteForByte() throws {
        let manifest = try Self.manifestHashes()
        let root = try #require(Bundle.main.resourceURL)
        var checked = 0
        for (packaged, repoPath) in Self.approvedFiles() where repoPath.hasPrefix("App/Fernlet/") {
            let inApp = root.appendingPathComponent(String(repoPath.dropFirst("App/Fernlet/".count)))
            #expect(try Self.sha256(inApp) == manifest[packaged], "the built app's \(inApp.lastPathComponent) differs from \(packaged)")
            checked += 1
        }
        #expect(checked == 2 + 398)
    }

    @Test func noExcludedPackageMaterialIsInTheRepositoryCopies() throws {
        let allowed: Set<String> = ["motion-engine.js", "movements.js"]
        let engine = try FileManager.default.contentsOfDirectory(atPath: RepoRoot.url(Self.enginePath).path)
        #expect(Set(engine) == allowed)
        for character in ExerciseAnimationCharacter.allCases {
            let folder = RepoRoot.url("\(Self.stillsPath)/\(character.rawValue)").path
            let names = try FileManager.default.contentsOfDirectory(atPath: folder)
            #expect(Set(names) == Set(Self.expectedIDs.map { "\($0).png" }))
        }
        let stillsRoot = try FileManager.default.contentsOfDirectory(atPath: RepoRoot.url(Self.stillsPath).path)
        #expect(Set(stillsRoot) == ["male", "female"])
    }

    /// Every approved file the repository carries: (manifest key, repository path).
    static func approvedFiles() -> [(String, String)] {
        var files = [
            ("Resources/FernletAnimations/motion-engine.js", "\(enginePath)/motion-engine.js"),
            ("Resources/FernletAnimations/movements.js", "\(enginePath)/movements.js"),
            ("Resources/FernletAnimations/renderer.js", "Tests/ExerciseAnimationReference/renderer.js"),
        ]
        for character in ExerciseAnimationCharacter.allCases {
            for id in expectedIDs {
                files.append(("Stills/\(character.rawValue)/\(id).png", "\(stillsPath)/\(character.rawValue)/\(id).png"))
            }
        }
        return files
    }

    // MARK: - Decoding

    @Test func anUnreadableCatalogThrowsAndARepeatedNameKeepsItsFirstRow() throws {
        #expect(throws: (any Error).self) { try ExerciseAnimationCatalog.decodeRows(Data("{".utf8)) }
        let first = ExerciseAnimationCatalogRow(name: "Squat", equipment: "barbell", id: "exercise-010",
                                                duration: 4, hold: false, stillProgress: 0.5)
        let second = ExerciseAnimationCatalogRow(name: " squat ", equipment: "barbell", id: "exercise-011",
                                                 duration: 4, hold: false, stillProgress: 0.5)
        #expect(ExerciseAnimationCatalog.keyed([first, second]) == ["squat": first.entry])
    }

    /// The fields of one `movements.js` record the catalog must agree with.
    struct BundledMovement: Decodable {
        let id: String
        let duration: Double
        let hold: Bool
    }

    /// The package manifest's file-hash map (its other fields are not read).
    struct ManifestFiles: Decodable {
        let files: [String: String]
    }
}
