import Foundation
import Testing

/// Grep-wall for purpose separation at the raw CryptoKit boundary. It deliberately scans source,
/// rather than testing a few hand-picked code paths, so a newly-added primitive call cannot rely on
/// a reviewer remembering this policy.
struct CryptographicPurposeBoundaryTests {
    private static let roots = ["FernletKit/Sources", "App/Fernlet"]
    private static let primitiveMarkers = [
        "signature(for:", "isValidSignature(", "hkdfDerivedSymmetricKey", "HKDF<", "HMAC<",
        "ChaChaPoly.seal", "ChaChaPoly.open", "AES.GCM.seal", "AES.GCM.open"
    ]

    @Test func rawCryptographicCallsNameAPurpose() throws {
        for sourceURL in try sourceFiles() {
            let lines = try String(contentsOf: sourceURL, encoding: .utf8)
                .components(separatedBy: .newlines)
            for index in lines.indices where Self.primitiveMarkers.contains(where: lines[index].contains) {
                let context = context(around: index, in: lines)
                #expect(
                    hasPurpose(context),
                    "Raw crypto call without a purpose at \(sourceURL.path):\(index + 1)"
                )
            }
        }
    }

    private func sourceFiles() throws -> [URL] {
        let root = RepoRoot.url
        return Self.roots.flatMap { (relativeRoot: String) -> [URL] in
            let directory = root.appendingPathComponent(relativeRoot)
            guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
                return []
            }
            return files.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        }
    }

    private func context(around index: Int, in lines: [String]) -> String {
        // Asymmetric window: a multi-line primitive call names its purpose inside its own
        // argument list, which sits below the call's opening line — never above it.
        let lower = max(0, index - 3)
        let upper = min(lines.count - 1, index + 6)
        return lines[lower...upper].joined(separator: "\n")
    }

    private func hasPurpose(_ context: String) -> Bool {
        context.contains("FernletCryptoPurpose")
            || context.contains("CryptographicPurpose")
            || context.contains("purpose")
            || context.contains("authenticated")
            || context.contains("cryptographic-domain:")
    }
}
