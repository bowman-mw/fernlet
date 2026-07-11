// DayDecodeCompatTests.swift
// Forward-compatibility of the day-resident enums (FernletDay.hygiene + the enums inside Workout,
// PlannedWorkout, Meal, JournalEntry, SleepLog). A raw value only a NEWER build knows must decode
// without throwing on this one — inside the blob a throw cascades into decode-failure recovery
// (whole store read-only); inside a DayRecord row it silently drops the day. Unknown tokens freeze
// to the field default, park in a side channel, survive a re-save round trip, are re-adopted by a
// build that knows them, and are cleared by an explicit local edit.

import Foundation
import Testing
import FernletDomainModel

struct DayDecodeCompatTests {
    // MARK: - FernletDay.hygiene (Set park)

    @Test func unknownHygieneMemberParksInsteadOfThrowing() throws {
        let day = try decodeDay("""
        {"date": "2026-07-10", "hygiene": ["shower", "hairCare", "floss"], "bottleCount": 2}
        """)

        #expect(day.hygiene == [.shower, .floss])
        #expect(day.unknownHygieneTokens == ["hairCare"])
        #expect(day.bottleCount == 2)

        // Round trip: the main key stays strictly decodable by the previous build; the parked
        // token rides in the side channel.
        let object = try encodeToObject(day)
        let hygieneData = try JSONSerialization.data(withJSONObject: object["hygiene"] as Any)
        #expect(try JSONDecoder().decode(Set<HygieneItem>.self, from: hygieneData) == [.shower, .floss])
        #expect(object["unknownHygieneTokens"] as? [String] == ["hairCare"])

        let second = try decodeDay(JSONEncoder().encode(day))
        #expect(second.hygiene == day.hygiene)
        #expect(second.unknownHygieneTokens == ["hairCare"])
    }

    @Test func parkedHygieneTokenThisBuildKnowsIsReadopted() throws {
        let day = try decodeDay("""
        {"date": "2026-07-10", "hygiene": ["shower"], "unknownHygieneTokens": ["sunscreen"]}
        """)
        #expect(day.hygiene == [.shower, .sunscreen])
        #expect(day.unknownHygieneTokens.isEmpty)
    }

    @Test func dayWithOnlyANewerHygieneItemStillCountsAsLogged() throws {
        // `hasLoggedContent` feeds fresh-install detection and coin accrual — a day whose only
        // content is a newer build's hygiene item must not read as empty on this build.
        let day = try decodeDay("""
        {"date": "2026-07-10", "hygiene": ["hairCare"], "completedPersonalCareTaskIDs": []}
        """)
        #expect(day.hygiene.isEmpty)
        #expect(day.unknownHygieneTokens == ["hairCare"])
        #expect(day.hasLoggedContent)
    }

    // MARK: - Workout enums

    @Test func unknownWorkoutEnumsFreezeAndPark() throws {
        let day = try decodeDay("""
        {
          "date": "2026-07-10",
          "workouts": [{
            "name": "Mystery session",
            "type": "Mobility",
            "mode": "recoveryFlow",
            "activityType": "surfing",
            "exercises": "flow",
            "notes": "",
            "intensity": "brutal",
            "muscleGroups": ["chest", "neckFlexors"]
          }]
        }
        """)

        let workout = try #require(day.workouts.first)
        #expect(workout.type == .fullBody)
        #expect(workout.unknownTypeToken == "Mobility")
        #expect(workout.mode == .strengthTraining)
        #expect(workout.unknownModeToken == "recoveryFlow")
        #expect(workout.activityType == nil)
        #expect(workout.unknownActivityTypeToken == "surfing")
        #expect(workout.intensity == .moderate)
        #expect(workout.unknownIntensityToken == "brutal")
        #expect(workout.muscleGroups == [.chest])
        #expect(workout.unknownMuscleGroupTokens == ["neckFlexors"])

        // Round trip preserves both halves; the main keys stay old-strict-decodable.
        let second = try decodeDay(JSONEncoder().encode(day))
        let reloaded = try #require(second.workouts.first)
        #expect(reloaded.type == .fullBody)
        #expect(reloaded.unknownTypeToken == "Mobility")
        #expect(reloaded.unknownModeToken == "recoveryFlow")
        #expect(reloaded.unknownActivityTypeToken == "surfing")
        #expect(reloaded.unknownIntensityToken == "brutal")
        #expect(reloaded.unknownMuscleGroupTokens == ["neckFlexors"])
    }

