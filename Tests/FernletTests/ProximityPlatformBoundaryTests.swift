// ProximityPlatformBoundaryTests.swift
// FernletTests
//
// The wall that keeps ProximityKit free of platform policy (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md
// §4 A0.6, Mac readiness). ProximityKit is to build for iOS 26 and native macOS 26 and to compute no
// value whose right answer differs by platform or by app: what an unnamed device is called, whether a
// connection ranges and where an installation keeps its files are its host's to state, and the module
// keeps only the mechanism seams a platform needs, each compiled only where its framework is usable.
// The iOS compiler does not keep it that way: a UIKit, NearbyInteraction or ActivityKit import, a read
// of the device's name, a platform directory and a default for a fact only the host may state all
// compile clean on iOS and pass every other test. So this suite reads ProximityKit's source through
// `ProximityNamespaceBoundaryTests`' one walker (lexed: comments dropped, literals emptied) and holds
// four rules, its readers fixtured both ways in a cell of their own:
//
//   1. every module a file imports (`import M`, `@preconcurrency import M`, `import struct M.X`) or
//      tests for with `canImport(M)` is a neutral baseline module, available on both platforms, or an
//      exact seam row: a file, a module, how its imports are guarded and the plan step that deletes
//      the row. A guarded seam's every import sits in its `#if` branch, never in its `#else`; a
//      whole-file seam's file opens with its `#if` and closes with its `#endif`, and holds no other
//      `#if`;
//   2. no file names a source of the device's name (`UIDevice`, `Host.current`, `NSHost`, `hostName`,
//      the SystemConfiguration, CoreServices and BSD calls, `localizedName`), but on the rows listed;
//   3. no file names a platform directory (Application Support, Documents, Caches, Library, the
//      temporary and home directories, a search-path call, a container), but on the rows listed, and
//      no `ProximityHost` extension declares a default for a fact only the host may state (its
//      namespace, install binding, trust policy, identity, routed rows, fallback name, ranging
//      provider and storage root), read as declarations at the extension's top level, never as names;
//   4. every channel-ready door that builds a connection's coordinator (the mesh's and the recipe
//      radio's here, and presence's heart door in FernletSocial, Fernlet's half) builds it over its
//      host's `makeProximityRangingProvider()`, once, naming no provider of its own, and
//      `NIRangingSession` is named in ProximityKit code only in its own file.
//
// The first three rules are ratchets both ways. A new use fails; a use that goes away fails too, until
// its row is deleted. Each transient row names the plan step that deletes it, and later steps only
// delete rows, so the wall ends with its permanent rows: `ProtectedSidecar.swift`'s guarded UIKit
// import (the protected-data retry, compiled only where UIKit is) and the NearbyInteraction provider's
// file, guarded whole by `#if os(iOS)` since plan step A0.6.3. Today's rows are 3 seams (those 2
// permanent, and 1 transient: the Live Activity reaper's ActivityKit), no device-name row, 1 directory
// row (the namespace's Application Support default) and 1 host-fact default (the extension's storage
// root). The coordinator's, the mesh manager's and the recipe-share manager's vestigial UIKit imports
// left at plan step A0.6.1, and the local name's UIKit import and its `UIDevice` read at A0.6.2, when
// the host began stating the fallback name; at A0.6.3, when the doors began asking their host for each
// connection's ranging provider, the NearbyInteraction provider's file was guarded whole. Until
// ProximityKit builds for macOS on every push, this scan is the only thing that sees a platform fact
// enter it.
//
// It never spells the vendor-identifier symbol: `NoTrackingBoundaryTests` bans that spelling
// everywhere, comments included.

import Foundation
import Testing

/// ProximityKit imports only neutral modules and its declared platform seams, reads no device name,
/// computes no platform directory and defaults no fact only its host may state, and every channel-ready
/// door asks its host for each connection's ranging provider: five cells, the first three rules ratchets
/// whose transient rows name the plan step that deletes them, and their readers fixtured both ways.
@Suite struct ProximityPlatformBoundaryTests {

