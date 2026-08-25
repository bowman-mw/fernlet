import Foundation
import Testing
import FernletDomainModel

@Suite
struct MealComponentBindScoreTests {
    @Test func validScoreRoundTripsAndControlsConfidence() throws {
        let original = component(bindScore: FoodItemSearch.confidentBindScore)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MealComponentSnapshot.self, from: encoded)

        #expect(decoded.bindScore == FoodItemSearch.confidentBindScore)
        #expect(decoded.hasConfidentBind)
    }

    @Test func oldAndInvalidScoresRemainUnverified() throws {
        let legacy = try decodedComponent(jsonScore: nil)
        #expect(legacy.bindScore == nil)
        #expect(!legacy.hasConfidentBind)

        let invalidScores: [Any] = [0, 12.5, FoodItemSearch.maximumStoredBindScore + 1, "not a score"]
        for score in invalidScores {
            let decoded = try decodedComponent(jsonScore: score)
            #expect(decoded.bindScore == nil)
            #expect(!decoded.hasConfidentBind)
        }

        let nonFinite = try decodedComponent(jsonScore: "NaN", permitsNonFinite: true)
        #expect(nonFinite.bindScore == nil)
        #expect(!nonFinite.hasConfidentBind)
    }

    @Test func initializerRejectsOutOfRangeScoresWithoutMakingThemLowOrHigh() {
        let belowFloor = component(bindScore: FoodItemSearch.minimumBindScore - 1)
        let aboveCeiling = component(bindScore: FoodItemSearch.maximumStoredBindScore + 1)
        var mutatedAfterInitialization = component(bindScore: FoodItemSearch.confidentBindScore)
        mutatedAfterInitialization.bindScore = FoodItemSearch.maximumStoredBindScore + 1

        #expect(belowFloor.bindScore == nil)
        #expect(aboveCeiling.bindScore == nil)
        #expect(!belowFloor.hasConfidentBind)
        #expect(!aboveCeiling.hasConfidentBind)
        #expect(!mutatedAfterInitialization.hasConfidentBind)
    }

    private func component(bindScore: Int?) -> MealComponentSnapshot {
        MealComponentSnapshot(
            foodItemId: UUID(),
            name: "Eggs",
            quantity: 1,
            unit: "each",
            macros: Macros(protein: 6, carbs: 0, fat: 5),
            micronutrients: Micronutrients(),
            bindScore: bindScore
        )
    }

    private func decodedComponent(jsonScore: Any?, permitsNonFinite: Bool = false) throws -> MealComponentSnapshot {
        let encoded = try JSONEncoder().encode(component(bindScore: FoodItemSearch.confidentBindScore))
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw BindScoreTestError.invalidJSON
        }
        if let jsonScore { object["bindScore"] = jsonScore }
        else { object.removeValue(forKey: "bindScore") }
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        if permitsNonFinite {
            decoder.nonConformingFloatDecodingStrategy = .convertFromString(
                positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
            )
        }
        return try decoder.decode(MealComponentSnapshot.self, from: data)
    }
}

private enum BindScoreTestError: Error {
    case invalidJSON
}