    @Test func explicitWorkoutEditClearsOnlyThatFieldsPark() throws {
        let day = try decodeDay("""
        {
          "date": "2026-07-10",
          "workouts": [{
            "name": "Mystery session", "type": "Mobility", "exercises": "", "notes": "",
            "intensity": "brutal"
          }]
        }
        """)
        var workout = try #require(day.workouts.first)
        workout.type = .upper
        #expect(workout.unknownTypeToken == nil)
        #expect(workout.unknownIntensityToken == "brutal")  // untouched field keeps its park
    }

    @Test func parkedWorkoutTokensThisBuildKnowsAreReadopted() throws {
        let day = try decodeDay("""
        {
          "date": "2026-07-10",
          "workouts": [{
            "name": "Run", "type": "Cardio", "exercises": "", "notes": "",
            "intensity": "light",
            "unknownActivityTypeToken": "running",
            "muscleGroups": [], "unknownMuscleGroupTokens": ["quads"]
          }]
        }
        """)
        let workout = try #require(day.workouts.first)
        #expect(workout.activityType == .running)
        #expect(workout.unknownActivityTypeToken == nil)
        #expect(workout.muscleGroups == [.quads])
        #expect(workout.unknownMuscleGroupTokens.isEmpty)
    }

    // MARK: - PlannedWorkout enums

    @Test func unknownPlannedWorkoutEnumsFreezeAndPark() throws {
        let day = try decodeDay("""
        {
          "date": "2026-07-10",
          "plannedWorkouts": [{
            "name": "Coming up",
            "split": "antagonistSuperset",
            "source": "aiCoach",
            "muscleGroups": ["glutes", "spinalErectors"]
          }]
        }
        """)

        let planned = try #require(day.plannedWorkouts.first)
        #expect(planned.split == .workout)
        #expect(planned.unknownSplitToken == "antagonistSuperset")
        #expect(planned.source == .user)
        #expect(planned.unknownSourceToken == "aiCoach")
        #expect(planned.muscleGroups == [.glutes])
        #expect(planned.unknownMuscleGroupTokens == ["spinalErectors"])

        let second = try decodeDay(JSONEncoder().encode(day))
        let reloaded = try #require(second.plannedWorkouts.first)
        #expect(reloaded.unknownSplitToken == "antagonistSuperset")
        #expect(reloaded.unknownSourceToken == "aiCoach")
        #expect(reloaded.unknownMuscleGroupTokens == ["spinalErectors"])
    }

    // MARK: - Meal enums

    @Test func unknownMealEnumsFreezeAndPark() throws {
        let day = try decodeDay("""
        {
          "date": "2026-07-10",
          "meals": [{
            "name": "Affogato",
            "mealType": "Dessert",
            "macros": {"protein": 4, "carbs": 20, "fat": 9},
            "mealSource": "importedPlan",
            "quality": "amazing",
            "confidence": "high",
            "note": "",
            "source": "manual"
          }]
        }
        """)

        let meal = try #require(day.meals.first)
        #expect(meal.mealType == .snack)
        #expect(meal.unknownMealTypeToken == "Dessert")
        #expect(meal.mealSource == .manual)
        #expect(meal.unknownMealSourceToken == "importedPlan")
        #expect(meal.quality == .ok)
        #expect(meal.unknownQualityToken == "amazing")
        #expect(meal.macros.carbs == 20)

        let second = try decodeDay(JSONEncoder().encode(day))
        let reloaded = try #require(second.meals.first)
        #expect(reloaded.unknownMealTypeToken == "Dessert")
        #expect(reloaded.unknownMealSourceToken == "importedPlan")
        #expect(reloaded.unknownQualityToken == "amazing")

        // Middle-build re-save contract: the re-encoded MAIN key must carry a token the previous
        // build's strict raw-value decode resolves (the frozen default), never the future token.
        let object = try encodeToObject(day)
        let mealObjects = try #require(object["meals"] as? [[String: Any]])
        let mainTypeToken = try #require(mealObjects.first?["mealType"] as? String)
        #expect(MealType(rawValue: mainTypeToken) == .snack)
        let mainQualityToken = try #require(mealObjects.first?["quality"] as? String)
        #expect(MealQuality(rawValue: mainQualityToken) == .ok)
    }