    /// One ProximityKit file: its path under the module root and its lexed source, as
    /// `ProximityNamespaceBoundaryTests.proximitySources()` yields it.
    typealias Source = (path: String, lexed: SwiftSourceLexer.Lexed)

    /// Fewer files than this and the walk is broken, not the module clean: ProximityKit holds 134 Swift
    /// files at plan step A0.6.0.
    static let minimumFilesWalked = 120

    // MARK: The rows

    /// The plan step that takes a platform fact out of ProximityKit. A step's case is deleted with its
    /// last row, as A0.6.1's (the vestigial UIKit imports), A0.6.2's (the local name's `UIDevice` read
    /// and its file's `import UIKit`) and A0.6.3's (the NearbyInteraction provider's unguarded import,
    /// whose row became the permanent whole-file seam) were.
    enum ExitStep: String, Sendable {
        /// The Live Activity reaper is the app's (A0.6.4): ActivityKit leaves with it.
        case a064 = "A0.6.4"
        /// The storage root always comes from the host (A0.6.6): the namespace's Application Support
        /// default and the host extension's default root.
        case a066 = "A0.6.6"
    }

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

    /// The modules any ProximityKit file may import or test for: today's exact set outside the seams,
    /// each one available on iOS and macOS alike. `FernletCrypto` and `FernletDomainModel` are the
    /// target's two package dependencies (`ProximityNamespaceBoundaryTests.proximityKitDependencies`).
    static let baselineModules: Set<String> = [
        "Foundation", "Combine", "Observation", "CryptoKit", "Security", "Network", "os", "Synchronization",
        "Dispatch", "Compression", "simd", "FernletCrypto", "FernletDomainModel"
    ]

    /// Every platform module a ProximityKit file imports, exactly. Permanent: `ProtectedSidecar`'s
    /// protected-data retry, which observes UIKit's protected-data notification and compiles out without
    /// it; and the NearbyInteraction provider, `NIRangingSession`, its whole file under `#if os(iOS)`
    /// since A0.6.3 (NearbyInteraction's module ships in the macOS SDK with every type it declares
    /// unavailable there, so `canImport` would not keep it out of a macOS build). Transient: the Live
    /// Activity reaper's ActivityKit (A0.6.4). The coordinator's, the mesh manager's and the
    /// recipe-share manager's UIKit imports, which nothing in them used, left at A0.6.1, and the local
    /// name's, which read `UIDevice`, at A0.6.2.
    static let seamRows: [SeamRow] = [
        SeamRow(path: "HeartSharing/ProtectedSidecar.swift", module: "UIKit",
                guarded: .partial("canImport(UIKit)"), exit: nil),
        SeamRow(path: "Ranging/NIRangingSession.swift", module: "NearbyInteraction",
                guarded: .wholeFile("os(iOS)"), exit: nil),
        SeamRow(path: "ForegroundAnchor/ProximityForegroundAnchor.swift", module: "ActivityKit",
                guarded: .partial("canImport(ActivityKit)"), exit: .a064)
    ]

    /// Every source of the device's name within a module's reach: UIKit's `UIDevice`, Foundation's
    /// `Host.current`, `NSHost` and `hostName`, SystemConfiguration's and CoreServices' computer and
    /// local-host names, the BSD calls (`utsname` stands for `uname`, which needs one, since a bare
    /// `uname` is a common variable name) and `localizedName`. On a Mac they lead to the user's own name
    /// for the machine, its Computer Name or host name, which the recipe radio would put in an
    /// unauthenticated TXT record.
    static let deviceNameNeedles: [Needle] = [
        .identifier("UIDevice"), .dotted("Host", "current"), .identifier("NSHost"), .identifier("hostName"),
        .identifier("SCDynamicStoreCopyComputerName"), .identifier("SCDynamicStoreCopyLocalHostName"),
        .identifier("CSCopyMachineName"), .identifier("gethostname"), .identifier("sysctlbyname"),
        .identifier("utsname"), .identifier("nodename"), .identifier("localizedName")
    ]

