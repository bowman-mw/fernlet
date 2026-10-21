// InputOutcomeFeedbackTests.swift
// FernletTests
//
// Tier B of the sounds-and-haptics pass (2026-10-20, `Docs/Handoff/Sounds-Haptics-Investigation.md`
// §4): the custom pickers and chips (B6), the water sheet's steps, "it worked, with a caveat" (B9),
// the waited-for results in Privacy & Data (B10), the journal's cap (B14), the photo results (B15),
// the passcode keypad (B24) and the Delete everything gate (B26).
//
// Everything that decides WHICH event plays is driven through the player's injected `perform` seam
// (UIKit never reports back what it played). Where a rule is about what must NEVER reach the player
// — a background restore, the silent duress wipe — no call exists to record, so the test pins the
// source instead and says so.
//
// Every level read goes to a private `UserDefaults` suite or to explicit preferences: the real key
// is process-global state shared by every suite running in parallel. The one helper that reads the
// real level (`FernletFeedback.play(_:)`) is checked against the same resolver it uses, so the
// expectation holds whatever level the test host's simulator carries.

import Foundation
import Testing
import FernletUI
@testable import FernletLockUI
@testable import Fernlet

/// Records what a ``FernletFeedback`` was asked to play.
@MainActor
private final class CueLog {
    /// Every cue that reached the player, in order.
    var played: [FernletFeedbackCue] = []
    /// ONE player for the log's life.
    lazy var feedback = FernletFeedback(perform: { [unowned self] in played.append($0) })

    var events: [FernletFeedbackEvent] { played.map(\.event) }
}

/// Records what a ``FernletAnnouncer`` was asked to say.
@MainActor
private final class SpokenLog {
    /// Every announcement, in order.
    var spoken: [FernletAnnouncement] = []
    /// ONE announcer for the log's life.
    lazy var announcer = FernletAnnouncer(post: { [unowned self] in spoken.append($0) })
}

@MainActor
@Suite struct InputOutcomeFeedbackTests {

    /// Every switch on, the level at All.
    private let all = FernletFeedbackPreferences(hapticsEnabled: true, soundsEnabled: false)

    /// Preferences at `level`, read from a fresh private suite through the one resolver.
    private func preferences(level: String) throws -> FernletFeedbackPreferences {
        let suite = try #require(UserDefaults(suiteName: "InputOutcomeFeedbackTests.\(UUID().uuidString)"))
        suite.set(level, forKey: FernletHapticsLevel.storageKey)
        return .resolved(in: suite)
    }

    /// What `FernletFeedback.play(_:)` — which reads the real level — would let through for `events`.
    private func expectedUnderTheRealLevel(_ events: [FernletFeedbackEvent]) -> [FernletFeedbackEvent] {
        let real = FernletFeedbackPreferences.resolved()
        return events.filter { real.allowsHaptic(for: $0) }
    }

    // MARK: B24, the passcode keypad

    /// Every key on every pad plays one identical tick — digits and backspace alike, whether the
    /// press changed the value or not (a digit past the length, a backspace on an empty field).
    @Test func theKeypadPlaysTheSameCueForEveryKey() throws {
        let tick = try #require(FernletFeedbackCue(event: .tick, preferences: all))
        #expect(tick.haptic == .selection && tick.sound == nil, "a selection tick, never a sound")
        let keys = (0...9).map(String.init) + [FernletNumericPad.backspaceKey]
        for maxLength in [4, 6] {
            for start in ["", "12", String(repeating: "7", count: maxLength)] {
                for key in keys {
                    let log = CueLog()
                    var value = start
                    FernletNumericPad.press(key, into: &value, maxLength: maxLength, feedback: log.feedback, preferences: all)
                    #expect(log.played == [tick], "key \(key) on a \(maxLength)-digit pad holding \(start.count) digits")
                }
            }
        }
    }

    /// A duress code feels exactly like the real one, key for key: the tick plays before the code
    /// goes anywhere, so nothing it does can depend on which code will match.
    @Test func aDuressCodeTypesExactlyLikeTheRealOne() {
        func type(_ code: String, editingWith backspaces: Int) -> (cues: [FernletFeedbackCue], value: String) {
            let log = CueLog()
            var value = ""
            for digit in code { FernletNumericPad.press(String(digit), into: &value, maxLength: 6, feedback: log.feedback, preferences: all) }
            for _ in 0..<backspaces {
                FernletNumericPad.press(FernletNumericPad.backspaceKey, into: &value, maxLength: 6, feedback: log.feedback, preferences: all)
            }
            return (log.played, value)
        }
        let real = type("135790", editingWith: 2)
        let duress = type("864208", editingWith: 2)
        #expect(real.cues == duress.cues && real.cues.count == 8)
        #expect(real.value == "1357" && duress.value == "8642", "the pad still edits the value as before")
    }

