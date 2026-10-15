// ProximityPlatformBoundaryTests.swift
// FernletTests
//
// Fernlet's half of the wall that keeps ProximityKit free of platform policy
// (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md §4 A0.6, Mac readiness). ProximityKit holds no
// platform policy: it builds for iOS 26 and native macOS 26 and computes no value whose right answer
// differs by platform or by app. What an unnamed device is called, whether a connection ranges and
// where an installation keeps its files are its host's to state, each a `ProximityHost` requirement
// with no default, and the module keeps only the two mechanism seams a platform needs, each compiled
// only where its framework is usable. Both halves of that wall are ProximityKit's own repository's
// since plan step A1.3 (Fernlet depends on https://github.com/bowman-mw/proximitykit at exactly
// 0.1.0): its CI builds and tests it for native macOS, the compiler half, and its package test
// `ProximityPlatformNeutralityTests` holds the rules over its code (its imports and platform branches,
// its device-name reads, its platform directories and host-fact defaults, its own channel-ready doors
// and `NIRangingSession`'s one home), the source half. This suite holds what is this repository's, two
// rules, each in a cell of its own:
//
//   1. presence's heart door in FernletSocial, Fernlet's channel-ready door, builds its connection's
//      coordinator over its host's `makeProximityRangingProvider()`, once, naming no provider of its
//      own (the rule the package suite holds ProximityKit's own two doors to);
//   2. the macOS build of the Mac-ready set, the three modules a Mac host of Fernlet's needs, is a
//      compiled fact on every push: the package manifest declares macOS 26 and the `MacReady` product,
//      which names FernletFoundation, FernletCrypto and FernletDomainModel, the CI workflow runs on
//      every push and pull request to `main` with no path or branch filter, and its macOS step, with no
//      `if:` or `continue-on-error:` on it or on its job and nothing but its preamble (`run: |`,
//      `set -euo pipefail`) before its run line, runs `Scripts/macos-build-selftest.sh`
//      (whose negative leg plants an `import UIKit` in FernletFoundation and greps the failure only a
//      native macOS build gives, and whose positive leg builds the clean tree),
//      `Scripts/macos-build-check.sh` holds the one `xcodebuild build` command for the `MacReady`
//      product and native macOS, and the pre-push hook runs it, its leg on unless a person skips it and
//      relevant to a change of the manifest or a FernletFoundation source; each read from what runs,
//      never from a step's title, an `echo` or a comment, its readers fixtured both ways in the same
//      cell.
//
// And it holds what other walls read: the `xcodebuild` command reader and its whole-word flag match
// (`xcodebuildBuildCommands(in:action:)` and `carries(_:in:)`, which `PowerOfTenBoundaryTests`' rule-10
// pins and `CIGateSelectorBoundaryTests` read), and the capture reader `CIGateSelectorBoundaryTests`
// reads the manifest with (`captures(of:in:)`).
//
// It never spells the vendor-identifier symbol: `NoTrackingBoundaryTests` bans that spelling
// everywhere, comments included.

import Foundation
import Testing

/// Fernlet's channel-ready door asks its host for each connection's ranging provider, and the Mac-ready
/// set's native macOS build runs on every push: two cells, the second's readers fixtured both ways in
/// it. The rules over ProximityKit's own code are its package suite's, `ProximityPlatformNeutralityTests`.
@Suite struct ProximityPlatformBoundaryTests {

    /// One token a rule refuses: its spelling, and the pattern that reads it in lexed code as a whole
    /// identifier, never inside a longer name.
    struct Needle: Sendable {
        /// The token as the lists and the failure messages spell it.
        let token: String
        /// The `NSRegularExpression` pattern that reads it.
        let pattern: String

        /// A whole identifier: no identifier character on either side, so `UIDeviceOrientation` is
        /// not `UIDevice` and `myHostName` is not `hostName`.
        static func identifier(_ name: String) -> Needle {
            Needle(token: name, pattern: #"(?<![A-Za-z0-9_])"# + name + #"(?![A-Za-z0-9_])"#)
        }
    }

    // MARK: W5, Fernlet's half: the presence door's ranging

    /// One channel-ready door: its file and the declaration its brace-matched body follows.
    struct Door: Sendable {
        /// The file, by its path under the repository root.
        let path: String
        /// The declaration prefix the door's body follows, unique in its file.
        let signature: String
    }

