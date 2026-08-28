// AuditRatchetBoundaryTests.swift
// FernletTests
//
// The STALENESS half of the runtime accessibility audit's ratchet
// (`Tests/FernletUITests/UXScreenProbe.auditBaselines`).
//
// Why this lives here and not in the UI target. The ratchet itself can only ever check the screens
// a run actually visits: if a probe is deleted or its screen renamed, its baseline entry is simply
// never consulted, and the wall stays green while silently watching nothing. That is the same hole
// `AccessibilityBoundaryTests.everyAllowlistEntryStillMatchesSomething` closes for the grep-wall's
// allowlist, and it is closed the same way — by reading the SOURCE and asserting that every frozen
// entry still corresponds to something real. A test inside the UI suite cannot do this, because it
// would have to have run every other test in the suite first to know which screens were visited.
//
// What this wall cannot see, stated because it is what stops it being mistaken for coverage: it
// checks that a baseline entry NAMES A SCREEN THAT IS STILL PROBED. It does not check that the
// baseline's contents are still accurate — only a run can do that, and the ratchet does it there,
// failing in both directions.

import Foundation
import Testing

/// Pins the runtime audit ratchet's bookkeeping: every frozen baseline still names a probed screen,
/// and the probe inventory itself cannot silently shrink.
@Suite struct AuditRatchetBoundaryTests {

    /// The file declaring ``UXScreenProbe/auditBaselineEntries``.
    static let probeSourcePath = "Tests/FernletUITests/UXScreenProbe.swift"

    /// The directory whose `.swift` files construct probes.
    static let uiTestRoot = "Tests/FernletUITests"

    /// Floor on the number of distinct probe screen names found in the UI suites (37 at the time of
    /// writing). Set below the real count so ordinary churn never trips it, but deleting a whole
    /// suite does. Without it, "every baseline entry is probed" and "the parse found nothing" are
    /// the same green result.
    static let minimumProbedScreens = 30

    /// Floor on the number of frozen baseline entries. Same non-vacuity argument: an empty map
    /// satisfies "every entry is still probed" trivially, so an accidental wipe of the map would
    /// otherwise read as a clean wall rather than as a disabled one.
    static let minimumBaselineEntries = 20

    /// Reads a repo-relative file.
    static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: RepoRoot.url.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Every capture-group-1 match of `pattern` in `text`.
    ///
    /// Bounded by the match count `NSRegularExpression` returns, which is bounded by the length of
    /// `text` — Power of 10 rule 2 holds without an explicit counter.
    static func captures(_ pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }

