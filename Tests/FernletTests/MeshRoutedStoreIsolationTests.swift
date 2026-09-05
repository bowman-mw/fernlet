// MeshRoutedStoreIsolationTests.swift
// FernletTests
//
// Grep-wall keeping every test `MeshRoutedStore` on its OWN scope — directory AND keychain service —
// in the idiom of `MeshSessionStoreIsolationTests` and `PhotoDirectoryIsolationTests`; plus the
// one-construction-site wall over `MeshCustodyDurabilityWitness`.
//
// The shared-disk-root flake family is a well-documented cross-suite hazard in this tree: XCTest and
// Swift Testing suites run in parallel inside ONE process, so anything rooted at a process-global
// path or a fixed keychain service is destroyed for every concurrently-running suite the moment one
// of them wipes. P5 item 3 adds a NEW persisted surface — `MeshRoutedIndex.sealed`, its `.corrupt`
// sibling, a whole directory of `MeshRoutedChunks/<uuid>.chunk` payload files, and the
// `com.fernlet.mesh-routed` key that seals all of them — and `MeshRoutedStore.wipeForDeleteAll`
// destroys every one of them by service and by path. The family must not gain a member.
//
// Source-scanning is the only way to catch the omission: `MeshRoutedStore(scope: .production)`
// compiles, passes in isolation every time, and lands its damage in somebody else's suite.
//
// The witness wall is a different kind of claim and lives here because it is the same tool. The
// compile-time gate on `MeshCustodyDurabilityWitness` is `fileprivate`, which is FILE scope — so it
// holds only while the type and its one minting verb share a file that holds nothing else. Moving
// the type would widen the gate silently, with no compile error and no failing behaviour test. This
// is the wall that notices.

import Foundation
import Testing
@testable import ProximityKit

/// Source-scan helpers shared by the routed walls. A free enum rather than a static on a suite,
/// because the suites that need it are not all main-actor isolated.
enum MeshRoutedSourceScan {

