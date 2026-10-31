import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// World Friends, the settings switch and Home's friend rules (`Docs/Handoff/World-Friends-Spec.md` §1.1,
/// §1.6, §2; screens `fr-tap-switch`, `fr-home-friend`, `fr-home-closed`, `fr-locoff`, `fr-tap-keep`,
/// approved 2026-10-31): "Connect by tapping phones" leads Privacy & Data and comes up on for existing
/// settings; a session is a hangout in every word; nobody new is offered on Home or Friends nearby; friends
/// in a closed hangout look exactly like friends each nearby; the location-off Home has no friends card;
/// and Keep as friends? can say "met by tapping phones".
@MainActor
struct WorldFriendsHomeTests {
    private static let appCatalog = "App/Fernlet/Localizable.xcstrings"
    private static let proximityUICatalog = "FernletKit/Sources/FernletProximityUI/Localizable.xcstrings"

    // MARK: The switch (fr-tap-switch, spec §1.6)

    /// On by default; a settings blob written before the switch decodes it on; off survives a round
    /// trip; the wire key is exactly `allowConnectByTapping` and is a known key, never parked.
    @Test func connectByTappingIsOnByDefaultAndForExistingSettings() throws {
        let defaults = FernletSettings()
        #expect(defaults.allowConnectByTapping, "on by default (spec §1.6)")
        var legacy = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as? [String: Any])
        #expect(legacy["allowConnectByTapping"] as? Bool == true, "the wire key is the English token allowConnectByTapping")
        legacy.removeValue(forKey: "allowConnectByTapping")
        let decoded = try JSONDecoder().decode(FernletSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.allowConnectByTapping, "saved settings from before the switch come up on")
        var off = defaults
        off.allowConnectByTapping = false
        let roundTripped = try JSONDecoder().decode(FernletSettings.self, from: JSONEncoder().encode(off))
        #expect(!roundTripped.allowConnectByTapping)
        #expect(roundTripped.parkedUnknownKeys["allowConnectByTapping"] == nil, "a key this build owns is never parked")
    }

    /// Privacy & Data leads with the switch, under its approved words, bound through the store's one setter.
    @Test func privacyAndDataLeadsWithTheTapSwitch() throws {
        let page = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/PrivacyDataSettingsView.swift"))
        let controls = try #require(MeshRoutedSourceScan.bracedBody(after: "private var privacyControls: some View", in: page))
        let tap = try #require(controls.range(of: "connectByTappingSection"))
        let photo = try #require(controls.range(of: "photoProtectionCard"))
        #expect(tap.lowerBound < photo.lowerBound, "Connect by tapping phones is the page's first control")
        let section = try #require(MeshRoutedSourceScan.bracedBody(after: "private var connectByTappingSection: some View", in: page))
        #expect(section.contains("FernletRowLabel(\"Connect by tapping phones\""))
        #expect(section.contains("detail: \"Listens only while Home is on screen, and only for a phone a few centimetres away. Sends no name and nothing that follows you.\""))
        #expect(section.contains("store.setAllowConnectByTapping($0)"))
        #expect(section.contains(".accessibilityIdentifier(\"privacy.connectByTapping\")"))
    }

    /// The switch's words carry the Spanish the spec gives.
    @Test func theSwitchSpeaksSpanish() throws {
        #expect(try Self.spanish("Connect by tapping phones", in: Self.appCatalog) == "Conectar juntando teléfonos")
        #expect(try Self.spanish("Listens only while Home is on screen, and only for a phone a few centimetres away. Sends no name and nothing that follows you.",
                                 in: Self.appCatalog)
                == "Solo escucha con el Inicio en pantalla, y solo un teléfono a pocos centímetros. No envía tu nombre ni nada que te siga.")
    }

    // MARK: A closed hangout (fr-home-closed draft 2: "never broadcast")

    /// A closed hangout advertises nothing about itself, so a friend in one reads exactly as a friend
    /// nearby on their own: "Start a hangout with Sam", no line about who they're with, no join row. A
    /// count without a hangout name is no hangout either. Only an open hangout says "Join Sam's hangout".
    @Test func friendsInAClosedHangoutReadAsFriendsEachNearby() {
        let closed = ["v": "1", "sid": "6F1C2A90-5D0E-4C1B-9E55-0A7B3C2D1E4F"]
        for (name, info) in [("Sam", closed), ("Rae", closed), ("Sam", ["v": "1", "memberCount": "3"])] {
            let kind = FriendsNearbyKind.classify(friendName: name, discoveryInfo: info)
            #expect(kind == .friend(name: name))
            #expect(FriendsNearbyCopy.heading(kind, someoneNearby: "Someone nearby") == "\(name) is nearby")
            #expect(FriendsNearbyCopy.note(kind) == nil, "nothing says who they're with")
            #expect(FriendsNearbyCopy.title(kind, someoneNearby: "Someone nearby") == "Start a hangout with \(name)")
        }
        let open = FriendsNearbyKind.classify(friendName: "Sam", discoveryInfo: ["v": "1", "meshName": "Picnic", "memberCount": "3"])
        #expect(FriendsNearbyCopy.title(open, someoneNearby: "Someone nearby") == "Join Sam's hangout")
    }

    /// On Home, two friends from a closed hangout are two friends nearby: one marker each (at most two),
    /// the blue button's "Start a hangout with Sam", which asks only Sam, and nothing that joins or names
    /// the hangout; Sprout's line is a friend's arrival, never that they're out together.
    @Test func onHomeAClosedHangoutIsTwoFriendsNearby() throws {
        #expect(FernletStore.worldNearbyFriendLimit == 2)
        var context = WorldQuickStartContext()
        context.canWalk = true
        context.canMeetFriends = true
        context.nearbyFriends = ["Sam", "Rae"]
        let card = try #require(WorldQuickStart.card(for: context))
        #expect(card.heading == .friendNearby(["Sam", "Rae"]))
        #expect(card.options == [.startSession(friend: "Sam"), .startActivity, .walkTogether])
        #expect(WorldQuickStartCopy.heading(card.heading) == "Sam and Rae are nearby")
        let words = card.options.map(WorldQuickStartCopy.title) + card.options.map(WorldQuickStartCopy.detail)
        #expect(!words.contains { $0.contains("Join ") || $0.contains("hangout ·") || $0.contains("out together") },
                "no join row and no 'out together' on Home: \(words)")
        var facts = WorldMapLine.Facts()
        facts.friendName = "Sam"
        #expect(WorldMapLine.line(facts) == "Sam's here!")
    }

    // MARK: Nobody new on Home (spec §1.1)

    /// "Make a friend" is retired everywhere, and nothing on Home, the blue button or Friends nearby says
    /// someone new is nearby (the rings of §1.2 are the tap lane's). Friends nearby stays, for friends.
    @Test func nothingOffersToMeetSomeoneNew() throws {
        let files = ["App/Fernlet/World/Friends/FriendsNearbyKind.swift", "App/Fernlet/World/Friends/FriendsNearbyPage.swift",
                     "App/Fernlet/World/Friends/NearbyPersonCard.swift", "App/Fernlet/World/QuickStart/WorldQuickStart.swift",
                     "App/Fernlet/World/QuickStart/WorldQuickStartCopy.swift", "App/Fernlet/World/QuickStart/WorldQuickStartViews.swift",
                     "App/Fernlet/World/Home/WorldMapHome.swift", "App/Fernlet/World/Home/WorldOffMapHome.swift",
                     "App/Fernlet/World/Home/WorldMapMarkers.swift", "App/Fernlet/World/Home/WorldMapLine.swift"]
        let retired = ["\"Make a friend\"", "defaultValue: \"Make a friend\"", "Someone with Fernlet is nearby",
                       "Not a friend yet", "Show each other a code, in person", "make a friend", ".newPerson"]
        // R2: bounded by the literal file list.
        for path in files {
            let code = MeshRoutedSourceScan.codeOnly(try RepoRoot.source(path))
            for word in retired {
                #expect(!code.contains(word), "\(path) still says \(word)")
            }
        }
        #expect(WorldQuickStartCopy.title(.friendsNearby) == "Friends nearby")
        #expect(WorldQuickStartCopy.detail(.friendsNearby) == "Start or join a hangout, in person")
        #expect(try Self.spanish("worldQuickStart.friendsNearby.detail", in: Self.appCatalog) == "Empieza o únete a una quedada, en persona")
    }

    /// The location-off Home (`fr-locoff` draft 2: "without location, it should rely on that tap action")
    /// has no friends card: no friend markers, no Friends nearby, no blue button.
    @Test func theLocationOffHomeHasNoFriendsCard() throws {
        let home = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/World/Home/WorldOffMapHome.swift"))
        for piece in ["worldNearbyFriends", "WorldNearbyFriendView", "FriendsNearby", "NearbyPersonCard", "WorldQuickStart",
                      "startSession", "is nearby"] {
            #expect(!home.contains(piece), "the location-off Home draws \(piece)")
        }
    }

    // MARK: A hangout, in every word (Q33, spec §2)

    /// The person never reads "session" on the hangout's own screens: the green button and its card, Hangout
    /// info, the end confirmation, Friends nearby and the blue button's camera line. Identifiers stay.
    @Test func aSessionIsAHangoutInEveryWord() throws {
        let files = ["App/Fernlet/World/Friends/WorldSessionButton.swift", "App/Fernlet/World/Friends/SessionPrompts.swift",
                     "App/Fernlet/World/Friends/SessionInfoSheet.swift", "App/Fernlet/World/Friends/FriendsNearbyPage.swift",
                     "App/Fernlet/World/QuickStart/WorldQuickStartCopy.swift"]
        let retired = ["\"Session info\"", "\"Leave session\"", "\"End session?\"", "\"End Session\"", "\"End session\"",
                       "Text(\"Session with", "in a session", "in this session", "from this session", "\"Session access\"",
                       "\"Session name\"", "\"Rename session\"", "? Text(\"Session\") :", "return Text(\"Session\") }",
                       "session info and leave",
                       "shared with the session", "Start a session"]
        // R2: bounded by the literal file list.
        for path in files {
            let code = MeshRoutedSourceScan.codeOnly(try RepoRoot.source(path))
            for word in retired {
                #expect(!code.contains(word), "\(path) still says \(word)")
            }
        }
        let button = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/World/Friends/WorldSessionButton.swift"))
        #expect(button.contains("Text(\"Hangout with \\(FriendsSessionNames.sentence(names))\")"))
        #expect(button.contains("title: Text(\"Hangout info\")") && button.contains("title: Text(\"Leave hangout\")"))
        #expect(button.contains(".accessibilityIdentifier(\"world.session.button\")"), "identifiers keep the session's names")
        #expect(button.contains(".accessibilityInputLabels([Text(\"Hangout\"), Text(\"Session\"), buttonLabel])"),
                "Voice Control answers to the new name and the old")
        #expect(WorldQuickStartCopy.title(.startSession(friend: "Sam")) == "Start a hangout with Sam")
        #expect(WorldQuickStartCopy.detail(.sessionCamera(shotsLeft: 3)) == "3 shots left · shared with the hangout")
        #expect(WorldQuickStartCopy.detail(.sessionCamera(shotsLeft: 1)) == "1 shot left · shared with the hangout")
    }

    /// Every new hangout string has its Spanish, with "quedada" for hangout.
    @Test func theHangoutWordsSpeakSpanish() throws {
        let expected: [String: String] = [
            "Hangout info": "Información de la quedada",
            "Leave hangout": "Salir de la quedada",
            "End hangout?": "¿Terminar la quedada?",
            "End hangout": "Terminar quedada",
            "Hangout with %@": "Quedada con %@",
            "Hangout": "Quedada",
            "You're in a hangout with %@. It lives on Home's hangout button.": "Estás en una quedada con %@. La tienes en el botón de quedada de Inicio."
        ]
        for (key, value) in expected {
            #expect(try Self.spanish(key, in: Self.appCatalog) == value, "\(key)")
        }
    }

    // MARK: Keep as friends? (fr-tap-keep)

    /// The sheet takes `metByTapping` (off by default, so every presenter that doesn't know stays as it
    /// was), the host passes its own, and the line under the name has its Spanish.
    @Test func keepAsFriendsCanSayMetByTapping() throws {
        let sheet = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("FernletKit/Sources/FernletProximityUI/KeepFriendsPromptSheet.swift"))
        #expect(sheet.contains("metByTapping: Bool = false"), "the sheet's input defaults to off")
        #expect(sheet.contains("if metByTapping {") && sheet.contains("FernletProximityUICopy.KeepFriends.metByTapping"))
        let host = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/World/Friends/KeepFriendsPromptHost.swift"))
        #expect(host.contains("var metByTapping = false") && host.contains("metByTapping: metByTapping,"))
        #expect(try Self.english("proximity.keepFriends.metByTapping", in: Self.proximityUICatalog) == "met by tapping phones")
        #expect(try Self.spanish("proximity.keepFriends.metByTapping", in: Self.proximityUICatalog) == "os conocisteis juntando teléfonos")
    }

    // MARK: Helpers

    /// A key's Spanish in `catalog` (its plain string unit), or nil.
    private static func spanish(_ key: String, in catalog: String) throws -> String? {
        try value(key, language: "es", in: catalog)
    }

    /// A key's English in `catalog` (its plain string unit), or nil.
    private static func english(_ key: String, in catalog: String) throws -> String? {
        try value(key, language: "en", in: catalog)
    }

    /// One language's plain string unit for `key` in a string catalog.
    private static func value(_ key: String, language: String, in catalog: String) throws -> String? {
        let data = try Data(contentsOf: RepoRoot.url(catalog))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let entry = strings[key] as? [String: Any]
        let localizations = entry?["localizations"] as? [String: Any]
        let unit = (localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any]
        return unit?["value"] as? String
    }
}