    /// Every device-name read in ProximityKit, exactly: none since plan step A0.6.2, when the local
    /// name's fallback, which read `UIDevice`, became its host's `proximityFallbackDisplayName`.
    static let deviceNameRows: [TokenRow] = []

    /// Every way a module could reach a platform directory: the `URL` and `FileManager` locations, the
    /// two Foundation functions, the search-path call, an app-group container and the two `FileManager`
    /// lookups by their first label.
    static let directoryNeedles: [Needle] = [
        .identifier("applicationSupportDirectory"), .identifier("documentDirectory"),
        .identifier("documentsDirectory"), .identifier("cachesDirectory"), .identifier("libraryDirectory"),
        .identifier("temporaryDirectory"), .identifier("NSTemporaryDirectory"), .identifier("NSHomeDirectory"),
        .identifier("homeDirectory"), .identifier("homeDirectoryForCurrentUser"),
        .identifier("NSSearchPathForDirectoriesInDomains"), .identifier("downloadsDirectory"),
        .identifier("desktopDirectory"), .identifier("sharedPublicDirectory"), .identifier("containerURL"),
        .call("urls", label: "for"), .call("url", label: "for")
    ]

    /// Every platform directory ProximityKit names, exactly: the namespace's default root under
    /// Application Support, which plan step A0.6.6 replaces with a folder under a base its host states.
    static let directoryRows: [TokenRow] = [
        TokenRow(path: "Namespace/ProximityNamespace+Installation.swift", token: "applicationSupportDirectory",
                 exit: .a066)
    ]

    /// The facts only a host may state, which no `ProximityHost` extension in ProximityKit may default:
    /// the requirements `ProximityHost.swift` says are never defaulted (the namespace, the install
    /// binding, the trust policy, the identity, the routed rows and, since plan steps A0.6.2 and A0.6.3,
    /// the fallback name and the ranging provider), then the storage root.
    static let hostFacts: Set<String> = [
        "proximityNamespace", "proximityInstallBinding", "makeProximityTrustPolicy", "makeProximityIdentity",
        "meshRoutedTypeEntries", "proximityFallbackDisplayName", "makeProximityRangingProvider",
        "proximitySupportDirectory"
    ]

    /// Every host fact ProximityKit still defaults, exactly: the storage root the host extension
    /// computes from the namespace, which plan step A0.6.6 deletes.
    static let hostFactDefaultRows: [TokenRow] = [
        TokenRow(path: "ProximityHost.swift", token: "proximitySupportDirectory", exit: .a066)
    ]

    // MARK: W1: the imports

