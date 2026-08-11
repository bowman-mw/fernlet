// PrivacyWipeCoverageTests.swift
// FernletTests
//
// Mechanical enforcement of Docs/PrivacyWipeCoverage.md (bitchat adoptions Increment 1): the
// "Delete everything" path must keep clearing every persistence surface in the manifest below.
// Grep-style source scan in the S3BoundaryTests house pattern — removing a wipe call, or landing
// a new store without wiring + documenting it, fails here. To add a store: add its wipe call in
// `FernletStore.deleteAllData`, a row in the doc, and its token here — same commit.
//
// The scan is bounded to the BODIES of `deleteAllData` and `resetAll` (its one delegated leg), with
// comments stripped. It used to scan the whole 4,000-line `FernletStore.swift`, which meant a row
// could be satisfied by the same call spelled in an unrelated function — deleting
// `clothingShop.clearAll()` from the wipe kept the suite green because
// `setAllowNearbyClothingShares` also calls it. Bounded, that deletion fails.
//
// VERIFY-BATCH NOTE: this file declares THREE top-level suites — `PrivacyWipeCoverageTests`
// (the source scan above), `PrivacyWipeMediaKeySurvivalTests`, and
// `PrivacyWipeAttemptMemoryRemovalTests` (both behavioral, real-funnel). xcodebuild's
// `-only-testing:` matches suite identifiers EXACTLY (no prefix matching), so a run scoped to
// `FernletTests/PrivacyWipeCoverageTests` alone silently skips the behavioral suites. Any verify
// batch or CI wiring re-baselining this file must name all three, and must confirm the intended
// `Test case` lines actually ran — never accept the success banner alone.

import Foundation
import Testing
import FernletPersistence
import LocalPersistence
import PrivateMediaStore
import CryptoKit
@testable import Fernlet

@Suite
struct PrivacyWipeCoverageTests {

    /// One token per row of the doc's "Cleared by Delete everything" table. Tokens are call-site
    /// spellings inside the bodies of `FernletStore.deleteAllData` and `resetAll`.
    private static let wipeManifest: [String] = [
        // Pending work & cloud
        "snapshotSaveCoordinator.cancelPending",
        "setSealedBackupEnabled",
        // The sealed-backup rollback high-water mark. The call site is two lines (`var
        // generationStore = SealedBackupGenerationStore()`, then `generationStore.reset()`), so the
        // token is the variable's spelling — the TYPE name never appears on the calling line and
        // could never work as a substring token (security-hardening P1b).
        "generationStore.reset",
        "cloudCopyDeleteHook",
        // Sealed narratives + buffers
        "periodDataDeleteHook",
        "intimacyDataDeleteHook",
        "journalDataDeleteHook",
        "pendingNarrativeBufferPurgeHook",
        // The residue half of the sealed wipe (P1a): the row hooks above empty the store, this
        // destroys and re-creates the FILE they lived in.
        "sealedStoreRebuildHook",
        // The opt-in HealthKit leg. The token is the HOOK's spelling, not the
        // `includingHealthKitSamples` parameter name — the parameter appears on the funnel's own
        // signature line (which the bounded scan includes by construction), so a parameter-named
        // token could never fail (security-hardening P1b, third gap of the generationStore class).
        "healthKitSampleDeleteHook",
        // Media
        "mealPhotoStore.deleteAll",
        "progressPhotoStore.deleteAll",
        "recipePhotoStore.deleteAll",
        "sharedRecipeImportQueue.clear",
        "purgeDataExports",
        // Social / proximity
        "clothingShop.clearAll",
        "sessionMessages.clear",
        "presenceManager.stop",
        "proximityTrustVault.apply",
        "heartLedger.clearAll",
        "moderationLedger.clearAll",
        "friendStateCache.clearAll",
        "closenessLedger.clearAll",
        "activities.clearAll",
        // Per-row + local stores
        "resetDiary",
        "savedRecipeService.reset",
        "customItemService.reset",
        "coinLedgerService.reset",
        "aiRetryQueueService.reset",
        "scrubStressLocalState",
        "worryBoxResetHook",
        "BarcodeServingMemory.clearAll",
        "RecipeWebImageAttemptMemory.clearAll",
        "guidedRunStateStore.clear",
        "cookingRunStateStore.clear",
        "clearSensitiveVisibilityResolution",
        "ageAssurance.clear",
        "repository.purgeAllPersistedData",
        // Widget / AI runtime
        "widgetSnapshotMirror",
        "pendingWidgetActionQueue.clear",
        "aiCallQuotaStore.reset",
        "aiAuditLogStore.clear",
        // Keychain identity + at-rest keys (the Increment 1 gap fixes)
        "wipeIdentityForDeleteAll",
        "deviceJournalKey",
        "deviceWorryKey",
        "invalidateEncryptionKeyCache",
        // Away-hearts dead-drop state (Increment 3): prekeys, peer bundles, outbox, dedup + the
        // service's own identity cache. The remote purge is a SEPARATE row because it must run
        // first — it needs the record names the local wipe destroys.
        "heartDropService.purgeDeadDrop",
        "heartDropService.wipeForDeleteAll",
        // Settings
        "storagePreferencesResetHook",
    ]

