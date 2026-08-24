// FernletAnnouncerTests.swift
// FernletTests
//
// Unit tests for the shared VoiceOver announcement seam (``FernletAnnouncer``) and the assistive
// dismissal-window resolver (``FernletDismissalWindow``), both from FernletUI.
//
// WHY THESE EXIST AT ALL. The accessibility system never reports back what it spoke: there is no
// API that answers "did VoiceOver say anything just now?", and an announcement leaves no trace in
// the view hierarchy for XCUITest to find. So an announcement that silently stops firing — a catch
// arm that grows an early return, a window that gets reordered — is invisible to every other kind
// of test in this repo. Both types are values with ONE injected closure precisely so that question
// becomes decidable here, and the assertions below are as much about what is NOT spoken (empty
// strings, the success that did not happen) as about what is.
//
// THREE GREP-WALLS live at the bottom, and together they are the localization half. Extracting the
// announcer did not remove the literal problem, it MOVED it — out of one guarded file and into
// fourteen call sites — so guarding only the file would have been a wall around an open door:
//
//   * `announcerSourceContainsNoStringLiteral` — no copy in the announcer itself. It has no
//     catalog to resolve against, so a literal there is English forever.
//   * `packageAnnounceCallsUseTheResolvedLabel` — inside FernletKit every `.announce(` must use
//     `resolved:`. A package call site using the `LocalizedStringResource` overload builds clean,
//     warns about nothing, passes LocalizationBoundaryTests (which skips resources by design), and
//     speaks its own raw key at runtime. This is the wall that closes that door.
//   * `onlyTheAnnouncerPostsAnAnnouncement` — one poster in the whole tree, because a seam that is
//     not the only seam makes every other test in this file worth nothing.
//
// None of the three failures is catchable by the compiler. All three are catchable by a source scan.
//
// KNOWN NON-ADOPTED SITES, deliberately left for the reconciliation batch. `FoodView.swift` is
// owned by the parallel food track, so batch A3 did not touch it: its bare `ProgressView()`
// (~:3317, the search / label-read progress card) is still an unlabelled empty leaf, and its
// `createdNotice` toast (~:5992, a 4 s `.task(id:)`) still auto-dismisses on the sighted-tap budget
// rather than through `FernletDismissalWindow`. Both are the same one-line fixes applied elsewhere
// in this batch; they are recorded here so the gap is visible in the tree and not only in a ledger.

import Foundation
import Testing
import FernletUI

/// Records what an announcer was asked to speak, in order, kind and words together.
@MainActor
private final class SpeechRecorder {
    /// Every announcement posted through ``announcer``, in posting order.
    var spoken: [FernletAnnouncement] = []

    /// An announcer that records here instead of speaking.
    var announcer: FernletAnnouncer {
        FernletAnnouncer { [self] in spoken.append($0) }
    }

    /// The words only, for assertions that do not care about the kind.
    var words: [String] { spoken.map(\.message) }
}

/// Pins exactly what ``FernletAnnouncer`` speaks and — the half that regresses silently — what it
/// does not.
@Suite struct FernletAnnouncerTests {

    /// An already-resolved sentence is posted verbatim, carrying the kind the call site chose.
    ///
    /// Verbatim matters: the `resolved:` overload exists for text that is ALREADY final (an error's
    /// `localizedDescription`, a status line the sheet is also rendering), so any transformation
    /// here would desynchronise the spoken sentence from the printed one.
    @MainActor
    @Test func resolvedSentenceIsSpokenVerbatimWithItsKind() async throws {
        let recorder = SpeechRecorder()
        recorder.announcer.announce(.error, resolved: "Couldn't save that.")

        #expect(recorder.spoken == [FernletAnnouncement(kind: .error, message: "Couldn't save that.")])
    }

    /// An empty sentence is dropped rather than posted.
    ///
    /// `localizedDescription` can come back empty from a badly-behaved error, and the adopted catch
    /// arms hand it straight through. Posting "" gives VoiceOver an announcement with nothing in
    /// it, which reads to the user as an interruption that swallowed itself.
    @MainActor
    @Test func emptySentenceIsNeverSpoken() async throws {
        let recorder = SpeechRecorder()
        recorder.announcer.announce(.error, resolved: "")
        recorder.announcer.announce(resolved: "")

        #expect(recorder.spoken.isEmpty)
    }

