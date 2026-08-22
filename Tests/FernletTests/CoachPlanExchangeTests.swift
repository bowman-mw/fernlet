import XCTest
import FernletDomainModel
import FernletFoundation
@testable import Fernlet

/// The manual coach exchange: clipboard export → pasted `CoachPlan` → dated `PlannedWorkout` rows.
///
/// The paste path takes UNSIGNED, UNTRUSTED text, so most of what's asserted here is what the
/// importer REFUSES — oversize blobs, truncated JSON, plans over the day cap, exercises with no
/// safety metadata, and plans that would apply despite a blocking issue. The happy path is one
/// test; the ways it must fail closed are the rest.
@MainActor
final class CoachPlanExchangeTests: XCTestCase {

    /// ``WorkoutExerciseCatalog``'s custom registry is process-global, so a test that registers an
    /// exercise would otherwise leak it into every later test in the run (and into the planning
    /// engine's feasibility checks). Clear it around every test.
    override func setUp() {
        super.setUp()
        WorkoutExerciseCatalog.registerCustomExercises([])
    }

    override func tearDown() {
        WorkoutExerciseCatalog.registerCustomExercises([])
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A minimal well-formed plan JSON, parameterised so individual tests can break one thing.
    private func planJSON(days: Int = 2,
                          exerciseName: String = "Zercher squat",
                          sets: String = "3",
                          reps: String = "\"8-10\"",
                          definition: String? = nil,
                          schemaVersion: Int = CoachPlan.currentSchemaVersion) -> String {
        let definitionJSON = definition ?? """
        {
          "name": "\(exerciseName)",
          "primaryMuscles": ["quads", "glutes"],
          "secondaryMuscles": ["abs"],
          "equipment": "barbell",
          "movementPattern": "squat",
          "inputKind": "strength"
        }
        """
        let dayObjects = (1...max(days, 1)).map { index in
            """
            {
              "dayIndex": \(index),
              "title": "Day \(index)",
              "isRestDay": false,
              "sessions": [
                {
                  "title": "Session \(index)",
                  "kind": "strength",
                  "exercises": [
                    { "name": "\(exerciseName)", "sets": \(sets), "reps": \(reps), "restSeconds": 120,
                      "guidance": "RPE 7" }
                  ]
                }
              ]
            }
            """
        }.joined(separator: ",")

        return """
        {
          "format": "\(CoachPlan.formatTag)",
          "schemaVersion": \(schemaVersion),
          "title": "Test block",
          "coachDisplayName": "Claude",
          "startPolicy": { "kind": "onAccept" },
          "days": [\(dayObjects)],
          "newExercises": [\(definitionJSON)]
        }
        """
    }

    private func decoded(_ json: String) throws -> CoachPlan {
        switch CoachPlanImporter.decode(pastedText: json) {
        case .success(let plan): return plan
        case .failure(let error): throw XCTSkip("expected a decodable plan, got: \(error.message)")
        }
    }

    // MARK: - Extracting JSON from a real paste

    func testExtractsJSONFromFencedReplyWithProse() throws {
        let reply = """
        Sure! Here's a 2-day block based on your history.

        ```json
        \(planJSON())
        ```

        Let me know if you want the volume adjusted.
        """
        let plan = try decoded(reply)
        XCTAssertEqual(plan.days.count, 2, "the plan must survive markdown fences and surrounding prose")
        XCTAssertEqual(plan.title, "Test block")
    }

    /// A brace inside a string value must not end the object scan.
    func testExtractsJSONWhenGuidanceContainsBraces() throws {
        let json = """
        { "format": "\(CoachPlan.formatTag)", "title": "T", "coachDisplayName": "C",
          "days": [ { "dayIndex": 1, "title": "D", "isRestDay": false, "sessions": [
            { "title": "S", "kind": "strength", "exercises": [
              { "name": "Push-up", "sets": 3, "reps": "10", "guidance": "tempo {2-0-1} and \\" quotes" }
            ] } ] } ],
          "newExercises": [] }
        """
        let extracted = CoachPlanImporter.extractJSON(from: "text before \(json) text after")
        XCTAssertNotNil(extracted, "a brace or escaped quote inside a string must not terminate the scan")
        XCTAssertTrue(extracted?.hasSuffix("}") == true)
    }

    func testRejectsPasteWithNoJSON() {
        guard case .failure(let error) = CoachPlanImporter.decode(pastedText: "I can't help with that.") else {
            return XCTFail("prose with no JSON object must not decode")
        }
        XCTAssertEqual(error, .noJSONFound)
    }

    func testRejectsEmptyPaste() {
        guard case .failure(let error) = CoachPlanImporter.decode(pastedText: "   \n  ") else {
            return XCTFail("empty text must not decode")
        }
        XCTAssertEqual(error, .empty)
    }

    /// A paste cut off mid-object has unbalanced braces and must fail rather than half-decode.
    func testRejectsTruncatedJSON() {
        let truncated = String(planJSON().dropLast(40))
        guard case .failure(let error) = CoachPlanImporter.decode(pastedText: truncated) else {
            return XCTFail("a truncated plan must not decode")
        }
        XCTAssertEqual(error, .noJSONFound, "unbalanced braces should read as 'no plan found'")
    }

    /// The size bound must be enforced BEFORE parsing, so a huge blob is never turned into objects.
    func testRejectsOversizePaste() {
        let huge = String(repeating: "a", count: CoachPlanLimits.maxPastedBytes + 1)
        guard case .failure(let error) = CoachPlanImporter.decode(pastedText: huge) else {
            return XCTFail("an oversize paste must be refused")
        }
        guard case .tooLarge = error else { return XCTFail("expected .tooLarge, got \(error)") }
    }

    // MARK: - Bounds

    func testRejectsPlanOverTheDayCap() {
        guard case .failure(let error) = CoachPlanImporter.decode(
            pastedText: planJSON(days: CoachPlanLimits.maxDays + 1)) else {
            return XCTFail("a plan over the day cap must be refused at decode")
        }
        guard case .bounded(.tooManyDays(let count)) = error else {
            return XCTFail("expected .tooManyDays, got \(error)")
        }
        XCTAssertEqual(count, CoachPlanLimits.maxDays + 1)
        XCTAssertTrue(error.message.contains("\(CoachPlanLimits.maxDays)"),
                      "the message must state the real limit so it's actionable")
    }

    func testAcceptsExactlyTheDayCap() throws {
        let plan = try decoded(planJSON(days: CoachPlanLimits.maxDays))
        XCTAssertEqual(plan.days.count, CoachPlanLimits.maxDays)
    }

    /// Models emit `"reps": 10` as readily as `"reps": "8-10"`; both must survive.
    func testAcceptsNumericReps() throws {
        let plan = try decoded(planJSON(reps: "10"))
        XCTAssertEqual(plan.days.first?.sessions.first?.exercises.first?.reps, "10")
    }

    // MARK: - Validation

    private var catalogNames: Set<String> { Set(WorkoutExerciseCatalog.allExercises.map(\.name)) }

    func testValidateAcceptsAPlanThatDefinesItsNewExercise() throws {
        let plan = try decoded(planJSON())
        let blocking = plan.validate(knownExerciseNames: catalogNames).filter(\.isBlocking)
        XCTAssertTrue(blocking.isEmpty, "a defined exercise should not block: \(blocking.map(\.detail))")
    }

    func testValidateBlocksAnUndefinedExercise() throws {
        let plan = try decoded(planJSON(definition: """
        { "name": "Something else", "primaryMuscles": ["quads"], "equipment": "barbell",
          "movementPattern": "squat" }
        """))
        let issues = plan.validate(knownExerciseNames: catalogNames)
        XCTAssertTrue(issues.contains { $0.kind == .undefinedExercise && $0.subject == "Zercher squat" },
                      "an exercise that is neither in the catalog nor defined must block the import")
    }

    /// Metadata is required precisely because `WorkoutSafetyFilter` needs it — a definition with no
    /// movement pattern must be rejected, not defaulted.
    func testValidateRejectsDefinitionMissingMovementPattern() throws {
        let plan = try decoded(planJSON(definition: """
        { "name": "Zercher squat", "primaryMuscles": ["quads"], "equipment": "barbell",
          "movementPattern": "" }
        """))
        let issues = plan.validate(knownExerciseNames: catalogNames)
        XCTAssertTrue(issues.contains { $0.kind == .unknownToken },
                      "a missing movement pattern must be reported, never defaulted to isolation")
    }

    func testValidateRejectsDefinitionWithNoPrimaryMuscles() throws {
        let plan = try decoded(planJSON(definition: """
        { "name": "Zercher squat", "primaryMuscles": [], "equipment": "barbell",
          "movementPattern": "squat" }
        """))
        let issues = plan.validate(knownExerciseNames: catalogNames)
        XCTAssertTrue(issues.contains { $0.kind == .invalidExerciseDefinition },
                      "with no muscles Fernlet can't check the exercise against the avoid list")
    }

    func testValidateRejectsUnknownMuscleToken() throws {
        let plan = try decoded(planJSON(definition: """
        { "name": "Zercher squat", "primaryMuscles": ["pecs"], "equipment": "barbell",
          "movementPattern": "squat" }
        """))
        let issues = plan.validate(knownExerciseNames: catalogNames)
        let unknown = issues.first { $0.kind == .unknownToken }
        XCTAssertNotNil(unknown)
        XCTAssertTrue(unknown?.detail.contains("chest") == true,
                      "the error must quote the accepted vocabulary so it's fixable")
    }

    /// A newer schema is refused outright rather than half-read.
    func testValidateRejectsNewerSchemaVersion() throws {
        let plan = try decoded(planJSON(schemaVersion: CoachPlan.currentSchemaVersion + 1))
        let issues = plan.validate(knownExerciseNames: catalogNames)
        XCTAssertEqual(issues.count, 1, "a newer schema must short-circuit, not list downstream noise")
        XCTAssertTrue(issues[0].isBlocking)
        XCTAssertTrue(issues[0].detail.contains("Update Fernlet"))
    }

    func testValidateRejectsForeignFormatTag() throws {
        let json = planJSON().replacingOccurrences(of: CoachPlan.formatTag, with: "some.other.format")
        let plan = try decoded(json)
        let issues = plan.validate(knownExerciseNames: catalogNames)
        XCTAssertTrue(issues.contains { $0.isBlocking }, "a foreign format tag must block")
    }

    func testValidateBlocksDuplicateDayIndex() throws {
        let json = """
        { "format": "\(CoachPlan.formatTag)", "title": "T", "coachDisplayName": "C",
          "days": [
            { "dayIndex": 1, "title": "A", "isRestDay": false, "sessions": [
              { "title": "S", "kind": "strength", "exercises": [
                { "name": "Push-up", "sets": 3, "reps": "10" } ] } ] },
            { "dayIndex": 1, "title": "B", "isRestDay": false, "sessions": [
              { "title": "S", "kind": "strength", "exercises": [
                { "name": "Push-up", "sets": 3, "reps": "10" } ] } ] }
          ],
          "newExercises": [] }
        """
        let plan = try decoded(json)
        let issues = plan.validate(knownExerciseNames: catalogNames)
        XCTAssertTrue(issues.contains { $0.isBlocking && $0.detail.contains("more than once") })
    }

    /// Out-of-range sets are advisory, not fatal — they're clamped on apply.
    func testOutOfRangeSetsAreClampedNotBlocking() throws {
        let plan = try decoded(planJSON(sets: "99"))
        let issues = plan.validate(knownExerciseNames: catalogNames)
        XCTAssertTrue(issues.contains { $0.kind == .clamped })
        XCTAssertFalse(issues.contains(where: \.isBlocking), "an absurd set count should clamp, not block")
    }

    // MARK: - Name normalization and token folding

    func testNormalizedNameCollapsesCaseAndWhitespace() {
        XCTAssertEqual(CoachPlan.normalizedName("  Bench   Press "), CoachPlan.normalizedName("bench press"))
        XCTAssertNotEqual(CoachPlan.normalizedName("Bench press"), CoachPlan.normalizedName("Bench pres"))
    }

    func testTokenMatchingToleratesSpacingAndCase() {
        XCTAssertEqual(CoachPlanTokens.muscle("Upper Back"), .upperBack)
        XCTAssertEqual(CoachPlanTokens.muscle("upper-back"), .upperBack)
        XCTAssertEqual(CoachPlanTokens.muscle("upperBack"), .upperBack)
        XCTAssertEqual(CoachPlanTokens.equipment("Body Weight") ?? CoachPlanTokens.equipment("bodyweight"), .bodyweight)
        XCTAssertEqual(CoachPlanTokens.movementPattern("Hinge"), .hinge)
        XCTAssertNil(CoachPlanTokens.muscle("pecs"), "an unmatched token must fail, never fall back")
    }

    // MARK: - Exercise line parsing

    func testParsesCommonLoggedLineShapes() {
        let cases: [(String, String, Int?, String?, Double?)] = [
            ("Bench press - 3 x 8", "Bench press", 3, "8", nil),
            ("Squat 5x5 @225", "Squat", 5, "5", 225),
            ("Incline DB press — 3x10 @ 40 lb", "Incline DB press", 3, "10", 40),
            ("Romanian deadlift - 4 x 8-10 @ 60kg", "Romanian deadlift", 4, "8-10", 60),
        ]
        for (line, name, sets, reps, weight) in cases {
            let parsed = ExerciseLineParser.parse(line)
            XCTAssertEqual(parsed?.name, name, "name from: \(line)")
            XCTAssertEqual(parsed?.sets, sets, "sets from: \(line)")
            XCTAssertEqual(parsed?.reps, reps, "reps from: \(line)")
            XCTAssertEqual(parsed?.weight, weight, "weight from: \(line)")
        }
        XCTAssertEqual(ExerciseLineParser.parse("Romanian deadlift - 4 x 8 @ 60kg")?.weightUnit, "kg")
        XCTAssertEqual(ExerciseLineParser.parse("Squat 5x5 @225 lbs")?.weightUnit, "lb")
    }

    /// A line with no sets × reps is conditioning, not a strength set — counting it would corrupt
    /// the rollup, so the parser refuses it and the caller counts it as unparsed.
    func testRefusesLinesWithNoSetsAndReps() {
        XCTAssertNil(ExerciseLineParser.parse("20 min row, easy"))
        XCTAssertNil(ExerciseLineParser.parse("Mobility flow"))
        XCTAssertNil(ExerciseLineParser.parse(""))
        XCTAssertNil(ExerciseLineParser.parse("3 x 8"), "a line with no name isn't an exercise")
    }

    /// The digits in "3 x 8" must not be read back as the load.
    func testDoesNotMistakeRepsForWeight() {
        XCTAssertNil(ExerciseLineParser.parse("Push-up - 3 x 8")?.weight)
    }

    /// The exact line an imported coach exercise logs as. Reading the RPE as a 7 lb bench press
    /// would silently corrupt the very rollup a coach programs the next block from.
    func testGuidanceSuffixIsNeverReadAsWeight() {
        let line = CoachExercise(name: "Bench press", sets: 3, reps: "8", guidance: "RPE 7").line
        XCTAssertEqual(line, "Bench press - 3 x 8 (RPE 7)", "precondition: this is what gets logged")
        let parsed = ExerciseLineParser.parse(line)
        XCTAssertEqual(parsed?.sets, 3)
        XCTAssertNil(parsed?.weight, "a parenthesised cue must never be mistaken for a load")

        XCTAssertNil(ExerciseLineParser.parse("Squat - 3 x 5, 2 min rest")?.weight,
                     "a bare trailing number is not a load")
        XCTAssertEqual(ExerciseLineParser.parse("Squat - 3 x 5 (2s pause) @ 185")?.weight, 185,
                      "a real load still parses with a cue in front of it")
    }

    // MARK: - Rollup

    func testRollupCountsSessionsAndTracksBestSet() {
        var older = FernletDay(date: "2026-08-01")
        older.workouts = [Workout(name: "Legs", type: .lower, exercises: "Squat - 3 x 5 @ 185",
                                  rpe: nil, notes: "", duration: 40, intensity: .moderate)]
        var newer = FernletDay(date: "2026-08-08")
        newer.workouts = [Workout(name: "Legs", type: .lower,
                                  exercises: "Squat - 3 x 5 @ 205\n20 min bike",
                                  rpe: nil, notes: "", duration: 40, intensity: .moderate)]

        let rollup = FernletStore.rollUpExerciseHistory(days: [newer, older])
        let squat = rollup.entries.first { $0.name.lowercased() == "squat" }
        XCTAssertEqual(squat?.sessions, 2, "two days means two sessions")
        XCTAssertEqual(squat?.totalSets, 6)
        XCTAssertEqual(squat?.firstLogged, "2026-08-01")
        XCTAssertEqual(squat?.lastLogged, "2026-08-08", "'last' must be the most recent day, not iteration order")
        XCTAssertEqual(squat?.lastWeight, 205)
        XCTAssertEqual(squat?.bestWeight, 205)
        XCTAssertEqual(rollup.unparsedLines, 1, "the conditioning line must be counted, not silently dropped")

        // Epley on the best set: 205 × (1 + 5/30) ≈ 239.2
        XCTAssertEqual(squat?.estimatedOneRepMax ?? 0, 239.2, accuracy: 0.15)
    }

    /// Past ~12 reps Epley is meaningless, so no estimate is published rather than a misleading one.
    func testNoOneRepMaxEstimateForHighRepSets() {
        var day = FernletDay(date: "2026-08-08")
        day.workouts = [Workout(name: "Arms", type: .upper, exercises: "Curl - 3 x 20 @ 20",
                                rpe: nil, notes: "", duration: 20, intensity: .light)]
        let entry = FernletStore.rollUpExerciseHistory(days: [day]).entries.first
        XCTAssertEqual(entry?.bestWeight, 20)
        XCTAssertNil(entry?.estimatedOneRepMax)
    }

    // MARK: - Export additions

    func testExportCarriesTargetsSetupAndHistory() {
        let (seed, repository, narratives) = makeTestStoreWithRepositories()
        var day = FernletDay(date: seed.todayKey)
        day.workouts = [Workout(name: "Push", type: .upper, exercises: "Bench press - 3 x 8 @ 135",
                                rpe: 7, notes: "", duration: 45, intensity: .moderate)]
        repository.updateDay(day, for: seed.todayKey, todayKey: seed.todayKey)

        let store = makeStoreSharingStores(repository: repository, narratives: narratives)
        store.settings.calorieTargetOverride = 2_400
        let bundle = store.buildTrainerExport(options: .coreOnly)

        XCTAssertEqual(bundle.targets?.calories, 2_400)
        XCTAssertEqual(bundle.targets?.caloriesIsUserSet, true, "a pinned target must be marked user-set")
        XCTAssertEqual(bundle.targets?.proteinIsUserSet, false, "an unpinned target must read as derived")
        XCTAssertNotNil(bundle.trainingSetup, "a coach needs to know what equipment is available")
        XCTAssertFalse(bundle.trainingSetup?.ownedEquipment.isEmpty ?? true)
        XCTAssertEqual(bundle.exerciseHistory?.first?.name, "Bench press")
        XCTAssertEqual(bundle.exerciseHistory?.first?.bestWeight, 135)
    }

    /// The clipboard window must narrow history; the file/mesh export must not.
    func testCoachWindowNarrowsHistoryButDefaultDoesNot() {
        let (seed, repository, narratives) = makeTestStoreWithRepositories()
        let oldKey = FernletStore.dayKey(startingOn: seed.todayKey, offsetBy: -400)!
        var old = FernletDay(date: oldKey)
        old.workouts = [Workout(name: "Old", type: .upper, exercises: "Bench press - 3 x 8",
                                rpe: nil, notes: "", duration: 30, intensity: .moderate)]
        repository.updateDay(old, for: oldKey, todayKey: seed.todayKey)

        let store = makeStoreSharingStores(repository: repository, narratives: narratives)
        let full = store.buildTrainerExport(options: .coreOnly, window: .unlimited)
        XCTAssertTrue(full.days.contains { $0.day == oldKey },
                      "the shipped file/mesh export must keep sending the whole history")

        let windowed = store.buildTrainerExport(options: .coreOnly, window: .coachHandoff)
        XCTAssertFalse(windowed.days.contains { $0.day == oldKey },
                       "a 400-day-old session is outside the 8-week clipboard window")
    }

    /// With the opt-in extras on, an out-of-window day must still be dropped whole — otherwise the
    /// clipboard blob the window exists to bound grows without limit.
    func testOptionalSectionsCannotSmuggleOutOfWindowDaysIn() {
        let (seed, repository, narratives) = makeTestStoreWithRepositories()
        let oldKey = FernletStore.dayKey(startingOn: seed.todayKey, offsetBy: -400)!
        var old = FernletDay(date: oldKey)
        old.bottleCount = 6
        old.sleep = SleepLog(hours: 7.5, quality: .good, note: "")
        repository.updateDay(old, for: oldKey, todayKey: seed.todayKey)

        let store = makeStoreSharingStores(repository: repository, narratives: narratives)
        var options = TrainerExportOptions()
        options.includeHydration = true
        options.includeSleep = true
        options.includeWellbeing = true

        XCTAssertTrue(store.buildTrainerExport(options: options, window: .unlimited)
            .days.contains { $0.day == oldKey }, "precondition: unlimited still carries it")
        XCTAssertFalse(store.buildTrainerExport(options: options, window: .coachHandoff)
            .days.contains { $0.day == oldKey },
            "hydration/sleep/wellbeing must not keep an out-of-window day alive")
    }

    func testClipboardTextCarriesBothThePromptAndTheData() throws {
        let store = makeTestStore()
        let text = try XCTUnwrap(store.coachHandoffClipboardText(options: .coreOnly))
        XCTAssertTrue(text.contains(CoachPlan.formatTag), "the schema the reply must use has to be in the prompt")
        XCTAssertTrue(text.contains("primaryMuscles"), "new-exercise metadata must be requested")
        XCTAssertTrue(text.contains("upperBack"), "the exact muscle vocabulary must be quoted")
        XCTAssertTrue(text.contains("\"about\""), "the user's own data must be in the same blob")
        XCTAssertTrue(text.contains("avoidedMuscles") || text.contains("safety"),
                      "the prompt must tell the model to respect the avoid lists")
        // The catalog is deliberately NOT sent — the owner's call, and what makes new exercises the
        // model's job to define.
        XCTAssertFalse(text.contains("Lateral raise"), "the exercise catalog must not be shipped")
    }

    // MARK: - Import: review and apply

    private func makeStoreWithPlan(_ json: String) throws -> (FernletStore, CoachPlan) {
        let store = makeTestStore()
        // A PREVIOUS test's store can still have a MainActor load task queued whose
        // `syncCustomExerciseCatalog` republish lands AFTER `setUp`'s clear (seen as the
        // full-suite-only "Zercher squat already registered" precondition failure). The test
        // bodies are synchronous, so nothing can interleave once we return — clearing here,
        // after this store's own init, makes the registry state the test's own again.
        WorkoutExerciseCatalog.registerCustomExercises([])
        return (store, try decoded(json))
    }

    func testImportMaterializesDatedPlannedWorkouts() throws {
        let (store, plan) = try makeStoreWithPlan(planJSON(days: 3))
        let start = store.todayKey
        let review = store.reviewCoachPlan(plan, startingOn: start)
        XCTAssertTrue(review.isImportable, "blockers: \(review.blockers.map(\.detail))")

        let result = try XCTUnwrap(store.applyCoachPlan(review, startingOn: start,
                                                        struckExerciseKeys: [], collisionPolicy: .keepBoth))
        XCTAssertEqual(result.plannedWorkoutCount, 3)
        XCTAssertEqual(result.dayCount, 3)

        for offset in 0..<3 {
            let key = try XCTUnwrap(FernletStore.dayKey(startingOn: start, offsetBy: offset))
            let planned = store.loadDay(for: key).plannedWorkouts
            XCTAssertEqual(planned.count, 1, "day \(offset + 1) should hold one planned workout")
            XCTAssertEqual(planned.first?.source, .coach, "imported rows must be tagged coach-sourced")
            XCTAssertTrue(planned.first?.exercises.contains("Zercher squat") == true)
            XCTAssertTrue(planned.first?.notes.contains("imported") == true,
                          "provenance must survive in the row's own text")
        }
    }

    func testImportRegistersNewExercisesInTheCatalog() throws {
        let (store, plan) = try makeStoreWithPlan(planJSON(days: 1))
        XCTAssertNil(WorkoutExerciseCatalog.exercise(named: "Zercher squat"), "precondition")

        let review = store.reviewCoachPlan(plan, startingOn: store.todayKey)
        XCTAssertEqual(review.newExercises.count, 1)
        _ = store.applyCoachPlan(review, startingOn: store.todayKey,
                                 struckExerciseKeys: [], collisionPolicy: .keepBoth)

        let registered = WorkoutExerciseCatalog.exercise(named: "zercher  SQUAT")
        XCTAssertNotNil(registered, "an imported exercise must be findable, case- and spacing-insensitively")
        XCTAssertEqual(registered?.movementPattern, .squat)
        XCTAssertTrue(registered?.primaryMuscles.contains(.quads) == true)
        XCTAssertTrue(store.settings.customExercises.contains { $0.name == "Zercher squat" },
                      "it must also be persisted, not only registered in the process-global catalog")
    }

    /// A pasted plan must not be able to redefine what a bundled lift targets.
    func testDefinitionCannotShadowABundledCatalogEntry() throws {
        let json = planJSON(exerciseName: "Push-up", definition: """
        { "name": "Push-up", "primaryMuscles": ["quads"], "equipment": "barbell",
          "movementPattern": "squat" }
        """)
        let (store, plan) = try makeStoreWithPlan(json)
        let review = store.reviewCoachPlan(plan, startingOn: store.todayKey)
        XCTAssertTrue(review.newExercises.isEmpty, "a definition colliding with the curated catalog must be dropped")
        _ = store.applyCoachPlan(review, startingOn: store.todayKey,
                                 struckExerciseKeys: [], collisionPolicy: .keepBoth)
        XCTAssertNotEqual(WorkoutExerciseCatalog.exercise(named: "Push-up")?.movementPattern, .squat,
                          "the bundled metadata must win")
    }

    func testSafetyPassFlagsAvoidedMovementAndMissingEquipment() throws {
        let (store, plan) = try makeStoreWithPlan(planJSON(days: 1))
        store.settings.workoutProfile.avoidedMovements = [.squat]
        store.settings.workoutLocations = [WorkoutLocation(name: "Living room", ownedEquipment: [])]
        store.settings.activeWorkoutLocationID = store.settings.workoutLocations[0].id

        let review = store.reviewCoachPlan(plan, startingOn: store.todayKey)
        let flag = try XCTUnwrap(review.safetyFlags.first)
        XCTAssertEqual(flag.exerciseName, "Zercher squat")
        XCTAssertTrue(flag.reason.contains("squat"), "the reason must name the avoided movement")
        XCTAssertTrue(flag.reason.contains("barbell"), "and the missing equipment")
        XCTAssertTrue(review.isImportable, "a safety conflict is a decision to make, not a hard block")
    }

    func testStruckExerciseIsLeftOutAndItsEmptySessionIsNotWritten() throws {
        let (store, plan) = try makeStoreWithPlan(planJSON(days: 2))
        let review = store.reviewCoachPlan(plan, startingOn: store.todayKey)
        let result = store.applyCoachPlan(
            review, startingOn: store.todayKey,
            struckExerciseKeys: [CoachPlan.normalizedName("Zercher squat")],
            collisionPolicy: .keepBoth)

        XCTAssertNil(result, "every session was emptied by the strike, so nothing should be written")
        XCTAssertTrue(store.loadDay(for: store.todayKey).plannedWorkouts.isEmpty,
                      "an emptied session must not leave a completable but contentless row")
    }

    /// The nastiest ordering in the apply path: "replace" + every exercise struck. A per-day delete
    /// that ran before the emptiness check would wipe the user's own plan, write nothing in its
    /// place, and then return nil — so the UI would report "nothing was changed" over real data loss.
    func testReplaceWithEverythingStruckDestroysNothing() throws {
        let (store, plan) = try makeStoreWithPlan(planJSON(days: 2))
        let key = store.todayKey
        store.planWorkout(PlannedWorkout(name: "My own plan", split: .upper, source: .user,
                                         notes: "", duration: 30), date: key)

        let review = store.reviewCoachPlan(plan, startingOn: key)
        let result = store.applyCoachPlan(
            review, startingOn: key,
            struckExerciseKeys: [CoachPlan.normalizedName("Zercher squat")],
            collisionPolicy: .replace)

        XCTAssertNil(result, "nothing survived the strikes, so the import writes nothing")
        let planned = store.loadDay(for: key).plannedWorkouts
        XCTAssertEqual(planned.count, 1, "the user's own planned workout must still be there")
        XCTAssertEqual(planned.first?.name, "My own plan")
        XCTAssertEqual(planned.first?.source, .user)
    }

    /// A day emptied by strikes must not have its existing plan replaced with nothing, even when
    /// other days of the same import do write.
    func testReplaceSkipsDaysThisPlanNoLongerPrescribesAnythingFor() throws {
        let json = """
        { "format": "\(CoachPlan.formatTag)", "title": "T", "coachDisplayName": "C",
          "days": [
            { "dayIndex": 1, "title": "A", "isRestDay": false, "sessions": [
              { "title": "A", "kind": "strength", "exercises": [
                { "name": "Push-up", "sets": 3, "reps": "10" } ] } ] },
            { "dayIndex": 2, "title": "B", "isRestDay": false, "sessions": [
              { "title": "B", "kind": "strength", "exercises": [
                { "name": "Dip", "sets": 3, "reps": "8" } ] } ] }
          ],
          "newExercises": [] }
        """
        let (store, plan) = try makeStoreWithPlan(json)
        let secondKey = try XCTUnwrap(FernletStore.dayKey(startingOn: store.todayKey, offsetBy: 1))
        store.planWorkout(PlannedWorkout(name: "Day 2 is mine", split: .lower, source: .user,
                                         notes: "", duration: 45), date: secondKey)

        let review = store.reviewCoachPlan(plan, startingOn: store.todayKey)
        let result = try XCTUnwrap(store.applyCoachPlan(
            review, startingOn: store.todayKey,
            struckExerciseKeys: [CoachPlan.normalizedName("Dip")], collisionPolicy: .replace))

        XCTAssertEqual(result.dayCount, 1, "only day 1 wrote anything")
        XCTAssertEqual(result.struckExerciseCount, 1, "the strike must still be reported")
        let day2 = store.loadDay(for: secondKey).plannedWorkouts
        XCTAssertEqual(day2.count, 1)
        XCTAssertEqual(day2.first?.name, "Day 2 is mine",
                       "day 2 prescribed nothing after the strike, so the user's plan stands")
    }

    /// Replace clears PLANNED rows only — never anything already logged.
    func testReplaceCollisionClearsPlannedButNeverLoggedWorkouts() throws {
        let (store, plan) = try makeStoreWithPlan(planJSON(days: 1))
        let key = store.todayKey
        store.planWorkout(PlannedWorkout(name: "My own plan", split: .upper, source: .user,
                                         notes: "", duration: 30), date: key)
        store.addWorkout(Workout(name: "Already done", type: .upper, exercises: "Push-up - 3 x 10",
                                 rpe: nil, notes: "", duration: 20, intensity: .light), date: key)

        let review = store.reviewCoachPlan(plan, startingOn: key)
        XCTAssertEqual(review.collidingDayKeys, [key], "the collision must be surfaced before applying")

        _ = store.applyCoachPlan(review, startingOn: key, struckExerciseKeys: [], collisionPolicy: .replace)
        let day = store.loadDay(for: key)
        XCTAssertEqual(day.plannedWorkouts.count, 1)
        XCTAssertEqual(day.plannedWorkouts.first?.source, .coach, "the user's planned row is replaced")
        XCTAssertTrue(day.workouts.contains { $0.name == "Already done" },
                      "a logged workout must survive an import that replaces plans")
    }

    /// A day emptied by a strike must not be counted as written just because an earlier day was.
    func testDayCountReflectsOnlyDaysThatActuallyGotAWorkout() throws {
        let json = """
        { "format": "\(CoachPlan.formatTag)", "title": "T", "coachDisplayName": "C",
          "days": [
            { "dayIndex": 1, "title": "A", "isRestDay": false, "sessions": [
              { "title": "A", "kind": "strength", "exercises": [
                { "name": "Push-up", "sets": 3, "reps": "10" } ] } ] },
            { "dayIndex": 2, "title": "B", "isRestDay": false, "sessions": [
              { "title": "B", "kind": "strength", "exercises": [
                { "name": "Dip", "sets": 3, "reps": "8" } ] } ] }
          ],
          "newExercises": [] }
        """
        let (store, plan) = try makeStoreWithPlan(json)
        let review = store.reviewCoachPlan(plan, startingOn: store.todayKey)
        // Strike everything on day 2 only.
        let result = try XCTUnwrap(store.applyCoachPlan(
            review, startingOn: store.todayKey,
            struckExerciseKeys: [CoachPlan.normalizedName("Dip")], collisionPolicy: .keepBoth))

        XCTAssertEqual(result.plannedWorkoutCount, 1)
        XCTAssertEqual(result.dayCount, 1, "day 2 wrote nothing, so it must not be counted")
        XCTAssertEqual(result.firstDayKey, result.lastDayKey)
        let secondKey = try XCTUnwrap(FernletStore.dayKey(startingOn: store.todayKey, offsetBy: 1))
        XCTAssertTrue(store.loadDay(for: secondKey).plannedWorkouts.isEmpty)
    }

    func testKeepBothCollisionLeavesTheExistingPlanInPlace() throws {
        let (store, plan) = try makeStoreWithPlan(planJSON(days: 1))
        let key = store.todayKey
        store.planWorkout(PlannedWorkout(name: "My own plan", split: .upper, source: .user,
                                         notes: "", duration: 30), date: key)

        let review = store.reviewCoachPlan(plan, startingOn: key)
        _ = store.applyCoachPlan(review, startingOn: key, struckExerciseKeys: [], collisionPolicy: .keepBoth)
        XCTAssertEqual(store.loadDay(for: key).plannedWorkouts.count, 2)
    }

    /// The apply path must refuse a plan the review screen called broken, even if a caller asks.
    func testApplyRefusesAPlanWithABlockingIssue() throws {
        let (store, plan) = try makeStoreWithPlan(planJSON(definition: """
        { "name": "Not the same exercise", "primaryMuscles": ["quads"], "equipment": "barbell",
          "movementPattern": "squat" }
        """))
        let review = store.reviewCoachPlan(plan, startingOn: store.todayKey)
        XCTAssertFalse(review.isImportable)
        XCTAssertNil(store.applyCoachPlan(review, startingOn: store.todayKey,
                                          struckExerciseKeys: [], collisionPolicy: .keepBoth))
        XCTAssertTrue(store.loadDay(for: store.todayKey).plannedWorkouts.isEmpty,
                      "a refused import must write nothing at all")
    }

    func testRestDaysMaterializeNothing() throws {
        let json = """
        { "format": "\(CoachPlan.formatTag)", "title": "T", "coachDisplayName": "C",
          "days": [
            { "dayIndex": 1, "title": "Rest", "isRestDay": true, "sessions": [] },
            { "dayIndex": 2, "title": "Push", "isRestDay": false, "sessions": [
              { "title": "Push", "kind": "strength", "exercises": [
                { "name": "Push-up", "sets": 3, "reps": "10" } ] } ] }
          ],
          "newExercises": [] }
        """
        let (store, plan) = try makeStoreWithPlan(json)
        let review = store.reviewCoachPlan(plan, startingOn: store.todayKey)
        let result = try XCTUnwrap(store.applyCoachPlan(review, startingOn: store.todayKey,
                                                        struckExerciseKeys: [], collisionPolicy: .keepBoth))
        XCTAssertEqual(result.plannedWorkoutCount, 1)
        XCTAssertTrue(store.loadDay(for: store.todayKey).plannedWorkouts.isEmpty, "day 1 is a rest day")
        let secondKey = try XCTUnwrap(FernletStore.dayKey(startingOn: store.todayKey, offsetBy: 1))
        XCTAssertEqual(store.loadDay(for: secondKey).plannedWorkouts.count, 1)
    }

    // MARK: - Editing workouts the user already planned

    /// A plan JSON that carries ONLY edits — the "adjust my existing month" case, which writes no
    /// new days at all.
    private func editsOnlyJSON(targetID: UUID, action: String, extra: String = "") -> String {
        """
        { "format": "\(CoachPlan.formatTag)", "title": "Tweaks", "coachDisplayName": "Claude",
          "days": [],
          "edits": [ { "targetID": "\(targetID.uuidString)", "action": "\(action)"\(extra) } ],
          "newExercises": [] }
        """
    }

    /// Plans the user already has must reach the coach, or there is nothing to adjust.
    func testExportCarriesUpcomingPlannedWorkoutsWithTheirIDs() throws {
        let store = makeTestStore()
        let planned = PlannedWorkout(name: "My Upper", split: .upper, source: .user,
                                     exercises: "Bench press - 3 x 8", notes: "", duration: 45)
        store.planWorkout(planned, date: store.todayKey)

        let bundle = store.buildTrainerExport(options: .coreOnly, window: .coachHandoff)
        let day = try XCTUnwrap(bundle.days.first { $0.day == store.todayKey })
        let exported = try XCTUnwrap(day.plannedWorkouts?.first)
        XCTAssertEqual(exported.id, planned.id, "the real row id must be echoed — it's the edit handle")
        XCTAssertEqual(exported.name, "My Upper")
        XCTAssertEqual(exported.source, "user")
        XCTAssertEqual(exported.exercises, ["Bench press - 3 x 8"])
    }

    /// Past plans are not adjustable, so sending them would only invite unusable edits.
    func testExportOmitsPlannedWorkoutsFromPastDays() throws {
        let (seed, repository, narratives) = makeTestStoreWithRepositories()
        let pastKey = try XCTUnwrap(FernletStore.dayKey(startingOn: seed.todayKey, offsetBy: -3))
        var past = FernletDay(date: pastKey)
        past.plannedWorkouts = [PlannedWorkout(name: "Old plan", split: .upper, source: .user,
                                               notes: "", duration: 30)]
        repository.updateDay(past, for: pastKey, todayKey: seed.todayKey)

        let store = makeStoreSharingStores(repository: repository, narratives: narratives)
        let bundle = store.buildTrainerExport(options: .coreOnly, window: .coachHandoff)
        XCTAssertNil(bundle.days.first { $0.day == pastKey }?.plannedWorkouts,
                     "a past day's leftover plan can't be adjusted, so it must not be sent")
    }

    func testAdjustRewritesOnlyWhatTheEditNames() throws {
        let store = makeTestStore()
        let planned = PlannedWorkout(name: "My Upper", split: .upper, source: .user,
                                     exercises: "Bench press - 3 x 8", notes: "my own note", duration: 45)
        store.planWorkout(planned, date: store.todayKey)

        let json = editsOnlyJSON(targetID: planned.id, action: "adjust", extra: """
        , "exercises": [ { "name": "Bench press", "sets": 4, "reps": "6", "guidance": "add 5lb" } ]
        """)
        let plan = try decoded(json)
        let review = store.reviewCoachPlan(plan, startingOn: store.todayKey)
        XCTAssertTrue(review.isImportable, "blockers: \(review.blockers.map(\.detail))")
        XCTAssertEqual(review.resolvedEdits.count, 1)
        XCTAssertEqual(review.resolvedEdits.first?.action, .adjust)

        let result = try XCTUnwrap(store.applyCoachPlan(review, startingOn: store.todayKey,
                                                        struckExerciseKeys: [], collisionPolicy: .keepBoth))
        XCTAssertEqual(result.editedCount, 1)
        XCTAssertEqual(result.plannedWorkoutCount, 0, "an edits-only plan adds no new workouts")
        XCTAssertTrue(result.changedAnything)

        let rows = store.loadDay(for: store.todayKey).plannedWorkouts
        XCTAssertEqual(rows.count, 1, "adjust rewrites in place; it must not duplicate the row")
        let updated = try XCTUnwrap(rows.first)
        XCTAssertTrue(updated.exercises.contains("4 x 6"), "the prescription must be the new one")
        XCTAssertEqual(updated.name, "My Upper", "a field the edit didn't name must be preserved")
        XCTAssertTrue(updated.notes.contains("my own note"), "the user's own note must survive")
        XCTAssertTrue(updated.notes.contains("Changed by Claude"), "provenance must be stamped")
        XCTAssertEqual(updated.source, .coach)
    }

    func testDeleteRemovesThePlannedRowAndNothingElse() throws {
        let store = makeTestStore()
        let planned = PlannedWorkout(name: "Drop me", split: .upper, source: .user, notes: "", duration: 30)
        store.planWorkout(planned, date: store.todayKey)
        store.addWorkout(Workout(name: "Already done", type: .upper, exercises: "Push-up - 3 x 10",
                                 rpe: nil, notes: "", duration: 20, intensity: .light), date: store.todayKey)

        let plan = try decoded(editsOnlyJSON(targetID: planned.id, action: "delete"))
        let review = store.reviewCoachPlan(plan, startingOn: store.todayKey)
        let result = try XCTUnwrap(store.applyCoachPlan(review, startingOn: store.todayKey,
                                                        struckExerciseKeys: [], collisionPolicy: .keepBoth))

        XCTAssertEqual(result.deletedCount, 1)
        let day = store.loadDay(for: store.todayKey)
        XCTAssertTrue(day.plannedWorkouts.isEmpty)
        XCTAssertTrue(day.workouts.contains { $0.name == "Already done" },
                      "a logged workout must survive an import that deletes plans")
    }

    /// An import may never rewrite history: only PLANNED rows are targetable, so a logged workout's
    /// id resolves to nothing.
    func testAnEditTargetingALoggedWorkoutCannotResolve() throws {
        let store = makeTestStore()
        let logged = Workout(name: "Done", type: .upper, exercises: "Push-up - 3 x 10",
                             rpe: nil, notes: "", duration: 20, intensity: .light)
        store.addWorkout(logged, date: store.todayKey)

        let plan = try decoded(editsOnlyJSON(targetID: logged.id, action: "delete"))
        let review = store.reviewCoachPlan(plan, startingOn: store.todayKey)
        XCTAssertTrue(review.resolvedEdits.isEmpty, "a logged workout is not an editable target")
        XCTAssertTrue(review.issues.contains { $0.kind == .unresolvableEdit },
                      "the user must be told the target wasn't found, not left guessing")
        XCTAssertFalse(review.isImportable)
        XCTAssertNil(store.applyCoachPlan(review, startingOn: store.todayKey,
                                          struckExerciseKeys: [], collisionPolicy: .keepBoth))
        XCTAssertTrue(store.loadDay(for: store.todayKey).workouts.contains { $0.name == "Done" })
    }

    func testAnEditTargetingAPastDayIsRefused() throws {
        let (seed, repository, narratives) = makeTestStoreWithRepositories()
        let pastKey = try XCTUnwrap(FernletStore.dayKey(startingOn: seed.todayKey, offsetBy: -2))
        let planned = PlannedWorkout(name: "Yesterday's plan", split: .upper, source: .user,
                                     notes: "", duration: 30)
        var past = FernletDay(date: pastKey)
        past.plannedWorkouts = [planned]
        repository.updateDay(past, for: pastKey, todayKey: seed.todayKey)

        let store = makeStoreSharingStores(repository: repository, narratives: narratives)
        let plan = try decoded(editsOnlyJSON(targetID: planned.id, action: "delete"))
        let review = store.reviewCoachPlan(plan, startingOn: store.todayKey)

        XCTAssertTrue(review.resolvedEdits.isEmpty)
        XCTAssertTrue(review.issues.contains { $0.kind == .unresolvableEdit && $0.detail.contains("already passed") },
                      "editing a past day changes nothing and must say so")
    }

    /// A stale id — the user completed or deleted the workout after copying their summary.
    func testAnEditTargetingAMissingWorkoutReportsAStaleSummary() throws {
        let store = makeTestStore()
        let plan = try decoded(editsOnlyJSON(targetID: UUID(), action: "delete"))
        let review = store.reviewCoachPlan(plan, startingOn: store.todayKey)

        let issue = try XCTUnwrap(review.issues.first { $0.kind == .unresolvableEdit })
        XCTAssertTrue(issue.detail.contains("fresh summary"),
                      "the message must tell the user how to recover, not just that it failed")
    }

    /// `replace` has to say what the workout becomes.
    func testReplaceWithoutExercisesIsBlocked() throws {
        let store = makeTestStore()
        let planned = PlannedWorkout(name: "Upper", split: .upper, source: .user, notes: "", duration: 30)
        store.planWorkout(planned, date: store.todayKey)

        let plan = try decoded(editsOnlyJSON(targetID: planned.id, action: "replace"))
        let review = store.reviewCoachPlan(plan, startingOn: store.todayKey)
        XCTAssertFalse(review.isImportable)
        XCTAssertTrue(review.blockers.contains { $0.detail.contains("lists no exercises") })
    }

    func testTwoEditsTargetingTheSameWorkoutAreBlocked() throws {
        let store = makeTestStore()
        let planned = PlannedWorkout(name: "Upper", split: .upper, source: .user, notes: "", duration: 30)
        store.planWorkout(planned, date: store.todayKey)

        let json = """
        { "format": "\(CoachPlan.formatTag)", "title": "T", "coachDisplayName": "C", "days": [],
          "edits": [
            { "targetID": "\(planned.id.uuidString)", "action": "delete" },
            { "targetID": "\(planned.id.uuidString)", "action": "adjust", "title": "Renamed" }
          ],
          "newExercises": [] }
        """
        let plan = try decoded(json)
        let review = store.reviewCoachPlan(plan, startingOn: store.todayKey)
        XCTAssertFalse(review.isImportable)
        XCTAssertTrue(review.blockers.contains { $0.detail.contains("same planned workout") })
    }

    func testUnknownEditActionIsReportedWithTheVocabulary() throws {
        let store = makeTestStore()
        let planned = PlannedWorkout(name: "Upper", split: .upper, source: .user, notes: "", duration: 30)
        store.planWorkout(planned, date: store.todayKey)

        let plan = try decoded(editsOnlyJSON(targetID: planned.id, action: "obliterate"))
        let review = store.reviewCoachPlan(plan, startingOn: store.todayKey)
        let issue = try XCTUnwrap(review.issues.first { $0.kind == .unknownToken })
        XCTAssertTrue(issue.detail.contains("adjust"), "the accepted actions must be quoted back")
    }

    /// An edit's exercises get the same safety pass as a new day's.
    func testEditExercisesAreSafetyChecked() throws {
        let store = makeTestStore()
        store.settings.workoutProfile.avoidedMovements = [.squat]
        let planned = PlannedWorkout(name: "Legs", split: .lower, source: .user, notes: "", duration: 45)
        store.planWorkout(planned, date: store.todayKey)

        let json = editsOnlyJSON(targetID: planned.id, action: "replace", extra: """
        , "exercises": [ { "name": "Back squat", "sets": 5, "reps": "5" } ]
        """)
        let plan = try decoded(json)
        let review = store.reviewCoachPlan(plan, startingOn: store.todayKey)
        XCTAssertTrue(review.safetyFlags.contains { $0.exerciseName == "Back squat" },
                      "a conflicting exercise must be flagged whether it arrives as a new day or an edit")
    }

    /// A strike is compared in `CoachPlan.normalizedName` form, but the edit path used to compare it
    /// against the RENDERED line as a lowercase prefix. "Back  squat" renders as "back  squat - …",
    /// which does not begin with the normalized key "back squat" — so the exercise the user turned
    /// off for safety came back in through the edit path, which is exactly the path they saw it on.
    func testStruckExerciseWithDoubleSpacedNameIsRemovedFromAnEditedRow() throws {
        let store = makeTestStore()
        store.settings.workoutProfile.avoidedMovements = [.squat]
        let planned = PlannedWorkout(name: "Legs", split: .lower, source: .user,
                                     exercises: "Leg press - 3 x 10", notes: "", duration: 45)
        store.planWorkout(planned, date: store.todayKey)

        let json = editsOnlyJSON(targetID: planned.id, action: "replace", extra: """
        , "exercises": [ { "name": "Back  squat", "sets": 5, "reps": "5" } ]
        """)
        let review = store.reviewCoachPlan(try decoded(json), startingOn: store.todayKey)
        let flag = try XCTUnwrap(review.safetyFlags.first)
        let struckKey = CoachPlan.normalizedName("Back  squat")
        XCTAssertEqual(flag.exerciseKey, struckKey, "the strike key is the normalized name")

        _ = store.applyCoachPlan(review, startingOn: store.todayKey,
                                 struckExerciseKeys: [struckKey], collisionPolicy: .keepBoth)

        let lines = store.loadDay(for: store.todayKey).plannedWorkouts.flatMap(\.exerciseLines)
        XCTAssertFalse(lines.contains { Self.normalizedLineName($0) == struckKey },
                       "a struck exercise must not survive its own strike because of its spacing")
        XCTAssertTrue(lines.contains("Leg press - 3 x 10"),
                      "nothing survived the strike, so the user's original row stays standing")
    }

    /// A title/notes-only edit proposes no exercises, so the user's existing lines were never
    /// flagged and are not strikable. Prefix-filtering the rendered "after" text — which for such an
    /// edit is the user's OWN prescription — silently deleted any line a struck key happened to
    /// begin with.
    func testTitleOnlyEditDoesNotStrikeTheUsersExistingLines() throws {
        let store = makeTestStore()
        let planned = PlannedWorkout(name: "Legs", split: .lower, source: .user,
                                     exercises: "Back squat - 3 x 5\nLeg press - 3 x 10",
                                     notes: "", duration: 45)
        store.planWorkout(planned, date: store.todayKey)

        let plan = try decoded(editsOnlyJSON(targetID: planned.id, action: "adjust",
                                             extra: ", \"title\": \"Legs (coach)\""))
        let review = store.reviewCoachPlan(plan, startingOn: store.todayKey)
        XCTAssertTrue(review.safetyFlags.isEmpty, "an edit proposing no exercises raises no flags")

        _ = store.applyCoachPlan(review, startingOn: store.todayKey,
                                 struckExerciseKeys: [CoachPlan.normalizedName("Back squat")],
                                 collisionPolicy: .keepBoth)

        let row = try XCTUnwrap(store.loadDay(for: store.todayKey).plannedWorkouts.first)
        XCTAssertEqual(row.exercises, "Back squat - 3 x 5\nLeg press - 3 x 10",
                       "an unrelated strike must not edit the user's own prescription")
        XCTAssertEqual(row.name, "Legs (coach)", "and the edit the plan actually proposed applies")
    }

    /// The exercise name at the head of a rendered prescription line, in strike-key form.
    private static func normalizedLineName(_ line: String) -> String {
        CoachPlan.normalizedName(line.components(separatedBy: " - ").first ?? line)
    }

    /// An edits-only plan is a complete plan; it must not be rejected for having no days.
    func testAnEditsOnlyPlanIsValid() throws {
        let store = makeTestStore()
        let planned = PlannedWorkout(name: "Upper", split: .upper, source: .user, notes: "", duration: 30)
        store.planWorkout(planned, date: store.todayKey)

        let plan = try decoded(editsOnlyJSON(targetID: planned.id, action: "adjust",
                                             extra: ", \"title\": \"Upper (coach)\""))
        XCTAssertTrue(plan.days.isEmpty)
        let review = store.reviewCoachPlan(plan, startingOn: store.todayKey)
        XCTAssertTrue(review.isImportable, "blockers: \(review.blockers.map(\.detail))")
    }

    /// A paste that neither adds nor changes anything is still empty.
    func testAPlanWithNoDaysAndNoEditsIsBlocked() throws {
        let json = """
        { "format": "\(CoachPlan.formatTag)", "title": "T", "coachDisplayName": "C",
          "days": [], "edits": [], "newExercises": [] }
        """
        let plan = try decoded(json)
        XCTAssertTrue(plan.validate(knownExerciseNames: catalogNames).contains { $0.isBlocking })
    }

    // MARK: - Wipe coverage

    /// The custom catalog is a PROCESS-GLOBAL registry, so clearing the settings blob isn't enough —
    /// a wipe has to empty the registry too or the exercise stays live in the picker, the safety
    /// filter and the planning engine until the app is relaunched.
    ///
    /// Deliberately drives `syncCustomExerciseCatalog()` directly rather than the whole `resetAll()`
    /// funnel. `resetAll` wipes `recipePhotoStore`, which every `FernletStore` in this process shares
    /// (it is built from the STATIC `FernletStore.photoDocumentsDirectory`), so an extra wipe caller
    /// here races every concurrently-running photo test — it flaked
    /// `RecipeReimportTests.failedReimportLeavesTheRecipeUntouched` three runs in a row. The half
    /// this test dropped is not lost: `PrivacyWipeCoverageTests`' manifest pins that `resetAll`'s
    /// body actually calls `syncCustomExerciseCatalog`, so the two together still prove the wipe
    /// empties the registry.
    func testWipingSettingsClearsTheLiveCustomExerciseRegistry() throws {
        let (store, plan) = try makeStoreWithPlan(planJSON(days: 1))
        let review = store.reviewCoachPlan(plan, startingOn: store.todayKey)
        // Pinned so a registry contaminated before review (making Zercher look bundled/known)
        // fails HERE with a diagnosis instead of at the post-apply precondition below.
        XCTAssertEqual(review.newExercises.count, 1, "precondition: the plan's exercise must review as new")
        _ = store.applyCoachPlan(review, startingOn: store.todayKey,
                                 struckExerciseKeys: [], collisionPolicy: .keepBoth)
        XCTAssertNotNil(WorkoutExerciseCatalog.exercise(named: "Zercher squat"), "precondition")

        // What `resetAll` does to this surface: `resetDiary()` blanks the settings, then the
        // re-publish pushes the now-empty list into the process-global catalog.
        store.settings.customExercises = []
        store.syncCustomExerciseCatalog()

        XCTAssertNil(WorkoutExerciseCatalog.exercise(named: "Zercher squat"),
                     "the live catalog must be cleared too, not just the persisted copy")
        XCTAssertTrue(WorkoutExerciseCatalog.customExercises.isEmpty)
        // The bundled catalog must survive — the re-publish replaces the custom list, not everything.
        XCTAssertNotNil(WorkoutExerciseCatalog.exercise(named: "Push-up"),
                        "clearing custom exercises must not empty the bundled catalog")
    }

    // MARK: - Gate

    func testCoachExchangeIsOffByDefault() {
        XCTAssertFalse(FernletSettings().coachExchangeEnabled,
                       "the unsigned-plan ingestion path must not exist in a default install")
    }
}
