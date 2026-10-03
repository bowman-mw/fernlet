// MeshSessionStoreIsolationTests.swift
// FernletTests
//
// Grep-wall keeping every test `MeshSessionStore` on its OWN scope — directory AND keychain
// service — in the idiom of `PhotoDirectoryIsolationTests`.
//
// The shared-disk-root flake family is a well-documented cross-suite hazard in this tree: XCTest and
// Swift Testing suites run in parallel inside ONE process, so anything rooted at a process-global
// path or a fixed keychain service is destroyed for every concurrently-running suite the moment one
// of them wipes. P3 item 2 adds a NEW persisted surface — `MeshSessionContext.sealed` plus the
// `com.fernlet.mesh-session` key that seals it — and `MeshSessionStore.wipeForDeleteAll` destroys
// both by service and by path. The family must not gain a member.
//
// Source-scanning is the only way to catch the omission:
// `MeshSessionStore(scope: .production(for: namespace, installBinding: binding))` compiles, passes in
// isolation every time, and lands its damage in somebody else's suite.
//
// The wall has two halves, because this store's isolation has two:
//   • the STORE half — every construction in the test tree names a scope, and never the production
//     one;
//   • the APP half — `FernletStore.meshSessionStorage` derives BOTH pieces from seams that are
//     already walled (`proximitySupportRoot`, `heartDropKeychainService`), which is what makes a
//     test store that is isolated for hearts isolated for mesh-session state for free. If that
//     derivation is ever replaced by a production constant, this wall goes red rather than the
//     flake appearing three suites away.

import FernletConnections
import FernletSocial
import Foundation
import Testing
@testable import ProximityKit

struct MeshSessionStoreIsolationTests {

    /// This file names the constructors in its own scanner literals, so exclude it from the sweep.
    private static let excludedFiles: Set<String> = ["MeshSessionStoreIsolationTests.swift"]

    // MARK: - The store half