    /// A `LocalizedStringResource` is RESOLVED before it is posted — the announcement carries the
    /// sentence, never the lookup key.
    ///
    /// This is the entire point of the resource-taking overload. A key that reached
    /// `AccessibilityNotification.Announcement` unresolved would be spoken as its own identifier
    /// ("announcerTests.unusedKey"), which is exactly how a missed `String(localized:)` sounds.
    @MainActor
    @Test func localizedResourceIsResolvedBeforeItIsSpoken() async throws {
        let recorder = SpeechRecorder()
        let resource = LocalizedStringResource(
            "fernletAnnouncerTests.absentKey",
            defaultValue: "Saved to your day.",
            comment: "Test-only resource; deliberately absent from every catalog")

        recorder.announcer.announce(.success, resource)

        #expect(recorder.words == ["Saved to your day."])
        #expect(recorder.spoken.first?.kind == .success)
    }

    /// The kind defaults to `.status`, so a call site that says nothing claims nothing.
    @MainActor
    @Test func omittedKindIsStatus() async throws {
        let recorder = SpeechRecorder()
        recorder.announcer.announce(resolved: "Recording started.")

        #expect(recorder.spoken.first?.kind == .status)
    }

    /// Order and kind are both preserved, and a kind that never fired never appears.
    ///
    /// The negative half is the one worth having: "no success was announced" is the assertion that
    /// catches a failure path which quietly started reporting itself as a win.
    @MainActor
    @Test func sequenceIsPreservedAndUnfiredKindsAreAbsent() async throws {
        let recorder = SpeechRecorder()
        let announcer = recorder.announcer
        announcer.announce(.status, resolved: "Checking.")
        announcer.announce(.error, resolved: "That didn't work.")
        announcer.announce(.error, resolved: "That didn't work either.")

        #expect(recorder.spoken.map(\.kind) == [.status, .error, .error])
        #expect(recorder.spoken.contains { $0.kind == .success } == false)
        #expect(recorder.words == ["Checking.", "That didn't work.", "That didn't work either."])
    }

    /// The announcer's own source file carries NO copy — the localization wall, mechanically.
    ///
    /// `AccessibilityNotification.Announcement` takes a `String`, and `FernletUI` deliberately ships
    /// without a string catalog (review §4.0), so a literal written inside the announcer resolves
    /// against `Bundle.main`, finds nothing, and is spoken in English in every locale, forever, with
    /// a clean build and a green test suite. The type's whole API shape — caller-resolved text only
    /// — exists to make that impossible, and this keeps it that way after the next edit.
    ///
    /// Comments are exempt (the doc comments quote example sentences on purpose); code lines are
    /// not. The check is deliberately blunt: ANY double-quoted literal on a code line fails, because
    /// there is no legitimate reason for this file to contain one.
    @Test func announcerSourceContainsNoStringLiteral() throws {
        let url = RepoRoot.url.appendingPathComponent("FernletKit/Sources/FernletUI/FernletAnnouncer.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let offenders = source.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .filter { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && trimmed.contains("\"")
            }
            .map { index, line in "\(index + 1): \(line)" }

