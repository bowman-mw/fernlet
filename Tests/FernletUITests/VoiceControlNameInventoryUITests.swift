import XCTest

// MARK: - Voice Control names on the common-task paths
//
// Voice Control activates a control by its NAME: the user says "Tap Log water", and the name is
// the element's `accessibilityUserInputLabels` when it has them, else its accessibility label. So a
// label written for VoiceOver ("I'm unwell today. Scoring goes gentle until tomorrow.") is a
// sentence a Voice Control user must say in full; an icon-only control with no label has no name
// at all; two controls with one name on one screen make Voice Control fall back to numbers; and a
// label that differs from the drawn text leaves the user saying the words they can see to no
// effect. (Docs/Accessibility-Nutrition-Labels.md §3, "Voice Control".)
//
// What this suite can and cannot see. XCUITest reports an element's accessibility LABEL, not its
// input labels — there is no `userInputLabels` attribute on `XCUIElement` or its snapshot — so a
// long label that already carries short input labels still reads as long here. The source half of
// the wall (rule A9 in `Scripts/accessibility-scan.py`) is what holds a long literal label to having
// input labels; this suite is the INVENTORY that says which names a user meets on each screen, and
// the one thing it fails on is a name input labels cannot excuse: an SF Symbol identifier
// ("person.2.fill") read out as a control's name. Whether a phrase actually activates the control
// is the owner's device pass (`Docs/Handoff/a11y-2026-10-18/voicecontrol-device-pass.md`); the
// simulator cannot run Voice Control.
//
// One measured trap, so the listing is not misread. XCUITest reports a SwiftUI Button's drawn
// children (its icon, its text) as further elements of the button's own type, so a tab bar of five
// buttons read as fifteen, every name "duplicated" and the Friends icon "named" `person.2.fill`.
// VoiceOver and Voice Control see one element per button. The walk therefore records a control and
// does not descend into it; the texts drawn inside it are kept as `drawn=` for comparison.

/// One actionable element on a screen, as Voice Control would name it.
struct VoiceControlNameEntry: Sendable {
    /// The element type XCUITest resolved (button, switch, text field, …).
    let type: XCUIElement.ElementType
    /// The accessibility label — Voice Control's name when there are no input labels.
    let label: String
    /// The accessibility identifier, for finding the source site.
    let identifier: String
    /// The placeholder a text field shows, which Voice Control also accepts as its name.
    let placeholder: String
    /// The visible texts inside the element, when XCUITest exposes them as children.
    let childTexts: [String]
    /// Whether the element's frame is inside the window (Voice Control names on-screen controls).
    let onScreen: Bool

    /// The words a user must say to name this element.
    var spokenName: String { label.isEmpty ? placeholder : label }

    /// Spoken word count, measured as rule A9 measures it: a whitespace-separated run holding a
    /// letter or a digit, so a "·" or "&" between words is not a word.
    var wordCount: Int {
        spokenName.split(whereSeparator: { $0.isWhitespace })
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
            .count
    }
}

/// Collects and classifies the Voice Control names on the current screen.
@MainActor
enum VoiceControlNameInventory {
    /// Element types Voice Control offers a name or a number for.
    static let actionableTypes: Set<XCUIElement.ElementType> = [
        .button, .link, .switch, .toggle, .textField, .secureTextField, .searchField, .textView,
        .slider, .stepper, .segmentedControl, .picker, .pickerWheel, .menuButton, .popUpButton,
        .tab, .datePicker, .incrementArrow, .decrementArrow, .disclosureTriangle,
    ]

    /// Actionable types whose CHILDREN are controls of their own (a segmented control's segments,
    /// a stepper's two buttons), so the walk records them and keeps going. Every other actionable
    /// type is a leaf: its children are its own drawing.
    static let containerTypes: Set<XCUIElement.ElementType> = [.segmentedControl, .picker, .stepper]

    /// More words than this makes a name a sentence. Shared with rule A9's `A9_MAX_LABEL_WORDS`.
    static let longNameWords = 4

    /// The deepest the snapshot walk goes. SwiftUI trees on these screens measured under 40 levels;
    /// the bound exists so a pathological tree cannot hang the run.
    static let maximumDepth = 64

    /// The most elements one listing records — far above any screen here (the busiest, Home,
    /// measured under 200 actionable elements), and a ceiling on the walk.
    static let maximumEntries = 600

