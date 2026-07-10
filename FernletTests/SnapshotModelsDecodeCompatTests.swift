// SnapshotModelsDecodeCompatTests.swift
// Forward-compatibility of the remaining synced-blob enum carriers: CompanionAppearance (settings),
// UserNutritionProfile / UserNutritionPreferences (settings), WorkoutProfile (settings), FoodItem
// (foodItems), DailyHealthScore (dailyScores), and TextureEntry (workshop). A raw value only a
// NEWER build knows must freeze to the field default and park in a side channel instead of throwing
// (a throw bricks the whole store into read-only recovery), survive re-save, re-adopt on upgrade,
// and clear on an explicit local edit.

import Foundation
import Testing
import FernletDomainModel

struct SnapshotModelsDecodeCompatTests {
    // MARK: - CompanionAppearance (the closet enums — settings, last-writer-wins synced)

    @Test func unknownAppearanceTokensFreezeAndParkPerField() throws {
        let appearance = try decode(CompanionAppearance.self, """
        {
          "bodyStyle": "hexagon",
          "palette": "fern",
          "bodyColor": "moss",
          "accessory": "crown",
          "accessoryColor": "sun",
          "clothing": "raincoat",
          "clothingColor": "aurora",
          "sideItem": "umbrella",
          "sideItemColor": "bark"
        }
        """)

        #expect(appearance.bodyStyle == .circle)
        #expect(appearance.unknownBodyStyleToken == "hexagon")
        #expect(appearance.palette == .fern)          // known values untouched
        #expect(appearance.unknownPaletteToken == nil)
        #expect(appearance.bodyColor == .moss)
        #expect(appearance.accessory == .sprout)
        #expect(appearance.unknownAccessoryToken == "crown")
        #expect(appearance.accessoryColor == .sun)
        #expect(appearance.clothing == CompanionClothing.none)
        #expect(appearance.unknownClothingToken == "raincoat")
        #expect(appearance.clothingColor == .terracotta)
        #expect(appearance.unknownClothingColorToken == "aurora")
        #expect(appearance.sideItem == CompanionSideItem.none)
        #expect(appearance.unknownSideItemToken == "umbrella")
        #expect(appearance.sideItemColor == .bark)
        #expect(appearance.unknownSideItemColorToken == nil)

        // Round trip: main keys carry old-strict-decodable values, tokens ride the side channels.
        let object = try encodeToObject(appearance)
        #expect(CompanionBodyStyle(rawValue: object["bodyStyle"] as? String ?? "") == .circle)
        #expect(object["unknownBodyStyleToken"] as? String == "hexagon")
        #expect(object["unknownClothingToken"] as? String == "raincoat")

        let second = try decode(CompanionAppearance.self, JSONEncoder().encode(appearance))
        #expect(second == appearance)
    }

    @Test func parkedAppearanceTokenThisBuildKnowsIsReadopted() throws {
        let appearance = try decode(CompanionAppearance.self, """
        {"bodyStyle": "circle", "unknownBodyStyleToken": "pear", "clothing": "none", "unknownClothingToken": "scarf"}
        """)
        #expect(appearance.bodyStyle == .pear)
        #expect(appearance.unknownBodyStyleToken == nil)
        #expect(appearance.clothing == .scarf)
        #expect(appearance.unknownClothingToken == nil)
    }

    @Test func wardrobeStyleKeyPathWriteClearsThePark() throws {
        var appearance = try decode(CompanionAppearance.self, """
        {"bodyStyle": "hexagon"}
        """)
        #expect(appearance.unknownBodyStyleToken == "hexagon")
        // The wardrobe bindings mutate via WritableKeyPath subscripts — those go through the
        // property setter, so the didSet clears the park like any explicit edit.
        let keyPath: WritableKeyPath<CompanionAppearance, CompanionBodyStyle> = \.bodyStyle
        appearance[keyPath: keyPath] = .softBlob
        #expect(appearance.bodyStyle == .softBlob)
        #expect(appearance.unknownBodyStyleToken == nil)
    }

    @Test func absentBodyColorStillDerivesFromPalette() throws {
        // Legacy behavior guard: with the bodyColor key absent, the default derives from the
        // (tolerantly decoded) palette exactly as before.
        let appearance = try decode(CompanionAppearance.self, """
        {"palette": "rose"}
        """)
        #expect(appearance.bodyColor == .rose)
    }

    // MARK: - UserNutritionProfile / UserNutritionPreferences (settings)

    @Test func unknownNutritionProfileTokensFreezeAndPark() throws {
        let profile = try decode(UserNutritionProfile.self, """
        {"age": 41, "weightPounds": 180, "heightInches": 70, "sex": "intersex", "activityLevel": "athlete"}
        """)
        #expect(profile.age == 41)
        #expect(profile.sex == .male)
        #expect(profile.unknownSexToken == "intersex")
        #expect(profile.activityLevel == .moderate)
        #expect(profile.unknownActivityLevelToken == "athlete")

        let second = try decode(UserNutritionProfile.self, JSONEncoder().encode(profile))
        #expect(second.unknownSexToken == "intersex")
        #expect(second.unknownActivityLevelToken == "athlete")

        var edited = profile
        edited.activityLevel = .active
        #expect(edited.unknownActivityLevelToken == nil)
        #expect(edited.unknownSexToken == "intersex")  // other field's park untouched
    }

