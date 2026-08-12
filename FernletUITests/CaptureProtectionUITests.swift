import XCTest

// MARK: - Capture-protection cover: the six protected surfaces
//
// Asserts the Tier-2 capture cover (and its accessibility label) renders over each of the six
// captureProtected surfaces: the Private hub root and the five sensitive sheets
// (JournalSheet, JournalEntryEditorSheet, DayEditSheet, LogPeriodSheet, LogIntimacySheet).
// Spec: Docs/Design-Capture-Protection-2026-08-10.md §7.
//
// Real capture cannot be driven from automation — simulator screen recording does not set
// UIScreen.isCaptured, and app.screenshot() does not post userDidTakeScreenshotNotification
// (verified 2026-08-11) — so every test launches with FERNLET_UI_TEST_FORCE_CAPTURE=1, which
// forces the injected CaptureProtectionState's capture override true (the design's test seam).
// The forced cover blocks hits on content beneath it, so the two JournalView-owned sheets are
// auto-presented by their own DEBUG launch hooks (FERNLET_UI_TEST_OPEN_JOURNAL_EDITOR /
// FERNLET_UI_TEST_OPEN_DAY_EDIT) rather than by navigation taps the cover would swallow.
//
// This friction is NOT a security control (spec §1); these tests assert rendering, nothing more.

final class CaptureProtectionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The cover's spoken/read explanation while capture is (forced) active — must match
    /// `CaptureProtectedModifier.coverText`'s recording branch.
    private let recordingLabel = "Hidden while your screen is being recorded"

    /// Asserts the per-surface cover element exists and carries the recording label.
    @MainActor
    private func assertCover(
        _ surface: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let cover = app.descendants(matching: .any)["capture.cover.\(surface)"].firstMatch
        XCTAssertTrue(
            cover.waitForExistence(timeout: timeout),
            "capture.cover.\(surface) never appeared — the forced Tier-2 cover is not rendering over this surface",
            file: file, line: line
        )
        XCTAssertTrue(
            cover.label.contains(recordingLabel),
            "capture.cover.\(surface) label was '\(cover.label)', expected it to contain '\(recordingLabel)'",
            file: file, line: line
        )
    }

    /// Surface 1: the Private hub root (covering the Journal/Cycle/Worry Box pages and their
    /// pushed details). Launched with the lock gate bypassed so the cover — INNER to the gate —
    /// is the visible layer.
    @MainActor
    func testCoverOverPrivateHub() {
        let app = UXTestApp.launch(
            bypassPrivateLock: true,
            extraEnvironment: ["FERNLET_UI_TEST_FORCE_CAPTURE": "1"]
        )
        app.buttons["Private"].firstMatch.tap()
        assertCover("privateHub", in: app)
    }

    /// Surface 2: the journal compose sheet, presented from the root router.
    @MainActor
    func testCoverOverJournalSheet() {
        let app = UXTestApp.launch(
            openSheet: "journal",
            extraEnvironment: ["FERNLET_UI_TEST_FORCE_CAPTURE": "1"]
        )
        assertCover("journalSheet", in: app)
    }

    /// Surface 3: the journal entry editor, auto-presented by its DEBUG hook (its normal entry
    /// points are taps the forced cover deliberately blocks). The Private tab must be selected
    /// first: the outer paged TabView instantiates its pages lazily, so the hub's JournalView —
    /// and its presenting hook — does not exist until the tab is visited.
    @MainActor
    func testCoverOverJournalEntryEditorSheet() {
        let app = UXTestApp.launch(
            bypassPrivateLock: true,
            extraEnvironment: [
                "FERNLET_UI_TEST_FORCE_CAPTURE": "1",
                "FERNLET_UI_TEST_OPEN_JOURNAL_EDITOR": "1",
            ]
        )
        app.buttons["Private"].firstMatch.tap()
        assertCover("journalEditor", in: app, timeout: 15)
    }

    /// Surface 4: the day edit sheet, auto-presented by its DEBUG hook. Selects the Private tab
    /// first for the same lazy-instantiation reason as the editor test.
    @MainActor
    func testCoverOverDayEditSheet() {
        let app = UXTestApp.launch(
            bypassPrivateLock: true,
            extraEnvironment: [
                "FERNLET_UI_TEST_FORCE_CAPTURE": "1",
                "FERNLET_UI_TEST_OPEN_DAY_EDIT": "1",
            ]
        )
        app.buttons["Private"].firstMatch.tap()
        assertCover("dayEdit", in: app, timeout: 15)
    }

    /// Surface 5: the period log sheet, presented from the root router.
    @MainActor
    func testCoverOverLogPeriodSheet() {
        let app = UXTestApp.launch(
            openSheet: "logPeriod",
            extraEnvironment: ["FERNLET_UI_TEST_FORCE_CAPTURE": "1"]
        )
        assertCover("logPeriod", in: app)
    }

    /// Surface 6: the intimacy log sheet, presented from the root router.
    @MainActor
    func testCoverOverLogIntimacySheet() {
        let app = UXTestApp.launch(
            openSheet: "logIntimacy",
            extraEnvironment: ["FERNLET_UI_TEST_FORCE_CAPTURE": "1"]
        )
        assertCover("logIntimacy", in: app)
    }
}