    /// The screen names every UI suite probes, as written in source.
    ///
    /// Two construction shapes exist and both are read: the direct `UXScreenProbe(app, "Name", …)`
    /// and `ScreenAppearanceUITests`' `probeSheet("id", "Name")` helper, which passes the name
    /// through a variable the direct pattern cannot see.
    ///
    /// Names containing a `\(` interpolation are DROPPED rather than matched literally: one probe
    /// builds its name from a loop variable (`"Settings · \(title)"`), so the literal in source is
    /// not a name any baseline could ever key on. Dropping it is correct — it simply means such a
    /// screen cannot be ratcheted — and silently *keeping* it would let a baseline entry named after
    /// the raw interpolation text pass this wall forever.
    static func probedScreenNames() throws -> Set<String> {
        let base = RepoRoot.url.appendingPathComponent(uiTestRoot)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return [] }
        var names: Set<String> = []
        for entry in entries.sorted() where entry.hasSuffix(".swift") {
            let text = try source("\(uiTestRoot)/\(entry)")
            names.formUnion(try captures(#"UXScreenProbe\(\s*app\s*,\s*"([^"]+)""#, in: text))
            names.formUnion(try captures(#"probeSheet\(\s*"[^"]+"\s*,\s*"([^"]+)""#, in: text))
            // Third shape: `OnboardingAppearanceUITests`' `probe("Onboarding · Welcome", title:…)`
            // helper, which — like `probeSheet` — hands the name to `UXScreenProbe` through a
            // variable the direct pattern cannot see. Added when the eight onboarding screens were
            // first baselined (2026-08-27); without it every one of them reads as orphaned.
            // Lower-case `probe(` is deliberate and sufficient to keep this off `UXScreenProbe(`
            // and `probeSheet(`: the regex is case-sensitive and both differ before the paren.
            names.formUnion(try captures(#"\bprobe\(\s*"([^"]+)""#, in: text))
            // Fourth shape: `SettingsAppearanceUITests` walks a table of labelled tuples and probes
            // each with the `probe:` element, spelled out as a literal precisely so this wall can
            // see it. Keyed on the argument LABEL rather than on tuple position, so re-ordering the
            // table's columns cannot silently empty this. It cannot match the baseline map in
            // `UXScreenProbe.swift` (also scanned by this parse) because nothing there is labelled.
            names.formUnion(try captures(#"probe:\s*"([^"]+)""#, in: text))
        }
        return names.filter { !$0.contains(#"\("#) }
    }

    /// The screen names frozen in ``UXScreenProbe/auditBaselineEntries``.
    ///
    /// Parsed from source rather than imported, because `FernletTests` and `FernletUITests` are
    /// separate targets that cannot see each other's symbols — the same constraint every grep-wall
    /// in this repo works under.
    static func baselineScreenNames() throws -> Set<String> {
        let text = try source(probeSourcePath)
        guard let start = text.range(of: "auditBaselineEntries") else { return [] }
        let tail = String(text[start.upperBound...])
        // A key line is a quoted string followed by `: [`; an identity line inside a set ends in a
        // comma. Keyed on the shape rather than on an exact indent, so re-indenting the map does not
        // silently empty this wall (the entry-count floor below would catch that, but a wall that
        // depends on whitespace is a wall that fails for the wrong reason).
        return Set(try captures(#"(?m)^\s+"([^"]+)"\s*:\s*\["#, in: tail))
    }
}

// MARK: - The wall

extension AuditRatchetBoundaryTests {

    /// Every frozen baseline still names a screen some probe actually visits.
    ///
    /// The failure this exists for: someone renames `"Sheet · Meal"` to `"Sheet · Log meal"`, the
    /// probe starts from an empty baseline and reports every one of its findings as new — or, worse,
    /// deletes the probe entirely and the entry sits in the map describing a screen that no longer
    /// runs, reading as coverage.
    @Test func everyBaselineScreenIsStillProbed() throws {
        let baselines = try Self.baselineScreenNames()
        let probed = try Self.probedScreenNames()

        #expect(
            probed.count >= Self.minimumProbedScreens,
            """
            Parsed only \(probed.count) probe screen names from \(Self.uiTestRoot) (floor \
            \(Self.minimumProbedScreens)) — a suite was deleted or the construction shape changed, \
            and this wall is now passing without looking at anything.
            """
        )
        #expect(
            baselines.count >= Self.minimumBaselineEntries,
            """
            Parsed only \(baselines.count) baseline entries from \(Self.probeSourcePath) (floor \
            \(Self.minimumBaselineEntries)) — the map was emptied or its literal shape changed. An \
            empty map satisfies the check below trivially, which is a disabled wall, not a clean one.
            """
        )

        let orphaned = baselines.subtracting(probed).sorted()
        #expect(
            orphaned.isEmpty,
            """
            \(orphaned.count) audit baseline(s) name a screen no probe visits any more. A baseline \
            that is never consulted is a hole nobody is watching: rename it to match the probe, or \
            delete it in the same commit that deleted the probe.
            \(orphaned.joined(separator: "\n"))
            """
        )
    }

    /// Every ` ``symbol`` ` DocC link in the audit harness names something that still exists in the
    /// file that links it.
    ///
    /// **Why this is here rather than only in `AdaptiveInkBoundaryTests`.** That suite added the
    /// same check after this round found four links in `FernletTheme.swift` pointing at a symbol
    /// that had never existed under that name — but it is scoped to `FernletUI`, and this pass then
    /// produced the identical defect one directory over: renaming `auditCeilings` to
    /// `auditBaselines` left a ` ``auditCeilings`` ` link behind in `UXScreenProbe.swift`. A rename
    /// breaking a doc link is evidently a *recurring* mistake in this repo, not a one-off, so the
    /// check follows the harness.
    ///
    /// The honest scope: base names only, matched against declarations in the same file. It does not
    /// resolve cross-file or cross-module links, and it does not check that an argument list is
    /// right — a ` ``identity(_:)`` ` link survives a change to `identity(_:extra:)`. It catches the
    /// failure that actually happens, which is a symbol that is simply gone.
    @Test func everyDocCLinkInTheAuditHarnessResolves() throws {
        let files = ["Tests/FernletUITests/UXScreenProbe.swift",
                     "Tests/FernletUITests/LockGateObservabilityUITests.swift",
                     "Tests/FernletUITests/UXScreenProbeIdentityTests.swift"]
        var broken: [String] = []
        for path in files {
            let text = try Self.source(path)
            for link in try Self.captures(#"``([A-Za-z_][A-Za-z0-9_]*)(?:\([^`]*\))?``"#, in: text) {
                let declarations = ["func \(link)(", "let \(link)", "var \(link)",
                                    "struct \(link)", "enum \(link)", "case \(link)"]
                guard !declarations.contains(where: { text.contains($0) }) else { continue }
                broken.append("\(path): ``\(link)``")
            }
        }
        #expect(
            broken.isEmpty,
            """
            \(broken.count) DocC link(s) name a symbol that no longer exists in the file linking \
            them — almost always the residue of a rename. Point them at the new name or make them \
            plain backticks:
            \(Set(broken).sorted().joined(separator: "\n"))
            """
        )
    }

    /// The ratchet is wired the way its doc comment says: identities exclude the frame, and both
    /// directions of the comparison fail.
    ///
    /// A source assertion rather than a behavioural one, for the reason at the top of this file —
    /// `FernletTests` cannot call into the UI target. It is still worth pinning: every one of these
    /// three properties is what makes the ratchet discriminating rather than decorative, and each
    /// fails silently if edited away (the suite goes *greener*, which is exactly why nobody notices).
    @Test func theRatchetStillComparesIdentitiesInBothDirections() throws {
        let text = try Self.source(Self.probeSourcePath)

        #expect(
            !text.contains("static let auditCeilings"),
            """
            `auditCeilings` is back. A per-screen COUNT is not discriminating — fixing one finding \
            while introducing another leaves it unchanged — and it is not stable, because it counts \
            duplicate element-less issues and frame floats. Use `auditBaselines`.
            """
        )
        #expect(
            text.contains("func identity(") && !identityIncludesFrame(text),
            """
            `UXScreenProbe.identity(_:)` must exist and must NOT embed the element frame. A frame in \
            the key makes every run report the same finding as both new and disappeared.
            """
        )
        #expect(
            text.contains("func normalisedLabel(") && identityNormalisesItsLabel(text),
            """
            `UXScreenProbe.identity(_:)` no longer routes the element label through \
            `normalisedLabel(_:)`. Without it the baseline pins wall-clock and seed-derived text — \
            Home's date eyebrow, the month calendar's title, the seeded counts — and the wall goes \
            red the day the date rolls, intermittently, for a reason that has nothing to do with \
            accessibility. See that function's doc comment.
            """
        )
        #expect(
            !baselinePinsAVolatileLiteral(text),
            """
            A frozen baseline entry contains a literal month name, weekday name or bare numeral \
            inside its label. That is a dated time bomb: the entry stops reproducing when the clock \
            or the demo seed moves, and the replacement is an unrecognised appearance, which fails \
            unconditionally. Re-harvest through `normalisedLabel(_:)`.
            """
        )
        #expect(
            text.contains("subtracting(baseline)") && text.contains("subtracting(found)"),
            """
            The ratchet must compare BOTH directions: findings not in the baseline, and baseline \
            entries that no longer reproduce. Dropping the second turns the map into a place stale \
            entries accumulate.
            """
        )
        #expect(
            text.contains("underReportingCategoryPrefixes") && text.contains("unreportedCategories("),
            """
            The under-reporting-category excuse is gone. It is the ONLY thing keeping the \
            `.dynamicType` audit type from failing this suite at random — that type answers short \
            under load, and the measurement is in `UXScreenProbe`'s doc comment. Removing it does \
            not make the wall stricter, it makes it flaky, which is how the previous version ended \
            up with a ceiling nobody trusted.
            """
        )
        #expect(
            !text.contains("auditTypes: XCUIAccessibilityAuditType { .all.subtracting(.contrast).subtracting(.dynamicType)"),
            """
            `.dynamicType` was subtracted from the audit. That type IS the Larger Text criterion the \
            App Store row is blocked on — dropping it would make this wall silent about the one \
            thing it was built to measure. The flakiness is handled by \
            `allOrNothingCategoryPrefixes`, not by switching the type off.
            """
        )
    }

