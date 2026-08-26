import Foundation
import Testing
@testable import Fernlet

/// Tail #6 — App Intents. The Siri/Spotlight actions themselves run out-of-process, but the foreground
/// intents' deep-link (which sheet the app should open when it becomes active) is a plain persisted
/// hand-off worth pinning: it must be honored exactly once, and only for a short window.
///
/// The suite also carries the **App Shortcut registration wall** (T2-9). Every way an `AppShortcut`
/// can be wrong — one too many for the system's ten-per-provider cap, a phrase that omits
/// `\(.applicationName)` — fails at *runtime*, silently, by simply not registering. Nothing about it
/// fails the build, and nothing about it is visible without a device and Siri. So the registrations
/// are pinned here: the live count from `FernletShortcuts.appShortcuts`, and a grep-wall over the
/// source for the phrase and intent shapes that `AppShortcut`'s opaque public surface hides.
///
/// A `final class` (not a struct) so `deinit` can act as teardown: the token is backed by the host's real
/// `UserDefaults.standard`, so a token left behind by a failing test would otherwise leak into a later
/// test or run. `init`/`deinit` drain it before and after every test to keep the suite hermetic.
@MainActor
final class AppIntentsTests {
    init() { _ = PendingIntentSheet.consume() }
    deinit { _ = PendingIntentSheet.consume() }  // nonisolated static func — safe from deinit

    @Test func pendingIntentSheetRoundTripsAndIsConsumedOnce() {
        PendingIntentSheet.request(.meal)
        #expect(PendingIntentSheet.consume() == .meal)
        // Consumed once — a second read finds nothing (so a stale request can't reopen the sheet later).
        #expect(PendingIntentSheet.consume() == nil)

        PendingIntentSheet.request(.journal)
        #expect(PendingIntentSheet.consume() == .journal)
        #expect(PendingIntentSheet.consume() == nil)

        PendingIntentSheet.request(.trainerPrepareSummary)
        #expect(PendingIntentSheet.consume() == .trainerPrepareSummary)
        PendingIntentSheet.request(.trainerCopySummaryAndPrompt)
        #expect(PendingIntentSheet.consume() == .trainerCopySummaryAndPrompt)
        PendingIntentSheet.request(.trainerPastePlan)
        #expect(PendingIntentSheet.consume() == .trainerPastePlan)
    }

    /// A token stranded past the expiry window (onboarding still up, app killed under a covering sheet,
    /// …) must be discarded rather than misfiring arbitrarily far in the future. Against the old
    /// timestamp-less token this would have returned `.meal` regardless of age.
    @Test func expiredPendingIntentSheetIsDiscarded() {
        // Just past the 120s window.
        PendingIntentSheet.request(.meal, createdAt: Date().addingTimeInterval(-125))
        #expect(PendingIntentSheet.consume() == nil)
        // Discarding still clears the slot, so a later request isn't shadowed by the stale one.
        #expect(PendingIntentSheet.consume() == nil)

        // A token comfortably within the window is still honored.
        PendingIntentSheet.request(.journal, createdAt: Date().addingTimeInterval(-30))
        #expect(PendingIntentSheet.consume() == .journal)
    }

    // MARK: - App Shortcut registration wall (T2-9)

