import XCTest

// MARK: - VoiceOver dry run: the common tasks and Apple's fundamentals, end to end
//
// One test per task the VoiceOver row of `Docs/Accessibility-Nutrition-Labels.md` (§3) names —
// log a meal, log water, log a mood, complete a workout — plus the three fundamentals Apple's
// criterion also covers: onboarding, changing a setting, and finding help. Each one is walked with
// `VoiceOverWalk`: every control is found by what VoiceOver would announce (a label or an
// identifier), must be the kind of element VoiceOver can operate, and is activated through the
// element; every screen on the way is audited and its reading order attached.
//
// A green run here is the PRECONDITION for the owner's device pass, not a substitute for it. What
// it cannot hear — announcements, where the cursor lands after a sheet closes, the escape gesture,
// custom actions — is listed in `Docs/Handoff/a11y-2026-10-18/voiceover-device-pass.md`, step by
// step against these same paths.

final class VoiceOverTaskUITests: XCTestCase {
    override func setUpWithError() throws {
        // A task walk stops at its first broken step: later steps assume the earlier ones landed,
        // so continuing would bury the real failure under consequences of it.
        continueAfterFailure = false
    }

    // MARK: - Log water

    /// Both water paths: Home's one-tap add, then the water sheet's adjustable count.
    @MainActor
    func testLogWaterWithVoiceOverOnly() throws {
        let app = UXTestApp.launch()
        let walk = VoiceOverWalk(app, task: "Log water", in: self)
        try walk.audit("Home")

        // One tap from Home. The count it changes is drawn on the tile, so the button must carry
        // that count as its own value — the only thing VoiceOver can re-read after the double-tap.
        let quickAdd = walk.button("home.water.quickAdd")
        let before = try XCTUnwrap(quickAdd.value as? String, "the quick add carries no value — the add is silent")
        walk.activate(quickAdd)
        XCTAssertTrue(
            walk.waitForValue(of: quickAdd, toChangeFrom: before),
            "the quick add's value did not change after adding a bottle (still \(before))"
        )

        // The sheet: the count is one adjustable element whose value moves with each bottle.
        walk.activate(walk.button(labelStartingWith: "Water,"))
        walk.element("sheet.water")
        try walk.audit("Water sheet")
        let count = walk.element("water.count")
        XCTAssertEqual(count.label, "Water today")
        let sheetBefore = try XCTUnwrap(count.value as? String)
        walk.press("Add a bottle")
        XCTAssertTrue(
            walk.waitForValue(of: count, toChangeFrom: sheetBefore),
            "the water count's value did not move after Add a bottle"
        )
        let added = try XCTUnwrap(count.value as? String)
        XCTAssertEqual(walk.button("Add a bottle").value as? String, added,
                       "Add a bottle should carry the count it produced as its value")

        walk.press("sheet.done")
        XCTAssertTrue(app.descendants(matching: .any)["sheet.water"].waitForNonExistence(timeout: 6))
        XCTAssertTrue(walk.button(labelStartingWith: "Water,").label.hasSuffix(added),
                      "the Water tile does not read the count the sheet saved (\(added))")
    }

    // MARK: - Log a mood

