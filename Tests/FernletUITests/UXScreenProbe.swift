import XCTest

// MARK: - UX appearance test harness
//
// These helpers back the ScreenAppearance* suites, whose job is different from every
// other UI suite in the tree: instead of asserting behavior (does element X exist / is it
// enabled), they check that each screen *looks right* — rendered, not clipped off-screen,
// not blank, not riding under the status bar — and attach a labeled screenshot of every
// screen so the whole app can be reviewed as a gallery in one test run.
//
// What XCUITest can and can't see: it has no access to colors or fonts, so true visual
// fidelity (the warm parchment / serif "vibe") is verified by the attached screenshots.
// What it *can* check deterministically is geometry — element frames vs the screen and the
// tab bar — which is exactly the class of "this screen looks off" bug (clipped headers,
// content pushed off-screen, blank states) that motivated this suite.

/// Builds a `-completeOnboarding` app pre-seeded with representative demo content
/// (`FERNLET_UI_TEST_SEED_DEMO`) so screens render populated rather than empty.
@MainActor
enum UXTestApp {
    static func launch(
        openSheet sheetID: String? = nil,
        bypassPrivateLock: Bool = false,
        extraEnvironment: [String: String] = [:]
    ) -> XCUIApplication {
        forcePortrait()
        let app = XCUIApplication()
        app.launchArguments = ["-completeOnboarding"]
        app.launchEnvironment["FERNLET_UI_TEST_SEED_DEMO"] = "1"
        if let sheetID { app.launchEnvironment["FERNLET_UI_TEST_OPEN_SHEET"] = sheetID }
        if bypassPrivateLock { app.launchEnvironment["FERNLET_UI_TEST_BYPASS_PRIVATE_LOCK"] = "1" }
        for (key, value) in extraEnvironment { app.launchEnvironment[key] = value }
        app.launch()
        return app
    }

    /// Puts the simulator back in portrait before an app launches.
    ///
    /// Simulator orientation is HOST state: it survives between runs, nothing in this repo sets it,
    /// and it drifts. On 2026-08-27 both the `iPhone 17` device and `Fernlet-A11y` were found
    /// rotated to landscape mid-session, having been portrait for the preceding runs of the same
    /// binary. That matters more here than in an ordinary UI suite, because
    /// ``UXScreenProbe/auditBaselines`` freezes per-screen CLIPPING and HIT-REGION findings, and
    /// both are functions of the window the screen laid out in — a rotated simulator fails most
    /// screens in BOTH directions at once and reads exactly like a real regression.
    ///
    /// ``UXScreenProbe/isOnBaselineEnvironment(file:line:)`` is the backstop that says so out loud;
    /// this is what stops it being needed. Call it from any probe suite that builds its own
    /// `XCUIApplication` instead of going through ``launch(openSheet:bypassPrivateLock:extraEnvironment:)``.
    static func forcePortrait() {
        XCUIDevice.shared.orientation = .portrait
    }
}

/// Layout-sanity + screenshot probe for a single screen or sheet. Chainable; every
/// assertion carries a `[screen]` prefixed message so a gallery run pinpoints which screen
/// is off.
@MainActor
struct UXScreenProbe {
    let app: XCUIApplication
    let name: String
    unowned let test: XCTestCase

    /// Frame-math slack (pt) to absorb rounding / antialiasing.
    private let tolerance: CGFloat = 1.0

    init(_ app: XCUIApplication, _ name: String, in test: XCTestCase) {
        self.app = app
        self.name = name
        self.test = test
    }

    private var window: XCUIElement { app.windows.firstMatch }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    // MARK: Core assertions

    /// The anchor rendered, has a non-degenerate frame, and sits fully within the screen
    /// (not clipped off any edge). This is the workhorse "the screen looks structurally
    /// correct" check.
    @discardableResult
    func assertOnScreen(
        _ identifier: String,
        timeout: TimeInterval = 8,
        file: StaticString = #file,
        line: UInt = #line
    ) -> Self {
        assertElementOnScreen(element(identifier), "anchor '\(identifier)'", timeout: timeout, file: file, line: line)
    }

