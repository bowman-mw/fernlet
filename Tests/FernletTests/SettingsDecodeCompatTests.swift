// SettingsDecodeCompatTests.swift
// Forward-compatibility of the synced FernletSettings enum fields — the arrays (`homeWidgets`,
// `quickLogItems`) and the scalars (`aiStatus`, `connectionInspectorMode`, `selectedGoal`):
// raw values added by a NEWER build must decode without throwing on this one (a throw cascades into
// decode-failure recovery and latches the device read-only), must survive a re-save round trip via
// the unknown-token side channels, and known-only blobs must keep the legacy encoded shape so the
// PREVIOUS build's strict decode still succeeds. Companion suites cover the other synced containers
// (DayDecodeCompatTests, SnapshotModelsDecodeCompatTests, ProximityRecordDecodeCompatTests,
// LogRecordsDecodeCompatTests).

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
          "didMigrateMealPhotosWidget": true,
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
        // Legacy blob (no migration markers) that ALSO carries a future token: BOTH one-time appends
        // (Milestones/First-aid, then Recent bites) run, and the future token is parked, not thrown on.
        let settings = try decode("""
        {"homeWidgets": ["companion", "futureWidget"]}
        """)

        #expect(settings.homeWidgets == [.companion, .firstAid, .milestones, .mealPhotos])
        #expect(settings.didMigrateMilestonesFirstAidWidgets)
        #expect(settings.didMigrateMealPhotosWidget)
        #expect(settings.unknownHomeWidgetTokens == ["futureWidget"])
    }

    // MARK: - Round trip preserves unknown tokens

    @Test func unknownTokensSurviveEncodeDecodeRoundTrip() throws {
        let first = try decode("""
        {
          "didMigrateMilestonesFirstAidWidgets": true,
          "didMigrateMealPhotosWidget": true,
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
          "didMigrateMealPhotosWidget": true,
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
          "didMigrateMealPhotosWidget": true,
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
        #expect(migrated.homeWidgets == [.companion, .firstAid, .milestones, .mealPhotos])
        #expect(migrated.didMigrateMilestonesFirstAidWidgets)
        #expect(migrated.didMigrateMealPhotosWidget)

        var edited = migrated
        edited.homeWidgets = [.milestones, .companion]  // user removed First aid + Recent bites + reordered
        let reloaded = try decode(JSONEncoder().encode(edited))
        #expect(reloaded.homeWidgets == [.milestones, .companion])
        #expect(reloaded.didMigrateMilestonesFirstAidWidgets)
        #expect(reloaded.didMigrateMealPhotosWidget)
    }

    @Test func recentBitesWidgetMigrationAppendsOnceForExistingUsers() throws {
        // An existing user who already migrated Milestones/First-aid but predates the Recent bites
        // widget (#11): only the mealPhotos append fires, appended after their kept widgets.
        let settings = try decode("""
        {"didMigrateMilestonesFirstAidWidgets": true, "homeWidgets": ["companion", "macros"]}
        """)
        #expect(settings.homeWidgets == [.companion, .macros, .mealPhotos])
        #expect(settings.didMigrateMealPhotosWidget)

        // Removing it sticks — the append does not refire once the marker has flipped true.
        var edited = settings
        edited.homeWidgets = [.companion, .macros]
        let reloaded = try decode(JSONEncoder().encode(edited))
        #expect(reloaded.homeWidgets == [.companion, .macros])
    }

    // MARK: - Scalar enum fields (freeze-on-unknown + parked-token side channels)

    @Test func unknownScalarTokensFreezeToDefaultsAndPark() throws {
        let settings = try decode("""
        {
          "didMigrateMilestonesFirstAidWidgets": true,
          "aiStatus": "hibernating",
          "connectionInspectorMode": "spectral",
          "selectedGoal": "endurance",
          "bottleOz": 40
        }
        """)

        #expect(settings.aiStatus == .off)
        #expect(settings.unknownAIStatusToken == "hibernating")
        #expect(settings.connectionInspectorMode == .live)
        #expect(settings.unknownConnectionInspectorModeToken == "spectral")
        #expect(settings.selectedGoal == .wellness)
        #expect(settings.unknownSelectedGoalToken == "endurance")
        #expect(settings.bottleOz == 40)

        // Re-save: the original keys carry values the previous build's strict decode accepts;
        // the parked tokens ride along in the side channels for a newer build to re-adopt.
        let object = try encodeToObject(settings)
        #expect(AIStatus(rawValue: object["aiStatus"] as? String ?? "") == .off)
        #expect(object["unknownAIStatusToken"] as? String == "hibernating")
        #expect(ConnectionInspectorMode(rawValue: object["connectionInspectorMode"] as? String ?? "") == .live)
        #expect(object["unknownConnectionInspectorModeToken"] as? String == "spectral")
        #expect(GoalType(persistedToken: object["selectedGoal"] as? String ?? "") == .wellness)
        #expect(object["unknownSelectedGoalToken"] as? String == "endurance")

        let second = try decode(JSONEncoder().encode(settings))
        #expect(second.aiStatus == .off)
        #expect(second.unknownAIStatusToken == "hibernating")
        #expect(second.unknownConnectionInspectorModeToken == "spectral")
        #expect(second.unknownSelectedGoalToken == "endurance")
    }

    @Test func parkedScalarTokenThisBuildKnowsIsReadopted() throws {
        // Upgrade path: an older build froze aiStatus to its default and parked "ready" (unknown
        // to it); this build knows "ready", so it wins over the frozen main value and the channel
        // clears.
        let settings = try decode("""
        {
          "didMigrateMilestonesFirstAidWidgets": true,
          "aiStatus": "off",
          "unknownAIStatusToken": "ready",
          "selectedGoal": "wellness",
          "unknownSelectedGoalToken": "strength"
        }
        """)

        #expect(settings.aiStatus == .ready)
        #expect(settings.unknownAIStatusToken == nil)
        #expect(settings.selectedGoal == .strength)
        #expect(settings.unknownSelectedGoalToken == nil)
    }

    @Test func explicitLocalSetClearsTheScalarPark() throws {
        var settings = try decode("""
        {"didMigrateMilestonesFirstAidWidgets": true, "aiStatus": "hibernating"}
        """)
        #expect(settings.unknownAIStatusToken == "hibernating")

        // The user flips the AI toggle on this device: last editor wins — the parked newer-build
        // token must NOT resurrect on the newer device.
        settings.aiStatus = .resting
        #expect(settings.unknownAIStatusToken == nil)
        let object = try encodeToObject(settings)
        #expect(object["aiStatus"] as? String == "resting")
        #expect(object["unknownAIStatusToken"] == nil)
    }

    @Test func legacyGoalAliasesDecodeWithoutParking() throws {
        // "Short-term" is a legacy alias GoalType has always mapped to .wellness — it must keep
        // resolving as a KNOWN token (not get parked as if it came from a newer build).
        let settings = try decode("""
        {"didMigrateMilestonesFirstAidWidgets": true, "selectedGoal": "Short-term"}
        """)
        #expect(settings.selectedGoal == .wellness)
        #expect(settings.unknownSelectedGoalToken == nil)
    }

    @Test func knownScalarEncodeAddsNoSideKeys() throws {
        let object = try encodeToObject(FernletSettings())
        // Scalar side channels are Optional and omitted when empty, so a known-only settings blob
        // keeps the legacy key set (plus the two always-present array side channels).
        #expect(object.keys.filter { $0.hasPrefix("unknown") }.sorted() == ["unknownHomeWidgetTokens", "unknownQuickLogTokens"])
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

    // MARK: - Generic unknown-KEY parking (systemic forward-compat, the counterpart to the token channels)

    /// Round trip: a blob with all-known keys PLUS unknown scalar/object/array keys parks the unknowns
    /// verbatim and re-emits them, byte-equivalent in structure, at the TOP LEVEL (never nested).
    @Test func unknownTopLevelKeysAreParkedAndSurviveRoundTrip() throws {
        let first = try decode("""
        {
          "bottleOz": 30,
          "didMigrateMilestonesFirstAidWidgets": true,
          "didMigrateMealPhotosWidget": true,
          "futureScalarFlag": true,
          "futureCount": 7,
          "futureString": "hello",
          "futureObject": {"nested": 1, "deep": {"x": "y"}},
          "futureArray": [1, "two", false, null]
        }
        """)

        // Exactly the five unknown keys are parked; the known `bottleOz` is NOT.
        #expect(Set(first.parkedUnknownKeys.keys)
            == ["futureScalarFlag", "futureCount", "futureString", "futureObject", "futureArray"])
        #expect(first.parkedUnknownKeys["futureScalarFlag"] == .bool(true))
        #expect(first.parkedUnknownKeys["futureCount"] == .integer(7))   // integral JSON numbers park exactly as Int64
        #expect(first.parkedUnknownKeys["futureString"] == .string("hello"))
        #expect(first.parkedUnknownKeys["futureArray"] == .array([.integer(1), .string("two"), .bool(false), .null]))
        #expect(first.parkedUnknownKeys["futureObject"]
            == .object(["nested": .integer(1), "deep": .object(["x": .string("y")])]))
        #expect(first.bottleOz == 30)

        // Re-encode: every parked key reappears at the top level; no nested wrapper key is introduced.
        let object = try encodeToObject(first)
        for key in ["futureScalarFlag", "futureCount", "futureString", "futureObject", "futureArray"] {
            #expect(object.keys.contains(key), "parked key \(key) must re-emit at top level")
        }
        #expect(!object.keys.contains("parkedUnknownKeys"), "parking must not add a wrapper key")

        // A full decode round trip preserves the parked payload exactly (key set + values).
        let second = try decode(JSONEncoder().encode(first))
        #expect(second.parkedUnknownKeys == first.parkedUnknownKeys)
    }

    /// Known-key precedence: generic parking writes unknown keys at the top level, so "a parked key that
    /// LATER becomes known" is just a top-level key this build now understands — it decodes normally and
    /// is never parked, so the current version's value always wins and a parked entry can't shadow it.
    @Test func knownKeysAreNeverParkedSoTheCurrentVersionAlwaysWins() throws {
        let settings = try decode("""
        {
          "bottleOz": 48,
          "companionName": "Fern",
          "trulyUnknownKey": "parked"
        }
        """)
        #expect(settings.bottleOz == 48)                        // normal decode…
        #expect(settings.companionName == "Fern")
        #expect(settings.parkedUnknownKeys["bottleOz"] == nil)  // …never parked, so it can't be shadowed
        #expect(settings.parkedUnknownKeys["companionName"] == nil)
        #expect(settings.parkedUnknownKeys.count == 1)
        #expect(settings.parkedUnknownKeys["trulyUnknownKey"] == .string("parked"))
    }

    /// Migration-marker non-regression: the privacy-critical `didMigratePeriodVisibility` /
    /// `periodTrackingVisible` / `intimacyTrackingVisible` are KNOWN keys — decoded, never parked — so
    /// generic parking can never let a stale copy shadow the live gate. Pure decode still leaves a
    /// pre-gate blob's migration UNRESOLVED (the pin runs later in `reconcilingSensitiveVisibility`,
    /// covered by SensitiveSurfaceGate*Tests), and a fresh save still encodes the marker as a real key.
    @Test func migrationMarkerIsAKnownKeyAndNeverParked() throws {
        // Pre-gate blob (no marker, no visibility keys) that also carries an unrelated future key.
        let preGate = try decode("""
        {"hasCompletedOnboarding": true, "someFutureKey": 1}
        """)
        #expect(preGate.periodTrackingVisible == nil)          // migration unresolved on pure decode…
        #expect(preGate.didMigratePeriodVisibility == false)   // …exactly as ef02375 established
        #expect(preGate.parkedUnknownKeys["didMigratePeriodVisibility"] == nil)
        #expect(preGate.parkedUnknownKeys["periodTrackingVisible"] == nil)
        #expect(preGate.parkedUnknownKeys["intimacyTrackingVisible"] == nil)
        #expect(preGate.parkedUnknownKeys.keys.contains("someFutureKey"))

        // When the marker IS present it decodes normally and is never parked.
        let marked = try decode("""
        {"didMigratePeriodVisibility": true, "periodTrackingVisible": false, "futureX": "y"}
        """)
        #expect(marked.didMigratePeriodVisibility)
        #expect(marked.periodTrackingVisible == false)
        #expect(marked.parkedUnknownKeys["didMigratePeriodVisibility"] == nil)

        // A fresh save still encodes the marker as a real (known) key — not parked, and per ef02375 it
        // defaults to false ("no determination represented here").
        let object = try encodeToObject(FernletSettings())
        #expect(object["didMigratePeriodVisibility"] as? Bool == false)
    }

    /// The point of the feature: a NEWER build's unknown privacy-ish gate survives an edit made on THIS
    /// (older) build — not flipped, not dropped — and re-appears for the newer build to re-adopt.
    @Test func unknownFuturePrivacyGateSurvivesAKnownEditRoundTrip() throws {
        var settings = try decode("""
        {
          "didMigrateMilestonesFirstAidWidgets": true,
          "didMigrateMealPhotosWidget": true,
          "someFutureVisibilityGate": false,
          "intimacyTrackingVisible": true
        }
        """)
        #expect(settings.parkedUnknownKeys["someFutureVisibilityGate"] == .bool(false))

        // Mutate a KNOWN setting on this build, then re-encode + reload (the older-build round trip).
        settings.bottleOz = 12
        let reloaded = try decode(JSONEncoder().encode(settings))
        #expect(reloaded.bottleOz == 12)
        #expect(reloaded.parkedUnknownKeys["someFutureVisibilityGate"] == .bool(false))  // untouched
        let object = try encodeToObject(settings)
        #expect(object["someFutureVisibilityGate"] as? Bool == false)  // re-emitted for the newer build
    }

    /// Empty/absent parking: a legacy blob with no unknown keys decodes with empty parking and encodes
    /// with NO parking artifact — parking is by-key write-back, not a nested container that would itself
    /// become an unknown key to an even-older build.
    @Test func legacyBlobWithNoUnknownKeysHasEmptyParkingAndNoArtifact() throws {
        let settings = try decode("""
        {
          "didMigrateMilestonesFirstAidWidgets": true,
          "didMigrateMealPhotosWidget": true,
          "bottleOz": 24,
          "homeWidgets": ["companion", "quickLog"]
        }
        """)
        #expect(settings.parkedUnknownKeys.isEmpty)

        let object = try encodeToObject(settings)
        #expect(!object.keys.contains("parkedUnknownKeys"))

        // A default-constructed settings likewise encodes with no parking artifact.
        let fresh = try encodeToObject(FernletSettings())
        #expect(!fresh.keys.contains("parkedUnknownKeys"))
    }

    /// Guards the hand-written `encode(to:)` against a dropped field: a representative value in each
    /// optionality kind (non-optional + every Optional written with `encodeIfPresent`) must survive a
    /// round trip. A field omitted from the custom encode would silently default here.
    @Test func customEncodePreservesAllKnownFieldsIncludingOptionals() throws {
        var settings = FernletSettings()
        settings.bottleOz = 99
        settings.companionName = "Fern"
        settings.localDesignerID = UUID()
        settings.calorieTargetOverride = 2100
        settings.proteinTargetOverride = 180
        settings.fatTargetOverride = 70
        settings.periodTrackingVisible = false
        settings.shopLastPublishedDayKey = "2026-07-18"
        settings.activeWorkoutLocationID = settings.workoutLocations.first?.id
        settings.unknownAIStatusToken = "hibernating"
        settings.hasPromptedForPresence = true
        settings.workoutProgression = ["squat": 3]

        let reloaded = try decode(JSONEncoder().encode(settings))
        #expect(reloaded.bottleOz == 99)
        #expect(reloaded.companionName == "Fern")
        #expect(reloaded.localDesignerID == settings.localDesignerID)
        #expect(reloaded.calorieTargetOverride == 2100)
        #expect(reloaded.proteinTargetOverride == 180)
        #expect(reloaded.fatTargetOverride == 70)
        #expect(reloaded.periodTrackingVisible == false)
        #expect(reloaded.shopLastPublishedDayKey == "2026-07-18")
        #expect(reloaded.activeWorkoutLocationID == settings.activeWorkoutLocationID)
        #expect(reloaded.unknownAIStatusToken == "hibernating")
        #expect(reloaded.hasPromptedForPresence)
        #expect(reloaded.workoutProgression == ["squat": 3])
    }

    // MARK: - JSONValue 64-bit integer precision (parked ids/timestamps must not detour through Double)

    @Test func jsonValueDecodesIntegersExactlyAndKeepsFractionsAsDouble() throws {
        // A top-level array so both decode and encode stay on the always-allowed path.
        let decoded = try JSONDecoder().decode([JSONValue].self,
            from: Data("[9007199254740993, 1.5, -42, 1e30]".utf8))
        // 2^53 + 1 is the smallest integer a Double can't represent; it must park as Int64, exactly.
        // 1.5 stays Double, -42 parks as Int64, and 1e30 (beyond Int64 range) stays Double.
        #expect(decoded == [.integer(9_007_199_254_740_993), .number(1.5), .integer(-42), .number(1e30)])

        let reencoded = try #require(String(data: JSONEncoder().encode(decoded), encoding: .utf8))
        #expect(reencoded.contains("9007199254740993"))   // emitted exactly, not rounded…
        #expect(!reencoded.contains("9.007"))             // …and never in e-notation
    }

    @Test func parkedIntegersRoundTripExactlyThroughSettings() throws {
        let bigID: Int64 = 9_007_199_254_740_993
        let nanos: Int64 = 1_752_940_800_123_456_789   // realistic ns timestamp, above 2^53, inside Int64
        let first = try decode("""
        {
          "bottleOz": 30,
          "futureBigID": 9007199254740993,
          "futureNanos": 1752940800123456789,
          "futureFraction": 1.5,
          "futureMix": {"count": 42, "ratios": [1, 2.5, 3]}
        }
        """)

        #expect(first.parkedUnknownKeys["futureBigID"] == .integer(bigID))
        #expect(first.parkedUnknownKeys["futureNanos"] == .integer(nanos))
        #expect(first.parkedUnknownKeys["futureFraction"] == .number(1.5))
        #expect(first.parkedUnknownKeys["futureMix"]
            == .object(["count": .integer(42), "ratios": .array([.integer(1), .number(2.5), .integer(3)])]))
        #expect(first.bottleOz == 30)   // the known key is still not parked

        // Re-emit as plain integer text — the whole point: a Double detour would corrupt bigID (off-by-one)
        // and re-emit large ids in e-notation that a strict Int64 decode on a newer build then throws on.
        let encoded = try JSONEncoder().encode(first)
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(text.contains("9007199254740993"))
        #expect(text.contains("1752940800123456789"))
        #expect(!text.contains("9.007199254740993e"))

        // Full decode round trip preserves the parked payload exactly.
        let second = try decode(encoded)
        #expect(second.parkedUnknownKeys == first.parkedUnknownKeys)
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