    /// Fernlet's door that builds one connection's coordinator: presence's heart door in FernletSocial.
    /// ProximityKit's own two, the mesh's and the pair session's, are its package suite's
    /// (`ProximityPlatformNeutralityTests.channelReadyDoors`).
    static let presenceHeartDoor = Door(path: "FernletKit/Sources/FernletSocial/Presence/PresenceManager.swift",
                                        signature: "private func handleHeartChannelReady(")

    /// The argument the door builds its coordinator's provider with: its host's answer, asked once per
    /// connection.
    static let hostRangingArgument = "ranging: store.makeProximityRangingProvider()"

    /// The providers the door may not name: a door that builds one has made its host's decision for it.
    static let doorProviderNeedles: [Needle] = [
        .identifier("NIRangingSession"), .identifier("NoopRangingProvider"), .identifier("MockRangingProvider")
    ]

    /// **W5, Fernlet's half.** Presence's heart door asks its host for each connection's ranging
    /// provider: its brace-matched body (comments dropped, literals emptied) passes
    /// ``hostRangingArgument`` exactly once and names none of ``doorProviderNeedles``. Whether a
    /// connection ranges is its host's decision (a host on macOS cannot build NearbyInteraction's types
    /// at all, and one may want no ranging), so a door that builds the NearbyInteraction provider itself
    /// takes that decision back from its host.
    @Test func thePresenceHeartDoorAsksItsHostForRanging() throws {
        let door = Self.presenceHeartDoor
        let code = Self.lexedCode(try RepoRoot.source(door.path))
        let body = try #require(MeshRoutedSourceScan.bracedBody(after: door.signature, in: code),
                                "\(door.path) no longer declares `\(door.signature)`")
        let asks = body.components(separatedBy: Self.hostRangingArgument).count - 1
        #expect(asks == 1, "\(door.path)'s door passes `\(Self.hostRangingArgument)` \(asks) times")
        // R2: bounded by the three needles.
        for needle in Self.doorProviderNeedles {
            #expect(try Self.mentions(of: needle, in: body) == 0, "\(door.path)'s door names \(needle.token)")
        }
    }

    // MARK: W6: the Mac build, on every push

    /// The package manifest, whose platforms and products W6 reads.
    static let manifestPath = "FernletKit/Package.swift"

    /// The manifest's platforms, exactly: iOS 26 and, since plan step A0.6.5, native macOS 26.
    static let manifestPlatforms: Set<String> = [".iOS(.v26)", ".macOS(.v26)"]

    /// The product the macOS check builds, its three modules named, so none of them leaves the Mac build
    /// unseen: FernletFoundation, FernletCrypto and FernletDomainModel, which a Mac host of Fernlet's
    /// needs. ProximityKit's macOS build is its own repository's CI since plan step A1.3.
    static let macReadyProduct =
        #".library(name: "MacReady", targets: ["FernletFoundation", "FernletCrypto", "FernletDomainModel"])"#

    /// The CI workflow step that runs the macOS self-test, by its `- name:`.
    static let macOSStepName = "The Mac-ready set on native macOS (Scripts/macos-build-selftest.sh)"

    /// The one line the macOS step's body runs.
    static let macOSStepRun = "Scripts/macos-build-selftest.sh"

    /// Where the self-test plants its probe: inside FernletFoundation, one of the set's three modules, so
    /// only a native macOS build fails on it.
    static let selfTestProbePath = "FernletKit/Sources/FernletFoundation/__MacOSBuildSelfTestProbe.swift"

    /// The self-test's negative leg: the check run over the probe, its output kept for the grep.
    static let selfTestCapture = #""$(Scripts/macos-build-check.sh 2>&1)""#

    /// The failure only a native macOS build gives the probe's `import UIKit`: the explicit-module
    /// dependency scan's wording for a module the platform lacks. xcodebuild never prints the SwiftPM
    /// command line's "no such module", so the self-test greps this, case-insensitively.
    static let macOSOnlyFailure = "unable to resolve module dependency: 'UIKit'"

    /// The check, whose one `xcodebuild build` command W6 and rule 10's pin read.
    static let checkScriptPath = "Scripts/macos-build-check.sh"

    /// What the check's command carries so that it builds the `MacReady` product's three modules, for
    /// native macOS, into its own derived data, with the dependency DAG enforced. Rule 10's three
    /// warnings-as-errors flags are `PowerOfTenBoundaryTests.r10MacOSBuildCheckScriptBuildsStrict()`'s
    /// to pin.
    static let checkCommandFlags = [
        "-scheme MacReady", "-destination 'generic/platform=macOS'", "-derivedDataPath",
        "DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR"
    ]