    @Test func missingMealTypeKeyStillThrows() throws {
        // Missing KEY ≠ unknown VALUE: no build (old or new) ever writes a meal without `mealType`,
        // so absence is corruption/truncation and must keep failing decode exactly like the
        // historical strict `container.decode` — only a present-but-unknown value freezes + parks.
        let json = """
        {
          "name": "Affogato",
          "macros": {"protein": 4, "carbs": 20, "fat": 9},
          "quality": "ok", "confidence": "high", "note": "", "source": "manual"
        }
        """
        let error = #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Meal.self, from: Data(json.utf8))
        }
        if case .keyNotFound(let key, _)? = error {
            #expect(key.stringValue == "mealType")
        } else {
            Issue.record("expected keyNotFound(mealType), got \(String(describing: error))")
        }
    }

    @Test func explicitMealEditClearsThePark() throws {
        let day = try decodeDay("""
        {
          "date": "2026-07-10",
          "meals": [{
            "name": "Affogato", "mealType": "Dessert",
            "macros": {"protein": 4, "carbs": 20, "fat": 9},
            "quality": "ok", "confidence": "high", "note": "", "source": "manual"
          }]
        }
        """)
        var meal = try #require(day.meals.first)
        meal.mealType = .snack  // meal-correction flow assigns the field directly
        #expect(meal.unknownMealTypeToken == nil)
    }

    // MARK: - JournalEntry.tag + SleepLog.quality

    @Test func unknownJournalTagAndSleepQualityFreezeAndPark() throws {
        let day = try decodeDay("""
        {
          "date": "2026-07-10",
          "journals": [{"text": "went outside", "tag": "sparkly"}],
          "sleep": {"quality": "refreshing", "note": ""}
        }
        """)

        let journal = try #require(day.journals.first)
        #expect(journal.tag == .neutral)
        #expect(journal.unknownTagToken == "sparkly")
        let sleep = try #require(day.sleep)
        #expect(sleep.quality == .ok)
        #expect(sleep.unknownQualityToken == "refreshing")

        let second = try decodeDay(JSONEncoder().encode(day))
        #expect(second.journals.first?.unknownTagToken == "sparkly")
        #expect(second.sleep?.unknownQualityToken == "refreshing")

        // An explicit local tag edit clears the park (last editor wins).
        var journalCopy = journal
        journalCopy.tag = .bright
        #expect(journalCopy.unknownTagToken == nil)
    }

    @Test func sealedJournalStripKeepsTheParkedTag() throws {
        let day = try decodeDay("""
        {
          "date": "2026-07-10",
          "journals": [{"id": "11111111-1111-1111-1111-111111111111", "text": "secret", "tag": "sparkly"}]
        }
        """)
        let journal = try #require(day.journals.first)
        let stripped = journal.strippedIfSealed(in: [journal.id])
        #expect(stripped.text.isEmpty)
        #expect(stripped.tag == .neutral)
        #expect(stripped.unknownTagToken == "sparkly")  // the strip must not drop the newer tag

        // Fail-closed allowlist (S3): the strip reconstructs memberwise, so its output carries
        // ONLY the known non-sensitive fields plus the parked side channel — nothing else. If a
        // new JournalEntry stored field makes this key set grow, strippedIfSealed must be
        // consciously re-audited before this expectation is updated.
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(stripped)) as? [String: Any])
        #expect(object.keys.sorted() == ["date", "emotions", "id", "isQuickMood", "tag", "text", "unknownTagToken"])
    }

    // MARK: - Helpers

    private func decodeDay(_ json: String) throws -> FernletDay {
        try decodeDay(Data(json.utf8))
    }

    private func decodeDay(_ data: Data) throws -> FernletDay {
        try JSONDecoder().decode(FernletDay.self, from: data)
    }

    private func encodeToObject(_ day: FernletDay) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(day)) as? [String: Any])
    }
}
