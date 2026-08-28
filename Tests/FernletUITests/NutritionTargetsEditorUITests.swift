import XCTest

/// #17 macro target overrides — drives the real Settings editor end to end on device. Proves the
/// editor is interactive and wired to the derivation (the math + settings round-trip are pinned by
/// `NutritionTargetOverrideTests`), and specifically guards the review-confirmed bug: a blank Fat
/// field's placeholder must track a pinned calorie override (fat derives from calories), not sit at a
/// stale fully-derived value that contradicts the macro rings.
final class NutritionTargetsEditorUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testEditorRebalancesResidualAndFatPlaceholderTracksCalories() throws {
        let app = UXTestApp.launch(openSheet: "settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings did not open")

        // Into "Goal & nutrition", the pushed screen that hosts the targets editor.
        let row = app.buttons["Goal & nutrition"]
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.isHittable, "'Goal & nutrition' row not reachable")
        row.tap()
        XCTAssertTrue(app.navigationBars["Goal & nutrition"].waitForExistence(timeout: 6),
                      "did not push Goal & nutrition")

        let calories = app.textFields["nutritionTargets.calories"]
        let protein = app.textFields["nutritionTargets.protein"]
        let fat = app.textFields["nutritionTargets.fat"]
        let carbs = app.descendants(matching: .any)["nutritionTargets.carbs"]
        for _ in 0..<10 where !(fat.exists && fat.isHittable) { app.swipeUp() }
        XCTAssertTrue(fat.waitForExistence(timeout: 4), "target fields not found")

        // Settings persist across launches, so clear any override left by a prior run → known baseline.
        resetIfPresent(app)
        try UXScreenProbe(app, "Settings · Nutrition targets", in: self).capture()

        // Baselines with every field blank (derived). A blank field reports its placeholder as `.value`.
        let derivedCalories = intValue(calories)
        let fatBaseline = fat.value as? String
        let carbsBaseline = carbs.label
        XCTAssertNotNil(derivedCalories, "could not read the derived calorie placeholder")

        // (1) Pin a clearly-different calorie target, leaving fat blank. The blank Fat placeholder must
        // MOVE (fat derives from calories) — the bug was it staying at the fully-derived value.
        setField(calories, to: "\((derivedCalories ?? 2_000) + 1_000)", app: app)
        XCTAssertNotEqual(fat.value as? String, fatBaseline,
                          "blank Fat placeholder did not track the calorie override (stale fully-derived value)")
        XCTAssertNotEqual(carbs.label, carbsBaseline, "carbs did not rebalance after pinning calories")
        // Its OWN probe name, not a second `capture()` on the one above. The two probes look at
        // genuinely different screens — this one has an override pinned, so the Reset control
        // exists and the fully-derived state above has nothing to reset — and a screen name is the
        // baseline key. Sharing one key made the ratchet unsatisfiable rather than strict: the
        // blank state reported 0 findings and the pinned state reported Reset's sub-44pt hit
        // region, so whichever way the single baseline was written, one of the two probes failed.
        // Named variants are how `ScreenAppearanceUITests` already handles the Cycle page's halves.
        try UXScreenProbe(app, "Settings · Nutrition targets (calories pinned)", in: self)
            .capture("calories pinned")

        // Back to baseline; the Fat placeholder returns to its derived value.
        resetIfPresent(app)
        XCTAssertEqual(fat.value as? String, fatBaseline, "Reset did not restore the derived Fat placeholder")

        // (2) Pin a high protein target; the residual carbs must drop.
        setField(protein, to: "300", app: app)
        XCTAssertEqual(protein.value as? String, "300", "protein override did not take the typed value")
        XCTAssertNotEqual(carbs.label, carbsBaseline, "carbs did not rebalance after pinning protein")

        // Leave the editor clean for the next run.
        resetIfPresent(app)
    }

    // MARK: - Helpers

    @MainActor private func intValue(_ field: XCUIElement) -> Int? {
        Int((field.value as? String ?? "").filter(\.isNumber))
    }

    @MainActor private func setField(_ field: XCUIElement, to text: String, app: XCUIApplication) {
        field.tap()
        field.typeText(text)
        // Number pad has no return key — tap the nav bar to dismiss it without navigating.
        app.navigationBars["Goal & nutrition"].tap()
    }

    @MainActor private func resetIfPresent(_ app: XCUIApplication) {
        let reset = app.buttons["nutritionTargets.reset"]
        for _ in 0..<4 where !(reset.exists && reset.isHittable) { app.swipeUp() }
        if reset.exists && reset.isHittable { reset.tap() }
    }
}
