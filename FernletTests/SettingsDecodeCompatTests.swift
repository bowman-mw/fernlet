// SettingsDecodeCompatTests.swift
// Forward-compatibility of the synced FernletSettings enum arrays (`homeWidgets`, `quickLogItems`):
// raw values added by a NEWER build must decode without throwing on this one (a throw cascades into
// decode-failure recovery and latches the device read-only), must survive a re-save round trip via
// the unknown-token side channels, and known-only blobs must keep the legacy encoded shape so the
// PREVIOUS build's strict decode still succeeds.

import Foundation
import Testing
import FernletDomainModel

struct SettingsDecodeCompatTests {
    // MARK: - Unknown tokens decode without throwing

    @Test func unknownEnumTokensDecodeWithoutThrowingAndKeepOtherData() throws {
        let settings = try decode("""
        {
          "bottleOz": 32,
          "proximityDisplayName": "Compat",
          "didMigrateMilestonesFirstAidWidgets": true,
          "homeWidgets": ["companion", "weatherOutlook", "quickLog"],
          "quickLogItems": ["meal", "futureShortcut", "water"]
        }
        """)

        #expect(settings.bottleOz == 32)
        #expect(settings.proximityDisplayName == "Compat")
        #expect(settings.homeWidgets == [.companion, .quickLog])
        #expect(settings.unknownHomeWidgetTokens == ["weatherOutlook"])
        // The parked slot is NOT padded back to six here — padding happens transiently at display
        // (`visibleQuickLog`), so a re-save can't hand the newer build's slot to an auto-filled default.
        #expect(settings.quickLogItems == [.meal, .water])
        #expect(settings.unknownQuickLogTokens == ["futureShortcut"])
    }

    @Test func unknownTokensCoexistWithWidgetMigration() throws {
        // Legacy blob (no migration marker) that ALSO carries a future token: the one-time
        // Milestones/First-aid append still runs, and the future token is parked, not thrown on.
        let settings = try decode("""
        {"homeWidgets": ["companion", "futureWidget"]}
        """)

        #expect(settings.homeWidgets == [.companion, .firstAid, .milestones])
        #expect(settings.didMigrateMilestonesFirstAidWidgets)
        #expect(settings.unknownHomeWidgetTokens == ["futureWidget"])
    }

    // MARK: - Round trip preserves unknown tokens

    @Test func unknownTokensSurviveEncodeDecodeRoundTrip() throws {
        let first = try decode("""
        {
          "didMigrateMilestonesFirstAidWidgets": true,
          "homeWidgets": ["companion", "weatherOutlook", "quickLog"],
          "quickLogItems": ["meal", "futureShortcut", "water"]
        }
        """)

        let object = try encodeToObject(first)
        // Unknown tokens re-encode in the side channels, never in the typed arrays (which must stay
        // decodable by the previous build's strict `[HomeWidget]`/`[FernletShortcut]` logic).
        #expect(object["homeWidgets"] as? [String] == ["companion", "quickLog"])
        #expect(object["unknownHomeWidgetTokens"] as? [String] == ["weatherOutlook"])
        #expect(object["quickLogItems"] as? [String] == ["meal", "water"])
        #expect(object["unknownQuickLogTokens"] as? [String] == ["futureShortcut"])

        let second = try decode(JSONEncoder().encode(first))
        #expect(second.homeWidgets == first.homeWidgets)
        #expect(second.unknownHomeWidgetTokens == first.unknownHomeWidgetTokens)
        #expect(second.quickLogItems == first.quickLogItems)
        #expect(second.unknownQuickLogTokens == first.unknownQuickLogTokens)
    }

    @Test func parkedTokensThisBuildKnowsAreReadopted() throws {
        // Simulates the upgrade path: an OLDER build with the side channels parked "firstAid" and
        // "breathing" (unknown to it); this build knows them, so they rejoin the typed arrays
        // (appended) and leave the side channels.
        let settings = try decode("""
        {
          "didMigrateMilestonesFirstAidWidgets": true,
          "homeWidgets": ["companion"],
          "unknownHomeWidgetTokens": ["firstAid"],
          "quickLogItems": ["meal", "water"],
          "unknownQuickLogTokens": ["breathing"]
        }
        """)

        #expect(settings.homeWidgets == [.companion, .firstAid])
        #expect(settings.unknownHomeWidgetTokens.isEmpty)
        #expect(settings.quickLogItems == [.meal, .water, .breathing, .move, .sleep, .journal])
        #expect(settings.unknownQuickLogTokens.isEmpty)
    }