    /// `source` with every whole-line comment removed, so a grep-wall states something about CODE
    /// rather than about the prose that explains why the code does not do a thing.
    static func codeOnly(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

struct MeshRoutedStoreIsolationTests {

    /// This file names the constructors in its own scanner literals, so exclude it from the sweep.
    private static let excludedFiles: Set<String> = ["MeshRoutedStoreIsolationTests.swift"]

    // MARK: - The store half

    /// Every `MeshRoutedStore(…)` in the test tree passes an explicit `scope:`.
    ///
    /// The initialiser has no default, so today this cannot even compile wrong — which is exactly why
    /// the wall is worth having: the cheapest "convenience" a future change could add is a defaulted
    /// `scope: .production`, and that change would be invisible to every other test.
    @Test func everyTestStoreConstructionNamesItsScope() throws {
        var scanned = 0
        for (file, source) in try Self.testSources() {
            for arguments in MeshSessionStoreIsolationTests.constructionArguments(
                of: "MeshRoutedStore(", in: source
            ) {
                scanned += 1
                #expect(
                    arguments.contains("scope:"),
                    """
                    \(file) constructs MeshRoutedStore without `scope:`, so it shares the process-wide \
                    sealed index, the process-wide chunk directory and the process-wide \
                    `com.fernlet.mesh-routed` keychain row with every other live store — any concurrent \
                    test that runs "delete everything" destroys all three. Pass a per-test scope (see \
                    MeshRoutedStoreFixtures.scope()).
                    """
                )
            }
        }
        #expect(scanned >= 8, "the MeshRoutedStore construction scan found only \(scanned) sites — scanner broken?")
    }

    /// No test builds the PRODUCTION scope, by either spelling.
    ///
    /// The directory half alone is not enough and neither is the key half: files on a private root
    /// sealed by a shared key survive somebody else's wipe as ciphertext nothing can open, which is
    /// strictly worse than losing them outright.
    @Test func noTestReachesTheProductionScope() throws {
        var scanned = 0
        for (file, source) in try Self.testSources() {
            scanned += 1
            #expect(
                !source.contains("MeshRoutedStorageScope.production"),
                "\(file) uses the PRODUCTION routed scope — it shares the real index, the real chunk directory and the real keychain row with every concurrent suite."
            )
            for arguments in MeshSessionStoreIsolationTests.constructionArguments(
                of: "MeshRoutedStorageScope(", in: source
            ) {
                #expect(
                    !arguments.contains("ProximitySupportLayout.defaultDirectory"),
                    "\(file) builds a routed scope on the production sidecar directory: \(arguments)"
                )
                #expect(
                    !arguments.contains("\"com.fernlet.mesh-routed\""),
                    "\(file) builds a routed scope on the production keychain service: \(arguments)"
                )
            }
        }
        #expect(scanned > 100, "the test-source sweep found only \(scanned) files — the test root moved?")
    }

    // MARK: - The app half

    /// `FernletStore.meshRoutedStorage` derives both halves from seams other walls already enforce.
    ///
    /// This is the load-bearing reason the store needs no fourth injectable seam on `FernletStore`:
    /// `PhotoDirectoryIsolationTests` already requires every test file that reaches `deleteAllData`
    /// and builds a store DIRECTLY to pass `proximitySupportDirectory:` **and**
    /// `heartDropKeychainService:`. Derive from those two and isolation is inherited; hard-code either
    /// one and it is silently lost — for the keychain half, with no file-level symptom at all.
    @Test func theAppScopeIsDerivedFromTheAlreadyWalledSeams() throws {
        let source = try RepoRoot.source("App/Fernlet/FernletStore.swift")
        guard let declaration = source.range(of: "var meshRoutedStorage: MeshRoutedStorageScope {") else {
            Issue.record("FernletStore.meshRoutedStorage is gone — the sealed routed store lost its app-side scope")
            return
        }
        let body = String(source[declaration.upperBound...].prefix(600))

        #expect(
            body.contains("directory: proximitySupportRoot"),
            "meshRoutedStorage no longer derives its directory from `proximitySupportRoot`, so a test store's routed custody is back on the production root."
        )
        #expect(
            body.contains("besideHeartDrop: heartDropKeychainService"),
            "meshRoutedStorage no longer derives its keychain service from `heartDropKeychainService`, so every live store shares one seal key and any wipe unopens the others' files."
        )
    }

    /// The derivation itself: production in, production out; anything else in, something else out.
    @Test func theDerivedKeychainServiceTracksItsHeartDropInput() {
        let production = MeshRoutedStorageScope.keychainService(besideHeartDrop: HeartPrekeyStore.keychainService)
        #expect(production == MeshRoutedStorageScope.productionKeychainService)

        let isolated = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        let derived = MeshRoutedStorageScope.keychainService(besideHeartDrop: isolated)
        #expect(derived != MeshRoutedStorageScope.productionKeychainService,
                "an isolated heart-drop service derived the PRODUCTION routed service — isolation lost")
        #expect(derived.hasPrefix(isolated), "the derived service must stay traceable to the scope it belongs to")

        let other = MeshRoutedStorageScope.keychainService(
            besideHeartDrop: "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        )
        #expect(derived != other, "two isolated stores derived the SAME routed service")
        // And the routed key does NOT lodge under the mesh-session service: one fate per service is
        // the only arrangement a service-wide delete can express honestly, so a session wipe must
        // not be able to orphan routed ciphertext. (Spelled as a literal rather than through the
        // session scope's own constant, which `MeshSessionStoreIsolationTests` bans by substring.)
        #expect(production != "com.fernlet.mesh-session")
        #expect(MeshRoutedSealKey.keychainAccount != MeshSessionSealKey.keychainAccount)
    }

    // MARK: - The durability gate

    /// `MeshCustodyDurabilityWitness` has exactly one construction site, and it is the file holding
    /// `committingCustody` and nothing else.
    ///
    /// The compile-time gate is `fileprivate`, so this wall is not redundant with it — it is what
    /// notices when someone MOVES the type, which widens the gate with no compile error. If the
    /// witness ever has to become `internal`, this wall is the replacement for the guarantee that is
    /// lost, and it must then be tightened rather than deleted.
    @Test func theDurabilityWitnessHasExactlyOneConstructionSite() throws {
        let root = RepoRoot.url("FernletKit/Sources/ProximityKit")
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        var scanned = 0
        var constructionSites: [String] = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            scanned += 1
            let source = try String(contentsOf: file, encoding: .utf8)
            let code = MeshRoutedSourceScan.codeOnly(source)
            if code.contains("MeshCustodyDurabilityWitness(") {
                constructionSites.append(file.lastPathComponent)
            }
        }
        #expect(scanned >= 8, "the ProximityKit sweep found only \(scanned) files — scanner broken?")
        #expect(
            constructionSites == ["MeshRoutedCustodyCommit.swift"],
            """
            `MeshCustodyDurabilityWitness(` is constructed in \(constructionSites) — it must be built \
            in exactly one file, the one holding `committingCustody` and nothing else. A second site \
            means a receipt can be minted for bytes no durable write returned.
            """
        )
    }

    /// The file that holds the witness holds the commit verb and nothing else — the property that
    /// makes `fileprivate` a real gate rather than a comment.
    @Test func theCommitFileHoldsOnlyTheWitnessAndItsVerb() throws {
        let source = try RepoRoot.source(
            "FernletKit/Sources/ProximityKit/Mesh/MeshRoutedCustodyCommit.swift"
        )
        let code = MeshRoutedSourceScan.codeOnly(source)
        #expect(code.contains("struct MeshCustodyDurabilityWitness"))
        #expect(code.contains("fileprivate init("))
        #expect(code.contains("func committingCustody("))
        // The write token's own gate is in another file, so this one cannot mint one either.
        #expect(code.contains("LoadToken(fileURL:") == false,
                "the commit file must not be able to mint a write token")
        let store = try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshRoutedStore.swift")
        #expect(MeshRoutedSourceScan.codeOnly(store).contains("fileprivate init(fileURL:"))
    }

    // MARK: - The delivery gate (P5 item 4)

    /// `MeshRecipientDeliveryWitness` has exactly one construction site, and it is the file holding
    /// `committingDelivery` and nothing else.
    ///
    /// Same claim, same reason as the custody witness above: the compile-time gate is `fileprivate`,
    /// so this wall is what notices when someone MOVES the type, which widens the gate with no
    /// compile error.
    @Test func theRecipientWitnessCanOnlyBeMintedInItsOwnFile() throws {
        var constructionSites: [String] = []
        for (file, code) in try Self.proximitySources() where code.contains("MeshRecipientDeliveryWitness(") {
            constructionSites.append(file)
        }
        #expect(
            constructionSites == ["MeshRoutedDeliveryCommit.swift"],
            """
            `MeshRecipientDeliveryWitness(` is constructed in \(constructionSites) — it must be built \
            in exactly one file, the one holding `committingDelivery` and nothing else. A second site \
            means a recipient receipt can be minted for an acknowledgement no durable write returned.
            """
        )
    }

    /// The file that holds the delivery witness holds the commit verb and nothing else — the property
    /// that makes `fileprivate` a real gate rather than a comment.
    @Test func theDeliveryCommitFileHoldsTheWitnessAndTheVerbAndNothingElse() throws {
        let code = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshRoutedDeliveryCommit.swift")
        )
        #expect(code.contains("struct MeshRecipientDeliveryWitness"))
        #expect(code.contains("fileprivate init("))
        #expect(code.contains("func committingDelivery("))
        // The write token's own gate is in another file, so this one cannot mint one either.
        #expect(code.contains("LoadToken(fileURL:") == false,
                "the delivery commit file must not be able to mint a write token")
        // And it holds no OTHER store verb: the ingest door lives next door on purpose.
        #expect(code.contains("func recordingRecipientReceipt(") == false)
        #expect(code.contains("func committingCustody(") == false)
    }

    /// The commit verb writes no delivery rung — the source half of the invariant its behavioural
    /// twin asserts.
    ///
    /// Cheap, and it is what stops the split being quietly re-merged by a later edit: the
    /// `delivered` rung has exactly ONE writer, and it takes a signed receipt whose signer is that
    /// destination.
    @Test func theCommitVerbWritesNoDeliveryRung() throws {
        let code = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshRoutedDeliveryCommit.swift")
        )
        #expect(code.contains("advancing(") == false,
                "the delivery commit file advances a rung — only the receipt door may")
        #expect(code.contains("MeshRoutedDeliveryRecord(encoding:") == false,
                "the delivery commit file re-encodes a delivery map — only the receipt door may")
        let ingest = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshRoutedDeliveryIngest.swift")
        )
        #expect(ingest.contains("advancing(receipt.recipientFingerprint, to: .delivered)"),
                "the receipt door is where a rung moves, on the SIGNER's own destination")
    }

    /// `MeshHeartLedgerProof` can only be built inside the ledger's own file — the heart half of
    /// durable-before-acknowledged, gated the same way.
    @Test func theHeartLedgerProofCanOnlyBeMintedInTheLedgersOwnFile() throws {
        var constructionSites: [String] = []
        for (file, code) in try Self.proximitySources() where code.contains("MeshHeartLedgerProof(") {
            constructionSites.append(file)
        }
        #expect(
            constructionSites == ["ProximityHeartLedger.swift"],
            """
            `MeshHeartLedgerProof(` is constructed in \(constructionSites) — only the ledger may vend \
            one. A second site means a heart receipt can be minted for a gift the ledger never stored.
            """
        )
        let ledger = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/HeartSharing/ProximityHeartLedger.swift")
        )
        #expect(ledger.contains("public nonisolated struct MeshHeartLedgerProof"))
        #expect(ledger.contains("fileprivate init(giftID:"))
    }

    /// Shipping code names exactly ONE ack-stage table.
    ///
    /// Injection alone does not deliver "a recipient cannot claim a weaker rule" — the table is a
    /// door parameter, so a second shipping value would be a second policy. A fixture table is a
    /// test-only affordance, and this is what keeps it one.
    ///
    /// The construction half uses the same paren-matching scanner the store walls above use, not a
    /// `contains("MeshRoutedAckStageTable(rows:")`: the literal form is blind to a construction
    /// wrapped between the paren and the `rows:` label, and this wall is the ONLY thing standing
    /// between a caller and a table mapping `…routed-type.heart.v1` to `.durableRecipientStorage` —
    /// a heart reported delivered on ciphertext alone, with no foreground decrypt and no ledger
    /// commit. Unlike the witness and the ledger proof, the table has no `fileprivate` gate.
    ///
    /// **P5 item 11 moved the construction site, and the wall moved with it in the same commit.**
    /// The table is now a PROJECTION of `MeshRoutedTypeRegistry`'s rows, so the one place a table is
    /// built is the registry's own file — and the sentence above stays true word for word, with the
    /// registry standing where the ack file used to. The member half is unchanged and stays that
    /// way by design: no shipping file, the registry's included, names any
    /// `MeshRoutedAckStageTable.` member but `.increment1` (which is why the registry declares its
    /// own `maxEntries` rather than reading `maxRows` across — the equality is pinned from the test
    /// target by `theRegistrysCapEqualsTheAckTablesCap`).
    @Test func shippingCodeNamesOneAckStageTable() throws {
        var constructionSites: [String] = []
        var otherValues: [String] = []
        for (file, code) in try Self.proximitySources() {
            for _ in MeshSessionStoreIsolationTests.constructionArguments(
                of: "MeshRoutedAckStageTable(", in: code
            ) {
                constructionSites.append(file)
            }
            for fragment in code.components(separatedBy: "MeshRoutedAckStageTable.").dropFirst()
            where !fragment.hasPrefix("increment1") {
                otherValues.append("\(file): …MeshRoutedAckStageTable.\(fragment.prefix(24))")
            }
        }
        #expect(constructionSites == ["MeshRoutedTypeRegistry.swift"],
                "a second shipping `MeshRoutedAckStageTable(rows:)` is a second policy: \(constructionSites)")
        #expect(otherValues.isEmpty,
                "shipping code names an ack-stage table other than `.increment1`: \(otherValues)")
    }

    /// Shipping code names exactly ONE routed type registry (P5 item 11).
    ///
    /// The ack-stage wall's exact shape, one level up. The registry is the single source of the
    /// verifier's accepted-token set, the ack-stage projection, the mint's per-type guards and the
    /// four forwarding gates — so a second shipping registry would be a second answer to "is this
    /// type known", and that is the one question plan §11 says must have one answer everywhere.
    ///
    /// The member half is why `MeshNetworkManager.routedTypes` spells its fallback out in full
    /// (`?? MeshRoutedTypeRegistry.increment1`), and why the mint's `types:` default is spelled the
    /// same way: a leading-dot `.increment1` — or a future `.increment2` in either position — is
    /// invisible to this scanner. `theTypeRegistryScannersMatchAcrossLines` fixtures that blind spot
    /// from both sides, asserting both of those files still name the type in full.
    @Test func shippingCodeNamesOneTypeRegistry() throws {
        var constructionSites: [String] = []
        var otherValues: [String] = []
        for (file, code) in try Self.proximitySources() {
            for _ in MeshSessionStoreIsolationTests.constructionArguments(
                of: "MeshRoutedTypeRegistry(", in: code
            ) {
                constructionSites.append(file)
            }
            for fragment in code.components(separatedBy: "MeshRoutedTypeRegistry.").dropFirst()
            where !fragment.hasPrefix("increment1") {
                otherValues.append("\(file): …MeshRoutedTypeRegistry.\(fragment.prefix(24))")
            }
        }
        #expect(constructionSites == ["MeshRoutedTypeRegistry.swift"],
                "a second shipping `MeshRoutedTypeRegistry(entries:)` is a second policy: \(constructionSites)")
        #expect(otherValues.isEmpty,
                "shipping code names a type registry other than `.increment1`: \(otherValues)")
    }

    /// No shipping code branches on a routed type token — the registry IS the only per-type switch.
    ///
    /// The allowlist is **per substring**, not per file, because the two spelling needles have
    /// different single-source rules. `MeshRoutedTypeToken.` may be named where the constants are
    /// declared and where the three registry rows are built from them; the raw
    /// `fernlet.mesh.routed-type.` literal may be named only where it is declared, because allowing
    /// it in the registry file would let an implementer type a spelling straight into a row and give
    /// one token two sources that drift silently.
    ///
    /// Legal by construction, and it must stay legal: passing `manifest.typeToken` as a **lookup
    /// argument**, logging it as a context value, and branching on a **resolved** value
    /// (`entry.requiresForegroundDecryptBeforeFinal`, `switch stage`, a retention comparison) are the
    /// point of the registry, not violations of it.
    ///
    /// `MeshRoutedSourceScan.codeOnly` strips whole-line comments only, so string literals survive
    /// (which is what makes the literal needle work at all) and so do trailing comments on code
    /// lines — a `let x = y  // see fernlet.mesh.routed-type.photo.v1` would be a false positive
    /// here. Noted rather than designed around: it fails loudly and the fix is to move the comment.
    @Test func noShippingCodeBranchesOnARoutedTypeToken() throws {
        var violations: [String] = []
        for (file, code) in try Self.proximitySources() {
            for (needle, files) in Self.routedTokenNeedles
            where code.contains(needle) && !files.contains(file) {
                violations.append("\(file): \(needle)")
            }
        }
        #expect(violations.isEmpty,
                "a per-type branch or a second token spelling outside the registry: \(violations)")
    }

    /// Wall 3's needles and their per-substring allowlists — **the wall's data, hoisted so the wall
    /// and its fixture read the same dictionary.**
    ///
    /// Held here rather than inside `noShippingCodeBranchesOnARoutedTypeToken` because a fixture that
    /// re-typed the needles as literals could not fail: deleting `"typeToken =="` from a local
    /// dictionary would blind the wall while every `"…".contains("typeToken ==")` assertion stayed
    /// green. `theTypeRegistryScannersMatchAcrossLines` drives THIS value, so removing or widening a
    /// row is a test failure rather than a silent narrowing of what the wall catches.
    private static let routedTokenNeedles: [String: Set<String>] = [
        "MeshRoutedTypeToken.": ["MeshRoutedAck.swift", "MeshRoutedTypeRegistry.swift"],
        "fernlet.mesh.routed-type.": ["MeshRoutedAck.swift"],
        "typeToken ==": [],
        "== manifest.typeToken": [],
        "switch manifest.typeToken": [],
        "typeToken.hasPrefix(": []
    ]

    /// The four bare per-type branch forms, each written so that EXACTLY ONE needle catches it.
    ///
    /// The uniqueness is the point. `if manifest.typeToken == MeshRoutedTypeToken.heart {` is caught
    /// by `"MeshRoutedTypeToken."` as well, so a fixture built on it would stay green with all four
    /// branch needles deleted. Each form here names a local instead, so the only thing that can catch
    /// it is its own needle.
    private static let routedTokenBranchForms: [String: String] = [
        "typeToken ==": "if manifest.typeToken == token {",
        "== manifest.typeToken": "if token == manifest.typeToken {",
        "switch manifest.typeToken": "switch manifest.typeToken {",
        "typeToken.hasPrefix(": "if manifest.typeToken.hasPrefix(prefix) {"
    ]

    /// The registry scanners themselves, fixtured — the matcher is the wall.
    ///
    /// Every fixture here drives a **shared** value, never a literal re-typed beside its own
    /// assertion: the construction cases run `MeshSessionStoreIsolationTests.constructionArguments`,
    /// and the needle cases run `Self.routedTokenNeedles`, the dictionary
    /// `noShippingCodeBranchesOnARoutedTypeToken` scans with. So deleting `"typeToken =="` from that
    /// dictionary, or widening `"fernlet.mesh.routed-type."`'s allowlist to admit the registry file,
    /// fails HERE rather than silently narrowing what wall 3 catches.
    ///
    /// The member scanner's blind spot is fixtured from both sides: a leading-dot `?? .increment1` is
    /// invisible to it (the negative), and the two shipping files that hold a registry value in a
    /// **default or fallback position** are asserted to spell the type out in full (the positive) —
    /// which is the only thing keeping the blind spot documented rather than occupied.
    @Test func theTypeRegistryScannersMatchAcrossLines() throws {
        let oneLine = "static let x = MeshRoutedTypeRegistry(entries: [row])"
        let wrapped = """
            static let x = MeshRoutedTypeRegistry(
                entries: [row]
            )
            """
        for (label, source) in [("one line", oneLine), ("wrapped", wrapped)] {
            #expect(
                MeshSessionStoreIsolationTests.constructionArguments(
                    of: "MeshRoutedTypeRegistry(", in: source
                ).count == 1,
                "the registry scanner missed a \(label) construction"
            )
        }
        let dotRead = "let y = MeshRoutedTypeRegistry.increment1.tokens"
        #expect(
            MeshSessionStoreIsolationTests.constructionArguments(
                of: "MeshRoutedTypeRegistry(", in: dotRead
            ).isEmpty,
            "the registry scanner counted a dot-member read as a construction"
        )
        try Self.expectTheMemberScannersBlindSpotIsStillEmpty()
        Self.expectTheWallsNeedlesStillDiscriminate()
    }

    /// The blind spot, both ways: the inferred form is invisible to the member scanner, and no
    /// shipping value-position read has moved into it.
    ///
    /// `MeshNetworkManager.swift` (the `routedTypes` fallback) and `MeshRoutedManifest.swift` (the
    /// mint's `types:` default) are the two places a registry value stands where a leading dot would
    /// compile — and where `shippingCodeNamesOneTypeRegistry` would then see nothing at all.
    private static func expectTheMemberScannersBlindSpotIsStillEmpty() throws {
        let inferred = "routedTypeRegistryForTesting ?? .increment1"
        #expect(inferred.components(separatedBy: "MeshRoutedTypeRegistry.").count == 1,
                "the member scanner's blind spot moved: an inferred member is now visible to it")
        let sources = try proximitySources()
        for name in ["MeshNetworkManager.swift", "MeshRoutedManifest.swift"] {
            let code = try #require(sources.first { $0.0 == name }?.1,
                                    "the sweep no longer reaches a file that holds a registry value")
            #expect(code.contains("MeshRoutedTypeRegistry.increment1"),
                    "\(name) shortened its registry value to a member the one-registry wall cannot see")
        }
    }

    /// Wall 3's needles, driven as data: each bare branch form is caught by exactly its own needle, a
    /// registry lookup is caught by none, and the raw literal's allowlist is still the ack file alone.
    private static func expectTheWallsNeedlesStillDiscriminate() {
        for (needle, form) in routedTokenBranchForms {
            #expect(routedTokenNeedles[needle]?.isEmpty == true,
                    "the wall dropped the per-type branch needle \(needle), or allowlisted a file for it")
            #expect(routedTokenNeedles.keys.filter { form.contains($0) } == [needle],
                    "the wall's needles no longer catch exactly one per-type branch form: \(form)")
        }
        let lookup = "routedTypes.entry(for: manifest.typeToken)"
        #expect(routedTokenNeedles.keys.contains { lookup.contains($0) } == false,
                "a registry lookup is being read as a per-type branch")
        let rawInRegistry = "let token = \"fernlet.mesh.routed-type.photo.v1\""
        #expect(routedTokenNeedles.keys.contains { rawInRegistry.contains($0) },
                "the raw-literal needle stopped matching a spelling written into a row")
        #expect(routedTokenNeedles["fernlet.mesh.routed-type."] == ["MeshRoutedAck.swift"],
                "the raw literal may now be typed straight into a registry row")
    }

    /// The ack-table scanner itself, fixtured BOTH ways — the wall's matcher is the wall.
    ///
    /// The wrapped form is the one the old `contains("MeshRoutedAckStageTable(rows:")` missed: a
    /// second policy written across two lines would have been invisible, and nothing else in the
    /// tree would have noticed.
    @Test func theAckStageTableScannerMatchesAcrossLines() {
        let oneLine = "static let x = MeshRoutedAckStageTable(rows: [row])"
        let wrapped = """
            static let x = MeshRoutedAckStageTable(
                rows: [row]
            )
            """
        let unrelated = "let y = MeshRoutedAckStageTable.increment1.stage(for: token)"
        for (label, source) in [("one line", oneLine), ("wrapped", wrapped)] {
            #expect(
                MeshSessionStoreIsolationTests.constructionArguments(
                    of: "MeshRoutedAckStageTable(", in: source
                ).count == 1,
                "the ack-table scanner missed a \(label) construction"
            )
        }
        #expect(
            MeshSessionStoreIsolationTests.constructionArguments(
                of: "MeshRoutedAckStageTable(", in: unrelated
            ).isEmpty,
            "the ack-table scanner counted a dot-member read as a construction"
        )
    }

    /// The ack path calls no decryption seam: a photo or a text is final on durable CIPHERTEXT, and
    /// the store never unwraps a content key.
    @Test func theAckPathNamesNoDecryptSeam() throws {
        let files = [
            "MeshRoutedAck.swift", "MeshRecipientReceipt.swift", "MeshRecipientReceiptVerifier.swift",
            "MeshRoutedDeliveryCommit.swift", "MeshRoutedDeliveryIngest.swift"
        ]
        for name in files {
            let code = MeshRoutedSourceScan.codeOnly(
                try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/\(name)")
            )
            #expect(code.contains("MeshRoutedContentKeyWrapper") == false, "\(name)")
            #expect(code.contains(".unwrap(") == false, "\(name)")
            #expect(code.contains("openKey()") == false, "\(name)")
        }
    }

    // MARK: - Scanner

    /// Every `.swift` file under ProximityKit, as `(filename, code-only source)`.
    private static func proximitySources() throws -> [(String, String)] {
        let root = RepoRoot.url("FernletKit/Sources/ProximityKit")
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        var sources: [(String, String)] = []
        // R2: bounded by the file list.
        for file in files.sorted(by: { $0.path < $1.path }) {
            sources.append((
                file.lastPathComponent,
                MeshRoutedSourceScan.codeOnly(try String(contentsOf: file, encoding: .utf8))
            ))
        }
        #expect(sources.count >= 8, "the ProximityKit sweep found only \(sources.count) files")
        return sources
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
}