    /// Calls the wipe path must NEVER make, with the reason it is banned. The inverse of the
    /// manifest: some deletions are bugs, and a green manifest says nothing about them.
    ///
    /// `deleteKeychainRowForWipe` deletes the ONE shared `com.fernlet.private-media` keychain row
    /// that encrypts every `PrivateMediaStore` — including `MeshNetworkManager.photoCacheStore`,
    /// the friend photo wall this funnel keeps BY DESIGN. Deleting it doesn't orphan a key, it
    /// shreds the wall: the next `mediaKey()` mints a fresh random key and every retained photo
    /// decrypts to garbage, permanently and with no failure signal. See the deliberate-exceptions
    /// table in Docs/PrivacyWipeCoverage.md.
    private static let bannedFromWipePath: [(token: String, why: String)] = [
        (
            "deleteKeychainRowForWipe",
            "deletes the shared media key that the deliberately-kept friend photo wall is encrypted with — every retained photo would decrypt to garbage after the next launch"
        )
    ]

    /// The three managers whose live in-memory identity caches must die with the keychain rows.
    private static let identitySeamFiles = [
        "FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift",
        "FernletKit/Sources/ProximityKit/Presence/PresenceManager.swift",
        "FernletKit/Sources/ProximityKit/RecipeSharing/ProximityRecipeShareManager.swift",
    ]

    /// The two functions that together ARE the wipe path, keyed by a unique substring of their
    /// declaration line.
    private static let wipeFunctionSignatures = [
        "func deleteAllData(includingHealthKitSamples",
        "func resetAll() -> [String]"
    ]

