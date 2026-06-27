// swift-tools-version: 6.2
import PackageDescription

// FernletKit — the local Swift package for the SPM module carve-up (plan §6).
// Phase 1 stands this up empty with a single Layer-0 `FernletFoundation` target;
// later phases add the rest of the layered DAG that forms the S3 privacy wall.
//
// `defaultIsolation(MainActor.self)` is set per target up front: MainActor
// isolation is NOT inherited from the app target's SWIFT_DEFAULT_ACTOR_ISOLATION
// build setting, so SPM targets must opt in explicitly (plan §7).
let package = Package(
    name: "FernletKit",
    platforms: [
        .iOS(.v26),
    ],
    products: [
        // Single umbrella product: the app and test targets link this ONE product
        // and can then `import` ANY target listed here. Each later module is added
        // to this `targets:` list (and gets its own `.target` below) with NO further
        // Xcode project surgery — the pbxproj references this product by name only.
        .library(name: "FernletKit", targets: ["FernletFoundation"]),
    ],
    targets: [
        .target(
            name: "FernletFoundation",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
    ]
)