    /// Every `MeshSessionStore(…)` in the test tree passes an explicit `scope:`.
    ///
    /// The initialiser has no default, so today this cannot even compile wrong — which is exactly
    /// why the wall is worth having: the cheapest "convenience" a future change could add is a
    /// defaulted `scope: .production`, and that change would be invisible to every other test.
    @Test func everyTestStoreConstructionNamesItsScope() throws {
        var scanned = 0
        for (file, source) in try Self.testSources() {
            for arguments in Self.constructionArguments(of: "MeshSessionStore(", in: source) {
                scanned += 1
                #expect(
                    arguments.contains("scope:"),
                    """
                    \(file) constructs MeshSessionStore without `scope:`, so it shares the process-wide \
                    sealed-context file and the process-wide `com.fernlet.mesh-session` keychain row \
                    with every other live store — any concurrent test that runs "delete everything" \
                    destroys both. Pass a per-test scope (see MeshSessionStoreFixtures.scope()).
                    """
                )
            }
        }
        #expect(scanned >= 8, "the MeshSessionStore construction scan found only \(scanned) sites — scanner broken?")
    }

    /// No test builds the PRODUCTION scope, by either spelling.
    ///
    /// The directory half alone is not enough and neither is the key half: files on a private root
    /// sealed by a shared key survive somebody else's wipe as ciphertext nothing can open, which is
    /// strictly worse than losing them outright. So both spellings that resolve to production —
    /// `MeshSessionStorageScope.production(for:installBinding:)` and a hand-built scope naming
    /// `ProximitySupportLayout.defaultDirectory` or the production service literal, or (since
    /// ProximityKit plan step A0.2.8, when the production scope began reading the namespace) a
    /// namespace's `installation.storage.defaultDirectory` or
    /// `installation.keychain.meshSessionSealKey.service` — are banned in the test tree. Since step
    /// A0.2.12 so are the two spellings the substring needle never saw: the shorthand
    /// `.production(for:installBinding:)` wherever a scope is expected
    /// (`MeshSessionStore(scope: .production(…))`), and the type-prefixed one broken before its `.`.
    /// See ``shorthandProductionScopes(in:)`` and ``typePrefixedProductionScopes(of:in:)``.
    @Test func noTestReachesTheProductionScope() throws {
        var scanned = 0
        for (file, source) in try Self.testSources() {
            scanned += 1
            #expect(
                !source.contains("MeshSessionStorageScope.production"),
                "\(file) uses the PRODUCTION mesh-session scope — it shares the real file and the real keychain row with every concurrent suite."
            )
            let code = SwiftSourceLexer.lex(source).code
            let reads = Self.typePrefixedProductionScopes(of: "MeshSessionStorageScope", in: code)
                + Self.shorthandProductionScopes(in: code)
            #expect(
                reads.isEmpty,
                """
                \(file) reaches a PRODUCTION storage scope through \(reads) — it shares the real file \
                and the real keychain row with every concurrent suite. A shorthand \
                `.production(for:installBinding:)` does not say which scope it builds (only the \
                mesh-session and routed scopes declare it), so this wall and its routed twin both \
                refuse it.
                """
            )
            for arguments in Self.constructionArguments(of: "MeshSessionStorageScope(", in: source) {
                #expect(
                    !arguments.contains("ProximitySupportLayout.defaultDirectory"),
                    "\(file) builds a mesh-session scope on the production sidecar directory: \(arguments)"
                )
                #expect(
                    !arguments.contains("\"com.fernlet.mesh-session\""),
                    "\(file) builds a mesh-session scope on the production keychain service: \(arguments)"
                )
                #expect(
                    !arguments.contains("installation.storage.defaultDirectory"),
                    "\(file) builds a mesh-session scope on a namespace's production directory: \(arguments)"
                )
                #expect(
                    !arguments.contains("installation.keychain.meshSessionSealKey.service"),
                    "\(file) builds a mesh-session scope on a namespace's production keychain service: \(arguments)"
                )
            }
        }
        #expect(scanned > 100, "the test-source sweep found only \(scanned) files — the test root moved?")
    }

    // MARK: - The app half

    /// `FernletStore.meshSessionStorage` derives both halves from seams other walls already enforce.
    ///
    /// This is the load-bearing reason the store needs no fourth injectable seam on `FernletStore`:
    /// `PhotoDirectoryIsolationTests` already requires every test file that reaches `deleteAllData`
    /// and builds a store DIRECTLY to pass `proximitySupportDirectory:` **and**
    /// `heartDropKeychainService:`. Derive from those two and isolation is inherited; hard-code
    /// either one and it is silently lost — for the keychain half, with no file-level symptom at
    /// all. Scanned rather than exercised because the failure is a source change, not a behaviour.
    @Test func theAppScopeIsDerivedFromTheAlreadyWalledSeams() throws {
        let source = try RepoRoot.source("App/Fernlet/FernletStore.swift")
        guard let declaration = source.range(of: "var meshSessionStorage: MeshSessionStorageScope {") else {
            Issue.record("FernletStore.meshSessionStorage is gone — the sealed mesh-session context lost its app-side scope")
            return
        }
        let tail = source[declaration.upperBound...]
        let body = String(tail.prefix(600))

        #expect(
            body.contains("directory: proximitySupportRoot"),
            "meshSessionStorage no longer derives its directory from `proximitySupportRoot`, so a test store's sealed context is back on the production root."
        )
        #expect(
            body.contains("besideHeartDrop: heartDropKeychainService"),
            "meshSessionStorage no longer derives its keychain service from `heartDropKeychainService`, so every live store shares one seal key and any wipe unopens the others' files."
        )
    }

    /// The derivation itself: production in, production out; anything else in, something else out.
    ///
    /// The behavioural half of the scan above — a derivation that returned the production service
    /// for an isolated input would pass the source scan and isolate nothing. Since ProximityKit plan
    /// step A0.2.8 the derivation and the production scope read the host's namespace, so this pins
    /// them under `.fernlet`: its seal-key service, its default directory, and the namespace itself
    /// carried on the scope — and since step A0.2.9, the install binding it is handed.
    @Test func theDerivedKeychainServiceTracksItsHeartDropInput() {
        let namespace = ProximityNamespace.fernlet
        let productionService = namespace.installation.keychain.meshSessionSealKey.service
        let production = MeshSessionStorageScope.keychainService(
            besideHeartDrop: HeartPrekeyStore.keychainService, in: namespace
        )
        #expect(production == productionService)
        let productionScope = MeshSessionStorageScope.production(
            for: namespace, installBinding: FernletDeviceBindingAdapter()
        )
        #expect(productionScope.keychainService == production)
        #expect(productionScope.directory == namespace.installation.storage.defaultDirectory)
        #expect(productionScope.namespace == namespace)
        #expect(productionScope.installBinding is FernletDeviceBindingAdapter)

        let isolated = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        let derived = MeshSessionStorageScope.keychainService(besideHeartDrop: isolated, in: namespace)
        #expect(derived != productionService,
                "an isolated heart-drop service derived the PRODUCTION mesh-session service — isolation lost")
        #expect(derived.hasPrefix(isolated), "the derived service must stay traceable to the scope it belongs to")

        let other = MeshSessionStorageScope.keychainService(
            besideHeartDrop: "com.fernlet.heartdrop.test.\(UUID().uuidString)", in: namespace
        )
        #expect(derived != other, "two isolated stores derived the SAME mesh-session service")
    }

    /// The two production-scope scanners, fixtured both ways, because the matcher is the wall.
    ///
    /// The shorthand scanner sees `.production(for:installBinding:)` in every place a scope goes: an
    /// argument, a typed binding wrapped across lines, a host's computed property, a `return`. The
    /// type-prefixed scanner sees its own type's spelling on one line and broken before the `.`, and
    /// not its twin's, which is what keeps each wall's derivation cell green under the other wall's
    /// sweep. Neither reads another type's `.production`, nor a production read through a value.
    @Test func theProductionScopeScannersSeeEverySpellingAndOnlyThose() {
        let shorthand = [
            "MeshSessionStore(scope: .production(for: namespace, installBinding: binding))",
            "let scope: MeshSessionStorageScope = .production(\n    for: .fernlet, installBinding: binding\n)",
            "var meshSessionStorage: MeshSessionStorageScope { .production(for: ns, installBinding: b) }",
            "var meshSessionStorage: MeshSessionStorageScope { return .production(for: ns, installBinding: b) }"
        ]
        for source in shorthand {
            #expect(Self.shorthandProductionScopes(in: source).count == 1, "the shorthand scanner missed: \(source)")
        }
        let typePrefixed = [
            "MeshSessionStorageScope.production(\n    for: namespace, installBinding: FernletDeviceBindingAdapter()\n)",
            "MeshSessionStorageScope\n    .production(for: namespace, installBinding: binding)"
        ]
        for source in typePrefixed {
            #expect(Self.shorthandProductionScopes(in: source).isEmpty, "read as shorthand: \(source)")
            #expect(Self.typePrefixedProductionScopes(of: "MeshSessionStorageScope", in: source).count == 1,
                    "the type-prefixed scanner missed: \(source)")
            #expect(Self.typePrefixedProductionScopes(of: "MeshRoutedStorageScope", in: source).isEmpty,
                    "the routed scanner read the session scope's spelling: \(source)")
        }
        let neither = [
            "index: index, at: now, capacity: .production, directoryFileCount: 0",
            "let inputs = CryptoFormatCensus.Inputs.production(for: store)",
            "let scope = host?.production(for: namespace, installBinding: binding)"
        ]
        for source in neither {
            #expect(Self.shorthandProductionScopes(in: source).isEmpty
                    && Self.typePrefixedProductionScopes(of: "MeshSessionStorageScope", in: source).isEmpty,
                    "a production scanner misread: \(source)")
        }
    }

    // MARK: - Scanner

    /// Every `.swift` file under the test root, as `(filename, source)`, minus this file.
    private static func testSources() throws -> [(String, String)] {
        let testsRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let enumerator = FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" && !excludedFiles.contains($0.lastPathComponent) }
        var sources: [(String, String)] = []
        // R2: bounded by the file list.
        for file in files.sorted(by: { $0.path < $1.path }) {
            sources.append((file.lastPathComponent, try String(contentsOf: file, encoding: .utf8)))
        }
        return sources
    }

    /// The argument text of every `name…)` construction in `source`, matched by depth so nested
    /// parentheses do not truncate an argument list.
    static func constructionArguments(of name: String, in source: String) -> [String] {
        var found: [String] = []
        var searchStart = source.startIndex
        // R2: each pass consumes at least one character of a finite string.
        while let head = source.range(of: name, range: searchStart..<source.endIndex) {
            searchStart = head.upperBound
            guard let close = matchingParenthesis(in: source, after: head.upperBound) else { continue }
            found.append(String(source[head.upperBound..<close]))
        }
        return found
    }

    /// Every implicit-member `.production(…)` in `code` whose arguments name `installBinding:`, with
    /// its argument text: the shorthand that builds a production storage scope wherever a scope is
    /// expected (`MeshSessionStore(scope: .production(for: namespace, installBinding: binding))`, a
    /// host's `var meshSessionStorage: MeshSessionStorageScope { .production(…) }`), which no
    /// type-prefixed needle can see. Only the mesh-session and routed scopes declare
    /// `production(for:installBinding:)`, so this finds both and cannot tell them apart. A member
    /// access is not shorthand: `MeshSessionStorageScope.production(`, the same broken across lines,
    /// `scope?.production(`. Pass lexed code (`SwiftSourceLexer.lex(_:).code`), so prose about the
    /// shorthand, and a fixture string spelling it, are not read as using it.
    static func shorthandProductionScopes(in code: String) -> [String] {
        var found: [String] = []
        var searchStart = code.startIndex
        // R2: each pass consumes at least one character of a finite string.
        while let head = code.range(of: ".production", range: searchStart..<code.endIndex) {
            searchStart = head.upperBound
            guard startsAnImplicitMember(at: head.lowerBound, in: code) else { continue }
            let rest = code[head.upperBound...].drop(while: \.isWhitespace)
            guard rest.first == "(",
                  let close = matchingParenthesis(in: code, after: code.index(after: rest.startIndex))
            else { continue }
            let arguments = code[code.index(after: rest.startIndex)..<close]
            if arguments.contains("installBinding:") { found.append(".production(\(arguments))") }
        }
        return found
    }

    /// Every `typeName.production` in `code`, whitespace and line breaks allowed around the `.`: the
    /// spelling the substring needle misses when a chain is broken before its `.`. Pass lexed code.
    static func typePrefixedProductionScopes(of typeName: String, in code: String) -> [String] {
        var found: [String] = []
        var searchStart = code.startIndex
        // R2: each pass consumes at least one character of a finite string.
        while let head = code.range(of: typeName, range: searchStart..<code.endIndex) {
            searchStart = head.upperBound
            if head.lowerBound > code.startIndex, isIdentifierCharacter(code[code.index(before: head.lowerBound)]) {
                continue
            }
            let dot = code[head.upperBound...].drop(while: \.isWhitespace)
            guard dot.first == "." else { continue }
            let member = dot.dropFirst().drop(while: \.isWhitespace)
            guard member.hasPrefix("production") else { continue }
            let after = member.dropFirst("production".count)
            if let next = after.first, isIdentifierCharacter(next) { continue }
            found.append(String(code[head.lowerBound..<after.startIndex]))
        }
        return found
    }

    /// Whether the `.` at `dot` starts an implicit member expression: what precedes it, past any
    /// whitespace, cannot end an expression the `.` continues, or is a keyword.
    private static func startsAnImplicitMember(at dot: String.Index, in code: String) -> Bool {
        var index = dot
        // R2: bounded by the characters before `dot`.
        while index > code.startIndex, code[code.index(before: index)].isWhitespace {
            index = code.index(before: index)
        }
        guard index > code.startIndex else { return true }
        let last = code[code.index(before: index)]
        if last == ")" || last == "]" { return false }
        if index == dot, "?!>".contains(last) { return false }
        guard isIdentifierCharacter(last) else { return true }
        let word = String(code[..<index].reversed().prefix(while: isIdentifierCharacter).reversed())
        return ["return", "in", "case", "try", "await", "throw", "else"].contains(word)
    }

    /// Whether `character` can be part of a Swift identifier, as far as these scanners need.
    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Index of the `)` closing the parenthesis that opened just before `start`, or nil.
    private static func matchingParenthesis(in source: String, after start: String.Index) -> String.Index? {
        var depth = 1
        var index = start
        // R2: bounded by the remaining characters.
        while index < source.endIndex {
            let character = source[index]
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