    /// Same on-screen / not-clipped checks as `assertOnScreen` but against an element the
    /// caller already has (e.g. a title `staticText` or a `Continue` button) — used where a
    /// screen has no stable identifier to key on.
    @discardableResult
    func assertElementOnScreen(
        _ el: XCUIElement,
        _ describe: String,
        timeout: TimeInterval = 8,
        file: StaticString = #file,
        line: UInt = #line
    ) -> Self {
        XCTAssertTrue(
            el.waitForExistence(timeout: timeout),
            "[\(name)] \(describe) never appeared — screen failed to render or wasn't reached",
            file: file, line: line
        )
        guard el.exists else { return self }

        let frame = el.frame
        XCTAssertTrue(
            frame.width >= 2 && frame.height >= 2,
            "[\(name)] \(describe) has a degenerate frame \(frame) — it didn't lay out",
            file: file, line: line
        )

        let bounds = window.frame
        XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX - tolerance,
            "[\(name)] \(describe) is clipped past the LEFT edge (\(frame) vs \(bounds))", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX + tolerance,
            "[\(name)] \(describe) is clipped past the RIGHT edge (\(frame) vs \(bounds))", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, bounds.minY - tolerance,
            "[\(name)] \(describe) is clipped past the TOP edge (\(frame) vs \(bounds))", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY + tolerance,
            "[\(name)] \(describe) is clipped past the BOTTOM edge (\(frame) vs \(bounds))", file: file, line: line)
        return self
    }

    /// A header sits below the status bar / Dynamic Island rather than hidden under it.
    /// Skipped when the configuration exposes no status bar.
    @discardableResult
    func assertBelowStatusBar(
        _ identifier: String,
        file: StaticString = #file,
        line: UInt = #line
    ) -> Self {
        assertBelowStatusBarElement(element(identifier), describe: "'\(identifier)'", file: file, line: line)
    }

    @discardableResult
    func assertBelowStatusBarElement(
        _ el: XCUIElement,
        describe: String = "element",
        file: StaticString = #file,
        line: UInt = #line
    ) -> Self {
        let statusBar = app.statusBars.firstMatch
        guard statusBar.exists, el.exists else { return self }
        XCTAssertGreaterThanOrEqual(
            el.frame.minY, statusBar.frame.maxY - tolerance,
            "[\(name)] \(describe) rides under the status bar (top \(el.frame.minY) < status-bar bottom \(statusBar.frame.maxY))",
            file: file, line: line
        )
        return self
    }

    /// The element does not overlap the floating bottom tab bar (content hidden behind it).
    /// Uses the Home tab button as the tab-bar reference; skipped when no tab bar is shown
    /// (e.g. inside a sheet).
    @discardableResult
    func assertAboveTabBar(
        _ identifier: String,
        file: StaticString = #file,
        line: UInt = #line
    ) -> Self {
        let tabButton = app.buttons["Home"]
        let el = element(identifier)
        guard tabButton.exists, tabButton.isHittable, el.exists else { return self }
        XCTAssertLessThanOrEqual(
            el.frame.maxY, tabButton.frame.minY + tolerance,
            "[\(name)] '\(identifier)' overlaps / sits behind the tab bar (bottom \(el.frame.maxY) > tab-bar top \(tabButton.frame.minY))",
            file: file, line: line
        )
        return self
    }

    /// Proves the screen isn't blank by finding an expected/seeded piece of content.
    @discardableResult
    func assertNotEmpty(
        containing text: String,
        timeout: TimeInterval = 5,
        file: StaticString = #file,
        line: UInt = #line
    ) -> Self {
        let match = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
        XCTAssertTrue(
            match.waitForExistence(timeout: timeout),
            "[\(name)] expected content containing '\(text)' but found none — screen looks empty/unpopulated",
            file: file, line: line
        )
        return self
    }

    // MARK: Accessibility audit — the runtime half of the §4.5 wall

    /// The audit types run on every screen.
    ///
    /// `.contrast` is **deliberately subtracted**, and this is the honest reason rather than a
    /// convenience: XCUITest's contrast auditor samples rendered pixels and cannot see which pairs
    /// are text and which are decorative, so on a parchment palette built from deliberately soft
    /// hairlines (a card edge at 0.08 bark, a chip outline at 0.12) it reports the design's whole
    /// vocabulary of quiet boundaries as failures. Those boundaries ARE measured — every ratio in
    /// `FernletUIComponents.swift`'s token doc comments was computed from the raw channel bytes,
    /// and Increase Contrast raises each of them past the 3:1 non-text floor (T2-6 / §4.2). A
    /// pixel auditor that cannot tell a 12pt caption from a 1pt divider would bury the four real
    /// findings under fifty false ones, and a noisy wall is a disabled wall.
    ///
    /// `.sufficientElementDescription`, `.hitRegion`, `.dynamicType`, `.elementDetection`,
    /// `.textClipped` and `.trait` all run. Those are the four things this audit is genuinely good
    /// at — an unlabeled element, a sub-44pt target, text clipped at AX5, a control with no trait.
    ///
    /// Re-examine this subtraction when the contrast work lands its second half; the review's
    /// instruction was to burn the contrast allowlist down deliberately rather than to leave the
    /// type off forever.
    static var auditTypes: XCUIAccessibilityAuditType { .all.subtracting(.contrast) }

    /// Runs `performAccessibilityAudit` against the current screen.
    ///
    /// **This throws, and that is the correction every draft of this proposal missed.**
    /// `performAccessibilityAudit(for:_:)` is a throwing method, so the chain that calls it has to
    /// throw too — every `capture()` call site gains a `try`. The three tempting ways around that
    /// are all banned here: `try!` traps the whole run on a transient audit failure, a swallowed
    /// `try?` turns the wall into decoration, and `XCTAssertNoThrow` discards the issue handler's
    /// findings and reports only that *something* went wrong.
    ///
    /// The issue handler returns `true` to suppress an issue and `false` to fail the test.
    /// Suppression happens only through ``auditExemptions``, which carries a reason per entry — the
    /// same house rule as `Scripts/accessibility-allowlist.json` and the Power-of-10 allowlist.
    ///
    /// **The honest ceiling**, restated at the call site because this is where it gets forgotten:
    /// this audit catches unlabeled elements, sub-44pt hit regions, clipped text at large type
    /// sizes and (when enabled) low-contrast pairs. It does **not** catch focus order, a label that
    /// is present but WRONG, a missing custom action, or an unhonored Reduce Motion. Those stay
    /// manual, forever.
    @discardableResult
    func audit(file: StaticString = #file, line: UInt = #line) throws -> Self {
        var (raw, found) = try runAudit()
        // ONE retry, and only for the unambiguous case: this screen has frozen findings but the
        // auditor just returned nothing at all. That is `performAccessibilityAudit` failing, not
        // the screen being fixed — a screen does not lose every finding in every category at once
        // without a code change. Measured 2026-08-27: `Settings · Nutrition targets` reported its
        // one hit-region finding on two runs and 0 raw issues on the third, and fifteen screens
        // went silent together inside a whole-`FernletUITests` invocation.
        //
        // A retry rather than an excuse, because the two are not equivalent. Excusing a zero would
        // turn a run where the auditor died into a GREEN one across every screen at once — the
        // whole wall silently passing is the failure this map exists to prevent. Retrying removes
        // the transient and leaves both directions walled; if the second pass is also empty the
        // report below still fails, saying exactly what happened.
        if found.isEmpty && !(Self.auditBaselines[name] ?? []).isEmpty {
            (raw, found) = try runAudit()
        }
        attachListingIfOffBaseline(raw: raw)
        guard isOnBaselineEnvironment(file: file, line: line) else { return self }
        report(found, raw: raw, file: file, line: line)
        return self
    }

    /// One `performAccessibilityAudit` pass: the raw descriptions and the identity set.
    private func runAudit() throws -> (raw: [String], found: Set<String>) {
        var raw: [String] = []
        var found: Set<String> = []
        try app.performAccessibilityAudit(for: Self.auditTypes) { issue in
            guard Self.exemption(for: issue) == nil else { return true }
            raw.append(Self.describe(issue))
            found.insert(Self.identity(issue))
            // Always `true`. The handler's own "report it" path (`false`) raises an issue with no
            // screen name on it, and a 26-screen gallery run then tells you something is wrong
            // without saying where. Reporting below keeps the probe's `[screen]` prefix, which is
            // the whole reason this harness exists.
            return true
        }
        return (raw, found)
    }

    /// The window geometry every identity in ``auditBaselines`` was recorded against: **iPhone 17
    /// in portrait**, which is what this repo's canonical `platform=iOS Simulator,name=iPhone 17`
    /// destination boots into (README, `Scripts/spm-wall-check.sh`, the pre-push hook and
    /// `.github/workflows/s3-wall.yml` all name that device).
    static let baselineWindowSize = CGSize(width: 402, height: 874)

    /// `FERNLET_UI_TEST_ALLOW_OFF_BASELINE_DEVICE=1` — run the ratchet anyway. The one legitimate
    /// use is re-recording the whole map against a deliberately chosen new device; it is an
    /// environment variable rather than a code edit so that re-record does not have to touch, and
    /// then remember to restore, this file.
    static var allowsOffBaselineDevice: Bool {
        ProcessInfo.processInfo.environment["FERNLET_UI_TEST_ALLOW_OFF_BASELINE_DEVICE"] == "1"
    }

    /// Whether this run is on the device and orientation the baselines describe — and, when it is
    /// not, ONE honest failure saying so instead of a screenful of audit deltas.
    ///
    /// **This guard is the residue of a real misdiagnosis, and the cost is why it is worth its
    /// lines.** The frozen identities are per-screen *layout* facts: which text clips, which target
    /// is under 44pt. Both are functions of the window the screen laid out in. Run the same
    /// unchanged binary on a simulator that is rotated to landscape, or on an iPhone 17 **Pro**
    /// rather than the iPhone 17 the map was recorded on, and the ratchet fails in BOTH directions
    /// on most screens at once — baseline entries stop reproducing because the layout moved, and
    /// fresh ones appear for the same reason. That pattern reads exactly like the audit engine
    /// itself having drifted under a runtime upgrade, and on 2026-08-27 it was diagnosed as that
    /// for some time before the window frame was checked. Landscape additionally suppresses
    /// `FERNLET_UI_TEST_OPEN_SHEET`'s sheet on some screens, so `assertOnScreen` fails first and the
    /// audit then measures whatever was behind it — noise on top of noise.
    ///
    /// Checking the window frame catches every one of those at once and costs one comparison. The
    /// failure names the destination to use, because "wrong device" is not a thing the reported
    /// deltas would ever say out loud.
    ///
    /// **What it deliberately does not check.** Appearance (light/dark) and content size are not
    /// asserted: `.contrast` is subtracted from ``auditTypes`` so appearance barely moves these
    /// findings, and XCUITest cannot read the content size category back. Those stay the runner's
    /// responsibility — a shut-down simulator boots to the light/`large` defaults the baselines
    /// were recorded at, which is why booting a fresh one is the reliable fix for a drifted device.
    private func isOnBaselineEnvironment(file: StaticString, line: UInt) -> Bool {
        let size = window.frame.size
        guard size != Self.baselineWindowSize else { return true }
        guard !Self.allowsOffBaselineDevice else { return true }
        XCTFail("""
            [\(name)] OFF-BASELINE ENVIRONMENT — the accessibility ratchet did not run, because its \
            result would have been meaningless. This run's window is \(size), but every identity in \
            `UXScreenProbe.auditBaselines` was recorded at \(Self.baselineWindowSize) (iPhone 17, \
            portrait). Clipping and hit-region findings are layout facts, so a different device or \
            a rotated simulator changes most of them at once and the deltas read like a real \
            regression when nothing regressed.

            Run this suite on the canonical destination:
                -destination 'platform=iOS Simulator,name=iPhone 17'
            and if that simulator has been rotated or left in dark mode, boot a fresh one (a \
            shut-down simulator boots portrait/light/large) rather than trusting the drifted state.

            To re-record the map against a deliberately chosen new device, set \
            FERNLET_UI_TEST_ALLOW_OFF_BASELINE_DEVICE=1.
            """, file: file, line: line)
        return false
    }

    /// On an off-baseline run the ratchet is skipped, so ``report(_:raw:file:line:)`` never attaches
    /// its listing. Attach the raw findings anyway — someone diagnosing why a device is off-baseline
    /// still wants to see what the audit saw.
    private func attachListingIfOffBaseline(raw: [String]) {
        guard window.frame.size != Self.baselineWindowSize, !Self.allowsOffBaselineDevice else { return }
        let attachment = XCTAttachment(string: """
            [\(name)] off-baseline run (window \(window.frame.size)) — ratchet skipped.

            -- raw (as reported, with frames) --
            \(raw.isEmpty ? "none" : raw.sorted().joined(separator: "\n"))
            """)
        attachment.name = "\(name) – accessibility audit (off-baseline)"
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }

    /// Compares this screen's findings against its baseline **as a set of issue identities**, and
    /// fails in BOTH directions: on an issue that is not in the baseline, and on a baseline entry
    /// that no longer reproduces.
    ///
    /// **Why identities and not a count.** The first version of this ratchet stored one integer per
    /// screen, and it was neither stable nor discriminating. Not discriminating, because fixing one
    /// finding while introducing another leaves the count unchanged and the wall green — the exact
    /// substitution a wall exists to catch. Not stable, because a *count* over `[String]` counts
    /// duplicates, and the two things the audit duplicates most are the least meaningful: an issue
    /// whose `element` is `nil` collapses to a bare category string (four separate "Potentially
    /// inaccessible text" lines on one sheet), and `describe` embedded the element's frame, whose
    /// float digits (`27.203980099502488`) differ between runs of the same screen. Measured on this
    /// tree at the time of writing: one full-suite run reported Home at 19 and failed Meal at 9
    /// against a ceiling of 6; the very next run of the same binary passed Meal and failed Home at
    /// 25. Neither run changed a line of app code.
    ///
    /// A `Set` of frame-free identities removes both noise sources at the source: duplicates of an
    /// element-less category collapse to one member, and the frame is not part of the key. What it
    /// costs is stated plainly in ``identity(_:)``.
    ///
    /// **Why a disappearance is a failure and not a `print`.** It was a `print` before, on the
    /// argument that a suite which fails when someone *fixes* something gets deleted. That argument
    /// is only sound when the measurement is noisy, and the fix above is what makes it quiet. The
    /// house rule everywhere else in this repo — `AccessibilityBoundaryTests`'
    /// `everyAllowlistEntryStillMatchesSomething`, the Power-of-10 allowlist — is that an entry
    /// matching nothing is a hole nobody is watching, and it is a failure. This is that rule.
    ///
    /// The one exception, carved narrowly and measured rather than assumed, is
    /// ``unreportedCategories(found:baseline:)``: one audit type genuinely under-reports, and its
    /// absences are attached to the run instead of failing it. Read that doc comment before
    /// widening the list — it names what the exception costs.
    private func report(_ found: Set<String>, raw: [String], file: StaticString, line: UInt) {
        let baseline = Self.auditBaselines[name] ?? []
        let unreported = Self.unreportedCategories(found: found, baseline: baseline)
        let appeared = found.subtracting(baseline).sorted()
        let disappeared = baseline.subtracting(found).subtracting(unreported).sorted()
        attachListing(found: found, raw: raw, appeared: appeared, disappeared: disappeared,
                      unreported: unreported.sorted())

        // A screen with a non-empty baseline that returns NOTHING AT ALL is the auditor failing, not
        // the screen being fixed — reported as such, because the generic "no longer reproduce"
        // message below sends the reader to delete baseline lines that are perfectly accurate.
        //
        // **The measurement behind this, 2026-08-27.** `performAccessibilityAudit` degrades badly in
        // a long run. `ScreenAppearanceUITests` on its own: `Home tab` reported 13 distinct findings
        // from 14 raw. The SAME binary inside a whole-`FernletUITests` invocation: `Home tab` 0 raw,
        // `Private · Cycle (both halves)` 0 raw against a 27-entry baseline, `Sheet · Hygiene` 0
        // against 7, `Friends tab` 0 against 4 — fifteen screens at once. Every category went silent
        // together, which no combination of app fixes can do, and which is why this is attributed to
        // the auditor rather than to the app.
        //
        // **What this deliberately does NOT do.** It does not pass. A run that measured nothing has
        // validated nothing, and turning that green would make the wall lie in the one direction it
        // was built to prevent. It also does not rescue the *partial* answers seen in the same run
        // (`Food tab` 1 of 5, `Move tab` 1 of 5): a partial set is indistinguishable from a real
        // fix, so those still fail as disappearances. The practical consequence, stated plainly:
        // this wall is only meaningful when the probe suites are run in their own `xcodebuild`
        // invocation, which is the context ``auditBaselineEntries`` was recorded in and says so.
        if found.isEmpty && !baseline.isEmpty {
            XCTFail("""
                [\(name)] the accessibility audit returned NOTHING (0 raw issues) for a screen with \
                \(baseline.count) frozen baseline finding(s), TWICE — `audit(file:line:)` already \
                retried. That is almost certainly the auditor under-reporting rather than \
                \(baseline.count) findings being fixed at once, so do NOT delete the baseline lines \
                on the strength of this run.

                `performAccessibilityAudit` goes silent for whole screens inside a long run: \
                measured 2026-08-27, fifteen screens returned 0 raw issues in a whole-FernletUITests \
                invocation while the same binary reported them normally with \
                `-only-testing:FernletUITests/ScreenAppearanceUITests`.

                Re-run the probe suites in their own invocation before believing any delta here.
                """, file: file, line: line)
            return
        }

        if !appeared.isEmpty {
            XCTFail("""
                [\(name)] \(appeared.count) accessibility audit finding(s) that are NOT in this \
                screen's baseline. A new finding means this change made the screen less usable at \
                large text sizes or with VoiceOver. Fix it, or — if it is genuinely not a defect — \
                add an `AuditExemption` naming it and why. Do NOT paste it into `auditBaselines`.
                \(appeared.joined(separator: "\n"))
                """, file: file, line: line)
        }
        if !disappeared.isEmpty {
            XCTFail("""
                [\(name)] \(disappeared.count) baseline finding(s) no longer reproduce. If you \
                fixed them, delete these lines from `UXScreenProbe.auditBaselines` in the SAME \
                commit — a baseline entry that matches nothing is a hole nobody is watching, and it \
                would silently absorb the next finding that happens to describe itself the same way.
                \(disappeared.joined(separator: "\n"))
                """, file: file, line: line)
        }
    }

    /// Attaches the run's findings so the backlog is readable without re-running the audit: the raw
    /// listing (frames and duplicates included — that detail is what a fixer needs), then the
    /// identity set the wall actually compares, then the three deltas.
    private func attachListing(found: Set<String>, raw: [String],
                               appeared: [String], disappeared: [String], unreported: [String]) {
        let body = """
            [\(name)] \(found.count) distinct finding(s) from \(raw.count) raw issue(s)

            -- raw (as reported, with frames) --
            \(raw.isEmpty ? "none" : raw.sorted().joined(separator: "\n"))

            -- identities (what the ratchet compares) --
            \(found.isEmpty ? "none" : found.sorted().joined(separator: "\n"))

            -- not in baseline (FAILS) --
            \(appeared.isEmpty ? "none" : appeared.joined(separator: "\n"))

            -- baseline entries that did not reproduce (FAILS) --
            \(disappeared.isEmpty ? "none" : disappeared.joined(separator: "\n"))

            -- baseline entries whose whole audit category went unreported this run (not walled) --
            \(unreported.isEmpty ? "none" : unreported.joined(separator: "\n"))
            """
        let attachment = XCTAttachment(string: body)
        attachment.name = "\(name) – accessibility audit"
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }

    /// Audit categories this harness has **measured** to under-report: on any given run they may
    /// report all, some, or none of the issues a screen actually has.
    ///
    /// Two categories qualify, each added only after being measured across runs of an unchanged
    /// binary. `.dynamicType` was the first, and finding it is what closed the "the ratchet is red
    /// in suite and green in isolation" bug rather than papering over it: it is a *stateful* audit —
    /// the auditor has to re-render the screen at other content size categories before it can decide
    /// anything — and under load it silently returns a short answer. `Potentially inaccessible text`
    /// was the second, added 2026-08-27; its measurement is on the property below.
    ///
    /// **The measurement, in three runs of the same unchanged binary.** `Private · Cycle (both
    /// halves)` reported 23 Dynamic Type findings, then 0, while all 4 of its non-Dynamic-Type
    /// findings reproduced byte-for-byte both times. `Home tab` reported 18, then 12 — a *partial*
    /// answer, which is why this is not modelled as an all-or-nothing switch (that was the first
    /// hypothesis and the Home run refuted it). Across these runs, non-Dynamic-Type findings were
    /// stable except `.hitRegion` for the shared recipe quantity field: that finding has failed to
    /// reproduce nondeterministically in both recipe sheets on an unchanged binary. Those two
    /// entries are excluded from the frozen baseline rather than called fixed.
    ///
    /// Run those numbers back through the original bug report and they account for it completely:
    /// Home measured 19 findings in isolation and 25 in suite context, and 18 of Home's baseline
    /// entries are Dynamic Type. The "suite-order sensitivity" was never about suite order, and
    /// never about app-container state — it was this one audit type answering short.
    /// **The second category, measured 2026-08-27.** `Potentially inaccessible text` qualifies on
    /// the same evidence, and it took six runs of an unchanged binary on the pinned simulator to see
    /// it, because the subset it goes missing from is different every time. That category is frozen
    /// on seven screens (Hygiene, Meal, Saved recipe notes, Sleep, Water, Workout, Workout
    /// suggestion). Runs 3 and 4 reported it absent from Workout + Workout suggestion; run 5 from
    /// Saved recipe notes + Workout + Workout suggestion; run 6 from Meal + Water. No two runs
    /// agreed, no app code changed between them, and every OTHER category on those same screens
    /// reproduced exactly.
    ///
    /// Why this category and not the clipped-text ones next to it: `Potentially inaccessible text`
    /// is the audit's most frequently ELEMENT-LESS finding, so ``identity(_:)`` degrades it to the
    /// bare category string (that cost is documented there). An identity carrying no element is one
    /// the auditor can drop without anything else about the screen changing — which is exactly the
    /// shape of what was measured. The cost is the same cost the Dynamic Type entry already pays and
    /// should be read the same way: on any given run those seven entries may be watched in one
    /// direction only.
    static let underReportingCategoryPrefixes = ["Dynamic Type font sizes",
                                                 "Potentially inaccessible text"]

    /// The baseline entries that must not be read as fixed just because this run did not report
    /// them — i.e. the ones belonging to an under-reporting category.
    ///
    /// **The asymmetry is the whole design.** A finding that *appears* fails unconditionally, in
    /// every category including this one: the auditor's failure mode is under-reporting, it does not
    /// invent issues, so an appearance is always real. Only an *absence* is ambiguous, and only for
    /// the categories listed above. Every other category is still walled in both directions, so a
    /// fixed clipped label still forces its baseline line to be deleted in the same commit.
    ///
    /// **What this costs, measured — and it is more than "a fix might go unnoticed".** On any given
    /// run, whatever this excuses is baseline that is not being walled *at all*, in either
    /// direction. Observed on passing runs: **5 of Home's 18** Dynamic Type entries excused on one,
    /// **6 of 18** on another, and on one `Private · Cycle (both halves)` run **23 of 23** — the
    /// screen's entire Dynamic Type baseline. So a third of Home's Larger Text backlog is typically
    /// unwatched, and occasionally a whole screen's is. Since Dynamic Type is 46 of the 135 frozen
    /// identities, that is a materially large hole and it should be read as one.
    ///
    /// The practical consequence: a genuine Dynamic Type fix will not make this suite red, so those
    /// entries can go stale without anyone being told. They are listed in every run's attachment
    /// under "whose category under-reports", which is where the Larger Text burn-down should be read
    /// from — but it is a weaker guarantee than the rest of the wall has, and it is weaker because
    /// the measurement is weaker, not because the criterion matters less. The
    /// alternative considered and rejected was subtracting `.dynamicType` from ``auditTypes``
    /// altogether, the way `.contrast` is: that would make the wall silent about the exact criterion
    /// the undeclared Larger Text row is blocked on.
    ///
    /// Matching is on the `compactDescription` prefix, which is Apple's wording and could change.
    /// The failure direction of that brittleness is the safe one: if the wording moves, these
    /// entries stop being recognised, stop being excused, and the wall goes **red** and loud rather
    /// than quietly permissive.
    static func unreportedCategories(found: Set<String>, baseline: Set<String>) -> Set<String> {
        var skipped: Set<String> = []
        for prefix in underReportingCategoryPrefixes {
            skipped.formUnion(baseline.filter { $0.hasPrefix(prefix) })
        }
        return skipped.subtracting(found)
    }

    /// One suppressed audit issue, matched on the audit type plus a substring of the issue's own
    /// description. Every entry states the invariant that makes it safe.
    struct AuditExemption: Sendable {
        /// The audit type the entry applies to.
        let auditType: XCUIAccessibilityAuditType
        /// A substring of `XCUIAccessibilityAuditIssue.compactDescription`.
        let descriptionContains: String
        /// Why this issue is not a defect.
        let reason: String
    }

    /// Audit issues deliberately suppressed, individually, with a reason.
    ///
    /// Empty on purpose. The measured backlog — 119 raw issues, which collapse to **135 identities
    /// across 22 screens** once duplicates and volatile values are keyed out — was **not** waved
    /// through here. It is frozen per screen in ``auditBaselines`` instead, so every one of those
    /// findings stays visible and attached to the run. This list is for the different case: a
    /// specific issue that is provably
    /// not a defect (a platform artifact, an element the audit misreads). Nothing has qualified yet,
    /// and the bar for adding an entry is the same as the other two walls' allowlists — state the
    /// invariant, not the inconvenience.
    static let auditExemptions: [AuditExemption] = []

    /// The per-screen baseline: the **exact set of issue identities** each probe screen is known to
    /// report, frozen. A ratchet in the same spirit as `Scripts/power-of-10-scan.py`'s
    /// `DENSITY_FLOOR` and `Scripts/accessibility-allowlist.json` — entries only ever come out.
    ///
    /// **Why a baseline and not a zero start.** The other two walls in this repo start clean
    /// because they were built alongside the fixes. This one could not: its first run over the
    /// probe screens found **119 raw issues**, and they are real. The breakdown, measured
    /// 2026-08-23 on iPhone 17 / iOS 26 with the standard demo seed:
    ///
    /// | Category | Count |
    /// |---|---|
    /// | Text clipped | 76 |
    /// | Dynamic Type font sizes are partially unsupported | 19 |
    /// | Hit area is too small | 15 |
    /// | Potentially inaccessible text | 7 |
    /// | Label not human | 2 |
    ///
    /// Three honest observations about that number. First, it is **not** a contradiction of the
    /// 2026-08-16 round's hit-target work: 15 sub-44pt regions across dense screens is a small
    /// residue, and several are inside system-drawn controls. Second, the 76 + 19 that are text and
    /// Dynamic Type findings are exactly the **Larger Text** criterion, which is why that App Store
    /// row is undeclared — that run is the first time anyone measured how far away it is. Third,
    /// the two "Label not human" findings are the highest-signal items in the whole set and should
    /// be fixed first: that category means an SF Symbol name or a raw token is being spoken.
    ///
    /// **The identities below are fewer than 119** and that is not a burn-down: they are the
    /// *distinct* identities the raw issues collapse to, which is what a set of frame-free keys
    /// means (see ``identity(_:)``). The raw count is still attached to every run.
    ///
    /// A screen with no entry here has an **empty** baseline and fails on its first finding, so a
    /// newly added probe starts clean by construction. `Tests/FernletTests/AuditRatchetBoundaryTests`
    /// is the staleness half: a key here whose probe was deleted or renamed fails that wall, so a
    /// baseline cannot outlive the screen it describes.
    static let auditBaselines: [String: Set<String>] = auditBaselineEntries

    /// A **stable** identity for one audit issue: category, element label, element identifier and
    /// element type — and deliberately **not** the frame.
    ///
    /// The frame is what made a count-based ratchet flap. Its float digits differ between two runs
    /// of the same unchanged screen (`27.203980099502488`), so a key containing it is a key that
    /// never matches itself twice.
    ///
    /// **The honest cost, stated because it is a real hole.** `issue.element` is optional, and when
    /// it is `nil` this degrades to the bare category — so *all* element-less "Text clipped" issues
    /// on one screen share a single identity, and going from one to six of them does not fail this
    /// wall. That is a deliberate trade: those issues carry nothing that distinguishes them, so a
    /// count over them was measuring the audit's own resolution luck rather than the app. Six
    /// element-less clipped texts and one are equally unactionable; a clipped text that *does*
    /// resolve an element is actionable and is keyed individually. The raw listing is attached to
    /// every run so the multiplicity is never lost, only un-walled.
    static func identity(_ issue: XCUIAccessibilityAuditIssue) -> String {
        guard let element = issue.element else { return issue.compactDescription }
        let label = element.label.isEmpty ? "<no label>" : "“\(normalisedLabel(element.label))”"
        let identifier = element.identifier.isEmpty ? "" : " id=\(element.identifier)"
        return "\(issue.compactDescription) — \(label)\(identifier) (\(element.elementType.rawValue))"
    }

    /// Weekday and month names, whose presence next to a numeral makes a label a DATE.
    static let volatileDateWords = [
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
        "January", "February", "March", "April", "May", "June", "July", "August",
        "September", "October", "November", "December"
    ]

    /// A label with wall-clock and seed-derived values replaced by placeholders, so an identity
    /// keyed on it survives midnight, the first of the month, and a change to the demo seed.
    ///
    /// **This is a time bomb the frame fix did not defuse.** Three of the frozen identities were
    /// rendered from the clock or the seed: `"SUNDAY, AUGUST 23"` (Home's date eyebrow), `"August
    /// 2026"` (the month calendar's title), and `"2 entries"` / `"2 of 8"` (seeded counts, and the
    /// last two land in the Text-clipped category, which is walled in *both* directions). The day
    /// the date rolls, the frozen literal stops reproducing **and** the new one is an unrecognised
    /// appearance — an unconditional failure. Worse, it would be *intermittent*: whether it fires
    /// depends on whether the under-reporting Dynamic Type pass happened to include that element on
    /// that run, which is the most expensive kind of red to diagnose.
    ///
    /// Two rules, both narrow on purpose:
    /// 1. **Nothing happens unless the label contains a numeral.** Every date this app renders
    ///    carries one, and requiring it keeps the substitution off ordinary copy — a sentence
    ///    mentioning "May" or "March" with no number is left exactly as written.
    /// 2. Then weekday and month names collapse to `<date-word>` and each run of digits to `#`.
    ///
    /// **The one collapse this causes, measured rather than assumed.** Normalising the 136 frozen
    /// identities yields 135: Home's `"1 logged"` and `"3 logged"` both become `"# logged"`. That is
    /// the *only* collision in the whole baseline. It is also the benign kind — the two labels are
    /// the same `QuickLogButton` component rendered twice with different seeded counts, so this
    /// merges two instances of one defect rather than hiding a second defect. Every other identity
    /// stays distinct, including the two `"0g"` chips (different screens) and `"# of #"` versus
    /// `"# entries"`. If a future change makes this map two genuinely different defects together,
    /// the symptom is a baseline that shrinks when it should not, and the fix is to key on the
    /// element identifier rather than to widen the placeholder.
    ///
    /// Known over-reach, accepted: substring matching means `"Marching"` inside a label that also
    /// has a digit becomes `"<date-word>ing"`. It is deterministic and harmless — an identity only
    /// has to be *stable*, not pretty.
    static func normalisedLabel(_ label: String) -> String {
        guard label.contains(where: { $0.isNumber }) else { return label }
        var out = label
        for word in volatileDateWords {
            out = out.replacingOccurrences(of: word, with: "<date-word>", options: [.caseInsensitive])
        }
        var collapsed = ""
        var inNumber = false
        for character in out {
            guard character.isNumber else {
                collapsed.append(character)
                inNumber = false
                continue
            }
            if !inNumber { collapsed.append("#") }
            inNumber = true
        }
        return collapsed
    }

    /// An audit issue rendered so someone can act on it without re-running the audit: the element's
    /// label **exactly as rendered** — not normalised — plus its identifier, type and frame.
    ///
    /// Deliberately not built on ``identity(_:)``. The two want opposite things: a report is read by
    /// a person who needs the real date and the real count to find the element on screen, and a key
    /// needs every one of those volatile values gone.
    static func describe(_ issue: XCUIAccessibilityAuditIssue) -> String {
        guard let element = issue.element else { return issue.compactDescription }
        let label = element.label.isEmpty ? "<no label>" : "“\(element.label)”"
        let identifier = element.identifier.isEmpty ? "" : " id=\(element.identifier)"
        return "\(issue.compactDescription) — \(label)\(identifier) "
            + "(\(element.elementType.rawValue), frame \(element.frame))"
    }

    /// The exemption covering `issue`, if any.
    static func exemption(for issue: XCUIAccessibilityAuditIssue) -> AuditExemption? {
        auditExemptions.first {
            issue.auditType.contains($0.auditType)
                && issue.compactDescription.contains($0.descriptionContains)
        }
    }

    // MARK: Screenshot gallery

    /// Attaches a labeled, always-kept screenshot of the current screen for visual review, and
    /// runs the accessibility audit on the same screen.
    ///
    /// The audit is chained here rather than added as a separate opt-in step because `capture()`
    /// is already the one call every one of the 37 screen probes makes, and an opt-in audit is one
    /// nobody remembers to opt into on the screen they just added. That is also why this method
    /// now `throws`: see ``audit(file:line:)``.
    @discardableResult
    func capture(_ suffix: String = "", file: StaticString = #file, line: UInt = #line) throws -> Self {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = suffix.isEmpty ? name : "\(name) – \(suffix)"
        attachment.lifetime = .keepAlways
        test.add(attachment)
        return try audit(file: file, line: line)
    }
}

