import Foundation
import Testing

/// The Messages target is intentionally a transport/rendering edge. A repository or private-module
/// import here would create a second persistence stack outside Fernlet's canonical exchange service.
struct MessagesExtensionBoundaryTests {
    @Test func messagesExtensionImportsOnlyItsTransportAndAppleUIFrameworks() throws {
        let source = try RepoRoot.source("App/FernletMessagesExtension/FernletMessagesViewController.swift")
        let imports = importedModules(in: source)

        #expect(imports == ["FernletExchange", "Messages", "UIKit"])
    }

    @Test func extensionBoundaryMatcherRejectsPrivateStorageImports() {
        let imports = importedModules(in: "import FernletExchange\nimport PrivateStoreCore\nimport HealthKit")

        #expect(imports.contains("PrivateStoreCore"))
        #expect(imports.contains("HealthKit"))
        #expect(!imports.contains("FernletStore"))
    }

    private func importedModules(in source: String) -> [String] {
        var modules: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard words.count == 2, words[0] == "import" else { continue }
            modules.append(String(words[1].split(separator: ".").first ?? ""))
        }
        return modules
    }
}
