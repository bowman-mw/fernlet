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

import Foundation
import Testing
import FernletDomainModel
import FernletFoundation
import LocalPersistence
import PrivateHealthStore
@testable import Fernlet

/// Grep-wall enforcing the token/display separation that makes localization safe.
///
/// Four independent enforcement areas, each with its own planted-token fixtures:
/// - ``everyPackageLocalizedStringPassesModuleBundle()`` — the `bundle: .module` rule inside
///   `FernletKit/Sources` (A).
/// - the `frozen…Tokens` tests — literal raw values of every enum whose tokens are persisted,
///   sealed, signed, or fed to a prompt (B).
/// - ``widgetSharedModelsMatchTheAppSideCrossProcessContract()`` — the app ↔ widget-extension
///   contract, which no type system spans (C).
/// - ``derivedSignalValuesAreTheFrozenLogicVocabulary()`` and its gate pins — the derived-signal
///   phrases that six call sites string-compare (D).
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
        /// Whether the call passes a `bundle:` argument at all (the wall only asks that the author
        /// made a deliberate choice; `.module` is the only meaningful value inside a package).
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
                path: "", line: line, text: text, passesBundle: code(chars, from: index, to: end).contains("bundle:")
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
