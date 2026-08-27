// LocalizationBoundaryTests.swift
// FernletTests
//
// The "localization wall" — sibling of the S3 privacy wall (S3BoundaryTests), the no-tracking wall
// (NoTrackingBoundaryTests), and the Power-of-10 wall (PowerOfTenBoundaryTests).
//
// THE RULE: every string in this codebase is exactly ONE of two things, and never both.
//
//   * a TOKEN — a persisted `rawValue`, a mesh wire byte, an AI prompt word, a dictionary key, a
//     matching input, an accessibility identifier, an export/schema field. Tokens are English
//     FOREVER: they are compared, decoded, signed, and shipped between processes and devices, and a
//     token that changes with the user's language silently stops matching itself.
//   * DISPLAY — text a person reads. Only display localizes.
//
// Where one string does both jobs it must be FORKED: the token keeps its exact characters (so
// already-persisted data still decodes) and a separate display property is added beside it.
//
// Why a wall and not a code review. Every failure mode this file guards is SILENT — nothing crashes,
// no test goes red on its own, and the damage shows up as data loss or wrong behaviour in a language
// nobody on the team reads:
//   - `String(localized:)` without `bundle: .module` inside a package resolves against `Bundle.main`,
//     finds nothing, and returns the English literal. The build is clean and the string is simply
//     never translated (A).
//   - a localized enum `rawValue` re-encodes user data under a translated key; the sealed columns
//     that decode with `compactMap` then drop every row they can no longer match (B).
//   - a drifted widget raw value makes the extension render the neutral companion forever — two
//     processes, no shared type, and no existing test spanning both (C).
//   - a localized derived-signal phrase silently opens or closes the six `==` gates that steer the
//     AI, the gentle offer, and the recommended workout intensity (D).
//
// Every scan DISCOVERS its inputs from the file system via ``RepoRoot`` and carries a hard FLOOR, so
// a moved root or a broken enumerator fails loudly instead of passing vacuously over zero files (the
// S3BoundaryTests house rule). Every pure matcher is exercised by planted fixtures — one snippet that
// MUST trip it and a near-miss that MUST NOT — because part A legitimately finds zero call sites on
// the day it is written, and a matcher nobody has proven is indistinguishable from a matcher that
// never fires.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────
// THE HONEST CEILING. These are GREP WALLS over Swift source, not a compiler, and the difference
// is not academic: an adversarial review of the first draft walked through 8 of 8 planted
// evasions. Every one is fixed and fixtured (`hardenedRulesCatchTheMeasuredEvasions`), but the
// exercise established the shape of what a source scan can and cannot promise, and pretending
// otherwise is how a wall gets trusted past its competence.
//
// What these rules DO catch: a display literal handed to one of the ~25 named SwiftUI heads; a
// `LocalizedStringKey` held in a property, a parameter default, a single- or multi-line collection
// literal, or a function return; an accessibility label/value/hint declared `String`, including
// across a wrapped signature; a `String(localized:)` in package source that does not resolve
// against `.module` — INCLUDING one that passes `bundle: .main`, which is the app→package migration
// typo and reads as compliant to any "is there a bundle argument" test; a bare sentence returned
// from a `LocalizedError`'s `errorDescription` / `failureReason` / `recoverySuggestion`, in either
// root, in every shape the sweep measured — implicit return, explicit return, stored property, or a
// literal laundered through a `let`; a bare literal ASSIGNED to a UIKit display or accessibility
// property, in either root, including through `??` and through a ternary wrapped onto its own
// lines; ANY uncatalogued letter-bearing literal in `App/FernletMessagesExtension`, the one UIKit
// target; and — through the pinned lists — a revert of any member THIS round forked, or of any key
// it put in a catalog.
//
// What they CANNOT catch, and never will:
//   * A HEAD NOT ON THE LIST. `displayInitializers`/`displayModifiers` are enumerations. A literal
//     passed to a SwiftUI API nobody has written down is invisible; the lists grow by someone
//     noticing, which is exactly the fallibility a wall is supposed to remove.
//   * A MEMBER NOT NAMED LIKE ONE. Rule F keys off four name fragments. Rename the member to
//     `spokenName: String` and it matches nothing — the measured evasion (g). `forkedMembers`
//     answers it for this round's work by pinning names; it cannot answer it for code not yet
//     written.
//   * INDIRECTION THROUGH A TYPE. A literal assigned to a `String` and passed through two
//     functions, a struct field, or a dictionary before reaching a display API is a data-flow
//     question. No line-oriented scan resolves it.
//   * COPY A `LocalizedError` BUILDS SOMEWHERE ELSE. Rule G reads the three copy members' own
//     bodies. A conformance whose `errorDescription` returns `Self.copy(for: self)`, or an
//     associated value that arrived as an English literal from its thrower, is the same data-flow
//     question — and `FernletLockError.invalidCredential` is a live example of the second, exempt
//     by design because the pass-through IS its contract.
//   * WHETHER A KEY IS ANY GOOD. A key can be present, bundled, harvested — and still be spliced
//     into a sentence a translator cannot reorder, or carry an English plural rule. Reviews find
//     those; this file cannot.
//   * WHETHER THE STRING ACTUALLY RESOLVES AT RUNTIME. Harvesting is checked here
//     (`everyForkedStringActuallyReachedItsCatalog` reads the committed catalogs); RESOLUTION is
//     not, and today it CANNOT be from inside the test bundle. Every package catalog in this repo
//     is English-only, and an all-English `.xcstrings` compiles to nothing — the module resource
//     bundles ship EMPTY, with `defaultValue` doing the rendering. There is therefore no runtime
//     lookup to assert on yet, which is why the catalog-FILE pins
//     (`theModuleStringCatalogsAddedBySection40StillExist`) are the guard.
//
//     The runtime check is a MANUAL procedure, recorded here so it is repeatable:
//       1. Add an `"fr"` localization with a distinctive value to one key in the module's
//          `Localizable.xcstrings` (e.g. `ui.action.save` → "ENREGISTRER-TEST").
//       2. Build the app scheme. SwiftPM now emits a non-empty `fr.lproj` into that module's
//          resource bundle.
//       3. Run with `-AppleLanguages (fr)` and confirm the string renders as the French value.
//          If it renders English, the lookup is going to `Bundle.main` and the `bundle: .module`
//          is missing or wrong.
//       4. Revert the injected localization.
//     This was performed against `FernletUI` for review §4.0 and resolved correctly through
//     `Bundle.module`; redo it whenever a module gains its first real translation.
//
// UNCATALOGUED DISPLAY COPY — the named deferred class. Several modules ship strings a person reads
// that reach no catalog at all, and they are deferred rather than forgotten. The largest entry this
// list ever carried was never on it: `App/FernletMessagesExtension` shipped 57 uncatalogued
// sentences for a whole round without anyone writing them down, because no rule scanned the target
// and no inventory covered it. Rules H1/H2 closed it, and this paragraph is the reminder that the
// inventory below is only ever as good as the sweep that produced it. None is a bug today
// (no non-English locale ships); each becomes one the day a translation lands, which is when it is
// hardest to find, so the inventory lives here rather than in a status report nobody can grep.
//
// The `LocalizedError` sweep changed the SHAPE of this list. Four modules — `AIProviders`,
// `CloudKitSync`, `FernletFoundation` and `HealthKitGateway` — previously had no
// `Localizable.xcstrings` at all, so their copy was not merely unswept but had nowhere to go. Each
// now owns a catalog and a `TARGETS` line in `Scripts/sync-string-catalogs.sh`, so what is left in
// them is an ordinary `String(localized:bundle:.module)` sweep rather than a blocked one:
//
//   * `FernletScoring` (~24 strings) — the derived-signal and readiness phrasing. STILL HAS NO
//     CATALOG. The hard part is not the count: several of these strings are ALSO logic tokens that
//     six call sites compare with `==` (see part D below), so localizing them requires the
//     token/display FORK, not a `String(localized:)` sweep. Part D is what stops a sweep from
//     silently breaking those gates.
//   * `HealthKitGateway` (14 strings) — `HealthCapability.title` (7) and `HealthCapability.summary`
//     (7), the settings-row name and the sentence describing what each capability reads and writes.
//     The module's four `HealthKitServiceError` sentences were localized by the sweep and are the
//     worked example for the rest; these are straightforward forks with a catalog now waiting.
//   * `PrivateHealthStore`-adjacent copy — `PeriodFlowLevel.title` (`rawValue.capitalized`),
//     `CycleDayEntry.flowLabel`, and the Tier-2 memory CATEGORY rendered by `SettingsSheet`. These
//     are sealed modules and deliberately have NO catalog: the fork belongs at the app-target
//     caller, as `PeriodFlowLevel.displayName` in `CycleTrackerView.swift` now demonstrates for the
//     two cycle sites. The memory category is the remaining one.
//
// Part G's allowlist is now EMPTY, and that is the finished state. It held `MessageTransportProbe`'s
// three sentences on the argument that their target owned no catalog; rule H2 gave the Messages
// extension one, which retired the argument rather than answering it. Everything inside `#if DEBUG`
// is still exempt, skipped structurally rather than by list — copy that is not in the shipping
// binary cannot be read in the wrong language. `FernletLockError.invalidCredential`'s pass-through
// carries no literal at all. The one live allowlist is H2's token inventory: five symbol names,
// defaults keys and wire strings that translating would BREAK, each with that argument attached.
//
// Nothing in this file enforces the deferred list — a grep cannot tell a display string from a token
// without knowing what the string is FOR, which is the whole reason the localization wall is a
// token/display discipline and not a lint rule. Part G is the one slice that IS enforceable, because
// `LocalizedError` names its display members for us.
// ─────────────────────────────────────────────────────────────────────────────────────────────

import Foundation
import Testing
import FernletDomainModel
import FernletFoundation
import LocalPersistence
import PrivateHealthStore
@testable import Fernlet

/// Grep-wall enforcing the token/display separation that makes localization safe.
///
/// Five independent enforcement areas, each with its own planted-token fixtures:
/// - ``everyPackageLocalizedStringPassesModuleBundle()`` — the `bundle: .module` rule inside
///   `FernletKit/Sources` (A).
/// - the `frozen…Tokens` tests — literal raw values of every enum whose tokens are persisted,
///   sealed, signed, or fed to a prompt (B).
/// - ``widgetSharedModelsMatchTheAppSideCrossProcessContract()`` — the app ↔ widget-extension
///   contract, which no type system spans (C).
/// - ``derivedSignalValuesAreTheFrozenLogicVocabulary()`` and its gate pins — the derived-signal
///   phrases that six call sites string-compare (D).
/// - ``accessibilityCopyIsNeverTypedString()`` and ``localizedErrorCopyIsNeverABareLiteral()`` — the
///   two display surfaces whose type or shape hides them from every other rule (F, G).
/// - ``uikitDisplayCopyIsNeverABareLiteral()`` and
///   ``everyMessagesExtensionLiteralIsCataloguedOrAnArguedToken()`` — the UIKit surface, which
///   ASSIGNS its copy rather than declaring it and so is invisible to F, and the one UIKit target,
///   held shut whole because an assignment rule reaches only a fifth of it (H).
///
/// Concurrency: the scans are pure functions over `String`s read off disk; the two tests that touch
/// app-target types are `@MainActor` because the app target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
struct LocalizationBoundaryTests {

    // MARK: - A. The `bundle: .module` wall

    /// The only root scanned by part A: the SPM package.
    ///
    /// `App/` is deliberately NOT scanned. The app target's own bundle IS `Bundle.main`, so the plain
    /// `String(localized:)` form is the CORRECT one there — scanning it would demand `bundle: .module`
    /// where no `.module` accessor even exists, and a wall that asks for the wrong thing gets
    /// disabled. The two app extensions are likewise their own main bundles.
    static let packageSourceRoot = "FernletKit/Sources"

    /// Floor for the package scan (215 `.swift` files at the time of writing). Set well below the real
    /// count so ordinary churn and the ongoing SPM carve-up never trip it, but a root that stops
    /// resolving does.
    static let minimumPackageFilesScanned = 170

    /// A package call site where `bundle:` is not merely unnecessary but IMPOSSIBLE.
    ///
    /// `String(localized:)` has an overload taking a `LocalizedStringResource` — a value the CALLER
    /// built, carrying the bundle the caller attached to it. That overload has no `bundle:`
    /// parameter, and the file doing the resolving holds no key of its own, so failure mode (A) —
    /// a literal in package source silently falling back to English — cannot occur: there is no
    /// literal to fall back to.
    ///
    /// Matched on path AND exact call text so an entry can never drift onto a different call, and
    /// an entry that stops matching is reported rather than left to rot (the
    /// `Scripts/power-of-10-allowlist.json` house rule: every entry states the invariant that makes
    /// it safe).
    struct BundleFreeResolution: Sendable {
        /// Repo-relative path of the file.
        let path: String
        /// The call's exact flattened text, as ``LocalizedCallSite/report`` renders it.
        let call: String
        /// Why `bundle:` cannot apply here.
        let reason: String
    }

    /// Every allowlisted bundle-free resolution. Keep this list at one or two entries; a third
    /// should prompt the question of whether the rule, not the list, needs to change.
    static let bundleFreeResolutions: [BundleFreeResolution] = [
        BundleFreeResolution(
            path: "FernletKit/Sources/FernletUI/FernletAnnouncer.swift",
            call: "String(localized: text)",
            reason: """
                `text` is a caller-supplied `LocalizedStringResource`, which carries its own bundle; \
                the resource-taking overload has no `bundle:` parameter at all. FernletAnnouncer is \
                the app's single VoiceOver-announcement seam and holds ZERO copy by design — \
                FernletAnnouncerTests scans its source for string literals to keep it that way, \
                which is the other half of this entry's invariant.
                """
        )
    ]

    /// One `String(localized:…)` call site found in package source.
    ///
    /// `text` is the WHOLE call — from `String` through its matching close paren, newlines included —
    /// because the argument that matters is routinely written on a later line than the head. Testing
    /// the span rather than the line is what makes multi-line formatting a non-issue.
    struct LocalizedCallSite: Hashable, Sendable {
        /// Repo-relative path of the file the call lives in.
        let path: String
        /// 1-based line of the `String(` head.
        let line: Int
        /// The full call text, from `String` to its matching `)`.
        let text: String
        /// Whether the call resolves against `.module`.
        ///
        /// Not "passes a `bundle:` argument at all", which is what this asked at first and what an
        /// adversarial review walked through by planting `bundle: .main` in package source. Inside
        /// a package `.main` is the APP's bundle — precisely the wrong one, and precisely the typo
        /// an app→package migration produces — so accepting it made the rule agree with the bug.
        let passesBundle: Bool

        /// `path:line: <call text, single-lined>` — pasteable straight into a search.
        var report: String {
            let flattened = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
            return "\(path):\(line): \(flattened)"
        }
    }

    /// Inside an SPM module, `String(localized:)` resolves its key against `Bundle.main` — the APP's
    /// bundle — unless `bundle: .module` is passed. The package's `Localizable.xcstrings` lives in the
    /// module bundle, so the lookup misses, falls back to the English literal baked into the code, and
    /// returns it. Nothing throws, nothing warns, no test fails: the string is simply never translated
    /// for the life of the product.
    ///
    /// That is why this is a wall and not a lint note. The mistake is invisible in every English build
    /// — which is every build anyone on this project runs — and only shows up as a half-translated
    /// screen in a language the team cannot proofread.
    ///
    /// The FLOOR is on FILES SCANNED, not on call sites found. Call-site count is not a health signal:
    /// it was zero when localization Phase 1 started, 96 a few hours later, and it will keep moving —
    /// while a green run here always means "no violations", which is indistinguishable from "the scan
    /// read nothing" unless the file count is pinned separately. The planted fixtures below carry the
    /// other half of the proof: that the matcher fires at all.
    @Test func everyPackageLocalizedStringPassesModuleBundle() throws {
        let (sites, filesScanned) = try Self.scanPackageForLocalizedCalls()

        #expect(
            filesScanned >= Self.minimumPackageFilesScanned,
            """
            Scanned only \(filesScanned) Swift files under \(Self.packageSourceRoot) (floor \
            \(Self.minimumPackageFilesScanned)) — the root moved or the enumerator broke, and this \
            wall is now passing without looking at anything.
            """
        )

