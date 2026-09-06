// RoutedShareRefusalCopyTests.swift
// FernletTests
//
// The P5 review's finding 5: a refused routed share used to reach the user as a `String` composed
// inside ProximityKit, which renders English in every language. The manager now publishes the
// frozen cause on `routedShareRefusal`, and the app forks it into `LocalizedStringKey` copy.

import Foundation
import SwiftUI
import Testing
import ProximityKit
@testable import Fernlet

/// The app-side copy the share refusal resolves to: localized by construction, one sentence per
/// frozen cause, and the seam it replaced closed by a wall.
@MainActor
@Suite struct RoutedShareRefusalCopyTests {

    /// Every cause has a sentence, the causes a user can act on differently read differently, the
    /// title shares the session alert's existing catalog row, and the tokens are frozen.
    @Test func everyCauseHasLocalizedCopy() {
        // R2: bounded by the enum's cases.
        for refusal in MeshRoutedShareRefusal.allCases {
            let message: LocalizedStringKey = RoutedShareRefusalCopy.message(refusal)
            #expect(message != RoutedShareRefusalCopy.title, "a sentence, not the title")
        }
        #expect(RoutedShareRefusalCopy.message(.destinationNotAddressable)
                != RoutedShareRefusalCopy.message(.sealFailed),
                "not reaching everyone is a different fact from a failed seal")
        #expect(RoutedShareRefusalCopy.message(.storeRefused)
                != RoutedShareRefusalCopy.message(.sealFailed),
                "a full store is a different fact from a failed seal")
        #expect(RoutedShareRefusalCopy.message(.storeUnavailable)
                != RoutedShareRefusalCopy.message(.storeRefused),
                "unavailable storage is a different fact from full storage")
        let title: LocalizedStringKey = RoutedShareRefusalCopy.title
        #expect(title == "Session")
        #expect(MeshRoutedShareRefusal.allCases.map(\.rawValue)
                == ["sealFailed", "destinationNotAddressable", "mintFailed", "storeRefused", "storeUnavailable"],
                "audit vocabulary; a rename breaks every reader of mesh.routedShare.refused")
    }

    /// The package composes no sentence and the camera presents the typed cause.
    @Test func theRefusalLeavesThePackageAsATokenOnly() throws {
        let manager = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift")
        )
        #expect(!manager.contains("Couldn't share that photo"),
                "the refusal sentence is composed in the app, never in the package")
        #expect(manager.contains("routedShareRefusal = refusal"),
                "the refusal is published as its frozen token")
        let camera = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/DisposableCameraView.swift")
        )
        #expect(camera.contains("RoutedShareRefusalCopy.message(refusal)"),
                "the camera's session alert forks the token into copy")
        #expect(camera.contains("manager.clearRoutedShareRefusal()"),
                "dismissing the alert clears the refusal, so the next one can show")
    }
}