    /// **W1.** Every module a ProximityKit file imports or tests for with `canImport` is a baseline
    /// module or an exact seam row, and every seam row's file still imports its module; a guarded row's
    /// imports sit in its `#if` branch and never its `#else`, and a whole-file row's file is that one
    /// `#if` from its first code line to its last. A platform framework enters ProximityKit only as a
    /// row with its guard and the step that removes it.
    @Test func proximityKitImportsOnlyNeutralModulesAndItsDeclaredSeams() throws {
        let sources = try ProximityNamespaceBoundaryTests.proximitySources()
        #expect(sources.count >= Self.minimumFilesWalked, "walked only \(sources.count) ProximityKit files")
        var named: Set<String> = []
        var imported: Set<String> = []
        // R2: bounded by the module's files.
        for source in sources {
            let uses = try Self.moduleUses(in: source.lexed.code).filter { !Self.baselineModules.contains($0.module) }
            named.formUnion(uses.map { Self.key(source.path, $0.module) })
            imported.formUnion(uses.filter(\.isImport).map { Self.key(source.path, $0.module) })
            Self.expectPlacement(of: uses, in: source)
        }
        let unlisted = named.subtracting(Self.seamRows.map { Self.key($0.path, $0.module) }).sorted()
        #expect(unlisted.isEmpty, """
            ProximityKit names a module that is neither a neutral baseline module nor a declared seam: \
            \(unlisted). A platform framework enters ProximityKit only as a seam row, with its guard and \
            the plan step that removes it
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

    /// **W2.** No ProximityKit file reads the device's name but on ``deviceNameRows``: what an unnamed
    /// device is called is its host's fact. Both directions: a row whose file no longer names its token
    /// fails until the row is deleted.
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

    /// **W4.** The readers read code as Swift does, both ways: an import in each of its forms, a
    /// `canImport` condition and its `#if` region, each W2 and W3 token, and a declaration at a
    /// `ProximityHost` extension's top level are read; the same text in a comment or a string literal,
    /// a line after `#else` as inside the guard, a longer name holding a token, a name an extension only
    /// reads, and a protocol's requirement are not. A whole-file guard is told from a partial one.
    @Test func theReadersReadCodeAsSwiftDoes() throws {
        try Self.expectModuleReadersFixtured()
        Self.expectWholeFileReaderFixtured()
        try Self.expectTokenReadersFixtured()
        try Self.expectDeclarationReaderFixtured()
    }

    /// The module reader: each import form and a `canImport` condition read, with the regions they sit
    /// in; nothing read from a comment or a literal; an import after `#else` outside the guard.
    static func expectModuleReadersFixtured() throws {
        let forms = try moduleUses(in: lexedCode("""
            import UIKit
            @preconcurrency import UIKit
            import struct Foundation.URL
            #if canImport(UIKit)
            #endif
            """))
        #expect(forms.map(\.module) == ["UIKit", "UIKit", "Foundation", "UIKit"], "read \(forms.map(\.module))")
        #expect(forms.map(\.isImport) == [true, true, true, false], "told imports from conditions as \(forms)")
        let prose = try moduleUses(in: lexedCode("""
            // import UIKit
            let a = "import UIKit"
            /* #if canImport(UIKit) */
            let b = "canImport(UIKit)"
            """))
        #expect(prose.isEmpty, "a comment or a literal was read as code: \(prose)")
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
        #expect(try mentions(of: .call("urls", label: "for"), in: lookup) == 1, "urls(for: was not read")
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

    /// The three doors that build one connection's coordinator: the mesh's and the recipe radio's in
    /// ProximityKit, and presence's heart door in FernletSocial, which is Fernlet's half and stays with
    /// Fernlet's walls when ProximityKit leaves the tree.
    static let channelReadyDoors = [
        Door(path: "FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift",
             signature: "private func handleChannelReady("),
        Door(path: "FernletKit/Sources/ProximityKit/RecipeSharing/ProximityRecipeShareManager.swift",
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

    /// Every module `code` names: each `import` declaration (any attributes, access level or kind before
    /// the path, its first component read) and each `canImport(…)` condition, with its region. Regions
    /// are read flat, since Power of 10's R8 forbids nesting: an `#if` opens one with its condition's
    /// text, an `#elseif` or `#else` moves past it, and `#endif` closes it.
    static func moduleUses(in code: String) throws -> [ModuleUse] {
        let declaration = try NSRegularExpression(
            pattern: #"^\s*(?:@\w+\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+"#
                + #"(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?(\w+)"#)
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

    /// A row's exit, as a failure message says it.
    static func exitText(_ exit: ExitStep?) -> String {
        exit.map { "a row plan step \($0.rawValue) deletes" } ?? "a permanent row"
    }

    /// `source`'s code as the walls read it: comments dropped, literals emptied.
    static func lexedCode(_ source: String) -> String {
        SwiftSourceLexer.lex(source).code
    }
}
