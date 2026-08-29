// PersistedSurfaceWipeBoundaryTests.swift
// FernletTests
//
// The DISCOVERY half of the "delete everything" wall (round 2026-08-20, Part 4.4; hardened against
// a four-way adversary round 2026-08-21).
//
// `PrivacyWipeCoverageTests` checks CORRESPONDENCE between three human-written artifacts — the calls
// in the funnel, the rows in Docs/PrivacyWipeCoverage.md, and its own manifest. It is a strong check
// on the wipe not silently LOSING a call it already makes, and it has no discovery at all: a new
// `UserDefaults`-backed store can ship, never be wiped, and never be documented, with that whole
// suite green. That is not hypothetical — roughly twenty uncleared surfaces accumulated behind the
// green suite and were found by a human walk of the sources on 2026-08-20 (they were fixed the same
// day; read `git log -3` and the doc's audit trail).
//
// This suite closes the hole from the other side. It walks the shipping sources, DISCOVERS every
// `UserDefaults`-backed persisted surface, and requires each one to carry a disposition row saying
// what "delete everything" does to it — cleared, kept, unreachable, or (honestly) an open gap. A new
// store now fails CI until somebody decides, in writing, which of those it is.
//
// ## What this wall proves, and what it cannot
//
// It proves a CALL IS PRESENT for every `UserDefaults`-backed surface it can see. It does not prove
// the call works, and it cannot see through indirection or through a runtime branch:
//
//   * **Reachability is invisible.** `#if DEBUG` is stripped on both sides (below), but that closes
//     the COMPILE-TIME form of the petting-state trap only. A clear gated on `if false`, on a launch
//     argument, on a feature flag, or sitting after an early `return` on the common path is
//     textually identical to an unconditional one. `DeleteAllDataTests` — which drives the real
//     funnel and asserts the surface is gone — is the only thing that can catch that, and it is
//     per-test coverage, not per-row coverage.
//   * **`.cleared` is one hop deep.** The token names a call in the funnel; the CALLEE's body is not
//     scanned. `deleteOwnPhotoEscrowBackups` is one line delegating to
//     `OwnPhotoBackupCoordinator.tearDownForDeleteAll()`, and gutting that callee two files away
//     leaves both halves of this wall green — the writers stay put, so nothing goes stale either.
//     `unscannedWipePathCallees` pins the set of such hops so it cannot silently GROW; whether each
//     body still does its job is a review question.
//   * **One hop of indirection hides unlimited keys.** A generic `Defaults.write(value, key)` helper
//     or a `@UserDefault("…")` property wrapper puts the literal at a NON-anchor call site, where
//     nothing looks. The helper's own seam requires one row; every key routed through it afterwards
//     requires nothing, is never named in the table, and inherits that row's disposition.
//     `expectedSeamSites` makes a seam that starts carrying MORE call sites fail even though the
//     wall still cannot read them, but the real mitigation is a house rule: **no generic defaults
//     setter — keys are literals at the call site.**
//   * **Class coverage is `UserDefaults` and FIRST-PARTY sources only.** Files on disk, keychain
//     accounts, Core Data entities, HealthKit and CloudKit namespaces are outside it, and so is any
//     SPM dependency that writes defaults of its own (`NoTrackingBoundaryTests`' dependency
//     allowlist is the control for that, not this).
//
// The doc says all of this in the same words, under "The UserDefaults discovery wall".
//
// ## Three properties worth reading before editing
//
// **`#if DEBUG` is stripped on BOTH sides.** A DEBUG-only writer is not a shipping surface, and a
// DEBUG-only clear must not satisfy a `.cleared` row. That second half is the trap this wall exists
// to close: `PetInteractionGovernor.clearPersistentState()` existed for months with its only caller
// inside a `#if DEBUG` UI-test seam, so RELEASE never cleared the companion petting state while a
// token scan would have called it clear. The condition is PARSED, not string-compared: Power-of-10
// R9 bans nested `#if`, which forces the tree's own `#if DEBUG && canImport(UIKit)` spelling, and an
// exact `== "DEBUG"` test read that as shipping code. Anything the two-branch model cannot represent
// (`#elseif`, a `||` mentioning DEBUG, an unterminated conditional) throws instead of being guessed.
//
// **Unresolved tokens carry the whole expression and the file, deliberately NOT the line.** A
// line-keyed table breaks on every unrelated edit to the same file, which trains people to "fix" the
// wall by renumbering instead of reading it. Keying on the last identifier alone was worse in the
// other direction: `unresolved:key@…` absorbed every later seam in that file whose expression
// happened to end in `key`, so the second such surface required nothing at all.
//
// **Over-reporting is safe; a silent drop is not.** Every rule here fails towards "emit an
// `unresolved:` token that needs a row". A key resolution that cannot be trusted — a mutated symbol,
// a qualifier this file does not declare, a type-shaped head, a family prefix too broad to mean
// anything — becomes a seam rather than a guess, because naming the WRONG key is how a table starts
// certifying a wipe that never happens.
//
// VERIFY-BATCH NOTE: `-only-testing:` matches suite identifiers exactly, so a run scoped to
// `FernletTests/PrivacyWipeCoverageTests` does NOT include this suite. Name
// `FernletTests/PersistedSurfaceWipeBoundaryTests` as well, and confirm the `Test case` lines really
// ran — never accept the success banner alone.

import Foundation
import Testing

@Suite
struct PersistedSurfaceWipeBoundaryTests {

    // MARK: - Discovered surfaces

    /// One persisted surface as discovered at one call site.
    ///
    /// `token` is the required-declaration key: a literal key, a `prefix*` family, or an
    /// `unresolved:<expression>@<file>` seam. `file` and `anchor` exist for the failure message — a
    /// wall that says only "undeclared surface" without naming where it was written is a wall people
    /// silence rather than read.
    struct DiscoveredSurface: Hashable {
        /// The required-declaration key: literal, `prefix*` family, or `unresolved:…` seam.
        let token: String
        /// Repo-relative path of the file the surface was written in.
        let file: String
        /// The binding the surface was discovered on (`@AppStorage`, `.set`, `.removeObject`, …).
        let anchor: String
    }

    /// One whole-tree discovery pass: the surfaces, keyed by token, plus the file counts the
    /// vacuous-pass floors are checked against.
    struct DiscoveryRun {
        /// Every discovered surface, grouped by token.
        let surfaces: [String: [DiscoveredSurface]]
        /// Shipping Swift files scanned, per scan root.
        let filesPerRoot: [String: Int]
        /// Call sites of a banned bulk `UserDefaults` write, as `<file>: <spelling>`.
        let bulkWriteSites: [String]

        /// Total shipping Swift files scanned across every root.
        var fileCount: Int { filesPerRoot.values.reduce(0, +) }
    }

    /// A loud stop rather than a quiet skip: every one of these means the scan can no longer be
    /// trusted to have looked at what it claims to have looked at.
    enum DiscoveryError: Error, CustomStringConvertible {
        /// A `#if` opened while another was already open. Power-of-10 bans this (Docs/Power-of-10-Swift.md
        /// R9), and the line state machine below is only exact while the ban holds.
        case nestedConditional(file: String, directive: String)
        /// A conditional the two-branch model cannot represent: an `#elseif`, or a `||` that mentions
        /// `DEBUG` (where neither branch is unconditionally shipping).
        case unsupportedConditional(file: String, directive: String)
        /// A `#if` that never closed. Left unchecked this drops every remaining line of the file
        /// SILENTLY, which is the one failure mode this wall must never have.
        case unterminatedConditional(file: String)
        /// A scan root resolved to nothing — the layout moved and this wall is scanning air.
        case emptyScanRoot(String)
        /// Shipping Swift found under a directory the scan excludes by name.
        case forbiddenScanDirectory(String)
        /// The wipe path carries a preprocessor conditional. A clear that needs a compile-time
        /// condition to run cannot certify an unconditional promise.
        case conditionalInWipePath(directive: String)

        var description: String {
            switch self {
            case .nestedConditional(let file, let directive):
                return "\(file) nests preprocessor conditionals at '\(directive)'. Power-of-10 R9 bans that, and the DEBUG stripper here is only exact while it holds — unnest it rather than loosening the wall."
            case .unsupportedConditional(let file, let directive):
                return "\(file) uses '\(directive)', which the two-branch stripper cannot represent. Split it into separate conditionals, or state the DEBUG half as a plain '#if DEBUG'."
            case .unterminatedConditional(let file):
                return "\(file) opens a preprocessor conditional that never closes. Left alone that silently discards every surface below it — check for a '#if' line inside a block comment or a multi-line string."
            case .emptyScanRoot(let root):
                return "Scan root '\(root)' contains no shipping Swift files — the tree moved and this wall would pass by looking at nothing."
            case .forbiddenScanDirectory(let path):
                return "\(path) is shipping Swift under a directory this scan excludes by name ('Tests' or a '.docc' catalog). Xcode's synchronized groups and SwiftPM compile it anyway, so it would ship unscanned — move it, or the exclusion has to go."
            case .conditionalInWipePath(let directive):
                return "the wipe path contains '\(directive)'. A clear behind a compile-time condition cannot certify a promise the dialog makes unconditionally — hoist it out, or make the condition a plain '#if DEBUG' so stripping removes it and the row fails honestly."
            }
        }
    }

    // MARK: - Dispositions

    /// What "delete everything" does to one discovered surface. Every surface must carry exactly one.
    enum Disposition {
        /// The funnel clears it. `token` must be CALLED in the DEBUG-stripped wipe path, be listed in
        /// `PrivacyWipeCoverageTests.wipeManifest`, not be satisfiable by a registered declaration
        /// line, and be paired with this key on one table row of Docs/PrivacyWipeCoverage.md.
        case cleared(token: String)
        /// It survives by design. The reason must be a real sentence and the key must appear,
        /// backticked, on a table row under "Deliberate exceptions" in Docs/PrivacyWipeCoverage.md.
        case kept(reason: String)
        /// Not a distinct persisted surface the funnel could reach — a read-only seam, or a site whose
        /// key already carries its own row. Same reason and documentation burden as `.kept`: it should
        /// never be cheaper to say "this is not a surface" than to say "this survives on purpose".
        case unreachableByDesign(reason: String)
        /// **Not** a deliberate exception: the wipe does not reach it and nobody decided it should
        /// survive. The key must appear, backticked, on a table row under "Open gaps".
        ///
        /// A fourth case, deliberately added beyond the three the round document named. Without it the
        /// only way to give the three known open gaps a row would be to file them under "kept … BY
        /// DESIGN", which is exactly the laundering Docs/PrivacyWipeCoverage.md refuses to do. An open
        /// gap is a decision that has not been made; saying so in the table is the honest option, and
        /// it makes the gaps mechanically visible for the first time.
        case openGap(reason: String)
    }