// MARK: - The frozen baselines

extension UXScreenProbe {

    /// The frozen per-screen identity sets behind ``auditBaselines``.
    ///
    /// Kept out of the main type so the map can be read as data. **Recorded, not invented**: every
    /// line below was copied verbatim from a full-suite run's "not in baseline" listing, so each
    /// one is a finding the audit really reported on that screen. Adding a line by hand — rather
    /// than by pasting what a run printed — defeats the whole wall, and reviewing a change to this
    /// map means asking which run produced it.
    ///
    /// Measured 2026-08-23 on the `Fernlet-A11y` simulator (iPhone 17 / iOS 26) with the standard
    /// `FERNLET_UI_TEST_SEED_DEMO` seed, from a full `ScreenAppearanceUITests` suite run — not from
    /// isolated per-test runs, because suite context is the bar this wall has to hold.
    /// THE 2026-08-27 HARVEST GAP. Everything below the `Food · Recipe detail` entry down to
    /// `Studio · Editor` was recorded on 2026-08-27 and is the same *kind* of record as the
    /// 2026-08-23 block: measured, not invented. It exists because the original harvest was taken
    /// "from a full `ScreenAppearanceUITests` suite run" while `capture()` audits EVERY probe in
    /// EVERY suite — so the nine probes that live in other suites (`RecentBitesUITests`,
    /// `ProgressPhotoUITests`, `OnboardingAppearanceUITests`, `NutritionTargetsEditorUITests`,
    /// `ItemCreationFlowUITests`, `RecipeDetailUITests`, `SettingsAppearanceUITests`) started from
    /// an EMPTY baseline and have failed on their first finding ever since. Nothing regressed; they
    /// were never measured. `FernletUITests` is not run by any CI workflow — `.github/workflows/`
    /// only invokes named `FernletTests` boundary suites — which is how that stayed unnoticed.
    ///
    /// Every entry here was copied from the "not in baseline" listing of a run on the pinned
    /// simulator and confirmed on a second, independent run. The high-signal findings the original
    /// harvest note says to fix first were FIXED in the same commit rather than frozen: six
    /// `Label not human-readable` (three SF Symbol names announced on the very first onboarding
    /// screen, two on Settings · Health, one on Settings · Signals) and one
    /// `Element has no description` on the full-size progress photo. What is frozen below is the
    /// Larger Text backlog these screens share with the other twenty-two.
    static let auditBaselineEntries: [String: Set<String>] = [
        "Food · Recipe detail": [
            "Text clipped — “Friends” (9)",
            "Text clipped — “Home” (9)",
            "Text clipped — “Move” (9)",
            "Text clipped — “Private” (9)",
        ],
        // SCREEN-HEADER SUBTITLE NO LONGER CLIPS (2026-08-27): `ScreenHeader`'s subtitle still
        // renders (FoodView.swift:87) — it is the clipping that stopped, not the element that went
        // away. The tab-bar clearance and scroll-position work that landed after the baseline
        // (e2ebd98, 1ff3294, 92678e8) is the layout change in that window. Same removal on `Move
        // tab`, which uses the same component. Re-verified deterministic across two independent
        // `xcodebuild test` runs on the pinned simulator before removing.
        "Food tab": [
            "Hit area is too small — “Adjust targets” id=food.adjustTargets (9)",
            "Text clipped — “Friends” (9)",
            "Text clipped — “Home” (9)",
            "Text clipped — “Move” (9)",
            "Text clipped — “Private” (9)",
        ],
        "Friends tab": [
            "Text clipped — “Friends” (9)",
            "Text clipped — “Home” (9)",
            "Text clipped — “Move” (9)",
            "Text clipped — “Private” (9)",
        ],
        "Home · Recent bites": [
            "Text clipped — “Chicken rice bowl” (48)",
            "Text clipped — “Food” (9)",
            "Text clipped — “Friends” (9)",
            "Text clipped — “Greek yogurt with berries” (48)",
            "Text clipped — “Home” (9)",
            "Text clipped — “Move” (9)",
            "Text clipped — “Private” (9)",
        ],
        // QUICK-LOG SUBTITLES NO LONGER CLIP (2026-08-27): `Text clipped — “# entries”` and
        // `“# of #”` both stopped reproducing. Note the first one has a second possible reading and
        // it is worth knowing which: `HomeView.swift:1361` renders "1 entry" (singular) below two
        // entries, and `normalisedLabel` maps that to “# entry” — a DIFFERENT identity from
        // “# entries”. So a seed that logs one entry rather than two would retire this line without
        // anything being fixed. Either way the finding does not reproduce and the line has to go;
        // flagged here because the singular/plural fork is a live time bomb for any future
        // count-bearing identity. Re-verified deterministic across two independent runs.
        "Home tab": [
            "Dynamic Type font sizes are partially unsupported — “# bottles” (48)",
            "Dynamic Type font sizes are partially unsupported — “# entries” (48)",
            "Dynamic Type font sizes are partially unsupported — “# logged” (48)",
            "Dynamic Type font sizes are partially unsupported — “# of #” (48)",
            "Dynamic Type font sizes are partially unsupported — “#h” (48)",
            "Dynamic Type font sizes are partially unsupported — “<date-word>, <date-word> #” (48)",
            "Dynamic Type font sizes are partially unsupported — “Care” (48)",
            "Dynamic Type font sizes are partially unsupported — “Fernlet” (48)",
            "Dynamic Type font sizes are partially unsupported — “I'm unwell today” (48)",
            "Dynamic Type font sizes are partially unsupported — “Journal” (48)",
            "Dynamic Type font sizes are partially unsupported — “Meals” (48)",
            "Dynamic Type font sizes are partially unsupported — “Move” (48)",
            "Dynamic Type font sizes are partially unsupported — “Quick log” (48)",
            "Dynamic Type font sizes are partially unsupported — “Scoring goes gentle until tomorrow” (48)",
            "Dynamic Type font sizes are partially unsupported — “Sleep” (48)",
            "Dynamic Type font sizes are partially unsupported — “Today” (48)",
            "Dynamic Type font sizes are partially unsupported — “Water” (48)",
            "Hit area is too small — “Care score # percent” (1)",
            "Text clipped — “Friends” (9)",
            "Text clipped — “Home” (9)",
            "Text clipped — “Move” (9)",
            "Text clipped — “Private” (9)",
        ],
        "Move · Progress photo detail": [
            "Text clipped — “Friends” (9)",
            "Text clipped — “Home” (9)",
            "Text clipped — “Move” (9)",
            "Text clipped — “Private” (9)",
        ],
        "Move · Progress photos": [
            "Text clipped — “Feeling stronger” (48)",
            "Text clipped — “Food” (9)",
            "Text clipped — “Friends” (9)",
            "Text clipped — “Home” (9)",
            "Text clipped — “Move” (9)",
            "Text clipped — “Private” (9)",
        ],
        // SCREEN-HEADER SUBTITLE NO LONGER CLIPS (2026-08-27): same component and same reason as
        // `Food tab` above (MoveView.swift:133 still renders it).
        //
        // SEED-DETERMINISM CORRECTION (2026-08-27): `Text clipped — “Full gym · # items”` is the
        // Move header's equipment segment (`MoveView.swift:2523`), and it is NEW here only because
        // the active workout location is now pinned by the demo seed. It previously read whatever
        // `WorkoutLocationUITests` had last left persisted — "Shed", which is short enough not to
        // clip — so this screen's real behaviour under the SHIPPED default was never measured. It
        // is a genuine clipped-text finding and joins the Larger Text backlog the rest of this map
        // freezes rather than a defect this round introduced.
        "Move tab": [
            "Label not human-readable — “figure.strengthtraining.traditional” id=figure.strengthtraining.traditional (43)",
            "Text clipped — “Friends” (9)",
            "Text clipped — “Full gym · # items” (48)",
            "Text clipped — “Home” (9)",
            "Text clipped — “Move” (9)",
            "Text clipped — “Private” (9)",
        ],
        // The eight onboarding screens. The `Hit area is too small — “Continue”` entries are all one
        // component: `SheetSaveBar`'s commit button, whose sub-44pt finding is ALREADY frozen for
        // `Sheet · Sleep` and `Sheet · Log intimacy`. It is deliberately not fixed here — one change
        // inside `FernletUIComponents.swift` would move ~41 call sites at once and shift several
        // frozen sheets in the same commit, which is its own increment, not a side effect of this
        // one. The identifiers on those entries are the screen containers' (a container
        // `accessibilityIdentifier` propagates to descendants that lack their own), which is why
        // one button reads as `id=onboarding.welcome`.
        "Onboarding · Dietary pattern": [
            "Hit area is too small — “Continue” id=onboarding.diet (9)",
            "Text clipped — “Pick an eating pattern” (48)",
        ],
        "Onboarding · Goal": [
            "Hit area is too small — “Continue” id=onboarding.goal (9)",
        ],
        "Onboarding · Lock setup": [
            "Text clipped — “Protect private spaces” (48)",
            "Text clipped — “The lock guards period, intimacy, and other sensitive areas before they open.” (48)",
        ],
        "Onboarding · Permissions": [
            "Hit area is too small — “Start Fernlet” id=onboarding.permissions (9)",
            "Text clipped — “Fernlet asks at first use where practical, so you can start without granting everything now.” (48)",
        ],
        "Onboarding · Personal details": [
            "Hit area is too small — “Continue” id=onboarding.personal (9)",
            "Text clipped — <no label> id=onboarding.displayName (49)",
            "Text clipped — “These are optional except age. Fernlet never asks for weight goals.” (48)",
        ],
        "Onboarding · Starter": [
            "Hit area is too small — “Continue” id=onboarding.starter (9)",
        ],
        "Onboarding · Storage choice": [
            "Text clipped — “Choose where logs live” (48)",
        ],
        "Onboarding · Welcome": [
            "Hit area is too small — “Continue” id=onboarding.welcome (9)",
            "Text clipped — “A small daily care companion built around privacy, local control, and enoughness.” (48)",
        ],
        "Private · Cycle (both halves)": [
            "Dynamic Type font sizes are partially unsupported — “<date-word> #” (48)",
            "Dynamic Type font sizes are partially unsupported — “Cycle” (48)",
            "Dynamic Type font sizes are partially unsupported — “Cycle” (9)",
            "Dynamic Type font sizes are partially unsupported — “Food” (9)",
            "Dynamic Type font sizes are partially unsupported — “Friends” (9)",
            "Dynamic Type font sizes are partially unsupported — “F” (48)",
            "Dynamic Type font sizes are partially unsupported — “Heavy” (48)",
            "Dynamic Type font sizes are partially unsupported — “Home” (9)",
            "Dynamic Type font sizes are partially unsupported — “Intimacy” (48)",
            "Dynamic Type font sizes are partially unsupported — “Journal” (9)",
            "Dynamic Type font sizes are partially unsupported — “Light” (48)",
            "Dynamic Type font sizes are partially unsupported — “Log at least # cycles to see predictions.” (48)",
            "Dynamic Type font sizes are partially unsupported — “Medium” (48)",
            "Dynamic Type font sizes are partially unsupported — “Move” (9)",
            "Dynamic Type font sizes are partially unsupported — “M” (48)",
            "Dynamic Type font sizes are partially unsupported — “Once you've logged a few cycles, Fernlet can gently soften your daily score on the phases that tend to be harder for you, and show a cycle chip and outlook on Home. It's optional, stays on this device, and never leaves the app.” (48)",
            "Dynamic Type font sizes are partially unsupported — “Period-aware care” (48)",
            "Dynamic Type font sizes are partially unsupported — “Private” (9)",
            "Dynamic Type font sizes are partially unsupported — “S” (48)",
            "Dynamic Type font sizes are partially unsupported — “T” (48)",
            "Dynamic Type font sizes are partially unsupported — “Worry box” (9)",
            "Dynamic Type font sizes are partially unsupported — “W” (48)",
            "Dynamic Type font sizes are partially unsupported — “Your cycle, at a glance.” (48)",
            "Text clipped — “Friends” (9)",
            "Text clipped — “Home” (9)",
            "Text clipped — “Move” (9)",
            "Text clipped — “Private” (9)",
        ],
        "Private · Cycle (intimacy only)": [
            "Text clipped — “Friends” (9)",
            "Text clipped — “Home” (9)",
            "Text clipped — “Move” (9)",
            "Text clipped — “Private” (9)",
        ],
        "Private · Cycle (period only)": [
            "Text clipped — “Friends” (9)",
            "Text clipped — “Home” (9)",
            "Text clipped — “Move” (9)",
            "Text clipped — “Private” (9)",
        ],
        "Private · Journal": [
            "Dynamic Type font sizes are partially unsupported — “F” (48)",
            "Dynamic Type font sizes are partially unsupported — “M” (48)",
            "Dynamic Type font sizes are partially unsupported — “S” (48)",
            "Dynamic Type font sizes are partially unsupported — “T” (48)",
            "Dynamic Type font sizes are partially unsupported — “W” (48)",
            "Text clipped — “Friends” (9)",
            "Text clipped — “Home” (9)",
            "Text clipped — “Move” (9)",
            "Text clipped — “Private” (9)",
        ],
        "Settings · Core memory": [
            "Text clipped — <no label> (49)",
        ],
        "Settings · Hub": [
            "Dynamic Type font sizes are partially unsupported — “Done” id=settings.done (9)",
            "Dynamic Type font sizes are partially unsupported — “PRIVACY & DATA” (48)",
            "Dynamic Type font sizes are unsupported",
            "Text clipped — “Search settings” (45)",
        ],
        // The fully-derived state has no entry here on purpose: it reports nothing, because with no
        // override pinned there is no Reset control to be too small. The pinned variant below is
        // where that finding lives.
        "Settings · Nutrition targets (calories pinned)": [
            "Hit area is too small — “Reset” id=nutritionTargets.reset (9)",
        ],
        "Settings · Personal care tasks": [
            "Text clipped — <no label> (49)",
            "Text clipped — “PERSONAL CARE TASKS” (48)",
        ],
        // BASELINE CORRECTION (2026-08-23), separate from T1-9: both recipe sheets share the
        // sub-44pt `TextField("Qty")` in FoodView. Its `.hitRegion` finding was proven to flap on
        // pristine ba6d561, so the two non-deterministic entries are not frozen as ratchet truth.
        //
        // IDENTITY-KEY MIGRATION (2026-08-27), and it is deliberately NOT the "paste the new
        // finding in" move this map's failure message forbids. The finding did not change; its KEY
        // did. `525b0c8` gave FoodView's ingredient search field an accessibility identifier
        // (`recipeIngredient.search`, FoodView.swift:2070), and ``identity(_:)`` folds the
        // identifier into the key — so one unchanged clipped text field stopped reporting as
        // `<no label> (49)` and started reporting as `<no label> id=recipeIngredient.search (49)`.
        // Three things establish that it is the same finding rather than a fix plus a regression:
        // the disappearance and the appearance happen in the SAME run, on BOTH recipe sheets, and
        // the new key names the exact field the old one described anonymously. Re-verified
        // deterministic across two independent runs on the pinned simulator. The clipping itself is
        // untouched — it stays part of the Larger Text backlog this round did not take on.
        "Sheet · Edit recipe": [
            "Hit area is too small — “#g” (9)",
            "Text clipped — <no label> id=recipeIngredient.search (49)",
        ],
        "Sheet · Goals": [
            "Hit area is too small — “Craft” (9)",
            "Text clipped — <no label> (49)",
        ],
        "Sheet · Hygiene": [
            "Potentially inaccessible text",
            "Text clipped — “Brush teeth AM” (48)",
            "Text clipped — “Deodorant” (48)",
            "Text clipped — “Personal care” (48)",
            "Text clipped — “Shower” (48)",
            "Text clipped — “Skincare AM” (48)",
            "Text clipped — “Sunscreen” (48)",
        ],
        "Sheet · Journal": [
            "Hit area is too small — “Start from this” id=journal.inspiration (9)",
        ],
        "Sheet · Log intimacy": [
            "Hit area is too small — “Save” (9)",
        ],
        "Sheet · Meal": [
            "Potentially inaccessible text",
            "Text clipped",
            "Text clipped — “Log meal” (48)",
            "Text clipped — “WHAT DID YOU EAT?” (48)",
        ],
        // Same identity-key migration as `Sheet · Edit recipe` above — the two sheets share the
        // ingredient search field that gained `recipeIngredient.search` in 525b0c8.
        "Sheet · Recipe": [
            "Hit area is too small — “#g” (9)",
            "Text clipped — <no label> id=recipeIngredient.search (49)",
        ],
        "Sheet · Recipe book": [
            "Text clipped — <no label> (49)",
            "Text clipped — “Seeded demo recipe. Mix, chill overnight, top with fruit.” (48)",
            "Text clipped — “Seeded demo recipe. Roast at # for # minutes.” (48)",
        ],
        "Sheet · Saved recipe notes": [
            "Potentially inaccessible text",
            "Text clipped — “Delete recipe” (48)",
            "Text clipped — “Demo recipe” (48)",
        ],
        "Sheet · Sleep": [
            "Hit area is too small — <no label> (49)",
            "Hit area is too small — “Save” (9)",
            "Potentially inaccessible text",
            "Text clipped — <no label> (49)",
            "Text clipped — “HOURS (OPTIONAL)” (48)",
            "Text clipped — “NOTE (OPTIONAL)” (48)",
            "Text clipped — “restorative, woke easy” (48)",
        ],
        "Sheet · Trends": [
            "Label not human-readable — “face.smiling” id=face.smiling (43)",
            "Text clipped",
        ],
        "Sheet · Water": [
            "Potentially inaccessible text",
            "Text clipped",
        ],
        // T1-9 (CHIP 44PT GROWTH, 2026-08-23): `kindField`'s Strength/Cardio chips are the FIRST
        // child of this sheet's ScrollView VStack, directly above `recentExerciseChips` ->
        // `strengthSection` -> `WorkoutExerciseBuilder`'s `id=exercise.search` field. Growing the
        // chip row's layout box from ~34pt to 44pt (`ChipButtonStyle`, FernletUIComponents.swift)
        // shifts every sibling below it down by the same ~10pt within this one scrollable sheet,
        // which is exactly why "Text clipped — <no label> id=exercise.search (49)" (the field's
        // clipping relative to the sheet's visible viewport at audit time) no longer reproduces.
        // Re-verified deterministic across two independent `xcodebuild test` runs before removing.
        "Sheet · Workout": [
            "Potentially inaccessible text",
            "Text clipped",
            "Text clipped — “Bench press” (48)",
            "Text clipped — “Log workout” (48)",
            "Text clipped — “Overhead press” (48)",
        ],
        // T1-9 (CHIP 44PT GROWTH, 2026-08-23): `feelingSection`'s Light/Moderate/Hard chips sit
        // directly above `SheetField("Anything else?")` in `configuratorContent`. That content was
        // hand-budgeted to fit the 437pt medium detent before T1-9. Growing the chip row's layout
        // box by ~10pt (`ChipButtonStyle`) breaks that old exact fit and shifts the "ANYTHING ELSE?"
        // caption's position relative to the sheet's visible viewport, which is why
        // "Text clipped — “ANYTHING ELSE?” (48)" no longer reproduces. Re-verified deterministic
        // across two independent `xcodebuild test` runs before removing. NOTE: this is a real
        // layout consequence, not just an audit artifact — see the increment's report for whether
        // the medium-detent budget needs to grow to match (out of this increment's scope).
        //
        // SEED-DETERMINISM CORRECTION (2026-08-27): `Text clipped — “Shed · # items”` became
        // `“Full gym · # items”`. One finding, one element — the sheet's SPACE & EQUIPMENT segment —
        // renamed because the demo seed now pins the active workout location to the shipped default
        // instead of inheriting whatever `WorkoutLocationUITests` last persisted. "Shed" was another
        // suite's leftover, so this line had been pinning test order rather than the app. See the
        // matching note on `Move tab`, where the same rename ADDS a finding: the default name is
        // longer, and the Move header's segment clips at it where "Shed" did not.
        "Sheet · Workout suggestion": [
            "Potentially inaccessible text",
            "Text clipped",
            "Text clipped — “Full gym · # items” (48)",
            "Text clipped — “SPACE & EQUIPMENT” (48)",
            "Text clipped — “Suggest a workout” id=workout.suggest (9)",
            "Text clipped — “Suggest workout” (48)",
        ],
        "Studio · Confirmation (flagged name)": [
            "Dynamic Type font sizes are partially unsupported",
            "Dynamic Type font sizes are partially unsupported — “Pick a friendlier name” (48)",
            "Dynamic Type font sizes are partially unsupported — “This name can't be used in your shop. Your item is saved — rename it and try listing again. (Private items can be named anything.)” (48)",
            "Potentially inaccessible text",
        ],
        "Studio · Editor (name/shop moved off)": [
            "Hit area is too small — “Mirror” id=studio.mirror (9)",
        ],
    ]
}
