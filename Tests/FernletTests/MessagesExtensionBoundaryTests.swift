import Foundation
import Testing

/// The Messages target is intentionally a transport/rendering edge. A repository or private-module
/// import there would create a second persistence stack outside Fernlet's canonical exchange
/// service — and, worse, put private data inside a process Messages hosts.
///
/// **Why the scan is by DIRECTORY and not by filename.** The first version of this suite named
/// `FernletMessagesViewController.swift` and checked its import list. That is the file the boundary
/// was written about, but it is not the boundary: a second file added to the same target is in the
/// same process with the same entitlements, and named-file scanning would never look at it. This
/// stopped being hypothetical the day `FernletMessagesCopy.swift` was added — a new file in the
/// target that the old test could not see. The rule is a property of the TARGET, so the scan
/// enumerates the target.
///
/// **What the extension is NOT tested for, stated plainly.** `FernletMessagesViewController` is a
/// `MSMessagesAppViewController` in a separate app-extension target, which this test bundle does not
/// link — so its rendering, selection and hand-off logic cannot be exercised here at all, and no
/// amount of test-writing in this file changes that. What holds it instead:
/// - the exchange logic it drives (envelope round trip, card-metadata revalidation, size limits,
///   catalog store, picker priority, inbox expiry/overflow/clear) is covered by
///   `FernletExchangeTests` and `ExchangeMessageEnvelopeV2Tests`, against the same types the
///   controller calls;
/// - which screen an opened card gets is `FernletMessagesReceivedItem.resolve`, a pure function in
///   `FernletExchange` pinned by `MessagesReceivedItemTests`; that the controller routes through it,
///   and never reads the composer's catalog on the way, is held here by source scan;
/// - its display copy is extracted to `FernletMessagesCopy` and held by
///   `LocalizationBoundaryTests` rules H1/H2;
/// - its import surface and file inventory are held here;
/// - so is its privacy manifest's required-reason declaration, against every source file that is
///   compiled into the appex binary (the target plus the package modules it links).
struct MessagesExtensionBoundaryTests {

    /// The target's directory. Every `.swift` file under it is in the appex process.
    static let extensionRoot = "App/FernletMessagesExtension"

    /// Floor for the scan. The target has three Swift files; a root that stops resolving reports
    /// zero and would otherwise pass vacuously.
    static let minimumFilesScanned = 3

    /// Modules an appex hosted by Messages may import.
    ///
    /// `FernletExchange` is the shared exchange core — value types, codecs and the App Group file
    /// stores, and deliberately no repository. Everything else is Apple UI/foundation. A module not
    /// on this list needs an argument in a review, not an edit here.
    static let permittedModules: Set<String> = ["FernletExchange", "Foundation", "Messages", "UIKit"]

    /// No file in the Messages target imports a private-store, health, or repository module.
    @Test func theMessagesTargetImportsOnlyItsTransportAndAppleUIFrameworks() throws {
        let files = try Self.swiftFiles()

        #expect(
            files.count >= Self.minimumFilesScanned,
            """
            Scanned only \(files.count) Swift files under \(Self.extensionRoot) (floor \
            \(Self.minimumFilesScanned)) — the target moved or the enumerator broke, and this \
            boundary is now unenforced.
            """
        )