    /// Every `UserDefaults`-backed surface the shipping sources declare, and what the wipe does to it.
    ///
    /// One key per row. A row whose key ends in `*` is a FAMILY: it covers the family token itself and
    /// narrower families beneath it, and — since 2026-08-21 — **not** concrete literal siblings, which
    /// must earn their own rows. (`fernlet.sealedBackup.generation.*` used to account for a
    /// hand-written `fernlet.sealedBackup.generation.lastPruneAt` that its `allCases` loop never
    /// removes.) An `unresolved:<expression>@<file>` row is a seam whose key is assembled somewhere
    /// this wall cannot follow; it is never dropped, because a dropped key is exactly the silent hole
    /// this file exists to remove.
    static let dispositions: [String: Disposition] = [

        // ── Cleared by the funnel ────────────────────────────────────────────────────────────────
        "ageAssuranceRecord": .cleared(token: "ageAssurance.clear"),
        // The Phase 2.2 sidecar-format migration latch (`HeartDropSidecarMigrationLatch`, one
        // bit, no content). Cleared because the wipe destroys its entire subject — the sidecar
        // files (`heartDropService.wipeForDeleteAll()`) AND the seal key
        // (`HeartPrekeyStore.wipeForDeleteAll()`'s service-wide delete) — the deliberate
        // mirror-image of `ownPhotoKeyMigrationComplete`'s kept row (subject survives) and the
        // same case as `hashVersionMigrationComplete`'s cleared row (subject destroyed).
        "com.fernlet.heartdrop.sidecarFormatMigrationComplete":
            .cleared(token: "HeartDropSidecarMigrationLatch.resetForDeleteAll"),
        // The Phase 2.6 sealed-column format-migration latch (`SealedColumnMigrationLatch`, one
        // bit, no content). Cleared because the wipe destroys the latch's entire subject — the
        // sealed store's four entities and their seven ciphertext columns — inside the same
        // `sealedStoreRebuildHook` closure, which tolerates a rebuild failure (`(try? …) != nil`
        // feeds the outcome), so a KEPT latch could stand over rows a failed purge left behind.
        // Same case as `sidecarFormatMigrationComplete` above (subject destroyed);
        // contrast `ownPhotoKeyMigrationComplete`, kept because its subject survives. The next
        // unlock's keyless revalidation census re-proves over the empty store.
        "com.fernlet.private-store.sealedColumnMigrationComplete":
            .cleared(token: "SealedColumnFormatMigrator.latch().reset"),
        "fernlet.ai.quota.pair": .cleared(token: "aiCallQuotaStore.reset"),
        "fernlet.barcodeLastServings.v1": .cleared(token: "BarcodeServingMemory.clearAll"),
        // The companion petting state, all four keys. `clearPersistentState()` existed long before
        // anything on a shipping path called it — see the header.
        "fernlet.companionPets.count": .cleared(token: "PetInteractionGovernor.clearPersistentState"),
        "fernlet.companionPets.windowStart": .cleared(token: "PetInteractionGovernor.clearPersistentState"),
        "fernlet.companionPets.cooldownUntil": .cleared(token: "PetInteractionGovernor.clearPersistentState"),
        "fernlet.companionPets.settledLineShownFor": .cleared(token: "PetInteractionGovernor.clearPersistentState"),
        // The plaintext half of the Health capability ledger. The live record is a keychain row now;
        // this defaults key is the legacy copy the ledger drains, and `clear` removes it directly.
        "fernlet.healthkit.requested-capabilities": .cleared(token: "HealthCapabilityRequestLedger.clear"),
        // Research §26 fix 1.10's local correction memory: normalized query → the food id the user
        // picked when they replaced a wrong match. Device-local, never synced, capped at 200 entries.
        "fernlet.foodSearchCorrections.v1": .cleared(token: "FoodSearchCorrectionMemory.clearAll"),
        // The un-consumed Messages deep-link request: which queue a shared card landed in, and the
        // record id inside it. `consume()` removes them on the happy path; this token is the wipe's
        // unconditional removal, added because the pointer otherwise outlives the record it names.
        "fernlet.messages.pendingInboxDestination": .cleared(token: "FernletMessagesRecipeImportRequest.clearPendingRequest"),
        "fernlet.messages.pendingInboxID": .cleared(token: "FernletMessagesRecipeImportRequest.clearPendingRequest"),
        "fernlet.messages.pendingRecipeInboxID": .cleared(token: "FernletMessagesRecipeImportRequest.clearPendingRequest"),
        "fernlet.recentActivityTypes": .cleared(token: "RecentActivityTypeMemory.clearAll"),
        "fernlet.recipeWebImageAttempts.v1": .cleared(token: "RecipeWebImageAttemptMemory.clearAll"),
        "fernlet.sealedBackup.generation.*": .cleared(token: "generationStore.reset"),
        "fernlet.sealedPhoto.generation.*": .cleared(token: "generationStore.reset"),
        "fernlet.sealedPhoto.restoreRepairIDs.*": .cleared(token: "deleteOwnPhotoEscrowBackups"),
        "fernlet.sealedPhoto.uploadedIDs.*": .cleared(token: "deleteOwnPhotoEscrowBackups"),
        "fernlet.sealedPhoto.routeCommitted": .cleared(token: "deleteOwnPhotoEscrowBackups"),
        // The Phase 2.1 hash-version migration latch (`SealedPhotoBackupMigrationLatch`, one bit,
        // no content). Cleared because the wipe destroys the manifests the bit makes a claim
        // about — the deliberate mirror-image of `ownPhotoKeyMigrationComplete`'s kept row, whose
        // subject (the re-sealed local files) survives the wipe.
        "fernlet.sealedPhoto.hashVersionMigrationComplete": .cleared(token: "deleteOwnPhotoEscrowBackups"),
        "fernlet.workout.tombstones": .cleared(token: "workoutTombstones.clearAll"),
        "sensitiveVisibilityResolved": .cleared(token: "clearSensitiveVisibilityResolution"),
        "sensitiveVisibilityResolvedPeriodVisible": .cleared(token: "clearSensitiveVisibilityResolution"),
        "sensitiveVisibilityResolvedIntimacyVisible": .cleared(token: "clearSensitiveVisibilityResolution"),
        // `releaseAll()` sets the count to zero and the property's `didSet` writes that through, so the
        // surviving key holds 0 rather than being removed. Cleared in the sense the dialog promises.
        "worryBox.lifetimeLetGoCount": .cleared(token: "worryBoxResetHook"),
        // The governor's own `date(forKey:)` / `set(_:forKey:)` wrappers: the key is their function
        // parameter, so it resolves to nothing here, but every caller passes one of the four
        // `Key.*` literals above and the same call clears all four.
        "unresolved:key@App/Fernlet/PetInteractionGovernor.swift":
            .cleared(token: "PetInteractionGovernor.clearPersistentState"),
        // `loadLegacy(_:key:)` reading the pre-database corpus (`fernlet-settings`, `fernlet-memories`,
        // every `fernlet-day-<date>` row …). The key is a function parameter; the callers pass
        // `LegacyKeys.*`, and `clearLegacyUserDefaultsIfPresent()` removes exactly that set.
        "unresolved:key@FernletKit/Sources/LocalPersistence/LocalFernletRepository.swift":
            .cleared(token: "repository.purgeAllPersistedData"),
        // The removal loop itself — `fixedKeys.forEach { legacyDefaults.removeObject(forKey: $0) }` and
        // the day-prefix sweep beside it. A closure-shorthand key resolves to nothing, and this row is
        // what keeps the legacy purge from vanishing unnoticed.
        "unresolved:$0@FernletKit/Sources/LocalPersistence/LocalFernletRepository.swift":
            .cleared(token: "repository.purgeAllPersistedData"),

        // ── Survives by design ───────────────────────────────────────────────────────────────────
        "com.fernlet.launch.priorUseRecorded": .kept(
            reason: "The Phase-6 prior-use marker: one bit that must outlive the wipe, or the next launch classifies a wiped-but-reused device as FRESH and silently adopts the excluded backup default over it."
        ),
        // The Phase 2.3 media at-rest FORMAT migration latch (`MediaAtRestFormatMigrationLatch`,
        // one bit, no content). Kept — NOT the mirror of the cleared format latches above,
        // because their "subject destroyed" premise is false here: three of its eight locations
        // (the friend wall's photos, thumbnails, and sealed index) deliberately SURVIVE the wipe.
        "com.fernlet.private-media.mediaAtRestFormatMigrationComplete": .kept(
            reason: "The media at-rest format-migration latch. The wipe empties the own-photo corpora, the surviving friend wall was proven all-current-format (or named residue) before the latch could set, and every post-wipe writer emits the current format — so the latch's claim stays true of everything the wipe leaves behind, and clearing it would only force a pointless re-scan."
        ),
        "com.fernlet.private-media.ownPhotoDeviceBindingConsent": .kept(
            reason: "The own-photo device-binding consent bit. Clearing it would silently WIDEN custody for everything captured after the wipe, because the next launch would find the gate unsatisfied and photos would go back to being backup-restorable."
        ),
        "com.fernlet.private-media.ownPhotoKeyMigrationComplete": .kept(
            reason: "The own-photo key migration latch. The files it describes were re-sealed under the own-photos key and survive as ciphertext nothing can open; clearing the latch would only force a pointless re-scan."
        ),
        "com.fernlet.savedRecipeMigrationCompleted": .kept(
            reason: "The saved-recipe legacy-migration latch. A wipe leaves the Core Data store empty by definition, so clearing this bit would re-run the JSON migration on the next launch and resurrect every recipe it describes."
        ),
        "fernlet.breathing.presetID": .kept(
            reason: "Breathing-timer configuration, not a record: which preset the user last chose. It holds nothing about the user's days, and clearing it only hands someone who just deleted their data a suddenly-unfamiliar app."
        ),
        "fernlet.breathing.minutes": .kept(
            reason: "Breathing-timer configuration, not a record: the session length the user last chose. Same class as the preset id beside it — app chrome, no content, nothing about any day."
        ),
        "fernlet.breathing.haptics": .kept(
            reason: "Breathing-timer configuration, not a record: whether the timer buzzes. Same class as the preset id and minutes beside it — app chrome, no content, nothing about any day."
        ),
        "fernlet.healthkit.workoutBackfillCompleted": .kept(
            reason: "The one-time workout backfill latch. Clearing it makes the next launch re-import the trailing 30 days of Health workouts straight back into the just-emptied day store, and re-upload them when sync is on."
        ),
        "fernlet.homePhotowall.previousPhotoIDs": .kept(
            reason: "Rotation bookkeeping (ids only) about the friend photo wall this funnel keeps BY DESIGN. Clearing it deletes notes about data that is still there: no privacy gain, just a worse wall on the next launch."
        ),
        "fernlet.intent.pendingSheet": .kept(
            reason: "A self-clearing Siri/Shortcuts hand-off token naming a SCREEN, never content. `consume()` removes it on read whether or not it is honored, and anything older than 120 seconds is discarded."
        ),
        "fernlet.intimacyLog.everStored": .kept(
            reason: "A sealed-store divergence latch: one bit meaning 'this install held intimacy rows'. It must outlive the wipe, or a sealed-backup chunk that survived a failed delete could restore itself onto the device."
        ),
        "fernlet.journalNarrative.everStored": .kept(
            reason: "A sealed-store divergence latch: one bit meaning 'this install held journal rows'. It must outlive the wipe, or a sealed-backup chunk that survived a failed delete could restore itself onto the device."
        ),
        "fernlet.menstrualNarrative.everStored": .kept(
            reason: "A sealed-store divergence latch: one bit meaning 'this install held cycle rows'. It must outlive the wipe, or a sealed-backup chunk that survived a failed delete could restore itself onto the device."
        ),
        "fernletAppearanceMode": .kept(
            reason: "Appearance preference (system / light / dark). A setting describing the app's chrome, not the user's days; clearing it only makes a freshly-wiped app look unfamiliar for no privacy gain."
        ),
        "fernletDarkModeEnabled": .kept(
            reason: "The legacy dark-mode appearance flag, read for installs predating the three-way appearance mode. Same class as the mode beside it: app chrome, no content, no timestamps."
        ),
        "hasCompletedOnboarding": .kept(
            reason: "Onboarding completion. It survives so a wipe does not replay the first-run flow, and the backup-exclusion launch gate ORs it in as its legacy evidence of prior use — clearing it would misclassify the device as fresh."
        ),
        "lockSetupDeferred": .kept(
            reason: "Records that the user skipped app-lock setup during onboarding. The app lock itself survives this funnel by design, so clearing this bit would re-nag about setting up a lock the device may already have."
        ),

        // ── Symbolic seams: kept keys this wall cannot resolve to a literal ──────────────────────
        // Each is a real binding whose key constant lives in ANOTHER file, so rule (c) — resolve the
        // terminal identifier in the same file — finds nothing. The underlying keys all carry kept
        // rows above; these rows exist so the seams themselves cannot disappear unnoticed, and each is
        // named in the doc's exceptions section with the key it really is. The token carries the WHOLE
        // key expression, so a second, different seam in the same file cannot inherit this row.
        "unresolved:FernletAppearanceMode.storageKey@App/Fernlet/FernletApp.swift": .kept(
            reason: "@AppStorage(FernletAppearanceMode.storageKey) — the appearance mode `fernletAppearanceMode`, kept as app chrome. The constant lives in FernletNavigation.swift, so the key resolves in neither direction from here."
        ),
        "unresolved:FernletAppearanceMode.storageKey@App/Fernlet/SettingsSheet.swift": .kept(
            reason: "@AppStorage(FernletAppearanceMode.storageKey) — the appearance mode `fernletAppearanceMode`, kept as app chrome. The constant lives in FernletNavigation.swift, so the key resolves in neither direction from here."
        ),
        "unresolved:FernletThemeDefaults.customLightBackgroundKey@App/Fernlet/ContentView.swift": .kept(
            reason: "@AppStorage(FernletThemeDefaults.customLightBackgroundKey) — the custom light background `fernletCustomLightBackgroundHex`, kept as app chrome. The constant lives in FernletKit's FernletTheme.swift."
        ),
        "unresolved:FernletThemeDefaults.customLightBackgroundKey@App/Fernlet/SettingsSheet.swift": .kept(
            reason: "@AppStorage(FernletThemeDefaults.customLightBackgroundKey) — the custom light background `fernletCustomLightBackgroundHex`, kept as app chrome. The constant lives in FernletKit's FernletTheme.swift."
        ),
        "unresolved:FernletThemeDefaults.customDarkBackgroundKey@App/Fernlet/ContentView.swift": .kept(
            reason: "@AppStorage(FernletThemeDefaults.customDarkBackgroundKey) — the custom dark background `fernletCustomDarkBackgroundHex`, kept as app chrome. The constant lives in FernletKit's FernletTheme.swift."
        ),
        "unresolved:FernletThemeDefaults.customDarkBackgroundKey@App/Fernlet/SettingsSheet.swift": .kept(
            reason: "@AppStorage(FernletThemeDefaults.customDarkBackgroundKey) — the custom dark background `fernletCustomDarkBackgroundHex`, kept as app chrome. The constant lives in FernletKit's FernletTheme.swift."
        ),
        "unresolved:OnboardingDefaults.hasCompletedOnboardingKey@App/Fernlet/FernletApp.swift": .kept(
            reason: "@AppStorage(OnboardingDefaults.hasCompletedOnboardingKey) — the kept `hasCompletedOnboarding` bit. The constant lives in OnboardingCoordinator.swift, so this binding's key cannot be resolved from here."
        ),
        "unresolved:OnboardingDefaults.hasCompletedOnboardingKey@App/Fernlet/BackupExclusionLaunchGate.swift": .unreachableByDesign(
            reason: "A read-only site: the launch gate reads `OnboardingDefaults.hasCompletedOnboardingKey` as legacy evidence of prior use. Nothing here writes a key, so there is no surface for the funnel to clear — and the key it reads carries its own kept row."
        ),
        "unresolved:key@FernletKit/Sources/FernletUI/FernletTheme.swift": .unreachableByDesign(
            reason: "A read-only site: `UserDefaults.standard.string(forKey: key)` where `key` is a ternary over the two custom-background constants. It writes nothing, and both keys it reads carry their own kept rows above."
        ),
        // The Phase 2.6 sealed-column format migrator's two dynamic-key writes. Both are
        // `NSManagedObject.setValue(_:forKey:)` onto rows of the sealed `FernletPrivate` Core
        // Data store — the KVC spelling the discovery scan cannot tell from a `UserDefaults`
        // write — where the key is one of the census's seven ciphertext attribute names, never a
        // defaults key. The store those rows live in carries its own `.cleared` funnel rows
        // (`sealedStoreRebuildHook` and the sealed row-delete hooks), so there is no
        // UserDefaults surface here for the funnel to reach.
        "unresolved:column.attributeName@FernletKit/Sources/PrivateStoreCore/SealedColumnFormatMigration.swift": .unreachableByDesign(
            reason: "Not a UserDefaults write: `row.setValue(newBlob, forKey: column.attributeName)` re-seals one ciphertext column of a sealed Core Data row during the Phase 2.6 format migration. The rows it writes live in the FernletPrivate store, which the funnel empties (row-delete hooks) and destroys (`sealedStoreRebuildHook`) under its own cleared rows."
        ),
        "unresolved:entry.column.attributeName@FernletKit/Sources/PrivateStoreCore/SealedColumnFormatMigration.swift": .unreachableByDesign(
            reason: "Not a UserDefaults write: `entry.row.setValue(entry.oldBlob, forKey: entry.column.attributeName)` is the migration's compensating restore of a sealed Core Data column's held old bytes. Same substrate as its sibling seam — the FernletPrivate store, wiped by the funnel's own cleared rows."
        ),

        // ── Open gaps: not cleared, and nobody decided they should survive ──────────────────────
        "fernlet.daySummary.lastRunKey": .openGap(
            reason: "One yyyy-MM-dd key: the last day the once-per-day summary backfill ran. A date the app was used, surviving the deletion of every day it describes. Low severity, and open since the 2026-08-20 sweep."
        ),
        "pastDayJournalScrubVersion": .openGap(
            reason: "The run-once version flag for the historical past-day journal scrub (WI-1). Keeping it is not load-bearing — post-wipe the scrub would simply run once over an empty store — so nothing has decided it should survive."
        ),
        "pastDayJournalScrubAttempts": .openGap(
            reason: "The scrub's retry-budget counter: how many launches sealed at least one day badly. Usually absent (it is removed at every terminal state), but when present it is a trace of app use that the wipe does not reach."
        ),
        "FernletMessages.lastRecipeID": .openGap(
            reason: "The recipe the user last picked in the iMessage composer, remembered so the composer re-selects it. It is written to the MESSAGES EXTENSION's own UserDefaults.standard — a separate defaults domain from the containing app's — so the funnel cannot reach it at all without first moving the key into the shared App Group suite. That move is a decision nobody has made, which is what puts it here rather than in the exceptions table. It is a pointer to a recipe the wipe deletes, not recipe content."
        )
    ]