    /// The pre-push hook's macOS leg: the check's invocation on a line of its own, as the S3 leg's is.
    static let hookInvocation = #""$REPO_ROOT/Scripts/macos-build-check.sh""#

    /// The test that opens the hook's macOS leg: the leg runs unless a person sets
    /// `SKIP_MACOS_BUILD_CHECK=1`, its default `0`, as the S3 leg's is.
    static let hookDefault = #"if [ "${SKIP_MACOS_BUILD_CHECK:-0}" = "1" ]; then"#

    /// How the hook assigns the macOS leg's relevance pattern, the `grep -E` pattern a pushed path must
    /// match for the leg to build.
    static let hookRelevancePrefix = "macos_relevant_regex='"

    /// Paths the macOS leg must find relevant: the manifest and a FernletFoundation source.
    static let hookRelevantPaths = [manifestPath, "FernletKit/Sources/FernletFoundation/FernletFoundation.swift"]

    /// **W6.** The Mac-ready set's macOS build is a compiled fact on every push, each piece read from
    /// what RUNS, never from a step's title, an `echo` or a comment, any of which can name a script
    /// nothing runs: the manifest declares exactly iOS 26 and macOS 26 and the `MacReady` product with
    /// its three modules, that line once; the
    /// workflow runs on every push and every pull request to `main`, its `on:` block filtering neither by
    /// path nor by branch, and declares its macOS step once, with no `if:` or `continue-on-error:` on the
    /// step or on its job (either keeps a declared step from running or from failing the run), and that
    /// step's body runs the self-test right after its preamble (``stepPreamble``), with no other line
    /// before it to exit, guard it or continue onto it; the self-test plants its probe in
    /// FernletFoundation, captures the check, greps the failure only a native macOS build gives, and
    /// runs the check again on the clean tree; the check holds one `xcodebuild build` command, for the
    /// `MacReady` product, native macOS, its own derived data and the dependency flag; and the pre-push
    /// hook runs the check, its leg on by default and relevant to a change of the manifest or a
    /// FernletFoundation source. Its
    /// readers are fixtured both ways. Each verdict is computed before its `#expect`, so a failure prints
    /// the verdict and its message, never a whole file: the workflow's own text names the floor script's
    /// restart line, which an echoed copy would trip.
    @Test func theMacBuildIsACompiledFactOnEveryPush() throws {
        let manifest = try RepoRoot.source(Self.manifestPath)
        let platforms = Self.platformEntries(in: manifest)
        let exactPlatforms = platforms.map { $0.count == Self.manifestPlatforms.count && Set($0) == Self.manifestPlatforms }
        #expect(exactPlatforms == true,
                "\(Self.manifestPath) declares the platforms \(platforms ?? []), not \(Self.manifestPlatforms.sorted())")
        let manifestLines = Self.nonCommentLines(manifest, commentPrefix: "//").map(Self.droppingTrailingComma)
        let declared = manifestLines.count(where: { $0 == Self.macReadyProduct })
        #expect(declared == 1, "\(Self.manifestPath) declares `\(Self.macReadyProduct)` \(declared) times")
        let workflow = try RepoRoot.source(".github/workflows/s3-wall.yml")
        let stepRunsTheSelfTest = Self.stepRuns(Self.macOSStepRun, step: Self.macOSStepName, in: workflow)
        #expect(stepRunsTheSelfTest, """
            the workflow's "\(Self.macOSStepName)" step is not declared exactly once, with no `if:` or \
            `continue-on-error:` on it or its job, and a body that runs `\(Self.macOSStepRun)` with nothing \
            but \(Self.stepPreamble) before it: a step whose title names the script, or that is skipped, \
            tolerated, exits first or guards its run line, runs nothing that counts
            """)
        let runsOnMain = Self.triggersRunOnMain(workflow)
        #expect(runsOnMain, """
            the workflow's `on:` block no longer runs it on every push and every pull request to `main` \
            (`push:` and `pull_request:`, each with `branches: ["main"]`, and no `paths:`, \
            `paths-ignore:` or `branches-ignore:`): a change it skips is a change the Mac build never saw
            """)
        let missing = Self.missingSelfTestLegs(in: try RepoRoot.source("Scripts/macos-build-selftest.sh"))
        #expect(missing.isEmpty, "Scripts/macos-build-selftest.sh no longer runs \(missing)")
        let commands = Self.xcodebuildBuildCommands(in: try RepoRoot.source(Self.checkScriptPath))
        #expect(commands.count == 1, "\(Self.checkScriptPath) holds \(commands.count) `xcodebuild build` commands, not one")
        let unflagged = Self.checkCommandFlags.filter { flag in
            !(commands.first.map { Self.carries(flag, in: $0) } ?? false)
        }
        #expect(unflagged.isEmpty, "\(Self.checkScriptPath)'s `xcodebuild build` command no longer carries \(unflagged)")
        let hook = try RepoRoot.source("Scripts/git-hooks/pre-push")
        let hookRuns = Self.runLines(of: hook).contains(Self.hookInvocation)
        #expect(hookRuns, "Scripts/git-hooks/pre-push no longer runs \(Self.hookInvocation)")
        let hookLegOn = Self.hookLegRunsByDefault(hook)
        #expect(hookLegOn, """
            Scripts/git-hooks/pre-push's macOS leg no longer opens with `\(Self.hookDefault)` and one \
            relevance pattern matching \(Self.hookRelevantPaths): a leg that skips itself builds nothing
            """)
        Self.expectWorkflowAndHookReadersFixtured()
        Self.expectHookLegReaderFixtured()
        Self.expectScriptReadersFixtured()
        Self.expectSelfTestReaderFixtured()
    }

    /// The workflow, hook and manifest readers, both ways: a step whose title names the script but whose
    /// run line is commented out or absent, or which is declared twice, does not run it, and the next
    /// step's run line is not its own; a step with an `if:` or a `continue-on-error:`, or in a job with
    /// an `if:`, does not run it, while the same step in an unguarded job does; a hook that only echoes
    /// the check's name, or names it in a comment, does not run it; a commented-out platform is not
    /// declared; and the preamble and trigger readers (``expectPreambleAndTriggerReadersFixtured(step:script:)``).
    static func expectWorkflowAndHookReadersFixtured() {
        let name = "Mac (Scripts/macos-build-selftest.sh)"
        let script = "Scripts/macos-build-selftest.sh"
        let running = "  - name: \(name)\n    run: |\n      set -euo pipefail\n      \(script)\n  - name: Next\n    run: x\n"
        #expect(stepRuns(script, step: name, in: running), "a step whose body runs the script was not read")
        let commented = "  - name: \(name)\n    run: |\n      set -euo pipefail\n      # \(script)\n"
        #expect(!stepRuns(script, step: name, in: commented), "a commented-out run line was read as running")
        let titled = "  - name: \(name)\n    run: |\n      set -euo pipefail\n"
        #expect(!stepRuns(script, step: name, in: titled), "a step whose title alone names the script was read as running")
        let nextStep = "  - name: \(name)\n    run: echo \"\(script)\"\n  - name: Next\n    run: |\n      \(script)\n"
        #expect(!stepRuns(script, step: name, in: nextStep), "the next step's run line was read as this step's")
        #expect(!stepRuns(script, step: name, in: running + running), "a step declared twice was read as declared once")
        let skipped = "  - name: \(name)\n    if: ${{ false }}\n    run: |\n      \(script)\n"
        #expect(!stepRuns(script, step: name, in: skipped), "a step its `if:` skips was read as running")
        let tolerated = "  - name: \(name)\n    continue-on-error: true\n    run: |\n      \(script)\n"
        #expect(!stepRuns(script, step: name, in: tolerated), "a step whose failure fails nothing was read as running")
        let job = "jobs:\n  wall:\n    runs-on: macos-26\n    steps:\n      - name: \(name)\n        run: |\n"
            + "          set -euo pipefail\n          \(script)\n"
        #expect(stepRuns(script, step: name, in: job), "a step in a job with no guard was not read as running")
        let skippedJob = job.replacingOccurrences(of: "    steps:\n", with: "    if: false\n    steps:\n")
        #expect(!stepRuns(script, step: name, in: skippedJob), "a step whose job its `if:` skips was read as running")
        let echoed = "echo \"[pre-push] Running the macOS build check (Scripts/macos-build-check.sh)…\"\n"
            + "# \(hookInvocation)\n"
        #expect(!runLines(of: echoed).contains(hookInvocation), "an echo or a comment naming the check was read as running it")
        #expect(runLines(of: "  \(hookInvocation)\n  code=$?\n").contains(hookInvocation),
                "the hook's invocation line was not read")
        let platforms = "platforms: [\n    .iOS(.v26),\n    // .macOS(.v26),\n],\nproducts: []\n"
        #expect(platformEntries(in: platforms) == [".iOS(.v26)"], "a commented-out platform was read as declared")
        expectPreambleAndTriggerReadersFixtured(step: name, script: script)
    }

    /// The preamble and trigger readers, both ways: a step whose body, between ``stepPreamble`` and its
    /// run line, exits (a bare `exit 0`, one after `&&`, one inside an `if …; then … fi`), guards the run
    /// line (an `if …; then :; else` closed by a `fi` after it) or continues a guard onto it (a trailing
    /// `\`) does not run it, while the same lines after the run line do not stop it; and an `on:` block
    /// without `pull_request:`, with `workflow_dispatch:` where `push:` was, or with a `paths:` filter under
    /// `push:` does not run on every change to `main`, while the workflow's own shape does.
    static func expectPreambleAndTriggerReadersFixtured(step name: String, script: String) {
        let head = "  - name: \(name)\n    run: |\n      set -euo pipefail\n"
        let shapes: [(line: String, closing: String)] = [
            ("exit 0", ""), (#"[ -n "$X" ] && exit 0"#, ""), ("if true; then exit 0; fi", ""),
            (#"if [ -z "${RUN_MAC:-}" ]; then :; else"#, "      fi\n"), (#"[ -n "${SKIP_MAC:-}" ] || \"#, "")
        ]
        // R2: bounded by the five shapes.
        for shape in shapes {
            #expect(!stepRuns(script, step: name, in: head + "      \(shape.line)\n      \(script)\n" + shape.closing),
                    "a step that runs `\(shape.line)` before its run line was read as running")
            #expect(stepRuns(script, step: name, in: head + "      \(script)\n      \(shape.line)\n" + shape.closing),
                    "a step that runs `\(shape.line)` after its run line was not read as running")
        }
        let main = #"branches: ["main"]"#
        let shaped = "on:\n  push:\n    \(main)\n  pull_request:\n    \(main)\n\nconcurrency:\n  group: x\n"
        #expect(triggersRunOnMain(shaped), "the workflow's own `on:` shape was not read as running on every change")
        let unreviewed = "on:\n  push:\n    \(main)\njobs:\n  wall:\n"
        #expect(!triggersRunOnMain(unreviewed), "an `on:` without `pull_request:` was read as running on every change")
        let dispatched = shaped.replacingOccurrences(of: "  push:\n", with: "  workflow_dispatch:\n")
        #expect(!triggersRunOnMain(dispatched), "an `on:` with `workflow_dispatch:` for `push:` was read as running on every push")
        let filtered = shaped.replacingOccurrences(of: "  push:\n    \(main)\n", with: "  push:\n    \(main)\n    paths: [\"Docs/**\"]\n")
        #expect(!triggersRunOnMain(filtered), "an `on:` whose push is filtered by `paths:` was read as running on every push")
    }

    /// The hook-leg reader, both ways: a leg on by default whose pattern matches the manifest and a
    /// FernletFoundation source runs; a leg off by default, a pattern that misses the manifest, and a
    /// pattern only a comment assigns do not.
    static func expectHookLegReaderFixtured() {
        let pattern = #"'^(FernletKit/Package\.swift|FernletKit/Sources/FernletFoundation/)'"#
        let leg = "macos_relevant_regex=\(pattern)\n\(hookDefault)\n"
        #expect(hookLegRunsByDefault(leg), "a leg on by default with a relevant pattern was not read as running")
        #expect(!hookLegRunsByDefault(leg.replacingOccurrences(of: ":-0", with: ":-1")),
                "a leg off by default was read as running")
        #expect(!hookLegRunsByDefault(leg.replacingOccurrences(of: "FernletKit/Package", with: "Nothing/Package")),
                "a pattern that misses the manifest was read as relevant")
        #expect(!hookLegRunsByDefault("# " + leg), "a pattern only a comment assigns was read as relevant")
    }

    /// The command reader, both ways: flags in an `echo` beside a bare `xcodebuild build` are not that
    /// command's; a command split across `\` continuations is read whole, every flag with it; a
    /// commented-out command and a `build-for-testing` are no `xcodebuild build`, while asked for its own
    /// action the `build-for-testing` is read alone; and a flag is matched as whole words.
    static func expectScriptReadersFixtured() {
        let echoed = "echo \"xcodebuild build -scheme ProximityKit SUPPRESS_WARNINGS=NO\"\nxcodebuild build -scheme Other\n"
        let bare = xcodebuildBuildCommands(in: echoed)
        #expect(bare == ["xcodebuild build -scheme Other"], "read the commands as \(bare)")
        #expect(!bare.contains { carries("SUPPRESS_WARNINGS=NO", in: $0) || carries("-scheme ProximityKit", in: $0) },
                "flags in an echo were read as the command's")
        let split = #"""
            # xcodebuild build -scheme Commented
            xcodebuild build -scheme MacReady -destination 'generic/platform=macOS' \
              -derivedDataPath "$DERIVED" \
              DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR SUPPRESS_WARNINGS=NO
            xcodebuild build-for-testing -scheme Fernlet
            """#
        let joined = xcodebuildBuildCommands(in: split)
        #expect(joined.count == 1, "read \(joined.count) `xcodebuild build` commands, not the one split across lines")
        let flags = checkCommandFlags + ["SUPPRESS_WARNINGS=NO"]
        #expect(flags.allSatisfy { flag in joined.contains { carries(flag, in: $0) } },
                "a flag on a continuation line was not read with its command: \(joined)")
        let testing = xcodebuildBuildCommands(in: split, action: "build-for-testing")
        #expect(testing == ["xcodebuild build-for-testing -scheme Fernlet"], "read the build-for-testing commands as \(testing)")
        #expect(!carries("-scheme ProximityKit", in: "xcodebuild build -scheme ProximityKitTests"),
                "a longer scheme name was read as ProximityKit")
        #expect(!carries("SUPPRESS_WARNINGS=NO", in: "xcodebuild build XSUPPRESS_WARNINGS=NO"),
                "a longer setting was read as SUPPRESS_WARNINGS=NO")
    }

    /// The self-test reader, both ways: a self-test that runs both legs is read whole, and one whose
    /// grep and positive leg appear only in `echo` lines and comments is missing exactly those two.
    static func expectSelfTestReaderFixtured() {
        let whole = """
            PROBE="\(selfTestProbePath)"
            cat > "$PROBE" <<'SWIFT'
            import UIKit
            SWIFT
            OUT=\(selfTestCapture)
            printf '%s' "$OUT" | grep -qi "\(macOSOnlyFailure)"
            Scripts/macos-build-check.sh
            """
        let read = missingSelfTestLegs(in: whole)
        #expect(read.isEmpty, "a self-test running both legs was read as missing \(read)")
        let named = """
            PROBE="\(selfTestProbePath)"
            import UIKit
            OUT=\(selfTestCapture)
            echo "grep for \(macOSOnlyFailure)"
            # Scripts/macos-build-check.sh
            echo "Scripts/macos-build-check.sh again"
            """
        let missing = missingSelfTestLegs(in: named)
        #expect(missing.count == 2 && missing.allSatisfy { $0.contains("grep") || $0.contains("positive") },
                "a self-test naming its grep and its positive leg only in an echo or a comment was read as \(missing)")
    }

    // MARK: The readers

    /// How many times `needle` is read in `code`.
    static func mentions(of needle: Needle, in code: String) throws -> Int {
        let regex = try NSRegularExpression(pattern: needle.pattern)
        return regex.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }

    /// The first capture group of every match of `regex` in `text`.
    static func captures(of regex: NSRegularExpression, in text: String) -> [String] {
        let string = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: string.length)).map {
            string.substring(with: $0.range(at: 1))
        }
    }

    // MARK: The build readers (W6)

    /// The trimmed lines of `text` that are neither blank nor comment-only (`commentPrefix` first).
    static func nonCommentLines(_ text: String, commentPrefix: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(commentPrefix) }
    }

    /// The lines of a shell script that run something, trimmed: not blank, not a `#` comment and not an
    /// `echo`, so a line that only prints a script's or a flag's name runs neither.
    static func runLines(of script: String) -> [String] {
        nonCommentLines(script, commentPrefix: "#").filter { $0 != "echo" && !$0.hasPrefix("echo ") }
    }

    /// `line` without one trailing comma, as an array element's line is compared.
    static func droppingTrailingComma(_ line: String) -> String {
        line.hasSuffix(",") ? String(line.dropLast()).trimmingCharacters(in: .whitespaces) : line
    }

    /// The entries of a manifest's `platforms:` array, read from its non-comment lines, or nil when the
    /// manifest does not declare `platforms:` exactly once with a bracketed list.
    static func platformEntries(in manifest: String) -> [String]? {
        let code = nonCommentLines(manifest, commentPrefix: "//").joined(separator: "\n")
        guard code.components(separatedBy: "platforms:").count == 2,
              let key = code.range(of: "platforms:"),
              let open = code[key.upperBound...].firstIndex(of: "["),
              let close = code[open...].firstIndex(of: "]") else { return nil }
        return code[code.index(after: open)..<close].split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// What a step's body must hold before its run line, exactly, line for line: the `run: |` key and
    /// `set -euo pipefail`, the macOS step's own preamble. Any other line there could keep the run line
    /// from running or from failing the step (an `exit`, an `if …; then :; else` around it, a guard
    /// whose trailing `\` continues onto it), so none is allowed.
    static let stepPreamble = ["run: |", "set -euo pipefail"]

    /// Whether `workflow` declares the step named `name` exactly once, that step's body, read with
    /// `CIGateSelectorBoundaryTests.stepBody(named:in:)` (its own non-comment lines, trimmed, the
    /// `- name:` line not among them), holds a line that is exactly `run` with exactly
    /// ``stepPreamble`` before it, and neither that body nor the keys of the job that holds the step
    /// (``jobKeys(holding:in:)``) set `if:` or `continue-on-error:`: a step or job with either is
    /// declared but may be skipped, or may fail without failing the run, and a line before the run line
    /// that is not the preamble's may end the step first, guard the run line or continue onto it.
    static func stepRuns(_ run: String, step name: String, in workflow: String) -> Bool {
        let lines = workflow.components(separatedBy: "\n")
        let declarations = lines.filter { $0.trimmingCharacters(in: .whitespaces) == "- name: \(name)" }
        let body = CIGateSelectorBoundaryTests.stepBody(named: name, in: workflow).components(separatedBy: "\n")
        let guarded = (body + jobKeys(holding: name, in: lines)).contains(where: isRunGuard)
        guard declarations.count == 1, !guarded, let runLine = body.firstIndex(of: run) else { return false }
        return Array(body[..<runLine]) == stepPreamble
    }

    /// Whether a trimmed workflow line sets `if:` or `continue-on-error:`, its key quoted or not.
    static func isRunGuard(_ line: String) -> Bool {
        line.range(of: #"^["']?(?:if|continue-on-error)["']?\s*:"#, options: .regularExpression) != nil
    }

    /// Whether `workflow`'s top-level `on:` block (``onBlock(of:)``) runs the workflow on every push and
    /// every pull request to `main`: it holds `push:` and `pull_request:`, each directly holding
    /// `branches: ["main"]`, and nowhere a `paths:`, `paths-ignore:` or `branches-ignore:` key, any of
    /// which lets a change to `main` pass without the workflow running.
    static func triggersRunOnMain(_ workflow: String) -> Bool {
        let indentOf = { (line: String) -> Int in line.prefix { $0 == " " }.count }
        guard let block = onBlock(of: workflow), let first = block.first else { return false }
        let indent = indentOf(first)
        let keys = block.map { $0.trimmingCharacters(in: .whitespaces) }
        let refused = ["paths:", "paths-ignore:", "branches-ignore:"]
        guard !keys.contains(where: { key in refused.contains(where: { key.hasPrefix($0) }) }) else { return false }
        return ["push:", "pull_request:"].allSatisfy { trigger in
            guard let start = block.indices.first(where: { indentOf(block[$0]) == indent && keys[$0] == trigger }) else {
                return false
            }
            let end = block.indices.first(where: { $0 > start && indentOf(block[$0]) <= indent }) ?? block.endIndex
            return keys[(start + 1)..<end].contains(#"branches: ["main"]"#)
        }
    }

    /// The code lines of `workflow`'s top-level `on:` block, as written: from the line that is exactly
    /// `on:` to the next line at the left margin, blank and comment lines left out; nil when the workflow
    /// does not declare it exactly once as a block.
    static func onBlock(of workflow: String) -> [String]? {
        let lines = workflow.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        let starts = lines.indices.filter { lines[$0] == "on:" }
        guard starts.count == 1, let start = starts.first else { return nil }
        let end = lines[(start + 1)...].firstIndex { !$0.hasPrefix(" ") } ?? lines.endIndex
        return Array(lines[(start + 1)..<end])
    }

    /// The keys of the job whose `steps:` hold the step named `name`, trimmed: the job's own lines at its
    /// `steps:` key's indentation, from the job's header (the last line before `steps:` indented less) to
    /// the next line indented no deeper than that header, blank and comment lines left out. Empty when no
    /// `steps:` key precedes the step.
    static func jobKeys(holding name: String, in lines: [String]) -> [String] {
        let isCode = { (line: String) -> Bool in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        let indent = { (line: String) -> Int in line.prefix { $0 == " " }.count }
        guard let step = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "- name: \(name)" }),
              let steps = lines[..<step].lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "steps:" }),
              let header = lines[..<steps].lastIndex(where: { isCode($0) && indent($0) < indent(lines[steps]) })
        else { return [] }
        let end = lines[(header + 1)...].firstIndex { isCode($0) && indent($0) <= indent(lines[header]) } ?? lines.endIndex
        return lines[(header + 1)..<end].filter { isCode($0) && indent($0) == indent(lines[steps]) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Whether the hook's macOS leg runs by default and finds a change to the Mac-ready set relevant: the hook's
    /// run lines hold ``hookDefault`` and exactly one assignment of the leg's relevance pattern
    /// (``hookRelevancePrefix``, the pattern single-quoted), and that pattern matches every one of
    /// ``hookRelevantPaths``.
    static func hookLegRunsByDefault(_ hook: String) -> Bool {
        let lines = runLines(of: hook)
        let patterns = lines.filter { $0.hasPrefix(hookRelevancePrefix) && $0.hasSuffix("'") }
            .map { String($0.dropFirst(hookRelevancePrefix.count).dropLast()) }
        guard lines.contains(hookDefault), patterns.count == 1, let pattern = patterns.first else { return false }
        return hookRelevantPaths.allSatisfy { $0.range(of: pattern, options: .regularExpression) != nil }
    }

    /// What the self-test must run, each on a line ``runLines(of:)`` reads, by name: the probe planted
    /// in FernletFoundation and its `import UIKit`; the negative leg's capture of the check and its grep for
    /// the failure only a native macOS build gives; and the positive leg, a line that runs the check
    /// again. Empty when every leg runs.
    static func missingSelfTestLegs(in script: String) -> [String] {
        let lines = runLines(of: script)
        let probe = Self.selfTestProbePath
        let capture = Self.selfTestCapture
        let failure = Self.macOSOnlyFailure
        let check = "Scripts/macos-build-check.sh"
        let legs: [(name: String, runs: (String) -> Bool)] = [
            ("the probe planted at \(probe)", { $0.contains(probe) }),
            ("the probe's `import UIKit`", { $0 == "import UIKit" }),
            ("the negative leg's capture \(capture)", { $0.contains(capture) }),
            ("the negative leg's grep for \"\(failure)\"", { $0.contains("grep") && $0.contains(failure) }),
            ("the positive leg, a line that runs \(check)", { $0.hasPrefix(check) })
        ]
        return legs.filter { leg in !lines.contains(where: leg.runs) }.map(\.name)
    }

    /// The commands in a shell script that start `xcodebuild <action>`, `build` unless another action is
    /// asked for: comment lines dropped and each command joined across its trailing-`\` continuations,
    /// so a flag on a continuation line is read with its command, while a flag in an `echo` or a comment
    /// is not, and `build-for-testing` is not `build`. Shared with `PowerOfTenBoundaryTests`' two strict
    /// build pins, `r10MacOSBuildCheckScriptBuildsStrict()` (`build`) and `r10WallCheckScriptBuildsStrict()`
    /// (`build-for-testing`).
    static func xcodebuildBuildCommands(in script: String, action: String = "build") -> [String] {
        var commands: [String] = []
        var carry = ""
        // R2: bounded by the script's line count.
        for rawLine in script.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasSuffix("\\") {
                carry += String(line.dropLast()) + " "
                continue
            }
            commands.append(carry + line)
            carry = ""
        }
        if !carry.isEmpty { commands.append(carry) }
        return commands.filter { command in
            let words = command.split(whereSeparator: \.isWhitespace)
            return words.count >= 2 && words[0] == "xcodebuild" && words[1] == action
        }
    }

    /// Whether `command` holds `flag`'s words as whole words, in order and adjacent, so
    /// `-scheme ProximityKit` is not `-scheme ProximityKitTests` and `SUPPRESS_WARNINGS=NO` is not the
    /// tail of a longer setting. Shared with `PowerOfTenBoundaryTests.r10MacOSBuildCheckScriptBuildsStrict()`.
    static func carries(_ flag: String, in command: String) -> Bool {
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        let needle = flag.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !needle.isEmpty, words.count >= needle.count else { return false }
        return (0...(words.count - needle.count)).contains { Array(words[$0..<($0 + needle.count)]) == needle }
    }

    /// `source`'s code as the walls read it: comments dropped, literals emptied.
    static func lexedCode(_ source: String) -> String {
        SwiftSourceLexer.lex(source).code
    }
}