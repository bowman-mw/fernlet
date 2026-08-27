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
///   `FernletExchangeTests`, against the same types the controller calls;
/// - its display copy is extracted to `FernletMessagesCopy` and held by
///   `LocalizationBoundaryTests` rules H1/H2;
/// - its import surface and file inventory are held here.
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
}
