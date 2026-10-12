// ProximityPlatformBoundaryTests.swift
// FernletTests
//
// The wall that keeps ProximityKit free of platform policy (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md
// §4 A0.6, Mac readiness). ProximityKit holds no platform policy: it builds for iOS 26 and native
// macOS 26 and computes no value whose right answer differs by platform or by app. What an unnamed
// device is called, whether a connection ranges and where an installation keeps its files are its
// host's to state, each a `ProximityHost` requirement with no default, and the module keeps only the
// two mechanism seams a platform needs, each compiled only where its framework is usable. Two halves
// hold it there. The compiler half is `Scripts/macos-build-selftest.sh`, on every push: it builds
// ProximityKit for native macOS, with the three modules a Mac host of Fernlet's needs beside it
// (the `MacReady` product), which refuses any symbol native macOS lacks wherever it stands outside
// its guard, after proving that build fails on a planted `import UIKit`. This suite is
// the source half, because the iOS compiler sees none of it and the macOS compiler not all of it: a
// UIKit, NearbyInteraction or ActivityKit import, a read of the device's name, a platform directory
// and a default for a fact only the host may state all compile clean on iOS and pass every other
// test, and a directory, a device-name read or a host default compiles on macOS too. So it reads
// ProximityKit's source through `ProximityNamespaceBoundaryTests`' one walker (lexed: comments
// dropped, literals emptied) and holds five rules, its readers fixtured both ways in a cell of their
// own, the fifth keeping the compiler half running:
//
//   1. every module a file imports (`import M`, `@preconcurrency import M`, `@_spi(S) import M`,
//      `import struct M.X`, at a line's start or after a `;`) or tests for with `canImport(M)` is a
//      neutral baseline module, available on both platforms, or an exact seam row: a file, a module,
//      how its imports are guarded and, for a transient row, the plan step that deletes it. A guarded
//      seam's every import sits in its `#if` branch, never in its `#else`; a whole-file seam's file
//      opens with its `#if` and closes with its `#endif`, and holds no other `#if`. And no `#if` or
//      `#elseif` tests the platform with `os(…)` but a seam row's own guard: a platform branch is
//      policy the iOS run never executes and the macOS build compiles;
//   2. no file names a source of the device's or its user's name (`UIDevice`, `Host.current`, `NSHost`,
//      `hostName`, `NSFullUserName` and `NSUserName`, the BSD account calls and record fields
//      (`getlogin`, `getpwuid`, `pw_name`, `pw_gecos`), the SystemConfiguration, CoreServices and BSD
//      host-name calls, the `KERN_HOSTNAME` sysctl, `localizedName`), but on the rows listed;
//   3. no file names a Foundation API for a platform directory (Application Support, Documents,
//      Caches, Library, the user's application, media and trash folders, the temporary, home and
//      current directories, a search-path call or lookup, a container), but on the rows listed, a path
//      spelled in a literal being out of a lexed reader's sight, and no `ProximityHost` extension
//      declares a default for a fact only the host may state (its namespace, install binding, trust
//      policy, identity, routed rows, fallback name, ranging provider and storage root), read as
//      declarations at the extension's top level, never as names;
//   4. every channel-ready door that builds a connection's coordinator (the mesh's and the pair
//      session's here, and presence's heart door in FernletSocial, Fernlet's half) builds it over its
//      host's `makeProximityRangingProvider()`, once, naming no provider of its own, and
//      `NIRangingSession` is named in ProximityKit code only in its own file;
//   5. ProximityKit's macOS build is a compiled fact on every push: the package manifest declares
//      macOS 26, ProximityKit's own product and the `MacReady` product, which names ProximityKit,
//      FernletFoundation, FernletCrypto and FernletDomainModel, the CI workflow runs on every push
//      and pull request to `main` with no path or branch filter, and its macOS step, with no `if:` or
//      `continue-on-error:` on it or on its job and nothing but its preamble (`run: |`,
//      `set -euo pipefail`) before its run line, runs `Scripts/macos-build-selftest.sh`
//      (whose negative leg plants an `import UIKit` in ProximityKit and greps the failure only a native
//      macOS build gives, and whose positive leg builds the clean tree), `Scripts/macos-build-check.sh`
//      holds the one `xcodebuild build` command for the `MacReady` product and native macOS, and the
//      pre-push hook runs it, its leg on unless a person skips it and relevant to a change of the
//      manifest or a ProximityKit source; each read from what runs, never from a step's title, an
//      `echo` or a comment, its readers fixtured both ways in the same cell.
//
// The first three rules are exact both ways: a new use fails, and a use that goes away fails too,
// until its row is deleted. Every row is permanent: `ProtectedSidecar.swift`'s guarded UIKit import
// (the protected-data retry, compiled only where UIKit is) and the NearbyInteraction provider's file,
// guarded whole by `#if os(iOS)`. There is no device-name row, no directory row and no host-fact
// default. The wall landed at plan step A0.6.0 as a ratchet over the tree before anything moved, with
// seven seam rows, a device-name row, a directory row and a host-fact default, and each transient row
// named the commit of plan step A0.6 that deleted it as its fact went to the host: the coordinator's,
// the mesh manager's and the recipe-share manager's vestigial UIKit imports at A0.6.1; the local name's
// UIKit import and its `UIDevice` read at A0.6.2, when the host began stating the fallback name; the
// NearbyInteraction provider's unguarded import at A0.6.3, when the doors began asking their host for
// each connection's ranging provider and the file was guarded whole, its row becoming the permanent
// seam; the Live Activity reaper's ActivityKit import at A0.6.4, with the reaper, which is the app's;
// and the namespace's Application Support default and the host extension's default root at A0.6.6,
// when the host began stating the storage root. A row's exit step stays a field, so that a later step
// can add a transient row with the step that deletes it, but no row carries one.
//
// It never spells the vendor-identifier symbol: `NoTrackingBoundaryTests` bans that spelling
// everywhere, comments included.