    private static func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Fernlet/FernletStore.swift").path) {
                return url
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func fernletStoreSource() throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent("Fernlet/FernletStore.swift"), encoding: .utf8)
    }

    /// The comment-stripped bodies of the wipe functions, concatenated. Throws if either function
    /// cannot be located, so a rename fails loudly instead of scanning an empty string.
    private static func wipePathSource() throws -> String {
        let source = try fernletStoreSource()
        return try wipeFunctionSignatures.map { try functionBody(matching: $0, in: source) }.joined(separator: "\n")
    }

    /// Extracts one method body from `source`: from the declaration line down to the first line that
    /// is exactly the method-level closing brace. Every `FernletStore` method sits at one level of
    /// class indentation, so `"    }"` is an exact, unambiguous terminator — no brace counting, and
    /// nothing to get wrong on a nested closure. Comments are stripped line by line.
    static func functionBody(matching signature: String, in source: String) throws -> String {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains(signature) }) else {
            throw BoundingError.functionNotFound(signature)
        }
        guard let end = lines[(start + 1)...].firstIndex(of: "    }") else {
            throw BoundingError.closingBraceNotFound(signature)
        }
        return lines[start...end].map(strippingComments).joined(separator: "\n")
    }

    enum BoundingError: Error, CustomStringConvertible {
        case functionNotFound(String)
        case closingBraceNotFound(String)
        case malformedCoverageDoc(String)

        var description: String {
            switch self {
            case .functionNotFound(let signature):
                return "Could not find '\(signature)' in FernletStore.swift — renamed? The wipe-coverage scan is bounded to it."
            case .closingBraceNotFound(let signature):
                return "Could not find the method-level closing brace after '\(signature)' — indentation changed?"
            case .malformedCoverageDoc(let detail):
                return "Docs/PrivacyWipeCoverage.md no longer parses as the reverse-direction check expects: \(detail)"
            }
        }
    }

    /// Drops a `//` comment tail so a token surviving only in prose (or in commented-out code) can't
    /// satisfy the manifest. `://` is left alone — that is a URL inside a string literal, not a
    /// comment.
    static func strippingComments(_ line: String) -> String {
        let characters = Array(line)
        var index = 0
        while index + 1 < characters.count {
            if characters[index] == "/", characters[index + 1] == "/" {
                if index > 0, characters[index - 1] == ":" {
                    index += 2
                    continue
                }
                return String(characters[0..<index])
            }
            index += 1
        }
        return line
    }

    @Test func deleteAllCoversEveryManifestSurface() throws {
        let wipePath = try Self.wipePathSource()
        let missing = Self.wipeManifest.filter { !wipePath.contains($0) }
        #expect(missing.isEmpty, "Wipe calls missing from the deleteAllData/resetAll bodies for: \(missing) — either restore the call or move the surface to the doc's deliberate-exceptions table AND remove its token here.")
    }

    /// The scan really is bounded, and really does ignore comments — otherwise the test above is the
    /// whole-file scan it replaced, and a deleted wipe call keeps passing.
    @Test func theScanIsBoundedToTheWipePathAndIgnoresComments() throws {
        let wipePath = try Self.wipePathSource()
        let wholeFile = try Self.fernletStoreSource()

        // Bounded: `setAllowNearbyClothingShares` also calls `clothingShop.clearAll()`, which is how
        // the old whole-file scan stayed green with the wipe's own call deleted.
        #expect(wholeFile.contains("func setAllowNearbyClothingShares"))
        #expect(!wipePath.contains("setAllowNearbyClothingShares"), "the scan reaches outside the wipe path — manifest rows can be satisfied by unrelated functions")
        #expect(wipePath.count < wholeFile.count / 3, "the extracted wipe path is implausibly large — the bounding is not bounding")

        // Comment-stripped: prose about a wipe call is not a wipe call.
        #expect(Self.strippingComments("        // heartLedger.clearAll()").trimmingCharacters(in: .whitespaces).isEmpty)
        #expect(Self.strippingComments("        heartLedger.clearAll()  // takes the sidecar").contains("heartLedger.clearAll()"))
        #expect(Self.strippingComments(#"let u = "https://example.com""#).contains("example.com"))
    }

    /// The extractor, on a synthetic source — so a failure above points at the wipe path, not at the
    /// bounding logic.
    @Test func functionBodyExtractionStopsAtTheMethodBrace() throws {
        let source = """
        final class Thing {
            func wipe() {
                if flag {
                    inside()
                }
            }

            func other() {
                outside()
            }
        }
        """
        let body = try Self.functionBody(matching: "func wipe()", in: source)
        #expect(body.contains("inside()"))
        #expect(!body.contains("outside()"))
        #expect(throws: (any Error).self) { try Self.functionBody(matching: "func missing()", in: source) }
    }

    /// The banned-call check: a wipe call that DESTROYS a deliberately-kept surface must not come
    /// back. The manifest can't express this — it only ever asserts presence.
    @Test func wipePathMakesNoBannedCall() throws {
        let wipePath = try Self.wipePathSource()
        for banned in Self.bannedFromWipePath {
            #expect(!wipePath.contains(banned.token), "\(banned.token) is back in the wipe path: it \(banned.why).")
        }
    }

    @Test func everyLiveIdentityCacheHasAWipeSeam() throws {
        let root = try Self.repoRoot()
        for file in Self.identitySeamFiles {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            #expect(source.contains("func wipeIdentityForDeleteAll"), "\(file) owns a live IdentityService but lost its wipe seam.")
        }
    }

    /// The rebuild hook is nil-tolerant in the funnel (an unwired TEST store must not report a
    /// failed wipe), so the PRODUCTION wiring is what needs a mechanical guard: without this, the
    /// manifest row above stays green while the app never rebuilds anything.
    @Test func theSealedStoreRebuildIsWiredInTheApp() throws {
        let root = try Self.repoRoot()
        let contentView = try String(contentsOf: root.appendingPathComponent("Fernlet/ContentView.swift"), encoding: .utf8)
        #expect(
            contentView.contains("store.sealedStoreRebuildHook ="),
            "the sealed-store rebuild is no longer wired in ContentView — the funnel's hook is nil in production, so 'delete everything' leaves the store file (and its -wal residue) intact."
        )
        #expect(
            contentView.contains("rebuildStore()"),
            "the wired rebuild hook no longer calls PrivatePersistenceController.rebuildStore()."
        )
    }

    /// The reversibility trap (Opus track §6): every deletion path must run while the app is
    /// LOCKED, so the rebuild must never acquire, use, or re-wrap a content key. A grep, because
    /// this is a property of the code's shape — a behavioral test can only show that today's
    /// callers happen not to need a key.
    @Test func theSealedStoreRebuildIsKeyless() throws {
        let root = try Self.repoRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("FernletKit/Sources/PrivateStoreCore/PrivatePersistenceController.swift"),
            encoding: .utf8
        )
        let body = try Self.functionBody(matching: "public func rebuildStore() throws", in: source)
        for token in ["contentKey", "decrypt", "ColumnCrypto", "unwrap", "SymmetricKey"] {
            #expect(!body.contains(token), "rebuildStore() names '\(token)': the rebuild must stay keyless or deleting data starts requiring the ability to read it.")
        }
        // And it really did find a body — an empty string trivially contains no token.
        #expect(body.contains("destroyPersistentStore"), "rebuildStore() no longer destroys the store file — the scan above is scanning the wrong function.")

        // The recovery half of the rebuild is on the same locked path, so it inherits the same
        // invariant: healing a storeless coordinator must never need a key either.
        let recovery = try Self.functionBody(matching: "public func reloadStoreIfNeeded() throws", in: source)
        for token in ["contentKey", "decrypt", "ColumnCrypto", "unwrap", "SymmetricKey"] {
            #expect(!recovery.contains(token), "reloadStoreIfNeeded() names '\(token)': the sealed-store recovery must stay keyless.")
        }
        #expect(recovery.contains("addStore"), "reloadStoreIfNeeded() no longer re-adds the store — the scan above is scanning the wrong function.")
    }

    /// No-storeless-app invariant, mechanically. A rebuild that leaves the coordinator with zero
    /// persistent stores is worse than the residue it exists to remove: every sealed write fails for
    /// the rest of the process, and `JournalSealingCoordinator` deliberately keeps a failed seal's
    /// PLAINTEXT in the days blob, which mirrors to iCloud when sync is on. Three guards, all of
    /// which have been missing at some point: the detach must not bail out mid-sequence, the re-add
    /// must retry, and the app must call the self-heal on foreground.
    @Test func theSealedStoreRebuildCannotLeaveTheAppStoreless() throws {
        let root = try Self.repoRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("FernletKit/Sources/PrivateStoreCore/PrivatePersistenceController.swift"),
            encoding: .utf8
        )
        let body = try Self.functionBody(matching: "public func rebuildStore() throws", in: source)
        #expect(
            body.contains("removeFailure = error"),
            "the detach is back to an unguarded `try`: a throw there exits before the re-add and leaves the coordinator with no store at all. Capture, continue, report."
        )
        #expect(
            body.contains("guard coordinator.persistentStores.isEmpty"),
            "rebuildStore() no longer checks that the store actually detached before destroying its file."
        )
        #expect(
            body.contains("try addStore(at: storeURL, description: description)"),
            "rebuildStore() no longer re-adds through the shared add path."
        )
        #expect(
            source.contains("public func reloadStoreIfNeeded() throws"),
            "the sealed-store self-heal is gone — a failed re-add would persist for the whole session with nothing to recover it."
        )
        #expect(
            source.contains("public var isStoreLoaded: Bool"),
            "the storeless state is undetectable again: nothing in the app reads PrivatePersistenceController.didFailToLoad."
        )

        let app = try String(contentsOf: root.appendingPathComponent("Fernlet/FernletApp.swift"), encoding: .utf8)
        #expect(
            app.contains("reloadStoreIfNeeded()"),
            "FernletApp no longer heals the sealed store on foreground — the dominant failure (the device auto-locking mid-wipe) would never recover."
        )

        // The uncatchable-crash guard: a save against a storeless coordinator raises an ObjC
        // exception no `catch` in the repositories can see. Every sealed writer must go through
        // `saveSealed()`, which turns it into a Swift error.
        for repository in [
            "FernletKit/Sources/PrivateMemoryStore/JournalNarrativeRepository.swift",
            "FernletKit/Sources/PrivateMemoryStore/WorryNarrativeRepository.swift",
            "FernletKit/Sources/PrivateHealthStore/IntimacyLogRepository.swift",
            "FernletKit/Sources/PrivateHealthStore/MenstrualNarrativeRepository.swift",
            "FernletKit/Sources/PrivateStoreCore/PrivateRowPlumbing.swift"
        ] {
            let repositorySource = try String(contentsOf: root.appendingPathComponent(repository), encoding: .utf8)
            #expect(
                !repositorySource.contains("try context.save()"),
                "\(repository) saves the sealed context with a bare save(): against a storeless coordinator that is an uncatchable SIGABRT, not a throw. Use saveSealed()."
            )
        }
    }

    /// `reset()`'s "fully honest — crypto-erased" tier is only true if EVERY key that seals a byte in
    /// the private store dies with it. Two of the four sealed entities (journal, Worry Box) are
    /// sealed under device fallback keys in a different keychain service whenever the lock is closed,
    /// so the single lock-service sweep was not enough. Behavioral coverage lives in
    /// `FernletLockServiceTests.resetDestroysEverySealedContentKeyNotJustTheLockService`; this pins
    /// the shape so the sweep cannot be refactored out while the docs keep the claim.
    @Test func resetSweepsTheSealedContentKeyServicesItsDocsClaim() throws {
        let root = try Self.repoRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("FernletKit/Sources/FernletLock/FernletLockService.swift"),
            encoding: .utf8
        )
        let body = try Self.functionBody(matching: "public func reset() throws", in: source)
        #expect(
            body.contains("for service in sealedContentKeyServices"),
            "reset() stopped sweeping the journal/Worry Box device keys, but Docs/PrivacyWipeCoverage.md still calls it crypto-erased."
        )
        #expect(
            source.contains("public let sealedContentKeyServices: [String]"),
            "the sweep is no longer injectable — a test's reset() would destroy the simulator's real sealed-content keys."
        )
        let doc = try String(contentsOf: root.appendingPathComponent("Docs/PrivacyWipeCoverage.md"), encoding: .utf8)
        #expect(doc.contains("sealedContentKeyServices"), "the wipe-coverage doc no longer documents the sealed-content key sweep.")
    }

    /// The in-memory seam still has to exist: the emptied meal/progress/recipe stores drop their
    /// cached key at the wipe. (The keychain ROW is a documented survivor — see
    /// `wipePathMakesNoBannedCall` and the deliberate-exceptions table.)
    @Test func mediaKeyCacheWipeSeamExists() throws {
        let root = try Self.repoRoot()
        let keyStore = try String(
            contentsOf: root.appendingPathComponent("FernletKit/Sources/PrivateMediaStore/PrivateMediaKeyStore.swift"),
            encoding: .utf8
        )
        #expect(keyStore.contains("func invalidateCachedKey"))
    }

    @Test func coverageDocExistsWithExceptionsTable() throws {
        let root = try Self.repoRoot()
        let doc = try String(contentsOf: root.appendingPathComponent("Docs/PrivacyWipeCoverage.md"), encoding: .utf8)
        #expect(doc.contains("Deliberate exceptions"), "The wipe-coverage doc lost its deliberate-exceptions section.")
        // Every manifest token should be findable in the doc so the two stay in sync.
        let undocumented = Self.wipeManifest.filter { !doc.contains($0) }
        #expect(undocumented.isEmpty, "Tokens enforced here but not documented in PrivacyWipeCoverage.md: \(undocumented)")
    }

    /// The reverse direction of `coverageDocExistsWithExceptionsTable`, which checks manifest → doc
    /// only. Without this half, a documented-but-unenforced row is invisible: a "Wiped by" entry
    /// whose call was deleted — or whose spelling never worked as a token, like the two-line
    /// `SealedBackupGenerationStore` call site the P1b audit found — leaves the doc promising a
    /// wipe nothing checks. Every row of the cleared-by table must name a token this file's
    /// manifest enforces; the deliberate-exceptions table is skipped by construction, because
    /// parsing is bounded to the cleared-by section (it stops at the next `##` heading).
    @Test func everyDocumentedWipeRowIsEnforcedByTheManifest() throws {
        let root = try Self.repoRoot()
        let doc = try String(contentsOf: root.appendingPathComponent("Docs/PrivacyWipeCoverage.md"), encoding: .utf8)
        let tokens = try Self.clearedByTableTokens(in: doc)
        // A parse that finds almost nothing is a broken parse, not a small table.
        #expect(tokens.count >= 40, "only \(tokens.count) rows parsed from the cleared-by table — the doc's layout changed and this check is no longer reading it.")
        let unenforced = tokens.filter { !Self.wipeManifest.contains($0) }
        #expect(unenforced.isEmpty, "Documented in the cleared-by table but not enforced by wipeManifest: \(unenforced) — add each token to the manifest (with its call really in the funnel), or move the surface to the deliberate-exceptions table.")
    }

    /// The first backticked span of each row's "Wiped by" column in the doc's "Cleared by Delete
    /// everything" table — the token, by the table's own convention. First span only, because rows
    /// decorate their token with prose that may itself carry code spans ("runs LAST in
    /// `resetAll`…"). Bounded to that one section so the deliberate-exceptions and honesty-tier
    /// tables are never parsed as wipe promises, and strict about shape: a row that stops splitting
    /// into exactly three columns, or loses its backticked token, throws rather than being silently
    /// skipped.
    static func clearedByTableTokens(in doc: String) throws -> [String] {
        guard let sectionStart = doc.range(of: "## Cleared by Delete everything") else {
            throw BoundingError.malformedCoverageDoc("the '## Cleared by Delete everything' heading is gone")
        }
        let tail = doc[sectionStart.upperBound...]
        let section = tail.range(of: "\n## ").map { tail[..<$0.lowerBound] } ?? tail

        var tokens: [String] = []
        for line in section.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Prose is any line with no pipe at all. GFM makes the LEADING pipe optional, so a
            // pipe-bearing line without one still renders as a table row — skipping it silently
            // would hide that row from this check, so it throws instead.
            guard trimmed.contains("|") else { continue }
            guard trimmed.hasPrefix("|") else {
                throw BoundingError.malformedCoverageDoc("a pipe-containing line in the cleared-by section lacks its leading pipe (GFM renders it as a row, this parser would skip it): \(trimmed)")
            }
            let columns = trimmed.components(separatedBy: "|")
            // The header row and its `---` separator are structure, not rows — detected by SHAPE
            // (exact header cell / dash-only cells), never by substring, so a data row whose prose
            // happens to contain "---" or the header words can't be silently dropped.
            if columns.count >= 2, columns[1].trimmingCharacters(in: .whitespaces) == "Surface" { continue }
            let interior = columns.dropFirst().dropLast()
            if !interior.isEmpty, interior.allSatisfy({ cell in
                let content = cell.trimmingCharacters(in: .whitespaces)
                return content.contains("-") && content.allSatisfy { $0 == "-" || $0 == ":" }
            }) { continue }
            // "| a | b | c |" splits into ["", " a ", " b ", " c ", ""] — the wiped-by cell is [3].
            guard columns.count == 5 else {
                throw BoundingError.malformedCoverageDoc("a cleared-by row does not have exactly three columns: \(trimmed)")
            }
            let wipedBy = columns[3]
            guard let open = wipedBy.firstIndex(of: "`"),
                  case let afterOpen = wipedBy.index(after: open),
                  let close = wipedBy[afterOpen...].firstIndex(of: "`") else {
                throw BoundingError.malformedCoverageDoc("a cleared-by row has no backticked token in its 'Wiped by' column: \(trimmed)")
            }
            tokens.append(String(wipedBy[afterOpen..<close]))
        }
        return tokens
    }

    /// Every `com.fernlet.*` keychain service the app uses must be named in one of the two tables —
    /// that is the doc's stated contract, and two services (the HealthKit anchors and the
    /// locked-note buffer key) used to be in neither.
    @Test func everyKeychainServiceIsDocumented() throws {
        let root = try Self.repoRoot()
        let doc = try String(contentsOf: root.appendingPathComponent("Docs/PrivacyWipeCoverage.md"), encoding: .utf8)

        var services: Set<String> = []
        for sourceRoot in ["Fernlet", "FernletKit/Sources"] {
            let rootURL = root.appendingPathComponent(sourceRoot)
            guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                services.formUnion(Self.keychainServiceLiterals(in: source))
            }
        }

        // Discovery is name-anchored, so a service declared without "service" in its binding would be
        // missed silently. The floor makes that a loud failure instead (S3BoundaryTests house pattern).
        let missingFromDiscovery = Self.knownKeychainServices.subtracting(services).sorted()
        #expect(missingFromDiscovery.isEmpty, "Keychain-service discovery lost: \(missingFromDiscovery) — renamed, moved, or bound to something that isn't spelled '…service'.")

        let undocumented = services.filter { !doc.contains($0) }.sorted()
        #expect(undocumented.isEmpty, "Keychain services in neither wipe-coverage table: \(undocumented) — add each to the cleared table (with its wipe call) or to the deliberate-exceptions table (with why it survives).")
    }

    /// The services that exist today. A floor, not a whitelist: discovery still reports anything NEW,
    /// and that new service must be documented before this suite goes green.
    private static let knownKeychainServices: Set<String> = [
        "com.fernlet.lock", "com.fernlet.storage-preferences", "com.fernlet.journal",
        "com.fernlet.healthkit-anchors", "com.fernlet.private-media", "com.fernlet.narrative-buffer",
        "com.fernlet.heartdrop", "com.fernlet.identity", "com.fernlet.moderation",
        "com.fernlet.device-binding"
    ]

    /// `com.fernlet.*` keychain SERVICE literals in `source`, found by anchoring on the binding that
    /// consumes them — a `…service`-named constant or a `service:`/`keychainService:` parameter. That
    /// anchor is what separates a service from the per-item ACCOUNT names sharing its prefix
    /// (`com.fernlet.lock.salt`, `com.fernlet.private-media.contentKey`), from UserDefaults keys, and
    /// from the `com.fernlet.sealed-backup` HKDF label — none of which are keychain services.
    /// Literal-based because the constants are private/internal to their modules: nothing to import.
    static func keychainServiceLiterals(in source: String) -> Set<String> {
        let pattern = try? NSRegularExpression(pattern: #"ervice[^"\n]{0,24}"(com\.fernlet\.[^"]*)""#)
        guard let pattern else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        var found: Set<String> = []
        for match in pattern.matches(in: source, range: range) {
            guard let literalRange = Range(match.range(at: 1), in: source) else { continue }
            let literal = String(source[literalRange])
            // Suites scope their fixtures as "com.fernlet.identity.test.<uuid>".
            if !literal.contains(".test.") { found.insert(literal) }
        }
        return found
    }
}