    /// The one-tap check-in on Home, then a journal entry with a feeling.
    @MainActor
    func testLogAMoodWithVoiceOverOnly() throws {
        let app = UXTestApp.launch()
        let walk = VoiceOverWalk(app, task: "Log a mood", in: self)

        // Pick a mood that is not today's current one, so the double-tap is a real write.
        let tags = ["good", "quiet", "bright", "neutral", "tired", "hard"]
        let chip = try XCTUnwrap(
            tags.lazy.map { app.buttons["quickMood.\($0)"].firstMatch }.first { $0.exists && !$0.isSelected },
            "no unselected mood chip is reachable on Home"
        )
        walk.assertSpeaksWords(chip, describe: "mood chip")
        XCTAssertTrue(chip.label.hasPrefix("Mood: "), "a mood chip reads '\(chip.label)'")
        walk.activate(chip)
        XCTAssertTrue(chip.wait(for: \.isSelected, toEqual: true, timeout: 4),
                      "the chosen mood chip is not marked selected after the double-tap")
        try walk.audit("Home · mood logged")

        // A written entry with a feeling, through the Journal tile and its sheet.
        walk.activate(walk.button(labelStartingWith: "Journal,"))
        walk.element("sheet.journal")
        try walk.audit("Journal sheet")
        let feeling = walk.button("Bright")
        walk.activate(feeling)
        XCTAssertTrue(feeling.wait(for: \.isSelected, toEqual: true, timeout: 4))
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 4), "the journal editor is not reachable")
        walk.assertSpeaksWords(editor, describe: "journal editor")
        walk.type("A short walk after lunch.", into: editor)
        walk.press("Save")
        XCTAssertTrue(app.descendants(matching: .any)["sheet.journal"].waitForNonExistence(timeout: 6),
                      "the journal sheet did not close after Save")
    }

    // MARK: - Log a meal

    /// The catalog path, the meal-logged toast, and its Undo.
    @MainActor
    func testLogAMealWithVoiceOverOnly() throws {
        let app = UXTestApp.launch()
        let walk = VoiceOverWalk(app, task: "Log a meal", in: self)
        // Where a VoiceOver user starts — and, measured on the first run, the settle the first
        // double-tap needs: activated straight after the launch hand-over on a loaded Mac, the
        // tile's tap landed and no sheet came up.
        try walk.audit("Home")

        let tile = walk.button(labelStartingWith: "Meals,")
        let tileBefore = tile.label
        walk.activate(tile)
        walk.element("sheet.meal")
        try walk.audit("Meal sheet")

        let field = walk.element("mealComposer.search")
        XCTAssertEqual(field.label, "What did you eat?", "the meal field is named by its placeholder")
        walk.type("apple", into: field)
        // The results stack's identifier reaches each suggestion row (it is not an accessibility
        // container), so the first row is the first BUTTON carrying it.
        let suggestion = app.buttons["mealComposer.catalogResults"].firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 8), "no catalog suggestion is a button")
        walk.assertSpeaksWords(suggestion, describe: "catalog suggestion")
        walk.activate(suggestion)
        let chosen = walk.element("mealComposer.selectedCatalogFood")
        XCTAssertTrue(chosen.isSelected, "the chosen food does not read as selected")
        try walk.audit("Meal sheet · food chosen")

        walk.press("Save")
        XCTAssertTrue(app.descendants(matching: .any)["sheet.meal"].waitForNonExistence(timeout: 8),
                      "the meal sheet did not close after Save")
        let undo = walk.button("mealToast.undo")
        try walk.audit("Meal logged toast")
        XCTAssertNotEqual(walk.button(labelStartingWith: "Meals,").label, tileBefore,
                          "the Meals tile did not change after logging")

        walk.activate(undo)
        XCTAssertTrue(undo.waitForNonExistence(timeout: 4), "the toast stayed after Undo")
        XCTAssertEqual(walk.button(labelStartingWith: "Meals,").label, tileBefore,
                       "Undo did not take the meal back off the Meals tile")
    }

    // MARK: - Complete a workout

    /// A logged activity through the workout sheet.
    @MainActor
    func testLogAWorkoutWithVoiceOverOnly() throws {
        let app = UXTestApp.launch()
        let walk = VoiceOverWalk(app, task: "Log a workout", in: self)

        walk.press("Move")
        walk.element("screen.move")
        try walk.audit("Move tab")
        walk.press("Log")
        walk.element("sheet.workout")
        try walk.audit("Workout sheet")
        walk.press("workout.kind.activity")
        walk.press("activity.common.running")
        try walk.audit("Workout sheet · running chosen")
        walk.press("Save")
        XCTAssertTrue(app.descendants(matching: .any)["sheet.workout"].waitForNonExistence(timeout: 8),
                      "the workout sheet did not close after Save")
        walk.dismissHealthAccessIfShown()
    }

    /// The guided workout from the Move tab's card to "Nicely done", through every set and rest.
    ///
    /// What gets suggested depends on the goal and the day: the seeded Wellness program offers a
    /// cardio descriptor on some days ("Easy cardio · 20 min"), which has no guided runner and so no
    /// Start now. The walk sets the Strength goal first — through Settings' own preset cards, the
    /// way a VoiceOver user would — and skips, saying so, on a day that still has nothing to guide.
    @MainActor
    func testCompleteAGuidedWorkoutWithVoiceOverOnly() throws {
        let app = UXTestApp.launch(openSheet: "settings")
        let walk = VoiceOverWalk(app, task: "Complete a workout", in: self)

        walk.press("settings.row.goalNutrition")
        let strength = walk.button("goalPreset.strength")
        walk.activate(strength)
        XCTAssertTrue(strength.wait(for: \.isSelected, toEqual: true, timeout: 4))
        walk.activate(app.navigationBars.buttons["Settings"].firstMatch)
        walk.press("settings.done")

        walk.press("Move")
        // A run an earlier launch left live persists by design (the app-group run state), and the
        // card then offers Resume instead of Suggest — measured on the final run, after an earlier
        // walk had stopped mid-run. Resuming is itself part of this task, so it is walked, not reset.
        let resume = app.buttons["workout.resume"].firstMatch
        if resume.waitForExistence(timeout: 2) {
            try walk.audit("Move tab · workout in progress")
            walk.activate(resume)
        } else {
            try startSuggestedRun(walk, app: app)
        }

        try finishRun(walk, app: app)
        walk.press("workout.guided.close")
        XCTAssertTrue(app.buttons["workout.guided.close"].waitForNonExistence(timeout: 6),
                      "the runner did not close after Done")
    }

    /// How to do an exercise, from the suggested plan's first exercise row: the info button is a
    /// named control, the how-to sheet passes the audit and carries its safety line, and Done closes
    /// it. Same Strength-goal setup as the guided walk, so the plan has catalog lifts with how-tos.
    @MainActor
    func testExerciseHowToWithVoiceOverOnly() throws {
        let app = UXTestApp.launch(openSheet: "settings")
        let walk = VoiceOverWalk(app, task: "Read how to do an exercise", in: self)

        walk.press("settings.row.goalNutrition")
        let strength = walk.button("goalPreset.strength")
        walk.activate(strength)
        XCTAssertTrue(strength.wait(for: \.isSelected, toEqual: true, timeout: 4))
        walk.activate(app.navigationBars.buttons["Settings"].firstMatch)
        walk.press("settings.done")

        walk.press("Move")
        guard app.buttons["workout.suggestToday"].firstMatch.waitForExistence(timeout: 4) else {
            throw XCTSkip("the Move card offers no Suggest (a plan or a run from an earlier launch is live)")
        }
        walk.press("workout.suggestToday")
        walk.press("workout.suggest")
        let info = app.buttons["workout.howTo.open"].firstMatch
        guard info.waitForExistence(timeout: 10) else {
            throw XCTSkip("today's suggested plan has no catalog exercise with a how-to")
        }
        walk.assertSpeaksWords(info, describe: "the how-to button")
        XCTAssertTrue(info.label.hasPrefix("How to do "), "the how-to button reads '\(info.label)'")
        walk.activate(info)

        walk.element("sheet.exerciseHowTo")
        try walk.audit("Exercise how-to")
        XCTAssertTrue(app.staticTexts["Stop if you feel sharp pain."].waitForExistence(timeout: 4),
                      "the how-to sheet lost its safety line")
        walk.press("sheet.done")
        XCTAssertTrue(app.descendants(matching: .any)["sheet.exerciseHowTo"].waitForNonExistence(timeout: 6),
                      "the how-to sheet did not close after Done")
    }

    /// Suggest → plan → Start now → Start: the way into a fresh guided run.
    @MainActor
    private func startSuggestedRun(_ walk: VoiceOverWalk, app: XCUIApplication) throws {
        walk.press("workout.suggestToday")
        // The Move tab presents its own Suggest sheet, which carries no `sheet.*` anchor; its
        // primary is the landmark.
        walk.button("workout.suggest")
        try walk.audit("Suggest sheet")
        walk.press("workout.suggest")
        let startNow = app.buttons["workout.startGuided"].firstMatch
        guard startNow.waitForExistence(timeout: 10) else {
            throw XCTSkip("today's suggested plan has nothing the guided runner can walk (no Start now)")
        }
        try walk.audit("Suggested plan")
        walk.press("workout.startGuided")
        walk.button("workout.guided.start")
        try walk.audit("Runner · ready")
        walk.press("workout.guided.start")
        walk.dismissHealthAccessIfShown()
    }

    /// Walks a live run to its finish: skip to the last exercise, then work its sets, skipping
    /// every rest. Bounded — a run that never finishes fails rather than spinning.
    @MainActor
    private func finishRun(_ walk: VoiceOverWalk, app: XCUIApplication) throws {
        var auditedWorking = false
        var auditedResting = false
        for _ in 0..<Self.maximumRunnerSteps {
            if app.buttons["workout.guided.close"].exists { return }
            let skipExercise = app.buttons["workout.guided.skipExercise"].firstMatch
            let skipRest = app.buttons["workout.guided.skipRest"].firstMatch
            // The warm-up and cool-down are twenty-odd timed stretches; their quiet secondary skips
            // the whole block (the cool-down skip finishes and logs), so the walk stays short.
            let skipWarmUp = app.buttons["workout.guided.skipWarmUp"].firstMatch
            let skipCoolDown = app.buttons["workout.guided.skipCoolDown"].firstMatch
            // A heavy lift's warm-up sets (idea 12) replace the skip-to-next secondary with "Skip
            // warm-up sets", which lands on the lift's first working set.
            let skipWarmUpSets = app.buttons["workout.guided.skipWarmUpSets"].firstMatch
            if skipRest.exists {
                if !auditedResting { try walk.audit("Runner · resting"); auditedResting = true }
                walk.activate(skipRest)
            } else if skipWarmUp.exists {
                walk.activate(skipWarmUp)
            } else if skipWarmUpSets.exists {
                walk.activate(skipWarmUpSets)
            } else if skipCoolDown.exists {
                walk.activate(skipCoolDown)
            } else if skipExercise.exists && skipExercise.isEnabled {
                if !auditedWorking { try walk.audit("Runner · working"); auditedWorking = true }
                walk.activate(skipExercise)
            } else {
                walk.press("workout.guided.doneSet")
            }
        }
        XCTFail("the guided run did not finish within \(Self.maximumRunnerSteps) steps")
    }

    /// Far past any seeded plan's sets and rests; it exists so ``finishRun(_:app:)`` is finite.
    static let maximumRunnerSteps = 80

    // MARK: - Fundamentals: onboarding

    /// First run, every step, to Home — choosing an option on each step that offers one.
    @MainActor
    func testOnboardingWithVoiceOverOnly() throws {
        UXTestApp.forcePortrait()
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding"]
        app.launchEnvironment["FERNLET_UI_TEST_DISABLE_CLOUD_DETECTION"] = "1"
        app.launch()
        let walk = VoiceOverWalk(app, task: "Onboarding", in: self)

        walk.element("onboarding.welcome")
        try walk.audit("Welcome")
        walk.press("Continue")
        walk.element("onboarding.lock")
        try walk.audit("Lock setup")
        walk.press("onboarding.lock.skip")
        walk.element("onboarding.storage")
        let local = walk.button("onboarding.storage.local")
        walk.activate(local)
        XCTAssertTrue(local.wait(for: \.isSelected, toEqual: true, timeout: 4))
        try walk.audit("Storage choice")
        walk.press("Continue")
        for screen in ["onboarding.goal", "onboarding.starter", "onboarding.personal"] {
            walk.element(screen)
            try walk.audit(screen)
            walk.press("Continue")
        }
        walk.element("onboarding.diet")
        let diet = walk.button("onboarding.diet.higherProtein")
        walk.activate(diet)
        XCTAssertTrue(diet.wait(for: \.isSelected, toEqual: true, timeout: 4),
                      "the chosen eating pattern does not read as selected")
        try walk.audit("Dietary pattern")
        walk.press("Continue")
        walk.element("onboarding.permissions")
        try walk.audit("Permissions")
        walk.press("Start Fernlet")
        walk.element("screen.home", timeout: 10)
    }

    // MARK: - Fundamentals: changing a setting

    /// Settings from Home's gear, Appearance, a choice, and back out.
    @MainActor
    func testChangeASettingWithVoiceOverOnly() throws {
        let app = UXTestApp.launch()
        let walk = VoiceOverWalk(app, task: "Change a setting", in: self)

        walk.press("home.settings")
        walk.element("sheet.settings")
        try walk.audit("Settings")
        walk.press("settings.row.appearance")
        let dark = walk.button("Dark")
        try walk.audit("Appearance")
        walk.activate(dark)
        XCTAssertTrue(dark.wait(for: \.isSelected, toEqual: true, timeout: 4),
                      "the chosen appearance does not read as selected")
        // Back to System so the walk leaves the simulator as it found it.
        let system = walk.button("System")
        walk.activate(system)
        XCTAssertTrue(system.wait(for: \.isSelected, toEqual: true, timeout: 4))
        // Done lives on the hub; the pushed page's back button ("Settings") returns to it.
        walk.activate(app.navigationBars.buttons["Settings"].firstMatch)
        walk.press("settings.done")
        XCTAssertTrue(app.descendants(matching: .any)["sheet.settings"].waitForNonExistence(timeout: 6))
    }

    // MARK: - Fundamentals: finding help

    /// Searching Settings for help lands on Safety & reporting: crisis lines and the developer.
    @MainActor
    func testFindHelpWithVoiceOverOnly() throws {
        let app = UXTestApp.launch()
        let walk = VoiceOverWalk(app, task: "Find help", in: self)

        walk.press("home.settings")
        walk.element("sheet.settings")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 6), "Settings has no search field")
        walk.assertSpeaksWords(search, describe: "settings search")
        walk.type("help", into: search)
        walk.activate(walk.button(labelStartingWith: "Safety & reporting"))
        let contact = walk.element("safety.contactEmail")
        walk.assertSpeaksWords(contact, describe: "developer contact link")
        XCTAssertTrue(contact.label.hasPrefix("Email the developer"), "the contact link reads '\(contact.label)'")
        try walk.audit("Safety & reporting")
    }
}