    /// How many CALL SITES each `unresolved:` seam accounts for today.
    ///
    /// A seam row is otherwise an unbounded absorber: `unresolved:key@PetInteractionGovernor.swift`
    /// covers every future write in that file whose key expression is also spelled `key`, and the new
    /// surface inherits the old row's `.cleared` promise without anybody looking. Keying on the whole
    /// expression closes the "different expression" half; this closes the "same expression, new site"
    /// half. Growth fails, shrinkage does not — a deleted call site is not a privacy problem, and
    /// `noDispositionRowIsStale` already catches a seam that disappears entirely.
    static let expectedSeamSites: [String: Int] = [
        "unresolved:$0@FernletKit/Sources/LocalPersistence/LocalFernletRepository.swift": 3,
        "unresolved:column.attributeName@FernletKit/Sources/PrivateStoreCore/SealedColumnFormatMigration.swift": 1,
        "unresolved:entry.column.attributeName@FernletKit/Sources/PrivateStoreCore/SealedColumnFormatMigration.swift": 1,
        "unresolved:FernletAppearanceMode.storageKey@App/Fernlet/FernletApp.swift": 1,
        "unresolved:FernletAppearanceMode.storageKey@App/Fernlet/SettingsSheet.swift": 1,
        "unresolved:FernletThemeDefaults.customDarkBackgroundKey@App/Fernlet/ContentView.swift": 1,
        "unresolved:FernletThemeDefaults.customDarkBackgroundKey@App/Fernlet/SettingsSheet.swift": 1,
        "unresolved:FernletThemeDefaults.customLightBackgroundKey@App/Fernlet/ContentView.swift": 1,
        "unresolved:FernletThemeDefaults.customLightBackgroundKey@App/Fernlet/SettingsSheet.swift": 1,
        "unresolved:OnboardingDefaults.hasCompletedOnboardingKey@App/Fernlet/BackupExclusionLaunchGate.swift": 1,
        "unresolved:OnboardingDefaults.hasCompletedOnboardingKey@App/Fernlet/FernletApp.swift": 1,
        "unresolved:key@App/Fernlet/PetInteractionGovernor.swift": 2,
        "unresolved:key@FernletKit/Sources/FernletUI/FernletTheme.swift": 1,
        "unresolved:key@FernletKit/Sources/LocalPersistence/LocalFernletRepository.swift": 1
    ]

    /// Functions the wipe path CALLS whose bodies the wipe-path scan does not cover.
    ///
    /// The other wall enumerates by access level (`private func`), which an internal helper walks
    /// straight past — `deleteOwnPhotoEscrowBackups` is internal, is called from the funnel, and is the
    /// `.cleared` token for three sealed-photo rows, with its whole body outside every scan. This pin
    /// enumerates by CALL instead, so the set cannot silently GROW: moving a clear into a new,
    /// unscanned leg fails here even when the leg is `internal`, `nonisolated`, or spelled with a
    /// modifier between `private` and `func`.
    ///
    /// It is a floor, not an approval. Whether each body still does its job is a review question, and
    /// the one-hop ceiling in the header says so plainly.
    static let unscannedWipePathCallees: Set<String> = [
        // Removes the three sensitive-visibility keys and calls nothing. Deliberately unregistered in
        // PrivacyWipeCoverageTests too: registering it would let its own token be satisfied by its
        // declaration line, which is the P1b defect class.
        "clearSensitiveVisibilityResolution",
        // One line: `await ownPhotoBackupCoordinator.tearDownForDeleteAll()`. The clearest live
        // instance of the one-hop ceiling — the removal it certifies happens two files away.
        "deleteOwnPhotoEscrowBackups",
        // A pure predicate over StoragePreferences; reads four Bools and touches no store.
        "hasSealedBackup",
        // Records the deferred-reupload flag for one sealed payload type.
        "recordSealedBackupReuploadDeferred",
        // The sealed-backup toggle; the funnel calls it to delete the cloud backups per payload type.
        "setSealedBackupEnabled",
        // Stops the HealthKit workout observer query before the wipe.
        "stopHealthKitWorkoutObservation",
        // Re-publishes the process-global custom-exercise catalog after the snapshot reset.
        "syncCustomExerciseCatalog"
    ]

    /// Surfaces that exist today and must always be rediscovered.
    ///
    /// A floor, not a whitelist — anything NEW still has to earn a row. Its job is the vacuous pass:
    /// every anchor and resolution rule below is a pattern, and a pattern that silently stops matching
    /// makes this whole suite green by looking at less. Files under active edit elsewhere are
    /// deliberately under-represented here, so a concurrent change to one of them cannot be mistaken
    /// for a broken matcher.
    static let knownSurfaces: Set<String> = [
        "fernlet.recentActivityTypes",
        "fernlet.workout.tombstones",
        "fernlet.companionPets.count",
        "fernlet.ai.quota.pair",
        "fernlet.homePhotowall.previousPhotoIDs",
        "fernlet.breathing.presetID",
        "sensitiveVisibilityResolved",
        "sensitiveVisibilityResolvedPeriodVisible",
        "sensitiveVisibilityResolvedIntimacyVisible",
        "hasCompletedOnboarding",
        "com.fernlet.launch.priorUseRecorded",
        "fernlet.intimacyLog.everStored",
        "fernlet.sealedPhoto.uploadedIDs.*",
        "fernlet.sealedBackup.generation.*",
        "unresolved:key@FernletKit/Sources/LocalPersistence/LocalFernletRepository.swift",
        "unresolved:$0@FernletKit/Sources/LocalPersistence/LocalFernletRepository.swift"
    ]

    /// The shipping scan roots. `discoveryFloorsHold` derives the `App/` half rather than trusting
    /// this list, so a new target cannot ship outside the frame.
    static let scanRoots = [
        "App/Fernlet", "App/FernletWidgets", "App/FernletShareExtension",
        // The iMessage extension is shipping Swift with its own persisted surface, and it writes to
        // a defaults domain the funnel cannot reach — precisely the thing that must be visible here
        // rather than outside the wall.
        "App/FernletMessagesExtension",
        "FernletKit/Sources"
    ]

    /// Total shipping Swift files the scan must see. The tree carries ~372; a run that finds many
    /// fewer is enumerating the wrong place, and this stops it reporting green for it.
    static let minimumScannedFiles = 350

    /// Surfaces the tree really has. The effective floor is `max(this, dispositions.count)`, so it
    /// ratchets with the table and cannot leave slack for "break a matcher and delete its rows in the
    /// same commit".
    static let minimumDiscoveredSurfaces = 50

    /// The `UserDefaults` accessors whose `forKey:` argument names a persisted surface.
    ///
    /// Matched as `.<name>` with a following `(` — whitespace between the two is tolerated, because
    /// `defaults.set (1, forKey: "k")` compiles warning-free and used to yield nothing at all. The
    /// method-name boundary is exact, so `.set` does not match inside `.setValue` (that spelling is
    /// handled separately, by receiver, below).
    static let defaultsMethods = [
        "set", "removeObject", "object", "string", "stringArray",
        "bool", "integer", "double", "data", "array", "dictionary"
    ]

    /// The KVC spelling. `NSUserDefaults` implements `setValue(_:forKey:)` by routing to
    /// `setObject(_:forKey:)`, so it is a fully real persisted write — the exclusion that kept Core
    /// Data's 62 KVC sites out of the results was receiver-blind and dropped defaults writes with it.
    static let keyValueCodingMethods = ["setValue"]

    /// Bulk `UserDefaults` writes that name no key at all, and are therefore banned rather than
    /// discovered.
    ///
    /// `setPersistentDomain(_:forName:)` writes a whole dictionary; `setValuesForKeys(_:)` takes its
    /// keys from the dictionary at runtime. Both persist, and neither carries a `forKey:` for any
    /// anchor to read — there is no honest way to give them a disposition row, so the only options are
    /// "banned" or "invisible". All five spellings appear zero times in the tree, so the ban costs
    /// nothing today and stops the shape landing by accident.
    static let bannedBulkWrites = [
        "setPersistentDomain(", "removePersistentDomain(", "setVolatileDomain(",
        "setValuesForKeys(", "CFPreferencesSetAppValue"
    ]

    /// The receiver spellings whose `setValue(_:forKey:)` is Core Data's KVC, not a defaults write.
    ///
    /// An explicit denylist rather than a defaults-shaped ALLOWlist, so the failure direction is
    /// over-reporting: a fourth receiver spelling becomes an undeclared surface that somebody has to
    /// look at, instead of an invisible one. All 62 KVC sites in the tree use exactly these three.
    static let coreDataKeyValueReceivers: Set<String> = ["object", "record", "request"]

    /// Keywords that introduce a type declaration, for the same-file qualifier check.
    static let typeDeclarationKeywords = ["struct", "enum", "class", "actor", "protocol", "extension", "typealias"]

    // MARK: - Matcher: comment and DEBUG stripping

    /// `PrivacyWipeCoverageTests.strippingComments` over a whole source. Shared deliberately: prose
    /// about a key is not a key, and the two walls must agree on what counts as code.
    ///
    /// Source-level rather than line-level since 2026-08-21. The line version could not see a
    /// `/* … */` span at all (so a block-commented `removeObject` counted as a live surface and
    /// padded the floors), truncated a line at a `//` inside a string literal (eating any write that
    /// shared the line), and its `://` carve-out preserved a genuine comment written after a `case`
    /// label's colon.
    static func strippingCommentSpans(_ source: String) -> String {
        PrivacyWipeCoverageTests.strippingComments(source)
    }