    /// Whether `identity(_:)`'s body mentions the element frame — the one thing it must not.
    ///
    /// Scoped to the function's own text (from its declaration to the next `static func`) so the
    /// neighbouring `describe(_:)`, which legitimately appends the frame, cannot fail this check.
    private func identityIncludesFrame(_ text: String) -> Bool {
        guard let start = text.range(of: "static func identity(") else { return false }
        return identityBody(text, from: start.upperBound).contains("element.frame")
    }

    /// Whether `identity(_:)`'s body routes the element's label through `normalisedLabel(_:)`.
    ///
    /// Scoped to the function's own text for the same reason as above: `describe(_:)` deliberately
    /// does NOT normalise (a person reading a report wants the real date), so a whole-file check
    /// would be satisfied by the wrong function.
    private func identityNormalisesItsLabel(_ text: String) -> Bool {
        guard let start = text.range(of: "static func identity(") else { return false }
        return identityBody(text, from: start.upperBound).contains("normalisedLabel(element.label)")
    }

    /// `identity(_:)`'s text, from its declaration to the next `static func` or `static let`.
    private func identityBody(_ text: String, from start: String.Index) -> Substring {
        let tail = text[start...]
        let end = tail.range(of: "static ")?.lowerBound ?? tail.endIndex
        return tail[..<end]
    }

