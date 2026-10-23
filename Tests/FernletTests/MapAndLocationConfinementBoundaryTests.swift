import Foundation
import Testing

/// The map and location confinement wall (World build, branch `world-ui`; World app plan step 1a).
///
/// The World Home is a live map, so two Apple frameworks that touch where someone is now ship in the
/// app. Each is held to an exact list of files:
/// - **MapKit** (and SwiftUI's `_MapKit_SwiftUI`) only in `AppleMutedBaseMap.swift`, the phase-1 base map
///   behind the map seam. Everything else draws from plain `GeoPoint`s and the `MapViewport` the base map
///   reports, which is what lets phase 2 swap in MapLibre, and what keeps Apple's map service to one
///   documented destination (`Docs/No-Tracking-Wall.md` §4a, "Apple Maps (MapKit)").
/// - **CoreLocation** (and `CoreLocationUI`, and `WeatherKit`, whose API carries `CLLocation`) only in
///   `WeatherKitService.swift`, where weather has always asked for a coarse fix. Step 5a of the plan adds
///   the World location source here, in the same commit as its file.
///
/// The watch build's planned MapKit route card (`WorkoutRouteMapView.swift`) and GPS recorder join these
/// lists when main is merged into `world-ui`. A stale entry (a listed file that no longer imports the
/// framework) fails too, so the lists can only describe the tree as it is.
struct MapAndLocationConfinementBoundaryTests {

    /// The five shipping Swift roots.
    static let shippingRoots = [
        "App/Fernlet", "App/FernletWidgets", "App/FernletShareExtension",
        "App/FernletMessagesExtension", "FernletKit/Sources",
    ]

    /// Modules that draw or query Apple's map.
    static let mapModules: Set<String> = ["MapKit", "_MapKit_SwiftUI"]
    /// Modules that read location (WeatherKit's API takes a `CLLocation`).
    static let locationModules: Set<String> = ["CoreLocation", "CoreLocationUI", "WeatherKit"]

    /// The only files that may import a map module.
    static let mapFiles: Set<String> = ["App/Fernlet/World/Map/AppleMutedBaseMap.swift"]
    /// The only files that may import a location module.
    static let locationFiles: Set<String> = ["FernletKit/Sources/AppServices/WeatherKitService.swift"]

    @Test func mapKitIsConfinedToTheAppleBaseMap() throws {
        let importers = try Self.files(importingAnyOf: Self.mapModules)
        #expect(importers == Self.mapFiles, "MapKit importers drifted: \(importers.sorted())")
    }

    @Test func locationIsConfinedToItsListedFiles() throws {
        let importers = try Self.files(importingAnyOf: Self.locationModules)
        #expect(importers == Self.locationFiles, "location importers drifted: \(importers.sorted())")
    }

    /// The matcher fires on a planted import of each kind, so the wall cannot pass by reading nothing.
    @Test func plantedImportsAreSeen() {
        let planted = "import SwiftUI\n@preconcurrency import MapKit\nimport CoreLocation\n"
        let modules = S3BoundaryTests.importedModules(in: planted)
        #expect(!modules.isDisjoint(with: Self.mapModules))
        #expect(!modules.isDisjoint(with: Self.locationModules))
    }

    // MARK: - Helpers

    /// Repo-relative paths of every shipping Swift file that imports one of `modules`. Fails when the
    /// walk reads too few files to be the real tree.
    static func files(importingAnyOf modules: Set<String>) throws -> Set<String> {
        var found: Set<String> = []
        var scanned = 0
        for relative in shippingRoots {
            let rootURL = RepoRoot.url.appendingPathComponent(relative)
            let base = rootURL.standardizedFileURL.path
            guard let walker = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
                Issue.record("cannot walk \(relative)")
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                scanned += 1
                let source = try String(contentsOf: url, encoding: .utf8)
                guard !S3BoundaryTests.importedModules(in: source).isDisjoint(with: modules) else { continue }
                found.insert(relative + String(url.standardizedFileURL.path.dropFirst(base.count)))
            }
        }
        #expect(scanned > 500, "scanned only \(scanned) shipping Swift files; a root moved")
        return found
    }
}