import Foundation
import Testing

/// ProximityKit imports only neutral modules and its declared platform seams, branches on the platform
/// only in their guards, reads no device name, computes no platform directory and defaults no fact only
/// its host may state, every channel-ready door asks its host for each connection's ranging provider,
/// and its native macOS build runs on every push: six cells, the first three rules exact both ways over
/// rows that are all permanent, and their readers fixtured both ways.
@Suite struct ProximityPlatformBoundaryTests {

    /// One ProximityKit file: its path under the module root and its lexed source, as
    /// `ProximityNamespaceBoundaryTests.proximitySources()` yields it.
    typealias Source = (path: String, lexed: SwiftSourceLexer.Lexed)

    /// Fewer files than this and the walk is broken, not the module clean: ProximityKit holds 135 Swift
    /// files at the end of plan step A0.6 (134 at A0.6.0, before A0.6.3 added the no-op provider).
    static let minimumFilesWalked = 120

    // MARK: The rows

    /// The plan step that takes a platform fact out of ProximityKit. A step's case is deleted with its
    /// last row, as A0.6.1's (the vestigial UIKit imports), A0.6.2's (the local name's `UIDevice` read
    /// and its file's `import UIKit`), A0.6.3's (the NearbyInteraction provider's unguarded import,
    /// whose row became the permanent whole-file seam), A0.6.4's (the Live Activity reaper's
    /// ActivityKit import, which left with the reaper for the app) and A0.6.6's (the namespace's
    /// Application Support default and the host extension's default root, when the host began stating
    /// the root) were.
    ///
    /// No case is left, so no row carries an exit and the enum is uninhabited: a row's `exit` is nil,
    /// a permanent row. The field stays so that a later step can add a transient row: that step adds
    /// its case with its step's name as a `String` raw value, the raw type with it, and
    /// ``exitText(_:)``'s arm naming it, which the compiler then requires.
    enum ExitStep: Sendable {}

    /// How a seam module's imports sit in their file.
    enum SeamGuard: Sendable, Equatable {
        /// Imported with no `#if` around it: only a transient row, which a later step deletes.
        case unguarded
        /// Every import of the module sits in the branch of `#if <condition>`, never in its `#else`; the
        /// rest of the file compiles everywhere.
        case partial(String)
        /// The file's code opens with `#if <condition>` and closes with its `#endif`, holding no other
        /// directive, so every import of the module sits in that one branch.
        case wholeFile(String)

        /// The `#if` condition the row's imports sit under, as written; nil for an unguarded row. W1
        /// allows a platform branch (`os(…)`) in the row's file under this condition alone.
        var condition: String? {
            switch self {
            case .unguarded:
                return nil
            case .partial(let text), .wholeFile(let text):
                return text
            }
        }
    }

    /// One module beyond the baseline that one ProximityKit file may import, or test for with
    /// `canImport`: the file, the module, how its imports are guarded, and the plan step that deletes
    /// the row (nil for a permanent seam).
    struct SeamRow: Sendable {
        /// The file, by its path under `FernletKit/Sources/ProximityKit/`.
        let path: String
        /// The module the file imports.
        let module: String
        /// How the file's imports of the module are guarded.
        let guarded: SeamGuard
        /// The step that deletes the row; nil for a permanent seam.
        let exit: ExitStep?
    }

    /// One place a ProximityKit file may still name a token a rule refuses: the file, the token as the
    /// rule's needle spells it, and the plan step that deletes the row (nil for a permanent one).
    struct TokenRow: Sendable {
        /// The file, by its path under `FernletKit/Sources/ProximityKit/`.
        let path: String
        /// The token, spelled as its needle's ``Needle/token``.
        let token: String
        /// The step that deletes the row; nil for a permanent one.
        let exit: ExitStep?
    }

    /// One token a rule refuses: its spelling, and the pattern that reads it in lexed code as a whole
    /// identifier, a dotted member or a labelled call, never inside a longer name.
    struct Needle: Sendable {
        /// The token as the rows and the failure messages spell it.
        let token: String
        /// The `NSRegularExpression` pattern that reads it.
        let pattern: String