        var offenders: [String] = []
        for (path, source) in files {
            for module in Self.importedModules(in: source) where !Self.permittedModules.contains(module) {
                offenders.append("\(path): import \(module)")
            }
        }
        #expect(
            offenders.isEmpty,
            """
            \(offenders.count) disallowed import(s) in the Messages extension. This target runs \
            inside a process Messages hosts: a repository or private-store module here builds a \
            second persistence stack outside the canonical exchange service, and puts private data \
            somewhere it was never meant to be. Reach the data through `FernletExchange`'s bounded \
            App Group catalog and inbox instead:
            \(offenders.sorted().joined(separator: "\n"))
            """
        )
    }

    /// A card someone opens is drawn from its own URL, never from the composer's catalog.
    ///
    /// 2026-09-30, the owner's report that receiving a recipe "pops up and is blank". Until then an
    /// opened card paid for the composer before its first frame: `viewDidLoad` read and validated the
    /// whole App Group catalog and built a composer card per recipe (up to 100, in the expanded style
    /// a received card opens in), and `willBecomeActive(with:)` read the catalog again before it looked
    /// at the selected message — all while Messages shows its own blank, spinning panel. A received
    /// card needs none of it, and the coordinated catalog read is the one step on that path that can
    /// wait on another process. `FernletTests` cannot link the appex, so this scan is what holds the
    /// shape: `viewDidLoad` reads no catalog, and draws the opening state (or the composer) only in
    /// the `PanelState` case that calls for it — never unconditionally, since Messages does not
    /// document that the view loads before the activation draws its decision; the selected-message branch
    /// of `willBecomeActive` goes straight to `showReceivedItem`, which switches over
    /// `FernletMessagesReceivedItem.resolve` (pinned by `MessagesReceivedItemTests`); and no function
    /// on the received-card path reaches the catalog or the composer.
    @Test func aReceivedCardIsDrawnWithoutTheComposersCatalog() throws {
        let source = try RepoRoot.source("App/FernletMessagesExtension/FernletMessagesViewController.swift")

        let viewDidLoad = try Self.body(of: "viewDidLoad", in: source)
        #expect(!viewDidLoad.contains("reloadCatalog") && !viewDidLoad.contains("loadCatalogIfNeeded"),
                "viewDidLoad reads the catalog again — before a received card's first frame")
        let drawn = viewDidLoad.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(drawn.filter { $0.contains("renderComposer") } == ["case .composer: renderComposer()"],
                "viewDidLoad renders the composer outside the case where an activation already decided it")
        #expect(drawn.filter { $0.contains("showOpening") } == ["case .opening: showOpening()"], """
            viewDidLoad draws the opening state whatever the panel is — if an activation ran before the \
            view loaded, the card it drew would be reset to a brand-mark-only panel, the reported symptom
            """)

        let activation = try Self.body(of: "willBecomeActive", in: source)
        let branch = try #require(activation.range(of: "guard let message = conversation.selectedMessage else {"),
                                  "willBecomeActive no longer branches on the selected message first")
        let composerReturn = try #require(activation.range(of: "return", range: branch.upperBound..<activation.endIndex))
        #expect(!activation[..<branch.lowerBound].contains("reloadCatalog"), "the catalog is read before the branch again")
        #expect(activation[branch.upperBound..<composerReturn.lowerBound].contains("reloadCatalog()"),
                "the composer branch must still re-read the catalog on every activation")
        let selectedPath = activation[composerReturn.upperBound...]
        #expect(selectedPath.contains("showReceivedItem(from: message)"))
        #expect(!selectedPath.contains("reloadCatalog") && !selectedPath.contains("renderComposer"))

        for name in Self.receivedCardPath {
            let body = try Self.body(of: name, in: source)
            #expect(!body.contains("reloadCatalog") && !body.contains("loadCatalogIfNeeded") && !body.contains("renderComposer"),
                    "\(name) is on the received-card path and reaches the composer's catalog")
        }
        #expect(try Self.body(of: "showReceivedItem", in: source).contains("FernletMessagesReceivedItem.resolve(messageURL:"),
                "the received screen is no longer decided by the resolver MessagesReceivedItemTests pins")
    }

    /// Every function an opened card runs through, from the switch to the drawn labels, plus the
    /// opening state `viewDidLoad` shows before the activation decides.
    static let receivedCardPath = [
        "showOpening", "showReceivedItem", "showReceivedRecipe", "showReceivedWorkout", "showReceived", "showInvalidReceivedItem"
    ]

    /// The body of `func <name>(` in `source`, or a recorded failure when the function is gone — a
    /// renamed function must fail the pin, not pass it by reading nothing.
    static func body(of name: String, in source: String) throws -> String {
        try #require(HealthKitLifecycleBoundaryTests.functionBody(named: name, in: source),
                     "func \(name)( is gone from FernletMessagesViewController — update this pin with the rename")
    }

    /// Fixture: the import matcher sees the forms that would matter, and the permitted set is a
    /// real filter rather than a rubber stamp.
    @Test func theImportMatcherRejectsPrivateStorageImports() {
        let imports = Self.importedModules(in: "import FernletExchange\nimport PrivateStoreCore\nimport HealthKit")

        #expect(imports.contains("PrivateStoreCore"))
        #expect(imports.contains("HealthKit"))
        #expect(!imports.contains("FernletStore"))
        #expect(!Self.permittedModules.contains("PrivateStoreCore"), "the allowlist must actually exclude it")
        #expect(!Self.permittedModules.contains("HealthKit"))
        #expect(Self.importedModules(in: "// import PrivateStoreCore").isEmpty, "a commented import is not one")
    }

    /// Every key the copy vault names is present in the extension's string catalog.
    ///
    /// This is the half of the localization fix that fails SILENTLY. A renamed member is a compile
    /// error and needs no test; a changed KEY is not — the code compiles, `String(localized:)`
    /// returns its `defaultValue`, the English renders correctly, and the catalog simply carries a
    /// key nothing uses beside a string nothing catalogues. Only re-running
    /// `Scripts/sync-string-catalogs.sh` and committing the diff fixes it, and only this notices it
    /// was not done. Modelled on `LocalizationBoundaryTests.everyForkedStringActuallyReachedItsCatalog`.
    @Test func everyCopyVaultKeyReachedTheCatalog() throws {
        let source = try RepoRoot.source("App/FernletMessagesExtension/FernletMessagesCopy.swift")
        let keys = Self.localizedKeys(in: source)

        #expect(
            keys.count >= Self.minimumCopyVaultKeys,
            """
            Found only \(keys.count) localized keys in FernletMessagesCopy (floor \
            \(Self.minimumCopyVaultKeys)) — the vault was gutted, or the `String(localized: "…"` \
            shape changed and this scan now reads nothing.
            """
        )

        let data = try Data(contentsOf: RepoRoot.url("App/FernletMessagesExtension/Localizable.xcstrings"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let catalogued = Set((json?["strings"] as? [String: Any] ?? [:]).keys)
        #expect(!catalogued.isEmpty, "the Messages catalog parsed to zero keys — it moved or broke")

        let missing = keys.subtracting(catalogued)
        #expect(
            missing.isEmpty,
            """
            \(missing.count) key(s) named in FernletMessagesCopy are not in \
            App/FernletMessagesExtension/Localizable.xcstrings, so no translator can see them and \
            they render English forever. Run Scripts/sync-string-catalogs.sh and commit the diff \
            with the code change:
            \(missing.sorted().joined(separator: "\n"))
            """
        )
    }

    /// Floor for the copy-vault scan (57 keys at the time of writing; the target's other three are
    /// the probe's).
    static let minimumCopyVaultKeys = 45

    /// Every `String(localized: "key"` key named in `source`.
    static func localizedKeys(in source: String) -> Set<String> {
        var found: Set<String> = []
        for line in source.components(separatedBy: "\n") {
            guard let head = line.range(of: "String(localized: \"") else { continue }
            let rest = line[head.upperBound...]
            guard let close = rest.firstIndex(of: "\"") else { continue }
            found.insert(String(rest[..<close]))
        }
        return found
    }

    /// Every `.swift` file in the target, as (repo-relative path, source).
    static func swiftFiles() throws -> [(path: String, source: String)] {
        let rootURL = RepoRoot.url(extensionRoot)
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
            Issue.record("Could not enumerate \(extensionRoot) — moved or renamed? This boundary is unenforced.")
            return []
        }
        var files: [(path: String, source: String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            files.append((url.path.replacingOccurrences(of: RepoRoot.url.path + "/", with: ""), source))
        }
        return files
    }

    /// Modules imported by `source`, ignoring commented-out lines.
    static func importedModules(in source: String) -> [String] {
        var modules: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { continue }
            let words = trimmed.split(separator: " ")
            guard words.count == 2, words[0] == "import" else { continue }
            modules.append(String(words[1].split(separator: ".").first ?? ""))
        }
        return modules
    }

    // MARK: - The privacy manifest matches the binary's required-reason API use

    /// The appex's own privacy manifest. App Store Connect checks each executable's required-reason
    /// API references against the manifest of the bundle that ships it (ITMS-91053); the containing
    /// app's manifest does not cover an extension's binary.
    static let privacyManifestPath = "App/FernletMessagesExtension/PrivacyInfo.xcprivacy"

    /// The package products the extension target links, per the project file. The source closure
    /// below is derived from this, so a second product is a deliberate edit here, not a silent gap.
    static let expectedPackageProducts = ["FernletExchange"]

    /// Floor for the binary-closure scan: the target's 3 files plus the 60 in `FernletExchange`,
    /// `FernletDomainModel` and `FernletFoundation` at the time of writing.
    static let minimumClosureFilesScanned = 40

    /// Apple's required-reason API categories and the identifiers that reach each one, transcribed
    /// from the `NSPrivacyAccessedAPIType` documentation (checked 2026-09-23).
    ///
    /// Matched as whole identifiers in comment- and string-stripped source, so `stat` does not fire
    /// inside `status`. What is deliberately NOT here: `FileManager.attributesOfItem(atPath:)` and
    /// `FileAttributeKey.size`. The Messages stores read an item's SIZE through that call to bound a
    /// read, and neither the call nor the size key is on Apple's list; the timestamp keys that ride
    /// the same dictionary (`creationDate`, `modificationDate`) are, and reading one of them fires
    /// this wall. `getattrlist` and friends reach two categories and are listed under both.
    static let requiredReasonIdentifiers: [String: Set<String>] = [
        "NSPrivacyAccessedAPICategoryUserDefaults": ["UserDefaults", "NSUserDefaults", "AppStorage"],
        "NSPrivacyAccessedAPICategoryFileTimestamp": [
            "creationDate", "modificationDate", "fileModificationDate", "contentModificationDateKey",
            "creationDateKey", "getattrlist", "getattrlistbulk", "fgetattrlist", "getattrlistat",
            "stat", "fstat", "fstatat", "lstat"
        ],
        "NSPrivacyAccessedAPICategorySystemBootTime": ["systemUptime", "mach_absolute_time"],
        "NSPrivacyAccessedAPICategoryDiskSpace": [
            "volumeAvailableCapacityKey", "volumeAvailableCapacityForImportantUsageKey",
            "volumeAvailableCapacityForOpportunisticUsageKey", "volumeTotalCapacityKey",
            "systemFreeSize", "systemSize", "statfs", "statvfs", "fstatfs", "fstatvfs",
            "getattrlist", "fgetattrlist", "getattrlistat"
        ],
        "NSPrivacyAccessedAPICategoryActiveKeyboards": ["activeInputModes"]
    ]

    /// The extension's privacy manifest declares EXACTLY the required-reason API categories used by
    /// the code compiled into its binary — no missing category (an upload refusal) and no extra one
    /// (a public claim about a use that does not exist).
    ///
    /// Written after the manifest shipped an empty `NSPrivacyAccessedAPITypes` while the composer
    /// read and wrote `UserDefaults.standard`: nothing compared the two, because the no-tracking wall
    /// reads manifests for tracking flags only. The scan covers the target AND every package module
    /// linked into the appex, because App Store Connect reads the binary, not the target folder.
    @Test func theExtensionManifestDeclaresExactlyTheRequiredReasonAPIsItsBinaryUses() throws {
        let products = try Self.linkedPackageProducts()
        #expect(products == Self.expectedPackageProducts, """
            The Messages extension links package products \(products), expected \
            \(Self.expectedPackageProducts). A new product widens the code compiled into the appex, \
            so the source closure this test scans must be widened with it.
            """)
        let roots = try [Self.extensionRoot] + Self.linkedModuleClosure(of: products).map { "FernletKit/Sources/\($0)" }
        let (used, scanned) = try Self.requiredReasonUse(under: roots)
        #expect(scanned >= Self.minimumClosureFilesScanned, """
            Scanned only \(scanned) Swift files across \(roots) (floor \
            \(Self.minimumClosureFilesScanned)) — the closure or the enumerator broke.
            """)

        let declared = try Self.declaredRequiredReasons()
        #expect(Set(declared.keys) == Set(used.keys), """
            \(Self.privacyManifestPath) declares \(declared.keys.sorted()) but the appex's code \
            uses \(used.keys.sorted()). Declare every used category with Apple's reason code (for \
            example CA92.1 for the extension's own defaults, 1C8F.1 for an App Group suite), and \
            remove any category nothing uses. Where each use is: \
            \(used.mapValues { $0.sorted() }.sorted { $0.key < $1.key })
            """)
        for (category, reasons) in declared {
            #expect(!reasons.isEmpty, "\(category) is declared with no reason code — App Store Connect rejects that.")
        }
    }

    /// Fixture: the identifier matcher fires on a real use, ignores prose and longer identifiers,
    /// and the manifest reader reads the shape the real file has.
    @Test func theRequiredReasonMatcherSeesUsesAndIgnoresProse() {
        let fire = Self.requiredReasonCategories(in: "let d = UserDefaults.standard\nlet t = attrs[.modificationDate]")
        #expect(fire == ["NSPrivacyAccessedAPICategoryUserDefaults", "NSPrivacyAccessedAPICategoryFileTimestamp"])
        #expect(Self.requiredReasonCategories(in: "// UserDefaults in a comment\nlet s = \"stat\"").isEmpty)
        #expect(Self.requiredReasonCategories(in: "let status = attrs[.size]; let userDefaultsLike = 1").isEmpty,
                "`stat` must not fire inside `status`, and a size read is not a timestamp read")
        #expect(Self.requiredReasonCategories(in: "if stat(path, &info) == 0 {}")
                == ["NSPrivacyAccessedAPICategoryFileTimestamp"])
    }

    /// Every required-reason category used under `roots`, with the files that use it.
    static func requiredReasonUse(under roots: [String]) throws -> (used: [String: Set<String>], scanned: Int) {
        var used: [String: Set<String>] = [:]
        var scanned = 0
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: RepoRoot.url(root), includingPropertiesForKeys: nil) else {
                Issue.record("Could not enumerate \(root) — the appex's source closure is unscanned.")
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                scanned += 1
                let source = try String(contentsOf: url, encoding: .utf8)
                for category in requiredReasonCategories(in: source) {
                    used[category, default: []].insert(url.lastPathComponent)
                }
            }
        }
        return (used, scanned)
    }

    /// The required-reason categories `source` reaches, judged on code only.
    static func requiredReasonCategories(in source: String) -> Set<String> {
        let identifiers = identifierSet(in: PrivacyWipeCoverageTests.strippingCommentsAndStringLiteralBodies(source))
        return Set(requiredReasonIdentifiers.compactMap { category, names in
            names.isDisjoint(with: identifiers) ? nil : category
        })
    }

    /// Every identifier in `source` — one linear pass, so a whole-identifier match is set membership.
    static func identifierSet(in source: String) -> Set<String> {
        var identifiers: Set<String> = []
        var current = ""
        for character in source {
            if character == "_" || character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                identifiers.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { identifiers.insert(current) }
        return identifiers
    }

    /// The `NSPrivacyAccessedAPITypes` the manifest declares, as category → reason codes.
    static func declaredRequiredReasons() throws -> [String: [String]] {
        let data = try Data(contentsOf: RepoRoot.url(privacyManifestPath))
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        guard let manifest = plist, let types = manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]] else {
            Issue.record("\(privacyManifestPath) has no readable NSPrivacyAccessedAPITypes array.")
            return [:]
        }
        var declared: [String: [String]] = [:]
        for entry in types {
            let category = entry["NSPrivacyAccessedAPIType"] as? String ?? "<unnamed>"
            declared[category] = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
        }
        return declared
    }

    /// The package products listed in the extension target's `packageProductDependencies`.
    static func linkedPackageProducts() throws -> [String] {
        let project = try RepoRoot.source("App/Fernlet.xcodeproj/project.pbxproj")
        let lines = project.components(separatedBy: "\n")
        // The same `/* FernletMessagesExtension */ = {` opener also names the synchronized folder
        // group, so the match is the one whose next line says it is the native target.
        let openers = lines.indices.filter { index in
            lines[index].hasSuffix("/* FernletMessagesExtension */ = {")
                && lines.indices.contains(index + 1) && lines[index + 1].contains("isa = PBXNativeTarget;")
        }
        guard openers.count == 1, let start = openers.first else {
            Issue.record("Found \(openers.count) FernletMessagesExtension native targets in the project file, expected 1.")
            return []
        }
        var products: [String] = []
        var inList = false
        for line in lines[(start + 1)...].prefix(64) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "};" { break }
            if trimmed.hasPrefix("packageProductDependencies = (") { inList = true; continue }
            guard inList else { continue }
            if trimmed == ");" { break }
            guard let open = trimmed.range(of: "/* "), let close = trimmed.range(of: " */") else { continue }
            products.append(String(trimmed[open.upperBound..<close.lowerBound]))
        }
        return products
    }

    /// Every FernletKit target the given products pull into a binary, by walking the `dependencies:`
    /// lists in `FernletKit/Package.swift` (the link graph, which is wider than the import graph
    /// whenever a dependency is declared but not imported).
    static func linkedModuleClosure(of products: [String]) throws -> [String] {
        let manifest = try RepoRoot.source("FernletKit/Package.swift")
        var closure: [String] = []
        var frontier = products
        // Bounded by the package's target count: each pass adds at least one new module or stops.
        for _ in 0..<64 where !frontier.isEmpty {
            let module = frontier.removeFirst()
            guard !closure.contains(module) else { continue }
            guard FileManager.default.fileExists(atPath: RepoRoot.url("FernletKit/Sources/\(module)").path) else {
                Issue.record("\(module) is linked into the appex but is not a FernletKit/Sources module — update this wall.")
                continue
            }
            closure.append(module)
            frontier += packageDependencies(of: module, in: manifest)
        }
        return closure
    }

    /// The quoted names in one target's `dependencies: [...]` list; empty when it declares none.
    static func packageDependencies(of target: String, in manifest: String) -> [String] {
        let pattern = #"name:\s*""# + target + #""\s*,\s*dependencies:\s*\[([^\]]*)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: manifest, range: NSRange(manifest.startIndex..., in: manifest)),
              let listRange = Range(match.range(at: 1), in: manifest) else { return [] }
        return manifest[listRange].split(separator: ",").compactMap { item in
            let name = item.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return name.isEmpty ? nil : name
        }
    }
}