    /// Every actionable element under `app`, from one snapshot (one IPC round trip, rather than a
    /// query per element).
    static func entries(of app: XCUIApplication) throws -> [VoiceControlNameEntry] {
        let root = try app.snapshot()
        let window = app.windows.firstMatch.frame
        var found: [VoiceControlNameEntry] = []
        var stack: [(XCUIElementSnapshot, Int)] = [(root, 0)]
        while let (node, depth) = stack.popLast(), found.count < maximumEntries {
            // The system keyboard's keys are Voice Control's own vocabulary, not the app's names. Its
            // dictation key sits outside the `.keyboard` element (measured), so it goes by identifier.
            if node.elementType == .keyboard || node.identifier == "dictation" { continue }
            let actionable = actionableTypes.contains(node.elementType)
            if actionable {
                found.append(entry(for: node, in: window))
            }
            guard depth < maximumDepth, !actionable || containerTypes.contains(node.elementType) else { continue }
            for child in node.children.reversed() { stack.append((child, depth + 1)) }
        }
        return found
    }

    private static func entry(for node: XCUIElementSnapshot, in window: CGRect) -> VoiceControlNameEntry {
        let texts = node.children
            .filter { $0.elementType == .staticText }
            .map(\.label)
            .filter { !$0.isEmpty }
        let frame = node.frame
        return VoiceControlNameEntry(
            type: node.elementType,
            label: node.label,
            identifier: node.identifier,
            placeholder: node.placeholderValue ?? "",
            childTexts: texts,
            onScreen: frame.width >= 1 && frame.height >= 1 && window.intersects(frame)
        )
    }

    /// A name that looks like an SF Symbol identifier (`plus.circle.fill`) rather than words.
    static func isSymbolName(_ name: String) -> Bool {
        name.contains(".") && !name.contains(" ")
            && name.allSatisfy { $0.isLowercase || $0 == "." || $0.isNumber }
    }

    /// The flags a name earns: EMPTY, SYMBOL, LONG, DUPLICATE, NOT-AS-DRAWN.
    static func flags(_ entry: VoiceControlNameEntry, duplicates: Set<String>) -> [String] {
        var flags: [String] = []
        let name = entry.spokenName
        if name.isEmpty { flags.append("EMPTY") }
        if isSymbolName(name) { flags.append("SYMBOL") }
        if entry.wordCount > longNameWords { flags.append("LONG") }
        if !name.isEmpty, duplicates.contains(name.lowercased()) { flags.append("DUPLICATE") }
        let lowered = name.lowercased()
        if let drawn = entry.childTexts.first, !lowered.contains(drawn.lowercased()) {
            flags.append("NOT-AS-DRAWN")
        }
        return flags
    }

    /// Lists the screen's names, attaches the listing, and fails on a name that is a symbol identifier.
    ///
    /// - Parameters:
    ///   - app: The running app.
    ///   - screen: The screen's gallery name.
    ///   - test: The test the attachment belongs to.
    ///   - file: The calling test's file.
    ///   - line: The calling test's line.
    static func record(
        _ app: XCUIApplication,
        _ screen: String,
        in test: XCTestCase,
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        let all = try entries(of: app).filter(\.onScreen)
        var counts: [String: Int] = [:]
        for entry in all where !entry.spokenName.isEmpty { counts[entry.spokenName.lowercased(), default: 0] += 1 }
        let duplicates = Set(counts.filter { $0.value > 1 }.keys)
        var lines: [String] = []
        for entry in all {
            let flagged = flags(entry, duplicates: duplicates)
            if flagged.contains("SYMBOL") {
                XCTFail("[\(screen)] a control is named '\(entry.spokenName)' (id \(entry.identifier)) — an SF "
                        + "Symbol identifier, which no one can say. Give it a label.", file: file, line: line)
            }
            let drawn = entry.childTexts.isEmpty ? "" : " drawn=\(entry.childTexts.joined(separator: " | "))"
            let row = "VCNAME\t\(screen)\t\(flagged.joined(separator: ","))\t\(entry.type.rawValue)\t"
                + "\(entry.spokenName)\tid=\(entry.identifier)\(drawn)"
            lines.append(row)
            print(row)
        }
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "Voice Control names – \(screen)"
        attachment.lifetime = .keepAlways
        test.add(attachment)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Voice Control screen – \(screen)"
        screenshot.lifetime = .keepAlways
        test.add(screenshot)
    }
}

