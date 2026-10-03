// PeerNameDisplayTests.swift
// FernletTests
//
// Owner request 2026-09-29: "When connecting over the mesh, there is a large string of characters.
// This shouldn't be shown." The connect path had three identifiers in a row: the QUIC transport's
// random Bonjour instance name before the handshake, the 16-hex fingerprint as the row title before
// commit (Option 1b's withheld name), and that fingerprint again in display type on the "Connected"
// celebration. Every in-person surface now names a peer through `PeerNameDisplay`, which answers
// the person's chosen name or a plain placeholder. This suite pins the helper's rules, and a
// source ratchet pins that the connect-path files render no identifier.

import Foundation
import Testing
import FernletConnections
import FernletDomainModel
@testable import ProximityKit
@testable import Fernlet

/// The display-name rule for peers, and the connect path's no-identifier ratchet.
@Suite struct PeerNameDisplayTests {

    /// A real fingerprint, built the way the identity layer builds one.
    private static func realFingerprint() -> String {
        IdentityService.fingerprint(of: Data("peer-name-display-\(UUID().uuidString)".utf8))
    }

    /// A chosen name is shown, sanitized the way every peer-supplied name is.
    @Test func aChosenNameIsShownSanitized() {
        #expect(PeerNameDisplay.personName("Alex", fingerprint: Self.realFingerprint()) == "Alex")
        #expect(PeerNameDisplay.shown("Ali\u{200B}ce", fingerprint: nil) == "Alice",
                "a zero-width scalar hides nothing: the name comes out as a person reads it")
        #expect(PeerNameDisplay.shown("  Sam\n Lee ", fingerprint: nil) == "Sam Lee",
                "whitespace collapses rather than gluing words together")
    }

    /// Option 1b's withheld name (empty until the peer commits) reads as the placeholder.
    @Test func aWithheldNameShowsThePlaceholder() {
        #expect(PeerNameDisplay.personName("", fingerprint: Self.realFingerprint()) == nil)
        #expect(PeerNameDisplay.shown("", fingerprint: nil) == PeerNameDisplay.text(for: .nearby),
                "the default placeholder is the connect path's")
        #expect(PeerNameDisplay.shown("\u{200B}\u{FEFF}", fingerprint: nil) == PeerNameDisplay.text(for: .nearby),
                "a name that sanitizes away to nothing is withheld too")
        #expect(PeerNameDisplay.shown("", fingerprint: nil, placeholder: .met) == PeerNameDisplay.text(for: .met))
    }

    /// A roster or trust-vault row that filed the fingerprint AS the name never shows it, in
    /// either case.
    @Test func aNameThatIsItsOwnFingerprintIsNeverShown() {
        let fingerprint = Self.realFingerprint()
        #expect(PeerNameDisplay.personName(fingerprint, fingerprint: fingerprint) == nil)
        #expect(PeerNameDisplay.personName(fingerprint.uppercased(), fingerprint: fingerprint) == nil,
                "case does not make a fingerprint a name")
        #expect(PeerNameDisplay.shown(fingerprint, fingerprint: fingerprint, placeholder: .met)
                == PeerNameDisplay.text(for: .met))
    }

    /// A surface with no fingerprint to hand still refuses the canonical shape: 16 hex characters.
    @Test func aBareFingerprintShapeIsNeverShown() {
        #expect(PeerNameDisplay.personName("3f2a9c81b4de4a61", fingerprint: nil) == nil)
        #expect(PeerNameDisplay.personName("3F2A9C81B4DE4A61", fingerprint: nil) == nil)
        #expect(PeerNameDisplay.personName(Self.realFingerprint(), fingerprint: nil) == nil,
                "whatever fingerprint the identity layer produces has the refused shape")
    }

    /// The QUIC transport's random instance name, whole or in the participant projection's
    /// 24-character moderated form, is never a name. The prefix is the host namespace's, so the cell
    /// mints and judges under `.fernlet`'s, as the app's radios and surfaces do.
    @Test func theQUICInstanceNameIsNeverShown() {
        let namespace = ProximityNamespace.fernlet
        let prefix = namespace.family.radios.meshInstanceNamePrefix
        let instanceName = MeshLinkAdvertisement.randomInstanceName(prefix: prefix)
        #expect(instanceName.hasPrefix(prefix), "the fixture is the real transport name")
        #expect(PeerNameDisplay.personName(instanceName, fingerprint: nil, in: namespace) == nil)
        let projected = ItemNameModeration.moderatedPeerDisplayName(instanceName)
        #expect(projected.count == ItemNameModeration.maxNameLength,
                "the participant projection truncates it, which is the form a session row received")
        #expect(PeerNameDisplay.personName(projected, fingerprint: nil, in: namespace) == nil)
        #expect(PeerNameDisplay.shown(projected, fingerprint: nil, in: namespace) == PeerNameDisplay.text(for: .nearby))
    }

    /// The rules refuse identifiers, not hex letters: short or spaced hex-looking names are names.
    @Test func hexLookingHumanNamesSurvive() {
        let names = ["Ada", "Bea", "Dee Cafe", "deadbeef", "A friend", "Fernlet fan"]
        // R2: bounded by the literal list.
        for name in names {
            #expect(PeerNameDisplay.personName(name, fingerprint: Self.realFingerprint()) == name,
                    "\(name) is a name a person chose")
        }
    }

    /// Both placeholders are plain phrases that pass the rule they stand in for.
    @Test func bothPlaceholdersAreNamesNotIdentifiers() {
        let placeholders = [PeerNameDisplay.text(for: .nearby), PeerNameDisplay.text(for: .met)]
        #expect(placeholders[0] != placeholders[1], "the two situations read differently")
        // R2: bounded by the two placeholders.
        for placeholder in placeholders {
            #expect(!placeholder.isEmpty)
            #expect(PeerNameDisplay.personName(placeholder, fingerprint: nil) == placeholder)
        }
    }

    /// A first name for warm copy is the first word of a chosen name, or the WHOLE placeholder:
    /// the rule runs before the split, so a nameless friend never reads "Someone".
    @Test func aFirstNameIsAWordOfANameOrTheWholePlaceholder() {
        let fingerprint = Self.realFingerprint()
        #expect(PeerNameDisplay.firstName("Aisha Bloom", fingerprint: fingerprint) == "Aisha")
        #expect(PeerNameDisplay.firstName("  Sam\n Lee ", fingerprint: nil) == "Sam",
                "split after sanitizing, so a newline is a word break and not part of the name")
        #expect(PeerNameDisplay.firstName(fingerprint, fingerprint: fingerprint, placeholder: .met)
                == PeerNameDisplay.text(for: .met), "the placeholder whole, never its first word")
        #expect(PeerNameDisplay.firstName(fingerprint, fingerprint: nil, placeholder: .met)
                == PeerNameDisplay.text(for: .met), "the 16-hex shape without the fingerprint in hand")
        #expect(PeerNameDisplay.firstName("", fingerprint: nil) == PeerNameDisplay.text(for: .nearby))
        let instanceName = MeshLinkAdvertisement.randomInstanceName()
        #expect(PeerNameDisplay.firstName(instanceName, fingerprint: nil, placeholder: .met)
                == PeerNameDisplay.text(for: .met))
    }

    /// Every heart sentence built on `PresenceManager.firstName(of:)` (the presence refusals the
    /// package composes, Home's received-heart card) refuses an identifier, because it delegates.
    @Test func thePresenceFirstNameNeverAnswersAnIdentifier() {
        #expect(PresenceManager.firstName(of: "Aisha Bloom") == "Aisha")
        #expect(PresenceManager.firstName(of: Self.realFingerprint()) == PeerNameDisplay.text(for: .met),
                "a friend kept before their name arrived has the fingerprint filed as the name")
        #expect(PresenceManager.firstName(of: "  ") == PeerNameDisplay.text(for: .met),
                "and an empty name reads the localized placeholder, not the English-only \"your friend\"")
    }

    /// The mesh heart's status lines (session info sheet) never name a fingerprint filed as a
    /// friend's name: "Sent 3f2a9c81b4de4a61 some good vibes." was the fix review's C-F1.
    @Test func sessionHeartStatusLinesNeverNameAFingerprint() {
        let fingerprint = Self.realFingerprint()
        let placeholder = PeerNameDisplay.text(for: .met)
        #expect(SessionHeartStatusCopy.shownRecipient(fingerprint) == placeholder)
        #expect(SessionHeartStatusCopy.shownRecipient("Robin Jones") == "Robin Jones")
        // A key's `==` does not compare interpolated values (a `.value` format argument is never
        // equal, measured: two keys both carrying "Someone you met" compared unequal), so the pin
        // reads each key's description, after proving the description carries its arguments.
        let named = String(describing: SessionHeartStatusCopy.sent(recipientName: "Robin Jones"))
        #expect(named.contains("Robin Jones"), "precondition: a key's description shows its arguments")
        let leftNamed = String(describing: SessionHeartStatusCopy.message(.recipientLeft, recipientName: "Robin Jones"))
        #expect(leftNamed.contains("Robin") && !leftNamed.contains("Jones"),
                "precondition: a failure sentence carries the first name")
        let sent = String(describing: SessionHeartStatusCopy.sent(recipientName: fingerprint))
        #expect(!sent.localizedCaseInsensitiveContains(fingerprint), "the sent line names no fingerprint")
        #expect(sent.contains(placeholder), "it names the placeholder instead")
        // R2: bounded by the enum's cases.
        for cause in MeshNetworkManager.SessionHeartFailure.allCases {
            let line = String(describing: SessionHeartStatusCopy.message(cause, recipientName: fingerprint))
            #expect(!line.localizedCaseInsensitiveContains(fingerprint), "\(cause) names no fingerprint")
            #expect(!line.contains("\"Someone\""), "\(cause) keeps the placeholder whole")
        }
    }

    /// The presence fallback's status builders, one per surface, interpolate no raw recipient name.
    ///
    /// They are private computed properties on views, so the pin is on their bodies: each of
    /// connecting, verifying and sent names the recipient through `shownRecipient`, and `.failed`
    /// passes the manager's sentence, which `thePresenceFirstNameNeverAnswersAnIdentifier` covers.
    @Test func presenceHeartStatusBuildersNameNoRawRecipient() throws {
        let sites = [
            ("App/Fernlet/DisposableCameraView.swift", "private var presenceHeartStatusText: String? {"),
            ("App/Fernlet/FriendListView.swift", "private var heartStatusText: String? {")
        ]
        // R2: bounded by the literal site list.
        for (path, signature) in sites {
            let code = MeshRoutedSourceScan.codeOnly(try RepoRoot.source(path))
            let body = try #require(MeshRoutedSourceScan.bracedBody(after: signature, in: code),
                                    "\(path) still builds the presence status line")
            #expect(!body.contains("\\(name)") && !body.contains("\\(recipientName)"),
                    "\(path) interpolates a raw recipient name")
            #expect(body.components(separatedBy: "SessionHeartStatusCopy.shownRecipient(").count - 1 == 3,
                    "\(path): connecting, verifying and sent each name through the helper")
        }
    }

    /// The files a person moves through while connecting render no identifier.
    ///
    /// Tokens, not screenshots: each forbidden token is the way an identifier used to reach one of
    /// these screens. `displayNameOrFingerprint` stays the PERSIST value (rosters, the trust vault,
    /// audits), so it is legal in the Kit and forbidden here.
    @Test func theConnectPathRendersNoIdentifier() throws {
        let files = [
            "App/Fernlet/ConnectView.swift",
            "App/Fernlet/JoinPromptSheet.swift",
            "App/Fernlet/ActivitiesView.swift",
            "App/Fernlet/DisposableCameraView.swift",
            "App/Fernlet/VerifyQRViews.swift",
            "App/Fernlet/SessionChatPanel.swift",
            "App/Fernlet/Proximity/UI/ProximityRecipeShareSheet.swift",
            "FernletKit/Sources/FernletProximityUI/KeepFriendsPromptSheet.swift"
        ]
        let forbidden = ["FingerprintText(", "displayNameOrFingerprint", ".peer.displayHint",
                         "fingerprint.prefix(", "fingerprint.map {"]
        var scanned = 0
        // R2: bounded by the literal file list.
        for path in files {
            let code = MeshRoutedSourceScan.codeOnly(try RepoRoot.source(path))
            scanned += 1
            for token in forbidden {
                #expect(!code.contains(token), "\(path) renders an identifier through \(token)")
            }
        }
        #expect(scanned == files.count, "every connect-path file was read")
    }

    /// The one fingerprint left in the app is the friend detail card's collapsed "Safety code".
    @Test func theSafetyCodeIsTheOnlyFingerprintOnScreen() throws {
        let appRoot = RepoRoot.url("App/Fernlet")
        let enumerator = try #require(FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil))
        var rendering: [String] = []
        var scanned = 0
        // R2: bounded by the files under App/Fernlet.
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let code = MeshRoutedSourceScan.codeOnly(try String(contentsOf: url, encoding: .utf8))
            if code.contains("FingerprintText(") { rendering.append(url.lastPathComponent) }
        }
        #expect(scanned > 100, "the walk reached the app's sources")
        #expect(rendering == ["FriendListView.swift"], "only the friend detail card shows a fingerprint")
        let friendList = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/FriendListView.swift"))
        let safetyCode = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private func safetyCodeDisclosure(", in: friendList))
        #expect(safetyCode.contains("if isRevealed {") && safetyCode.contains("FingerprintText("),
                "and only once revealed, behind the collapsed toggle")
    }
}