/// The behavioral half of FIX 1: the shared at-rest media key must SURVIVE "delete everything", or
/// the friend photo wall the dialog promises to keep becomes unreadable noise on the next launch.
///
/// Separate suite because it drives a real `FernletStore` through the real funnel (the source scans
/// above are pure). The `.serialized` trait is declared for symmetry with `DeleteAllDataTests`, but
/// be honest about what it buys: it serializes tests WITHIN a suite only, so on this one-test suite
/// it is inert, and it provides no cross-SUITE exclusion in any case — a live wipe here CAN
/// interleave at its await points with wipes running in the other suites. That is a latent hazard,
/// accepted for now (P1b, comment-only): the wipes touch process-wide keychain + preferences state,
/// and what actually keeps these suites from corrupting each other today is per-test fixtures
/// (fresh repository files, injected defaults), not scheduling.
@MainActor
@Suite(.serialized)
struct PrivacyWipeMediaKeySurvivalTests {

    private func keyBytes(_ key: SymmetricKey?) -> Data? {
        key.map { $0.withUnsafeBytes { Data($0) } }
    }

    @Test func deleteAllKeepsTheSharedMediaKeySoTheKeptPhotoWallStaysReadable() async {
        // Mint (or read) BOTH rows of the Phase-5 media-key split. The friend row is the one the
        // kept photo wall decrypts under; the own row is kept too (owner decision) — its STORES are
        // emptied by the wipe instead, so the key protects nothing, while deleting it would
        // reintroduce the same stale-cache hazard for anything captured between wipe and relaunch.
        let before = keyBytes(KeychainPrivateMediaKeyProvider(role: .friendWall).mediaKey())
        let ownBefore = keyBytes(KeychainPrivateMediaKeyProvider(role: .ownPhotos).mediaKey())
        #expect(before != nil, "precondition: could not read or mint the shared media key")
        #expect(ownBefore != nil, "precondition: could not read or mint the own-photo media key")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wipe-media-key-\(UUID().uuidString).json")
        let store = FernletStore(repository: LocalFernletRepository(fileURL: url))
        await store.deleteAllData(includingHealthKitSamples: false)

        // A FRESH provider holds no cached key, so this is the next launch reading the keychain —
        // exactly the path that used to mint a brand-new key and strand every retained photo.
        let after = keyBytes(KeychainPrivateMediaKeyProvider(role: .friendWall).mediaKey())
        #expect(
            after == before,
            "the wipe destroyed the shared media key: every photo on the deliberately-kept friend photo wall now decrypts to garbage"
        )
        let ownAfter = keyBytes(KeychainPrivateMediaKeyProvider(role: .ownPhotos).mediaKey())
        #expect(
            ownAfter == ownBefore,
            "the wipe destroyed the own-photo media key, so anything captured before relaunch would seal under a key that no longer exists"
        )
    }
}