        let bundleless = sites.filter { !$0.passesBundle }
        let offenders = bundleless.filter { !Self.isAllowlistedBundleFree($0) }
        #expect(
            offenders.isEmpty,
            """
            \(offenders.count) `String(localized:)` call(s) inside FernletKit omit `bundle: .module`. \
            Inside a package that resolves against Bundle.main, finds no catalog entry, and silently \
            returns the English literal FOREVER — no error, no warning, no failing test but this one. \
            Add `bundle: .module` to each:
            \(offenders.map(\.report).sorted().joined(separator: "\n"))
            """
        )

        // Allowlist hygiene: an entry that no longer matches anything is an entry nobody is
        // reading, and it would silently cover the next call that happens to land on that text.
        let unused = Self.bundleFreeResolutions.filter { entry in
            !bundleless.contains { Self.matches(entry, $0) }
        }
        #expect(
            unused.isEmpty,
            """
            \(unused.count) allowlisted bundle-free resolution(s) match no call any more. Delete \
            them — a stale entry is a hole nobody is watching:
            \(unused.map { "\($0.path): \($0.call)" }.sorted().joined(separator: "\n"))
            """
        )
    }

    /// Whether a bundle-less call is one of the ``bundleFreeResolutions``.
    static func isAllowlistedBundleFree(_ site: LocalizedCallSite) -> Bool {
        bundleFreeResolutions.contains { matches($0, site) }
    }

    /// Exact path AND exact flattened-call match — never a prefix or a path-only match, so an entry
    /// cannot widen to cover a neighbouring call added later in the same file.
    static func matches(_ entry: BundleFreeResolution, _ site: LocalizedCallSite) -> Bool {
        guard site.path == entry.path else { return false }
        return site.report.hasSuffix(": \(entry.call)")
    }

    /// Fixture: the bundle-free allowlist covers exactly one call in exactly one file.
    ///
    /// An allowlist is only as good as its narrowness. This plants the two ways a well-meaning
    /// entry usually widens — the same call text appearing in a different module, and a genuinely
    /// bad neighbouring call in the allowlisted file — and proves neither is swallowed.
    @Test func bundleFreeAllowlistCoversOnlyItsExactCall() throws {
        let entry = try #require(Self.bundleFreeResolutions.first)

        let exact = LocalizedCallSite(path: entry.path, line: 1, text: entry.call, passesBundle: false)
        #expect(Self.isAllowlistedBundleFree(exact))

        // Same call text, another module — the resource might come from anywhere there.
        let elsewhere = LocalizedCallSite(
            path: "FernletKit/Sources/ProximityKit/SomeOtherFile.swift",
            line: 1, text: entry.call, passesBundle: false)
        #expect(!Self.isAllowlistedBundleFree(elsewhere))

        // The allowlisted file's NEXT bundle-less call, with a real literal in it, stays a
        // violation — an entry must never turn its file into an exempt file.
        let neighbour = LocalizedCallSite(
            path: entry.path, line: 2,
            text: #"String(localized: "Saved")"#, passesBundle: false)
        #expect(!Self.isAllowlistedBundleFree(neighbour))
    }

    /// The pinned package string catalog must keep existing.
    ///
    /// `FernletDomainModel` is the module the `bundle: .module` path is verified against; deleting its
    /// `Localizable.xcstrings` would not break the build (the lookup just falls through to the English
    /// literal, exactly as an un-catalogued module does), so nothing else would notice.
    @Test func theDomainModelStringCatalogStillExists() {
        let catalog = RepoRoot.url("FernletKit/Sources/FernletDomainModel/Localizable.xcstrings")
        #expect(
            FileManager.default.fileExists(atPath: catalog.path),
            """
            FernletKit/Sources/FernletDomainModel/Localizable.xcstrings is gone. Its absence is \
            SILENT — every `String(localized:…, bundle: .module)` in that module keeps compiling and \
            keeps returning the English literal. Restore it (and its `defaultLocalization: "en"` \
            declaration in FernletKit/Package.swift) rather than deleting this pin.
            """
        )
    }

    /// Fixture: the call scanner flags a bundle-less call, accepts a bundled one, and — the case that
    /// actually matters — reads the `bundle:` argument when it sits on a LATER line than the head, or
    /// when the head itself is split across lines.
    ///
    /// Without this the wall is unfalsifiable. Part A is expected to report zero violations forever —
    /// that is what success looks like — so only a planted token can distinguish "nothing is wrong"
    /// from "the matcher never fires".
    @Test func localizedCallScannerSeesBundleAcrossLineBreaks() {
        let bad = #"let greeting = String(localized: "Hello", comment: "greeting")"#
        let badSites = Self.localizedCalls(in: bad)
        #expect(badSites.count == 1)
        #expect(badSites.first?.passesBundle == false)

        let good = #"let greeting = String(localized: "Hello", bundle: .module, comment: "greeting")"#
        #expect(Self.localizedCalls(in: good).first?.passesBundle == true)

        // The argument on a later line — the formatting the wall exists to survive.
        let multiline = """
        let greeting = String(
            localized: "Hello",
            bundle: .module,
            comment: "greeting"
        )
        """
        let multilineSites = Self.localizedCalls(in: multiline)
        #expect(multilineSites.count == 1, "a `String(` head split from `localized:` must still match")
        #expect(multilineSites.first?.passesBundle == true)

        // A nested call and a paren inside the literal must not end the span early.
        let nested = #"String(localized: "Meals (today)", bundle: .module, comment: String(describing: 1))"#
        #expect(Self.localizedCalls(in: nested).first?.passesBundle == true)

        // AttributedString(localized:) has the same Bundle.main default and the same silent failure.
        let attributed = #"AttributedString(localized: "Hello", comment: "x")"#
        #expect(Self.localizedCalls(in: attributed).first?.passesBundle == false)

        // Near-misses that must NOT be treated as call sites.
        #expect(Self.localizedCalls(in: "let s = LocalizedStringResource(\"Hello\")").isEmpty)
        #expect(Self.localizedCalls(in: "func localizedTitle() -> String { \"x\" }").isEmpty)
        #expect(Self.localizedCalls(in: #"let sample = "String(localized: \"x\")""#).isEmpty,
                "a call named inside a string literal is data, not a call site")

        // The real false positives this scan hit on its first run over the tree: doc comments that
        // WARN against localizing at a wire seam. Six of them, all correct, all would have hard-failed
        // CI. A wall that fires on careful documentation is a wall someone deletes.
        let warningComment = """
        /// **DO NOT LOCALIZE ANY STRING THAT REACHES THIS FUNCTION.** A `String(localized:)` anywhere
        /// upstream makes the canonical bytes locale-dependent.
        // nothing here should ever call String(localized:)
        func appendCanonical() {}
        """
        #expect(Self.localizedCalls(in: warningComment).isEmpty,
                "a comment naming String(localized:) is documentation, not a call")
        #expect(Self.localizedCalls(in: "/* String(localized: \"x\") */\nlet y = 1").isEmpty,
                "block comments are skipped too")

        // A comment INSIDE a call must not be able to fake the bundle argument.
        let fakedBundle = """
        String(localized: "Hello",
               // bundle: .module would go here, but nobody added it
               comment: "greeting")
        """
        #expect(Self.localizedCalls(in: fakedBundle).first?.passesBundle == false)
    }

    // MARK: - B. Frozen token canaries

    /// Sealed cycle symptoms. `PeriodSymptom` raw values ride the ChaChaPoly-encrypted
    /// `MenstrualNarrative.symptomFlags` column, and the decode side maps them with `compactMap` — a
    /// token that no longer matches is not an error, it is a row that quietly disappears.
    ///
    /// So a rename here is UNRECOVERABLE data loss on the most sensitive data in the app: the
    /// ciphertext still decrypts, the JSON still parses, and the symptom the user logged is simply
    /// absent from their history with nothing anywhere saying why. Localize a `title`/`displayName`
    /// beside these; never the `rawValue`.
    @Test func frozenPeriodSymptomTokens() {
        #expect(
            PeriodSymptom.allCases.map(\.rawValue) == [
                "cramps", "headache", "breastTenderness", "moodSwings", "fatigue",
                "bloating", "acne", "backPain", "foodCravings"
            ],
            """
            PeriodSymptom raw values changed. These are SEALED column tokens decoded with `compactMap`: \
            every already-logged symptom that no longer matches is silently dropped from the user's \
            cycle history, and the plaintext to recover it from does not exist anywhere else. If you \
            are localizing symptom names, add a display property and leave `rawValue` alone.
            """
        )
    }

    /// Sealed journal + trainer-export tokens.
    ///
    /// `FeelingTag` is persisted on every `JournalEntry`, is the memory category for `MemoryNote`, and
    /// rides the sealed journal narrative; `SleepQuality` is persisted on `SleepLog` AND emitted as
    /// `quality.rawValue` in the trainer/coach export JSON, where a human coach's tooling parses it.
    /// Both also decode tolerantly with a parked unknown token — which means a renamed case does not
    /// fail, it parks, freezes to the default (`.neutral` / `.ok`), and reports the wrong mood or the
    /// wrong sleep quality until someone notices by eye.
    @Test func frozenJournalAndSleepTokens() {
        #expect(
            FeelingTag.allCases.map(\.rawValue) == ["bright", "good", "neutral", "quiet", "tired", "hard"],
            """
            FeelingTag raw values changed. They are persisted on every journal entry and ride the \
            sealed journal narrative; the tolerant decoder does not fail on an unknown token, it \
            FREEZES the entry to `.neutral` and parks the original — so past entries silently read as \
            neutral instead of how the user actually felt. Localize `label`, not `rawValue`.
            """
        )
        #expect(
            SleepQuality.allCases.map(\.rawValue) == ["poor", "ok", "good", "great"],
            """
            SleepQuality raw values changed. They are persisted on SleepLog and shipped verbatim as \
            `quality` in the trainer/coach export (TrainerExportBuilder emits `$0.quality.rawValue`), \
            so a rename both freezes existing logs to `.ok` via the tolerant decoder AND hands a \
            coach's tooling a value it cannot parse. Localize `label`/`description`, not `rawValue`.
            """
        )
    }

    /// The companion state, which is a token in two directions at once.
    ///
    /// It is byte-mirrored into the widget extension's app-group JSON (`companionStateRaw`, compared
    /// against the extension's hand-copied `WidgetCompanionState` — see part C) and it is emitted as
    /// `state` in the coach/trainer export schema. Note the capitalization: these raw values are
    /// already display-shaped, which is exactly the trap this wall exists for. They are TOKENS.
    ///
    /// `CompanionState` is not `CaseIterable`, so the live check is per-case; the declaration is also
    /// parsed off disk in part C, which is what catches an ADDED case.
    @Test func frozenCompanionStateTokens() {
        let live = [
            CompanionState.thriving, .okay, .tired, .resting, .sick
        ].map(\.rawValue)
        #expect(
            live == Self.frozenCompanionStateRawValues,
            """
            CompanionState raw values changed (now \(live)). They cross a PROCESS boundary as \
            `companionStateRaw` in the app-group snapshot the widget extension reads — the extension \
            deliberately links no FernletKit product, so nothing but this wall connects the two — and \
            they are the `state` field of the coach export schema. A drift renders the neutral \
            companion in the widget forever. Localize a display name beside them; never these.
            """
        )
    }

    /// Meal + workout categories: persisted rows AND Foundation Models prompt vocabulary.
    ///
    /// `MealType` raw values are display-shaped ("Breakfast", "Pre-workout") and are round-tripped
    /// through the model in `FoundationFoodSelection` (`MealType(rawValue: mealType)`) — localize them
    /// and the model's answer stops resolving to a case in any non-English locale, so every AI meal
    /// classification silently falls back. `WorkoutType` is persisted on workout rows and exported as
    /// `type` to the coach; its `allCases` is deliberately narrowed to the four current categories
    /// while the legacy cases stay decodable, so the legacy raw values are pinned individually.
    @Test func frozenMealAndWorkoutTypeTokens() {
        #expect(
            MealType.allCases.map(\.rawValue) == [
                "Breakfast", "Lunch", "Dinner", "Snack", "Pre-workout", "Post-workout"
            ],
            """
            MealType raw values changed. They are persisted on every meal AND they are the vocabulary \
            the on-device model answers with — `FoundationFoodSelection` resolves the model's reply via \
            `MealType(rawValue:)`. Localizing them makes that lookup miss in every non-English locale, \
            so AI meal classification silently degrades to the deterministic fallback. Fork a display \
            property instead.
            """
        )

        let workoutRawValues = [
            WorkoutType.upper, .lower, .armsBack, .mixed, .fullBody, .cardio, .run, .hike
        ].map(\.rawValue)
        #expect(
            workoutRawValues == ["Upper", "Lower", "Arms/Back", "Upper/Mixed", "Full Body", "Cardio", "C210K Run", "Hike"],
            """
            WorkoutType raw values changed (now \(workoutRawValues)). They are persisted on workout \
            rows, exported to the coach as `type`, and four of them are LEGACY cases kept decodable \
            purely so old rows still load — renaming one strands that history. Localize a display name.
            """
        )
        #expect(
            WorkoutType.allCases.map(\.rawValue) == ["Upper", "Lower", "Full Body", "Cardio"],
            """
            WorkoutType.allCases changed. It is deliberately narrowed to the four CURRENT categories \
            so pickers never offer the legacy ones while old rows keep decoding; widening it puts \
            retired categories back in front of users.
            """
        )
    }

    /// Coach-plan wire tokens.
    ///
    /// `MuscleGroup` and `Equipment` raw values are persisted in day rows, persisted in the
    /// safety-relevant `WorkoutProfile.avoidedMuscles` set, and shipped in the coach/trainer export
    /// (`avoidedMuscles: wp.avoidedMuscles.map(\.rawValue)`). The safety case is the sharp one: an
    /// avoided muscle that fails to decode does not fail loudly, it un-avoids itself, and the planner
    /// then prescribes the exact movement the user marked as injured.
    @Test func frozenCoachPlanWireTokens() {
        #expect(
            MuscleGroup.allCases.map(\.rawValue) == [
                "chest", "upperBack", "lats", "lowerBack", "traps",
                "frontDelts", "sideDelts", "rearDelts", "biceps", "triceps", "forearms",
                "abs", "obliques", "quads", "hamstrings", "glutes", "calves",
                "adductors", "abductors", "fullBody"
            ],
            """
            MuscleGroup raw values changed. They are coach-plan wire tokens AND the persisted \
            `WorkoutProfile.avoidedMuscles` set — an avoided muscle whose token no longer matches \
            silently stops being avoided, and the planner prescribes the movement the user marked as \
            injured. Localize `displayName`, never `rawValue`.
            """
        )
        #expect(
            Equipment.allCases.map(\.rawValue) == [
                "barbell", "dumbbell", "machine", "cable", "bodyweight",
                "kettlebell", "band", "bench", "cardio", "none"
            ],
            """
            Equipment raw values changed. They are coach-plan wire tokens and the capability the \
            safety filter checks a `WorkoutLocation` against before an exercise may be prescribed; a \
            drift makes every capability check miss, so either nothing is prescribable or the wrong \
            things are. Localize `displayName`, never `rawValue`.
            """
        )
    }

    /// `GoalType`'s legacy persisted-display aliases.
    ///
    /// The sharpest instance of the token/display collision in the tree: early builds persisted the
    /// DISPLAY string ("Weight Management") as the stored goal, so `init(persistedToken:)` still maps
    /// those aliases. The failure is silent and total — `init(from:)` freezes an unrecognized token to
    /// `.wellness`, which means deleting an alias does not throw, it RESETS the user's goal, and every
    /// nutrition target, training split, and rest recommendation quietly changes with it.
    ///
    /// Each alias is round-tripped through the real decoder (not just the initializer) because the
    /// decoder is where the fall-through lives.
    @Test func frozenGoalTypeLegacyAliases() throws {
        let aliases: [(token: String, expected: GoalType)] = [
            ("Weight Management", .weightManagement),
            ("Mental Health", .mentalHealth),
            ("Sports Prep", .sportsPrep),
            ("Short-term", .wellness),
            ("Long-term", .strength),
            ("Wellness", .wellness),
            ("Strength", .strength),
            ("Recovery", .recovery),
            ("Exploring", .exploring),
            ("Sport", .sportsPrep),
            ("Sports", .sportsPrep)
        ]
        for alias in aliases {
            let resolved = GoalType(persistedToken: alias.token)
            #expect(
                resolved == alias.expected,
                """
                GoalType.init(persistedToken:) no longer maps the legacy alias "\(alias.token)" to \
                .\(alias.expected) (got \(String(describing: resolved))). Early builds persisted the \
                DISPLAY string as the stored goal, so this alias IS live user data. Dropping it does \
                not throw — `init(from:)` freezes to `.wellness` — so the user's goal silently resets \
                and their calorie targets, training split, and rest guidance all change with it.
                """
            )

            // The decoder is where the fall-through actually happens, so prove it there too.
            let decoded = try JSONDecoder().decode(GoalType.self, from: Data("\"\(alias.token)\"".utf8))
            #expect(
                decoded == alias.expected,
                "decoding the persisted token \"\(alias.token)\" yielded .\(decoded) — a silent goal reset"
            )
        }

        // The fall-through itself is part of the contract: an unknown token must land on `.wellness`
        // (and be parked by FernletSettings), never trap. This is what makes a deleted alias silent.
        let unknown = try JSONDecoder().decode(GoalType.self, from: Data("\"MintedByANewerBuild\"".utf8))
        #expect(unknown == .wellness, "an unrecognized goal token must freeze to .wellness, not trap")
        #expect(GoalType(persistedToken: "MintedByANewerBuild") == nil)

        #expect(
            GoalType.allCases.map(\.rawValue) == [
                "wellness", "strength", "weightManagement", "mentalHealth", "recovery", "exploring", "sportsPrep"
            ],
            """
            GoalType raw values changed. They are the CURRENT persisted tokens (exported to the coach \
            as `goal`), distinct from the legacy display aliases above. Localize `displayName`, \
            `tagline`, `nutritionSummary`, and `trainingSummary` — never `rawValue`.
            """
        )
    }

    // MARK: - C. The widget cross-process contract

    /// The app-side companion-state raw values, frozen here once and reused by parts B and C so the
    /// two checks cannot drift apart into separately-wrong lists.
    static let frozenCompanionStateRawValues = ["Thriving", "Okay", "Tired", "Resting", "Sick"]

    /// Repo-relative path of the widget extension's hand-copied contract file.
    static let widgetSharedModelsPath = "App/FernletWidgets/WidgetSharedModels.swift"

    /// Repo-relative path of the app-side `CompanionState` declaration.
    static let companionModelsPath = "FernletKit/Sources/FernletDomainModel/CompanionModels.swift"

    /// `App/FernletWidgets/WidgetSharedModels.swift` is the ENTIRE contract between two processes.
    ///
    /// The widget extension deliberately links no FernletKit product (the umbrella product also
    /// carries the sealed `Private*` stores, `AIProviders`, and `CloudKitSync` — an S3-wall regression
    /// vector and a WidgetKit memory hazard), so there is no shared type, no shared constant, and no
    /// compiler check spanning the two sides. Four literals carry everything:
    ///
    ///   - the app-group id, which names the container both processes open;
    ///   - the five `WidgetCompanionState` raw values, matched against `companionStateRaw` in the
    ///     mirrored snapshot;
    ///   - the pending-action discriminator the app dispatches on when draining taps;
    ///   - the `en_US_POSIX` / Gregorian / `yyyy-MM-dd` day-key formatter, which is the join field for
    ///     every app-group file (a locale-following formatter would emit a Buddhist or Hijri year on a
    ///     device configured for one, and no day gate would ever match again).
    ///
    /// A drift in the companion raw values is the quiet one: `WidgetCompanionState(rawValue:)` returns
    /// nil, the widget falls back to the neutral "Fernlet" treatment, and it stays there forever. The
    /// app is fine, the extension does not crash, and nothing else in the suite spans both sides.
    ///
    /// Parsed off disk because the widget's sources cannot be imported here — the same technique
    /// `WidgetBridgeTests.widgetWriterAndAppQueueAgreeOnTheQueueCap` already uses for the queue cap.
    @Test @MainActor func widgetSharedModelsMatchTheAppSideCrossProcessContract() throws {
        let widgetSource = try RepoRoot.source(Self.widgetSharedModelsPath)
        #expect(widgetSource.count > 1_000, "\(Self.widgetSharedModelsPath) is empty or truncated — nothing below is being checked")

        // 1) The app-group id: the container both processes open. A mismatch means the widget writes
        //    taps into a directory the app never drains, and reads a snapshot the app never writes.
        #expect(
            widgetSource.contains("let fernletAppGroupIdentifier = \"\(WidgetBridgeFiles.appGroupIdentifier)\""),
            """
            The widget's `fernletAppGroupIdentifier` no longer literally matches the app's \
            WidgetBridgeFiles.appGroupIdentifier ("\(WidgetBridgeFiles.appGroupIdentifier)"). The two \
            processes would then open DIFFERENT containers: every +1-water tap lands in a file the app \
            never drains, and the widget renders a snapshot that is never republished. Nothing errors.
            """
        )

        // 2) The five companion raw values, one-for-one and in order, on both sides. Parsing the app's
        //    declaration (rather than only listing the live cases) is what catches an ADDED case:
        //    CompanionState is not CaseIterable, so a sixth case would otherwise be invisible here.
        let widgetStates = try #require(
            Self.enumRawValues(in: widgetSource, enumName: "WidgetCompanionState"),
            "`enum WidgetCompanionState` is gone from \(Self.widgetSharedModelsPath) — the widget's half of the contract cannot be read"
        )
        let appSource = try RepoRoot.source(Self.companionModelsPath)
        let appStates = try #require(
            Self.enumRawValues(in: appSource, enumName: "CompanionState"),
            "`enum CompanionState` is gone from \(Self.companionModelsPath) — the app's half of the contract cannot be read"
        )
        #expect(
            appStates == Self.frozenCompanionStateRawValues,
            "CompanionState now declares \(appStates); the frozen contract is \(Self.frozenCompanionStateRawValues)"
        )
        #expect(
            widgetStates == appStates,
            """
            The widget's WidgetCompanionState raw values \(widgetStates) no longer match the app's \
            CompanionState raw values \(appStates), one-for-one. `WidgetCompanionState(rawValue:)` \
            then returns nil for the mirrored `companionStateRaw`, and the widget renders the neutral \
            companion FOREVER — the extension links no FernletKit product, so no other test in this \
            suite spans both sides. Edit both files in the same commit, or fork a display name and \
            leave the raw values alone.
            """
        )

        // 3) The pending-action discriminator the app dispatches on while draining.
        #expect(
            widgetSource.contains("static let waterPlusOne = \"\(PendingWidgetAction.waterPlusOne)\""),
            """
            The widget's pending-action token no longer matches the app's \
            PendingWidgetAction.waterPlusOne ("\(PendingWidgetAction.waterPlusOne)"). The app drains \
            rows with `action.action == PendingWidgetAction.waterPlusOne` and DROPS anything else as \
            unknown — so every tap is written, read, and thrown away in silence.
            """
        )

        try Self.expectWidgetDayKeyFormatterMatchesTheApp(widgetSource)
    }

    /// The widget's day-key formatter, rebuilt from the literals in its source and compared against
    /// the app's canonical `FernletDate.dayKey(for:)`.
    ///
    /// Split out of ``widgetSharedModelsMatchTheAppSideCrossProcessContract()`` to keep that body
    /// under the Power-of-10 60-line ceiling. Checking the literals alone would not prove much;
    /// constructing a formatter from them and comparing its OUTPUT is what pins the contract, because
    /// the failure mode is a formatter that follows the device locale and emits a non-Gregorian year.
    static func expectWidgetDayKeyFormatterMatchesTheApp(_ widgetSource: String) throws {
        #expect(
            widgetSource.contains("Calendar(identifier: .gregorian)"),
            """
            The widget's day-key formatter no longer pins the Gregorian calendar. On a device set to a \
            Buddhist or Japanese calendar it would emit a year the app never writes, so `dateKey` \
            never joins and WidgetDayGate treats every snapshot as stale — an empty widget, no error.
            """
        )
        let locale = try #require(
            Self.firstLiteral(in: widgetSource, after: "Locale(identifier: "),
            "the widget's day-key formatter no longer pins a locale identifier"
        )
        let format = try #require(
            Self.firstLiteral(in: widgetSource, after: "f.dateFormat = "),
            "the widget's day-key formatter no longer declares a literal dateFormat"
        )
        #expect(locale == "en_US_POSIX", "widget day-key locale is \"\(locale)\" — only en_US_POSIX is locale-stable")
        #expect(format == "yyyy-MM-dd", "widget day-key format is \"\(format)\" — the app writes yyyy-MM-dd")

        // Rebuild the widget's formatter from its own literals and compare against the app's canonical
        // key. This is the assertion that would actually catch a locale-following formatter.
        let rebuilt = DateFormatter()
        rebuilt.locale = Locale(identifier: locale)
        rebuilt.calendar = Calendar(identifier: .gregorian)
        rebuilt.dateFormat = format
        let fixedDate = Date(timeIntervalSince1970: 1_780_000_000)
        #expect(
            rebuilt.string(from: fixedDate) == FernletDate.dayKey(for: fixedDate),
            """
            A formatter built from the widget's own literals produces \
            "\(rebuilt.string(from: fixedDate))" where the app's FernletDate.dayKey produces \
            "\(FernletDate.dayKey(for: fixedDate))". The day key is the join field for every \
            app-group file; when it diverges, the widget shows an empty day and every queued tap is \
            filed under a day the app will not look at.
            """
        )
    }

    /// Fixture: the enum-raw-value parser reads both raw-valued and bare cases, stops at the enum's
    /// closing brace, and reports a missing enum as nil rather than as an empty (vacuously equal) list.
    @Test func enumRawValueParserReadsDeclarationsAndFailsLoudlyWhenAbsent() {
        let source = """
        enum WidgetCompanionState: String {
            case thriving = "Thriving"
            case okay = "Okay"
        }

        enum Other: String {
            case ignored = "Ignored"
        }
        """
        #expect(Self.enumRawValues(in: source, enumName: "WidgetCompanionState") == ["Thriving", "Okay"])
        #expect(Self.enumRawValues(in: source, enumName: "Other") == ["Ignored"])
        // Absent enum -> nil, never [] — an empty list would compare equal to another empty list and
        // pass vacuously, which is precisely the failure this whole file is built to avoid.
        #expect(Self.enumRawValues(in: source, enumName: "Missing") == nil)

        let bare = "enum Bare: String {\n    case alpha, beta\n    case gamma\n}"
        #expect(Self.enumRawValues(in: bare, enumName: "Bare") == ["alpha", "beta", "gamma"])

        // The regression that made this parser necessary in its current form: these enums are exactly
        // the ones growing a localized `displayName`, and its `switch self` body is full of lines
        // beginning with `case `. Reading those as declarations doubles the parsed list and fails the
        // cross-process comparison for a reason that has nothing to do with the contract.
        let withDisplayProperty = """
        enum Companion: String {
            case thriving = "Thriving"
            case sick = "Sick"

            var displayName: String {
                switch self {
                case .thriving: String(localized: "companionState.thriving", defaultValue: "Thriving", bundle: .module)
                case .sick: String(localized: "companionState.sick", defaultValue: "Sick", bundle: .module)
                }
            }
        }
        """
        #expect(
            Self.enumRawValues(in: withDisplayProperty, enumName: "Companion") == ["Thriving", "Sick"],
            "switch arms inside a display property must not be read as case declarations"
        )
    }

    // MARK: - D. Derived-signal values used as logic tokens

    /// Repo-relative path of the factory that mints every derived-signal value.
    static let derivedSignalFactoryPath = "FernletKit/Sources/LocalPersistence/DerivedSignalFactory.swift"

    /// The complete vocabulary `DerivedSignalFactory` can put in a `DerivedSignalRecord.value`.
    ///
    /// `{}` stands for a string interpolation, so the two counted phrases appear here in the shape the
    /// scanner reports them: `"\(gapCount) possible gap\(…)"` reads as `{} possible gap{}`.
    static let frozenSignalValueVocabulary: Set<String> = [
        "insufficient data",
        // moodTrend
        "needs gentleness", "improving", "declining", "steady",
        // energyTrend
        "low", "rising", "dipping",
        // eatingPattern
        "light", "protein-forward", "inconsistent", "consistent",
        // intensityReadiness
        "ready for light", "ready for moderate", "ready for hard",
        // progressionTrend
        "building", "deloading",
        // micronutrientGaps{7,14}Day
        "{} possible gap{}", "{} covered"
    ]

    /// The seven signal names, which are dictionary-style lookup keys (`first(where: { $0.signalName == … })`).
    static let frozenSignalNames = [
        "moodTrend", "energyTrend", "eatingPattern", "progressionTrend",
        "intensityReadiness", "micronutrientGaps7Day", "micronutrientGaps14Day"
    ]

    /// The derived-signal `value` strings are DISPLAY TEXT AND LOGIC TOKENS AT THE SAME TIME — the
    /// exact collision this wall exists to police, and the only one in the tree that is still
    /// unresolved.
    ///
    /// They are rendered to the user verbatim on Home, and they are also `==`-compared by six gates:
    /// the AI-runs-at-all gate (`LaunchPreparationService` drops every signal equal to "insufficient
    /// data" and skips the model entirely when nothing survives), the gentle-offer gate
    /// (`GentleOfferEngine` opens on "needs gentleness"), the recommended-intensity map
    /// (`FernletStore.recommendedWorkoutIntensity`), two Home copy switches, and Home's tone
    /// classifier. Localize a phrase and every one of those comparisons silently stops matching: the
    /// AI stops running, the gentle offer stops appearing, and the workout card loses its
    /// recommendation — with no error anywhere.
    ///
    /// APPROACH: a source scan of the declaration site, plus one live round-trip. Driving all
    /// nineteen values through fixtures would mean reproducing each heuristic's thresholds (protein
    /// totals, RPE-weighted load, HRV recovery) in the test, which couples the wall to the thresholds
    /// rather than to the vocabulary — the wrong invariant, and brittle against every tuning change.
    /// The scan pins the vocabulary; the round-trip below proves the scan describes something the
    /// factory really emits.
    @Test func derivedSignalValuesAreTheFrozenLogicVocabulary() throws {
        let source = try RepoRoot.source(Self.derivedSignalFactoryPath)
        let (values, assignmentSites) = Self.signalValueLiterals(in: source)

        #expect(
            assignmentSites >= 20,
            """
            Found only \(assignmentSites) `value = …` assignments in \(Self.derivedSignalFactoryPath) \
            (expected 22) — the factory was restructured and this scan is no longer reading the \
            values it claims to freeze. Re-point the scan rather than lowering the floor.
            """
        )
        #expect(
            values == Self.frozenSignalValueVocabulary,
            """
            The derived-signal vocabulary changed.
              added:   \(values.subtracting(Self.frozenSignalValueVocabulary).sorted())
              removed: \(Self.frozenSignalValueVocabulary.subtracting(values).sorted())
            These strings are shown to the user AND string-compared by six gates (the AI-runs-at-all \
            gate, the gentle-offer gate, the recommended-intensity map, two Home copy switches, and \
            Home's tone classifier). Changing one silently turns a gate off: no error, no crash, the \
            feature just stops happening. If you are localizing them, FORK them first — keep these \
            exact strings as the token and add a display projection at the render sites.
            """
        )
    }

    /// The live half: a one-day window of an empty day must still produce exactly the seven named
    /// signals, all valued with the literal the AI gate compares against.
    ///
    /// Deliberately the trivial fixture. It pins the two things a scan cannot: that `signalName` really
    /// is the lookup key those `first(where:)` calls use, and that "insufficient data" is a string the
    /// factory genuinely emits rather than one this file merely found in the source.
    @Test func derivedSignalFactoryEmitsTheFrozenNamesAndTheAIGateLiteral() {
        let dayKey = "2026-08-19"
        let records = DerivedSignalFactory.makeSignals(
            from: [(dayKey, FernletDay(date: dayKey))],
            todayKey: dayKey
        )

        #expect(
            records.map(\.signalName) == Self.frozenSignalNames,
            """
            DerivedSignalFactory now emits \(records.map(\.signalName)). These names are LOOKUP KEYS — \
            `FernletStore.recommendedWorkoutIntensity()` and the Home cards find their record with \
            `first(where: { $0.signalName == "…" })` and return nil when it is missing, which reads to \
            the user as "the feature is gone", not as an error.
            """
        )
        for record in records {
            #expect(
                record.value == "insufficient data",
                """
                An empty day produced \(record.signalName) = "\(record.value)" instead of \
                "insufficient data". That exact literal is the AI-runs-at-all gate: \
                LaunchPreparationService filters `$0.value != "insufficient data"` and skips the model \
                when nothing survives. A changed literal makes the gate pass on empty data (the model \
                is asked to comment on nothing) or fail on real data (the model never runs at all).
                """
            )
        }
    }

    /// The six gates that string-compare a derived-signal value, pinned at their call sites.
    ///
    /// Freezing the factory's output is only half the contract — the other half is that the consumers
    /// still compare against those literals. Pinned by source scan because these live in the app
    /// target's view and store layers, where constructing the surrounding state is far more fragile
    /// than reading the comparison itself.
    ///
    /// If one of these gates is refactored to compare against a NAMED CONSTANT instead of a literal,
    /// that is an improvement — re-point the pin at the new call site, do not delete it.
    @Test func theSixSignalValueGatesStillCompareTheFrozenLiterals() throws {
        let gates: [(path: String, needle: String, consequence: String)] = [
            ("App/Fernlet/LaunchPreparationService.swift", #"$0.value != "insufficient data""#,
             "the AI-runs-at-all gate: with no match, every signal survives the filter and the model is asked to comment on an empty day"),
            ("App/Fernlet/GentleOffers.swift", #"moodTrendValue == "needs gentleness""#,
             "the gentle-offer gate: with no match, the offer never appears on the days it exists for"),
            ("App/Fernlet/FernletStore.swift", #"case "ready for hard": return .hard"#,
             "the recommended-intensity map: with no match it returns nil and the workout card loses its recommendation"),
            ("App/Fernlet/HomeView.swift", #"mood.value == "needs gentleness""#,
             "Home's mood copy: with no match the card shows the generic line on the days that most need the gentle one"),
            ("App/Fernlet/HomeView.swift", #"readiness.value == "ready for hard""#,
             "Home's readiness copy: with no match the push/restore guidance silently disappears"),
            ("App/Fernlet/HomeView.swift", #"lower.contains("declining")"#,
             "Home's tone classifier: with no match a declining trend is rendered in the upbeat tone")
        ]
        for gate in gates {
            let source = try RepoRoot.source(gate.path)
            #expect(
                source.contains(gate.needle),
                """
                \(gate.path) no longer contains `\(gate.needle)`. That comparison is \(gate.consequence). \
                Either the literal drifted from DerivedSignalFactory (fix the drift) or the gate moved \
                to a named constant (an improvement — re-point this pin at the new call site).
                """
            )
        }
    }

    /// Fixture: the `value = …` literal extractor reads plain literals, the literals passed to
    /// `trendValue(rising:falling:steady:)`, and an interpolated literal whose interpolation itself
    /// contains string literals — the shape `micronutrientTrend` actually writes.
    @Test func signalValueExtractorReadsPlainAndInterpolatedLiterals() {
        let source = #"""
        func f() {
            let value: String
            if a {
                value = "insufficient data"
            } else if b {
                value = trendValue(scores: s, rising: "improving", falling: "declining", steady: "steady")
            } else {
                value = "\(gapCount) possible gap\(gapCount == 1 ? "" : "s")"
            }
            let other = "not a signal value"
        }
        """#
        let (values, sites) = Self.signalValueLiterals(in: source)
        #expect(sites == 3)
        #expect(values == ["insufficient data", "improving", "declining", "steady", "{} possible gap{}"])
        // A literal that is not assigned to `value` must not enter the vocabulary — otherwise the
        // frozen set would churn with every unrelated string in the file.
        #expect(!values.contains("not a signal value"))
    }

    // MARK: - E. The SwiftUI display-literal wall

    /// SwiftUI initializers whose first parameter is a `LocalizedStringKey`.
    ///
    /// A bare literal handed to one of these inside a package module is looked up in `Bundle.main`
    /// — the APP's bundle — which never consults the module's own catalog. Same silent failure as
    /// part A, different door: part A watches `String(localized:)`, this watches the SwiftUI half,
    /// and until this test existed the SwiftUI half was completely unguarded. Eighteen live
    /// violations were sitting in `FernletUI` and `ProximityKit` on the day it was written.
    ///
    /// Matched only when the literal is the FIRST argument, so `Text(verbatim:)`,
    /// `Image(systemName:)` and every already-resolved `FernletUICopy.…` call are non-matches by
    /// construction rather than by exclusion list.
    static let displayInitializers = [
        "Text", "Button", "Label", "Toggle", "TextField", "SecureField", "Picker", "Section",
        "Stepper", "Link", "NavigationLink", "ProgressView", "Menu", "DatePicker",
        "ContentUnavailableView", "LocalizedStringKey", "LocalizedStringResource",
    ]

    /// View modifiers whose first parameter is a `LocalizedStringKey`, with the same `Bundle.main`
    /// default and the same silent failure.
    ///
    /// `accessibilityIdentifier` is deliberately ABSENT: an identifier is a token, frozen English
    /// forever, and a wall that demanded a bundle there would be asking for the wrong thing.
    /// `accessibilityLabel`/`Value`/`Hint` have no `bundle:` parameter of their own, so the fix at
    /// those sites is to pass `Text("…", bundle: .module)` — which this scan then sees as a
    /// correct `Text(` call and the modifier as a non-literal first argument.
    static let displayModifiers = [
        "navigationTitle", "navigationBarTitle", "alert", "confirmationDialog",
        "accessibilityLabel", "accessibilityValue", "accessibilityHint",
        "accessibilityAction", "accessibilityInputLabels", "help",
    ]

    /// One SwiftUI display call in package source whose first argument is a string literal.
    struct DisplayLiteralSite: Hashable, Sendable {
        /// Repo-relative path of the file.
        let path: String
        /// 1-based line of the call head.
        let line: Int
        /// The initializer or modifier name, e.g. `Text` or `.alert`.
        let head: String
        /// The literal's text, interpolations collapsed to `{}`.
        let literal: String
        /// Whether a `bundle:` argument appears anywhere in the call span.
        let passesBundle: Bool

        /// `path:line: Head("literal")` — pasteable straight into a search.
        var report: String { "\(path):\(line): \(head)(\"\(literal)\")" }
    }

    /// Inside an SPM module, SwiftUI resolves a `LocalizedStringKey` against `Bundle.main` unless a
    /// `bundle:` argument is passed — and most of these APIs have no `bundle:` parameter at all, so
    /// the only correct form is to resolve first (a copy vault: `FernletUICopy`, `FernletLockCopy`,
    /// `ProximityUICopy`) or to wrap in `Text(_:bundle:)`.
    ///
    /// This is the exact sibling of ``everyPackageLocalizedStringPassesModuleBundle()`` and exists
    /// because that test could not see SwiftUI. `CLAUDE.md`'s localization-wall paragraph has always
    /// named BOTH doors — "`String(localized:)` **and** SwiftUI's `LocalizedStringKey`" — but only
    /// the first was enforced, which is why `SheetSaveBar`'s `"Save"` default could carry a written
    /// note admitting it was broken and still ship.
    ///
    /// The FLOOR is on files scanned, for the same reason as part A: zero violations is the
    /// intended steady state, and is indistinguishable from a scan that read nothing.
    @Test func packageDisplayLiteralsPassModuleBundle() throws {
        let (sites, filesScanned) = try Self.scanPackageForDisplayLiterals()

        #expect(
            filesScanned >= Self.minimumPackageFilesScanned,
            """
            Scanned only \(filesScanned) Swift files under \(Self.packageSourceRoot) (floor \
            \(Self.minimumPackageFilesScanned)) — the root moved or the enumerator broke, and this \
            wall is now passing without looking at anything.
            """
        )

        let offenders = sites.filter { !$0.passesBundle }
        #expect(
            offenders.isEmpty,
            """
            \(offenders.count) SwiftUI display literal(s) inside FernletKit resolve against \
            Bundle.main and will render untranslated English FOREVER — clean build, no warning, no \
            other failing test. Resolve through the module's copy vault (FernletUICopy, \
            FernletLockCopy, ProximityUICopy) with `String(localized:…, bundle: .module)`, or pass \
            `Text("…", bundle: .module)`:
            \(offenders.map(\.report).sorted().joined(separator: "\n"))
            """
        )

        let held = try Self.scanPackageForHeldKeys()
        #expect(
            held.isEmpty,
            """
            \(held.count) `LocalizedStringKey` member(s) inside FernletKit hold a literal of their \
            own. A key carries no bundle, so it resolves against Bundle.main and never sees the \
            module's catalog — moving the literal from a call site into a property hides it from \
            every call-site scan without fixing anything. Resolve through the module's copy vault \
            and type the member `String`. (A LocalizedStringKey PARAMETER is correct — that is a \
            caller's key, and it is FernletUI's whole architecture.)
            \(held.map(\.report).sorted().joined(separator: "\n"))
            """
        )
    }

    /// Scans package source for `LocalizedStringKey` members holding their own literals.
    static func scanPackageForHeldKeys() throws -> [DisplayLiteralSite] {
        let rootURL = RepoRoot.url(packageSourceRoot)
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
            Issue.record("Could not enumerate \(packageSourceRoot) — the held-key wall is unenforced.")
            return []
        }
        var sites: [DisplayLiteralSite] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let relativePath = url.path.replacingOccurrences(of: RepoRoot.url.path + "/", with: "")
            for found in localizedStringKeyLiteralDeclarations(in: source) {
                sites.append(DisplayLiteralSite(
                    path: relativePath, line: found.line, head: "LocalizedStringKey",
                    literal: found.text, passesBundle: false
                ))
            }
        }
        return sites
    }

    /// Fixture: the display-literal scanner fires on each shape it must catch and stays silent on
    /// each shape it must not.
    ///
    /// Without this the wall is unfalsifiable — it is expected to report zero forever, which looks
    /// exactly like a matcher that never runs.
    @Test func displayLiteralScannerSeparatesKeysFromResolvedText() {
        // The two shapes that were actually shipping in the tree.
        #expect(Self.displayLiterals(in: #"Button("Cancel", action: onCancel)"#).count == 1)
        #expect(Self.displayLiterals(in: #"Text("Keep as friends?")"#).first?.literal == "Keep as friends?")

        // A modifier head needs its leading dot; the same word as a declaration must not match.
        #expect(Self.displayLiterals(in: #".accessibilityLabel("12 coins")"#).count == 1)
        #expect(Self.displayLiterals(in: #"func accessibilityLabel("x")"#).isEmpty)

        // The correct forms.
        #expect(Self.displayLiterals(in: #"Text(verbatim: FernletUICopy.save)"#).isEmpty)
        #expect(Self.displayLiterals(in: #"Button(FernletUICopy.cancel, action: action)"#).isEmpty)
        #expect(Self.displayLiterals(in: #"Text("Hello", bundle: .module)"#).first?.passesBundle == true)

        // A literal that is not the FIRST argument is somebody else's parameter, not a key.
        #expect(Self.displayLiterals(in: #"Label(FernletUICopy.done, systemImage: "checkmark")"#).isEmpty)

        // Substring safety: an identifier ENDING in a head word is not that head.
        #expect(Self.displayLiterals(in: #"SheetText("caption")"#).isEmpty)
        #expect(Self.displayLiterals(in: #"myButton("x")"#).isEmpty)

        // Comments naming a call are documentation, not a call — the lesson part A learned the
        // hard way when six doc comments warning against localizing failed CI.
        #expect(Self.displayLiterals(in: #"// never write Text("Hello") here"#).isEmpty)
        #expect(Self.displayLiterals(in: "/* Text(\"Hello\") */\nlet y = 1").isEmpty)
        #expect(Self.displayLiterals(in: #"let sample = "Text(\"Hello\")""#).isEmpty,
                "a call named inside a string literal is data, not a call site")

        // A `bundle:` written inside a COMMENT in the span must not fake the argument.
        let faked = """
        Text("Hello",
             // bundle: .module was never added
             tableName: nil)
        """
        #expect(Self.displayLiterals(in: faked).first?.passesBundle == false)

        // Multi-line: the literal on a later line than the head still matches, and a paren inside
        // the literal does not end the span early.
        let multiline = """
        Text(
            "Meals (today)",
            bundle: .module
        )
        """
        #expect(Self.displayLiterals(in: multiline).first?.passesBundle == true)

        // THE TERNARY. Six of these were live in ProximityKit and the first draft of this rule —
        // which required the literal to be the first token — saw none of them.
        #expect(Self.displayLiterals(in: #"Button(isKept ? "Keeping" : "Keep") { toggle() }"#).count == 1)
        #expect(Self.displayLiterals(in: #"Button(isKept ? copy.keeping : copy.keep) { toggle() }"#).isEmpty)

        // The held-key form: the literal moved out of the call and into a property.
        let heldKey = """
        private var explainerText: LocalizedStringKey {
            saveToPhotos == nil ? "Choose which to save." : "Choose which to keep."
        }
        """
        #expect(Self.localizedStringKeyLiteralDeclarations(in: heldKey).count == 1)

        let resolvedProperty = """
        private var explainerText: String {
            saveToPhotos == nil ? ProximityUICopy.Review.explainerSave : ProximityUICopy.Review.explainerKeep
        }
        """
        #expect(Self.localizedStringKeyLiteralDeclarations(in: resolvedProperty).isEmpty)

        // A `LocalizedStringKey` PARAMETER is the correct architecture, not a violation — it is the
        // caller's key, harvested into the caller's catalog.
        let parameter = """
        public init(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) {
            self.label = Text(label)
        }
        """
        #expect(Self.localizedStringKeyLiteralDeclarations(in: parameter).isEmpty)

        // A stored property fed from such a parameter holds no literal of its own.
        #expect(Self.localizedStringKeyLiteralDeclarations(in: "    var placeholder: LocalizedStringKey").isEmpty)

        // The one-line forms. The first draft of the span reader missed BOTH — it required the
        // literal to be on a later line than the `{` — which the plant-it-and-watch-it-fail run
        // caught and no fixture would have.
        #expect(Self.localizedStringKeyLiteralDeclarations(
            in: #"    private var planted: LocalizedStringKey { "Planted" }"#).count == 1)
        #expect(Self.localizedStringKeyLiteralDeclarations(
            in: #"    let planted: LocalizedStringKey = "Planted""#).count == 1)
    }

    /// Fixture: the eight shapes an adversarial review used to walk straight through the first
    /// draft of these rules. One `#expect` per measured evasion; each was green before the
    /// hardening and is red now.
    @Test func hardenedRulesCatchTheMeasuredEvasions() {
        // (a) A parameter DEFAULT — the shape review §4.0 is literally about, and it carries no
        //     `var`/`let` for the property rule to key off.
        #expect(Self.localizedStringKeyLiteralDeclarations(
            in: #"    public init(label: LocalizedStringKey = "Save", disabled: Bool = false) {"#).count == 1)
        // …while a bare key parameter stays correct: that is the CALLER's key.
        #expect(Self.localizedStringKeyLiteralDeclarations(
            in: "    public init(_ label: LocalizedStringKey, disabled: Bool = false) {").isEmpty)
        // …and a literal default on a DIFFERENT parameter is not blamed on this one.
        #expect(Self.localizedStringKeyLiteralDeclarations(
            in: #"    init(_ label: LocalizedStringKey, identifier: String = "row") {"#).isEmpty)

        // (b) A function RETURNING a key — the property shape one keyword away.
        let returningFunction = """
        private func primaryActionLabel() -> LocalizedStringKey {
            saveToPhotos == nil ? "Save selected" : "Keep selected"
        }
        """
        #expect(Self.localizedStringKeyLiteralDeclarations(in: returningFunction).count == 1)

        // (c) The array spelling, which `": LocalizedStringKey"` could never match.
        #expect(Self.localizedStringKeyLiteralDeclarations(
            in: #"    static let names: [LocalizedStringKey] = ["Hat", "Face"]"#).count == 1)
        #expect(Self.localizedStringKeyLiteralDeclarations(
            in: #"    var title: LocalizedStringKey? = "Untitled""#).count == 1)

        // (d) + (e) Two heads that were simply missing from the lists.
        #expect(Self.displayLiterals(in: #".accessibilityAction(named: "Retry") { retry() }"#).count == 1)
        #expect(Self.displayLiterals(in: #"ContentUnavailableView("No meals yet", systemImage: "fork.knife")"#).count == 1)
        // A label-less action is a closure, not copy.
        #expect(Self.displayLiterals(in: ".accessibilityAction { retry() }").isEmpty)

        // (f) A MULTI-LINE signature. Rule F was line-based, so wrapping the parameter list hid the
        //     name from the return type. Nothing more exotic than a line break was needed.
        let wrappedSignature = """
        private func shutterAccessibilityLabel(
            canShoot: Bool
        ) -> String {
        """
        #expect(Self.stringTypedAccessibilityCopy(in: wrappedSignature).count == 1)
        // The same signature, correctly typed, still passes.
        let wrappedCorrect = """
        private func shutterAccessibilityLabel(
            canShoot: Bool
        ) -> Text {
        """
        #expect(Self.stringTypedAccessibilityCopy(in: wrappedCorrect).isEmpty)

        // (h) The verbatim exemption is now ARGUMENT-LEVEL. A literal that merely contains the
        //     word, or an interpolation of a variable named for it, no longer exempts the call.
        #expect(Self.displayLiterals(in: #"Text("Read this verbatim, please")"#).count == 1)
        #expect(Self.displayLiterals(in: #"Text("Signed \(verbatimFingerprint) today")"#).count == 1)
        // The real label still exempts, and so does a `verbatim`-prefixed one.
        #expect(Self.displayLiterals(in: #"Text(verbatim: "already final")"#).isEmpty)
        #expect(Self.displayLiterals(in: #"SheetTextEditor(verbatimPlaceholder: "already final")"#).isEmpty)

        // (g) is NOT here, and cannot be: a member renamed to `spokenName: String` matches no name
        //     fragment any rule can know in advance. That evasion is answered by the pinned list in
        //     `forkedMembers`, and its residue is stated in this file's header.
    }

    /// Fixture: the MULTI-LINE collection forms of evasion (c).
    ///
    /// The first fix for (c) was verified against a one-line array and declared closed; a second
    /// review pointed out that the fixture had flattened the very thing that made it an evasion.
    /// Wrapped across lines the array escaped twice over: ``logicalLines(in:)`` joined only round
    /// brackets, so the literals were never in the declaration's text, and
    /// ``declarationSpanHoldsLiteral(_:startingAt:)`` bails on a declaration with no `{`.
    @Test func multiLineCollectionsOfKeysAreCaught() {
        let wrappedArray = """
        private static let paletteNames: [LocalizedStringKey] = [
            "Near-black",
            "Bark",
        ]
        """
        #expect(Self.localizedStringKeyLiteralDeclarations(in: wrappedArray).count == 1)

        let wrappedDictionary = """
        static let bySlot: [String: LocalizedStringKey] = [
            "hat": "Hat",
            "face": "Face",
        ]
        """
        #expect(Self.localizedStringKeyLiteralDeclarations(in: wrappedDictionary).count == 1)

        // A wrapped collection of ALREADY-RESOLVED strings is the correct shape and stays clean.
        let wrappedResolved = """
        private static var paletteNames: [String] = [
            FernletUICopy.nearBlack,
            FernletUICopy.bark,
        ]
        """
        #expect(Self.localizedStringKeyLiteralDeclarations(in: wrappedResolved).isEmpty)

        // The joiner itself: square brackets now carry a unit across lines, and braces still do not
        // (a joined function body would make every rule read one enormous string).
        #expect(Self.logicalLines(in: "let a = [\n  1,\n  2\n]").first?.text == "let a = [ 1, 2 ]")
        #expect(Self.logicalLines(in: "func f() {\n  let x = 1\n}").first?.text == "func f() {")
        #expect(Self.delimiterBalance("let a = [") == 1)
        #expect(Self.delimiterBalance("]") == -1)
        #expect(Self.delimiterBalance(#"let s = "a [ b""#) == 0)
    }

    /// Fixture: `bundle: .main` inside a package is a violation, not a pass.
    ///
    /// The rule asked only whether a `bundle:` argument existed, so the one wrong value it will
    /// ever realistically be given — `.main`, the app's bundle, which is what an app→package move
    /// leaves behind — read as compliant. It is the same silent English as passing no bundle at all.
    @Test func onlyTheModuleBundleCountsInsidePackageSource() {
        let main = #"String(localized: "Saved", bundle: .main)"#
        #expect(Self.localizedCalls(in: main).first?.passesBundle == false)
        #expect(Self.localizedCalls(in: #"String(localized: "Saved", bundle: Bundle.main)"#).first?.passesBundle == false)

        // The correct spellings, both of them.
        #expect(Self.localizedCalls(in: #"String(localized: "Saved", bundle: .module)"#).first?.passesBundle == true)
        #expect(Self.localizedCalls(in: #"String(localized: "Saved", bundle: Bundle.module)"#).first?.passesBundle == true)

        // A trailing argument must not swallow the bundle value.
        #expect(Self.localizedCalls(in: #"String(localized: "Saved", bundle: .module, comment: "x")"#)
                .first?.passesBundle == true)
        #expect(Self.localizedCalls(in: #"String(localized: "Saved", bundle: .main, comment: "x")"#)
                .first?.passesBundle == false)

        // The SwiftUI half keys off the same helper.
        #expect(Self.displayLiterals(in: #"Text("Saved", bundle: .main)"#).first?.passesBundle == false)
        #expect(Self.displayLiterals(in: #"Text("Saved", bundle: .module)"#).first?.passesBundle == true)
    }

    /// Fixture: ``logicalLines(in:)`` joins a wrapped signature and leaves everything else alone.
    @Test func logicalLinesJoinWrappedSignaturesOnly() {
        let wrapped = """
        func f(
            a: Int,
            b: Int
        ) -> String {
            return "x"
        }
        """
        let units = Self.logicalLines(in: wrapped)
        #expect(units.first?.text == "func f( a: Int, b: Int ) -> String {")
        #expect(units.first?.line == 1)
        // The body lines are their own units — joining must not swallow the whole declaration.
        #expect(units.contains { $0.text == "return \"x\"" })

        // A balanced line is returned untouched, at its own 1-based number.
        let flat = "let a = 1\nlet b = f(2)"
        #expect(Self.logicalLines(in: flat).map(\.text) == ["let a = 1", "let b = f(2)"])
        #expect(Self.logicalLines(in: flat).map(\.line) == [1, 2])

        // A paren inside a string literal or a trailing comment must not unbalance the count.
        #expect(Self.delimiterBalance(#"let s = "a ( b""#) == 0)
        #expect(Self.delimiterBalance("let a = 1  // note (see above)") == 0)
    }

    /// Every display-literal call in `source`. Pure + testable; comments and nested string literals
    /// are skipped through the same ``skipNonCode(_:from:)`` every other scan in this file uses.
    static func displayLiterals(in source: String) -> [DisplayLiteralSite] {
        let chars = Array(source)
        var sites: [DisplayLiteralSite] = []
        var index = 0
        var line = 1
        while index < chars.count {
            if let skip = skipNonCode(chars, from: index) {
                line += countNewlines(chars, from: index, to: skip)
                index = max(skip, index + 1)
                continue
            }
            if chars[index] == "\n" { line += 1 }
            guard let head = displayCallHead(chars, at: index) else {
                index += 1
                continue
            }
            let end = endOfCall(chars, openParen: head.openParen)
            let literal = readStringLiteral(chars, from: head.quote)
            sites.append(DisplayLiteralSite(
                path: "", line: line, head: head.name, literal: literal.text,
                passesBundle: resolvesAgainstModuleBundle(code(chars, from: index, to: end))
            ))
            line += countNewlines(chars, from: index, to: end)
            index = max(end, index + 1)
        }
        return sites
    }

    /// When a display initializer or modifier head starts at `index` AND its FIRST ARGUMENT contains
    /// a string literal, that head's name plus the offsets of its `(` and of the literal's opening
    /// quote; otherwise nil.
    ///
    /// "The first argument contains a literal" — rather than "begins with one" — is what catches the
    /// shape that got past the first draft of this rule and shipped:
    /// `Button(isKept ? "Keeping" : "Keep")`. Six live literals in `ProximityKit` were hiding inside
    /// ternaries and were only found because adding that module's catalog made the harvester write
    /// them out as valueless keys.
    ///
    /// A first argument mentioning `verbatim` is exempt by construction: that label is this repo's
    /// marker for text that is already final, and it is chosen by typing it.
    static func displayCallHead(
        _ chars: [Character], at index: Int
    ) -> (name: String, openParen: Int, quote: Int)? {
        for name in displayModifiers where matches(chars, at: index, ".\(name)") {
            if let found = literalArgument(chars, after: index + name.count + 1) {
                return (".\(name)", found.openParen, found.quote)
            }
        }
        guard index == 0 || !isIdentifierCharacter(chars[index - 1]) else { return nil }
        for name in displayInitializers where matches(chars, at: index, name) {
            if let found = literalArgument(chars, after: index + name.count) {
                return (name, found.openParen, found.quote)
            }
        }
        return nil
    }

    /// The `(` at or after `index` and the opening quote of the first string literal inside its
    /// FIRST argument, when there is one; otherwise nil.
    static func literalArgument(_ chars: [Character], after index: Int) -> (openParen: Int, quote: Int)? {
        let cursor = skipWhitespace(chars, from: index)
        guard cursor < chars.count, chars[cursor] == "(" else { return nil }
        let openParen = cursor
        let argumentEnd = endOfFirstArgument(chars, openParen: openParen)
        // ARGUMENT-LEVEL exemption, not span-level. The first draft asked whether the word
        // "verbatim" appeared anywhere in the first argument, which any literal could satisfy on
        // its own: `Text("read this verbatim")` exempted itself, and so did an interpolation of a
        // variable that merely happened to be named `verbatimSomething`. Only the argument LABEL
        // counts now, because the label is the thing an author has to type on purpose.
        if let label = firstArgumentLabel(chars, openParen: openParen),
           label.lowercased().hasPrefix("verbatim") {
            return nil
        }
        guard let quote = firstQuote(chars, from: openParen + 1, to: argumentEnd) else { return nil }
        return (openParen, quote)
    }

    /// The first argument's LABEL (the identifier before its `:`), or nil when the first argument is
    /// unlabelled — which a string literal always is.
    static func firstArgumentLabel(_ chars: [Character], openParen: Int) -> String? {
        var cursor = skipWhitespace(chars, from: openParen + 1)
        var label = ""
        while cursor < chars.count, isIdentifierCharacter(chars[cursor]), chars[cursor] != "." {
            label.append(chars[cursor])
            cursor += 1
        }
        guard !label.isEmpty else { return nil }
        cursor = skipWhitespace(chars, from: cursor)
        guard cursor < chars.count, chars[cursor] == ":" else { return nil }
        return label
    }

    /// Index just past the first top-level argument of the call opening at `openParen` — the first
    /// `,` at nesting depth 1, or the closing `)`.
    static func endOfFirstArgument(_ chars: [Character], openParen: Int) -> Int {
        var depth = 0
        var index = openParen
        while index < chars.count {
            if let skip = skipNonCode(chars, from: index) {
                index = max(skip, index + 1)
                continue
            }
            let character = chars[index]
            if character == "(" || character == "[" || character == "{" { depth += 1 }
            if character == ")" || character == "]" || character == "}" {
                depth -= 1
                if depth <= 0 { return index }
            }
            if character == ",", depth == 1 { return index }
            index += 1
        }
        return chars.count
    }

    /// The index of the first string-literal quote in `from..<to`, skipping comments.
    static func firstQuote(_ chars: [Character], from: Int, to: Int) -> Int? {
        var index = from
        let end = min(to, chars.count)
        while index < end {
            if chars[index] == "\"" { return index }
            if chars[index] == "/", let skip = skipNonCode(chars, from: index) {
                index = max(skip, index + 1)
                continue
            }
            index += 1
        }
        return nil
    }

    /// Declarations in package source that HOLD a `LocalizedStringKey` literal of their own, in any
    /// of the three shapes a key can hide in.
    ///
    /// The second half of the ternary lesson, hardened after an adversarial review landed 3 of its
    /// 8 evasions here. `private var explainerText: LocalizedStringKey { … }` moves the literal out
    /// of the call and into a property, where no call-site scan can see it — and a key held in
    /// package source carries no bundle, so it still resolves against `Bundle.main`. The first
    /// draft caught only that one shape. All three are caught now:
    ///
    /// - **S — stored or computed property.** `var x: LocalizedStringKey { "…" }`, and the array,
    ///   optional and dictionary spellings (`[LocalizedStringKey]`, `LocalizedStringKey?`), which
    ///   the old `": LocalizedStringKey"` substring silently missed.
    /// - **P — parameter with a literal DEFAULT.** `init(label: LocalizedStringKey = "Save")` — the
    ///   exact shape review §4.0 exists to fix, and it has no `var`/`let` to key off. Only the
    ///   default is a violation; a bare `LocalizedStringKey` parameter is the opposite of one, and
    ///   is `FernletUI`'s whole architecture (it is the CALLER's key).
    /// - **R — function RETURNING a key.** `func label() -> LocalizedStringKey { cond ? "a" : "b" }`
    ///   is the property shape one keyword away, and evaded the property rule completely.
    ///
    /// Every span scan is bounded (Power of 10 rule 2): a declaration is read for at most
    /// ``maximumDeclarationLines`` lines, so a missing closing brace cannot run to end of file.
    static func localizedStringKeyLiteralDeclarations(in source: String) -> [(line: Int, text: String)] {
        let rawLines = source.components(separatedBy: "\n")
        var found: [(line: Int, text: String)] = []
        for unit in logicalLines(in: source) {
            let trimmed = unit.text
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { continue }
            guard declaresType(trimmed, named: "LocalizedStringKey") else { continue }
            if parameterHoldsLiteralDefault(trimmed, type: "LocalizedStringKey") {
                found.append((unit.line, trimmed))
                continue
            }
            guard isPropertyOrKeyReturningFunction(trimmed, type: "LocalizedStringKey") else { continue }
            // BOTH halves, because a value can live in either place. The joined logical line holds
            // an `= "…"` or an `= [ … ]` collection (square brackets are joined); the raw brace span
            // holds a multi-line computed body, which is NOT joined. Checking only the span missed
            // every multi-line array and dictionary — the span reader bails when a declaration has
            // no `{` at all.
            if valueHoldsLiteral(trimmed) || declarationSpanHoldsLiteral(rawLines, startingAt: unit.line - 1) {
                found.append((unit.line, trimmed))
            }
        }
        return found
    }

    /// True when `text` mentions `name` in TYPE position — after a `:` or a `->`, through any number
    /// of brackets, optionals and generic braces.
    ///
    /// Written as a token test rather than the old `": \(name)"` substring because `[Type]`,
    /// `Type?` and `[String: Type]` are all the same declaration wearing different punctuation, and
    /// the array spelling was a measured evasion.
    static func declaresType(_ text: String, named name: String) -> Bool {
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            guard matches(chars, at: index, name) else {
                index += 1
                continue
            }
            let after = index + name.count
            let boundedAfter = after >= chars.count || !isIdentifierCharacter(chars[after]) || chars[after] == "."
            if boundedAfter, typePositionPrecedes(chars, before: index) { return true }
            index = after
        }
        return false
    }

    /// True when a `:` or `->` introduces the type starting at `index`, ignoring the brackets and
    /// whitespace a container type puts in between.
    static func typePositionPrecedes(_ chars: [Character], before index: Int) -> Bool {
        var cursor = index - 1
        var steps = 0
        while cursor >= 0, steps < 64 {
            let character = chars[cursor]
            if character == ":" { return true }
            if character == ">", cursor > 0, chars[cursor - 1] == "-" { return true }
            guard character == " " || character == "[" || character == "<" || character == "(" else { return false }
            cursor -= 1
            steps += 1
        }
        return false
    }

    /// True when `text` is a `var`/`let` declaration of `type`, or a function RETURNING it.
    static func isPropertyOrKeyReturningFunction(_ text: String, type: String) -> Bool {
        if text.hasPrefix("var ") || text.hasPrefix("let ")
            || text.contains(" var ") || text.contains(" let ") { return true }
        guard let arrow = text.range(of: "->") else { return false }
        return declaresType(String(text[arrow.lowerBound...]), named: type)
    }

    /// True when a parameter of `type` carries a string-literal DEFAULT.
    ///
    /// Scans forward from the type to the end of that ONE parameter (its top-level `,` or the
    /// closing `)`), so a literal default on a *different* parameter — `Bool = false, name: String
    /// = "x"` beside a clean `LocalizedStringKey` — cannot be blamed on this one.
    static func parameterHoldsLiteralDefault(_ text: String, type: String) -> Bool {
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            guard matches(chars, at: index, type), typePositionPrecedes(chars, before: index) else {
                index += 1
                continue
            }
            let end = endOfParameter(chars, from: index + type.count)
            let slice = String(chars[min(index, end)..<end])
            if slice.contains("="), firstQuote(chars, from: index, to: end) != nil { return true }
            index = max(end, index + 1)
        }
        return false
    }

    /// Index of the `,` or `)` ending the parameter that starts at `index`.
    static func endOfParameter(_ chars: [Character], from index: Int) -> Int {
        var depth = 0
        var cursor = index
        while cursor < chars.count {
            if let skip = skipNonCode(chars, from: cursor) {
                cursor = max(skip, cursor + 1)
                continue
            }
            let character = chars[cursor]
            if character == "(" || character == "[" || character == "<" { depth += 1 }
            if character == ")" || character == "]" || character == ">" {
                if depth <= 0 { return cursor }
                depth -= 1
            }
            if character == ",", depth <= 0 { return cursor }
            cursor += 1
        }
        return chars.count
    }

    /// Source lines with their continuations joined, so a declaration split across lines is ONE unit.
    ///
    /// A line whose round OR SQUARE brackets are unbalanced absorbs the lines after it until they
    /// balance. Round brackets alone were the first version, and they made the multi-line signature
    /// evasion visible — but left the collection literal wide open:
    ///
    /// ```swift
    /// static let names: [LocalizedStringKey] = [
    ///     "Hat",                                  // ← invisible while only `(` counted
    ///     "Face",
    /// ]
    /// ```
    ///
    /// which is the same evasion as the wrapped signature, one bracket shape over. Bounded by
    /// ``maximumDeclarationLines`` per unit.
    ///
    /// Returns 1-based start lines and whitespace-collapsed text.
    static func logicalLines(in source: String) -> [(line: Int, text: String)] {
        let rawLines = source.components(separatedBy: "\n")
        var units: [(line: Int, text: String)] = []
        var index = 0
        while index < rawLines.count {
            var joined = rawLines[index].trimmingCharacters(in: .whitespaces)
            var depth = delimiterBalance(joined)
            var consumed = 0
            while depth > 0, index + consumed + 1 < rawLines.count, consumed < maximumDeclarationLines {
                consumed += 1
                let next = rawLines[index + consumed].trimmingCharacters(in: .whitespaces)
                joined += " " + next
                depth += delimiterBalance(next)
            }
            units.append((index + 1, joined))
            index += consumed + 1
        }
        return units
    }

    /// Round and square brackets opened minus closed on one line, ignoring comments and string
    /// literals.
    ///
    /// Braces are deliberately NOT counted: a `{` opens a body, and joining a whole function body
    /// into its signature would make every rule in this file read one enormous string. Bodies are
    /// reached instead through ``declarationSpanHoldsLiteral(_:startingAt:)``, which brace-balances
    /// on purpose.
    static func delimiterBalance(_ line: String) -> Int {
        let chars = Array(line)
        var depth = 0
        var index = 0
        while index < chars.count {
            if let skip = skipNonCode(chars, from: index) {
                if skip > index, chars[index] == "/" { return depth }
                index = max(skip, index + 1)
                continue
            }
            if chars[index] == "(" || chars[index] == "[" { depth += 1 }
            if chars[index] == ")" || chars[index] == "]" { depth -= 1 }
            index += 1
        }
        return depth
    }

    /// How many lines of a declaration the span scan will read before giving up.
    static let maximumDeclarationLines = 40

    /// True when the declaration starting at `index` holds a string literal in its VALUE — after the
    /// `{` of a computed property or the `=` of a stored one.
    ///
    /// Reading the value rather than the whole line is what keeps a `LocalizedStringKey` parameter
    /// (`_ label: LocalizedStringKey`) and a stored property fed from one (`var placeholder:
    /// LocalizedStringKey`) out of the results: neither has a value of its own here.
    static func declarationSpanHoldsLiteral(_ lines: [String], startingAt index: Int) -> Bool {
        var span = ""
        var depth = 0
        var seenBrace = false
        var cursor = index
        let limit = min(index + maximumDeclarationLines, lines.count)
        while cursor < limit {
            if cursor > index, !seenBrace { break }
            let line = lines[cursor]
            span += line + "\n"
            for character in line where character == "{" || character == "}" {
                seenBrace = true
                depth += character == "{" ? 1 : -1
            }
            if seenBrace, depth <= 0 { break }
            cursor += 1
        }
        return valueHoldsLiteral(span)
    }

    /// True when `text` holds a string literal in its VALUE — after the `{` of a computed property
    /// or the `=` of a stored one (or of a parameter default).
    ///
    /// Reading only the value is what keeps a bare `LocalizedStringKey` parameter — a CALLER's key,
    /// and `FernletUI`'s whole architecture — out of the results.
    static func valueHoldsLiteral(_ text: String) -> Bool {
        let chars = Array(text)
        guard let bodyStart = chars.firstIndex(where: { $0 == "{" || $0 == "=" }) else { return false }
        return firstQuote(chars, from: bodyStart, to: chars.count) != nil
    }

    /// True when `character` can appear inside a Swift identifier — the guard that stops `Text(`
    /// from matching inside `SheetText(`.
    static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "."
    }

    /// Scans every `.swift` file under ``packageSourceRoot`` for SwiftUI display literals.
    static func scanPackageForDisplayLiterals() throws -> (sites: [DisplayLiteralSite], filesScanned: Int) {
        let rootURL = RepoRoot.url(packageSourceRoot)
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
            Issue.record("Could not enumerate \(packageSourceRoot) — moved or renamed? The display-literal wall is unenforced.")
            return ([], 0)
        }
        var sites: [DisplayLiteralSite] = []
        var filesScanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            filesScanned += 1
            let relativePath = url.path.replacingOccurrences(of: RepoRoot.url.path + "/", with: "")
            for site in displayLiterals(in: source) {
                sites.append(DisplayLiteralSite(
                    path: relativePath, line: site.line, head: site.head,
                    literal: site.literal, passesBundle: site.passesBundle
                ))
            }
        }
        return (sites, filesScanned)
    }

    // MARK: - F2. The forked members, pinned by name

    /// One member this round forked off `String`, and the type it must keep.
    struct ForkedMember: Sendable {
        /// Repo-relative path of the file the member lives in.
        let path: String
        /// The declaration's exact trimmed text, as ``logicalLines(in:)`` renders it.
        let declaration: String
        /// What the member is for, so a failure reads as a regression and not a puzzle.
        let role: String
    }

    /// Every member review T2-1 forked, pinned by name AND file.
    ///
    /// **Why a pin and not a pattern.** Rule F keys off four name fragments
    /// (``accessibilityCopyNames``), which covers a member called `accessibilityLabel` and nothing
    /// else. Most of this round's forks are not named that way at all — `albumCellLabel`,
    /// `paletteName(at:)`, `caption`, `deleteMessage(equipmentCount:)` — so reverting any of them
    /// to `String` compiles, renders correctly in English, drops the string out of every catalog,
    /// and passes every other test in this file. The adversarial review demonstrated exactly that
    /// by renaming a member to `spokenName: String` and watching the wall stay green.
    ///
    /// A pin cannot generalize to a member nobody wrote down — that limit is stated in this file's
    /// header — but it does make THIS round's work non-revertible-in-silence, which is the property
    /// the round was for.
    static let forkedMembers: [ForkedMember] = [
        ForkedMember(path: "App/Fernlet/ConnectView.swift",
                     declaration: "private func albumCellLabel(_ post: FriendPhotoWallPost) -> Text {",
                     role: "the friend-photo album cell's spoken description"),
        ForkedMember(path: "App/Fernlet/ConnectView.swift",
                     declaration: "accessibilityLabel: LocalizedStringKey,",
                     role: "circleActionButton's caller-supplied VoiceOver label"),
        ForkedMember(path: "App/Fernlet/CreationStudioView.swift",
                     declaration: "private static func paletteName(at index: Int) -> Text {",
                     role: "the design canvas's 16 spoken colour names"),
        ForkedMember(path: "App/Fernlet/BarcodeScanView.swift",
                     declaration: "var caption: LocalizedStringKey",
                     role: "the scan-frame caption, drawn AND spoken"),
        ForkedMember(path: "App/Fernlet/HomeView.swift",
                     declaration: "private func firstAidChip(_ icon: String, _ label: LocalizedStringKey, tool: FirstAidTool) -> some View {",
                     role: "the First Aid chip's name and hint"),
        ForkedMember(path: "App/Fernlet/HomeView.swift",
                     declaration: "private var accessibilityLabelText: Text {",
                     role: "the Home summary card's spoken label"),
        ForkedMember(path: "App/Fernlet/MealPhotoPolaroid.swift",
                     declaration: "private var accessibilityText: Text {",
                     role: "the meal photo's spoken description, including its unavailable states"),
        ForkedMember(path: "App/Fernlet/JournalView.swift",
                     declaration: "var accessibilityLabel: Text {",
                     role: "the journal calendar cell, including the feeling tag"),
        ForkedMember(path: "App/Fernlet/CycleTrackerView.swift",
                     declaration: "var accessibilityLabel: Text {",
                     role: "the cycle calendar cell, including flow and intimacy"),
        ForkedMember(path: "App/Fernlet/MoveView.swift",
                     declaration: "var accessibilityLabel: Text {",
                     role: "the workout week cell — the one that was speaking WorkoutType.rawValue"),
        ForkedMember(path: "App/Fernlet/DisposableCameraView.swift",
                     declaration: "private func shutterAccessibilityLabel(canShoot: Bool) -> Text {",
                     role: "the camera shutter's four states"),
        ForkedMember(path: "App/Fernlet/WorkoutLocationSetupView.swift",
                     declaration: "static func deleteMessage(equipmentCount count: Int) -> LocalizedStringKey {",
                     role: "the location-delete confirmation body"),
        ForkedMember(path: "App/Fernlet/NutritionTargetsEditor.swift",
                     declaration: "let label: LocalizedStringKey",
                     role: "the macro row's drawn word, which is also the field's accessibility name"),
        ForkedMember(path: "App/Fernlet/DestructiveConfirmation.swift",
                     declaration: "let title: LocalizedStringKey",
                     role: "every irreversible dialog's title"),
        ForkedMember(path: "App/Fernlet/DestructiveConfirmation.swift",
                     declaration: "let message: Text",
                     role: "every irreversible dialog's body"),
        ForkedMember(path: "App/Fernlet/DestructiveConfirmation.swift",
                     declaration: "let confirmLabel: LocalizedStringKey",
                     role: "every irreversible dialog's destructive button"),
        ForkedMember(path: "App/Fernlet/DestructiveConfirmation.swift",
                     declaration: "let label: LocalizedStringKey",
                     role: "the second destructive outcome's button"),
        ForkedMember(path: "App/Fernlet/HomeView.swift",
                     declaration: "slot: LocalizedStringKey,",
                     role: "the wardrobe selector row's uppercase slot caption"),
        ForkedMember(path: "App/Fernlet/WardrobeView.swift",
                     declaration: "private func sectionLabel(_ text: LocalizedStringKey) -> some View {",
                     role: "the wardrobe's uppercase section caption"),
        ForkedMember(path: "FernletKit/Sources/FernletUI/FernletUIComponents.swift",
                     declaration: "public init(text: Binding<String>, placeholder: LocalizedStringKey, minHeight: CGFloat = 120) {",
                     role: "SheetTextEditor's placeholder, which is also the editor's accessibility name"),
        ForkedMember(path: "FernletKit/Sources/FernletUI/FernletUIComponents.swift",
                     declaration: "var placeholder: LocalizedStringKey",
                     role: "SheetGrowingTextField's placeholder, which names the field"),
    ]

    /// The members this round forked are still forked.
    ///
    /// Each entry names a declaration that used to be `String` and now must not be. Reverting one
    /// is SILENT in every other way — it compiles, it renders in English, and the string simply
    /// leaves the catalog — so this is the only test that would notice. The failure message names
    /// the member and what it is for, because "a fork was reverted" is useless without which one.
    ///
    /// Matching is on the declaration TEXT within its file, so a rename fails here too (loudly, as
    /// a stale pin) rather than quietly ceasing to protect anything.
    @Test func thisRoundsForkedMembersStillCarryLocalizedTypes() throws {
        var missing: [String] = []
        for entry in Self.forkedMembers {
            let url = RepoRoot.url(entry.path)
            let source = try String(contentsOf: url, encoding: .utf8)
            let present = Self.logicalLines(in: source).contains { $0.text.contains(entry.declaration) }
            if !present { missing.append("\(entry.path): \(entry.declaration)  ← \(entry.role)") }
        }
        #expect(
            missing.isEmpty,
            """
            \(missing.count) member(s) forked by accessibility review T2-1 no longer carry their \
            localized type. A revert to `String` binds SwiftUI's verbatim overload: it compiles, it \
            reads correctly in English, and the sentence silently leaves every string catalog. If a \
            member was deliberately RENAMED, update its pin in `forkedMembers` in the same commit:
            \(missing.sorted().joined(separator: "\n"))
            """
        )
    }

    /// One catalog key that a review-T2-1 fork put there, and the file it came from.
    struct HarvestedKey: Sendable {
        /// Repo-relative path of the catalog the key must appear in.
        let catalog: String
        /// The key exactly as the compiler harvested it.
        let key: String
        /// The fork that produced it, for the failure message.
        let source: String
    }

    /// Keys that exist ONLY because a `String` was forked to `LocalizedStringKey`/`Text` or routed
    /// through a copy vault. Every one was measured ABSENT from its catalog before the fork.
    static let harvestedForkKeys: [HarvestedKey] = [
        HarvestedKey(catalog: "App/Fernlet/Localizable.xcstrings", key: "Delete everything?",
                     source: "DestructiveConfirmation.title, forked String → LocalizedStringKey"),
        HarvestedKey(catalog: "App/Fernlet/Localizable.xcstrings",
                     key: "This deletes the location and its equipment setup. Your logged workouts are not affected.",
                     source: "WorkoutLocationSetupView.deleteMessage, forked String → LocalizedStringKey"),
        HarvestedKey(catalog: "App/Fernlet/Localizable.xcstrings", key: "Photo of %@",
                     source: "MealPhotoPolaroid.accessibilityText, forked String → Text"),
        HarvestedKey(catalog: "App/Fernlet/Localizable.xcstrings", key: "Day %lld, feeling %@",
                     source: "JournalMonthCell.accessibilityLabel, forked String → Text"),
        HarvestedKey(catalog: "App/Fernlet/Localizable.xcstrings", key: "Take photo",
                     source: "DisposableCameraView.shutterAccessibilityLabel, forked String → Text"),
        HarvestedKey(catalog: "App/Fernlet/Localizable.xcstrings", key: "Opens %@ straight away",
                     source: "HomeView.firstAidChip hint, label forked String → LocalizedStringKey"),
        HarvestedKey(catalog: "App/Fernlet/Localizable.xcstrings", key: "tab.home",
                     source: "FernletTab.title, forked literal → String(localized:)"),
        HarvestedKey(catalog: "FernletKit/Sources/FernletUI/Localizable.xcstrings", key: "ui.action.save",
                     source: "SheetSaveBar's default label, §4.0 — the trap its own doc comment named"),
        HarvestedKey(catalog: "FernletKit/Sources/FernletUI/Localizable.xcstrings",
                     key: "ui.capture.cover.recording",
                     source: "CaptureProtectedModifier.coverText, §4.0"),
        HarvestedKey(catalog: "FernletKit/Sources/ProximityKit/Localizable.xcstrings",
                     key: "proximity.keepFriends.keeping",
                     source: "the keep-as-friend chip's ternary literal, §4.0"),
        HarvestedKey(catalog: "FernletKit/Sources/AppServices/Localizable.xcstrings",
                     key: "notification.dailyCheckIn.title",
                     source: "NotificationService's daily check-in title, T2-19"),
    ]

    /// The forks actually reached a catalog.
    ///
    /// This is the half the other tests cannot show. Parts A, E and F prove no *bad* shape is left
    /// in the source; none of them proves a *good* shape produced anything. Harvesting is the step
    /// that was silently missing before — a `String` parameter compiles, renders correctly in
    /// English, and is simply never seen by the extractor, so the key a translator would work on
    /// does not exist. Reading the committed catalog is the only place that is observable.
    ///
    /// Every key below was measured absent from its catalog before this round's fork, so a failure
    /// here means a fork was reverted (or `Scripts/sync-string-catalogs.sh` was not re-run and
    /// committed), not that a string moved.
    @Test func everyForkedStringActuallyReachedItsCatalog() throws {
        var missing: [String] = []
        for entry in Self.harvestedForkKeys {
            let url = RepoRoot.url(entry.catalog)
            let data = try Data(contentsOf: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let strings = json?["strings"] as? [String: Any] ?? [:]
            #expect(!strings.isEmpty, "\(entry.catalog) parsed to zero keys — the catalog moved or broke")
            if strings[entry.key] == nil {
                missing.append("\(entry.catalog): \(entry.key)  ← \(entry.source)")
            }
        }
        #expect(
            missing.isEmpty,
            """
            \(missing.count) key(s) that a review-T2-1/§4.0 fork put into a string catalog are gone. \
            Either the fork was reverted — in which case the string is frozen English again, with a \
            clean build and no other failing test — or the catalogs were not re-synced. Run \
            Scripts/sync-string-catalogs.sh and commit the diff with the code change:
            \(missing.sorted().joined(separator: "\n"))
            """
        )
    }

    /// Keys whose whole point is a COUNT, and the catalog they live in.
    ///
    /// A `%lld` in a `defaultValue` is not a plural rule — it is one string with a number in it.
    /// Without an explicit `variations.plural` block the catalog offers a translator exactly one
    /// form, and every language with more than two (Russian, Polish, Arabic, Welsh) is stuck
    /// agreeing in the wrong number forever. English is already wrong at "1 coins".
    static let pluralRuledKeys: [HarvestedKey] = [
        HarvestedKey(catalog: "FernletKit/Sources/FernletUI/Localizable.xcstrings",
                     key: "ui.coins.balance",
                     source: "the coin pill's spoken balance"),
        HarvestedKey(catalog: "FernletKit/Sources/ProximityKit/Localizable.xcstrings",
                     key: "proximity.review.deleteAll",
                     source: "the photo review sheet's destructive button"),
        HarvestedKey(catalog: "App/Fernlet/Localizable.xcstrings",
                     key: "move.goalCount",
                     source: "the Move header's goal count"),
        // The Messages extension's four counts. All are hand-authored: the recipe subtitle is
        // three INDEPENDENT plurals ("4 servings · 9 ingredients · 6 steps"), which is why they are
        // three keys joined by punctuation rather than one key with three `%lld` slots — a single
        // key offers a translator one plural rule for three different nouns.
        HarvestedKey(catalog: "App/FernletMessagesExtension/Localizable.xcstrings",
                     key: "messages.recipe.servingCount",
                     source: "a Messages recipe card's serving count"),
        HarvestedKey(catalog: "App/FernletMessagesExtension/Localizable.xcstrings",
                     key: "messages.recipe.ingredientCount",
                     source: "a Messages recipe card's ingredient count"),
        HarvestedKey(catalog: "App/FernletMessagesExtension/Localizable.xcstrings",
                     key: "messages.recipe.stepCount",
                     source: "a Messages recipe card's step count"),
        HarvestedKey(catalog: "App/FernletMessagesExtension/Localizable.xcstrings",
                     key: "messages.workout.sessionCount",
                     source: "the session count on a shared workout plan"),
    ]

    /// Every count-bearing key carries real plural variations.
    ///
    /// These are hand-authored: `xcstringstool sync` adds keys and preserves what is already there,
    /// but it will never INVENT a plural rule, so nothing except this test would notice one being
    /// dropped — and the failure mode is a wrong number in a language nobody here reads.
    @Test func countBearingKeysCarryPluralVariations() throws {
        var missing: [String] = []
        for entry in Self.pluralRuledKeys {
            let data = try Data(contentsOf: RepoRoot.url(entry.catalog))
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let strings = json?["strings"] as? [String: Any] ?? [:]
            let localizations = (strings[entry.key] as? [String: Any])?["localizations"] as? [String: Any]
            let english = localizations?["en"] as? [String: Any]
            let plural = (english?["variations"] as? [String: Any])?["plural"] as? [String: Any]
            let forms = Set(plural?.keys ?? [:].keys)
            if !forms.contains("one") || !forms.contains("other") {
                missing.append("\(entry.catalog): \(entry.key)  ← \(entry.source)")
            }
        }
        #expect(
            missing.isEmpty,
            """
            \(missing.count) count-bearing key(s) have no `one`/`other` plural variation. A bare \
            `%lld` default gives a translator ONE form for a language that may need six, and \
            `xcstringstool sync` will never add the block back:
            \(missing.sorted().joined(separator: "\n"))
            """
        )
    }

    /// The two package string catalogs added by review §4.0 must keep existing.
    ///
    /// Their absence is SILENT in exactly the way ``theDomainModelStringCatalogStillExists()``
    /// describes: every `String(localized:…, bundle: .module)` in `FernletUI` and `ProximityKit`
    /// keeps compiling and keeps returning its `defaultValue`. Nothing else would notice.
    @Test func theModuleStringCatalogsAddedBySection40StillExist() {
        for module in ["FernletUI", "ProximityKit", "AppServices"] {
            let catalog = RepoRoot.url("FernletKit/Sources/\(module)/Localizable.xcstrings")
            #expect(
                FileManager.default.fileExists(atPath: catalog.path),
                """
                FernletKit/Sources/\(module)/Localizable.xcstrings is gone. Its absence is SILENT — \
                the module's copy vault keeps compiling and keeps returning English defaultValues. \
                Restore it (and its line in Scripts/sync-string-catalogs.sh) rather than deleting \
                this pin.
                """
            )
        }
    }

    // MARK: - F. Accessibility copy may not be typed `String`

    /// Roots scanned by part F: shipping source in both the app target and the package.
    ///
    /// Unlike part A this scan is NOT package-only, because the failure it guards is not about
    /// bundles at all — it is about which SwiftUI overload the argument's static type selects, and
    /// that is identical in the app target.
    static let accessibilityScanRoots = ["App", "FernletKit/Sources"]

    /// Floor for the part-F scan (385 `.swift` files across both roots at the time of writing). Set
    /// well below the real count so ordinary churn never trips it, but a root that stops resolving
    /// does — the same house rule as ``minimumPackageFilesScanned``.
    static let minimumAccessibilityFilesScanned = 320

    /// Identifier fragments that mark a declaration as *accessibility copy* — text whose only job is
    /// to be spoken.
    static let accessibilityCopyNames = [
        "accessibilitylabel", "accessibilityvalue", "accessibilityhint", "accessibilitytext",
    ]

    /// A declaration of accessibility copy that is typed `String`.
    struct AccessibilityCopyDeclaration: Hashable, Sendable {
        /// Repo-relative path.
        let path: String
        /// 1-based line.
        let line: Int
        /// The declaration's trimmed source line.
        let text: String

        /// `path:line: <declaration>` — pasteable straight into a search.
        var report: String { "\(path):\(line): \(text)" }
    }

    /// A `String`-typed accessibility member that is nonetheless correct, and why.
    struct AccessibilityCopyException: Sendable {
        /// Repo-relative path of the file.
        let path: String
        /// The declaration's exact trimmed text.
        let declaration: String
        /// Why `String` is right here.
        let reason: String
    }

    /// Every allowlisted `String`-typed accessibility member. Keep this list very short: a third or
    /// fourth entry means the rule, not the list, needs rethinking.
    static let accessibilityCopyExceptions: [AccessibilityCopyException] = [
        AccessibilityCopyException(
            path: "App/Fernlet/MoveView.swift",
            declaration: "private var spaceAccessibilityValue: String {",
            reason: """
                Not handed to `.accessibilityValue(_:)` at all — it is spliced into the `%@` slot of \
                the segment's own `.accessibilityLabel("Space, \\(…)")` key, which is where the \
                localization happens. Its own body resolves through `String(localized:)`, so the \
                value in that slot is translated too. A `Text` here could not be interpolated into \
                a `LocalizedStringKey` argument list without becoming a second key.
                """
        ),
    ]

    /// An accessibility label, value or hint whose static type is `String` does not localize —
    /// SwiftUI's `StringProtocol` overload renders it verbatim — and, worse, the compiler never
    /// harvests it, so the string is not even *present* in the catalog for a translator to find.
    ///
    /// This is the rule the review's §4.5 calls "the highest-value single rule available", and it
    /// deliberately lives HERE rather than in an accessibility wall: it is a localization failure
    /// that happens to surface through accessibility APIs, and one home beats two half-rules.
    ///
    /// It is a TYPE check, not a call-site grep, for the reason §4.5 gives: a grep over
    /// `.accessibilityLabel(x)` cannot tell `x: String` (a defect) from `x: Text` (correct), because
    /// the argument's type is exactly what is invisible at the call site. Checking the declaration
    /// is the one place the type is written down.
    ///
    /// A declaration carrying `verbatim` is exempt by construction: that label is this repo's
    /// documented marker for text that is *already final* (`SectionLabel.init(verbatim:)`,
    /// `EmptyState.init(verbatim:)`, `FernletAnnouncer.announce(_:resolved:)`), and it is chosen by
    /// typing it, which is the whole point of the convention.
    @Test func accessibilityCopyIsNeverTypedString() throws {
        let (declarations, filesScanned) = try Self.scanForStringTypedAccessibilityCopy()

        #expect(
            filesScanned >= Self.minimumAccessibilityFilesScanned,
            """
            Scanned only \(filesScanned) Swift files under \(Self.accessibilityScanRoots.joined(separator: ", ")) \
            (floor \(Self.minimumAccessibilityFilesScanned)) — a root moved or the enumerator broke, \
            and this wall is now passing without looking at anything.
            """
        )

        let offenders = declarations.filter { declaration in
            !Self.accessibilityCopyExceptions.contains { Self.matches($0, declaration) }
        }
        #expect(
            offenders.isEmpty,
            """
            \(offenders.count) accessibility label/value/hint member(s) are typed `String`. SwiftUI \
            renders a `String` VERBATIM — it never localizes — and the compiler never harvests it, \
            so the sentence is not in any catalog for a translator to even see. Declare it as \
            `Text` (or `LocalizedStringKey` for a parameter), or, if it really is already-resolved \
            text, give it a `verbatim` label so the choice is one somebody typed:
            \(offenders.map(\.report).sorted().joined(separator: "\n"))
            """
        )

        let unused = Self.accessibilityCopyExceptions.filter { entry in
            !declarations.contains { Self.matches(entry, $0) }
        }
        #expect(
            unused.isEmpty,
            """
            \(unused.count) allowlisted `String`-typed accessibility member(s) match nothing any \
            more. Delete them — a stale entry is a hole nobody is watching:
            \(unused.map { "\($0.path): \($0.declaration)" }.sorted().joined(separator: "\n"))
            """
        )
    }

    /// Exact path AND exact declaration text — never a path-only match, so an entry cannot turn its
    /// file into an exempt file.
    static func matches(_ entry: AccessibilityCopyException, _ declaration: AccessibilityCopyDeclaration) -> Bool {
        declaration.path == entry.path && declaration.text == entry.declaration
    }

    /// Fixture: the type check fires on each shape that must fail and stays silent on each shape
    /// that must pass.
    ///
    /// Part F is expected to report zero forever, so — as everywhere else in this file — only a
    /// planted token distinguishes "nothing is wrong" from "the matcher never runs".
    @Test func accessibilityCopyTypeCheckSeesTheStringForms() {
        // The four shapes that were live in the tree the day this rule was written.
        #expect(Self.stringTypedAccessibilityCopy(in: "    var accessibilityLabel: String {").count == 1)
        #expect(Self.stringTypedAccessibilityCopy(in: "    private var accessibilityText: String {").count == 1)
        #expect(Self.stringTypedAccessibilityCopy(in: "    private func shutterAccessibilityLabel(canShoot: Bool) -> String {").count == 1)
        #expect(Self.stringTypedAccessibilityCopy(in: "        accessibilityLabel: String,").count == 1)
        #expect(Self.stringTypedAccessibilityCopy(in: "    var accessibilityHint: String?").count == 1,
                "an optional is the same defect")

        // The corrected forms.
        #expect(Self.stringTypedAccessibilityCopy(in: "    var accessibilityLabel: Text {").isEmpty)
        #expect(Self.stringTypedAccessibilityCopy(in: "        accessibilityLabel: LocalizedStringKey,").isEmpty)
        #expect(Self.stringTypedAccessibilityCopy(in: "    private func albumCellLabel(_ post: Post) -> Text {").isEmpty)

        // `verbatim` is the documented "already final" marker and is exempt by construction.
        #expect(Self.stringTypedAccessibilityCopy(in: "        verbatim accessibilityLabel: String,").isEmpty)

        // A CALL SITE is not a declaration — the leading dot is the discriminator, and without it
        // this rule would fire on all ~150 correct `.accessibilityLabel(…)` uses in the app.
        #expect(Self.stringTypedAccessibilityCopy(in: "        .accessibilityLabel(name as String)").isEmpty)
        #expect(Self.stringTypedAccessibilityCopy(in: "            .accessibilityValue(String(describing: x))").isEmpty)

        // Documentation naming the pattern is documentation.
        #expect(Self.stringTypedAccessibilityCopy(in: "    /// var accessibilityLabel: String is the defect").isEmpty)
        #expect(Self.stringTypedAccessibilityCopy(in: "    // accessibilityLabel: String").isEmpty)

        // An unrelated `String` member is not accessibility copy.
        #expect(Self.stringTypedAccessibilityCopy(in: "    var summaryText: String {").isEmpty)
    }

    /// The `String`-typed accessibility-copy declarations in `source`, by line. Pure + testable.
    ///
    /// Runs over ``logicalLines(in:)``, not raw lines. The first draft was line-based, and an
    /// adversarial review broke it by doing nothing more exotic than wrapping a signature:
    ///
    /// ```swift
    /// private func shutterAccessibilityLabel(
    ///     canShoot: Bool
    /// ) -> String {          // ← the name and the type are now on different lines
    /// ```
    ///
    /// Joining continuation lines until the round brackets balance puts the name and the return
    /// type back in one string, which is the only form this rule can reason about.
    static func stringTypedAccessibilityCopy(in source: String) -> [(line: Int, text: String)] {
        var found: [(line: Int, text: String)] = []
        for unit in logicalLines(in: source) {
            let trimmed = unit.text
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"), !trimmed.contains("verbatim") else { continue }
            if accessibilityCopyTypes(in: trimmed).contains(where: isStringType) {
                found.append((unit.line, trimmed))
            }
        }
        return found
    }

    /// The declared type of every accessibility-copy member named in `text`.
    ///
    /// Reading each member's OWN type — rather than asking whether the string `": String"` occurs
    /// anywhere in it — is what makes the rule survive line-joining. A wrapped signature legitimately
    /// mixes types (`systemName: String` beside `accessibilityLabel: LocalizedStringKey`), and the
    /// first joined version of this rule reported all three such helpers in the tree as violations.
    /// Returns one entry per named member, so a signature carrying two is fully checked.
    static func accessibilityCopyTypes(in text: String) -> [String] {
        let chars = Array(text)
        var types: [String] = []
        var index = 0
        while index < chars.count {
            guard let nameEnd = accessibilityCopyNameEnd(chars, at: index) else {
                index += 1
                continue
            }
            if let type = declaredType(chars, after: nameEnd) { types.append(type) }
            index = nameEnd
        }
        return types
    }

    /// The index just past an accessibility-copy identifier starting at `index`, or nil.
    ///
    /// Whole-identifier matching: the scan finds identifier STARTS (a letter or `_` whose
    /// predecessor is neither an identifier character nor a `.`), reads the identifier out, and asks
    /// whether it contains one of ``accessibilityCopyNames``. That covers both `accessibilityLabel`
    /// and `shutterAccessibilityLabel` without a second code path, and the leading-dot exclusion is
    /// what separates a DECLARATION from the ~150 correct `.accessibilityLabel(…)` call sites.
    static func accessibilityCopyNameEnd(_ chars: [Character], at index: Int) -> Int? {
        guard chars[index].isLetter || chars[index] == "_" else { return nil }
        if index > 0, isIdentifierCharacter(chars[index - 1]) { return nil }
        var cursor = index
        while cursor < chars.count, chars[cursor].isLetter || chars[cursor].isNumber || chars[cursor] == "_" {
            cursor += 1
        }
        let identifier = String(chars[index..<cursor]).lowercased()
        guard accessibilityCopyNames.contains(where: identifier.contains) else { return nil }
        return cursor
    }

    /// The type a declaration gives the member whose identifier ends at `nameEnd`.
    ///
    /// Two shapes, and only two: `name: Type` (property or parameter) and
    /// `name(<params>) -> Type` (function). Anything else — a call, a `case`, prose — yields nil.
    static func declaredType(_ chars: [Character], after nameEnd: Int) -> String? {
        var cursor = skipWhitespace(chars, from: nameEnd)
        guard cursor < chars.count else { return nil }
        if chars[cursor] == ":" {
            let end = endOfParameter(chars, from: cursor + 1)
            return String(chars[(cursor + 1)..<min(end, chars.count)]).trimmingCharacters(in: .whitespaces)
        }
        guard chars[cursor] == "(" else { return nil }
        cursor = endOfCall(chars, openParen: cursor)
        cursor = skipWhitespace(chars, from: cursor)
        guard matches(chars, at: cursor, "->") else { return nil }
        cursor = skipWhitespace(chars, from: cursor + 2)
        var end = cursor
        while end < chars.count, chars[end] != "{" { end += 1 }
        return String(chars[cursor..<end]).trimmingCharacters(in: .whitespaces)
    }

    /// True when a declared type IS `String` (optionals included) rather than merely mentioning it.
    ///
    /// `StringProtocol`, `StringLiteralType` and `[String]` are other types; a bare `String`,
    /// `String?` and `String!` are the defect, and `= "default"` after it is still the same type.
    static func isStringType(_ type: String) -> Bool {
        var head = type
        // A property carries its body brace and a parameter its default; neither is part of the
        // type. Trimming both is what lets `var accessibilityLabel: String {` and
        // `accessibilityHint: String? = nil` resolve to the same answer as a bare `String`.
        if let brace = head.firstIndex(of: "{") { head = String(head[..<brace]) }
        if let equals = head.firstIndex(of: "=") { head = String(head[..<equals]) }
        head = head.trimmingCharacters(in: .whitespaces)
        return head == "String" || head == "String?" || head == "String!"
    }

    /// Scans both shipping roots for `String`-typed accessibility copy.
    static func scanForStringTypedAccessibilityCopy() throws -> (
        declarations: [AccessibilityCopyDeclaration], filesScanned: Int
    ) {
        var declarations: [AccessibilityCopyDeclaration] = []
        var filesScanned = 0
        for root in accessibilityScanRoots {
            let rootURL = RepoRoot.url(root)
            guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
                Issue.record("Could not enumerate \(root) — moved or renamed? The accessibility-copy wall is unenforced.")
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                filesScanned += 1
                let relativePath = url.path.replacingOccurrences(of: RepoRoot.url.path + "/", with: "")
                for found in stringTypedAccessibilityCopy(in: source) {
                    declarations.append(AccessibilityCopyDeclaration(
                        path: relativePath, line: found.line, text: found.text
                    ))
                }
            }
        }
        return (declarations, filesScanned)
    }

    // MARK: - G. `LocalizedError` copy may not be a bare literal

    /// Roots scanned by part G: shipping source in both the app target and the package.
    ///
    /// The same two roots as part F, for the same reason — the defect is not about bundles, so the
    /// app target is exactly as exposed as the package.
    static let localizedErrorScanRoots = ["App", "FernletKit/Sources"]

    /// Floor for the part-G scan (406 `.swift` files across both roots at the time of writing). Set
    /// well below the real count so ordinary churn never trips it, but a root that stops resolving
    /// does — the same house rule as ``minimumPackageFilesScanned``.
    static let minimumLocalizedErrorFilesScanned = 320

    /// The `LocalizedError` members whose value a person actually reads.
    ///
    /// `helpAnchor` is deliberately absent: it names a macOS help-book anchor, which is a token.
    static let localizedErrorCopyMembers = ["errorDescription", "failureReason", "recoverySuggestion"]

    /// A user-facing sentence sitting in a `LocalizedError` member as a plain literal.
    struct LocalizedErrorLiteral: Hashable, Sendable {
        /// Repo-relative path.
        let path: String
        /// 1-based line of the literal itself, not of the member that holds it.
        let line: Int
        /// The literal's text, with any interpolation collapsed to `{}`.
        let literal: String

        /// `path:line: "<literal>"` — pasteable straight into a search.
        var report: String { "\(path):\(line): \"\(literal)\"" }
    }

    /// A bare literal in a `LocalizedError` member that is nonetheless correct, and why.
    struct LocalizedErrorException: Sendable {
        /// Repo-relative path of the file.
        let path: String
        /// The literal's exact text.
        let literal: String
        /// Why no key belongs here.
        let reason: String
    }

    /// Every allowlisted bare literal. Keep this list short: entries are copy a person could in
    /// principle read, exempted only because no build that reaches a person contains them.
    ///
    /// `#if DEBUG` copy needs no entry — ``debugOnlyLineFlags(in:)`` skips it structurally, because
    /// a sentence that is not in the shipping binary cannot be read in any language.
    /// Empty, and that is the finished state. It held three `MessageTransportProbe` sentences whose
    /// argument was "its target owns no catalog, so cataloguing them buys a translator nothing".
    /// Rule H2 gave the Messages extension a catalog and a `TARGETS` line, which retired the
    /// argument rather than answering it — the three sentences are now keyed like every other one,
    /// at a cost of nine lines. The probe itself is still dead code with zero call sites; deleting
    /// it remains the right cleanup, and now costs three catalog keys rather than a rule change.
    static let localizedErrorExceptions: [LocalizedErrorException] = []

    /// A sentence returned from `errorDescription` / `failureReason` / `recoverySuggestion` as a
    /// plain literal never reaches a catalog, so it renders English in every language forever.
    ///
    /// This is a BODY rule, and it has to be: parts A and E read only `FernletKit/Sources`, and part
    /// F — the one rule that reads `App/` — asserts that display copy is not typed `String`.
    /// `LocalizedError` mandates `String?`, so F's type signal cannot fire here and its remedy
    /// (declare it `Text`) is not available. `String(localized:)` inside the body is the only form
    /// that reaches a catalog, so the only thing left to check is whether it is there.
    ///
    /// The check is deliberately blunt: after every `String(localized:)` / `AttributedString(localized:)`
    /// call in the body is blanked out — which takes its `defaultValue:` and `comment:` literals with
    /// it — ANY string literal left standing is a violation. Measured over the tree the day it was
    /// written, that produced exactly the two known-and-argued skips and no false positive at all,
    /// so a narrower "is this literal in return position" rule would have bought precision nobody
    /// needed and cost the ability to see a literal spliced in through a `let` or a ternary.
    ///
    /// Empty and whitespace-only literals are ignored: `""` is a sentinel, not a sentence.
    @Test func localizedErrorCopyIsNeverABareLiteral() throws {
        let (literals, filesScanned) = try Self.scanForBareLocalizedErrorLiterals()

        #expect(
            filesScanned >= Self.minimumLocalizedErrorFilesScanned,
            """
            Scanned only \(filesScanned) Swift files under \(Self.localizedErrorScanRoots.joined(separator: ", ")) \
            (floor \(Self.minimumLocalizedErrorFilesScanned)) — a root moved or the enumerator broke, \
            and this wall is now passing without looking at anything.
            """
        )

        let offenders = literals.filter { literal in
            !Self.localizedErrorExceptions.contains { Self.matches($0, literal) }
        }
        #expect(
            offenders.isEmpty,
            """
            \(offenders.count) `LocalizedError` sentence(s) are plain string literals. Nothing \
            harvests them, so they are not in any catalog for a translator to see and they render \
            English in every language — through Shortcuts, the share sheet and system alerts, where \
            nobody on the team will ever notice. Wrap each in `String(localized:defaultValue:comment:)` \
            with a dotted-namespace key (`<domain>.error.<case>`), adding `bundle: .module` if and \
            only if the file is package source:
            \(offenders.map(\.report).sorted().joined(separator: "\n"))
            """
        )

        let unused = Self.localizedErrorExceptions.filter { entry in
            !literals.contains { Self.matches(entry, $0) }
        }
        #expect(
            unused.isEmpty,
            """
            \(unused.count) allowlisted bare `LocalizedError` literal(s) match nothing any more. \
            Delete them — a stale entry is a hole nobody is watching:
            \(unused.map { "\($0.path): \($0.literal)" }.sorted().joined(separator: "\n"))
            """
        )
    }

    /// Exact path AND exact literal — never a path-only match, so an entry cannot turn its file into
    /// an exempt file.
    static func matches(_ entry: LocalizedErrorException, _ literal: LocalizedErrorLiteral) -> Bool {
        literal.path == entry.path && literal.literal == entry.literal
    }

    /// Fixture: the body rule fires on each shape that must fail and stays silent on each shape that
    /// must pass.
    ///
    /// Part G is expected to report zero forever once the sweep lands, so — as everywhere else in
    /// this file — only a planted violation distinguishes "nothing is wrong" from "the matcher never
    /// runs". Both directions are planted, because a matcher that fires on everything is as useless
    /// as one that fires on nothing.
    @Test func localizedErrorBodyScannerSeesTheLiteralForms() {
        // MUST TRIP — the shapes the sweep found in the tree.
        #expect(Self.bareLocalizedErrorLiterals(in: """
            var errorDescription: String? {
                "Could not read that label."
            }
            """).count == 1, "a single implicit return is the commonest shape")
        #expect(Self.bareLocalizedErrorLiterals(in: """
            public var errorDescription: String? {
                switch self {
                case .a: "First."
                case .b: return "Second."
                }
            }
            """).count == 2, "implicit and explicit returns are the same defect")
        #expect(Self.bareLocalizedErrorLiterals(in: """
            var failureReason: String? { "Why it failed." }
            """).count == 1, "failureReason is display copy too")
        #expect(Self.bareLocalizedErrorLiterals(in: """
            var recoverySuggestion: String? { "Try again." }
            """).count == 1, "so is recoverySuggestion")
        #expect(Self.bareLocalizedErrorLiterals(in: """
            var errorDescription: String? {
                let prefix = "Keychain "
                return prefix + operation
            }
            """).count == 1, "a literal laundered through a `let` is still uncatalogued copy")
        #expect(Self.bareLocalizedErrorLiterals(in: """
            var errorDescription: String? = "Stored, not computed."
            """).count == 1, "a stored property satisfies the protocol just as well")
        #expect(Self.bareLocalizedErrorLiterals(in: """
            var errorDescription: String? {
                String(localized: "k", defaultValue: "Fine.", comment: "c") + " and \\("x")"
            }
            """).count == 1, "one localized call does not launder a second bare literal beside it")

        // MUST NOT TRIP — the corrected forms and the near misses.
        #expect(Self.bareLocalizedErrorLiterals(in: """
            var errorDescription: String? {
                String(localized: "camera.error.unavailable",
                       defaultValue: "Camera access is unavailable.",
                       comment: "Shown when the camera cannot be opened.")
            }
            """).isEmpty, "the whole point: defaultValue and comment are INSIDE the call")
        #expect(Self.bareLocalizedErrorLiterals(in: """
            public var errorDescription: String? {
                String(localized: "lock.error.locked",
                       defaultValue: "App lock is locked.",
                       bundle: .module,
                       comment: "Shown when the lock is closed.")
            }
            """).isEmpty, "package form, with the module bundle")
        #expect(Self.bareLocalizedErrorLiterals(in: """
            var errorDescription: String? {
                switch self {
                case .invalidCredential(let message): message
                }
            }
            """).isEmpty, "a pass-through of an already-finished sentence holds no literal")
        #expect(Self.bareLocalizedErrorLiterals(in: """
            var errorDescription: String? { nil }
            """).isEmpty, "no literal, no finding")
        #expect(Self.bareLocalizedErrorLiterals(in: """
            var errorDescription: String? {
                // A note mentioning "a quoted phrase" is documentation.
                String(localized: "k", defaultValue: "Fine.", comment: "c")
            }
            """).isEmpty, "comments are not code — the lesson part A learned the hard way")
        #expect(Self.bareLocalizedErrorLiterals(in: """
            var errorDescription: String? { "" }
            """).isEmpty, "an empty literal is a sentinel, not a sentence")

        // A READ or an ARGUMENT LABEL is not a declaration — without this discriminator the rule
        // fires on every `catch` block in the app that unwraps someone else's errorDescription.
        #expect(Self.bareLocalizedErrorLiterals(in: """
            notice = (error as? LocalizedError)?.errorDescription ?? "Could not import that."
            """).isEmpty, "a leading dot means a read, not a declaration")
        #expect(Self.bareLocalizedErrorLiterals(in: """
            queue.noteFailure(record, errorDescription: "Could not import that.")
            """).isEmpty, "an argument label is not a member declaration")
        #expect(Self.bareLocalizedErrorLiterals(in: """
            init(errorDescription: String? = "Default.") { }
            """).isEmpty, "nor is an initializer parameter")
        #expect(Self.bareLocalizedErrorLiterals(in: """
            /// var errorDescription: String? { "the defect" }
            """).isEmpty, "documentation naming the pattern is documentation")

        // A neighbouring member's body must not be swallowed into this one.
        #expect(Self.bareLocalizedErrorLiterals(in: """
            var errorDescription: String? {
                String(localized: "k", defaultValue: "Fine.", comment: "c")
            }
            var debugSummary: String {
                "Not display copy."
            }
            """).isEmpty, "the scan resumes AFTER the body, and debugSummary is not one of the three")
    }

    /// Fixture: `#if DEBUG` copy is skipped, and only the branch that actually is debug-only.
    ///
    /// The carve-out is structural rather than an allowlist entry because it is mechanically true —
    /// a sentence excluded from the shipping binary cannot be read in the wrong language — and
    /// because the evasion it appears to open is self-defeating: wrapping real copy in `#if DEBUG`
    /// removes it from the app along with the finding.
    @Test func debugOnlyErrorCopyIsSkippedButItsReleaseBranchIsNot() {
        #expect(Self.bareLocalizedErrorLiterals(in: """
            #if DEBUG
            var errorDescription: String? { "A probe diagnostic." }
            #endif
            """).isEmpty, "DEBUG-only copy never reaches a person")
        #expect(Self.bareLocalizedErrorLiterals(in: """
            #if DEBUG
            var errorDescription: String? { "A probe diagnostic." }
            #else
            var errorDescription: String? { "Shipping copy." }
            #endif
            """).count == 1, "the #else of an #if DEBUG is the RELEASE branch and must still be checked")
        #expect(Self.bareLocalizedErrorLiterals(in: """
            #if !DEBUG
            var errorDescription: String? { "Shipping copy." }
            #else
            var errorDescription: String? { "A probe diagnostic." }
            #endif
            """).count == 1, "and the sense inverts with the condition")
        #expect(Self.bareLocalizedErrorLiterals(in: """
            #if canImport(UIKit)
            var errorDescription: String? { "Shipping copy." }
            #else
            var errorDescription: String? { "Also shipping copy." }
            #endif
            """).count == 2, "an unrelated condition exempts neither branch")
        #expect(Self.bareLocalizedErrorLiterals(in: """
            #if DEBUG
            let probe = 1
            #endif
            var errorDescription: String? { "Shipping copy." }
            """).count == 1, "#endif closes the region — code after it is shipping code again")
    }

    /// The four package string catalogs this sweep created must keep existing.
    ///
    /// Same silent failure as ``theModuleStringCatalogsAddedBySection40StillExist()``, and the
    /// reason these four are pinned separately: before the sweep they did not exist at all, so the
    /// 30 keys these four now hold had nowhere to go. Delete one and every
    /// `String(localized:…, bundle: .module)` in that module keeps compiling and keeps returning its
    /// English `defaultValue` — no warning, no failing build, no missing symbol.
    ///
    /// A catalog is only half of it: a module also needs its line in the `TARGETS` array of
    /// `Scripts/sync-string-catalogs.sh`, or it emits `.stringsdata` that nothing ever syncs and the
    /// catalog silently stops tracking the code. That half is checked by
    /// ``everyLocalizedErrorCatalogIsWiredIntoTheSyncScript()``.
    @Test func theStringCatalogsAddedByTheLocalizedErrorSweepStillExist() {
        for module in Self.localizedErrorSweepCatalogModules {
            let catalog = RepoRoot.url("FernletKit/Sources/\(module)/Localizable.xcstrings")
            #expect(
                FileManager.default.fileExists(atPath: catalog.path),
                """
                FernletKit/Sources/\(module)/Localizable.xcstrings is gone. Its absence is SILENT — \
                the module's LocalizedError copy keeps compiling and keeps returning English \
                defaultValues. Restore it (and its line in Scripts/sync-string-catalogs.sh) rather \
                than deleting this pin.
                """
            )
        }
    }

    /// The modules that gained their first catalog in the `LocalizedError` sweep.
    static let localizedErrorSweepCatalogModules = [
        "AIProviders", "CloudKitSync", "FernletFoundation", "HealthKitGateway",
    ]

    /// Every module with a catalog is also named in the sync script's `TARGETS` array.
    ///
    /// The catalog and the `TARGETS` line are one change in two files, and the missing half fails
    /// SILENTLY in the direction nobody checks: the module compiles, `String(localized:)` returns
    /// its `defaultValue`, and the catalog simply stops learning about new keys. `--check` cannot
    /// catch it either — a target it was never told about is a target it never looks at.
    @Test func everyLocalizedErrorCatalogIsWiredIntoTheSyncScript() throws {
        let script = try RepoRoot.source("Scripts/sync-string-catalogs.sh")
        var unwired: [String] = []
        for module in Self.localizedErrorSweepCatalogModules {
            let entry = "\"\(module):FernletKit/Sources/\(module)/Localizable.xcstrings\""
            if !script.contains(entry) { unwired.append(entry) }
        }
        #expect(
            unwired.isEmpty,
            """
            \(unwired.count) module(s) own a Localizable.xcstrings that Scripts/sync-string-catalogs.sh \
            never syncs. The module emits .stringsdata nobody reads, so its catalog silently stops \
            tracking the code — and `--check` cannot notice, because it only checks targets it was \
            told about. Add to the TARGETS array:
            \(unwired.sorted().joined(separator: "\n"))
            """
        )
    }

    /// Every bare display literal inside a `LocalizedError` copy member in `source`, by line.
    ///
    /// Pure + testable, and line-oriented at the top so a member's body can be found without a
    /// parser: a declaration line, then a brace-balanced (or `=`-terminated) span, then a character
    /// walk over that span that blanks comments and whole `String(localized:)` calls.
    static func bareLocalizedErrorLiterals(in source: String) -> [(line: Int, literal: String)] {
        let chars = Array(source)
        let lines = source.components(separatedBy: "\n")
        let debugOnly = debugOnlyLineFlags(in: source)
        let starts = lineStartOffsets(in: chars, lineCount: lines.count)
        var found: [(line: Int, literal: String)] = []
        var index = 0
        while index < lines.count {
            guard !debugOnly[index], declaresLocalizedErrorCopy(lines[index]),
                  let span = localizedErrorValueSpan(chars, lineStart: starts[index]) else {
                index += 1
                continue
            }
            found += bareLiterals(chars, from: span.start, to: span.end, startLine: index + 1)
            // Resume AFTER the body, so a member declared inside it is not scanned twice and the
            // next member's own declaration line is still reached.
            while index + 1 < starts.count, starts[index + 1] < span.end { index += 1 }
            index += 1
        }
        return found
    }

    /// Character offset where each 0-based line begins.
    static func lineStartOffsets(in chars: [Character], lineCount: Int) -> [Int] {
        var starts = [0]
        starts.reserveCapacity(lineCount)
        for (offset, character) in chars.enumerated() where character == "\n" { starts.append(offset + 1) }
        while starts.count < lineCount { starts.append(chars.count) }
        return starts
    }

    /// True when a line DECLARES one of ``localizedErrorCopyMembers``.
    ///
    /// The discriminator is the preceding keyword, and it is what separates the ~14 declarations in
    /// the tree from the far more numerous reads (`(error as? LocalizedError)?.errorDescription`),
    /// argument labels (`noteFailure(record, errorDescription:)`) and initializer parameters. A
    /// leading `.` is excluded by ``isIdentifierCharacter(_:)`` counting it as part of an identifier.
    static func declaresLocalizedErrorCopy(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { return false }
        let chars = Array(trimmed)
        var index = 0
        while index < chars.count {
            guard chars[index].isLetter || chars[index] == "_" else { index += 1; continue }
            if index > 0, isIdentifierCharacter(chars[index - 1]) { index += 1; continue }
            var cursor = index
            while cursor < chars.count, chars[cursor].isLetter || chars[cursor].isNumber || chars[cursor] == "_" {
                cursor += 1
            }
            if localizedErrorCopyMembers.contains(String(chars[index..<cursor])),
               declarationKeywordPrecedes(chars, before: index) {
                return true
            }
            index = max(cursor, index + 1)
        }
        return false
    }

    /// True when the identifier starting at `index` is introduced by `var` or `func`.
    static func declarationKeywordPrecedes(_ chars: [Character], before index: Int) -> Bool {
        var cursor = index - 1
        while cursor >= 0, chars[cursor] == " " { cursor -= 1 }
        let end = cursor + 1
        while cursor >= 0, chars[cursor].isLetter { cursor -= 1 }
        let word = String(chars[(cursor + 1)..<max(end, cursor + 1)])
        return word == "var" || word == "func"
    }

    /// The span of a copy member's VALUE: a brace-balanced body, or the rest of the statement after
    /// an `=`.
    ///
    /// Both shapes conform to `LocalizedError`, so both are checked. `nil` when the declaration line
    /// carries neither — a protocol requirement written `{ get }` has a body and simply holds no
    /// literal, which the walk below reports as the zero findings it is.
    static func localizedErrorValueSpan(_ chars: [Character], lineStart: Int) -> (start: Int, end: Int)? {
        var index = lineStart
        while index < chars.count, chars[index] != "\n" {
            if let skip = skipNonCode(chars, from: index), skip > index {
                index = max(skip, index + 1)
                continue
            }
            if chars[index] == "{" { return (index, endOfBody(chars, openBrace: index)) }
            if chars[index] == "=" { return (index, endOfStatement(chars, from: index)) }
            index += 1
        }
        return nil
    }

    /// Index just past the `}` matching `openBrace`, skipping comments and string literals so a brace
    /// inside a sentence cannot end the body early.
    static func endOfBody(_ chars: [Character], openBrace: Int) -> Int {
        var depth = 0
        var index = openBrace
        while index < chars.count {
            if let skip = skipNonCode(chars, from: index), skip > index {
                index = max(skip, index + 1)
                continue
            }
            if chars[index] == "{" { depth += 1 }
            if chars[index] == "}" {
                depth -= 1
                if depth <= 0 { return index + 1 }
            }
            index += 1
        }
        return chars.count
    }

    /// Index of the end of the statement starting at `index` — the next newline outside any literal,
    /// comment or bracket. The stored-property (`= "…"`) counterpart of ``endOfBody(_:openBrace:)``.
    static func endOfStatement(_ chars: [Character], from index: Int) -> Int {
        var depth = 0
        var cursor = index
        while cursor < chars.count {
            if let skip = skipNonCode(chars, from: cursor), skip > cursor {
                cursor = max(skip, cursor + 1)
                continue
            }
            if chars[cursor] == "(" || chars[cursor] == "[" { depth += 1 }
            if chars[cursor] == ")" || chars[cursor] == "]" { depth -= 1 }
            if chars[cursor] == "\n", depth <= 0 { return cursor }
            cursor += 1
        }
        return chars.count
    }

    /// The string literals in `from..<to` that are neither inside a comment nor inside a
    /// `String(localized:)` call — which is exactly the set that reaches no catalog.
    static func bareLiterals(
        _ chars: [Character], from: Int, to: Int, startLine: Int
    ) -> [(line: Int, literal: String)] {
        var found: [(line: Int, literal: String)] = []
        var index = from
        var line = startLine
        let end = min(to, chars.count)
        while index < end {
            if chars[index] == "\n" { line += 1; index += 1; continue }
            if chars[index] == "/", let skip = skipNonCode(chars, from: index), skip > index {
                line += countNewlines(chars, from: index, to: skip)
                index = max(skip, index + 1)
                continue
            }
            // A localized call swallows its own `defaultValue:` and `comment:` literals, which is
            // the whole discriminator: those two ARE the catalogued form.
            if chars[index] == "S", let openParen = localizedCallHead(chars, at: index) {
                let callEnd = endOfCall(chars, openParen: openParen)
                line += countNewlines(chars, from: index, to: callEnd)
                index = max(callEnd, index + 1)
                continue
            }
            guard chars[index] == "\"" else { index += 1; continue }
            let literal = readStringLiteral(chars, from: index)
            if !literal.text.trimmingCharacters(in: .whitespaces).isEmpty {
                found.append((line, literal.text))
            }
            line += countNewlines(chars, from: index, to: literal.end)
            index = max(literal.end, index + 1)
        }
        return found
    }

    /// Whether each 0-based line sits inside a branch that only compiles in DEBUG.
    ///
    /// Tracks `#if` / `#elseif` / `#else` / `#endif` as a stack of frames, so a nested directive
    /// cannot clear an enclosing DEBUG region. `#else` inverts only when the frame's own condition
    /// was about DEBUG: the `#else` of `#if DEBUG` is the release branch, the `#else` of
    /// `#if !DEBUG` is the debug branch, and the `#else` of `#if canImport(UIKit)` is neither.
    static func debugOnlyLineFlags(in source: String) -> [Bool] {
        var flags: [Bool] = []
        var stack: [(isDebugBranch: Bool, isAboutDebug: Bool)] = []
        for raw in source.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if") {
                let condition = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                stack.append((condition == "DEBUG", condition == "DEBUG" || condition == "!DEBUG"))
            } else if trimmed.hasPrefix("#elseif"), !stack.isEmpty {
                let condition = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                stack[stack.count - 1] = (condition == "DEBUG", condition == "DEBUG" || condition == "!DEBUG")
            } else if trimmed == "#else", !stack.isEmpty {
                let frame = stack[stack.count - 1]
                stack[stack.count - 1] = (frame.isAboutDebug && !frame.isDebugBranch, frame.isAboutDebug)
            } else if trimmed.hasPrefix("#endif"), !stack.isEmpty {
                stack.removeLast()
            }
            flags.append(stack.contains { $0.isDebugBranch })
        }
        return flags
    }

    /// Scans both shipping roots for bare literals in `LocalizedError` copy members.
    static func scanForBareLocalizedErrorLiterals() throws -> (
        literals: [LocalizedErrorLiteral], filesScanned: Int
    ) {
        var literals: [LocalizedErrorLiteral] = []
        var filesScanned = 0
        for root in localizedErrorScanRoots {
            let rootURL = RepoRoot.url(root)
            guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
                Issue.record("Could not enumerate \(root) — moved or renamed? The LocalizedError-copy wall is unenforced.")
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                filesScanned += 1
                let relativePath = url.path.replacingOccurrences(of: RepoRoot.url.path + "/", with: "")
                for found in bareLocalizedErrorLiterals(in: source) {
                    literals.append(LocalizedErrorLiteral(
                        path: relativePath, line: found.line, literal: found.literal
                    ))
                }
            }
        }
        return (literals, filesScanned)
    }

    // MARK: - H. UIKit display copy: the assignment shape, and the one UIKit target

    /// Roots scanned by part H1: shipping source in both the app target and the package — the same
    /// two as F and G, for the same reason. The defect is not about bundles.
    static let uikitAssignmentScanRoots = ["App", "FernletKit/Sources"]

    /// Floor for the part-H1 scan (408 `.swift` files across both roots at the time of writing).
    static let minimumUIKitAssignmentFilesScanned = 320

    /// UIKit properties whose value a person reads or hears.
    ///
    /// Deliberately NOT `title`: `UIButton.Configuration.title`, `UINavigationItem.title` and
    /// `MSMessage`'s own layout all use it, but so does every value type in the tree with a `title`
    /// field — a recipe, a workout card, a catalog entry — and those are data, not display copy set
    /// on a view. Including it made the rule report the model layer. The button titles this round
    /// fixed reach their `Configuration` through a function argument, which H1 could not see either
    /// way; H2 is what actually caught them.
    static let uikitDisplayProperties = [
        "text", "attributedText", "placeholder", "summaryText",
        "caption", "subcaption", "trailingCaption",
        "accessibilityLabel", "accessibilityValue", "accessibilityHint",
    ]

    /// A UIKit display or accessibility property assigned a bare literal.
    struct UIKitDisplayAssignment: Hashable, Sendable {
        /// Repo-relative path.
        let path: String
        /// 1-based line of the assignment.
        let line: Int
        /// The property assigned, e.g. `accessibilityHint`.
        let property: String
        /// The literal's text, with any interpolation collapsed to `{}`.
        let literal: String

        /// `path:line: <property> = "<literal>"` — pasteable straight into a search.
        var report: String { "\(path):\(line): \(property) = \"\(literal)\"" }
    }

    /// A UIKit display property set to a bare literal never reaches a catalog.
    ///
    /// This is the shape rule F cannot see. F is a TYPE check over `var` / `func` DECLARATIONS —
    /// `var accessibilityHint: String` — and it is the right rule for SwiftUI, where copy is
    /// declared before it is handed to a modifier. UIKit declares nothing: it ASSIGNS, on an object
    /// it does not own, to a property whose type is fixed by the framework at `String?`. There is no
    /// declaration to check and no `Text` to declare instead, so F's signal cannot fire and F's
    /// remedy is not available. `String(localized:)` is the only form that reaches a catalog here,
    /// exactly as in rule G, so — exactly as in rule G — the check is whether it is there.
    ///
    /// Measured over both roots the day it was written, this found 12 assignments, all in
    /// `FernletMessagesViewController`, and no false positive.
    ///
    /// LIMIT, and it is the load-bearing one: 12 was a small fraction of that file's real surface of
    /// 57. The rest reached the screen as function arguments, `UIButton.Configuration` titles,
    /// initializer arguments and helper returns — the "INDIRECTION THROUGH A TYPE" ceiling this file
    /// documents, which no assignment-shaped rule can close. H1 generalizes to any UIKit file added
    /// later; ``everyMessagesExtensionLiteralIsCataloguedOrAnArguedToken()`` is what actually holds
    /// today's one UIKit target shut. Neither substitutes for the other.
    ///
    /// Literals with no letters are ignored: `""` is a sentinel and `" · "` is punctuation. That is
    /// what lets the fixed code join plural-ruled counts with a separator instead of keying it.
    @Test func uikitDisplayCopyIsNeverABareLiteral() throws {
        let (assignments, filesScanned) = try Self.scanForBareUIKitDisplayAssignments()

        #expect(
            filesScanned >= Self.minimumUIKitAssignmentFilesScanned,
            """
            Scanned only \(filesScanned) Swift files under \(Self.uikitAssignmentScanRoots.joined(separator: ", ")) \
            (floor \(Self.minimumUIKitAssignmentFilesScanned)) — a root moved or the enumerator broke, \
            and this wall is now passing without looking at anything.
            """
        )

        #expect(
            assignments.isEmpty,
            """
            \(assignments.count) UIKit display/accessibility propert(ies) are assigned a bare string \
            literal. Nothing harvests them, so they are in no catalog for a translator to see and \
            they render English in every language. Wrap each in \
            `String(localized:defaultValue:comment:)` with a dotted-namespace key, or — if the \
            target already has a copy vault, as `FernletMessagesExtension` does — add a member there \
            and assign that. App-target source takes NO `bundle:` argument; package source takes \
            `bundle: .module`:
            \(assignments.map(\.report).sorted().joined(separator: "\n"))
            """
        )
    }

    /// Fixture: the assignment rule fires on each shape that must fail and stays silent on each
    /// shape that must pass.
    ///
    /// Both directions are planted, because H1 is expected to report zero forever from the day it
    /// lands — and a matcher nobody has proven is indistinguishable from one that never fires.
    @Test func uikitAssignmentScannerSeesTheDisplayShapes() {
        // MUST TRIP — the shapes measured in FernletMessagesViewController before the fix.
        #expect(Self.bareUIKitDisplayAssignments(in: #"        statusLabel.text = "Fernlet couldn't prepare this item.""#).count == 1,
                "the plain label assignment is the commonest shape")
        #expect(Self.bareUIKitDisplayAssignments(in: #"        browseButton.accessibilityHint = "Shows the catalog.""#).count == 1,
                "an accessibility hint is display copy too")
        #expect(Self.bareUIKitDisplayAssignments(in: #"        message.summaryText = "Fernlet: \(title)""#).count == 1,
                "interpolation does not make a literal catalogued")
        #expect(Self.bareUIKitDisplayAssignments(in: #"        layout.trailingCaption = "Fernlet recipe""#).count == 1,
                "the Messages card captions are display copy")
        #expect(Self.bareUIKitDisplayAssignments(in: #"        label.text = value ?? "Open Fernlet.""#).count == 1,
                "a literal reached through `??` is still the fallback a person reads")
        #expect(Self.bareUIKitDisplayAssignments(in: """
                    searchBar.placeholder = isRecipes
                        ? "Search recipes"
                        : "Search plans"
            """).count == 2, "a ternary wrapped onto its own lines hides two literals, not zero")
        #expect(Self.bareUIKitDisplayAssignments(in: #"        label.accessibilityValue = on ? "Selected" : """#).count == 1,
                "the empty arm is a sentinel; only the spoken arm counts")

        // MUST NOT TRIP.
        #expect(Self.bareUIKitDisplayAssignments(in: """
                label.text = String(localized: "messages.brand", defaultValue: "⌁  FERNLET",
                                    comment: "Wordmark above the composer title.")
            """).isEmpty, "a localized call is the catalogued form — its own literals must not count")
        #expect(Self.bareUIKitDisplayAssignments(in: #"        label.text = FernletMessagesCopy.brand"#).isEmpty,
                "a copy-vault member is already keyed")
        #expect(Self.bareUIKitDisplayAssignments(in: #"        searchBar.text = """#).isEmpty,
                "clearing a field is not copy")
        #expect(Self.bareUIKitDisplayAssignments(in: #"        label.text = [a, b].joined(separator: " · ")"#).isEmpty,
                "a separator carries no letters, so it is punctuation, not a sentence")
        #expect(Self.bareUIKitDisplayAssignments(in: #"        if entry.text == "done" { return }"#).isEmpty,
                "a comparison is not an assignment")
        #expect(Self.bareUIKitDisplayAssignments(in: #"        card.title = "Weeknight pasta""#).isEmpty,
                "`title` is excluded on purpose — it is a model field far more often than a view's")
        #expect(Self.bareUIKitDisplayAssignments(in: #"        // label.text = "an old note about the label""#).isEmpty,
                "a commented-out assignment ships nothing")
        #expect(Self.bareUIKitDisplayAssignments(in: #"        label.text = url ?? "see https://fernlet.com for help""#).count == 1,
                "the `//` inside a URL literal is not a comment — truncating there would hide the sentence")
        #expect(Self.bareUIKitDisplayAssignments(in: """
            #if DEBUG
                    label.text = "seeded"
            #endif
            """).isEmpty, "copy that is not in the shipping binary cannot be read in the wrong language")
    }

    // MARK: - H2. The one UIKit target, held shut whole

    /// The only target in the repo whose views are UIKit rather than SwiftUI.
    ///
    /// `FernletShareExtension` also has a `ShareViewController`, but it renders no copy of its own —
    /// its three sentences are `LocalizedError` cases, which rule G already owns.
    static let uikitTargetRoot = "App/FernletMessagesExtension"

    /// Floor for the part-H2 scan: the target's three Swift files. Small on purpose — this root is
    /// one directory, so the floor's job is to notice the directory moving, not churn.
    static let minimumUIKitTargetFilesScanned = 3

    /// A literal in the UIKit target that is a protocol or system TOKEN rather than copy.
    struct UIKitTargetToken: Sendable {
        /// Repo-relative path of the file.
        let path: String
        /// The literal's exact text.
        let literal: String
        /// Why this is a token and not a sentence.
        let reason: String
    }

    /// Every literal in `App/FernletMessagesExtension` that is not display copy.
    ///
    /// Keep this list honest rather than short: it is the target's complete token inventory, and
    /// each entry is the argument for why translating it would BREAK something.
    static let uikitTargetTokens: [UIKitTargetToken] = [
        UIKitTargetToken(
            path: "App/FernletMessagesExtension/FernletMessagesViewController.swift",
            literal: "fork.knife",
            reason: """
                SF Symbol name, resolved by `UIImage(systemName:)` against Apple's fixed catalogue. \
                Translating it returns nil and the card loses its glyph.
                """
        ),
        UIKitTargetToken(
            path: "App/FernletMessagesExtension/FernletMessagesViewController.swift",
            literal: "dumbbell.fill",
            reason: "SF Symbol name — see the `fork.knife` entry."
        ),
        UIKitTargetToken(
            path: "App/FernletMessagesExtension/FernletMessagesViewController.swift",
            literal: "figure.strengthtraining.traditional",
            reason: "SF Symbol name — see the `fork.knife` entry."
        ),
        UIKitTargetToken(
            path: "App/FernletMessagesExtension/FernletMessagesViewController.swift",
            literal: "FernletMessages.lastRecipeID",
            reason: """
                `UserDefaults` key. It is written on selection and read back on the next launch, so \
                a spelling that varied by language would lose the person's last choice every time \
                they changed the device language — the exact silent-data-loss failure the \
                token/display separation exists to prevent.
                """
        ),
        UIKitTargetToken(
            path: "App/FernletMessagesExtension/MessageTransportProbe.swift",
            literal: "data:application/vnd.fernlet.message-probe;base64,",
            reason: """
                Wire prefix of the probe's data URL. It is written by `url(for:)` and matched with \
                `hasPrefix` by `payload(from:)`, so the two halves stop agreeing the moment it is \
                translated.
                """
        ),
    ]

    /// Every string a person reads in the one UIKit target is catalogued, or is an argued token.
    ///
    /// WHY A WHOLE-TARGET RULE and not just H1. `a814ac4` added a complete user-facing target, and
    /// every wall in this repo looked straight past it: rules A and E read `FernletKit/Sources`;
    /// rule F checks declarations, and UIKit assigns; rule G reads `LocalizedError` members. The
    /// target had no `Localizable.xcstrings` and no `TARGETS` line in
    /// `Scripts/sync-string-catalogs.sh`, so writing `String(localized:)` there would have harvested
    /// nothing either — the surface was not merely unswept, it was unsweepable. Fifty-seven
    /// sentences shipped frozen in English, and no test in the repo could have gone red.
    ///
    /// H1 is the general shape rule and it found 12 of those 57. This is the rule that finds the
    /// other 45, and it can be this blunt precisely because the target is three files: anything with
    /// a letter in it is either keyed or listed above with a reason. It is the same instrument as
    /// `S3BoundaryTests`'s per-file inventories — cheap because the surface is small, and exact
    /// because it does not try to be clever about which shape the string reached the screen through.
    ///
    /// It does NOT generalize: pointed at `App/Fernlet` it would report thousands of legitimate
    /// tokens. It is scoped to the one directory whose entire job is presentation.
    @Test func everyMessagesExtensionLiteralIsCataloguedOrAnArguedToken() throws {
        let (literals, filesScanned) = try Self.scanUIKitTargetForBareLiterals()

        #expect(
            filesScanned >= Self.minimumUIKitTargetFilesScanned,
            """
            Scanned only \(filesScanned) Swift files under \(Self.uikitTargetRoot) \
            (floor \(Self.minimumUIKitTargetFilesScanned)) — the target moved or the enumerator \
            broke, and this wall is now passing without looking at anything.
            """
        )

        let offenders = literals.filter { literal in
            !Self.uikitTargetTokens.contains { Self.matches($0, literal) }
        }
        #expect(
            offenders.isEmpty,
            """
            \(offenders.count) bare string literal(s) in \(Self.uikitTargetRoot) are neither \
            catalogued nor listed as tokens. If a person reads it, add a member to \
            `FernletMessagesCopy` and use that (no `bundle:` argument — an appex's `Bundle.main` is \
            its own bundle). If it is a symbol name, a defaults key or a wire string, add it to \
            `uikitTargetTokens` WITH the argument for why translating it would break something:
            \(offenders.map(\.report).sorted().joined(separator: "\n"))
            """
        )

        let unused = Self.uikitTargetTokens.filter { entry in
            !literals.contains { Self.matches(entry, $0) }
        }
        #expect(
            unused.isEmpty,
            """
            \(unused.count) allowlisted token(s) match nothing any more. Delete them — a stale entry \
            is a hole nobody is watching:
            \(unused.map { "\($0.path): \($0.literal)" }.sorted().joined(separator: "\n"))
            """
        )
    }

    /// Exact path AND exact literal — never a path-only match, so an entry cannot turn its file into
    /// an exempt file.
    static func matches(_ entry: UIKitTargetToken, _ literal: LocalizedErrorLiteral) -> Bool {
        literal.path == entry.path && literal.literal == entry.literal
    }

    /// The Messages extension's catalog and its `TARGETS` line must both keep existing.
    ///
    /// Two files, one change, and the missing half is silent in both directions: without the
    /// catalog every `String(localized:)` in the target quietly returns its `defaultValue`; without
    /// the `TARGETS` line the catalog stops learning about new keys and `--check` cannot notice,
    /// because it only checks targets it was told about. This is the pin that would have failed on
    /// the day `a814ac4` landed.
    @Test func theMessagesExtensionCatalogIsWiredIntoTheSyncScript() throws {
        let catalog = RepoRoot.url("App/FernletMessagesExtension/Localizable.xcstrings")
        #expect(
            FileManager.default.fileExists(atPath: catalog.path),
            """
            App/FernletMessagesExtension/Localizable.xcstrings is gone. Its absence is SILENT — \
            every String(localized:) in the extension keeps compiling and keeps returning its \
            English defaultValue. Restore it rather than deleting this pin.
            """
        )
        let script = try RepoRoot.source("Scripts/sync-string-catalogs.sh")
        #expect(
            script.contains("\"FernletMessagesExtension:App/FernletMessagesExtension/Localizable.xcstrings\""),
            """
            The Messages extension has a Localizable.xcstrings that Scripts/sync-string-catalogs.sh \
            never syncs. The target emits .stringsdata nobody reads, so its catalog silently stops \
            tracking the code. Restore its line in the TARGETS array.
            """
        )
    }

    /// Fixture: the whole-target scan separates catalogued copy from bare copy.
    @Test func uikitTargetScannerSeparatesCataloguedCopyFromBareCopy() {
        #expect(Self.bareLettersBearingLiterals(in: #"    static let prefix = "data:application/probe;base64,""#).count == 1,
                "an un-keyed literal is reported; the allowlist is what argues it away, not the scan")
        #expect(Self.bareLettersBearingLiterals(in: """
                String(localized: "messages.brand", defaultValue: "⌁  FERNLET",
                       comment: "Wordmark above the composer title.")
            """).isEmpty, "a localized call swallows its own defaultValue and comment")
        #expect(Self.bareLettersBearingLiterals(in: #"        [a, b].joined(separator: " · ")"#).isEmpty,
                "punctuation carries no letters")
        #expect(Self.bareLettersBearingLiterals(in: #"        guard !text.isEmpty else { return "" }"#).isEmpty,
                "an empty sentinel is not a sentence")
        #expect(Self.bareLettersBearingLiterals(in: #"        // a note mentioning "some copy" in prose"#).isEmpty,
                "a comment ships nothing")
        #expect(Self.bareLettersBearingLiterals(in: """
            #if DEBUG
                    let seed = "seeded"
            #endif
            """).isEmpty, "debug-only copy is not in the shipping binary")
    }

    // MARK: - H. Discovery and matchers

    /// Scans both shipping roots for UIKit display properties assigned a bare literal.
    static func scanForBareUIKitDisplayAssignments() throws -> (
        assignments: [UIKitDisplayAssignment], filesScanned: Int
    ) {
        var assignments: [UIKitDisplayAssignment] = []
        var filesScanned = 0
        for root in uikitAssignmentScanRoots {
            let rootURL = RepoRoot.url(root)
            guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
                Issue.record("Could not enumerate \(root) — moved or renamed? The UIKit-assignment wall is unenforced.")
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                filesScanned += 1
                let relativePath = url.path.replacingOccurrences(of: RepoRoot.url.path + "/", with: "")
                for found in bareUIKitDisplayAssignments(in: source) {
                    assignments.append(UIKitDisplayAssignment(
                        path: relativePath, line: found.line, property: found.property, literal: found.literal
                    ))
                }
            }
        }
        return (assignments, filesScanned)
    }

    /// Scans the one UIKit target for any letter-bearing literal that is not inside a localized call.
    static func scanUIKitTargetForBareLiterals() throws -> (
        literals: [LocalizedErrorLiteral], filesScanned: Int
    ) {
        let rootURL = RepoRoot.url(uikitTargetRoot)
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
            Issue.record("Could not enumerate \(uikitTargetRoot) — moved or renamed? The UIKit-target wall is unenforced.")
            return ([], 0)
        }
        var literals: [LocalizedErrorLiteral] = []
        var filesScanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            filesScanned += 1
            let relativePath = url.path.replacingOccurrences(of: RepoRoot.url.path + "/", with: "")
            for found in bareLettersBearingLiterals(in: source) {
                literals.append(LocalizedErrorLiteral(
                    path: relativePath, line: found.line, literal: found.literal
                ))
            }
        }
        return (literals, filesScanned)
    }

    /// Every letter-bearing string literal in `source` that is not part of a `String(localized:)`
    /// call, skipping comments and `#if DEBUG` branches.
    ///
    /// The letter test is what makes a whole-file rule usable: `""`, `" · "` and `"%@"` are
    /// sentinels, punctuation and format, and reporting them would drown the real finding.
    static func bareLettersBearingLiterals(in source: String) -> [(line: Int, literal: String)] {
        let chars = Array(source)
        let debugOnly = debugOnlyLineFlags(in: source)
        return bareLiterals(chars, from: 0, to: chars.count, startLine: 1).filter { found in
            guard found.literal.contains(where: { $0.isLetter }) else { return false }
            let index = found.line - 1
            return index < 0 || index >= debugOnly.count || !debugOnly[index]
        }
    }

    /// Every UIKit display/accessibility property in `source` assigned a bare literal.
    ///
    /// Line-oriented at the top, then a character walk over the assignment's VALUE span — the same
    /// two-stage shape as ``bareLocalizedErrorLiterals(in:)``, and for the same reason: the value is
    /// where the literal is, and reading only the value keeps a comparison (`==`) and a
    /// same-named model field out of the results.
    static func bareUIKitDisplayAssignments(in source: String) -> [(line: Int, property: String, literal: String)] {
        let chars = Array(source)
        let lines = source.components(separatedBy: "\n")
        let debugOnly = debugOnlyLineFlags(in: source)
        let starts = lineStartOffsets(in: chars, lineCount: lines.count)
        var found: [(line: Int, property: String, literal: String)] = []
        for index in lines.indices {
            guard !debugOnly[index],
                  let hit = uikitDisplayAssignment(in: codeOnlyPrefix(of: lines[index])) else { continue }
            let span = uikitAssignmentValueSpan(
                chars: chars, lines: lines, starts: starts, from: index, equalsColumn: hit.equalsColumn
            )
            for literal in bareLiterals(chars, from: span.start, to: span.end, startLine: index + 1)
            where literal.literal.contains(where: { $0.isLetter }) {
                found.append((literal.line, hit.property, literal.literal))
            }
        }
        return found
    }

    /// `line` up to its first comment, so a commented-out assignment is not read as live code.
    ///
    /// Not cosmetic: the value span starts just past the `=`, which for a `// label.text = "…"`
    /// line is already INSIDE the comment — so the span scan's own comment skipping has nothing
    /// left to skip and reports the literal. The planted near-miss fixture caught exactly this.
    /// `skipNonCode` does the walking, so a `//` inside a string literal (`"https://…"`) is not
    /// mistaken for a comment and a block comment is skipped whole.
    static func codeOnlyPrefix(of line: String) -> String {
        let chars = Array(line)
        var index = 0
        while index < chars.count {
            if chars[index] == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                return String(chars[0..<index])
            }
            guard let skip = skipNonCode(chars, from: index) else { index += 1; continue }
            index = max(skip, index + 1)
        }
        return line
    }

    /// The display property assigned on `line`, and the column just past its `=`.
    ///
    /// Requires a `.` before the name (it is a property on something) and rejects `==`, `!=`, `>=`,
    /// `<=` and the compound assignments, so a comparison never reads as an assignment.
    static func uikitDisplayAssignment(in line: String) -> (property: String, equalsColumn: Int)? {
        let chars = Array(line)
        for property in uikitDisplayProperties {
            var index = 0
            while index < chars.count {
                guard matches(chars, at: index, property), index > 0, chars[index - 1] == "." else {
                    index += 1
                    continue
                }
                let after = skipWhitespace(chars, from: index + property.count)
                guard after < chars.count, chars[after] == "=",
                      after + 1 >= chars.count || chars[after + 1] != "=",
                      after == 0 || !"=!<>+-*/?".contains(chars[after - 1]) else {
                    index += 1
                    continue
                }
                return (property, after + 1)
            }
        }
        return nil
    }

    /// Character range of the value assigned on line `index`, absorbing continuation lines.
    ///
    /// A line is absorbed when brackets are still unbalanced (a wrapped call) OR when the next line
    /// opens with a ternary or coalescing operator (a wrapped ternary, whose brackets balance on
    /// every line and which `logicalLines` therefore cannot join). That second case is not
    /// hypothetical: it is how this round's own fixed code formats `searchBar.placeholder`, so a
    /// rule blind to it would certify the exact shape it was written to guard.
    static func uikitAssignmentValueSpan(
        chars: [Character], lines: [String], starts: [Int], from index: Int, equalsColumn: Int
    ) -> (start: Int, end: Int) {
        let start = min(starts[index] + equalsColumn, chars.count)
        var last = index
        var depth = delimiterBalance(String(Array(lines[index]).dropFirst(equalsColumn)))
        while last + 1 < lines.count, last - index < maximumDeclarationLines {
            let next = lines[last + 1].trimmingCharacters(in: .whitespaces)
            let continues = depth > 0 || next.hasPrefix("?") || next.hasPrefix(":") || next.hasPrefix("??")
            guard continues else { break }
            last += 1
            depth += delimiterBalance(lines[last])
        }
        let end = last + 1 < starts.count ? starts[last + 1] : chars.count
        return (start, end)
    }

    // MARK: - Pure matchers

    /// Every `String(localized:…)` / `AttributedString(localized:…)` call in `source`, with whether it
    /// passes a `bundle:` argument.
    ///
    /// Spans the WHOLE call — head through matching close paren — so an argument written on a later
    /// line is still seen, and skips string literals while balancing parens so a `)` inside a message
    /// cannot end the span early.
    ///
    /// COMMENTS ARE SKIPPED, and that is not a nicety. The first run of this scan over the tree
    /// reported six "violations", every one of them a doc comment WARNING future authors never to
    /// call `String(localized:)` at that seam (the canonical signature serializer, the mesh payload
    /// summary, the connection inspector). Hard-failing CI on correct, careful documentation is how a
    /// wall gets switched off — the same false-positive lesson S3BoundaryTests learned at identifier
    /// boundaries (F12). Pure + testable.
    static func localizedCalls(in source: String) -> [LocalizedCallSite] {
        let chars = Array(source)
        var sites: [LocalizedCallSite] = []
        var index = 0
        var line = 1
        while index < chars.count {
            if let skip = skipNonCode(chars, from: index) {
                line += countNewlines(chars, from: index, to: skip)
                index = max(skip, index + 1)
                continue
            }
            if chars[index] == "\n" { line += 1 }
            guard chars[index] == "S", let openParen = localizedCallHead(chars, at: index) else {
                index += 1
                continue
            }
            let end = endOfCall(chars, openParen: openParen)
            let text = String(chars[index..<min(end, chars.count)])
            sites.append(LocalizedCallSite(
                path: "", line: line, text: text,
                passesBundle: resolvesAgainstModuleBundle(code(chars, from: index, to: end))
            ))
            line += countNewlines(chars, from: index, to: end)
            index = max(end, index + 1)
        }
        return sites
    }

    /// When `index` opens a string literal, a `//` comment, or a `/* */` comment, the index just past
    /// it; otherwise nil. One place decides what "not code" means, so every scan agrees.
    static func skipNonCode(_ chars: [Character], from index: Int) -> Int? {
        guard index < chars.count else { return nil }
        if chars[index] == "\"" { return readStringLiteral(chars, from: index).end }
        guard chars[index] == "/", index + 1 < chars.count else { return nil }
        if chars[index + 1] == "/" {
            var cursor = index + 2
            while cursor < chars.count, chars[cursor] != "\n" { cursor += 1 }
            return cursor
        }
        guard chars[index + 1] == "*" else { return nil }
        var depth = 0
        var cursor = index
        while cursor + 1 < chars.count {
            if chars[cursor] == "/", chars[cursor + 1] == "*" { depth += 1; cursor += 2; continue }
            if chars[cursor] == "*", chars[cursor + 1] == "/" {
                depth -= 1
                cursor += 2
                if depth <= 0 { return cursor }
                continue
            }
            cursor += 1
        }
        return chars.count
    }

    /// The `from..<to` span with comments removed (string literals kept — `bundle:` never hides in
    /// one). Used to decide `passesBundle`, so a `// no bundle: here` note inside a multi-line call
    /// cannot fake the argument's presence.
    static func code(_ chars: [Character], from: Int, to: Int) -> String {
        var text = ""
        var index = from
        let end = min(to, chars.count)
        while index < end {
            guard chars[index] == "/" || chars[index] == "\"" else {
                text.append(chars[index])
                index += 1
                continue
            }
            guard let skip = skipNonCode(chars, from: index) else {
                text.append(chars[index])
                index += 1
                continue
            }
            if chars[index] == "\"" { text += String(chars[index..<min(skip, end)]) }
            index = max(skip, index + 1)
        }
        return text
    }

    /// Newlines in `from..<to` — the incremental line counter for the scan above.
    static func countNewlines(_ chars: [Character], from: Int, to: Int) -> Int {
        var count = 0
        var index = max(from, 0)
        let end = min(to, chars.count)
        while index < end {
            if chars[index] == "\n" { count += 1 }
            index += 1
        }
        return count
    }

    /// The index of the `(` when a `String(localized:` head starts at `index`, else nil.
    ///
    /// Whitespace and newlines are tolerated between `String`, `(`, and `localized:` so a call split
    /// across lines at the head still matches. Matching on the bare suffix `String` is deliberate: it
    /// also catches `AttributedString(localized:)`, which carries the identical `Bundle.main` default
    /// and the identical silent failure.
    static func localizedCallHead(_ chars: [Character], at index: Int) -> Int? {
        guard matches(chars, at: index, "String") else { return nil }
        var cursor = skipWhitespace(chars, from: index + 6)
        guard cursor < chars.count, chars[cursor] == "(" else { return nil }
        let openParen = cursor
        cursor = skipWhitespace(chars, from: cursor + 1)
        guard matches(chars, at: cursor, "localized:") else { return nil }
        return openParen
    }

    /// Index just past the `)` matching `openParen`, skipping string literals and comments so a paren
    /// inside a message argument — or inside a `// note` between arguments — cannot unbalance the count.
    static func endOfCall(_ chars: [Character], openParen: Int) -> Int {
        var depth = 0
        var index = openParen
        while index < chars.count {
            let character = chars[index]
            if let skip = skipNonCode(chars, from: index) {
                index = max(skip, index + 1)
                continue
            }
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth <= 0 { return index + 1 }
            }
            index += 1
        }
        return chars.count
    }

    /// The string literals assigned to `value` in `source`, plus how many such assignments were seen.
    ///
    /// Only lines whose trimmed form starts with `value = ` contribute, so unrelated strings in the
    /// same file never enter the frozen vocabulary. Interpolations collapse to `{}`.
    static func signalValueLiterals(in source: String) -> (values: Set<String>, sites: Int) {
        var values: Set<String> = []
        var sites = 0
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("value = ") else { continue }
            sites += 1
            let chars = Array(trimmed)
            var index = 0
            while index < chars.count {
                guard chars[index] == "\"" else {
                    index += 1
                    continue
                }
                let literal = readStringLiteral(chars, from: index)
                values.insert(literal.text)
                index = max(literal.end, index + 1)
            }
        }
        return (values, sites)
    }

    /// The first string literal following `marker` in `source` (e.g. the identifier in
    /// `Locale(identifier: "en_US_POSIX")`), or nil when the marker is absent.
    ///
    /// Deliberately naive: it does not skip comments, so a comment quoting the same marker would
    /// shadow the real declaration. That is acceptable HERE because every caller compares the result
    /// against an expected literal — a shadowed match fails loudly with both values in the message,
    /// it never passes on the wrong string.
    static func firstLiteral(in source: String, after marker: String) -> String? {
        guard let markerRange = source.range(of: marker) else { return nil }
        let tail = Array(source[markerRange.upperBound...])
        guard let quote = tail.firstIndex(of: "\"") else { return nil }
        return readStringLiteral(tail, from: quote).text
    }

    /// The declared raw values of `enumName` in `source`, in declaration order, or nil when the enum
    /// is not found.
    ///
    /// Only lines at brace depth 1 — directly inside the enum body — count as case DECLARATIONS. That
    /// exclusion is load-bearing, not cosmetic: these enums are exactly the ones growing localized
    /// display properties right now, and a `switch self { case .thriving: … }` inside such a property
    /// is full of lines that begin with `case `. Reading those as declarations silently doubles the
    /// parsed list, which would make the part-C comparison fail for a reason that has nothing to do
    /// with the contract. ``isCaseDeclaration(_:)`` is the second, independent guard.
    ///
    /// Returning nil rather than `[]` for a missing enum is equally load-bearing: an empty list
    /// compares equal to another empty list, so a renamed enum would make the cross-process
    /// comparison pass while checking nothing.
    static func enumRawValues(in source: String, enumName: String) -> [String]? {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("enum \(enumName)") && $0.contains("{") }) else {
            return nil
        }
        var values: [String] = []
        var depth = 0
        for line in lines[start...] {
            depth += line.reduce(0) { $0 + ($1 == "{" ? 1 : 0) } - line.reduce(0) { $0 + ($1 == "}" ? 1 : 0) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if depth == 1, isCaseDeclaration(trimmed) { values.append(contentsOf: rawValues(fromCaseLine: trimmed)) }
            if depth <= 0 { break }
        }
        return values
    }

    /// True when `trimmed` declares enum cases rather than opening a `switch` arm.
    ///
    /// A declaration names an identifier (`case thriving = "Thriving"`); the switch arms that appear
    /// in these enums' display properties name a member or a value (`case .thriving:`,
    /// `case "ready for hard":`). Checking the first character after `case ` separates those two
    /// without a parser. A binding arm (`case let x`) also starts with a letter — the brace-depth
    /// guard in ``enumRawValues(in:enumName:)`` is what excludes it, which is why both checks exist.
    static func isCaseDeclaration(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("case ") else { return false }
        guard let first = trimmed.dropFirst("case ".count).drop(while: { $0 == " " }).first else { return false }
        return first.isLetter || first == "_"
    }

    /// The raw values declared by one `case` line: the literal after `=`, else the bare case names
    /// (which are their own raw values for a `String`-backed enum).
    static func rawValues(fromCaseLine line: String) -> [String] {
        let body = String(line.dropFirst("case ".count))
        guard let equals = body.firstIndex(of: "=") else {
            return body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let chars = Array(body[body.index(after: equals)...])
        guard let quote = chars.firstIndex(of: "\"") else {
            return [String(body[body.index(after: equals)...]).trimmingCharacters(in: .whitespaces)]
        }
        return [readStringLiteral(chars, from: quote).text]
    }

    /// Reads the Swift string literal whose opening quote is at `openQuote`.
    ///
    /// Returns the literal's text with every `\(…)` interpolation collapsed to `{}`, and the index just
    /// past the closing quote. Escapes are consumed as a pair so an escaped quote never ends the
    /// literal, and interpolations are skipped wholesale so the quotes INSIDE one (`\(n == 1 ? "" : "s")`)
    /// do not either.
    ///
    /// LIMIT: an interpolation containing a nested literal that itself interpolates is not modelled.
    /// No such literal exists in the scanned files, and if one appeared the scan would over-read and
    /// the frozen-set comparison would fail LOUDLY — never silently pass.
    static func readStringLiteral(_ chars: [Character], from openQuote: Int) -> (text: String, end: Int) {
        var text = ""
        var index = openQuote + 1
        while index < chars.count {
            let character = chars[index]
            if character == "\\", index + 1 < chars.count {
                if chars[index + 1] == "(" {
                    text += "{}"
                    index = skipInterpolation(chars, from: index + 1)
                    continue
                }
                text.append(chars[index + 1])
                index += 2
                continue
            }
            if character == "\"" { return (text, index + 1) }
            text.append(character)
            index += 1
        }
        return (text, chars.count)
    }

    /// Index just past the `)` closing the interpolation whose `(` is at `openParen`.
    ///
    /// Tracks nested parens and skips nested string literals inline rather than recursing (Power of 10
    /// rule 1), which is why the nested-interpolation limit above exists.
    static func skipInterpolation(_ chars: [Character], from openParen: Int) -> Int {
        var depth = 0
        var insideString = false
        var index = openParen
        while index < chars.count {
            let character = chars[index]
            if insideString {
                if character == "\\" { index += 2; continue }
                if character == "\"" { insideString = false }
                index += 1
                continue
            }
            if character == "\"" { insideString = true; index += 1; continue }
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth <= 0 { return index + 1 }
            }
            index += 1
        }
        return chars.count
    }

    /// True when a call's code text passes `bundle:` AND the value it passes is the MODULE bundle.
    ///
    /// `.module` and `Bundle.module` both count; `.main`, `Bundle.main` and anything else do not.
    /// The distinction is the entire point inside a package: `.main` resolves against the app's
    /// bundle, which never contains the module's catalog, so the string falls back to its English
    /// literal exactly as if no bundle had been passed. A wall that accepted any `bundle:` argument
    /// was checking that a keyword had been typed, not that the lookup was correct.
    static func resolvesAgainstModuleBundle(_ callText: String) -> Bool {
        guard let marker = callText.range(of: "bundle:") else { return false }
        let chars = Array(callText[marker.upperBound...])
        let end = endOfParameter(chars, from: 0)
        // `.whitespacesAndNewlines`, not `.whitespaces`: this runs over the RAW call text, and the
        // formatting these calls are actually written in puts the bundle argument on its own line.
        // `.whitespaces` leaves the trailing newline attached and every correct multi-line call
        // reads as a violation.
        let value = String(chars[0..<min(end, chars.count)]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value == ".module" || value == "Bundle.module"
    }

    /// True when `token` appears verbatim at `index`.
    static func matches(_ chars: [Character], at index: Int, _ token: String) -> Bool {
        let expected = Array(token)
        guard index >= 0, index + expected.count <= chars.count else { return false }
        for offset in 0..<expected.count where chars[index + offset] != expected[offset] { return false }
        return true
    }

    /// Index of the first non-whitespace character at or after `index`.
    static func skipWhitespace(_ chars: [Character], from index: Int) -> Int {
        var cursor = index
        while cursor < chars.count, chars[cursor].isWhitespace { cursor += 1 }
        return cursor
    }

    // MARK: - Discovery

    /// Scans every `.swift` file under ``packageSourceRoot`` for `String(localized:)` call sites.
    ///
    /// Returns the sites (paths made repo-relative for the failure report) and the number of files
    /// actually read, so the caller can enforce the floor rather than trusting an enumerator that may
    /// have silently returned nothing.
    static func scanPackageForLocalizedCalls() throws -> (sites: [LocalizedCallSite], filesScanned: Int) {
        let rootURL = RepoRoot.url(packageSourceRoot)
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
            Issue.record("Could not enumerate \(packageSourceRoot) — moved or renamed? The bundle:.module wall is unenforced.")
            return ([], 0)
        }
        var sites: [LocalizedCallSite] = []
        var filesScanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            filesScanned += 1
            let relativePath = url.path.replacingOccurrences(of: RepoRoot.url.path + "/", with: "")
            for site in localizedCalls(in: source) {
                sites.append(LocalizedCallSite(
                    path: relativePath, line: site.line, text: site.text, passesBundle: site.passesBundle
                ))
            }
        }
        return (sites, filesScanned)
    }
}