    // MARK: - Known-only blobs keep the legacy shape

    @Test func legacyBlobStillDecodes() throws {
        // Old-shape JSON: no side-channel keys, migration marker present — exactly what the
        // previous build wrote.
        let settings = try decode("""
        {
          "didMigrateMilestonesFirstAidWidgets": true,
          "homeWidgets": ["companion", "quickLog", "macros"],
          "quickLogItems": ["meal", "water", "move", "sleep", "journal", "care"]
        }
        """)

        #expect(settings.homeWidgets == [.companion, .quickLog, .macros])
        #expect(settings.quickLogItems == [.meal, .water, .move, .sleep, .journal, .care])
        #expect(settings.unknownHomeWidgetTokens.isEmpty)
        #expect(settings.unknownQuickLogTokens.isEmpty)
    }

    @Test func knownOnlyEncodeStaysDecodableByTheOldStrictLogic() throws {
        var settings = FernletSettings()
        settings.homeWidgets = [.companion, .quickLog]
        settings.quickLogItems = [.meal, .water, .move, .sleep, .journal, .care]

        let object = try encodeToObject(settings)
        // The only deliberate additions to the encoded shape are the two side-channel keys, which the
        // old build's keyed container skips.
        #expect(object.keys.filter { $0.hasPrefix("unknown") }.sorted() == ["unknownHomeWidgetTokens", "unknownQuickLogTokens"])
        #expect(object["unknownHomeWidgetTokens"] as? [String] == [])
        #expect(object["unknownQuickLogTokens"] as? [String] == [])
        // The previous build decodes these arrays strictly — prove no unknown token leaks into them.
        let widgetsData = try JSONSerialization.data(withJSONObject: object["homeWidgets"] as Any)
        let itemsData = try JSONSerialization.data(withJSONObject: object["quickLogItems"] as Any)
        #expect(try JSONDecoder().decode([HomeWidget].self, from: widgetsData) == [.companion, .quickLog])
        #expect(try JSONDecoder().decode([FernletShortcut].self, from: itemsData) == [.meal, .water, .move, .sleep, .journal, .care])
    }

    @Test func widgetMigrationDoesNotRefireAcrossRoundTrips() throws {
        let migrated = try decode("""
        {"homeWidgets": ["companion"], "quickLogItems": ["meal"]}
        """)
        #expect(migrated.homeWidgets == [.companion, .firstAid, .milestones])
        #expect(migrated.didMigrateMilestonesFirstAidWidgets)

        var edited = migrated
        edited.homeWidgets = [.milestones, .companion]  // user removed First aid + reordered
        let reloaded = try decode(JSONEncoder().encode(edited))
        #expect(reloaded.homeWidgets == [.milestones, .companion])
        #expect(reloaded.didMigrateMilestonesFirstAidWidgets)
    }

    // MARK: - Side-channel bounds

    @Test func parkedUnknownTokensAreDedupedAndBounded() throws {
        let tokens = (0..<20).map { "future\($0)" } + ["future0", String(repeating: "x", count: 65)]
        let json = try JSONSerialization.data(withJSONObject: [
            "didMigrateMilestonesFirstAidWidgets": true,
            "homeWidgets": tokens
        ] as [String: Any])
        let settings = try decode(json)

        // All-unknown array: the typed list falls back to the defaults; the tokens are parked
        // deduped and capped, with oversized ones treated as corrupt and dropped.
        #expect(settings.homeWidgets == HomeWidget.defaultWidgets)
        #expect(settings.unknownHomeWidgetTokens == (0..<16).map { "future\($0)" })
    }

    // MARK: - Helpers

    private func decode(_ json: String) throws -> FernletSettings {
        try decode(Data(json.utf8))
    }

    private func decode(_ data: Data) throws -> FernletSettings {
        try JSONDecoder().decode(FernletSettings.self, from: data)
    }

    private func encodeToObject(_ settings: FernletSettings) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
    }
}