        #expect(offenders.isEmpty,
                "FernletAnnouncer.swift must contain no copy — every sentence is caller-resolved. \(offenders)")
    }

    /// One `.announce(` call found in package source.
    struct AnnounceCallSite: Hashable, Sendable {
        /// Repo-relative path.
        let path: String
        /// 1-based line of the `.announce(` head.
        let line: Int
        /// The whole call, from `.announce` through its matching `)`.
        let text: String

        /// Whether the call goes through the `resolved:` overload — the only one a package caller
        /// may use. See ``packageAnnounceCallsUseTheResolvedLabel()``.
        ///
        /// Decided during the span scan, NOT by a substring test over ``text``. `resolved:` has to
        /// be an argument LABEL of this call: at the call's own paren depth, and outside every
        /// string literal. A substring test passes any call whose *copy* happens to contain the
        /// word — `announce(.status, LocalizedStringResource("Conflict resolved: your other
        /// device's key is now in use."))` is a real sentence this app could plausibly ship, and it
        /// is exactly the violation this wall exists to catch.
        let usesResolvedLabel: Bool

        /// `path:line: <call, single-lined>` — pasteable straight into a search.
        var report: String {
            let flattened = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
            return "\(path):\(line): \(flattened)"
        }
    }

    /// Every `.announce(` call in a source string, with its full parenthesised span.
    ///
    /// Comment lines are skipped (doc comments name the API on purpose) and the span is balanced
    /// across newlines, because the argument that matters is routinely on a later line than the
    /// head. The scan is bounded: a call span never runs past ``maximumCallSpan`` characters, so a
    /// stray unbalanced paren cannot walk the rest of the file.
    static func announceCalls(in source: String) -> [AnnounceCallSite] {
        let characters = Array(source)
        var sites: [AnnounceCallSite] = []
        var line = 1
        var index = 0
        while index < characters.count {
            if characters[index] == "\n" { line += 1; index += 1; continue }
            guard matchesHead(characters, at: index), !isCommentLine(source, line: line) else {
                index += 1
                continue
            }
            let call = scanCall(characters, from: index + announceHead.count)
            sites.append(AnnounceCallSite(path: "", line: line,
                                          text: String(characters[index..<call.end]),
                                          usesResolvedLabel: call.usesResolvedLabel))
            index += 1
        }
        return sites
    }

    /// The literal this wall keys on. A leading dot, so ``FernletAnnouncer``'s own declaration and
    /// its internal self-call are not call sites.
    private static let announceHead = Array(".announce(")

    /// Rule 2 bound on one call's span.
    private static let maximumCallSpan = 2000

    private static func matchesHead(_ characters: [Character], at index: Int) -> Bool {
        matches(announceHead, characters, at: index)
    }

    private static func isCommentLine(_ source: String, line: Int) -> Bool {
        let lines = source.components(separatedBy: .newlines)
        guard line - 1 < lines.count else { return false }
        return lines[line - 1].trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    /// The label this wall requires on every package call site.
    private static let resolvedLabel = Array("resolved:")

    /// Walks one call from just inside its open paren to its matching close, reporting where it
    /// ends and whether `resolved:` appeared as an ARGUMENT LABEL of *this* call.
    ///
    /// Three things are tracked together because they answer one question. **Depth** keeps a label
    /// belonging to a nested call — `announce(.error, helper(resolved: x))` — from counting for the
    /// outer one. **String state** keeps prose out of it, which is the whole point: copy that
    /// happens to read "Conflict resolved: …" is not a label. **The ceiling** is the rule-2 bound,
    /// so an unbalanced paren cannot walk the rest of the file.
    ///
    /// Escapes are honoured, and a `"""` literal is handled by consequence rather than by design:
    /// three toggles is odd, so the block reads as in-string and closes correctly. If that ever
    /// does misfire the error is conservative — content stays "inside a string", so a label hidden
    /// there is not credited and the call stays a violation.
    private static func scanCall(_ characters: [Character], from start: Int) -> (end: Int, usesResolvedLabel: Bool) {
        var depth = 1
        var index = start
        var inString = false
        var escaped = false
        var labelled = false
        let ceiling = min(characters.count, start + maximumCallSpan)
        while index < ceiling {
            let character = characters[index]
            if escaped {
                escaped = false
            } else if inString {
                if character == "\\" { escaped = true } else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else {
                if character == "(" { depth += 1 }
                if character == ")" {
                    depth -= 1
                    if depth == 0 { return (index + 1, labelled) }
                }
                if depth == 1, matches(Self.resolvedLabel, characters, at: index) { labelled = true }
            }
            index += 1
        }
        return (ceiling, labelled)
    }

    /// Whether `token` sits at `index` in `characters`.
    private static func matches(_ token: [Character], _ characters: [Character], at index: Int) -> Bool {
        guard index + token.count <= characters.count else { return false }
        return Array(characters[index..<(index + token.count)]) == token
    }

    /// Inside `FernletKit/Sources`, every `.announce(` call MUST use the `resolved:` label.
    ///
    /// This closes the channel the announcer's own no-literal rule does not: the copy did not
    /// disappear when ``FernletAnnouncer`` was extracted, it moved to the CALL SITES, and at a
    /// package call site the `LocalizedStringResource` overload is a silent trap. Both failing
    /// shapes build clean, warn about nothing, and pass `LocalizationBoundaryTests` — which skips
    /// `LocalizedStringResource` by design (its own near-miss fixture asserts exactly that):
    ///
    ///   * `announce(.error, "Couldn't unlock.")` — a bare literal, spoken in English forever.
    ///   * `announce(.error, LocalizedStringResource("Couldn't unlock."))` — a resource CREATED in
    ///     package source defaults to `Bundle.main`, so at runtime it resolves to its own raw key.
    ///
    /// A package caller has a correct route and already uses it: resolve with the module's own copy
    /// vault (`FernletLockCopy`, `CaptureNudgeCopy`) or `String(localized:bundle:.module)` — which
    /// `LocalizationBoundaryTests` then checks — and pass the result as `resolved:`. App-target and
    /// app-extension callers keep the unlabelled overload; their `Bundle.main` IS their catalog.
    @Test func packageAnnounceCallsUseTheResolvedLabel() throws {
        let root = RepoRoot.url("FernletKit/Sources")
        var scanned = 0
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            scanned += 1
            let source = try String(contentsOf: url, encoding: .utf8)
            let relative = url.path.replacingOccurrences(of: RepoRoot.url.path + "/", with: "")
            offenders += Self.announceCalls(in: source)
                .filter { !$0.usesResolvedLabel }
                .map { site in
                    AnnounceCallSite(path: relative, line: site.line, text: site.text,
                                     usesResolvedLabel: site.usesResolvedLabel).report
                }
        }

        #expect(scanned >= 170,
                "Scanned only \(scanned) package Swift files — the root moved and this wall reads nothing.")
        #expect(offenders.isEmpty,
                """
                \(offenders.count) `.announce(` call(s) inside FernletKit do not use `resolved:`. \
                Inside a package BOTH other shapes are silently English forever: a bare literal is \
                never harvested at all, and a `LocalizedStringResource` created here defaults to \
                `Bundle.main`, misses the module catalog, and is spoken as its own raw key. \
                Resolve with the module's copy vault or `String(localized:bundle:.module)` and pass \
                it as `resolved:`:
                \(offenders.sorted().joined(separator: "\n"))
                """)
    }

    /// Fixture: the `.announce(` scanner sees both failing shapes, accepts the correct one, and
    /// does not fire on prose or on the announcer's own declaration.
    ///
    /// Without this the wall is unfalsifiable — it is expected to report zero forever, which is
    /// indistinguishable from a matcher that never fires.
    @Test func announceCallScannerSeesTheResolvedLabel() {
        // The exact shape planted during review: a bare literal at a package call site.
        let literal = #"FernletAnnouncer.system.announce(.error, "Couldn't unlock.")"#
        #expect(Self.announceCalls(in: literal).count == 1)
        #expect(Self.announceCalls(in: literal).first?.usesResolvedLabel == false)

        // The subtler one: a resource CREATED in package source, defaulting to Bundle.main.
        let resource = #"self.announcer.announce(.status, LocalizedStringResource("Locked."))"#
        #expect(Self.announceCalls(in: resource).first?.usesResolvedLabel == false)

        // The correct package form.
        let good = "FernletAnnouncer.system.announce(.error, resolved: spoken)"
        #expect(Self.announceCalls(in: good).first?.usesResolvedLabel == true)

        // The label on a later line than the head — the formatting the wall must survive.
        let multiline = """
        announcer.announce(
            .status,
            resolved: CaptureNudgeCopy.spokenAnnouncement
        )
        """
        let multilineSites = Self.announceCalls(in: multiline)
        #expect(multilineSites.count == 1, "a split call must still match")
        #expect(multilineSites.first?.usesResolvedLabel == true)

        // A paren inside the argument must not end the span early and hide the label.
        let nested = #"a.announce(.error, resolved: String(format: "%@ (%d)", name, count))"#
        #expect(Self.announceCalls(in: nested).first?.usesResolvedLabel == true)

        // THE COPY-CONTAINS-THE-WORD ESCAPE. A substring test over the call span passes this, and
        // it is not a contrived sentence — the escrow-conflict copy in this app reads exactly like
        // it. `resolved:` here is prose inside a string literal, not an argument label.
        let prose = #"""
        FernletAnnouncer.system.announce(.status, LocalizedStringResource("Conflict resolved: your other device's key is now in use."))
        """#
        #expect(Self.announceCalls(in: prose).count == 1)
        #expect(Self.announceCalls(in: prose).first?.usesResolvedLabel == false,
                "`resolved:` inside a string literal is copy, not an argument label")

        // The same sentence, correctly resolved: the label IS present and the copy still contains
        // the word. Both halves must be read independently, or the fix above would over-correct.
        let proseResolved = #"""
        FernletAnnouncer.system.announce(.status, resolved: "Conflict resolved: your other device's key is now in use.")
        """#
        #expect(Self.announceCalls(in: proseResolved).first?.usesResolvedLabel == true)

        // A label belonging to a NESTED call does not count for the outer one.
        let nestedLabel = "a.announce(.error, helper(resolved: text))"
        #expect(Self.announceCalls(in: nestedLabel).first?.usesResolvedLabel == false,
                "a nested call's label is not this call's label")

        // An escaped quote must not end the string early and expose the prose to the label scan.
        let escapedQuote = #"a.announce(.status, LocalizedStringResource("She said \"resolved: yes\" out loud."))"#
        #expect(Self.announceCalls(in: escapedQuote).first?.usesResolvedLabel == false)

        // Near-misses that must NOT be call sites: the declaration (no leading dot), the internal
        // self-call, and prose that names the API.
        #expect(Self.announceCalls(in: "public func announce(_ kind: Kind, resolved m: String) {").isEmpty)
        #expect(Self.announceCalls(in: "        announce(kind, resolved: String(localized: text))").isEmpty)
        #expect(Self.announceCalls(in: #"    /// Use `.announce(.error, "oops")` — never do this."#).isEmpty,
                "a call named inside a doc comment is prose, not a call site")
    }

    /// Exactly ONE place in shipping code posts a VoiceOver announcement.
    ///
    /// The seam is only a seam while it is the only one. A view that posts
    /// `AccessibilityNotification.Announcement` inline still works, still ships, and is still
    /// invisible to every test here — which is precisely the state this batch left behind. This
    /// keeps the single-owner property true rather than merely true today, and it is the reason the
    /// other tests in this file are worth anything at all.
    ///
    /// Comment lines are exempt (this file's own prose names the API), and the floor on files
    /// scanned is the standard non-vacuity guard: a scan that reads nothing must fail, not pass.
    @Test func onlyTheAnnouncerPostsAnAnnouncement() throws {
        let roots = ["App/Fernlet", "App/FernletWidgets", "App/FernletShareExtension", "FernletKit/Sources"]
        var scanned = 0
        var posters: Set<String> = []
        for root in roots {
            let base = RepoRoot.url(root)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            while let url = files?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                scanned += 1
                let source = try String(contentsOf: url, encoding: .utf8)
                let posts = source.split(separator: "\n", omittingEmptySubsequences: false)
                    .contains { line in
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
                            && trimmed.contains("AccessibilityNotification.Announcement(")
                    }
                // Repo-relative, never the file NAME: a second file called FernletAnnouncer.swift
                // anywhere in the tree would otherwise satisfy this wall while posting freely.
                if posts { posters.insert(url.path.replacingOccurrences(of: RepoRoot.url.path + "/", with: "")) }
            }
        }

        // 383 shipping files at the time of writing — the same count `Scripts/power-of-10-scan.py`
        // reports over the same four roots. The floor sits well below it so ordinary churn and the
        // continuing SPM carve-up never trip it, but a root that stops resolving does.
        #expect(scanned >= 340,
                "Scanned only \(scanned) shipping Swift files — a root moved and this wall is passing over nothing.")
        #expect(posters == ["FernletKit/Sources/FernletUI/FernletAnnouncer.swift"],
                """
                VoiceOver announcements must be posted through FernletAnnouncer and nowhere else, so \
                that what is (and is not) spoken stays assertable. Inline posters found: \
                \(posters.sorted().joined(separator: ", "))
                """)
    }
}

/// Pins the assistive-technology branch of ``FernletDismissalWindow``, which no other test can
/// reach: `UIAccessibility.isVoiceOverRunning` cannot be forced from a unit test, so without the
/// injected read the branch that only runs for VoiceOver and Switch Control users would be the one
/// branch in the app that nothing ever exercises.
@Suite struct FernletDismissalWindowTests {

    /// With no assistive technology running, the sighted-tap budget is returned unchanged — by
    /// BOTH methods.
    ///
    /// This is the "everyone else sees no difference" guarantee: every adopted toast keeps its
    /// existing timing by default, so this work cannot regress the visual design.
    @MainActor
    @Test func standardWindowIsUnchangedWithoutAssistiveTechnology() async throws {
        let resolver = FernletDismissalWindow(isAssistiveNavigationRunning: { false })

        #expect(resolver.window(standard: .seconds(5), assistive: .seconds(20)) == .seconds(5))
        #expect(resolver.windowUnlessAssistive(standard: .seconds(4)) == .seconds(4))
    }

    /// With an assistive technology running, the stretched window is returned instead.
    @MainActor
    @Test func assistiveWindowReplacesTheStandardOne() async throws {
        let resolver = FernletDismissalWindow(isAssistiveNavigationRunning: { true })

        #expect(resolver.window(standard: .seconds(5),
                                assistive: FernletDismissalWindow.assistiveActionWindow)
                == FernletDismissalWindow.assistiveActionWindow)
        #expect(resolver.window(standard: .seconds(4),
                                assistive: FernletDismissalWindow.assistiveNoticeWindow)
                == FernletDismissalWindow.assistiveNoticeWindow)
    }

    /// ``FernletDismissalWindow/window(standard:assistive:)`` NEVER answers "no window".
    ///
    /// The non-optional return is the whole reason the two policies are separate methods. A caller
    /// has already assigned the state its timer will clear by the time it asks, so an optional here
    /// invites `guard … else { return }` — which strands the toast on screen forever, a worse
    /// outcome than any window length. This pins the type-level guarantee that the branch cannot
    /// be written.
    @MainActor
    @Test func theStretchingWindowAlwaysAnswers() async throws {
        for running in [true, false] {
            let resolver = FernletDismissalWindow(isAssistiveNavigationRunning: { running })
            let window: Duration = resolver.window(standard: .seconds(4), assistive: .seconds(12))
            #expect(window > .zero)
        }
    }

    /// ``FernletDismissalWindow/windowUnlessAssistive(standard:)`` suppresses auto-dismissal
    /// entirely while an assistive technology runs — the right answer when dismissal REMOVES
    /// CONTROLS from the accessibility tree rather than retiring a notice, because a stretched
    /// timer would still eventually delete the only buttons on the screen out from under a
    /// VoiceOver user mid-swipe.
    @MainActor
    @Test func assistiveRunSuppressesAutoDismissalForControlBearingSurfaces() async throws {
        let resolver = FernletDismissalWindow(isAssistiveNavigationRunning: { true })

        #expect(resolver.windowUnlessAssistive(standard: .seconds(5)) == nil)
    }

    /// The stretched windows are longer than any standard budget in the app, and the action window
    /// is the longer of the two.
    ///
    /// Pinned because the two constants are the only place the *policy* lives: an edit that made
    /// the assistive window shorter than the sighted one would be a straight-faced regression that
    /// nothing else would notice.
    @MainActor
    @Test func stretchedWindowsAreOrderedAndLongerThanTheSightedBudget() async throws {
        #expect(FernletDismissalWindow.assistiveNoticeWindow > .seconds(6))
        #expect(FernletDismissalWindow.assistiveActionWindow > FernletDismissalWindow.assistiveNoticeWindow)
    }
}