    /// Removes `#if DEBUG` bodies (keeping any `#else` half) and the `#else` half of `#if !DEBUG`,
    /// leaving every other conditional — `#if canImport(…)`, `#if os(…)` — completely untouched.
    ///
    /// A line state machine, exact rather than heuristic because Power-of-10 R9 bans nested `#if`.
    /// Rather than assume that ban, it throws when it is broken. The condition is PARSED into
    /// conjuncts, not string-compared: R9's no-nesting rule is precisely what forces the tree's own
    /// `#if DEBUG && canImport(UIKit)` spelling, and an exact `== "DEBUG"` test read 272 lines of
    /// DEBUG-only code as shipping source. Three shapes stop the run instead of being guessed —
    /// nesting, any `#elseif`, and a `||` that mentions DEBUG — and an unbalanced conditional throws
    /// at EOF rather than silently discarding the rest of the file.
    static func strippingDebugBranches(_ source: String, file: String) throws -> String {
        var kept: [String] = []
        var depth = 0
        var dropping = false
        var isDebugConditional = false
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if") {
                depth += 1
                guard depth == 1 else { throw DiscoveryError.nestedConditional(file: file, directive: trimmed) }
                let condition = String(trimmed.dropFirst(3))
                let conjuncts = debugConjuncts(of: condition)
                if conjuncts.mentionsDebug, conjuncts.isDisjunction {
                    throw DiscoveryError.unsupportedConditional(file: file, directive: trimmed)
                }
                isDebugConditional = conjuncts.mentionsDebug
                dropping = conjuncts.terms.contains("DEBUG")
                continue
            }
            // Before `#else`: "#elseif".hasPrefix("#else") is true, so order is load-bearing.
            if trimmed.hasPrefix("#elseif") {
                throw DiscoveryError.unsupportedConditional(file: file, directive: trimmed)
            }
            if trimmed.hasPrefix("#else") {
                if isDebugConditional { dropping.toggle() }
                continue
            }
            if trimmed.hasPrefix("#endif") {
                depth = max(0, depth - 1)
                dropping = false
                isDebugConditional = false
                continue
            }
            if !dropping { kept.append(line) }
        }
        guard depth == 0 else { throw DiscoveryError.unterminatedConditional(file: file) }
        return kept.joined(separator: "\n")
    }

    /// A `#if` condition broken into its terms: whether it mentions `DEBUG` at all, whether it is a
    /// disjunction (which the two-branch model cannot represent), and the terms themselves.
    ///
    /// Spaces and parentheses are normalised away, so `#if (DEBUG)` and `#if DEBUG && os(iOS)` both
    /// read as DEBUG-gated. `os(iOS)` normalises to `osiOS`, which is a term this only ever compares
    /// against `DEBUG` — good enough, and it never mistakes one for the other.
    static func debugConjuncts(of condition: String) -> (terms: [String], mentionsDebug: Bool, isDisjunction: Bool) {
        let normalised = condition.filter { !$0.isWhitespace && $0 != "(" && $0 != ")" }
        let isDisjunction = normalised.contains("||")
        var terms: [String] = []
        for orTerm in normalised.components(separatedBy: "||") {
            terms += orTerm.components(separatedBy: "&&")
        }
        return (terms, terms.contains("DEBUG") || terms.contains("!DEBUG"), isDisjunction)
    }

    // MARK: - Matcher: discovery

    /// Every persisted surface one file declares.
    ///
    /// The whole pipeline for one file, in order: strip comment spans, strip DEBUG branches, then
    /// anchor on the three bindings — `@AppStorage(…)` attributes, `UserDefaults` accessors carrying a
    /// `forKey:`, and the KVC `setValue(_:forKey:)` spelling on a non-Core-Data receiver. Pure: source
    /// text in, findings out, no disk.
    static func surfaces(in rawSource: String, file: String) throws -> [DiscoveredSurface] {
        let source = try strippingDebugBranches(strippingCommentSpans(rawSource), file: file)
        let characters = Array(source)
        var found = appStorageSurfaces(in: characters, file: file)
        found += accessorSurfaces(in: characters, file: file)
        found += keyValueCodingSurfaces(in: characters, file: file)
        return found
    }

    /// `@AppStorage(…)` bindings. The fused spelling is complete: Swift 6 rejects whitespace between
    /// an attribute name and its `(`, so there is no spaced variant to tolerate.
    static func appStorageSurfaces(in characters: [Character], file: String) -> [DiscoveredSurface] {
        let attribute = "@AppStorage("
        return occurrences(of: attribute, in: characters).flatMap { start in
            callSurfaces(
                at: start + attribute.count - 1, labelled: nil,
                in: characters, file: file, anchor: "@AppStorage"
            )
        }
    }

    /// `UserDefaults` accessor calls carrying a `forKey:` argument.
    ///
    /// Dotted calls always; bare, receiver-less calls too when the file declares `extension
    /// UserDefaults` or a `UserDefaults` subclass, where `self.` is implicit and the leading dot the
    /// anchor needs simply is not written. That idiom appears zero times in the tree today, which is
    /// exactly why it was worth closing: it is the shape the NEXT defaults store would take.
    static func accessorSurfaces(in characters: [Character], file: String) -> [DiscoveredSurface] {
        let scansDotless = declaresUserDefaultsMember(in: characters)
        var found: [DiscoveredSurface] = []
        for method in defaultsMethods {
            for open in memberCallOpenings(of: method, in: characters) {
                found += callSurfaces(at: open, labelled: "forKey", in: characters, file: file, anchor: ".\(method)")
            }
            guard scansDotless else { continue }
            for open in bareCallOpenings(of: method, in: characters) {
                found += callSurfaces(at: open, labelled: "forKey", in: characters, file: file, anchor: method)
            }
        }
        return found
    }

    /// KVC writes that are not Core Data's. See ``coreDataKeyValueReceivers`` for why the
    /// discrimination is by receiver rather than by method name.
    static func keyValueCodingSurfaces(in characters: [Character], file: String) -> [DiscoveredSurface] {
        var found: [DiscoveredSurface] = []
        for method in keyValueCodingMethods {
            for start in memberOccurrences(of: method, in: characters) {
                guard !coreDataKeyValueReceivers.contains(receiver(before: start, in: characters)) else { continue }
                guard let open = openParenthesis(after: start + method.count + 1, in: characters) else { continue }
                found += callSurfaces(at: open, labelled: "forKey", in: characters, file: file, anchor: ".\(method)")
            }
        }
        return found
    }

    /// Banned bulk-write spellings this file uses, as `<file>: <spelling>`. Comment spans and
    /// string-literal bodies are removed first, so prose about the API is not the API.
    static func bulkWriteSites(in rawSource: String, file: String) -> [String] {
        let source = PrivacyWipeCoverageTests.strippingCommentsAndStringLiteralBodies(rawSource)
        return bannedBulkWrites.filter { source.contains($0) }.map { "\(file): \($0)" }
    }

    /// Whether this file declares `extension UserDefaults` or a `UserDefaults` subclass — the two
    /// shapes in which an accessor call has no receiver text for a dotted anchor to find.
    static func declaresUserDefaultsMember(in characters: [Character]) -> Bool {
        for start in wordOccurrences(of: "extension", in: characters) {
            var cursor = SourceCursor(characters, at: start + "extension".count)
            cursor.skipWhitespace()
            if cursor.matchWord("UserDefaults") { return true }
        }
        for start in wordOccurrences(of: "class", in: characters) {
            var cursor = SourceCursor(characters, at: start + "class".count)
            cursor.skipWhitespace()
            guard cursor.readIdentifier() != nil else { continue }
            cursor.skipWhitespace()
            guard cursor.match(":") else { continue }
            cursor.skipWhitespace()
            if cursor.matchWord("UserDefaults") { return true }
        }
        return false
    }

    /// The surfaces one call site yields.
    ///
    /// A call missing the requested label is usually a same-named method that is not a `UserDefaults`
    /// accessor (`formatter.string(from:)`) and yields nothing — UNLESS its argument list mentions
    /// `forKey` anyway, which means the label is spelled in a way the splitter could not read
    /// (`forKey : "k"`, a newline before the colon). That case yields a seam rather than nothing:
    /// dropping it silently is the one failure this wall must never have.
    static func callSurfaces(
        at openIndex: Int,
        labelled label: String?,
        in characters: [Character],
        file: String,
        anchor: String
    ) -> [DiscoveredSurface] {
        switch argument(labelled: label, ofCallAt: openIndex, in: characters) {
        case .missingLabel(let arguments):
            guard let label else {
                return [DiscoveredSurface(token: "unresolved:appStorage@\(file)", file: file, anchor: anchor)]
            }
            guard identifiers(in: arguments).contains(label) else { return [] }
            return [DiscoveredSurface(token: "unresolved:missingLabel@\(file)", file: file, anchor: anchor)]
        case .unbalanced:
            return [DiscoveredSurface(token: "unresolved:unbalanced@\(file)", file: file, anchor: anchor)]
        case .expression(let expression):
            return keyTokens(for: expression, inFile: characters, file: file)
                .map { DiscoveredSurface(token: $0, file: file, anchor: anchor) }
        }
    }

    /// The result of reading one argument out of a call's parentheses.
    enum CallArgument: Equatable {
        /// The argument text, trimmed, with its label removed.
        case expression(String)
        /// The call has no argument with that label. Carries the raw argument list so the caller can
        /// tell "a different method entirely" from "the label is there, spelled unreadably".
        case missingLabel(arguments: String)
        /// The parentheses never close. Reported, never dropped.
        case unbalanced
    }

    /// Reads the argument labelled `label` (or the first positional argument when `label` is nil) out
    /// of the parenthesised list opening at `openIndex`.
    ///
    /// String-aware, so a `"…(…)"` literal inside the call cannot unbalance the walk, and depth-aware,
    /// so a nested call's own `forKey:` is not mistaken for this one's.
    static func argument(labelled label: String?, ofCallAt openIndex: Int, in characters: [Character]) -> CallArgument {
        guard openIndex >= 0, openIndex < characters.count, characters[openIndex] == "(" else { return .unbalanced }
        var depth = 0
        var index = openIndex
        var inString = false
        var start = openIndex + 1
        while index < characters.count {
            let character = characters[index]
            if inString {
                if character == "\\" { index += 2; continue }
                if character == "\"" { inString = false }
                index += 1
                continue
            }
            if character == "\"" { inString = true; index += 1; continue }
            if character == "(" {
                depth += 1
                if depth == 1 { start = index + 1 }
            } else if character == ")" {
                depth -= 1
                if depth == 0 { return argument(labelled: label, from: String(characters[start..<index])) }
            }
            index += 1
        }
        return .unbalanced
    }

    /// Picks one argument out of an already-extracted argument list.
    ///
    /// Labels are compared STRUCTURALLY — split at the first top-level colon, trim, compare — rather
    /// than by a raw `hasPrefix("forKey:")`. `forKey : "k"` and a newline before the colon are both
    /// legal Swift with no diagnostic, and both used to make the whole call vanish.
    static func argument(labelled label: String?, from arguments: String) -> CallArgument {
        let parts = topLevelArguments(arguments).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let label else {
            // `@AppStorage(wrappedValue: x, "key")` puts the key second. Never drop it silently.
            let positional = parts.filter { labelSplit(of: $0)?.label != "wrappedValue" }
            guard let first = positional.first, !first.isEmpty else { return .missingLabel(arguments: arguments) }
            return .expression(first)
        }
        for part in parts {
            guard let split = labelSplit(of: part), split.label == label else { continue }
            return .expression(split.value)
        }
        return .missingLabel(arguments: arguments)
    }

    /// One argument split at its first TOP-LEVEL colon: the label and the value, both trimmed. Nil
    /// when the argument carries no label at all.
    static func labelSplit(of part: String) -> (label: String, value: String)? {
        let characters = Array(part)
        var depth = 0
        var inString = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if inString {
                if character == "\\" { index += 2; continue }
                if character == "\"" { inString = false }
                index += 1
                continue
            }
            if character == "\"" { inString = true; index += 1; continue }
            if "([{".contains(character) { depth += 1 }
            if ")]}".contains(character) { depth -= 1 }
            if character == ":", depth == 0 {
                let label = String(characters[0..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(characters[(index + 1)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return (label, value)
            }
            index += 1
        }
        return nil
    }

    /// Splits an argument list on its top-level commas, ignoring commas inside nested brackets or
    /// string literals.
    static func topLevelArguments(_ text: String) -> [String] {
        let characters = Array(text)
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inString = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if inString {
                current.append(character)
                if character == "\\", index + 1 < characters.count {
                    current.append(characters[index + 1])
                    index += 2
                    continue
                }
                if character == "\"" { inString = false }
                index += 1
                continue
            }
            if character == "\"" { inString = true }
            if "([{".contains(character) { depth += 1 }
            if ")]}".contains(character) { depth -= 1 }
            if character == ",", depth == 0 {
                parts.append(current)
                current = ""
                index += 1
                continue
            }
            current.append(character)
            index += 1
        }
        parts.append(current)
        return parts
    }

    // MARK: - Matcher: key resolution

    /// Every token a key expression resolves to. **Never empty** — an unresolvable key becomes an
    /// `unresolved:<expression>@<file>` token that requires a disposition row exactly like a literal
    /// one. That is the single most important rule in this file: a dropped key is an invisible surface.
    ///
    /// Four shapes, in order: an inline literal is the key; an interpolated literal contributes its
    /// literal prefix as a `prefix*` family; an identifier, dotted path, `.rawValue` case or same-file
    /// function call resolves against a literal DECLARED for that terminal symbol in the SAME file;
    /// anything else is unresolved. A dotted path additionally requires this file to declare the
    /// qualifier, so `NewDefaults.storageKey` cannot bind to an unrelated local named `storageKey` two
    /// functions away. When a symbol is bound to several different literals in one file, every
    /// candidate is emitted — over-reporting a real key is safe, silently picking the wrong one is not.
    static func keyTokens(for expression: String, inFile characters: [Character], file: String) -> [String] {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [unresolvedToken(for: trimmed, file: file)] }
        if let body = stringLiteralBody(trimmed) {
            return literalTokens(forBody: body, inFile: characters, file: file, expression: trimmed)
        }
        guard let symbol = terminalSymbol(of: trimmed) else { return [unresolvedToken(for: trimmed, file: file)] }
        if let owner = qualifier(of: trimmed), owner != "Self", !declaresType(owner, inFile: characters) {
            return [unresolvedToken(for: trimmed, file: file)]
        }
        let candidates = literalCandidates(for: symbol, inFile: characters)
        let resolved = uniqued(candidates.compactMap { token(forLiteralBody: $0) })
        return resolved.isEmpty ? [unresolvedToken(for: trimmed, file: file)] : resolved
    }

    /// The tokens an inline string literal yields: the key, a `prefix*` family, or a seam when the
    /// prefix is too broad to mean anything.
    static func literalTokens(
        forBody body: String,
        inFile characters: [Character],
        file: String,
        expression: String
    ) -> [String] {
        if let literalToken = token(forLiteralBody: body) { return [literalToken] }
        guard body.hasPrefix("\\(") else { return ["unresolved:shortFamilyPrefix@\(file)"] }
        let leading = leadingInterpolationTokens(body, inFile: characters)
        return leading.isEmpty ? [unresolvedToken(for: expression, file: file)] : leading
    }

    /// `keyTokens(for:inFile:file:)` over a source STRING — the fixture-facing spelling. The
    /// character array is what the tree walk threads through, so one file is converted once rather
    /// than once per symbolic call site.
    static func keyTokens(for expression: String, in source: String, file: String) -> [String] {
        keyTokens(for: expression, inFile: Array(source), file: file)
    }

    /// A literal body's token: the key itself, or a `prefix*` family when the literal interpolates.
    /// Nil when the literal STARTS with its interpolation (no prefix to key a family on) or when the
    /// prefix is too broad to be a family at all — see ``familyPrefixIsSpecific(_:)``.
    static func token(forLiteralBody body: String) -> String? {
        guard let interpolation = body.range(of: "\\(") else { return body }
        let prefix = String(body[body.startIndex..<interpolation.lowerBound])
        guard familyPrefixIsSpecific(prefix) else { return nil }
        return prefix + "*"
    }

    /// Whether a family prefix names something narrower than a whole namespace.
    ///
    /// One interpolated write of `"fernlet.\(feature).state"` mints the token `fernlet.*`, and the only
    /// row shape that can cover that token is a `fernlet.*` family — which then blankets every
    /// `fernlet.`-prefixed key the app will ever have. Two dot-separated components is the floor;
    /// anything broader becomes a seam somebody has to argue for.
    static func familyPrefixIsSpecific(_ prefix: String) -> Bool {
        prefix.split(separator: ".").count >= 2
    }

    /// `"\(Keys.prefix)\(id)"` — the literal opens with its interpolation, so the family prefix is
    /// whatever that first interpolated symbol resolves to in this file.
    static func leadingInterpolationTokens(_ body: String, inFile characters: [Character]) -> [String] {
        guard body.hasPrefix("\\(") else { return [] }
        let inner = interpolatedExpression(body)
        guard let symbol = terminalSymbol(of: inner) else { return [] }
        return uniqued(literalCandidates(for: symbol, inFile: characters).compactMap { candidate in
            guard let resolved = token(forLiteralBody: candidate) else { return nil }
            return resolved.hasSuffix("*") ? resolved : resolved + "*"
        })
    }

    /// The expression inside a literal's leading `\(…)`, by paren balance.
    static func interpolatedExpression(_ body: String) -> String {
        let characters = Array(body)
        guard characters.count > 2 else { return "" }
        var depth = 1
        var index = 2
        var inner = ""
        while index < characters.count {
            let character = characters[index]
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 { return inner }
            }
            inner.append(character)
            index += 1
        }
        return inner
    }

    /// The body of `expression` when it is exactly one string literal, else nil. The "exactly"
    /// matters: `"a" + suffix` starts and ends with a quote but is not a literal key.
    static func stringLiteralBody(_ expression: String) -> String? {
        let characters = Array(expression)
        guard characters.first == "\"" else { return nil }
        var index = 1
        var body = ""
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                body.append(character)
                body.append(characters[index + 1])
                index += 2
                continue
            }
            if character == "\"" { return index == characters.count - 1 ? body : nil }
            body.append(character)
            index += 1
        }
        return nil
    }

    /// The identifier a key expression is keyed on: the last component of a dotted path
    /// (`Key.petCount` → `petCount`), the case name of a raw-value path (`Key.lastMood.rawValue` →
    /// `lastMood`), or the name of a called function (`Self.key(for: corpus)` → `key`).
    ///
    /// Nil for a ternary, an operator expression, `$0` — and for a TYPE-shaped head, which is what
    /// `String(format: "…", id)` is. `terminalSymbol` used to return `String` for that, and searching
    /// the file for the word `String` matched every `: String = "…"` annotation, so the surface was
    /// reported under whatever key that annotated binding held.
    static func terminalSymbol(of expression: String) -> String? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = String(trimmed.prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty else { return nil }
        guard head.count == trimmed.count || trimmed.hasSuffix(")") else { return nil }
        guard head.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) else { return nil }
        var components = head.components(separatedBy: ".")
        if components.count > 1, components.last == "rawValue" { components.removeLast() }
        guard let last = components.last, let initial = last.first else { return nil }
        guard initial.isLetter || initial == "_" else { return nil }
        guard !initial.isUppercase else { return nil }
        return last
    }

    /// The first component of a dotted key expression (`FernletThemeDefaults.customDarkBackgroundKey`
    /// → `FernletThemeDefaults`), or nil when the expression is a bare symbol.
    static func qualifier(of expression: String) -> String? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = String(trimmed.prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces)
        let components = head.components(separatedBy: ".")
        guard components.count > 1, let first = components.first, !first.isEmpty else { return nil }
        return first
    }

    /// Whether this file declares a type called `name`.
    static func declaresType(_ name: String, inFile characters: [Character]) -> Bool {
        for keyword in typeDeclarationKeywords {
            for start in wordOccurrences(of: keyword, in: characters) {
                var cursor = SourceCursor(characters, at: start + keyword.count)
                cursor.skipWhitespace()
                if cursor.matchWord(name) { return true }
            }
        }
        return false
    }

    /// Every string literal DECLARED for `symbol` in this file, by the four same-file shapes the app
    /// actually uses: `let/var symbol = "…"`, `case symbol = "…"` (a raw-value enum), an initializer
    /// default argument `symbol: String = "…"` (Fernlet's test-injection idiom), and a
    /// single-expression `func symbol(…) -> String { "…" }`.
    ///
    /// Two rules keep the resolution honest rather than merely willing:
    ///
    /// - **The occurrence must be a declaration site.** A bare word search over the file bound
    ///   `NewDefaults.storageKey` to an unrelated `let storageKey = "fernlet.recentActivityTypes"`
    ///   three functions away — and because one candidate SUPPRESSES the unresolved fallback, the real
    ///   key was never named anywhere. 117 shipping files carry a binding available to shadow like that.
    /// - **A symbol that is ever mutated resolves to nothing.** `var key = "…"; key += ".v2"` used to
    ///   resolve to the PREFIX, so the table named a key that is not the key.
    static func literalCandidates(for symbol: String, inFile characters: [Character]) -> [String] {
        guard !symbol.isEmpty, !isReassigned(symbol, inFile: characters) else { return [] }
        var found: [String] = []
        for start in wordOccurrences(of: symbol, in: characters) where declarationPrecedes(start, in: characters) {
            var cursor = SourceCursor(characters, at: start + symbol.count)
            if let literal = cursor.readBindingLiteral() { found.append(literal) }
        }
        let declaration = "func \(symbol)"
        for start in wordOccurrences(of: declaration, in: characters) {
            var cursor = SourceCursor(characters, at: start + declaration.count)
            if let literal = cursor.readStringReturningBody() { found.append(literal) }
        }
        return uniqued(found)
    }

    /// `literalCandidates(for:inFile:)` over a source STRING — the fixture-facing spelling.
    static func literalCandidates(for symbol: String, in source: String) -> [String] {
        literalCandidates(for: symbol, inFile: Array(source))
    }

    /// Whether the symbol occurrence at `start` is a DECLARATION: introduced by `let`, `var` or
    /// `case`, or sitting in a parameter position (immediately after `(` or `,`). Whitespace and
    /// newlines are skipped, because Fernlet's injectable initializers put each parameter on its own
    /// line.
    static func declarationPrecedes(_ start: Int, in characters: [Character]) -> Bool {
        var index = start - 1
        while index >= 0, characters[index].isWhitespace { index -= 1 }
        guard index >= 0 else { return false }
        if characters[index] == "(" || characters[index] == "," { return true }
        let end = index + 1
        while index >= 0, isIdentifierCharacter(characters[index]) { index -= 1 }
        let word = String(characters[(index + 1)..<end])
        return word == "let" || word == "var" || word == "case"
    }

    /// Whether `symbol` is ever the target of a compound assignment in this file.
    static func isReassigned(_ symbol: String, inFile characters: [Character]) -> Bool {
        for start in wordOccurrences(of: symbol, in: characters) {
            var cursor = SourceCursor(characters, at: start + symbol.count)
            cursor.skipInlineWhitespace()
            if cursor.match("+=") { return true }
        }
        return false
    }

    /// The token an unresolvable key expression gets: the whole expression with its whitespace
    /// normalised, plus the file.
    ///
    /// The file and NOT the line, deliberately. A line-keyed table breaks on every unrelated edit to
    /// the same file, which teaches people to renumber the wall instead of reading it. The whole
    /// EXPRESSION and not just its last identifier, equally deliberately: `unresolved:storageKey@…`
    /// absorbed any later seam in that file whose expression also ended in `storageKey`, so the second
    /// such surface inherited the first one's disposition and required nothing.
    static func unresolvedToken(for expression: String, file: String) -> String {
        let normalised = expression.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return "unresolved:\(normalised.isEmpty ? "expression" : normalised)@\(file)"
    }

    /// Every maximal identifier run in `text` — a leading letter or underscore, then identifier
    /// characters. Digits cannot start one, so `$0` contributes nothing.
    static func identifiers(in text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for character in text {
            if current.isEmpty {
                if character.isLetter || character == "_" { current.append(character) }
                continue
            }
            if isIdentifierCharacter(character) {
                current.append(character)
                continue
            }
            runs.append(current)
            current = ""
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    // MARK: - Matcher: primitives

    /// Indices where `needle` occurs in `characters`.
    static func occurrences(of needle: String, in characters: [Character]) -> [Int] {
        let target = Array(needle)
        guard !target.isEmpty, characters.count >= target.count else { return [] }
        var hits: [Int] = []
        for start in 0...(characters.count - target.count) {
            guard characters[start] == target[0] else { continue }
            var matched = true
            var offset = 1
            while offset < target.count {
                if characters[start + offset] != target[offset] { matched = false; break }
                offset += 1
            }
            if matched { hits.append(start) }
        }
        return hits
    }

    /// Indices where `word` occurs with a non-identifier character on each side, so `key` does not
    /// match inside `monkeyKey`.
    static func wordOccurrences(of word: String, in characters: [Character]) -> [Int] {
        occurrences(of: word, in: characters).filter { start in
            if start > 0, isIdentifierCharacter(characters[start - 1]) { return false }
            let after = start + word.count
            if after < characters.count, isIdentifierCharacter(characters[after]) { return false }
            return true
        }
    }

    /// Indices of the `.` in every `.method` member reference whose next character cannot continue the
    /// identifier — so `.set` never matches inside `.setValue`.
    static func memberOccurrences(of method: String, in characters: [Character]) -> [Int] {
        occurrences(of: ".\(method)", in: characters).filter { start in
            let after = start + method.count + 1
            guard after < characters.count else { return true }
            return !isIdentifierCharacter(characters[after])
        }
    }

    /// The opening parenthesis of every `.method(` call, tolerating spaces and tabs between the two.
    static func memberCallOpenings(of method: String, in characters: [Character]) -> [Int] {
        memberOccurrences(of: method, in: characters).compactMap {
            openParenthesis(after: $0 + method.count + 1, in: characters)
        }
    }

    /// The opening parenthesis of every receiver-less `method(` call.
    static func bareCallOpenings(of method: String, in characters: [Character]) -> [Int] {
        wordOccurrences(of: method, in: characters)
            .filter { $0 == 0 || characters[$0 - 1] != "." }
            .compactMap { openParenthesis(after: $0 + method.count, in: characters) }
    }

    /// The index of the `(` at or just after `index`, skipping spaces and tabs but never a newline —
    /// a call whose parenthesis is on the next line is a different expression, not a spaced call.
    static func openParenthesis(after index: Int, in characters: [Character]) -> Int? {
        var cursor = index
        while cursor < characters.count, characters[cursor] == " " || characters[cursor] == "\t" { cursor += 1 }
        guard cursor < characters.count, characters[cursor] == "(" else { return nil }
        return cursor
    }

    /// The identifier immediately before `dotIndex` — the receiver of a `.method(…)` call. Empty when
    /// the member reference has no plain-identifier receiver (a closing paren, a bracket, `self`-less
    /// leading dot syntax).
    static func receiver(before dotIndex: Int, in characters: [Character]) -> String {
        var index = dotIndex - 1
        let end = index + 1
        while index >= 0, isIdentifierCharacter(characters[index]) { index -= 1 }
        guard index + 1 < end else { return "" }
        return String(characters[(index + 1)..<end])
    }

    /// Whether `character` can appear inside a Swift identifier.
    static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// `values` with later duplicates dropped, order preserved.
    static func uniqued(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    /// A forward-only cursor over one file's characters, used by the key resolvers.
    ///
    /// Every method advances only on a match, so a failed step leaves the cursor where the caller can
    /// try another shape. Pure and bounded: nothing here reads disk, and every loop is bounded by the
    /// character count.
    struct SourceCursor {
        /// The file's characters.
        let characters: [Character]
        /// The next character to read.
        var index: Int

        /// Positions the cursor at `index` in `characters`.
        init(_ characters: [Character], at index: Int) {
            self.characters = characters
            self.index = index
        }

        /// Advances past whitespace and newlines.
        mutating func skipWhitespace() {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
        }

        /// Advances past spaces and tabs but STOPS at a newline. Used by the binding reader, so a
        /// `let key: String` declaration cannot reach across lines and adopt the next statement's
        /// `= "…"` as its own literal.
        mutating func skipInlineWhitespace() {
            while index < characters.count, characters[index].isWhitespace, !characters[index].isNewline {
                index += 1
            }
        }

        /// Consumes `text` and returns true, or leaves the cursor alone and returns false.
        mutating func match(_ text: String) -> Bool {
            let target = Array(text)
            guard index + target.count <= characters.count else { return false }
            for offset in 0..<target.count where characters[index + offset] != target[offset] { return false }
            index += target.count
            return true
        }

        /// `match`, but refusing a match that runs into an identifier character — so `return` does not
        /// match inside `returnedValue`.
        mutating func matchWord(_ word: String) -> Bool {
            let saved = index
            guard match(word) else { return false }
            guard index < characters.count,
                  PersistedSurfaceWipeBoundaryTests.isIdentifierCharacter(characters[index])
            else { return true }
            index = saved
            return false
        }

        /// Reads an identifier at the cursor, or nil when there is none.
        mutating func readIdentifier() -> String? {
            var name = ""
            while index < characters.count,
                  PersistedSurfaceWipeBoundaryTests.isIdentifierCharacter(characters[index]) {
                name.append(characters[index])
                index += 1
            }
            return name.isEmpty ? nil : name
        }

        /// Consumes a balanced `(…)` group starting at the cursor.
        mutating func skipParenthesisGroup() -> Bool {
            guard index < characters.count, characters[index] == "(" else { return false }
            var depth = 0
            while index < characters.count {
                if characters[index] == "(" { depth += 1 }
                if characters[index] == ")" {
                    depth -= 1
                    if depth == 0 { index += 1; return true }
                }
                index += 1
            }
            return false
        }

        /// Reads a `"…"` literal at the cursor and returns its body, escapes intact.
        mutating func readStringLiteral() -> String? {
            guard index < characters.count, characters[index] == "\"" else { return nil }
            var body = ""
            index += 1
            while index < characters.count {
                let character = characters[index]
                if character == "\\", index + 1 < characters.count {
                    body.append(character)
                    body.append(characters[index + 1])
                    index += 2
                    continue
                }
                if character == "\"" { index += 1; return body }
                body.append(character)
                index += 1
            }
            return nil
        }

        /// Reads the literal of a `… = "…"` binding at the cursor — a stored property, an enum case's
        /// raw value, or an initializer's default argument. The optional `: String` annotation is
        /// tolerated.
        mutating func readBindingLiteral() -> String? {
            skipInlineWhitespace()
            if match(":") {
                skipInlineWhitespace()
                guard matchWord("String") else { return nil }
                skipInlineWhitespace()
            }
            guard match("=") else { return nil }
            skipInlineWhitespace()
            return readStringLiteral()
        }

        /// Reads the literal of a single-expression `(…) -> String { "…" }` function body at the
        /// cursor. Single-expression only: a multi-statement body could contain any number of
        /// unrelated literals, and guessing among them is how a wall starts reporting wrong keys.
        mutating func readStringReturningBody() -> String? {
            guard skipParenthesisGroup() else { return nil }
            skipWhitespace()
            guard match("->") else { return nil }
            skipWhitespace()
            guard matchWord("String") else { return nil }
            skipWhitespace()
            guard match("{") else { return nil }
            skipWhitespace()
            _ = matchWord("return")
            skipWhitespace()
            guard let literal = readStringLiteral() else { return nil }
            skipWhitespace()
            return match("}") ? literal : nil
        }
    }

    // MARK: - Matcher: the table checks

    /// Whether row `key` accounts for `token` — the same key, or a `prefix*` family covering a
    /// narrower family beneath it.
    ///
    /// A family covers families, never concrete literal siblings. A family token is only ever MINTED
    /// by interpolation, and the clear behind it is invariably a loop over an enum's `allCases`, so a
    /// hand-written sibling that is not one of those cases is never removed — and
    /// `fernlet.sealedBackup.generation.*` happily accounted for it while promising it was wiped.
    static func row(_ key: String, covers token: String) -> Bool {
        if key == token { return true }
        guard key.hasSuffix("*"), token.hasSuffix("*") else { return false }
        return token.hasPrefix(String(key.dropLast()))
    }

    /// Discovered tokens with no disposition row, sorted.
    static func undeclaredSurfaces(_ discovered: Set<String>, table: [String: Disposition]) -> [String] {
        discovered.filter { token in !table.keys.contains { row($0, covers: token) } }.sorted()
    }

    /// Disposition rows nothing in the tree discovers any more, sorted. A stale row is a hole: it
    /// looks like coverage and enforces nothing.
    static func staleRows(_ discovered: Set<String>, table: [String: Disposition]) -> [String] {
        table.keys.filter { key in !discovered.contains { row(key, covers: $0) } }.sorted()
    }

    /// Family rows discovery does not mint, sorted.
    ///
    /// A family row must be a token the scan really produced. Invented ones are the cheapest possible
    /// bypass of the whole wall: `"*"` has the empty prefix, so with one `.unreachableByDesign` line —
    /// the only disposition that needs no doc row — every surface the app will ever have is covered,
    /// no row goes stale, and all three checks stay green over a store nobody declared.
    static func inventedFamilyRows(_ discovered: Set<String>, table: [String: Disposition]) -> [String] {
        table.keys.filter { $0.hasSuffix("*") && !discovered.contains($0) }.sorted()
    }

    /// Seam rows whose call-site count is missing or has grown, sorted.
    static func seamSiteFailures(_ surfaces: [String: [DiscoveredSurface]], expected: [String: Int]) -> [String] {
        var failures: [String] = []
        for token in surfaces.keys.sorted() where token.hasPrefix("unresolved:") {
            let sites = (surfaces[token] ?? []).count
            guard let allowed = expected[token] else {
                failures.append("\(token) has \(sites) call site(s) and no entry in expectedSeamSites")
                continue
            }
            if sites > allowed {
                failures.append("\(token) now covers \(sites) call sites, up from the declared \(allowed) — a NEW surface is hiding behind an existing seam's disposition")
            }
        }
        for token in expected.keys.sorted() where surfaces[token] == nil {
            failures.append("\(token) is declared in expectedSeamSites but nothing discovers it any more")
        }
        return failures
    }

    /// One disposition that does not hold up.
    struct DispositionFailure: Hashable, CustomStringConvertible {
        /// The row's key.
        let key: String
        /// What is wrong with it.
        let detail: String

        var description: String { "\(key): \(detail)" }
    }

    /// The minimum length of a survivor's reason. Short enough to write, long enough that "legacy" or
    /// "not needed" cannot pass for a decision.
    static let minimumKeptReasonLength = 40

    /// The minimum word count of a survivor's reason. The length floor alone accepted
    /// `String(repeating: "y", count: 40)` — and the suite's own fixture used to PIN that as a
    /// passing row, which is the clearest possible proof that a character count is not a decision.
    static let minimumKeptReasonWords = 8

    /// The parts of Docs/PrivacyWipeCoverage.md a disposition can be checked against.
    ///
    /// Table rows and backticked spans, never free text. The old check was `section.contains(key)`
    /// over 18 KB of prose, which any key that is a SUBSTRING of existing text satisfies —
    /// `fernlet.breathing.preset` inside the documented `fernlet.breathing.presetID`,
    /// `fernletAppearance` inside `fernletAppearanceMode`, and `*` in 134 places.
    struct CoverageDocument {
        /// One entry per table row of the whole document: the backticked spans on that row.
        let rowSpans: [Set<String>]
        /// Backticked spans on table rows under "## Deliberate exceptions".
        let exceptionKeys: Set<String>
        /// Backticked spans on table rows under "## Open gaps".
        let openGapKeys: Set<String>

        /// Whether ONE table row names both `key` and `token`.
        ///
        /// This is the only place the two halves of a `.cleared` row are tied together. `.cleared`
        /// used to check the token twice and the key never, which made it the cheapest disposition to
        /// declare AND the only one that certified nothing: one line naming any existing manifest
        /// token marked any new surface wiped.
        func pairs(_ key: String, with token: String) -> Bool {
            rowSpans.contains { $0.contains(key) && $0.contains(token) }
        }

        /// Parses the evidence out of the document text.
        static func parsing(_ document: String) -> CoverageDocument {
            CoverageDocument(
                rowSpans: tableRowSpans(in: document),
                exceptionKeys: keys(in: section("## Deliberate exceptions", of: document)),
                openGapKeys: keys(in: section("## Open gaps", of: document))
            )
        }

        /// The backticked spans of every table row in `text`, one set per row.
        static func tableRowSpans(in text: String) -> [Set<String>] {
            text.components(separatedBy: "\n")
                .filter { $0.contains("|") }
                .map { Set(backtickedSpans(in: $0)) }
        }

        /// Every backticked span on any table row of `text`.
        static func keys(in text: String) -> Set<String> {
            tableRowSpans(in: text).reduce(into: Set<String>()) { $0.formUnion($1) }
        }

        /// The backticked spans of one line: the odd-indexed pieces of a split on the backtick.
        static func backtickedSpans(in line: String) -> [String] {
            let parts = line.components(separatedBy: "`")
            return parts.indices.filter { $0 % 2 == 1 }.map { parts[$0] }
        }

        /// The text between a `## ` heading and the next one.
        static func section(_ heading: String, of document: String) -> String {
            guard let start = document.range(of: heading) else { return "" }
            let tail = document[start.upperBound...]
            return String(tail.range(of: "\n## ").map { tail[..<$0.lowerBound] } ?? tail)
        }
    }

    /// Every row that does not meet its own requirements.
    ///
    /// Pure over its inputs so the planted fixtures can drive it directly: a weak row must be caught
    /// by the checker, not merely absent from today's table.
    static func unmetDispositions(
        table: [String: Disposition],
        wipePath: String,
        manifest: [String],
        declarationLines: [String],
        document: CoverageDocument
    ) -> [DispositionFailure] {
        var failures: [DispositionFailure] = []
        for key in table.keys.sorted() {
            guard let disposition = table[key] else { continue }
            switch disposition {
            case .cleared(let token):
                failures += clearedFailures(
                    key: key, token: token, wipePath: wipePath,
                    manifest: manifest, declarationLines: declarationLines, document: document
                )
            case .kept(let reason):
                failures += survivorFailures(
                    key: key, reason: reason, verb: "kept",
                    documented: document.exceptionKeys, section: "Deliberate exceptions"
                )
            case .unreachableByDesign(let reason):
                failures += survivorFailures(
                    key: key, reason: reason, verb: "declared unreachable by design",
                    documented: document.exceptionKeys, section: "Deliberate exceptions"
                )
            case .openGap(let reason):
                failures += survivorFailures(
                    key: key, reason: reason, verb: "declared an open gap",
                    documented: document.openGapKeys, section: "Open gaps"
                )
            }
        }
        return failures
    }

    /// The four obligations of a `.cleared` row.
    static func clearedFailures(
        key: String,
        token: String,
        wipePath: String,
        manifest: [String],
        declarationLines: [String],
        document: CoverageDocument
    ) -> [DispositionFailure] {
        var failures: [DispositionFailure] = []
        if !callIsPresent(token, in: wipePath) {
            failures.append(DispositionFailure(key: key, detail: "declared cleared by '\(token)', which the DEBUG-stripped wipe path does not CALL. Either the call was deleted, it only ever ran in DEBUG, it was renamed to something narrower that merely starts with this spelling, or the name survives only inside a string literal."))
        }
        if !manifest.contains(token) {
            failures.append(DispositionFailure(key: key, detail: "declared cleared by '\(token)', which PrivacyWipeCoverageTests.wipeManifest does not enforce. Add the token there (with its doc row) so both walls judge the same funnel."))
        }
        if declarationLines.contains(where: { $0.contains(token) }) {
            failures.append(DispositionFailure(key: key, detail: "declared cleared by '\(token)', which is a substring of a registered wipe function's own DECLARATION line. The extractor includes that line, so the token can never fail — even with an empty body and no caller. Spell the token so only the call site carries it."))
        }
        if !document.pairs(key, with: token) {
            failures.append(DispositionFailure(key: key, detail: "declared cleared by '\(token)', but no table row of Docs/PrivacyWipeCoverage.md names BOTH `\(key)` and `\(token)`. Without that pairing the row proves only that some call exists somewhere — not that it has anything to do with this key."))
        }
        return failures
    }

    /// The three obligations of a row that says a surface survives — `.kept`, `.unreachableByDesign`
    /// or `.openGap`. They carry the same burden deliberately: it must never be cheaper to say "this
    /// is not really a surface" than to say "this survives on purpose".
    static func survivorFailures(
        key: String,
        reason: String,
        verb: String,
        documented: Set<String>,
        section: String
    ) -> [DispositionFailure] {
        var failures: [DispositionFailure] = []
        if reason.count < minimumKeptReasonLength {
            failures.append(DispositionFailure(key: key, detail: "\(verb) with a \(reason.count)-character reason. Say why, in a sentence."))
        } else if !reasonReadsAsADecision(reason) {
            failures.append(DispositionFailure(key: key, detail: "\(verb) with a reason that clears the length floor without saying anything (fewer than \(minimumKeptReasonWords) words, or padding). The floor filters one-word non-answers; the sentence is for the reviewer."))
        }
        if !documented.contains(key) {
            failures.append(DispositionFailure(key: key, detail: "\(verb), but `\(key)` is not a backticked span on any table ROW of the '\(section)' section of Docs/PrivacyWipeCoverage.md. A surface nobody wrote down is indistinguishable from one nobody noticed — and a key that merely appears somewhere in the prose is not a row."))
        }
        return failures
    }

    /// Whether a reason is a sentence rather than padding that clears the character floor.
    static func reasonReadsAsADecision(_ reason: String) -> Bool {
        let words = reason.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= minimumKeptReasonWords else { return false }
        return Set(reason.filter { !$0.isWhitespace }).count >= 8
    }

    /// Whether `token` appears in `path` as a CALL: not preceded by an identifier character or a dot,
    /// and followed by `(` — optionally through an optional-chaining `?`, which is how the live
    /// `worryBoxResetHook?()` is spelled.
    ///
    /// A bare `contains` accepted two things it should not. A NARROWING rename kept it green:
    /// `generationStore.reset` is a substring of `generationStore.resetPhotoNamespace()`, which
    /// clears a strictly smaller set. And a token named inside a string literal counted as a call —
    /// the funnel already carries 41 machine-readable event strings, one of which is four characters
    /// from satisfying a manifest token by itself. (The literals are blanked before this runs; this is
    /// the second half of the same fix.)
    static func callIsPresent(_ token: String, in path: String) -> Bool {
        let characters = Array(path)
        for start in occurrences(of: token, in: characters) {
            if start > 0, isIdentifierCharacter(characters[start - 1]) || characters[start - 1] == "." { continue }
            var cursor = SourceCursor(characters, at: start + token.count)
            cursor.skipInlineWhitespace()
            _ = cursor.match("?")
            cursor.skipInlineWhitespace()
            if cursor.match("(") { return true }
        }
        return false
    }

    /// The function-declaration lines of an extracted wipe path.
    ///
    /// `functionBody` returns each leg from its DECLARATION line down, so every registered signature
    /// is inside the text both walls search. A token that is a substring of one of those lines can
    /// never fail — an empty body with no caller satisfies it forever. Three hand-written comments in
    /// the other suite explain why particular tokens were spelled the way they were; this makes that
    /// convention enforceable instead of advisory.
    static func declarationLines(in wipePath: String) -> [String] {
        wipePath.components(separatedBy: "\n").filter(PrivacyWipeCoverageTests.isDeclarationLine)
    }

    /// Names of every function declared in `source`, at any access level.
    static func declaredFunctionNames(in source: String) -> Set<String> {
        let characters = Array(PrivacyWipeCoverageTests.strippingCommentsAndStringLiteralBodies(source))
        var names: Set<String> = []
        for start in wordOccurrences(of: "func", in: characters) {
            var cursor = SourceCursor(characters, at: start + 4)
            cursor.skipWhitespace()
            if let name = cursor.readIdentifier() { names.insert(name) }
        }
        return names
    }

    /// The name a function-declaration line declares.
    static func declaredFunctionName(of line: String) -> String? {
        let characters = Array(line)
        guard let start = wordOccurrences(of: "func", in: characters).first else { return nil }
        var cursor = SourceCursor(characters, at: start + 4)
        cursor.skipWhitespace()
        return cursor.readIdentifier()
    }

    /// Functions declared in `storeSource` that `wipePath` calls but does not SCAN.
    static func unscannedCallees(in wipePath: String, storeSource: String) -> [String] {
        let scanned = Set(declarationLines(in: wipePath).compactMap(declaredFunctionName(of:)))
        return declaredFunctionNames(in: storeSource).filter { name in
            guard !scanned.contains(name) else { return false }
            return callIsPresent(name, in: wipePath) || wipePath.contains("Self.\(name)(")
        }.sorted()
    }

    // MARK: - The tree walk

    /// Shipping Swift files under `root`.
    ///
    /// Tests and DocC catalogs are excluded by name — a fixture's defaults key is not a shipping
    /// surface, and a doc page's code sample is not code — but finding one THROWS rather than
    /// skipping. Xcode's file-system-synchronized groups and SwiftPM both compile everything beneath
    /// a source directory, so a `Tests` folder inside a scan root would ship unscanned, and the
    /// exclusion is now the thing that has to justify itself. The check is against the path RELATIVE
    /// to the root, so a checkout directory that happens to be called `Tests` cannot silence it.
    static func shippingSwiftFiles(under root: String) throws -> [URL] {
        let rootURL = RepoRoot.url(root)
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
            throw DiscoveryError.emptyScanRoot(root)
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = relativePath(of: url, under: rootURL.path)
            let components = relative.components(separatedBy: "/")
            guard !components.contains("Tests"), !components.contains(where: { $0.hasSuffix(".docc") }) else {
                throw DiscoveryError.forbiddenScanDirectory("\(root)/\(relative)")
            }
            files.append(url)
        }
        guard !files.isEmpty else { throw DiscoveryError.emptyScanRoot(root) }
        return files
    }

    /// `url`'s path relative to `base`, or its last component when it is not beneath `base`.
    static func relativePath(of url: URL, under base: String) -> String {
        guard url.path.hasPrefix(base + "/") else { return url.lastPathComponent }
        return String(url.path.dropFirst(base.count + 1))
    }

    /// Top-level `App/` directories that hold Swift source and are not scan roots.
    ///
    /// The roots are a hard-coded list, and a hard-coded list is what a new target walks straight
    /// past: every `@AppStorage` in a new widget bundle, control extension or watch app would need no
    /// row and trip nothing. `FernletKit/Sources` needs no equivalent — a new module lands inside it.
    static func unscannedAppDirectories() throws -> [String] {
        let entries = try FileManager.default.contentsOfDirectory(
            at: RepoRoot.url("App"), includingPropertiesForKeys: nil
        )
        var offenders: [String] = []
        for entry in entries {
            let relative = "App/" + entry.lastPathComponent
            guard !scanRoots.contains(relative), holdsSwiftSource(entry) else { continue }
            offenders.append(relative)
        }
        return offenders.sorted()
    }

    /// Whether `directory` contains a Swift file at any depth.
    static func holdsSwiftSource(_ directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        for case let url as URL in enumerator where url.pathExtension == "swift" { return true }
        return false
    }

    /// One whole-tree discovery pass over every scan root.
    static func discover() throws -> DiscoveryRun {
        let rootPath = RepoRoot.url.path
        var surfacesByToken: [String: [DiscoveredSurface]] = [:]
        var filesPerRoot: [String: Int] = [:]
        var bannedSites: [String] = []
        for root in scanRoots {
            let files = try shippingSwiftFiles(under: root)
            filesPerRoot[root] = files.count
            for url in files {
                let relative = relativePath(of: url, under: rootPath)
                let source = try String(contentsOf: url, encoding: .utf8)
                for surface in try surfaces(in: source, file: relative) {
                    surfacesByToken[surface.token, default: []].append(surface)
                }
                bannedSites += bulkWriteSites(in: source, file: relative)
            }
        }
        return DiscoveryRun(
            surfaces: surfacesByToken, filesPerRoot: filesPerRoot, bulkWriteSites: bannedSites.sorted()
        )
    }

    /// The wipe path both walls judge, with `#if DEBUG` branches stripped.
    ///
    /// Built on `PrivacyWipeCoverageTests.wipePathSource()` — the same bounded, comment-stripped
    /// funnel-plus-hook-wiring text, never a second definition of it. Any preprocessor conditional at
    /// all throws first: stripping handles the DEBUG shapes, but `#if os(macOS)` in an iOS-only app is
    /// dead code the stripper deliberately leaves alone, and a clear inside it would certify a promise
    /// RELEASE never keeps. The funnel carries zero directives today, so the rule costs nothing.
    static func debugStrippedWipePath() throws -> String {
        let source = try PrivacyWipeCoverageTests.wipePathSource()
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#if") || trimmed.hasPrefix("#else") || trimmed.hasPrefix("#endif") else { continue }
            throw DiscoveryError.conditionalInWipePath(directive: trimmed)
        }
        return try strippingDebugBranches(source, file: "the wipe path")
    }

    /// The wipe path `.cleared` tokens are matched against: DEBUG-stripped, and with every string
    /// literal's BODY blanked so prose inside a literal cannot pass for a call.
    static func wipePathForTokenMatching() throws -> String {
        PrivacyWipeCoverageTests.strippingCommentsAndStringLiteralBodies(try debugStrippedWipePath())
    }

    /// Docs/PrivacyWipeCoverage.md.
    static func coverageDoc() throws -> String {
        try RepoRoot.source("Docs/PrivacyWipeCoverage.md")
    }

    // MARK: - Tests

    /// The wall itself: every persisted surface in the shipping sources carries a disposition.
    @Test func everyDiscoveredSurfaceIsDeclared() throws {
        let run = try Self.discover()
        let undeclared = Self.undeclaredSurfaces(Set(run.surfaces.keys), table: Self.dispositions)
        let detail = undeclared.map { token in
            let files = Set((run.surfaces[token] ?? []).map(\.file)).sorted().joined(separator: ", ")
            return "\(token) (written in: \(files))"
        }
        #expect(
            detail.isEmpty,
            """
            \(undeclared.count) persisted surface(s) with no row in PersistedSurfaceWipeBoundaryTests.dispositions:
            \(detail.joined(separator: "\n"))
            Decide what 'delete everything' does to each — clear it (.cleared, with the token in the funnel, the \
            manifest and paired with the key on one doc row), keep it (.kept, with its reason and a \
            Deliberate-exceptions row), rule it out (.unreachableByDesign, same burden), or say honestly that \
            nobody has decided (.openGap, listed under Open gaps).
            """
        )
    }

    /// The reverse direction. A row nothing discovers looks like coverage and enforces nothing — and
    /// on this wall it is also the signal that a matcher stopped matching.
    @Test func noDispositionRowIsStale() throws {
        let run = try Self.discover()
        let stale = Self.staleRows(Set(run.surfaces.keys), table: Self.dispositions)
        #expect(
            stale.isEmpty,
            "dispositions names \(stale), which nothing in the shipping sources declares any more. Drop the row if the surface is gone — but first check the key was not simply renamed, because a rename plus a stale row means the NEW key is undeclared and this suite is telling you both halves at once."
        )
        let invented = Self.inventedFamilyRows(Set(run.surfaces.keys), table: Self.dispositions)
        #expect(
            invented.isEmpty,
            "dispositions declares family row(s) \(invented) that discovery never minted. A family token comes from an interpolated literal and nowhere else, so an invented one is a wildcard: it silences surfaces instead of accounting for them."
        )
    }

    /// Every row keeps its own promise: a cleared surface names a call the funnel really makes, the
    /// other wall really enforces, and the doc really ties to THIS key; a survivor carries a real
    /// sentence and a documented table row.
    @Test func everyDispositionIsMet() throws {
        let wipePath = try Self.wipePathForTokenMatching()
        let document = Self.CoverageDocument.parsing(try Self.coverageDoc())
        let failures = Self.unmetDispositions(
            table: Self.dispositions,
            wipePath: wipePath,
            manifest: PrivacyWipeCoverageTests.wipeManifest,
            declarationLines: Self.declarationLines(in: wipePath),
            document: document
        )
        #expect(
            failures.isEmpty,
            "unmet disposition(s):\n\(failures.map(\.description).joined(separator: "\n"))"
        )
    }

    /// Every `unresolved:` seam declares how many call sites hide behind it, and none has grown.
    @Test func everySeamDeclaresItsCallSiteCount() throws {
        let run = try Self.discover()
        let failures = Self.seamSiteFailures(run.surfaces, expected: Self.expectedSeamSites)
        #expect(
            failures.isEmpty,
            """
            seam accounting is out of date:
            \(failures.joined(separator: "\n"))
            An unresolved row is the one row shape that can absorb a surface nobody has ever seen, so its site \
            count is the only thing standing between 'this seam' and 'everything routed through this seam'.
            """
        )
    }

    /// The floors against a vacuous pass. Every anchor here is a pattern, and a pattern that quietly
    /// stops matching turns this suite green by looking at less — which is the exact failure mode the
    /// wall exists to prevent, arriving through the wall itself.
    @Test func discoveryFloorsHold() throws {
        let run = try Self.discover()
        for root in Self.scanRoots {
            #expect((run.filesPerRoot[root] ?? 0) > 0, "scan root \(root) enumerated no shipping Swift files")
        }
        #expect(
            run.fileCount >= Self.minimumScannedFiles,
            "only \(run.fileCount) shipping Swift files scanned (floor \(Self.minimumScannedFiles)) — the tree moved, or an exclusion is eating real source."
        )
        // Ratcheted against the table, so "break a matcher and delete its rows in the same commit"
        // cannot hide in the slack a fixed number leaves behind.
        let surfaceFloor = max(Self.minimumDiscoveredSurfaces, Self.dispositions.count)
        #expect(
            run.surfaces.count >= surfaceFloor,
            "only \(run.surfaces.count) persisted surfaces discovered (floor \(surfaceFloor), which tracks the \(Self.dispositions.count)-row table) — the anchors or the key resolution stopped matching, and everything below this line is passing on a smaller scan."
        )
        let lost = Self.knownSurfaces.subtracting(run.surfaces.keys).sorted()
        #expect(
            lost.isEmpty,
            "discovery lost known surface(s) \(lost). Either they were genuinely removed from the app (drop them from knownSurfaces in the same commit as the deletion) or — far more likely — an anchor or a resolution rule stopped matching."
        )
        // A bulk write names no key, so it can never earn a disposition row — the choice is between
        // banning the spelling and letting the surface be invisible.
        #expect(
            run.bulkWriteSites.isEmpty,
            "banned bulk UserDefaults write(s) \(run.bulkWriteSites). setPersistentDomain / setValuesForKeys / setVolatileDomain persist without naming a key at any call site, so nothing here can discover what they wrote — write the keys individually instead."
        )
        let unscanned = try Self.unscannedAppDirectories()
        #expect(
            unscanned.isEmpty,
            "App directory \(unscanned) holds shipping Swift and is not a scan root. Every @AppStorage and UserDefaults write in it is outside this wall — add it to scanRoots in the same commit as the target."
        )
    }

    /// The wipe-path scan is not silently shrinking. The other wall enumerates by ACCESS LEVEL, so a
    /// leg spelled `func` or `private nonisolated func` escapes it; this enumerates by CALL.
    @Test func theWipePathScanIsNotSilentlyShrinking() throws {
        let wipePath = try Self.wipePathForTokenMatching()
        let store = try RepoRoot.source("App/Fernlet/FernletStore.swift")
        let unscanned = Set(Self.unscannedCallees(in: wipePath, storeSource: store))
        let unpinned = unscanned.subtracting(Self.unscannedWipePathCallees).sorted()
        #expect(
            unpinned.isEmpty,
            "the wipe path calls \(unpinned), whose bodies no registered signature covers and which unscannedWipePathCallees does not name. A clear moved into one of those is invisible to both walls — register it in PrivacyWipeCoverageTests.wipeFunctionSignatures, or pin it here with what it is."
        )
        let gone = Self.unscannedWipePathCallees.subtracting(unscanned).sorted()
        #expect(
            gone.isEmpty,
            "unscannedWipePathCallees names \(gone), which the wipe path no longer calls unqualified. Drop the entries rather than leaving a blanket exemption behind."
        )
    }

    /// The matchers, on planted source strings rather than files on disk, so a failure here points at
    /// the matcher and not at today's tree. These are the properties an attacker would probe first.
    @Test func plantedFixturesDriveTheMatchers() throws {
        let fixture = """
        struct Fixture {
            @AppStorage("fixture.b") private var flag = false
            static let namedKey = "fixture.named"
            private let injected: String
            init(injected: String = "fixture.injected") { self.injected = injected }
            static func familyKey(for id: String) -> String { "fixture.family.\\(id)" }
            func write(_ defaults: UserDefaults, _ object: NSManagedObject) {
                defaults.set(1, forKey: "fixture.key")
                defaults.removeObject(forKey: Self.namedKey)
                defaults.set(2, forKey: injected)
                defaults.set(3, forKey: Self.familyKey(for: id))
                defaults.set(4, forKey: assembledElsewhere)
                object.setValue(payload, forKey: "payloadData")
                _ = formatter.string(from: Date())
            }
        }
        """
        let tokens = Set(try Self.surfaces(in: fixture, file: "Fixture.swift").map(\.token))
        #expect(tokens.contains("fixture.key"), "an inline literal key is not discovered")
        #expect(tokens.contains("fixture.b"), "an @AppStorage literal key is not discovered")
        #expect(tokens.contains("fixture.named"), "a same-file constant key does not resolve")
        #expect(tokens.contains("fixture.injected"), "an initializer default-argument key does not resolve")
        #expect(tokens.contains("fixture.family.*"), "an interpolated key does not become a family token")
        #expect(
            tokens.contains("unresolved:assembledElsewhere@Fixture.swift"),
            "an unresolvable symbolic key was DROPPED instead of becoming an unresolved token — the one failure this wall must never have"
        )
        #expect(!tokens.contains("payloadData"), "Core Data's setValue(_:forKey:) is being matched as a UserDefaults write")
        #expect(tokens.count == 6, "unexpected extra surfaces: \(tokens.sorted())")
    }

    /// KVC is a real persisted write. `NSUserDefaults` routes `setValue(_:forKey:)` to
    /// `setObject(_:forKey:)`, so the key survives relaunch — but the exclusion that keeps Core Data's
    /// 62 KVC sites out of the results was receiver-blind and dropped defaults writes with them.
    @Test func theKeyValueCodingSpellingIsDiscovered() throws {
        let fixture = """
        struct Fixture {
            func write(_ defaults: UserDefaults, _ record: NSManagedObject) {
                defaults.setValue(1, forKey: "fixture.kvc")
                UserDefaults.standard.setValue(2, forKey: "fixture.kvc.standard")
                record.setValue(payload, forKey: "payloadData")
            }
        }
        """
        let tokens = Set(try Self.surfaces(in: fixture, file: "Fixture.swift").map(\.token))
        #expect(tokens.contains("fixture.kvc"), "a KVC defaults write is invisible — it needs no row and the wipe can leave it behind")
        #expect(tokens.contains("fixture.kvc.standard"), "a KVC write on UserDefaults.standard is invisible")
        #expect(!tokens.contains("payloadData"), "a Core Data KVC receiver is being reported as a defaults surface")
    }

    /// Inside `extension UserDefaults` the receiver is implicit, so there is no leading dot for the
    /// anchor to find. Zero files in the tree use the idiom today, which is exactly why it was worth
    /// closing: it is the shape the next defaults store takes.
    @Test func aUserDefaultsExtensionIsNotInvisible() throws {
        let fixture = """
        extension UserDefaults {
            var lastExportAt: Date? {
                get { object(forKey: "fixture.extension.key") as? Date }
                set { set(newValue, forKey: "fixture.extension.key") }
            }
        }
        """
        let tokens = Set(try Self.surfaces(in: fixture, file: "Fixture.swift").map(\.token))
        #expect(
            tokens.contains("fixture.extension.key"),
            "a receiver-less accessor inside `extension UserDefaults` is invisible — dropping `self.` is the whole evasion"
        )
        // …and the bare anchors stay switched OFF in an ordinary file, where `set(` and `object(` are
        // somebody else's methods.
        let ordinary = """
        struct Fixture {
            func write() { set(1, forKey: "fixture.not.defaults") }
        }
        """
        let ordinaryTokens = try Self.surfaces(in: ordinary, file: "Fixture.swift")
        #expect(
            ordinaryTokens.isEmpty,
            "the bare anchors are firing outside a UserDefaults extension — every same-named method in the app would need a row"
        )
    }

    /// A seam token names the WHOLE expression. Keyed on the last identifier, one
    /// `unresolved:storageKey@…` row absorbed every later seam in that file whose expression happened
    /// to end in `storageKey`, and the new surface inherited the old row's disposition.
    @Test func seamsAreKeyedOnTheWholeExpression() throws {
        let fixture = """
        struct Fixture {
            func a(_ defaults: UserDefaults) { defaults.set(1, forKey: FernletAppearanceMode.storageKey) }
            func b(_ defaults: UserDefaults) { defaults.set(2, forKey: SecretTracker.storageKey) }
        }
        """
        let tokens = Set(try Self.surfaces(in: fixture, file: "Fixture.swift").map(\.token))
        #expect(tokens.contains("unresolved:FernletAppearanceMode.storageKey@Fixture.swift"))
        #expect(
            tokens.contains("unresolved:SecretTracker.storageKey@Fixture.swift"),
            "two different seams collapsed into one token — the second surface needs no row and inherits the first one's disposition"
        )
        // The site count is the other half: the same expression twice is one seam, and it grew.
        let twice = ["unresolved:key@F.swift": [
            DiscoveredSurface(token: "unresolved:key@F.swift", file: "F.swift", anchor: ".set"),
            DiscoveredSurface(token: "unresolved:key@F.swift", file: "F.swift", anchor: ".set")
        ]]
        #expect(Self.seamSiteFailures(twice, expected: ["unresolved:key@F.swift": 1]).count == 1)
        #expect(Self.seamSiteFailures(twice, expected: ["unresolved:key@F.swift": 2]).isEmpty)
        #expect(Self.seamSiteFailures(twice, expected: [:]).count == 1, "a seam with no declared site count must fail")
    }

    /// Resolution refuses to guess. A dotted path whose qualifier this file does not declare, a
    /// type-shaped head, and a mutated symbol all become seams instead of naming the wrong key.
    @Test func keyResolutionRefusesToGuess() throws {
        let shadowed = """
        struct Store {
            func unrelated() { let storageKey = "fernlet.recentActivityTypes"; _ = storageKey }
            func write(_ defaults: UserDefaults) { defaults.set(1, forKey: NewDefaults.storageKey) }
        }
        """
        let shadowedTokens = Set(try Self.surfaces(in: shadowed, file: "S.swift").map(\.token))
        #expect(
            !shadowedTokens.contains("fernlet.recentActivityTypes"),
            "a cross-file constant resolved to an unrelated local of the same name — the table now says a key that is never wiped is wiped"
        )
        #expect(shadowedTokens.contains("unresolved:NewDefaults.storageKey@S.swift"))

        let typeShaped = """
        struct Store {
            private let legacy: String = "fernlet.workout.tombstones"
            func write(_ defaults: UserDefaults, _ id: String) {
                defaults.set(1, forKey: String(format: "fernlet.newThing.%@", id))
            }
        }
        """
        let typeTokens = Set(try Self.surfaces(in: typeShaped, file: "S.swift").map(\.token))
        #expect(
            !typeTokens.contains("fernlet.workout.tombstones"),
            "String(...) resolved through the TYPE NAME and picked up a `: String = …` annotation elsewhere in the file"
        )
        #expect(typeTokens.count == 1, "the String(format:) site should yield exactly one seam: \(typeTokens.sorted())")

        let mutated = """
        struct Store {
            func write(_ defaults: UserDefaults) {
                var key = "fernlet.companionPets.count"
                key += ".v2"
                defaults.set(1, forKey: key)
            }
        }
        """
        let mutatedTokens = Set(try Self.surfaces(in: mutated, file: "S.swift").map(\.token))
        #expect(
            !mutatedTokens.contains("fernlet.companionPets.count"),
            "a key composed across statements resolved to its PREFIX, so the table names a key that is not the key"
        )
        #expect(mutatedTokens.contains("unresolved:key@S.swift"))
    }

    /// A raw-value enum store names its keys instead of collapsing them. Two distinct persisted keys
    /// used to produce one `unresolved:rawValue@file` token, and whatever row satisfied the first
    /// silently covered every case added afterwards.
    @Test func rawValueKeysResolveToTheirCaseLiterals() throws {
        let fixture = """
        struct Fixture {
            enum Key: String {
                case lastMood = "fixture.mood.lastMood"
                case lastNote = "fixture.mood.lastNote"
            }
            func write(_ defaults: UserDefaults) {
                defaults.set(1, forKey: Key.lastMood.rawValue)
                defaults.set(2, forKey: Key.lastNote.rawValue)
            }
        }
        """
        let tokens = Set(try Self.surfaces(in: fixture, file: "Fixture.swift").map(\.token))
        #expect(tokens.contains("fixture.mood.lastMood"))
        #expect(tokens.contains("fixture.mood.lastNote"))
        #expect(tokens.count == 2, "N keys collapsed into fewer tokens: \(tokens.sorted())")
    }

    /// Whitespace spellings the compiler accepts without a diagnostic used to drop the surface
    /// entirely — not even as a seam, which is the one outcome this wall must never have.
    @Test func whitespaceSpellingsAreStillDiscovered() throws {
        let fixture = """
        struct Fixture {
            func write(_ defaults: UserDefaults) {
                defaults.set (1, forKey: "fixture.spacedCall")
                defaults.set(2, forKey : "fixture.spacedLabel")
                defaults.set /* legacy */ (3, forKey: "fixture.blockComment")
            }
        }
        """
        let tokens = Set(try Self.surfaces(in: fixture, file: "Fixture.swift").map(\.token))
        #expect(tokens.contains("fixture.spacedCall"), "a space before the parenthesis dropped the call")
        #expect(tokens.contains("fixture.spacedLabel"), "a space before the label's colon dropped the call")
        #expect(tokens.contains("fixture.blockComment"), "a block comment before the parenthesis dropped the call")

        // A label split across lines — the structural comparison reads it; the raw `hasPrefix`
        // dropped the whole call, which is a silent hole rather than a missed resolution.
        let unreadable = """
        struct Fixture {
            func write(_ defaults: UserDefaults) {
                defaults.set(1, forKey
                    : "fixture.newlineLabel")
            }
        }
        """
        let split = Set(try Self.surfaces(in: unreadable, file: "Fixture.swift").map(\.token))
        #expect(split.contains("fixture.newlineLabel"), "a `forKey` split across lines was dropped silently")

        // …and a genuinely unrelated same-named method still yields nothing.
        let unrelated = """
        struct Fixture {
            func write() { _ = formatter.string(from: Date()) }
        }
        """
        let unrelatedTokens = try Self.surfaces(in: unrelated, file: "Fixture.swift")
        #expect(unrelatedTokens.isEmpty, "an unrelated same-named method is being reported as a defaults surface")
    }

    /// Comment spans can neither create a surface nor hide one.
    @Test func commentSpansCannotCreateOrHideASurface() throws {
        let fixture = """
        struct Fixture {
            func write(_ defaults: UserDefaults, _ path: String) {
                /* the old store, removed 2026-09-01:
                   defaults.removeObject(forKey: "fixture.deleted.v1") */
                if path.hasPrefix("//") { defaults.set(1, forKey: "fixture.behindTheLiteral") }
                switch path {
                case "full"://defaults.set(2, forKey: "fixture.commentedOut")
                    break
                default: break
                }
                defaults.set(3, forKey: "fixture.plain")
            }
        }
        """
        let tokens = Set(try Self.surfaces(in: fixture, file: "Fixture.swift").map(\.token))
        #expect(!tokens.contains("fixture.deleted.v1"), "a block-commented write counts as a live surface — it pads the floors and keeps a dead row non-stale")
        #expect(!tokens.contains("fixture.commentedOut"), "the ':' lookbehind preserved a real comment")
        #expect(tokens.contains("fixture.behindTheLiteral"), "a '//' inside a string literal truncated the line and ate the write on it")
        #expect(tokens.contains("fixture.plain"))
    }

    /// A family prefix has to mean something. One interpolated `"fernlet.\\(feature)"` mints
    /// `fernlet.*`, and the only row that can cover that token blankets the whole namespace.
    @Test func aFamilyPrefixMustBeSpecific() throws {
        let fixture = """
        struct Fixture {
            func write(_ defaults: UserDefaults, _ id: String) {
                defaults.set(1, forKey: "fernlet.\\(id)")
                defaults.set(2, forKey: "fixture.family.\\(id)")
            }
        }
        """
        let tokens = Set(try Self.surfaces(in: fixture, file: "Fixture.swift").map(\.token))
        #expect(!tokens.contains("fernlet.*"), "a one-component family prefix was minted — a row covering it would silence every fernlet. key forever")
        #expect(tokens.contains("unresolved:shortFamilyPrefix@Fixture.swift"))
        #expect(tokens.contains("fixture.family.*"), "a specific family prefix must still mint its family token")
    }

    /// `#if DEBUG` on the discovery side: a DEBUG-only writer is not a shipping surface. On the real
    /// tree this removes exactly one seam today, so it is load-bearing rather than decorative.
    @Test func debugOnlyWritersAreNotShippingSurfaces() throws {
        let fixture = """
        struct Fixture {
            func write(_ defaults: UserDefaults) {
                defaults.set(1, forKey: "shipping.key")
                #if DEBUG
                defaults.set(2, forKey: "debug.only.key")
                #endif
                #if !DEBUG
                defaults.set(3, forKey: "release.only.key")
                #else
                defaults.set(4, forKey: "debug.else.key")
                #endif
                #if canImport(UIKit)
                defaults.set(5, forKey: "platform.key")
                #endif
                #if DEBUG && canImport(UIKit)
                defaults.set(6, forKey: "compound.debug.key")
                #endif
            }
        }
        """
        let tokens = Set(try Self.surfaces(in: fixture, file: "Fixture.swift").map(\.token))
        #expect(tokens.contains("shipping.key"))
        #expect(tokens.contains("release.only.key"), "#if !DEBUG keeps its body — that IS shipping code")
        #expect(tokens.contains("platform.key"), "a non-DEBUG conditional must be left completely alone")
        #expect(!tokens.contains("debug.only.key"), "a DEBUG-only write is being counted as a shipping surface")
        #expect(!tokens.contains("debug.else.key"), "the #else half of #if !DEBUG is DEBUG-only and must be stripped")
        #expect(
            !tokens.contains("compound.debug.key"),
            "`#if DEBUG && canImport(UIKit)` — the spelling Power-of-10 R9 forces on this tree — is being read as shipping code"
        )
    }

    /// `#if DEBUG` on the wipe-path side — the petting-state trap, mechanically. A clear that only
    /// ever runs in DEBUG must not satisfy a `.cleared` row, or the wall certifies a wipe that RELEASE
    /// never performs. The compound spelling is the tree's own idiom and gets its own fixture.
    @Test func aDebugOnlyClearDoesNotSatisfyACleared() throws {
        for condition in ["DEBUG", "DEBUG && canImport(UIKit)", "(DEBUG)", "canImport(UIKit) && DEBUG"] {
            let funnel = """
            func deleteAllData() {
                realStore.clearAll()
                #if \(condition)
                pettingGovernor.clearPersistentState()
                #endif
            }
            """
            let stripped = try Self.strippingDebugBranches(funnel, file: "fixture")
            #expect(stripped.contains("realStore.clearAll"))
            #expect(!stripped.contains("clearPersistentState"), "the DEBUG-only clear survived '#if \(condition)'")
            let failures = Self.unmetDispositions(
                table: ["petting.state": .cleared(token: "pettingGovernor.clearPersistentState")],
                wipePath: stripped,
                manifest: ["pettingGovernor.clearPersistentState"],
                declarationLines: [],
                document: Self.CoverageDocument.parsing("| `petting.state` | `pettingGovernor.clearPersistentState` |")
            )
            #expect(failures.count == 1, "a DEBUG-only clear was accepted as a real one under '#if \(condition)': \(failures)")
        }
    }

    /// Shapes the two-branch model cannot represent stop the run rather than being guessed at, and an
    /// unbalanced conditional throws instead of silently discarding the rest of the file.
    @Test func theDebugStripperRefusesWhatItCannotModel() {
        let nested = "#if DEBUG\n#if os(iOS)\nlet x = 1\n#endif\n#endif"
        #expect(throws: (any Error).self) { try Self.strippingDebugBranches(nested, file: "fixture") }

        let elseif = "#if DEBUG\nlet x = 1\n#elseif os(iOS)\nlet y = 2\n#endif"
        #expect(throws: (any Error).self) { try Self.strippingDebugBranches(elseif, file: "fixture") }

        // The reverse ordering: a DEBUG-only clear reached through an `#elseif` whose OPENING
        // condition is not DEBUG. The old guard read the opening condition only.
        let reversed = "#if os(watchOS)\n#elseif DEBUG\nclearPersistentState()\n#endif"
        #expect(throws: (any Error).self) { try Self.strippingDebugBranches(reversed, file: "fixture") }

        let disjunction = "#if DEBUG || FERNLET_UITESTS\nclearPersistentState()\n#endif"
        #expect(throws: (any Error).self) { try Self.strippingDebugBranches(disjunction, file: "fixture") }

        let unterminated = "#if DEBUG\nlet x = 1"
        #expect(throws: (any Error).self) { try Self.strippingDebugBranches(unterminated, file: "fixture") }
    }

    /// A `#if DEBUG` quoted inside a multi-line string is prose, not a directive. Unblanked, it set
    /// `dropping` with no `#endif` to clear it and every surface below vanished from discovery — the
    /// one failure mode the header says this wall must never have.
    @Test func aDirectiveInsideAStringLiteralIsNotADirective() throws {
        let fixture = """
        struct Fixture {
            static let sample = \"\"\"
        #if DEBUG
        print(1)
        \"\"\"
            func write(_ defaults: UserDefaults) { defaults.set(1, forKey: "fixture.below") }
        }
        """
        let tokens = Set(try Self.surfaces(in: fixture, file: "Fixture.swift").map(\.token))
        #expect(
            tokens.contains("fixture.below"),
            "a '#if DEBUG' line inside a multi-line string silently swallowed the rest of the file"
        )
    }

    /// The table checker rejects weak rows. Without this the checks are only as strong as today's
    /// table happening to be well-written.
    @Test func theDispositionCheckerRejectsWeakRows() {
        let document = Self.CoverageDocument.parsing("""
        ## Cleared by Delete everything
        | Surface | Where | Wiped by |
        | --- | --- | --- |
        | `g.ok.cleared` | UserDefaults | `reallyCalled` |
        | `k.cleared.unpaired` | UserDefaults | `somethingElse` |
        ## Deliberate exceptions
        | Surface | Why | Exit |
        | --- | --- | --- |
        | `h.ok.kept` — the documented survivor | it says why | uninstall |
        | `i.ok.unreachable` — a read-only seam | it says why | uninstall |
        ## Open gaps
        | Surface | What survives | Severity |
        | --- | --- | --- |
        | `j.ok.gap` | one date | Low |
        """)
        let sentence = "It survives because the next launch reads this bit as evidence of prior use, and clearing it would misclassify the device."
        let table: [String: Disposition] = [
            "a.cleared.but.uncalled": .cleared(token: "nothingCallsThis"),
            "b.cleared.but.unenforced": .cleared(token: "alsoCalled"),
            "c.kept.but.terse": .kept(reason: "legacy"),
            "d.kept.but.undocumented": .kept(reason: sentence),
            "e.unreachable.but.silent": .unreachableByDesign(reason: ""),
            "f.gap.but.unlisted": .openGap(reason: "nobody has decided"),
            "k.cleared.unpaired": .cleared(token: "reallyCalled"),
            "l.kept.but.padded": .kept(reason: String(repeating: "y", count: Self.minimumKeptReasonLength)),
            "m.unreachable.but.terse": .unreachableByDesign(reason: "read-only seam")
        ]
        let failures = Self.unmetDispositions(
            table: table,
            wipePath: "reallyCalled()\nalsoCalled()",
            manifest: ["nothingCallsThis", "reallyCalled"],
            declarationLines: [],
            document: document
        )
        let flagged = Set(failures.map(\.key))
        #expect(flagged == Set(table.keys), "the checker missed: \(Set(table.keys).subtracting(flagged).sorted())")

        // …and accepts rows that really are met, so it is not simply failing everything.
        let met: [String: Disposition] = [
            "g.ok.cleared": .cleared(token: "reallyCalled"),
            "h.ok.kept": .kept(reason: sentence),
            "i.ok.unreachable": .unreachableByDesign(reason: sentence),
            "j.ok.gap": .openGap(reason: sentence)
        ]
        let clean = Self.unmetDispositions(
            table: met,
            wipePath: "reallyCalled()",
            manifest: ["reallyCalled"],
            declarationLines: [],
            document: document
        )
        #expect(clean.isEmpty, "the checker rejects rows that are met: \(clean)")
    }

    /// The three ways a `.cleared` token used to pass while proving nothing about the key: a narrowing
    /// rename, a mention inside a string literal, and the token's own declaration line.
    @Test func aClearedTokenMustNameARealCall() {
        let document = Self.CoverageDocument.parsing("| `k` | UserDefaults | `generationStore.reset` |")
        let table: [String: Disposition] = ["k": .cleared(token: "generationStore.reset")]

        func failures(_ wipePath: String, declarationLines: [String] = []) -> [DispositionFailure] {
            Self.unmetDispositions(
                table: table, wipePath: wipePath, manifest: ["generationStore.reset"],
                declarationLines: declarationLines, document: document
            )
        }
        #expect(failures("generationStore.reset()").isEmpty, "a real call is being rejected")
        #expect(
            !failures("generationStore.resetPhotoNamespace()").isEmpty,
            "a NARROWING rename kept the row green — the surviving surface is still promised as wiped"
        )
        #expect(
            !failures(PrivacyWipeCoverageTests.strippingCommentsAndStringLiteralBodies(
                #"audit.record("skipping generationStore.reset until v2")"#
            )).isEmpty,
            "a token named inside a string literal satisfied the row"
        )
        #expect(
            !failures("generationStore.reset()", declarationLines: ["    private func generationStore.reset() {"]).isEmpty,
            "a token satisfied by a registered declaration line can never fail — the P1b defect class"
        )
        // The live spelling `worryBoxResetHook?()` must still read as a call.
        #expect(Self.callIsPresent("worryBoxResetHook", in: "worryBoxResetHook?()"))
        #expect(!Self.callIsPresent("worryBoxResetHook", in: "store.worryBoxResetHook = { }"))
    }

    /// Family rows cover their prefix, and cover nothing else — not a concrete literal sibling, and
    /// not a namespace they were never minted for.
    @Test func familyRowsCoverTheirPrefixOnly() {
        #expect(Self.row("fernlet.sealedPhoto.uploadedIDs.*", covers: "fernlet.sealedPhoto.uploadedIDs.*"))
        #expect(Self.row("fernlet.sealedPhoto.*", covers: "fernlet.sealedPhoto.uploadedIDs.*"))
        #expect(!Self.row("fernlet.sealedPhoto.uploadedIDs.*", covers: "fernlet.sealedPhoto.routeCommitted"))
        #expect(!Self.row("fernlet.exact", covers: "fernlet.exact.suffixed"))
        #expect(
            !Self.row("fernlet.sealedBackup.generation.*", covers: "fernlet.sealedBackup.generation.lastPruneAt"),
            "a family row still covers a hand-written literal sibling its allCases loop never removes"
        )
        #expect(
            Self.undeclaredSurfaces(["fernlet.a.1"], table: ["fernlet.a.*": .unreachableByDesign(reason: "x")]) == ["fernlet.a.1"],
            "a concrete key was absorbed by a family row instead of earning its own"
        )
        #expect(Self.staleRows(["fernlet.a.1"], table: ["fernlet.b.*": .unreachableByDesign(reason: "x")]) == ["fernlet.b.*"])

        // The wildcard bypass: one `.unreachableByDesign` row keyed `*` used to cover every surface
        // the app will ever have, go non-stale forever, and need no documentation at all.
        let discovered: Set<String> = ["fernlet.brand.new.secret", "fernlet.sealedPhoto.uploadedIDs.*"]
        for wildcard in ["*", "unresolved:*", "fernlet.*"] {
            let table: [String: Disposition] = [wildcard: .unreachableByDesign(reason: "x")]
            #expect(
                !Self.inventedFamilyRows(discovered, table: table).isEmpty,
                "the wildcard row '\(wildcard)' is accepted — it silences the whole wall in one line"
            )
        }
        #expect(
            Self.inventedFamilyRows(discovered, table: ["fernlet.sealedPhoto.uploadedIDs.*": .unreachableByDesign(reason: "x")]).isEmpty,
            "a family row discovery really minted is being rejected"
        )
    }

    /// The two walls judge ONE wipe path. If this file ever grew its own extraction, a clear could be
    /// "present" here and absent there, which is worse than either wall alone.
    @Test func bothWallsJudgeTheSameWipePath() throws {
        let shared = try PrivacyWipeCoverageTests.wipePathSource()
        let stripped = try Self.debugStrippedWipePath()
        #expect(!shared.isEmpty)
        #expect(stripped.count <= shared.count, "the DEBUG-stripped wipe path is longer than the source it came from")
        #expect(shared.contains("store.periodDataDeleteHook ="), "the shared wipe path lost the ContentView hook wiring")
        #expect(stripped.contains("repository.purgeAllPersistedData"), "the stripped wipe path lost the repository purge — stripping is eating shipping code")
        let matchable = try Self.wipePathForTokenMatching()
        #expect(
            matchable.contains("repository.purgeAllPersistedData"),
            "blanking string-literal bodies is eating real calls out of the wipe path"
        )
    }
}