    /// Fewer drops the keypad's tick (a touch) and the pad still works; the one seam reads nothing
    /// but the key it was handed.
    @Test func fewerDropsTheKeypadTick() throws {
        let log = CueLog()
        var value = ""
        FernletNumericPad.press("4", into: &value, maxLength: 4, feedback: log.feedback, preferences: try preferences(level: "fewer"))
        #expect(log.played.isEmpty && value == "4")

        let source = try RepoRoot.source("FernletKit/Sources/FernletLockUI/FernletLockView.swift")
        #expect(source.contains("""
            private func handleKey(_ key: String) {
                    Self.press(key, into: &value, maxLength: maxLength)
                }
            """), "every pad's keys go through the one seam")
        #expect(source.contains("""
            ) {
                    (feedback ?? .system).play(.tick, preferences: preferences ?? .resolved())
                    if key == backspaceKey {
            """), "the tick is the seam's first, unconditional statement")
    }

    // MARK: B6, custom pickers and chips

    /// A real change ticks; a tap on the choice already made plays nothing; Fewer drops the tick
    /// and keeps the choice.
    @Test func fewerDropsTickAndAChoiceStillLands() throws {
        let log = CueLog()
        var meal: String? = "Lunch"
        log.feedback.select("Lunch", in: &meal, preferences: all)
        #expect(log.played.isEmpty && meal == "Lunch", "re-choosing the current chip is not a change")
        log.feedback.select(nil, in: &meal, preferences: all)
        log.feedback.select("Dinner", in: &meal, preferences: all)
        #expect(log.events == [.tick, .tick] && meal == "Dinner")

        let fewer = CueLog()
        var level = "beginner"
        fewer.feedback.select("advanced", in: &level, preferences: try preferences(level: "fewer"))
        #expect(fewer.played.isEmpty && level == "advanced")
        fewer.feedback.select("beginner", in: &level, preferences: try preferences(level: "off"))
        #expect(fewer.played.isEmpty && level == "beginner")
    }

    /// The chip style draws the chip being chosen AND the one being let go, so a tick there would
    /// play twice: the cue lives in each control's action, and the hub picker uses the same seam.
    @Test func chipsTickInTheirActionsNeverInTheStyle() throws {
        let components = try RepoRoot.source("FernletKit/Sources/FernletUI/FernletUIComponents.swift")
        let style = try #require(components.range(of: "public struct ChipButtonStyle: ButtonStyle {"))
        let styleEnd = try #require(components.range(of: "\n}\n", range: style.upperBound..<components.endIndex))
        #expect(!components[style.lowerBound..<styleEnd.upperBound].contains("FernletFeedback"))
        #expect(components.contains("FernletFeedback.system.select(section, in: &selection)"), "HubSectionPicker")
    }

    // MARK: The water sheet

    /// A tick per bottle, `limit` at 0 and at the cap, and the day's target is an ordinary bottle.
    @Test func waterSheetStepsTickAndLimitAtTheEnds() {
        #expect(WaterSheet.stepEvent(after: 5) == .tick)
        #expect(WaterSheet.stepEvent(after: 8) == .tick, "reaching a target is never felt as a goal")
        #expect(WaterSheet.stepEvent(after: 0) == .limit)
        #expect(WaterSheet.stepEvent(after: WaterSheet.maximumBottles) == .limit)
        #expect(WaterSheet.maximumBottles == 30)
        let log = CueLog()
        for after in [1, 0, 29, 30] { log.feedback.play(WaterSheet.stepEvent(after: after), preferences: all) }
        #expect(log.events == [.tick, .limit, .tick, .limit])
    }

    // MARK: B9 and B15, results with a caveat

    /// A thin label reading shows the retake tips beside its values, so it is a caveat; a confident
    /// one is done; a scan that read nothing is failed.
    @Test func labelScanResultsAreDoneCaveatOrFailed() {
        #expect(NutritionLabelCameraSheet.scanEvent(recognizedFieldCount: 6) == .done)
        #expect(NutritionLabelCameraSheet.scanEvent(recognizedFieldCount: NutritionLabelCameraSheet.confidentFieldCount) == .done)
        #expect(NutritionLabelCameraSheet.scanEvent(recognizedFieldCount: 1) == .caveat)
        #expect(NutritionLabelCameraSheet.scanEvent(recognizedFieldCount: nil) == .failed)
    }

    /// Open Food Facts: found is done, a failed lookup is failed, and "not found" is an answer, not
    /// an error, so it plays nothing.
    @Test func anOpenFoodFactsMissIsAnAnswerNotAnError() throws {
        let product = try OpenFoodFactsLookupTests.product(OpenFoodFactsLookupTests.nutellaJSON,
                                                           code: OpenFoodFactsLookupTests.nutellaCode)
        #expect(OpenFoodFactsLookupCard.feedbackEvent(for: .found(product)) == .done)
        #expect(OpenFoodFactsLookupCard.feedbackEvent(for: .notFound) == nil)
        #expect(OpenFoodFactsLookupCard.feedbackEvent(for: .notPermitted) == nil)
        #expect(OpenFoodFactsLookupCard.feedbackEvent(for: .failed(.network)) == .failed)
        #expect(OpenFoodFactsLookupCard.feedbackEvent(for: .failed(.rateLimited)) == .failed)
    }

    // MARK: B14, the journal's cap

    /// The cap is felt as `limit` and the banner is spoken; a long-reflection banner is spoken and
    /// felt as nothing.
    @Test func theJournalCapIsFeltAndItsBannerSpoken() {
        #expect(JournalPromptReason.limitReached.feedbackEvent == .limit)
        #expect(JournalPromptReason.longReflection.feedbackEvent == nil)

        let log = CueLog()
        let voice = SpokenLog()
        JournalPromptReason.limitReached.signalArrival(feedback: log.feedback, announcer: voice.announcer)
        #expect(log.events == expectedUnderTheRealLevel([.limit]))
        #expect(log.played.allSatisfy { $0.sound == nil }, "the journal never makes a sound")
        let banner = JournalPromptReason.limitReached
        #expect(voice.spoken.count == 1)
        #expect(voice.spoken.first?.kind == .status)
        #expect(voice.spoken.first.map { $0.message.contains(banner.title) && $0.message.contains(banner.message) } == true)

        // Both logs held for the call: each player captures its log `unowned`.
        let quiet = CueLog()
        let suggestion = SpokenLog()
        JournalPromptReason.longReflection.signalArrival(feedback: quiet.feedback, announcer: suggestion.announcer)
        #expect(quiet.played.isEmpty)
        #expect(suggestion.spoken.count == 1, "a long-reflection banner is spoken too")
    }

    /// Once per sheet: each of the three editors signals inside its `promptedReasons` gate, so a
    /// reason already shown never buzzes or speaks again while typing past the cap.
    @Test func theJournalCapIsFeltOncePerSheet() throws {
        let source = try RepoRoot.source("App/Fernlet/JournalView.swift")
        let gated = """
                guard promptedReasons.contains(reason) == false else { return }
                promptedReasons.insert(reason)
                showJournalPromptNotification(reason)
                reason.signalArrival()
        """
        #expect(source.components(separatedBy: gated).count == 4, "JournalSheet, JournalEntryEditorSheet, DayEditSheet")
        #expect(source.components(separatedBy: "signalArrival()").count == 4, "a signal outside the gate")
    }

    // MARK: B10, waited-for results in Privacy & Data

    /// A Retry restore the person waited on lands as done or failed; a failed photo-backup enable
    /// has already played its own `failed`, so the pass adds nothing.
    @Test func aRetryRestoreResultIsDoneOrFailed() {
        #expect(PrivacyDataSettingsView.retryRestoreEvent(enableRetried: nil, stillRetryable: false) == .done)
        #expect(PrivacyDataSettingsView.retryRestoreEvent(enableRetried: nil, stillRetryable: true) == .failed)
        #expect(PrivacyDataSettingsView.retryRestoreEvent(enableRetried: true, stillRetryable: false) == .done)
        #expect(PrivacyDataSettingsView.retryRestoreEvent(enableRetried: false, stillRetryable: true) == nil)
        #expect(PrivacyDataSettingsView.retryRestoreEvent(enableRetried: false, stillRetryable: false) == nil)
    }

    /// Background backups and restores are passive, so they play nothing. No player call exists on
    /// those paths to record, so this pins the source: the restore and upload funnels never name the
    /// player, and Privacy & Data plays only inside the actions the person started — never from a
    /// declarative trigger that a background pass changing the store's status could fire.
    @Test func aBackgroundRestorePlaysNothing() throws {
        let passive = [
            "App/Fernlet/SealedBackupCoordinator.swift", "App/Fernlet/OwnPhotoBackupCoordinator.swift",
            "App/Fernlet/FernletStoreLoader.swift", "App/Fernlet/SealedBackupV2Engine.swift",
            "App/Fernlet/SealedBackupV2Engine+Restore.swift", "App/Fernlet/SealedBackupV2Engine+Export.swift",
            "App/Fernlet/SealedBackupV2Engine+Commit.swift", "App/Fernlet/SealedBackupService.swift",
            "App/Fernlet/SealedPhotoBackupService.swift",
        ]
        for path in passive {
            let source = try RepoRoot.source(path)
            #expect(!source.contains("FernletFeedback") && !source.contains("fernletFeedback"), "\(path) plays a cue")
        }
        let store = try RepoRoot.source("App/Fernlet/FernletStore.swift")
        for funnel in ["func restoreSealedBackupsIfNeeded(", "func retrySealedBackups("] {
            #expect(!(try methodBody(funnel, in: store)).contains("FernletFeedback"), "\(funnel) plays a cue")
        }

        let page = try RepoRoot.source("App/Fernlet/PrivacyDataSettingsView.swift")
        #expect(!page.contains(".fernletFeedback("), "a state-keyed cue would fire on a background pass")
        let allowed: Set<String> = ["setOperationError", "retrySealedRestore", "resolveEscrowConflict", "confirmCloudDataDeleted"]
        let players = try enclosingFunctions(of: "FernletFeedback.system.play(", in: page)
        #expect(!players.isEmpty && Set(players).isSubset(of: allowed), "Privacy & Data plays from \(players)")
    }

    // MARK: B10 and B26, Delete everything

    /// The wipe's outcome is felt as its alert goes up — done or failed — through the UI flow.
    @Test func deleteEverythingFeelsItsOutcome() {
        let clean = FernletStore.DeleteAllOutcome()
        let partial = FernletStore.DeleteAllOutcome(incompleteStores: ["iCloud"])
        #expect(DeleteEverythingFlow.outcomeEvent(clean) == .done)
        #expect(DeleteEverythingFlow.outcomeEvent(partial) == .failed)

        let log = CueLog()
        let flow = DeleteEverythingFlow(feedback: log.feedback)
        flow.land(clean)
        #expect(flow.showSuccess && flow.failure == nil)
        flow.land(partial)
        #expect(flow.failure == partial)
        #expect(log.events == expectedUnderTheRealLevel([.done, .failed]))
    }

    /// The silent duress wipe reaches the same store funnel through `duressPurgeHook`, never through
    /// the flow, so the funnel and the hook must never name the player.
    @Test func theDuressWipeStaysSilent() throws {
        let store = try RepoRoot.source("App/Fernlet/FernletStore.swift")
        #expect(!(try methodBody("func deleteAllData(includingHealthKitSamples", in: store)).contains("FernletFeedback"))
        let content = try RepoRoot.source("App/Fernlet/ContentView.swift")
        let hook = try #require(content.range(of: "lockService.installDuressPurgeHook {"))
        let hookEnd = try #require(content.range(of: "\n        }\n", range: hook.upperBound..<content.endIndex))
        #expect(!content[hook.lowerBound..<hookEnd.upperBound].contains("eedback"))
    }

    /// The typed gate's arming is felt once per sheet, as a caveat, and never on disarming.
    @Test func theTypedGateArmsOnce() {
        #expect(DeleteEverythingSheet.armingEvent(isArmed: true, alreadyFelt: false) == .caveat)
        #expect(DeleteEverythingSheet.armingEvent(isArmed: true, alreadyFelt: true) == nil)
        #expect(DeleteEverythingSheet.armingEvent(isArmed: false, alreadyFelt: false) == nil)
        #expect(FernletFeedbackEvent.caveat.haptic == .warning)
    }

    // MARK: Source helpers

    /// The body of the method `declaration` opens in a type at four-space indent, up to its closing
    /// brace.
    private func methodBody(_ declaration: String, in source: String) throws -> Substring {
        let start = try #require(source.range(of: declaration), "\(declaration) moved")
        let end = try #require(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        return source[start.lowerBound..<end.upperBound]
    }

    /// The name of the nearest `func` above each occurrence of `token`.
    private func enclosingFunctions(of token: String, in source: String) throws -> [String] {
        let funcName = try Regex(#"func (\w+)\("#)
        var names: [String] = []
        var cursor = source.startIndex
        while let hit = source.range(of: token, range: cursor..<source.endIndex) {
            let before = source[source.startIndex..<hit.lowerBound]
            let name = before.matches(of: funcName).last.map { String(before[$0.range]) } ?? "?"
            names.append(name.replacingOccurrences(of: "func ", with: "").replacingOccurrences(of: "(", with: ""))
            cursor = hit.upperBound
        }
        return names
    }
}