    /// Whether any frozen baseline entry's LABEL still carries a value the clock or the demo seed
    /// can change.
    ///
    /// Scoped to the text between the curly quotes, which is the only part built from rendered
    /// content — the category prefix, the `id=` and the element-type number around it are all
    /// structural and may legitimately contain digits.
    private func baselinePinsAVolatileLiteral(_ text: String) -> Bool {
        guard let start = text.range(of: "auditBaselineEntries") else { return false }
        let months = ["January", "February", "March", "April", "May", "June", "July",
                      "August", "September", "October", "November", "December"]
        let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        for line in text[start.upperBound...].components(separatedBy: .newlines) {
            guard line.contains("\u{201C}"), let label = quotedLabel(line) else { continue }
            if label.contains(where: { $0.isNumber }) { return true }
            if (months + weekdays).contains(where: { label.range(of: $0, options: .caseInsensitive) != nil }) {
                return true
            }
        }
        return false
    }

    /// The text between the first pair of curly quotes on `line`.
    private func quotedLabel(_ line: String) -> String? {
        guard let open = line.range(of: "\u{201C}"),
              let close = line.range(of: "\u{201D}", range: open.upperBound..<line.endIndex) else { return nil }
        return String(line[open.upperBound..<close.lowerBound])
    }
}
