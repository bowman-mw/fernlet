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
        #expect(RoutedShareRefusalCopy.message(.keyMismatch)
                != RoutedShareRefusalCopy.message(.destinationNotAddressable),
                "not everyone being here yet is a different fact from sources that disagree")
        #expect(MeshRoutedShareRefusal.allCases.map(\.rawValue)
                == ["sealFailed", "destinationNotAddressable", "mintFailed", "storeRefused",
                    "storeUnavailable", "keyMismatch"],
                "audit vocabulary; a rename breaks every reader of mesh.routedShare.refused")
    }

    /// The CHAT fork's own sweep (P6 item 4). `everyCauseHasLocalizedCopy` calls
    /// `RoutedShareRefusalCopy.message` **by name**, so nothing about it generalises to a second
    /// fork: without this loop the chat sentences would have zero coverage and a new
    /// `MeshRoutedShareRefusal` case would be a build error in one fork and silent in the other.
    ///
    /// It also pins the two outcomes that deliberately say NOTHING — `.staged`, because the row
    /// appearing in the transcript is the feedback, and `.empty`, because the send control is
    /// already disabled for it — because "no notice" is the kind of behaviour a refactor removes by
    /// accident in the other direction.
    @Test func everyChatSendOutcomeHasItsOwnCopy() {
        // R2: bounded by the enum's cases.
        for refusal in MeshRoutedShareRefusal.allCases {
            let message: LocalizedStringKey = RoutedShareRefusalCopy.chatMessage(refusal)
            #expect(message != RoutedShareRefusalCopy.title, "a sentence, not the title")
            #expect(message != RoutedShareRefusalCopy.message(refusal),
                    "and NOT the photo sentence, every one of which says the photo stayed on the user's own wall")
            #expect(RoutedShareRefusalCopy.chatNotice(.refused(refusal)) == message,
                    "the notice for a refusal IS the refusal's own sentence")
        }
        #expect(RoutedShareRefusalCopy.chatMessage(.destinationNotAddressable)
                != RoutedShareRefusalCopy.chatMessage(.sealFailed),
                "not reaching everyone is a different fact from a failed seal")
        #expect(RoutedShareRefusalCopy.chatMessage(.storeUnavailable)
                != RoutedShareRefusalCopy.chatMessage(.storeRefused),
                "unavailable storage is a different fact from full storage")
        #expect(RoutedShareRefusalCopy.chatNotice(.staged) == nil,
                "a staged send says nothing — the row in the transcript is the feedback")
        #expect(RoutedShareRefusalCopy.chatNotice(.empty) == nil,
                "and an empty draft says nothing — the send control is already disabled")
        let noRecipients = RoutedShareRefusalCopy.chatNotice(.noDestinations)
        #expect(noRecipients != nil,
                "but `.noDestinations` MUST speak for text: destinations are frozen at the mint and there is no offline queue")
        #expect(RoutedShareRefusalCopy.chatNotice(.ageGated) != nil)
        #expect(RoutedShareRefusalCopy.chatNotice(.ageGated) != noRecipients)
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
        // P6 item 4: chat neither shares that copy nor that surface. The panel is a sheet OVER the
        // camera, so publishing a chat refusal on `routedShareRefusal` would fire an alert on a
        // covered presenter — one of the two presentations is dropped.
        let panel = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/SessionChatPanel.swift")
        )
        #expect(panel.contains("RoutedShareRefusalCopy.chatNotice(outcome)"),
                "the chat panel forks the RETURNED outcome into copy")
        #expect(!panel.contains("routedShareRefusal"),
                "and never reads the photo path's observable, whose alert lives on the covered view")
    }
}