        /// A whole identifier: no identifier character on either side, so `UIDeviceOrientation` is
        /// not `UIDevice` and `myHostName` is not `hostName`.
        static func identifier(_ name: String) -> Needle {
            Needle(token: name, pattern: #"(?<![A-Za-z0-9_])"# + name + #"(?![A-Za-z0-9_])"#)
        }

        /// A member read through its type, `Type.member`, with any space around the dot.
        static func dotted(_ type: String, _ member: String) -> Needle {
            Needle(token: type + "." + member,
                   pattern: #"(?<![A-Za-z0-9_])"# + type + #"\s*\.\s*"# + member + #"(?![A-Za-z0-9_])"#)
        }

        /// A call by its name and first argument label, `name(label:`.
        static func call(_ name: String, label: String) -> Needle {
            Needle(token: name + "(" + label + ":",
                   pattern: #"(?<![A-Za-z0-9_])"# + name + #"\s*\(\s*"# + label + #"\s*:"#)
        }
    }

    /// The modules any ProximityKit file may import or test for: exactly the set it imports outside the
    /// seams, each one available on iOS and macOS alike. `FernletCrypto` is the target's one package
    /// dependency (`ProximityNamespaceBoundaryTests.proximityKitDependencies`); no other Fernlet module
    /// is here, so an import of one fails this wall as well as the strict build.
    static let baselineModules: Set<String> = [
        "Foundation", "Combine", "Observation", "CryptoKit", "Security", "Network", "os", "Synchronization",
        "Dispatch", "Compression", "simd", "FernletCrypto"
    ]

    /// Every platform module a ProximityKit file imports, exactly, and both rows are permanent:
    /// `ProtectedSidecar`'s protected-data retry, which observes UIKit's protected-data notification and
    /// compiles out without it; and the NearbyInteraction provider, `NIRangingSession`, its whole file
    /// under `#if os(iOS)` since A0.6.3 (NearbyInteraction's module ships in the macOS SDK with every
    /// type it declares unavailable there, so `canImport` would not keep it out of a macOS build). No
    /// transient row is left: the coordinator's, the mesh manager's and the recipe-share manager's
    /// UIKit imports, which nothing in them used, left at A0.6.1, the local name's, which read
    /// `UIDevice`, at A0.6.2, and the Live Activity reaper's ActivityKit, with the reaper, which is the
    /// app's, at A0.6.4.
    static let seamRows: [SeamRow] = [
        SeamRow(path: "HeartSharing/ProtectedSidecar.swift", module: "UIKit",
                guarded: .partial("canImport(UIKit)"), exit: nil),
        SeamRow(path: "Ranging/NIRangingSession.swift", module: "NearbyInteraction",
                guarded: .wholeFile("os(iOS)"), exit: nil)
    ]

    /// Every source of the device's name within a module's reach: UIKit's `UIDevice`, Foundation's
    /// `Host.current`, `NSHost` and `hostName`, and its `NSFullUserName()` and `NSUserName()`, which on a
    /// Mac return the person's own full and short account names, and the BSD routes to the same two
    /// (`getlogin` and `getlogin_r`, `getpwuid` and `getpwuid_r`, and the account record's `pw_name` and
    /// `pw_gecos`, its short and full names); SystemConfiguration's and CoreServices' computer and
    /// local-host names, the BSD host-name calls (`utsname` stands for `uname`, which needs one, since a
    /// bare `uname` is a common variable name, and `KERN_HOSTNAME` for the `sysctl` that reads the host
    /// name by its MIB, since a bare `sysctl` reads any setting) and `localizedName`. On a Mac they lead to
    /// the user's own name or their name for the machine, its Computer Name or host name, which the recipe
    /// radio would put in an unauthenticated TXT record.
    static let deviceNameNeedles: [Needle] = [
        .identifier("UIDevice"), .dotted("Host", "current"), .identifier("NSHost"), .identifier("hostName"),
        .identifier("NSFullUserName"), .identifier("NSUserName"),
        .identifier("getlogin"), .identifier("getlogin_r"), .identifier("getpwuid"), .identifier("getpwuid_r"),
        .identifier("pw_name"), .identifier("pw_gecos"),
        .identifier("SCDynamicStoreCopyComputerName"), .identifier("SCDynamicStoreCopyLocalHostName"),
        .identifier("CSCopyMachineName"), .identifier("gethostname"), .identifier("sysctlbyname"),
        .identifier("utsname"), .identifier("nodename"), .identifier("KERN_HOSTNAME"), .identifier("localizedName")
    ]

    /// Every device-name read in ProximityKit, exactly: none since plan step A0.6.2, when the local
    /// name's fallback, which read `UIDevice`, became its host's `proximityFallbackDisplayName`.
    static let deviceNameRows: [TokenRow] = []

    /// Every Foundation API by which a module could name a platform directory: the `URL` and
    /// `FileManager` locations by name (the user's application, media and trash folders and the current
    /// directory among them), the three Foundation functions, the search-path call, an app-group or
    /// ubiquity container, and the lookups by a search-path directory by their first label (`FileManager`'s
    /// two and `URL`'s initializer). A path spelled in a literal is not code a lexed reader sees, since
    /// the lexer empties literals: the needles hold the APIs, not every string.
    static let directoryNeedles: [Needle] = [
        .identifier("applicationSupportDirectory"), .identifier("documentDirectory"),
        .identifier("documentsDirectory"), .identifier("cachesDirectory"), .identifier("libraryDirectory"),
        .identifier("temporaryDirectory"), .identifier("NSTemporaryDirectory"), .identifier("NSHomeDirectory"),
        .identifier("NSHomeDirectoryForUser"), .identifier("homeDirectory"), .identifier("homeDirectoryForCurrentUser"),
        .identifier("NSSearchPathForDirectoriesInDomains"), .identifier("downloadsDirectory"),
        .identifier("desktopDirectory"), .identifier("sharedPublicDirectory"), .identifier("applicationDirectory"),
        .identifier("userDirectory"), .identifier("moviesDirectory"), .identifier("musicDirectory"),
        .identifier("picturesDirectory"), .identifier("trashDirectory"), .identifier("currentDirectory"),
        .identifier("currentDirectoryPath"), .identifier("containerURL"),
        .call("url", label: "forUbiquityContainerIdentifier"), .call("urls", label: "for"), .call("url", label: "for"),
        .call("URL", label: "for")
    ]

    /// Every platform directory ProximityKit names, exactly: none since plan step A0.6.6, when the
    /// namespace's default root under Application Support became `directory(under:)`, its folder under
    /// a base its host picks.
    static let directoryRows: [TokenRow] = []

    /// The facts only a host may state, which no `ProximityHost` extension in ProximityKit may default:
    /// the requirements `ProximityHost.swift` says are never defaulted (the namespace, the install
    /// binding, the trust policy, the identity, the routed rows and, since plan steps A0.6.2, A0.6.3 and
    /// A0.6.6, the fallback name, the ranging provider and the storage root).
    static let hostFacts: Set<String> = [
        "proximityNamespace", "proximityInstallBinding", "makeProximityTrustPolicy", "makeProximityIdentity",
        "meshRoutedTypeEntries", "proximityFallbackDisplayName", "makeProximityRangingProvider",
        "proximitySupportDirectory"
    ]

    /// Every host fact ProximityKit still defaults, exactly: none since plan step A0.6.6, when the
    /// host extension's default storage root, computed from the namespace, was deleted. The extension
    /// still defaults the two storage scopes, which are no host fact: they are built on the root the
    /// host states.
    static let hostFactDefaultRows: [TokenRow] = []

    // MARK: W1: the imports

    /// **W1.** Every module a ProximityKit file imports or tests for with `canImport` is a baseline
    /// module or an exact seam row, and every seam row's file still imports its module; a guarded row's
    /// imports sit in its `#if` branch and never its `#else`, and a whole-file row's file is that one
    /// `#if` from its first code line to its last. A platform framework enters ProximityKit only as a
    /// row with its guard and, unless it is a permanent mechanism seam, the step that removes it. And
    /// no `#if` or `#elseif` names `os(…)` but a seam row's own guard in that row's file, so no branch
    /// holds a platform answer the iOS run never executes and the macOS build compiles.
    @Test func proximityKitImportsOnlyNeutralModulesAndItsDeclaredSeams() throws {
        let sources = try ProximityNamespaceBoundaryTests.proximitySources()
        #expect(sources.count >= Self.minimumFilesWalked, "walked only \(sources.count) ProximityKit files")
        var named: Set<String> = []
        var imported: Set<String> = []
        var branches: Set<String> = []
        // R2: bounded by the module's files.
        for source in sources {
            let uses = try Self.moduleUses(in: source.lexed.code).filter { !Self.baselineModules.contains($0.module) }
            named.formUnion(uses.map { Self.key(source.path, $0.module) })
            imported.formUnion(uses.filter(\.isImport).map { Self.key(source.path, $0.module) })
            branches.formUnion(try Self.platformConditions(in: source.lexed.code).map { Self.key(source.path, $0) })
            Self.expectPlacement(of: uses, in: source)
        }
        let unlisted = named.subtracting(Self.seamRows.map { Self.key($0.path, $0.module) }).sorted()
        #expect(unlisted.isEmpty, """
            ProximityKit names a module that is neither a neutral baseline module nor a declared seam: \
            \(unlisted). A platform framework enters ProximityKit only as a seam row, with its guard and \
            the plan step that removes it
            """)
        let guards = Set(Self.seamRows.compactMap { row in row.guarded.condition.map { Self.key(row.path, $0) } })
        let unguarded = branches.subtracting(guards).sorted()
        #expect(unguarded.isEmpty, """
            ProximityKit branches on the platform outside a seam row's own guard: \(unguarded). A platform \
            branch is policy the iOS run never executes and the macOS build compiles: the host states the \
            fact, and a mechanism that needs a platform guard is a seam row
            """)
        // R2: bounded by the rows.
        for row in Self.seamRows where !imported.contains(Self.key(row.path, row.module)) {
            Issue.record("""
                \(row.path) no longer imports \(row.module): delete its seam row in the same commit \
                (\(Self.exitText(row.exit)))
                """)
        }
    }

    /// Holds every import of a guarded row's module in `source` to its row's `#if` branch, and a
    /// whole-file row's file to its one `#if`.
    static func expectPlacement(of uses: [ModuleUse], in source: Source) {
        // R2: bounded by the rows.
        for row in seamRows where row.path == source.path {
            let condition: String
            switch row.guarded {
            case .unguarded:
                continue
            case .partial(let text):
                condition = text
            case .wholeFile(let text):
                condition = text
                #expect(isWholeFile(source.lexed.code, guardedBy: text),
                        "\(row.path) is no longer `#if \(text)` from its first code line to its last")
            }
            let misplaced = misplacedImports(of: row.module, under: condition, in: uses)
            #expect(misplaced.isEmpty, """
                \(row.path) imports \(row.module) outside `#if \(condition)` (after its `#else`, or under \
                another condition or none) on line(s) \(misplaced)
                """)
        }
    }

    /// The lines on which `uses` imports `module` anywhere but in the branch of `#if <condition>`.
    static func misplacedImports(of module: String, under condition: String, in uses: [ModuleUse]) -> [Int] {
        uses.filter { $0.isImport && $0.module == module }
            .filter { $0.region.condition != condition || $0.region.afterElse }
            .map(\.line)
    }

    // MARK: W2: the device's name

    /// **W2.** No ProximityKit file reads the device's name, or its user's, but on ``deviceNameRows``:
    /// what an unnamed device is called is its host's fact. Both directions: a row whose file no longer
    /// names its token fails until the row is deleted.
    @Test func proximityKitReadsNoDeviceName() throws {
        let sources = try ProximityNamespaceBoundaryTests.proximitySources()
        #expect(sources.count >= Self.minimumFilesWalked, "walked only \(sources.count) ProximityKit files")
        let found = try Self.tokenUses(of: Self.deviceNameNeedles, in: sources)
        Self.expectExactly(Self.deviceNameRows, found: found, refusing: "a device-name source")
    }

    // MARK: W3: directories and host facts

    /// **W3.** No ProximityKit file computes a platform directory but on ``directoryRows``: where an
    /// installation keeps its files is its host's fact. And no `ProximityHost` extension declares a
    /// default for one of ``hostFacts`` but on ``hostFactDefaultRows``: a default would be the module's
    /// policy for every host, which a host could not override without a second seam. The extension
    /// reader must see at least the two extensions the module holds (`ProximityHost.swift`'s defaults
    /// and `PeerDisplayNames.swift`'s local name), so a broken reader cannot pass on an empty read.
    @Test func proximityKitComputesNoDirectoryAndDefaultsNoHostFact() throws {
        let sources = try ProximityNamespaceBoundaryTests.proximitySources()
        #expect(sources.count >= Self.minimumFilesWalked, "walked only \(sources.count) ProximityKit files")
        let directories = try Self.tokenUses(of: Self.directoryNeedles, in: sources)
        Self.expectExactly(Self.directoryRows, found: directories, refusing: "a platform directory")
        var defaults: Set<String> = []
        var bodies = 0
        // R2: bounded by the module's files.
        for source in sources {
            bodies += try Self.hostExtensionBodies(in: source.lexed.code).count
            let declared = try Self.hostExtensionDeclarations(in: source.lexed.code)
            defaults.formUnion(declared.filter(Self.hostFacts.contains).map { Self.key(source.path, $0) })
        }
        #expect(bodies >= 2, "read only \(bodies) `ProximityHost` extension bodies; the reader is broken")
        Self.expectExactly(Self.hostFactDefaultRows, found: defaults, refusing: "a default for a host fact")
    }

    // MARK: W4: the readers, fixtured

    /// **W4.** The readers read code as Swift does, both ways: an import in each of its forms (an
    /// attribute with arguments before it, and a second import after a `;`, included), a `canImport`
    /// condition and its `#if` region, a platform branch's condition, each W2 and W3 token, and a
    /// declaration at a `ProximityHost` extension's top level are read; the same text in a comment or a
    /// string literal, a line after `#else` as inside the guard, a name that only starts with `import`,
    /// a condition that names no `os(…)`, a longer name holding a token, a name an extension only reads,
    /// and a protocol's requirement are not. A whole-file guard is told from a partial one.
    @Test func theReadersReadCodeAsSwiftDoes() throws {
        try Self.expectModuleReadersFixtured()
        Self.expectWholeFileReaderFixtured()
        try Self.expectPlatformBranchReaderFixtured()
        try Self.expectTokenReadersFixtured()
        try Self.expectDeclarationReaderFixtured()
    }

    /// The module reader: each import form and a `canImport` condition read, with the regions they sit
    /// in; nothing read from a comment or a literal, nor from a name that only starts with `import`; an
    /// import after `#else` outside the guard.
    static func expectModuleReadersFixtured() throws {
        let forms = try moduleUses(in: lexedCode("""
            import UIKit
            @preconcurrency import UIKit
            import struct Foundation.URL
            import Foundation; import ActivityKit
            @_spi(Private) import NearbyInteraction
            @_spi(Private)import CoreServices
            #if canImport(UIKit)
            #endif
            """))
        #expect(forms.map(\.module) == ["UIKit", "UIKit", "Foundation", "Foundation", "ActivityKit", "NearbyInteraction",
                                        "CoreServices", "UIKit"], "read \(forms.map(\.module))")
        #expect(forms.map(\.isImport) == [true, true, true, true, true, true, true, false],
                "told imports from conditions as \(forms)")
        let prose = try moduleUses(in: lexedCode("""
            // import UIKit
            let a = "import UIKit"
            /* #if canImport(UIKit) */
            let b = "canImport(UIKit)"
            let c = "x; import UIKit"; importantThing()
            """))
        #expect(prose.isEmpty, "a comment, a literal or a longer name was read as code: \(prose)")
        let branches = try moduleUses(in: lexedCode("""
            #if canImport(UIKit)
            import UIKit
            #else
            import UIKit
            #endif
            import os
            """))
        let guarded = Region(condition: "canImport(UIKit)", afterElse: false)
        #expect(branches == [
            ModuleUse(line: 1, module: "UIKit", isImport: false, region: guarded),
            ModuleUse(line: 2, module: "UIKit", isImport: true, region: guarded),
            ModuleUse(line: 4, module: "UIKit", isImport: true, region: Region(condition: "canImport(UIKit)", afterElse: true)),
            ModuleUse(line: 6, module: "os", isImport: true, region: Region(condition: nil, afterElse: false))
        ], "read the regions as \(branches)")
        #expect(misplacedImports(of: "UIKit", under: "canImport(UIKit)", in: branches) == [4],
                "an import after `#else` is outside the guard")
        #expect(misplacedImports(of: "UIKit", under: "os(iOS)", in: branches) == [2, 4],
                "an import under another condition is outside this guard")
    }

    /// The whole-file reader: one `#if` from the first code line to the last is whole; a file with code
    /// outside it, a second `#if` or another condition is not.
    static func expectWholeFileReaderFixtured() {
        let whole = lexedCode("// NIRangingSession.swift\n#if os(iOS)\nimport NearbyInteraction\nfinal class A {}\n#endif\n")
        let partial = lexedCode("import Foundation\n#if os(iOS)\nimport NearbyInteraction\n#endif\nfinal class B {}\n")
        let twice = lexedCode("#if os(iOS)\nimport NearbyInteraction\n#endif\n#if DEBUG\nlet c = 1\n#endif\n")
        #expect(isWholeFile(whole, guardedBy: "os(iOS)"), "a file under one `#if` from end to end is whole")
        #expect(!isWholeFile(partial, guardedBy: "os(iOS)"), "a file with code outside its `#if` is partial")
        #expect(!isWholeFile(twice, guardedBy: "os(iOS)"), "a file with a second `#if` is not one guard")
        #expect(!isWholeFile(whole, guardedBy: "canImport(NearbyInteraction)"), "another condition is not this guard")
    }

    /// The platform-branch reader: an `#if` or `#elseif` that names `os(…)`, alone, negated or combined,
    /// is read with its condition as written; a `DEBUG`, `canImport` or `targetEnvironment` condition,
    /// an `os` that no directive tests, and a directive in a comment or a literal are not.
    static func expectPlatformBranchReaderFixtured() throws {
        let read = try platformConditions(in: lexedCode("""
            #if os(iOS)
            #elseif !os(macOS) && canImport(UIKit)
            #endif
            #if DEBUG
            #elseif canImport(UIKit)
            #endif
            #if targetEnvironment(simulator)
            #endif
            let os = Logger(); _ = os(1)
            // #if os(macOS)
            let text = "#if os(macOS)"
            """))
        #expect(read == ["os(iOS)", "!os(macOS) && canImport(UIKit)"], "read the platform branches as \(read)")
    }

    /// The token readers: each W2 and W3 token read once in `_ = <token>` beside the same text in a
    /// comment and a literal, and none read inside a longer name.
    static func expectTokenReadersFixtured() throws {
        // R2: bounded by the needles.
        for needle in deviceNameNeedles + directoryNeedles {
            let code = lexedCode("_ = \(needle.token)\n// _ = \(needle.token)\nlet quoted = \"\(needle.token)\"\n")
            let read = try mentions(of: needle, in: code)
            #expect(read == 1, "`\(needle.token)` is read \(read) times in code, a comment and a literal")
        }
        let neighbours = lexedCode("_ = UIDeviceOrientation.portrait\nlet myHostName = 1\n_ = HostName.current\n")
        #expect(try mentions(of: .identifier("UIDevice"), in: neighbours) == 0, "UIDeviceOrientation read as UIDevice")
        #expect(try mentions(of: .identifier("hostName"), in: neighbours) == 0, "myHostName read as hostName")
        #expect(try mentions(of: .dotted("Host", "current"), in: neighbours) == 0, "HostName.current read as Host.current")
        let lookup = lexedCode("_ = FileManager.default.urls(for: .cachesDirectory, in: mask)\n")
        #expect(try mentions(of: .call("url", label: "for"), in: lookup) == 0, "urls(for: read as url(for:")
        #expect(try mentions(of: .call("URL", label: "for"), in: lookup) == 0, "urls(for: read as URL(for:")
        #expect(try mentions(of: .call("urls", label: "for"), in: lookup) == 1, "urls(for: was not read")
        let ubiquity = lexedCode("_ = FileManager.default.url(forUbiquityContainerIdentifier: nil)\n")
        #expect(try mentions(of: .call("url", label: "for"), in: ubiquity) == 0,
                "url(forUbiquityContainerIdentifier: read as url(for:")
    }

    /// The declaration reader: the names declared at a `ProximityHost` extension's top level, a body
    /// with nested braces included; a name the body only reads, a protocol's requirement, a comment and
    /// a literal are not declarations.
    static func expectDeclarationReaderFixtured() throws {
        let declared = try hostExtensionDeclarations(in: lexedCode("""
            public protocol ProximityHost: AnyObject {
                var proximitySupportDirectory: URL { get }
            }
            public extension ProximityHost {
                var proximitySupportDirectory: URL { if flag { return base }; return other }
                func makeProximityRangingProvider() -> any RangingProvider { NoopRangingProvider() }
                var resolved: String {
                    let namespace = proximityNamespace
                    return name.isEmpty ? proximityFallbackDisplayName : name
                }
            }
            """))
        #expect(declared == ["proximitySupportDirectory", "makeProximityRangingProvider", "resolved"],
                "read the declarations as \(declared)")
        let reads = try hostExtensionDeclarations(in: lexedCode("""
            extension ProximityHost {
                let namespace = proximityNamespace
                name.isEmpty ? proximityFallbackDisplayName : name
            }
            // extension ProximityHost { var proximityNamespace: ProximityNamespace { .fernlet } }
            let text = "extension ProximityHost { func makeProximityIdentity() }"
            """))
        #expect(reads == ["namespace"], "a read, a comment or a literal was read as a declaration: \(reads)")
        #expect(try hostExtensionBodies(in: lexedCode("protocol ProximityHost { var a: Int { get } }")).isEmpty,
                "a protocol's body was read as an extension's")
    }

    // MARK: W5: the doors' ranging

    /// One channel-ready door: its file and the declaration its brace-matched body follows.
    struct Door: Sendable {
        /// The file, by its path under the repository root.
        let path: String
        /// The declaration prefix the door's body follows, unique in its file.
        let signature: String
    }

    /// The three doors that build one connection's coordinator: the mesh's and the pair session's in
    /// ProximityKit, and presence's heart door in FernletSocial, which is Fernlet's half and stays with
    /// Fernlet's walls when ProximityKit leaves the tree.
    static let channelReadyDoors = [
        Door(path: "FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift",
             signature: "private func handleChannelReady("),
        Door(path: "FernletKit/Sources/ProximityKit/RecipeSharing/ProximityPairSession.swift",
             signature: "private func handleChannelReady("),
        Door(path: "FernletKit/Sources/FernletSocial/Presence/PresenceManager.swift",
             signature: "private func handleHeartChannelReady(")
    ]

    /// The argument each door builds its coordinator's provider with: its host's answer, asked once per
    /// connection.
    static let hostRangingArgument = "ranging: store.makeProximityRangingProvider()"

    /// The providers no door may name: a door that builds one has made its host's decision for it.
    static let doorProviderNeedles: [Needle] = [
        .identifier("NIRangingSession"), .identifier("NoopRangingProvider"), .identifier("MockRangingProvider")
    ]

    /// **W5.** Every channel-ready door asks its host for each connection's ranging provider: each door's
    /// brace-matched body (comments dropped, literals emptied) passes ``hostRangingArgument`` exactly
    /// once and names none of ``doorProviderNeedles``, and `NIRangingSession` is named in ProximityKit
    /// code only in its own file. Whether a connection ranges is its host's decision (a host on macOS
    /// cannot build NearbyInteraction's types at all, and one may want no ranging), so a door, or any
    /// other ProximityKit file, that builds the NearbyInteraction provider itself takes that decision
    /// back from every host.
    @Test func everyChannelReadyDoorAsksItsHostForRanging() throws {
        // R2: bounded by the three doors.
        for door in Self.channelReadyDoors {
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
        let sources = try ProximityNamespaceBoundaryTests.proximitySources()
        #expect(sources.count >= Self.minimumFilesWalked, "walked only \(sources.count) ProximityKit files")
        let named = try Self.tokenUses(of: [.identifier("NIRangingSession")], in: sources)
        let home = Self.key("Ranging/NIRangingSession.swift", "NIRangingSession")
        #expect(named == [home], """
            `NIRangingSession` is named in ProximityKit code at \(named.sorted()), not only in its own file: \
            a connection's provider is its host's to build
            """)
    }

    // MARK: W6: the Mac build, on every push

    /// The package manifest, whose platforms and products W6 reads.
    static let manifestPath = "FernletKit/Package.swift"

    /// The manifest's platforms, exactly: iOS 26 and, since plan step A0.6.5, native macOS 26.
    static let manifestPlatforms: Set<String> = [".iOS(.v26)", ".macOS(.v26)"]

    /// ProximityKit's own product, the one the package exports from its own repository at plan step A1.
    static let proximityKitProduct = #".library(name: "ProximityKit", targets: ["ProximityKit"])"#

    /// The product the macOS check builds, its four modules named, so none of them leaves the Mac build
    /// unseen: ProximityKit, and FernletFoundation, FernletCrypto and FernletDomainModel, which a Mac
    /// host of Fernlet's needs and which ProximityKit's dependencies no longer reach (plan step A1.0).
    static let macReadyProduct =
        #".library(name: "MacReady", targets: ["ProximityKit", "FernletFoundation", "FernletCrypto", "FernletDomainModel"])"#

    /// The CI workflow step that runs the macOS self-test, by its `- name:`.
    static let macOSStepName = "ProximityKit on native macOS (Scripts/macos-build-selftest.sh)"

    /// The one line the macOS step's body runs.
    static let macOSStepRun = "Scripts/macos-build-selftest.sh"

    /// Where the self-test plants its probe: inside ProximityKit, so only a native macOS build fails on it.
    static let selfTestProbePath = "FernletKit/Sources/ProximityKit/__MacOSBuildSelfTestProbe.swift"

    /// The self-test's negative leg: the check run over the probe, its output kept for the grep.
    static let selfTestCapture = #""$(Scripts/macos-build-check.sh 2>&1)""#

    /// The failure only a native macOS build gives the probe's `import UIKit`: the explicit-module
    /// dependency scan's wording for a module the platform lacks. xcodebuild never prints the SwiftPM
    /// command line's "no such module", so the self-test greps this, case-insensitively.
    static let macOSOnlyFailure = "unable to resolve module dependency: 'UIKit'"

    /// The check, whose one `xcodebuild build` command W6 and rule 10's pin read.
    static let checkScriptPath = "Scripts/macos-build-check.sh"

    /// What the check's command carries so that it builds the `MacReady` product's four modules, for
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

    /// Paths the macOS leg must find relevant: the manifest and a ProximityKit source.
    static let hookRelevantPaths = [manifestPath, "FernletKit/Sources/ProximityKit/Engine/ProximityCoordinator.swift"]

    /// **W6.** ProximityKit's macOS build is a compiled fact on every push, each piece read from what
    /// RUNS, never from a step's title, an `echo` or a comment, any of which can name a script nothing
    /// runs: the manifest declares exactly iOS 26 and macOS 26, ProximityKit's own product and the
    /// `MacReady` product with its four modules, each line once; the
    /// workflow runs on every push and every pull request to `main`, its `on:` block filtering neither by
    /// path nor by branch, and declares its macOS step once, with no `if:` or `continue-on-error:` on the
    /// step or on its job (either keeps a declared step from running or from failing the run), and that
    /// step's body runs the self-test right after its preamble (``stepPreamble``), with no other line
    /// before it to exit, guard it or continue onto it; the self-test plants its probe in
    /// ProximityKit, captures the check, greps the failure only a native macOS build gives, and runs the
    /// check again on the clean tree; the check holds one `xcodebuild build` command, for the
    /// `MacReady` product, native macOS, its own derived data and the dependency flag; and the pre-push
    /// hook runs the check, its leg on by default and relevant to a change of the manifest or a
    /// ProximityKit source. Its
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
        // R2: bounded by the two pinned products.
        for product in [Self.proximityKitProduct, Self.macReadyProduct] {
            let declared = manifestLines.count(where: { $0 == product })
            #expect(declared == 1, "\(Self.manifestPath) declares `\(product)` \(declared) times")
        }
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
    /// ProximityKit source runs; a leg off by default, a pattern that misses the manifest, and a pattern
    /// only a comment assigns do not.
    static func expectHookLegReaderFixtured() {
        let pattern = #"'^(FernletKit/Package\.swift|FernletKit/Sources/ProximityKit/)'"#
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

    /// The `#if` region a line sits in: the condition of the `#if` that opened it, and whether an
    /// `#elseif` or `#else` has moved past that condition. Outside every region the condition is nil.
    struct Region: Sendable, Equatable {
        /// The opening `#if`'s condition, as written; nil outside every region.
        let condition: String?
        /// Whether the line is past the region's `#elseif` or `#else`, so outside its condition.
        let afterElse: Bool
    }

    /// One module a file names: an `import` declaration or a `canImport(…)` condition, with the region
    /// it sits in.
    struct ModuleUse: Sendable, Equatable {
        /// The 1-based line.
        let line: Int
        /// The module, the first component of an import's path.
        let module: String
        /// Whether it is an `import` declaration rather than a `canImport` condition.
        let isImport: Bool
        /// The `#if` region in force on that line, the condition's own `#if` line included.
        let region: Region
    }

    /// Every module `code` names: each `import` declaration, at a line's start or after a `;` (any
    /// attributes, an argument list such as `@_spi(S)`'s among them, access level or kind before the
    /// path, its first component read), and each `canImport(…)` condition, with its region. Regions are
    /// read flat, since Power of 10's R8 forbids nesting: an `#if` opens one with its condition's text,
    /// an `#elseif` or `#else` moves past it, and `#endif` closes it.
    static func moduleUses(in code: String) throws -> [ModuleUse] {
        let declaration = try NSRegularExpression(
            pattern: #"(?:^|;)\s*(?:@\w+(?:\([^)]*\)\s*|\s+))*(?:(?:public|package|internal|fileprivate|private)\s+)?"#
                + #"import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?(\w+)"#)
        let condition = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])canImport\s*\(\s*(\w+)"#)
        var uses: [ModuleUse] = []
        var region = Region(condition: nil, afterElse: false)
        // R2: bounded by the file's line count.
        for (offset, line) in code.components(separatedBy: "\n").enumerated() {
            region = nextRegion(after: line, from: region)
            let here = region
            uses += captures(of: condition, in: line).map {
                ModuleUse(line: offset + 1, module: $0, isImport: false, region: here)
            }
            uses += captures(of: declaration, in: line).map {
                ModuleUse(line: offset + 1, module: $0, isImport: true, region: here)
            }
        }
        return uses
    }

    /// The region in force from `line` on, given the one before it.
    static func nextRegion(after line: String, from region: Region) -> Region {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        switch directive(of: trimmed) {
        case "if":
            return Region(condition: String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces),
                          afterElse: false)
        case "elseif", "else":
            return Region(condition: region.condition, afterElse: true)
        case "endif":
            return Region(condition: nil, afterElse: false)
        default:
            return region
        }
    }

    /// The conditional-compilation directive `line` opens with (`if`, `elseif`, `else` or `endif`), or
    /// nil for any other line.
    static func directive(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let word = String(trimmed.dropFirst().prefix { $0.isLetter })
        return ["if", "elseif", "else", "endif"].contains(word) ? word : nil
    }

    /// Every `#if` or `#elseif` condition in `code` that tests the platform with `os(…)`, as written
    /// after its directive, in order.
    static func platformConditions(in code: String) throws -> [String] {
        let platform = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])os\s*\("#)
        var conditions: [String] = []
        // R2: bounded by the file's line count.
        for line in code.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let word = directive(of: trimmed), word == "if" || word == "elseif" else { continue }
            let condition = String(trimmed.dropFirst(word.count + 1)).trimmingCharacters(in: .whitespaces)
            if platform.firstMatch(in: condition, range: NSRange(condition.startIndex..., in: condition)) != nil {
                conditions.append(condition)
            }
        }
        return conditions
    }

    /// Whether `code`'s first code line is `#if <condition>`, its last is `#endif`, and it holds no
    /// other directive: the whole file compiled under that one condition.
    static func isWholeFile(_ code: String, guardedBy condition: String) -> Bool {
        let lines = code.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let directives = lines.filter { directive(of: $0) != nil }
        return lines.first == "#if " + condition && lines.last == "#endif" && directives.count == 2
    }

    /// How many times `needle` is read in `code`.
    static func mentions(of needle: Needle, in code: String) throws -> Int {
        let regex = try NSRegularExpression(pattern: needle.pattern)
        return regex.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }

    /// Every file-and-token key (``key(_:_:)``) for which a needle is read at least once in a file.
    static func tokenUses(of needles: [Needle], in sources: [Source]) throws -> Set<String> {
        var found: Set<String> = []
        // R2: bounded by the module's files × the needles.
        for source in sources {
            for needle in needles {
                guard try mentions(of: needle, in: source.lexed.code) > 0 else { continue }
                found.insert(key(source.path, needle.token))
            }
        }
        return found
    }

    /// The names declared directly in each `ProximityHost` extension body in `code`: a `var`, `let` or
    /// `func` at the body's top level. A name the body only reads, or declares inside a member, is not
    /// one; a protocol's body is not an extension's and is not read.
    static func hostExtensionDeclarations(in code: String) throws -> [String] {
        let declaration = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])(?:var|let|func)\s+([A-Za-z_]\w*)"#)
        var names: [String] = []
        // R2: bounded by the extensions in one file.
        for body in try hostExtensionBodies(in: code) {
            names += captures(of: declaration, in: body)
        }
        return names
    }

    /// The top-level text of each `ProximityHost` extension's body in `code`, `public` or not: what lies
    /// directly inside its braces, every nested brace pair's contents left out.
    static func hostExtensionBodies(in code: String) throws -> [String] {
        let opener = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])extension\s+(?:ProximityKit\s*\.\s*)?ProximityHost(?![A-Za-z0-9_])"#)
        let matches = opener.matches(in: code, range: NSRange(code.startIndex..., in: code))
        return matches.compactMap { match in
            Range(match.range, in: code).flatMap { topLevelText(ofBodyFrom: $0.upperBound, in: code) }
        }
    }

    /// The text directly inside the first brace pair that opens at or after `start`, its nested pairs'
    /// contents left out; nil when there is none or it never closes.
    static func topLevelText(ofBodyFrom start: String.Index, in code: String) -> String? {
        guard let open = code[start...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var text = ""
        var index = open
        // R2: bounded by the remaining characters of a finite string.
        while index < code.endIndex {
            let character = code[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return text }
            } else if depth == 1 {
                text.append(character)
            }
            index = code.index(after: index)
        }
        return nil
    }

    /// The first capture group of every match of `regex` in `text`.
    static func captures(of regex: NSRegularExpression, in text: String) -> [String] {
        let string = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: string.length)).map {
            string.substring(with: $0.range(at: 1))
        }
    }

    /// Records each key in `found` that no row lists, and each row whose key `found` lacks: the rule is
    /// exact both ways.
    static func expectExactly(_ rows: [TokenRow], found: Set<String>, refusing what: String) {
        let unlisted = found.subtracting(rows.map { key($0.path, $0.token) }).sorted()
        #expect(unlisted.isEmpty, """
            ProximityKit names \(what) outside its rows: \(unlisted). The host states this fact; a \
            platform answer in the module is policy no host can override
            """)
        // R2: bounded by the rows.
        for row in rows where !found.contains(key(row.path, row.token)) {
            Issue.record("""
                \(row.path) no longer names \(row.token): delete its row in the same commit \
                (\(exitText(row.exit)))
                """)
        }
    }

    /// The key a file's use of a module or token is compared by.
    static func key(_ path: String, _ token: String) -> String {
        path + " names " + token
    }

    /// A row's exit, as a failure message says it: every row is permanent since plan step A0.6.6, when
    /// ``ExitStep``'s last case left with its rows. A step that adds a transient row adds the arm that
    /// names its step ("a row plan step <step> deletes").
    static func exitText(_ exit: ExitStep?) -> String {
        switch exit {
        case .none:
            return "a permanent row"
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

    /// Whether the hook's macOS leg runs by default and finds a ProximityKit change relevant: the hook's
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
    /// in ProximityKit and its `import UIKit`; the negative leg's capture of the check and its grep for
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