    /// `AppShortcutsProvider` is capped at ten shortcuts; the eleventh is dropped at runtime with no
    /// build error and no in-app symptom. Pin both the live count and the source, so neither an
    /// eleventh registration nor a registration that silently stopped compiling into the provider
    /// can ship unnoticed.
    @Test func appShortcutRegistrationsMatchTheSourceAndStayUnderTheCap() throws {
        let registered = FernletShortcuts.appShortcuts.count
        #expect(registered == Self.expectedIntentNames.count)
        #expect(registered <= Self.systemShortcutCap,
                "AppShortcutsProvider caps at \(Self.systemShortcutCap); extras are dropped at runtime")
        let source = try RepoRoot.source(Self.shortcutsSourcePath)
        let declared = source.components(separatedBy: "AppShortcut(").count - 1
        #expect(declared == registered,
                "\(declared) AppShortcut( in the source but \(registered) registered")
    }

    /// Cooking/workout controls are consolidated at the provider boundary. The original live-activity
    /// types remain discoverable, but promoting either original type again would spend a reserved slot.
    /// Nothing here may write sealed journal / cycle / intimacy data: a background write would land
    /// outside the app-lock gate, which is a security decision rather than an accessibility one.
    @Test func promotedIntentListIsExactlyTheRebalancedAllocation() throws {
        let source = try RepoRoot.source(Self.shortcutsSourcePath)
        let names = Self.registeredIntentNames(in: source)
        #expect(names.sorted() == Self.expectedIntentNames.sorted(),
                "provider intents changed: \(names)")
    }

    /// Apple rejects any `AppShortcut` phrase that does not interpolate `\(.applicationName)`, and a
    /// rejected phrase is simply never registered — no build error, no runtime complaint.
    @Test func everyAppShortcutPhraseInterpolatesTheApplicationName() throws {
        let source = try RepoRoot.source(Self.shortcutsSourcePath)
        let phrases = Self.phraseLiterals(in: source)
        // Vacuous-pass guard (see RepoRoot): a parser that matched nothing would pass silently.
        #expect(phrases.count >= 2 * Self.expectedIntentNames.count,
                "phrase scan found only \(phrases.count) literals — the parser lost the arrays")
        for phrase in phrases {
            #expect(phrase.contains("\\(.applicationName)"), "phrase omits the app name: \(phrase)")
        }
    }

    /// The IDE does not synchronize AppShortcuts.xcstrings, so every source phrase must be mirrored
    /// by hand using the catalog's `${applicationName}` placeholder spelling.
    @Test func appShortcutPhraseCatalogMatchesTheProvider() throws {
        let source = try RepoRoot.source(Self.shortcutsSourcePath)
        let expected = Set(Self.phraseLiterals(in: source).map {
            $0.replacingOccurrences(of: "\\(.applicationName)", with: "${applicationName}")
        })
        let data = try Data(contentsOf: RepoRoot.url(Self.shortcutsCatalogPath))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: Any])
        #expect(Set(strings.keys) == expected,
                "AppShortcuts.xcstrings must contain exactly the provider's phrases")
    }

    /// `LogWaterIntent` gained a `bottles` parameter so a Voice Control or Shortcuts user can log a
    /// glass count in one action. The default is the load-bearing half: shortcuts built against the
    /// old unparameterized intent must keep logging exactly one bottle.
    @Test func logWaterIntentStillDefaultsToASingleBottle() {
        #expect(LogWaterIntent().bottles == 1)
        #expect(LogWaterIntent.maxBottlesPerRun == 10)
    }

    // MARK: - Intent input + dialog wall (review #15 / #25)

    /// The range Shortcuts DECLARES and the range `perform()` ENFORCES must be the same numbers.
    ///
    /// They cannot be one constant. `inclusiveRange:` is declared
    /// `_const IntentParameter<Value>.InclusiveRange<…>?`, so only a literal is accepted there —
    /// `swiftc` rejects `Self.maxBottlesPerRun` with `expect a compile-time constant literal`. So
    /// the literal is read back out of the source and pinned to the constants instead. A drift is
    /// otherwise invisible: Shortcuts would keep offering a stepper that runs past what the intent
    /// honours, and the bottles above the cap would be silently dropped with a cheerful dialog.
    @Test func theDeclaredBottleRangeMatchesTheEnforcedCap() throws {
        let source = try RepoRoot.source(Self.intentsSourcePath)
        let range = try #require(Self.inclusiveRangeLiteral(in: source),
                                 "no `inclusiveRange: (lo, hi)` literal found — the parser lost it")
        #expect(range.low == LogWaterIntent.minBottlesPerRun,
                "inclusiveRange floor \(range.low) ≠ minBottlesPerRun \(LogWaterIntent.minBottlesPerRun)")
        #expect(range.high == LogWaterIntent.maxBottlesPerRun,
                "inclusiveRange ceiling \(range.high) ≠ maxBottlesPerRun \(LogWaterIntent.maxBottlesPerRun)")
    }

    /// `bottles` arrives from outside the app, and `0..<bottles` is a **trap** on a negative
    /// (`Range` requires `lowerBound <= upperBound`) — not an empty loop. Both loop sites must be
    /// preceded by an entry guard rather than trusting `inclusiveRange`, which is only a resolution
    /// hint. Reverting either guard leaves a clean build and a latent crash reachable from Siri.
    @Test func bothBottleLoopsAreGuardedAtEntry() throws {
        let source = try RepoRoot.source(Self.intentsSourcePath)
        #expect(source.contains("guard bottles >= Self.minBottlesPerRun else {"),
                "perform() no longer validates the resolved bottle count at entry")
        #expect(source.contains("guard bottles > 0 else { return }"),
                "bumpWidgetSnapshot() no longer guards its 0..<bottles loop at entry")
        #expect(!source.contains("for _ in 0..<bottles"),
                "an unclamped `0..<bottles` loop is back — a negative count traps at runtime")
    }

    /// The water confirmation must be a catalog PLURAL RULE, not an `if` in Swift.
    ///
    /// A `bottles > 1` fork in Swift offers exactly the two forms English needs and freezes every
    /// language with more (Polish three, Arabic six) into agreeing in the wrong number — with a
    /// clean build and nothing else failing. `xcstringstool sync` adds keys but never INVENTS a
    /// plural rule, so this is the only thing that would notice the block being dropped.
    @Test func theWaterConfirmationCarriesPluralVariations() throws {
        let data = try Data(contentsOf: RepoRoot.url(Self.appCatalogPath))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = json?["strings"] as? [String: Any] ?? [:]
        #expect(!strings.isEmpty, "\(Self.appCatalogPath) parsed to zero keys — the catalog broke")
        let entry = try #require(strings[Self.waterDialogKey] as? [String: Any],
                                 "\(Self.waterDialogKey) is missing from \(Self.appCatalogPath)")
        let english = (entry["localizations"] as? [String: Any])?["en"] as? [String: Any]
        let plural = (english?["variations"] as? [String: Any])?["plural"] as? [String: Any]
        let forms = Set(plural?.keys ?? [:].keys)
        #expect(forms.contains("one") && forms.contains("other"),
                "\(Self.waterDialogKey) lost its one/other plural variation; forms = \(forms.sorted())")
        // The one-bottle form keeps the pre-parameter wording, so an old shortcut sounds unchanged.
        let one = ((plural?["one"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        #expect(one == "Logged a bottle of water.")
    }

    /// Both guided-workout intents must REPORT what happened, not return a bare success.
    ///
    /// They are Siri phrases as well as Lock Screen buttons. A button can afford a silent no-op —
    /// the card the user is looking at simply does not move — but Siri plays the success chime for
    /// `.result()`, so "skip rest" spoken with no workout running was indistinguishable from a real
    /// skip. Reverting to `-> some IntentResult` + `return .result()` fails here.
    @Test func guidedWorkoutIntentsSpeakTheirOutcome() throws {
        let source = try RepoRoot.source(Self.guidedIntentsSourcePath)
        #expect(source.components(separatedBy: "some IntentResult & ProvidesDialog").count - 1 == 2,
                "both guided-workout perform()s must return ProvidesDialog")
        #expect(!source.contains("return .result()"),
                "a guided-workout intent is back to reporting a no-op as a bare success")
        // The failure paths must SAY what happened, not merely decline.
        for phrase in Self.guidedNoOpDialogFragments {
            #expect(source.contains(phrase), "no-op dialog missing: \(phrase)")
        }
    }

    // MARK: - Registration wall fixtures

    /// The system's per-provider `AppShortcut` limit.
    private static let systemShortcutCap = 10

    private static let shortcutsSourcePath = "App/Fernlet/FernletShortcuts.swift"

    private static let shortcutsCatalogPath = "App/Fernlet/AppShortcuts.xcstrings"

    private static let intentsSourcePath = "App/Fernlet/FernletAppIntents.swift"

    private static let guidedIntentsSourcePath =
        "App/FernletWidgets/GuidedWorkoutLiveActivityIntents.swift"

    private static let appCatalogPath = "App/Fernlet/Localizable.xcstrings"

    /// The plural-ruled catalog key behind `LogWaterIntent.loggedDialog(bottles:)`.
    private static let waterDialogKey = "intent.water.logged"

    /// The no-op lines the guided-workout intents must speak. Each names WHAT happened rather than
    /// just declining, which is the half a bare `.result()` could never convey.
    private static let guidedNoOpDialogFragments = [
        "No workout is running, so there's no set to finish.",
        "No workout is running, so there's no rest to skip.",
        "You're resting right now, so there's no set to finish yet.",
        "You're not resting right now, so there's nothing to skip.",
    ]

    /// The `(low, high)` numbers from the first `inclusiveRange: (…)` literal in a source file.
    /// Returns `nil` rather than a default if the shape moved, so the caller fails loudly instead of
    /// comparing against invented numbers.
    private static func inclusiveRangeLiteral(in source: String) -> (low: Int, high: Int)? {
        guard let after = source.components(separatedBy: "inclusiveRange: (").dropFirst().first,
              let close = after.firstIndex(of: ")") else { return nil }
        let parts = after[after.startIndex..<close].split(separator: ",")
        guard parts.count == 2,
              let low = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let high = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (low, high)
    }

    /// Every intent the provider is allowed to surface, as written at the `intent:` label.
    private static let expectedIntentNames = [
        "LogWaterIntent", "LogMealIntent", "OpenJournalIntent",
        "ControlCookingIntent", "ControlWorkoutIntent",
        "ExportRecipeIntent", "ImportRecipeIntent",
        "ExportWorkoutPlanIntent", "ImportWorkoutPlanIntent"
    ]

    /// The type name from each `intent: SomeIntent(),` line. `AppShortcut` exposes no stored
    /// properties, so the source is the only place the registered intents are readable.
    private static func registeredIntentNames(in source: String) -> [String] {
        var names: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("intent: "), trimmed.hasSuffix("(),") else { continue }
            names.append(String(trimmed.dropFirst(8).dropLast(3)))
        }
        return names
    }

    /// Every string literal inside a `phrases: [ … ]` array, with the surrounding quotes stripped.
    /// Line-format agnostic on purpose — the registrations are packed onto shared lines to stay
    /// under the 60-line ceiling, and a parser that assumed one phrase per line would silently
    /// stop finding them.
    private static func phraseLiterals(in source: String) -> [String] {
        var literals: [String] = []
        // Bounded by the number of `phrases:` arrays in one file.
        for chunk in source.components(separatedBy: "phrases: [").dropFirst() {
            guard let close = chunk.range(of: "]") else { continue }
            literals.append(contentsOf: quotedRuns(in: String(chunk[chunk.startIndex..<close.lowerBound])))
        }
        return literals
    }

    /// The contents of every `"…"` run in a fragment. Splitting on the quote character makes the
    /// odd-indexed components exactly the quoted runs; no phrase contains an escaped quote.
    private static func quotedRuns(in fragment: String) -> [String] {
        var runs: [String] = []
        for (index, piece) in fragment.components(separatedBy: "\"").enumerated() where index % 2 == 1 {
            runs.append(piece)
        }
        return runs
    }
}