final class VoiceControlNameInventoryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - Fundamentals: onboarding

    @MainActor
    func testOnboardingNames() throws {
        UXTestApp.forcePortrait()
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding"]
        app.launchEnvironment["FERNLET_UI_TEST_DISABLE_CLOUD_DETECTION"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome to Fernlet"].waitForExistence(timeout: 8))
        try VoiceControlNameInventory.record(app, "Onboarding · Welcome", in: self)
        app.buttons["Continue"].tap()

        XCTAssertTrue(app.staticTexts["Protect private spaces"].waitForExistence(timeout: 4))
        try VoiceControlNameInventory.record(app, "Onboarding · Lock", in: self)
        app.buttons["onboarding.lock.skip"].tap()

        XCTAssertTrue(app.staticTexts["Choose where logs live"].waitForExistence(timeout: 4))
        try VoiceControlNameInventory.record(app, "Onboarding · Storage", in: self)
        app.buttons["onboarding.storage.local"].tap()
        app.buttons["Continue"].tap()

        let steps: [(String, String, String)] = [
            ("Plan your goals", "Onboarding · Goals", "Continue"),
            ("Make Fernlet yours", "Onboarding · Starter", "Continue"),
            ("Add personal details", "Onboarding · Personal details", "Continue"),
            ("Pick an eating pattern", "Onboarding · Eating pattern", "Continue"),
            ("Permissions when needed", "Onboarding · Permissions", "Start Fernlet"),
        ]
        for (title, screen, next) in steps {
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 4), "[\(screen)] never appeared")
            try VoiceControlNameInventory.record(app, screen, in: self)
            app.buttons[next].tap()
        }
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 8))
    }

    // MARK: - Home, and the quick paths it carries (water, mood)

    @MainActor
    func testHomeNames() throws {
        let app = UXTestApp.launch()
        try VoiceControlNameInventory.record(app, "Home", in: self)
        app.swipeUp()
        try VoiceControlNameInventory.record(app, "Home – scrolled", in: self)
    }

    // MARK: - Common task: log a meal

    @MainActor
    func testMealNames() throws {
        let app = UXTestApp.launch(openSheet: "meal")
        XCTAssertTrue(app.descendants(matching: .any)["sheet.meal"].waitForExistence(timeout: 8))
        try VoiceControlNameInventory.record(app, "Sheet · Meal", in: self)

        let search = app.descendants(matching: .any)["mealComposer.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) { search.tap() }
        search.typeText("apple")
        let results = app.descendants(matching: .any)["mealComposer.catalogResults"].firstMatch
        XCTAssertTrue(results.waitForExistence(timeout: 8))
        try VoiceControlNameInventory.record(app, "Sheet · Meal – results", in: self)
        results.tap()
        XCTAssertTrue(app.descendants(matching: .any)["mealComposer.selectedCatalogFood"].firstMatch
            .waitForExistence(timeout: 4))
        try VoiceControlNameInventory.record(app, "Sheet · Meal – food chosen", in: self)
    }

    @MainActor
    func testFoodTabNames() throws {
        let app = UXTestApp.launch()
        app.buttons["Food"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.food"].waitForExistence(timeout: 8))
        try VoiceControlNameInventory.record(app, "Food tab", in: self)
    }

    // MARK: - Common task: log water

    @MainActor
    func testWaterNames() throws {
        let app = UXTestApp.launch(openSheet: "water")
        XCTAssertTrue(app.descendants(matching: .any)["sheet.water"].waitForExistence(timeout: 8))
        try VoiceControlNameInventory.record(app, "Sheet · Water", in: self)
    }

    // MARK: - Common task: log a mood

    @MainActor
    func testJournalNames() throws {
        let app = UXTestApp.launch(openSheet: "journal")
        XCTAssertTrue(app.descendants(matching: .any)["sheet.journal"].waitForExistence(timeout: 8))
        try VoiceControlNameInventory.record(app, "Sheet · Journal", in: self)
    }

    // MARK: - Common task: complete a workout

    @MainActor
    func testMoveNames() throws {
        let app = UXTestApp.launch()
        app.buttons["Move"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.move"].waitForExistence(timeout: 8))
        try VoiceControlNameInventory.record(app, "Move tab", in: self)
        app.swipeUp()
        try VoiceControlNameInventory.record(app, "Move tab – scrolled", in: self)
    }

    @MainActor
    func testWorkoutSheetNames() throws {
        let app = UXTestApp.launch(openSheet: "workout")
        XCTAssertTrue(app.descendants(matching: .any)["sheet.workout"].waitForExistence(timeout: 8))
        try VoiceControlNameInventory.record(app, "Sheet · Workout – exercise", in: self)
        app.buttons["workout.kind.activity"].tap()
        XCTAssertTrue(app.textFields["activity.search"].waitForExistence(timeout: 4))
        try VoiceControlNameInventory.record(app, "Sheet · Workout – activity", in: self)
    }

    // MARK: - Fundamentals: settings and help

    @MainActor
    func testSettingsNames() throws {
        let app = UXTestApp.launch(openSheet: "settings")
        XCTAssertTrue(app.descendants(matching: .any)["sheet.settings"].waitForExistence(timeout: 8))
        try VoiceControlNameInventory.record(app, "Settings", in: self)
        app.swipeUp()
        try VoiceControlNameInventory.record(app, "Settings – scrolled", in: self)
    }

    @MainActor
    func testSettingsSubpageNames() throws {
        let app = UXTestApp.launch(openSheet: "settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        for (row, title) in [("settings.row.goalNutrition", "Goal & nutrition"),
                             ("settings.row.appearance", "Appearance")] {
            app.buttons[row].firstMatch.tap()
            let bar = app.navigationBars[title]
            XCTAssertTrue(bar.waitForExistence(timeout: 6), "[Settings · \(title)] never appeared")
            try VoiceControlNameInventory.record(app, "Settings · \(title)", in: self)
            app.swipeUp()
            try VoiceControlNameInventory.record(app, "Settings · \(title) – scrolled", in: self)
            bar.buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 6))
        }
    }

    @MainActor
    func testSafetyAndReportingNames() throws {
        let app = UXTestApp.launch(openSheet: "settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let row = app.buttons["settings.row.safety"].firstMatch
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.navigationBars["Safety & reporting"].waitForExistence(timeout: 6))
        try VoiceControlNameInventory.record(app, "Settings · Safety & reporting", in: self)
        app.swipeUp()
        try VoiceControlNameInventory.record(app, "Settings · Safety & reporting – scrolled", in: self)
    }

    // MARK: - Common task: complete a workout (guided)

    /// The suggestion, its plan, and — when today's plan has a session the runner can guide — the
    /// guided runner. The demo seed's plan for today is easy cardio, which the runner does not
    /// guide (measured 2026-10-18: "Today's session · Easy cardio" with Edit, Save for later and
    /// "Already did this — log it", and no Start now), so on that seed the cell records the plan
    /// and stops; the runner's names are covered by the device pass.
    @MainActor
    func testGuidedWorkoutNames() throws {
        let app = UXTestApp.launch(openSheet: "workoutSuggestion")
        XCTAssertTrue(app.descendants(matching: .any)["sheet.workoutSuggestion"].waitForExistence(timeout: 8))
        try VoiceControlNameInventory.record(app, "Workout suggestion", in: self)
        app.buttons["workout.suggest"].firstMatch.tap()
        let startNow = app.buttons["workout.startGuided"].firstMatch
        let plan = app.buttons["workout.approvePlan"].firstMatch
        XCTAssertTrue(plan.waitForExistence(timeout: 30), "[Workout suggestion] no plan appeared within 30s")
        app.swipeUp()
        try VoiceControlNameInventory.record(app, "Workout suggestion – plan", in: self)
        guard startNow.exists else { return }
        startNow.tap()
        let start = app.buttons["workout.guided.start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        try VoiceControlNameInventory.record(app, "Guided workout – ready", in: self)
        start.tap()
        XCTAssertTrue(app.buttons["workout.guided.doneSet"].firstMatch.waitForExistence(timeout: 8))
        try VoiceControlNameInventory.record(app, "Guided workout – running", in: self)
    }

    // MARK: - Common task: log a mood (the Private hub's journal)

    @MainActor
    func testPrivateJournalNames() throws {
        let app = UXTestApp.launch(bypassPrivateLock: true)
        app.buttons["Private"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.journal"].waitForExistence(timeout: 8))
        try VoiceControlNameInventory.record(app, "Private · Journal", in: self)
    }

    @MainActor
    func testFirstAidNames() throws {
        let app = UXTestApp.launch(openSheet: "firstAid")
        XCTAssertTrue(app.descendants(matching: .any)["sheet.firstAid"].waitForExistence(timeout: 8))
        try VoiceControlNameInventory.record(app, "Sheet · First aid", in: self)
    }
}