    @Test func unknownNutritionPreferenceTokensFreezeAndPark() throws {
        let preferences = try decode(UserNutritionPreferences.self, """
        {"dietaryPattern": "keto", "guidanceIntensity": "coachy"}
        """)
        #expect(preferences.dietaryPattern == .balanced)
        #expect(preferences.unknownDietaryPatternToken == "keto")
        #expect(preferences.guidanceIntensity == .steady)
        #expect(preferences.unknownGuidanceIntensityToken == "coachy")

        let readopted = try decode(UserNutritionPreferences.self, """
        {"dietaryPattern": "balanced", "unknownDietaryPatternToken": "lowerCarb", "guidanceIntensity": "steady"}
        """)
        #expect(readopted.dietaryPattern == .lowerCarb)
        #expect(readopted.unknownDietaryPatternToken == nil)
    }

    // MARK: - WorkoutProfile (settings; avoided sets are a safety field)

    @Test func unknownWorkoutProfileTokensParkWithoutThrowing() throws {
        let profile = try decode(WorkoutProfile.self, """
        {
          "avoidedMuscles": ["quads", "neckFlexors"],
          "avoidedMovements": ["hinge", "plyometric"],
          "experience": "elite",
          "trainingDaysPerWeek": 4
        }
        """)
        #expect(profile.avoidedMuscles == [.quads])
        #expect(profile.unknownAvoidedMuscleTokens == ["neckFlexors"])
        #expect(profile.avoidedMovements == [.hinge])
        #expect(profile.unknownAvoidedMovementTokens == ["plyometric"])
        #expect(profile.experience == .beginner)
        #expect(profile.unknownExperienceToken == "elite")
        #expect(profile.trainingDaysPerWeek == 4)

        // Re-save can't strip the newer build's avoided selections (un-avoiding is unsafe).
        let second = try decode(WorkoutProfile.self, JSONEncoder().encode(profile))
        #expect(second.unknownAvoidedMuscleTokens == ["neckFlexors"])
        #expect(second.unknownAvoidedMovementTokens == ["plyometric"])
        #expect(second.unknownExperienceToken == "elite")

        var edited = profile
        edited.experience = .intermediate  // WorkoutSetupView assigns the field directly
        #expect(edited.unknownExperienceToken == nil)
    }

    @Test func parkedAvoidedMuscleTokenIsReadopted() throws {
        let profile = try decode(WorkoutProfile.self, """
        {"avoidedMuscles": ["quads"], "unknownAvoidedMuscleTokens": ["calves"]}
        """)
        #expect(profile.avoidedMuscles == [.quads, .calves])
        #expect(profile.unknownAvoidedMuscleTokens.isEmpty)
    }

    // MARK: - FoodItem (blob foodItems)

    @Test func unknownFoodItemTokensFreezeAndPark() throws {
        let item = try decode(FoodItem.self, """
        {
          "name": "Mystery bar",
          "servingSize": 1,
          "servingUnit": "bar",
          "macros": {"protein": 10, "carbs": 20, "fat": 5},
          "category": "Snacks",
          "source": "openFoodFacts",
          "dataType": "fortified",
          "tags": []
        }
        """)
        // Unknown source must not falsely claim USDA or AI provenance.
        #expect(item.source == .manual)
        #expect(item.unknownSourceToken == "openFoodFacts")
        #expect(item.dataType == .srLegacy)
        #expect(item.unknownDataTypeToken == "fortified")

        let second = try decode(FoodItem.self, JSONEncoder().encode(item))
        #expect(second.unknownSourceToken == "openFoodFacts")
        #expect(second.unknownDataTypeToken == "fortified")

        let readopted = try decode(FoodItem.self, """
        {
          "name": "Mystery bar", "servingSize": 1, "servingUnit": "bar",
          "macros": {"protein": 10, "carbs": 20, "fat": 5}, "category": "Snacks",
          "source": "manual", "unknownSourceToken": "usda", "tags": []
        }
        """)
        #expect(readopted.source == .usda)
        #expect(readopted.unknownSourceToken == nil)
    }

    // MARK: - DailyHealthScore (blob dailyScores; recomputable)

    @Test func unknownCompanionStateFreezesAndParks() throws {
        let score = try decode(DailyHealthScore.self, """
        {"dateKey": "2026-07-10", "score": 0.8, "companionState": "Sparkling"}
        """)
        #expect(score.companionState == .okay)
        #expect(score.unknownCompanionStateToken == "Sparkling")

        let second = try decode(DailyHealthScore.self, JSONEncoder().encode(score))
        #expect(second.unknownCompanionStateToken == "Sparkling")

        // Recomputing on this device assigns a known state, which clears the park.
        var recomputed = score
        recomputed.companionState = .thriving
        #expect(recomputed.unknownCompanionStateToken == nil)
    }

    // MARK: - TextureEntry.tags (blob workshop)

    @Test func unknownTextureTagsParkWithoutThrowing() throws {
        let entry = try decode(TextureEntry.self, """
        {"body": "note", "tags": ["tension", "sparkle"]}
        """)
        #expect(entry.tags == [.tension])
        #expect(entry.unknownTagTokens == ["sparkle"])

        let second = try decode(TextureEntry.self, JSONEncoder().encode(entry))
        #expect(second.tags == [.tension])
        #expect(second.unknownTagTokens == ["sparkle"])
    }

    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decode(type, Data(json.utf8))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    private func encodeToObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
}
