import Foundation
import Testing
import UIKit

/// Every SF Symbol named by a string literal in shipping source exists on the runtime under test.
///
/// A misspelled or nonexistent name compiles clean and fails only at run time, where
/// `Image(systemName:)` logs "No symbol named … found" and draws nothing — the disposable camera's
/// off-state glyphs (`camera.slash`, `film.slash`) were invisible that way until a simulator log
/// review (2026-10-29). The scan reads source off disk like the other grep walls; names built at run
/// time are out of its reach.
struct SFSymbolNameTests {
    /// The call-site labels that take a symbol name directly.
    private static let pattern = #/(?:systemName|systemImage):\s*"([A-Za-z0-9.]+)"/#

    @Test func everyLiteralSymbolNameResolves() throws {
        var missing: [String] = []
        var checked = 0
        for path in try Self.shippingSwiftFiles() {
            let source = try String(contentsOf: RepoRoot.url.appendingPathComponent(path), encoding: .utf8)
            for match in source.matches(of: Self.pattern) {
                checked += 1
                let name = String(match.output.1)
                if UIImage(systemName: name) == nil {
                    missing.append("\(path): \(name)")
                }
            }
        }
        #expect(checked > 100, "the scan found almost no symbol names — the layout or the pattern moved")
        #expect(missing.isEmpty, "SF Symbols with no such name: \(missing.joined(separator: ", "))")
    }

    /// Every shipping Swift file under `App/` and `FernletKit/Sources/`, repo-relative.
    private static func shippingSwiftFiles() throws -> [String] {
        let root = RepoRoot.url
        var paths: [String] = []
        for folder in ["App", "FernletKit/Sources"] {
            let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(folder),
                                                            includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                paths.append(String(url.path.dropFirst(root.path.count + 1)))
            }
        }
        #expect(paths.count > 100, "the scan found almost nothing — the layout moved")
        return paths
    }
}
