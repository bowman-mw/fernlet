// PrivacyWipeCoverageTests.swift
// FernletTests
//
// Mechanical enforcement of Docs/PrivacyWipeCoverage.md (bitchat adoptions Increment 1): the
// "Delete everything" path must keep clearing every persistence surface in the manifest below.
// Grep-style source scan in the S3BoundaryTests house pattern — removing a wipe call, or landing
// a new store without wiring + documenting it, fails here. To add a store: add its wipe call in
// `FernletStore.deleteAllData`, a row in the doc, and its token here — same commit.
//
// The scan is bounded to the BODIES of the funnel and its numbered legs, with comments stripped. It
// used to scan the whole 4,000-line `FernletStore.swift`, which meant a row could be satisfied by
// the same call spelled in an unrelated function — deleting `clothingShop.clearAll()` from the wipe
// kept the suite green because `setAllowNearbyClothingShares` also calls it. Bounded, that deletion
// fails.
//
// 2026-08-20 — the scan gained two properties it was missing:
//   • It also covers `ContentView.attachDeleteAllHooks` / `attachCloudDeleteAllHooks`. Several real
//     clears live inside those hook closures, and a `FernletStore`-only scan could not see a hook
//     that stopped being wired.
//   • `everyPrivateWipeHelperIsRegistered` closes the evasion the bounding itself created: only
//     REGISTERED bodies are scanned, so a banned call moved into a new, unregistered private leg
//     was invisible. Every private helper the wipe path calls must now be registered.
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
    ///
    /// Internal, not private, because it is **shared with `PersistedSurfaceWipeBoundaryTests`** (Part
    /// 4.4): a `.cleared` disposition over there must name a token this manifest already enforces, so
    /// the discovery wall can never certify a clear that this wall does not also pin. Read-only from
    /// there — the widening is access only, no behaviour change.
    static let wipeManifest: [String] = [
        // Pending work & cloud
        "snapshotSaveCoordinator.cancelPending",
        "setSealedBackupEnabled",
        // The sealed-backup rollback high-water mark. The call site is two lines (`var
        // generationStore = SealedBackupGenerationStore()`, then `generationStore.reset()`), so the
        // token is the variable's spelling — the TYPE name never appears on the calling line and
        // could never work as a substring token (security-hardening P1b).
        "generationStore.reset",
        // The own-photo escrow route (Phase 5, step 5b). Its own token because it is NOT a
        // `SealedBackupPayloadType`: the `allCases` loop above cannot reach it, and a route the
        // manifest does not name is a backup "delete everything" would leave in iCloud.
        "deleteOwnPhotoEscrowBackups",
        "cloudCopyDeleteHook",
        // The LEGACY direct-CloudKit records (2026-08-20). Its own token, and unconditional in the
        // funnel, because neither cloud leg above reaches it: `cloudCopyDeleteHook` runs only on
        // "stop syncing, keep the copy", and a live sync deletes the server copy by PROPAGATING the
        // local row deletes — which `NSPersistentCloudKitContainer` can do only for the `CD_`-prefixed
        // types it wrote. A bare-named record has no local row to propagate from.
        "legacyCloudRecordDeleteHook",
        // …and the service call the hook is wired to, pinned through the ContentView half of the
        // scan (see `wipePathSource`): the hook alone would stay green if `attachCloudDeleteAllHooks`
        // stopped wiring it.
        "deleteLegacyDirectCloudKitRecords",
        // Sealed narratives + buffers
        "periodDataDeleteHook",
        "intimacyDataDeleteHook",
        "journalDataDeleteHook",
        "pendingNarrativeBufferPurgeHook",
        // The residue half of the sealed wipe (P1a): the row hooks above empty the store, this
        // destroys and re-creates the FILE they lived in.
        "sealedStoreRebuildHook",
        // The same residue pass for the MAIN (synced) store, added 2026-08-20 — until then the day
        // rows were row-deleted only, so their page images stayed in the database file. Separate
        // mechanism, not just a separate hook: this file carries the CloudKit mirror's pending
        // export queue in its persistent history, so it is checkpointed and vacuumed, never
        // destroyed. The second token pins the wiring through the ContentView half of the scan.
        "mainStoreRebuildHook",
        "compactStoreAfterWipe",
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
        // The peer half of the moderation ban store: 30-day bans keyed to OTHER designers'
        // fingerprints. The SELF-ban row in the same keychain service is a deliberate survivor
        // (2026-07-17), which is why the token names the peer-scoped call and not a service sweep.
        "moderationBanStore.clearPeerBansForDeleteAll",
        // Per-row + local stores
        "resetDiary",
        "savedRecipeService.reset",
        // The pre-Core-Data `SavedRecipes.json` file. Its own token beside the per-row reset above:
        // the migration latch survives the wipe by design, so nothing re-reads the file — but until
        // 2026-08-20 nothing deleted it either, and it holds plaintext recipe text.
        "LegacySavedRecipeJSONRepository().deleteFile",
        "customItemService.reset",
        "coinLedgerService.reset",
        // The milestone ledger stopped being a deliberate survivor on 2026-08-20: it is a dated
        // trail of WHEN the destroyed content happened, and it mirrors to the user's CloudKit
        // private database. The token is the service call; the row delete rides its closure.
        "milestoneLedgerService.reset",
        "aiRetryQueueService.reset",
        "scrubStressLocalState",
        "worryBoxResetHook",
        "BarcodeServingMemory.clearAll",
        "RecentActivityTypeMemory.clearAll",
        "RecipeWebImageAttemptMemory.clearAll",
        // The workout tombstone ring. Not only privacy: a surviving tombstone tells the workout
        // observer to DELETE a still-existing app-authored Health sample on the next re-enable,
        // which would override an explicit "keep my Health samples" answer at the wipe.
        "workoutTombstones.clearAll",
        "guidedRunStateStore.clear",
        "cookingRunStateStore.clear",
        "clearSensitiveVisibilityResolution",
        // The custom exercise catalog (imported from a coach plan). Its own token even though
        // `resetDiary` already clears `settings.customExercises`, because `WorkoutExerciseCatalog` is
        // a PROCESS-GLOBAL registry: without the re-publish a deleted exercise stays live in the
        // picker, the safety filter and the planning engine until the app is relaunched — a wipe the
        // user can still see the results of.
        "syncCustomExerciseCatalog",
        "ageAssurance.clear",
        "repository.purgeAllPersistedData",
        // Widget / AI runtime
        "widgetSnapshotMirror",
        "pendingWidgetActionQueue.clear",
        "aiCallQuotaStore.reset",
        "aiAuditLogStore.clear",
        // The record of which Apple Health prompts have ever been shown — `cycleTracking` and
        // `intimateLogging` among them. A plaintext `UserDefaults` array cleared by nothing until
        // 2026-08-20; now a device-only keychain row with a real failure signal.
        "HealthCapabilityRequestLedger.clear",
        // Companion petting counts + window/settle timestamps. `clearPersistentState` existed and
        // its only caller was a `#if DEBUG` UI-test seam, so RELEASE never cleared it.
        "PetInteractionGovernor.clearPersistentState",
        // Keychain identity + at-rest keys (the Increment 1 gap fixes)
        "wipeIdentityForDeleteAll",
        // The consequence of the row above, and the reason it is a separate token: rotating the
        // proximity identity makes a duress recovery blob unopenable by ANY device, while this
        // funnel deliberately keeps the app lock, the content key and the enrollment rows. Without
        // the reconcile the phone keeps `DuressMode.recoveryLock` armed over a dead blob, and firing
        // it destroys every local unlock key for a ceremony that can only fail.
        "identityRotatedHook",
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

    /// The functions that together ARE the wipe path, keyed by a unique substring of their
    /// declaration line.
    ///
    /// `deleteAllData` is the ordered funnel; the `…ForWipe` / `delete…` / `clear…` helpers below are
    /// its numbered legs, split out of the funnel body for the Power-of-10 60-line rule (R4) — the
    /// wipe path is the funnel PLUS every leg it calls, so the scan must cover all of them or a
    /// deleted wipe call inside a leg would go unnoticed.
    private static let wipeFunctionSignatures = [
        "func deleteAllData(includingHealthKitSamples",
        "func stopWritersForWipe()",
        "func deleteSealedCloudBackups(",
        "func deleteSealedRows(",
        "func deleteHealthSamplesIfRequested(",
        "func deletePhotoCorpora(",
        "func clearInboxesAndExports(",
        "func clearDeviceLocalLedgers(",
        "func rotateProximityIdentityAndPurgeDeadDrop(",
        "func resetAll() -> [String]"
    ]

    /// The `ContentView` half of the wipe path: five real clears live inside the hook closures
    /// wired here (the sealed row deletes, the locked-note buffer purge, the two store rebuilds,
    /// the HealthKit sweep and both direct-CloudKit sweeps), and a scan bounded to `FernletStore`
    /// cannot see any of them — a hook could stop being wired with every token still green.
    /// Scanning them makes hook-side spellings usable as manifest tokens.
    private static let hookWiringFunctionSignatures = [
        "func attachDeleteAllHooks()",
        "func attachCloudDeleteAllHooks()"
    ]

    /// Private `FernletStore` helpers the wipe path calls that are deliberately NOT registered
    /// above, with the reason. Everything else must be registered — see
    /// `everyPrivateWipeHelperIsRegistered`, which is what stops a banned call being smuggled into
    /// an unscanned leg.
    private static let unregisteredWipeHelpers: [(name: String, why: String)] = [
        (
            "hasSealedBackup",
            "a pure predicate over StoragePreferences — it reads four Bools and touches no store, so there is nothing in it for a banned call to be hidden behind"
        ),
        (
            "clearSensitiveVisibilityResolution",
            "registering it would let its own manifest token be satisfied by its declaration line (the extractor includes it), making the token unfalsifiable — the P1b defect class. It removes three UserDefaults keys and calls nothing"
        )
    ]

    private static func fernletStoreSource() throws -> String {
        try String(contentsOf: RepoRoot.url.appendingPathComponent("App/Fernlet/FernletStore.swift"), encoding: .utf8)
    }

    private static func contentViewSource() throws -> String {
        try String(contentsOf: RepoRoot.url.appendingPathComponent("App/Fernlet/ContentView.swift"), encoding: .utf8)
    }

    /// The comment-stripped bodies of the wipe functions, concatenated. Throws if any function
    /// cannot be located, so a rename fails loudly instead of scanning an empty string.
    ///
    /// Internal, not private, because it is **shared with `PersistedSurfaceWipeBoundaryTests`** (Part
    /// 4.4), which resolves its `.cleared` tokens against exactly this text (after also stripping
    /// `#if DEBUG` branches). One definition of "the wipe path" for both walls, so they cannot
    /// disagree about what the funnel is. Access-only widening — no behaviour change.
    static func wipePathSource() throws -> String {
        try storeWipePathSource() + "\n" + hookWiringSource()
    }

    /// The `FernletStore` half only — the funnel and its numbered legs. Kept separate because the
    /// private-helper wall below is a property of the store's own methods.
    private static func storeWipePathSource() throws -> String {
        let source = try fernletStoreSource()
        return try wipeFunctionSignatures.map { try functionBody(matching: $0, in: source) }.joined(separator: "\n")
    }

    private static func hookWiringSource() throws -> String {
        let source = try contentViewSource()
        return try hookWiringFunctionSignatures.map { try functionBody(matching: $0, in: source) }.joined(separator: "\n")
    }

    /// Extracts one method body from `source`: from the declaration line down to the first
    /// method-level closing brace. Every `FernletStore` method sits at one level of type
    /// indentation, so a `}` at exactly four spaces is an unambiguous terminator — no brace
    /// counting, and nothing to get wrong on a nested closure.
    ///
    /// Three properties the naive version did not have, each an evasion the 2026-08-21 adversary
    /// round demonstrated against it:
    ///
    /// - Comments are stripped **before** the search, not after, so a doc comment that merely
    ///   MENTIONS a signature cannot become the first matching line and silently swap one leg's
    ///   body for an unrelated one. (Stripping preserves line count, so nothing shifts.)
    /// - The match must be a real declaration and must be UNIQUE. Two declarations sharing a
    ///   signature substring throw rather than silently binding to whichever comes first.
    /// - The terminator tolerates trailing whitespace. A stray space on a leg's closing brace used
    ///   to run the extraction on into the next function, whose calls could then satisfy tokens.
    static func functionBody(matching signature: String, in source: String) throws -> String {
        let lines = strippingComments(source).components(separatedBy: "\n")
        let declarations = lines.indices.filter { lines[$0].contains(signature) && isDeclarationLine(lines[$0]) }
        guard let start = declarations.first else { throw BoundingError.functionNotFound(signature) }
        guard declarations.count == 1 else {
            throw BoundingError.ambiguousSignature(signature, count: declarations.count)
        }
        guard let end = lines[(start + 1)...].firstIndex(where: isMethodClosingBrace) else {
            throw BoundingError.closingBraceNotFound(signature)
        }
        return lines[start...end].joined(separator: "\n")
    }

    /// Whether `line` DECLARES a function — attributes and access modifiers, then `func`. A line
    /// that merely calls or names one does not qualify, which is what makes the signature match in
    /// `functionBody(matching:in:)` a declaration match rather than a substring match.
    static func isDeclarationLine(_ line: String) -> Bool {
        let modifiers = [
            "public ", "internal ", "fileprivate ", "private ", "static ", "final ", "class ",
            "nonisolated ", "override ", "mutating ", "@discardableResult ", "@MainActor ", "@objc "
        ]
        var rest = line.trimmingCharacters(in: .whitespaces)
        var budget = 0
        while budget < modifiers.count {
            guard let modifier = modifiers.first(where: { rest.hasPrefix($0) }) else { break }
            rest = String(rest.dropFirst(modifier.count)).trimmingCharacters(in: .whitespaces)
            budget += 1
        }
        return rest.hasPrefix("func ")
    }

    /// Whether `line` is a method-level closing brace: `}` alone at exactly one level of type
    /// indentation. Trailing whitespace is tolerated deliberately — the old exact `"    }"` match
    /// was defeated by a single stray space.
    static func isMethodClosingBrace(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == "}"
            && line.prefix(while: { $0 == " " }).count == 4
    }

    enum BoundingError: Error, CustomStringConvertible {
        case functionNotFound(String)
        case closingBraceNotFound(String)
        case malformedCoverageDoc(String)
        case ambiguousSignature(String, count: Int)

        var description: String {
            switch self {
            case .functionNotFound(let signature):
                return "Could not find '\(signature)' in FernletStore.swift — renamed? The wipe-coverage scan is bounded to it."
            case .closingBraceNotFound(let signature):
                return "Could not find the method-level closing brace after '\(signature)' — indentation changed?"
            case .malformedCoverageDoc(let detail):
                return "Docs/PrivacyWipeCoverage.md no longer parses as the reverse-direction check expects: \(detail)"
            case .ambiguousSignature(let signature, let count):
                return "'\(signature)' matches \(count) function declarations — the extraction would bind to whichever came first. Make the registered signature unique."
            }
        }
    }

    /// Blanks every COMMENT out of Swift source, so a token surviving only in prose — or in
    /// commented-out code — cannot satisfy the manifest. Removed characters become spaces and
    /// newlines are preserved, so offsets and line numbers are unchanged and callers may keep
    /// reasoning line by line.
    ///
    /// Source-level rather than line-level since 2026-08-21, because the line version had three
    /// demonstrated holes: it could not see a `/* … */` span at all (a deleted clear stayed
    /// certified by its own TODO), a `//` inside a string literal truncated the rest of the
    /// physical line (silently eating a defaults write sitting on it), and its `://` carve-out
    /// preserved a genuine comment written after a `case …:` or a ternary's colon. Quote tracking
    /// subsumes that carve-out: a `//` inside a literal is literal text either way.
    ///
    /// A multi-line `"""` body is blanked too. It is prose, a template or a code sample — never a
    /// defaults key and never a call — and leaving it in let a `#if DEBUG` line inside a string
    /// read as a real directive.
    static func strippingComments(_ source: String) -> String {
        var scanner = CommentScanner(source)
        return scanner.stripped()
    }

    /// `strippingComments(_:)`, and additionally blanks the BODY of every string literal.
    ///
    /// Used wherever a token is matched as evidence that a CALL is present. A bare
    /// `wipePath.contains("aiAuditLogStore.clear")` is also satisfied by an audit-log event NAMED
    /// after the call it replaced, and the extracted funnel already carries 41 machine-readable
    /// event strings of exactly that shape (`"deleteAll.cloudCopyDeleteFailed"`,
    /// `"identityRotated"`, …). Blanking the bodies makes prose-in-a-literal stop counting as code
    /// without touching the code itself.
    static func strippingCommentsAndStringLiteralBodies(_ source: String) -> String {
        var scanner = CommentScanner(source, blanksStringLiterals: true)
        return scanner.stripped()
    }

    /// A single forward pass over Swift source that blanks comment spans — and, optionally, the
    /// bodies of string literals — leaving everything else exactly where it was.
    ///
    /// Blanking rather than deleting is load-bearing: offsets and line numbers stay put, so the
    /// `#if` line machine in `PersistedSurfaceWipeBoundaryTests` and every line-oriented caller keep
    /// working on the same coordinates as the original file. Not thread-shared and not stored: each
    /// call builds its own scanner, so there is no mutable global here.
    struct CommentScanner {
        /// The source being scanned.
        private let characters: [Character]
        /// Whether string-literal bodies are blanked as well as comments.
        private let blanksStringLiterals: Bool
        /// The next character to read.
        private var index = 0
        /// The rewritten source built so far.
        private var output: [Character] = []

        /// Prepares a scan over `source`.
        init(_ source: String, blanksStringLiterals: Bool = false) {
            self.characters = Array(source)
            self.blanksStringLiterals = blanksStringLiterals
        }

        /// The rewritten source. Every loop below is bounded by the character count, and every
        /// branch advances the cursor by at least one.
        mutating func stripped() -> String {
            output.reserveCapacity(characters.count)
            while index < characters.count {
                if matches("//") { blankLineComment(); continue }
                if matches("/*") { blankBlockComment(); continue }
                if matches("\"\"\"") { blankMultilineString(); continue }
                if characters[index] == "\"" { copyStringLiteral(); continue }
                output.append(characters[index])
                index += 1
            }
            return String(output)
        }

        /// Whether `text` starts at the cursor.
        private func matches(_ text: String) -> Bool {
            let target = Array(text)
            guard index + target.count <= characters.count else { return false }
            for offset in 0..<target.count where characters[index + offset] != target[offset] { return false }
            return true
        }

        /// Replaces the next `count` characters with spaces, preserving newlines.
        private mutating func blank(_ count: Int) {
            var remaining = count
            while remaining > 0, index < characters.count {
                output.append(characters[index] == "\n" ? "\n" : " ")
                index += 1
                remaining -= 1
            }
        }

        /// Copies the next `count` characters through unchanged.
        private mutating func copy(_ count: Int) {
            var remaining = count
            while remaining > 0, index < characters.count {
                output.append(characters[index])
                index += 1
                remaining -= 1
            }
        }

        /// Blanks a `//` comment through to — but not including — the newline that ends it.
        private mutating func blankLineComment() {
            while index < characters.count, characters[index] != "\n" { blank(1) }
        }

        /// Blanks a `/* … */` span. Depth-counted because Swift block comments nest.
        private mutating func blankBlockComment() {
            var depth = 0
            while index < characters.count {
                if matches("/*") { depth += 1; blank(2); continue }
                if matches("*/") {
                    depth -= 1
                    blank(2)
                    if depth <= 0 { return }
                    continue
                }
                blank(1)
            }
        }

        /// Blanks the body of a `"""…"""` literal, keeping both delimiters.
        private mutating func blankMultilineString() {
            copy(3)
            while index < characters.count {
                if matches("\"\"\"") { copy(3); return }
                blank(1)
            }
        }

        /// Handles a single-line `"…"` literal: copied through, or blanked when the caller asked
        /// for that. Stops at a newline — a single-line literal cannot span one, and refusing to
        /// run past it is what keeps an unbalanced quote from swallowing the rest of the file.
        private mutating func copyStringLiteral() {
            copy(1)
            while index < characters.count, characters[index] != "\n" {
                if characters[index] == "\\", index + 1 < characters.count {
                    if blanksStringLiterals { blank(2) } else { copy(2) }
                    continue
                }
                if characters[index] == "\"" { copy(1); return }
                if blanksStringLiterals { blank(1) } else { copy(1) }
            }
        }
    }

    @Test func deleteAllCoversEveryManifestSurface() throws {
        // Literal bodies blanked: a token named in an audit-log string is not a call.
        let wipePath = Self.strippingCommentsAndStringLiteralBodies(try Self.wipePathSource())
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

        // 2026-08-21 adversary round — three demonstrated escapes from the line-based stripper.
        #expect(
            !Self.strippingComments("/* restore heartLedger.clearAll() in b21 */").contains("clearAll"),
            "a block comment still certifies a deleted clear — the stripper cannot see /* … */"
        )
        #expect(
            !Self.strippingComments("        case .full://heartLedger.clearAll()").contains("clearAll"),
            "the ':' lookbehind is preserving a real comment written after a case label"
        )
        #expect(
            Self.strippingComments(#"if p.hasPrefix("//") { d.set(1, forKey: "k") }"#).contains("forKey"),
            "a '//' inside a string literal truncated the line and ate the write on it"
        )
        #expect(
            !Self.strippingCommentsAndStringLiteralBodies(#"log("aiAuditLogStore.clear skipped")"#).contains("aiAuditLogStore.clear"),
            "a token named inside a string literal still counts as a call"
        )
        #expect(
            Self.strippingCommentsAndStringLiteralBodies(#"aiAuditLogStore.clear()"#).contains("aiAuditLogStore.clear"),
            "blanking literal bodies is eating real code"
        )
        #expect(
            Self.strippingComments("a\n/* x\ny */\nb").components(separatedBy: "\n").count == 4,
            "the stripper changed the line count — every line-oriented caller is now reading shifted coordinates"
        )
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

        // 2026-08-21 adversary round: a doc comment naming a signature above an EARLIER method used
        // to win the `firstIndex(where:)` race and silently swap one leg's body for another's.
        let decoyed = """
        final class Thing {
            /// Mirrors func wipe() for the un-hide path.
            func decoy() {
                wrongBody()
            }

            func wipe() {
                inside()
            }
        }
        """
        let afterDecoy = try Self.functionBody(matching: "func wipe()", in: decoyed)
        #expect(afterDecoy.contains("inside()"), "a doc-comment mention of the signature captured the extraction")
        #expect(!afterDecoy.contains("wrongBody()"))

        // A trailing space on the closing brace used to run the extraction into the next function.
        let sloppy = "final class Thing {\n    func wipe() {\n        inside()\n    } \n\n    func other() {\n        outside()\n    }\n}"
        let bounded = try Self.functionBody(matching: "func wipe()", in: sloppy)
        #expect(!bounded.contains("outside()"), "a stray space on the terminator let the scan run into the next function")

        // Two declarations sharing the signature must throw rather than bind to the first.
        let ambiguous = """
        final class Thing {
            func wipe() {
                first()
            }
        }
        extension Thing {
            func wipe() {
                second()
            }
        }
        """
        #expect(throws: (any Error).self) { try Self.functionBody(matching: "func wipe()", in: ambiguous) }
    }

    /// The ContentView half of the scan is really in there, and really bounded — otherwise the two
    /// hook-side tokens (`compactStoreAfterWipe`, `deleteLegacyDirectCloudKitRecords`) are
    /// satisfied by nothing and the extension is decorative.
    @Test func theScanReachesTheHookWiringInContentView() throws {
        let wipePath = try Self.wipePathSource()
        let contentView = try Self.contentViewSource()

        #expect(wipePath.contains("store.periodDataDeleteHook ="), "the hook-wiring half of the scan is missing — the clears living in ContentView closures are invisible again.")
        #expect(wipePath.contains("store.legacyCloudRecordDeleteHook ="))
        // Bounded to the two wiring functions, not the whole 1,500-line view: `refreshPeriodContext`
        // is elsewhere in the file and must not be reachable, or a hook-side token could be
        // satisfied by an unrelated closure.
        #expect(contentView.contains("func refreshPeriodContext()"))
        #expect(!wipePath.contains("func refreshPeriodContext()"), "the ContentView extraction is not bounded to the wiring functions")
    }

    /// The registration wall (round 2026-08-20, Part 4.4). `wipePathMakesNoBannedCall` scans only
    /// the REGISTERED bodies, so the cheapest way to defeat it is to move a banned call into a new
    /// private leg and not register it — the suite stays green and the scan silently shrinks.
    ///
    /// So: every private `FernletStore` helper the wipe path calls must be registered in
    /// `wipeFunctionSignatures`, or named in `unregisteredWipeHelpers` with the reason it is safe
    /// to leave unscanned. Dot-qualified calls are ignored (`proximityTrustVault.apply(…)` is not a
    /// call to the store's own `apply`), `Self.`-qualified ones are not.
    @Test func everyPrivateWipeHelperIsRegistered() throws {
        let source = try Self.fernletStoreSource()
        let path = try Self.storeWipePathSource()
        let exempt = Set(Self.unregisteredWipeHelpers.map(\.name))
        let unregistered = Self.privateFunctionNames(in: source)
            .filter { !exempt.contains($0) }
            .filter { name in !Self.wipeFunctionSignatures.contains { $0.contains("func \(name)(") } }
            .filter { Self.wipePathCalls($0, in: path) }
            .sorted()
        #expect(
            unregistered.isEmpty,
            "the wipe path calls private helper(s) \(unregistered) that no signature in wipeFunctionSignatures covers — their bodies are never scanned, so a banned call inside one is invisible. Register each (or add it to unregisteredWipeHelpers with the reason it cannot hide one)."
        )
        // And the exemptions are real declarations, so a stale entry can't silently widen the hole.
        let declared = Set(Self.privateFunctionNames(in: source))
        let stale = exempt.subtracting(declared).sorted()
        #expect(stale.isEmpty, "unregisteredWipeHelpers names \(stale), which no longer exist — drop the entries rather than leaving a blanket exemption behind.")
    }

    /// Every registered signature still resolves in its own file. `wipePathSource()` throws when one
    /// does not, but it throws from inside other tests — this names the rename directly.
    @Test func everyRegisteredWipeFunctionStillResolves() throws {
        let store = try Self.fernletStoreSource()
        for signature in Self.wipeFunctionSignatures {
            #expect(throws: Never.self, "FernletStore.swift no longer declares '\(signature)'") {
                _ = try Self.functionBody(matching: signature, in: store)
            }
        }
        let contentView = try Self.contentViewSource()
        for signature in Self.hookWiringFunctionSignatures {
            #expect(throws: Never.self, "ContentView.swift no longer declares '\(signature)'") {
                _ = try Self.functionBody(matching: signature, in: contentView)
            }
        }
    }

    /// Names of every `private func` / `private static func` declared in `source`.
    static func privateFunctionNames(in source: String) -> [String] {
        matches(of: #"private\s+(?:static\s+)?func\s+([A-Za-z_][A-Za-z0-9_]*)"#, in: source)
    }

    /// Whether `path` contains an unqualified — or `Self.`-qualified — call to `name`. The
    /// lookbehind is what keeps a same-named method on a collaborator (`…vault.apply(…)`) from
    /// counting as a call to the store's own private helper.
    static func wipePathCalls(_ name: String, in path: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let unqualified = "(?<![A-Za-z0-9_.])\(escaped)\\("
        let selfQualified = "Self\\.\(escaped)\\("
        return !matches(of: unqualified, in: path).isEmpty || !matches(of: selfQualified, in: path).isEmpty
    }

    /// Capture group 1 of every match, or the whole match when the pattern has no group.
    private static func matches(of pattern: String, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            let group = match.numberOfRanges > 1 ? 1 : 0
            return Range(match.range(at: group), in: source).map { String(source[$0]) }
        }
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
        let root = RepoRoot.url
        for file in Self.identitySeamFiles {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            #expect(source.contains("func wipeIdentityForDeleteAll"), "\(file) owns a live IdentityService but lost its wipe seam.")
        }
    }

    /// The rebuild hook is nil-tolerant in the funnel (an unwired TEST store must not report a
    /// failed wipe), so the PRODUCTION wiring is what needs a mechanical guard: without this, the
    /// manifest row above stays green while the app never rebuilds anything.
    @Test func theSealedStoreRebuildIsWiredInTheApp() throws {
        let root = RepoRoot.url
        let contentView = try String(contentsOf: root.appendingPathComponent("App/Fernlet/ContentView.swift"), encoding: .utf8)
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
        let root = RepoRoot.url
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
        let root = RepoRoot.url
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

        let app = try String(contentsOf: root.appendingPathComponent("App/Fernlet/FernletApp.swift"), encoding: .utf8)
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
        let root = RepoRoot.url
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
        let root = RepoRoot.url
        let keyStore = try String(
            contentsOf: root.appendingPathComponent("FernletKit/Sources/PrivateMediaStore/PrivateMediaKeyStore.swift"),
            encoding: .utf8
        )
        #expect(keyStore.contains("func invalidateCachedKey"))
    }

    @Test func coverageDocExistsWithExceptionsTable() throws {
        let root = RepoRoot.url
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
        let root = RepoRoot.url
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

    /// The Phase-6 prior-use marker (`FernletPriorUseMarker`) survives "delete everything" BY
    /// DESIGN — which puts it in exactly the class the funnel-bounded token scan can never see: a
    /// KEPT key never appears in the wipe bodies, so removing its documentation fails nothing
    /// mechanical. And unlike keychain services (below), UserDefaults keys have no
    /// `…service`-shaped binding to anchor a discovery floor on, so this pin is per-key: the
    /// marker's literal must stay in the deliberate-exceptions table — after the exceptions
    /// heading, never in the cleared table (it is a survivor, not a promise).
    @MainActor
    @Test func theWipeSurvivingPriorUseMarkerIsDocumentedAsADeliberateException() throws {
        let root = RepoRoot.url
        let doc = try String(contentsOf: root.appendingPathComponent("Docs/PrivacyWipeCoverage.md"), encoding: .utf8)
        let key = FernletPriorUseMarker.defaultsKey

        guard let exceptionsStart = doc.range(of: "## Deliberate exceptions") else {
            throw BoundingError.malformedCoverageDoc("the deliberate-exceptions heading is gone")
        }
        let tail = doc[exceptionsStart.upperBound...]
        let exceptionsSection = tail.range(of: "\n## ").map { tail[..<$0.lowerBound] } ?? tail

        #expect(
            exceptionsSection.contains(key),
            "the wipe-surviving prior-use marker (\(key)) lost its deliberate-exceptions row in Docs/PrivacyWipeCoverage.md — a kept key the funnel-bounded scan structurally cannot catch, so this pin is its only enforcement."
        )
        #expect(
            !doc[..<exceptionsStart.lowerBound].contains(key),
            "the prior-use marker (\(key)) appears before the deliberate-exceptions section — it survives the wipe by design and must never be listed as a cleared surface."
        )
    }

    /// Every `com.fernlet.*` keychain service the app uses must be named in one of the two tables —
    /// that is the doc's stated contract, and two services (the HealthKit anchors and the
    /// locked-note buffer key) used to be in neither.
    @Test func everyKeychainServiceIsDocumented() throws {
        let root = RepoRoot.url
        let doc = try String(contentsOf: root.appendingPathComponent("Docs/PrivacyWipeCoverage.md"), encoding: .utf8)

        var services: Set<String> = []
        for sourceRoot in ["App/Fernlet", "FernletKit/Sources"] {
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
        let store = FernletStore(repository: LocalFernletRepository(fileURL: url), sensitiveVisibilityDefaults: uniqueSensitiveVisibilityDefaults(), appGroupDirectory: uniqueAppGroupDirectory(),
                                 sharedRecipeImportQueueFileURL: uniqueSharedRecipeImportQueueURL(),
                                 photoDocumentsDirectory: uniquePhotoDirectory(),
                                 proximitySupportDirectory: uniqueProximityDirectory(),
                                 heartDropKeychainService: uniqueHeartDropKeychainService(),
                                 aiQuotaDefaults: uniqueAIQuotaDefaults())
        _ = await store.deleteAllData(includingHealthKitSamples: false)

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
        let store = FernletStore(repository: LocalFernletRepository(fileURL: url), sensitiveVisibilityDefaults: uniqueSensitiveVisibilityDefaults(), appGroupDirectory: uniqueAppGroupDirectory(),
                                 sharedRecipeImportQueueFileURL: uniqueSharedRecipeImportQueueURL(),
                                 photoDocumentsDirectory: uniquePhotoDirectory(),
                                 proximitySupportDirectory: uniqueProximityDirectory(),
                                 heartDropKeychainService: uniqueHeartDropKeychainService(),
                                 aiQuotaDefaults: uniqueAIQuotaDefaults())
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

        _ = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(
            !RecipeWebImageAttemptMemory.hasAttempted(recipeID, defaults: store.webImageAttemptDefaults),
            "delete everything left the web-image attempt bookkeeping behind — the sidecar outlived the recipes it described"
        )
    }
}
