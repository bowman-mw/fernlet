// MeshP10ImportWallAcceptanceTests.swift
// FernletTests
//
// Network migration **P10's acceptance battery, clause (4)** (plan §16.4, §17.2, launcher item 9):
// the background-refresh import and call-spelling wall, promoted to the clause level.
//
// §17.2 names five things the handler must NEVER do — touch the mesh, touch HealthKit, force a
// CloudKit sync, reach Foundation Models, or create a store while protected data is unavailable —
// and §16.4 makes the mechanical half of that a repository gate. `BackgroundRefreshBoundaryTests` IS
// that gate; this clause asserts the gate is real, is aimed at the right directory, is at least as
// big as it was measured to be, and runs on a CI line.
//
// **The pins are read as VALUES, never re-spelled.** `measuredSpellingCount`,
// `measuredClockAndPersistenceCount`, `measuredAppDeclarationCount`, `measuredRadioVerbCount` and
// `minimumFilesScanned` are `static let`s on the wall suite, in the same test module; a second copy
// of 84 needles here would be a second list to keep whole, and two lists edited together would both
// stay green. What this clause adds is the direction the wall cannot assert about itself: that its
// numbers have not SHRUNK, that its scan root is still the refresh directory, and that it is on a
// workflow line at all — a wall with no compiler half that leaves CI is a wall that runs nowhere.
//
// **Every walk here is this file's own.** The directory walk, the source scan and the identifier
// count go through `FileManager` and `MeshP7Acceptance.sources(under:)` rather than through the
// wall's own `swiftFiles()` — a broken helper would otherwise make the wall and its acceptance
// clause green together, which is precisely the failure an acceptance battery exists to catch.
//
// The wall itself lives on the `s3-grep` step and not on the mesh-batteries one: it is not a
// `MeshP<n>…AcceptanceTests`, so `everyMeshAcceptanceBatteryIsGated` demands it nowhere, and the
// name pins below are the only thing that would notice it leaving.

import Foundation
import Testing
@testable import Fernlet

/// **Clause (4): the import and call-spelling wall.** Aimed at the refresh directory, no smaller
/// than it was measured, covering §17.2's five prohibitions, holding the identifier as its positive
/// needle, and running on a CI line of its own.
@MainActor
@Suite(.serialized)
struct MeshP10ImportWallAcceptanceTests {

    /// The refresh suites that ride the `s3-grep` step: the wall itself and the three unit suites
    /// beside it.
    ///
    /// Name-pinned for `MeshRoutedDrainWallTests`' reason: none of the four is a
    /// `MeshP<n>…AcceptanceTests`, so nothing DEMANDS any of them, and `measuredSuiteNameCounts`
    /// catches only a name leaving the line as a COUNT — it cannot say which one left.
    private static let gatedRefreshSuites = [
        "BackgroundRefreshBoundaryTests",
        "CompanionRefreshSchedulingTests",
        "CompanionRefreshPipelineTests",
        "WidgetSnapshotContentEqualityTests"
    ]

    /// **The wall is aimed at the refresh directory, and its floor covers every file this phase
    /// landed there.**
    ///
    /// The floor is the anti-vacuity half. A scan root that stopped resolving enumerates NOTHING,
    /// finds no violations and passes — the wall reports green precisely when it has stopped
    /// looking — so the floor must track the real file count rather than sitting at one.
    ///
    /// The walk below is this file's own `FileManager` enumeration, deliberately: if the wall's
    /// `swiftFiles()` broke, the wall and this clause would otherwise go green together.
    @Test func theWallIsAimedAtTheRefreshDirectoryAndItsFloorIsNotVacuous() throws {
        #expect(BackgroundRefreshBoundaryTests.refreshRoot == MeshP10Acceptance.refreshRoot,
                "the wall still walks the directory every refresh file lands in")
        let root = RepoRoot.url(MeshP10Acceptance.refreshRoot)
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let found = (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }

        #expect(found.count >= BackgroundRefreshBoundaryTests.minimumFilesScanned, """
            \(found.count) Swift files under \(MeshP10Acceptance.refreshRoot), against a floor of \
            \(BackgroundRefreshBoundaryTests.minimumFilesScanned). A directory that stopped \
            resolving reports zero and the wall passes having scanned nothing
            """)
        #expect(BackgroundRefreshBoundaryTests.minimumFilesScanned >= 5, """
            the floor fell below the five files items 2, 3 and 4 landed (the identifier, the \
            scheduling seam, the coordinator, the pipeline and the wiring) — lower it only with a \
            file's retirement argued in the same commit
            """)
        #expect(BackgroundRefreshBoundaryTests.appTargetRoot == "App/Fernlet",
                "and the second walk — the one that proves each app-declared needle still names something")
    }

    /// **The zero-list is no smaller than it was measured, and §17.2's five prohibitions each have a
    /// needle.**
    ///
    /// The counts are the wall's own pins, read as values; the five prohibitions are re-derived here
    /// from the SPECIFICATION rather than from the list, which is the point — a needle quietly
    /// dropped for one of the five would leave the count pin satisfied by whatever replaced it.
    ///
    /// The store-creation pair is the one §17.2 prohibition an import-only wall is blind to: the app
    /// target is ONE module, so `FernletStore(` and `FernletStore.load(` reach it with no import
    /// line at all.
    @Test func theZeroListIsWholeAndCoversEveryProhibitionTheSpecificationNames() {
        let spellings = BackgroundRefreshBoundaryTests.forbiddenSpellings
        #expect(spellings.count >= BackgroundRefreshBoundaryTests.measuredSpellingCount, """
            \(spellings.count) needles against a measured \
            \(BackgroundRefreshBoundaryTests.measuredSpellingCount). A needle removed is a \
            prohibition retired; LOWER the pin only with the retirement argued
            """)
        let family = spellings.filter {
            $0.why.hasPrefix(BackgroundRefreshBoundaryTests.clockAndPersistenceReasonPrefix)
        }
        #expect(family.count >= BackgroundRefreshBoundaryTests.measuredClockAndPersistenceCount, """
            the clock-and-persistence family shrank (\(family.count) against \
            \(BackgroundRefreshBoundaryTests.measuredClockAndPersistenceCount)). It is where "at \
            handle + background, never on a timer" and "no new persisted surface" are actually \
            enforced — neither has any other mechanical home
            """)
        let appDeclared = spellings.filter(\.isAppDeclaration)
        #expect(appDeclared.count >= BackgroundRefreshBoundaryTests.measuredAppDeclarationCount,
                "and the app-declared needles, each of which is proved to still name a declaration")
        #expect(BackgroundRefreshBoundaryTests.measuredRadioVerbCount == 10,
                "the ten radio verbs copied from the retirement wall, as a value")

        let tokens = Set(spellings.map(\.token))
        // R2: bounded by the five prohibitions §17.2 names.
        for needle in ["ProximityKit", "HKHealthStore", "CKContainer", "LanguageModelSession", "FernletStore("] {
            #expect(tokens.contains(needle), """
                §17.2's prohibition behind `\(needle)` has no needle any more. The five are: never \
                the mesh, never HealthKit, never a CloudKit force-sync, never Foundation Models, \
                never a store creation while protected data is unavailable
                """)
        }
        #expect(tokens.contains("FernletStore.load("),
                "…and the creation path's other spelling: acquire through `FernletStoreAccess.shared.load()`")
    }

    /// **The module classification is a partition, and the allowlist is tiny on purpose.**
    ///
    /// Three sets and one derivation. `permittedModules` is DERIVED from the reasons map so the
    /// filter and the explanations cannot drift apart; the permitted set is disjoint from both
    /// forbidden maps, so no module is quietly on two lists; and the allowlist is pinned to the SIX
    /// names it holds — by count and by name — because a name added to it is a claim that a
    /// ≤ 30 s opportunistic task needs a new framework, and that belongs in a review with its
    /// argument rather than in a drive-by edit.
    ///
    /// Pinned at the MEASURED six rather than bounded by a round number: the `<= 8` this cell
    /// shipped with left two slots a seventh and an eighth framework could occupy in silence, which
    /// is the whole review the clause exists to force. Both halves are read off the wall's own
    /// `permitted` set, so the two suites cannot drift apart without one of them going red.
    @Test func theModuleClassificationIsAPartitionAndTheAllowlistIsSmall() {
        let permitted = BackgroundRefreshBoundaryTests.permittedModules
        let forbidden = Set(BackgroundRefreshBoundaryTests.forbiddenModuleReasons.keys)
        let frameworks = Set(BackgroundRefreshBoundaryTests.forbiddenAppleFrameworkReasons.keys)

        #expect(permitted == Set(BackgroundRefreshBoundaryTests.permittedModuleReasons.keys),
                "the permitted set is derived from the reasons, so a name cannot be allowed unexplained")
        #expect(permitted.isDisjoint(with: forbidden), "no FernletKit module is both allowed and forbidden")
        #expect(permitted.isDisjoint(with: frameworks), "and no Apple framework is")
        #expect(permitted.count == 6, """
            the refresh handler's allowlist is \(permitted.count) modules, not the six this clause \
            measured. Each name is a claim that a fifteen-minute opportunistic task needs a \
            framework; move this pin only with the claim written down
            """)
        #expect(permitted == ["Foundation", "BackgroundTasks", "WidgetKit",
                              "FernletFoundation", "FernletDomainModel", "os"], """
            …and they are those six BY NAME (\(permitted.sorted().joined(separator: ", "))). A \
            count alone lets one name leave as another arrives, which is a framework entering the \
            ≤ 30 s task with nobody's argument behind it
            """)
        // R2: bounded by the four frameworks §17.2 names by hand.
        for framework in ["HealthKit", "CloudKit", "FoundationModels", "MultipeerConnectivity"] {
            #expect(frameworks.contains(framework), "`\(framework)` lost its spelled-out prohibition")
        }
        #expect(forbidden.contains("ProximityKit") && forbidden.contains("AIProviders")
                && forbidden.contains("CloudKitSync") && forbidden.contains("HealthKitGateway"),
                "and the four FernletKit modules the five prohibitions actually live behind")
    }

    /// **The identifier is the wall's positive needle and appears exactly once, as code.**
    ///
    /// A wall made only of prohibitions passes vacuously over an emptied directory. The identifier
    /// is the one thing that must BE there, so a directory reduced to comments reds instead of going
    /// quiet — and "exactly once" is what keeps a second, drifting copy from appearing beside it.
    ///
    /// Counted over comment-stripped source, so the literal in a header paragraph does not satisfy
    /// it: `MeshRoutedSourceScan.codeOnly` drops whole-line comments, which is what every `///` and
    /// `//` line in those files is.
    @Test func theIdentifierIsThePositiveNeedleAndAppearsExactlyOnceAsCode() throws {
        let sources = try MeshP7Acceptance.sources(under: MeshP10Acceptance.refreshRoot)
        #expect(sources.count >= BackgroundRefreshBoundaryTests.minimumFilesScanned,
                "the scan lost the refresh directory (\(sources.count) files)")

        let quoted = "\"" + MeshP10Acceptance.taskIdentifier + "\""
        let homes = MeshP7Acceptance.homes(of: quoted, in: sources)
        #expect(homes == ["CompanionRefreshIdentifier.swift"], """
            the frozen identifier has \(homes.count) code homes (\(homes)) instead of one. Zero \
            means the directory was emptied or reduced to comments and every prohibition below \
            passes over nothing; two means a copy that can drift from `Info.plist` silently
            """)
        #expect(MeshP7Acceptance.homes(of: "import BackgroundTasks", in: sources).count == 1,
                "the framework enters the directory through exactly one door, the seam")
        #expect(Set(MeshP7Acceptance.homes(of: "BGAppRefreshTask", in: sources))
                == ["CompanionRefreshScheduling.swift"], """
            `BGAppRefreshTask` is spoken in one file. The coordinator speaks the SEAM's protocols \
            and the pipeline knows what a background task is not at all — which is what makes both \
            drivable by a fake
            """)
    }

    /// **The wall runs on a CI line, and so do the three refresh unit suites beside it.**
    ///
    /// None of the four is a `MeshP<n>…AcceptanceTests`, so `everyMeshAcceptanceBatteryIsGated`
    /// demands none of them; `measuredSuiteNameCounts` notices a name LEAVING the step but cannot
    /// say which. This is the `MeshRoutedDrainWallTests` argument applied to P10's own four: a wall
    /// with no compiler half, and three suites whose subject is a background task nothing else in
    /// the tree exercises.
    ///
    /// The clause suites of this battery are deliberately NOT here — they ride the mesh-batteries
    /// step, and clause (5) is where that is asserted.
    @Test func theWallAndTheRefreshUnitSuitesAreOnACiLine() throws {
        let workflow = try RepoRoot.source(MeshP10Acceptance.workflowPath)
        let steps = CIGateSelectorBoundaryTests.gatedSteps(in: workflow)
        let grep = steps.filter { $0.label == "s3-grep" }
        #expect(grep.count == 1, "one s3-grep step")
        let named = Set(grep.first?.suites ?? [])

        // R2: bounded by the four named suites.
        for suite in Self.gatedRefreshSuites {
            #expect(named.contains(suite), """
                `\(suite)` left the `s3-grep` step, and it runs on no other line: §16.4's wall has \
                no compiler half at all, and the three refresh suites are the only thing in the \
                tree that drives a `BGAppRefreshTask` seam
                """)
        }
        #expect(named.count >= 7, """
            the s3-grep step names \(named.count) suites, against the seven measured on it. The \
            four above belong THERE rather than on the mesh line because that step's floor is the \
            shared `1` — adding a name needs no Mac to re-measure, where the mesh step's floor is a \
            measured test count
            """)
    }
}