/// The behavioral half of the `RecipeWebImageAttemptMemory.clearAll` manifest row (security-hardening
/// P0c): the device-local "one automatic web-image attempt per recipe" `UserDefaults` sidecar must be
/// REMOVED by "delete everything" — the reverse direction of `PrivacyWipeMediaKeySurvivalTests`, which
/// asserts survival of a deliberately-kept surface.
///
/// Separate suite for the same reason as the media-key one: it drives a real `FernletStore` through the
/// real `deleteAllData` funnel (the source scans above are pure). The `.serialized` trait is inert here
/// too — one test, and no cross-suite exclusion either way (see the note on
/// `PrivacyWipeMediaKeySurvivalTests`); what actually isolates this test is its own injected
/// `UserDefaults` suite (`webImageAttemptDefaults`), not scheduling.
@MainActor
@Suite(.serialized)
struct PrivacyWipeAttemptMemoryRemovalTests {

    @Test func deleteAllClearsTheRecipeWebImageAttemptMemory() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wipe-attempt-memory-\(UUID().uuidString).json")
        let store = FernletStore(repository: LocalFernletRepository(fileURL: url))
        // Isolate the sidecar from the shared `.standard` suite (the injection seam exists for
        // exactly this — see `webImageAttemptDefaults`); record + wipe still share ONE instance,
        // which is the contract the manifest token documents.
        let suiteName = "fernlet-tests-wipe-attempt-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.webImageAttemptDefaults = defaults

        let recipeID = UUID()
        RecipeWebImageAttemptMemory.recordAttempt(recipeID, defaults: store.webImageAttemptDefaults)
        #expect(RecipeWebImageAttemptMemory.hasAttempted(recipeID, defaults: store.webImageAttemptDefaults),
                "precondition: the attempt was not recorded")

        await store.deleteAllData(includingHealthKitSamples: false)

        #expect(
            !RecipeWebImageAttemptMemory.hasAttempted(recipeID, defaults: store.webImageAttemptDefaults),
            "delete everything left the web-image attempt bookkeeping behind — the sidecar outlived the recipes it described"
        )
    }
}
