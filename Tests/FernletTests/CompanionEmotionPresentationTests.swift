import Foundation
import SwiftUI
import Testing
import FernletDomainModel
import FernletScoring
@testable import Fernlet

/// The companion's emotions from the app's side (owner decision 2026-09-24): the faces the renderer
/// resolves, the spoken status, the store's inputs, the widget snapshot's emotion timeline, and the
/// privacy rules — never persisted, never synced, never on the friend wire.
@MainActor
struct CompanionEmotionPresentationTests {

    /// The emotions a gentle day (tagged hard or tired, or a trend that needs gentleness) can show.
    static let gentleEmotions: Set<CompanionEmotion> = [.sad, .tired, .sleepy, .comforted]

    // MARK: - Faces

    /// End to end through the renderer: over the engine's whole input grid, every face the Home
    /// companion can draw on a gentle or unwell day — settled pose included — is never cheerful.
    /// This is the owner's "having a happy companion on a hard day seems wrong", as a test.
    @Test func noGentleOrUnwellDayEverDrawsACheerfulFace() {
        var checked = 0
        for inputs in CompanionEmotionEngineTests.grid() where inputs.isGentleDay || inputs.state == .sick {
            for time in CompanionEmotionEngineTests.gridTimes {
                let emotion = CompanionEmotionEngine.emotion(for: inputs, at: time, calendar: CompanionEmotionEngineTests.calendar)
                for settled in [false, true] {
                    let face = CompanionExpression.resolve(state: inputs.state, emotion: emotion, settled: settled,
                                                     gentleDay: inputs.isGentleDay)
                    #expect(!face.isHappyLooking, "a cheerful face (\(face)) on a gentle/unwell day: \(inputs) at \(time)")
                    checked += 1
                }
            }
        }
        #expect(checked > 10_000, "the gentle-day slice of the grid shrank to \(checked) faces")
    }

    /// With no emotion the companion draws exactly its old state face, so every decorative render
    /// (launch, previews, friends' avatars — none of which passes an emotion) is unchanged.
    @Test func noEmotionDrawsTheOldStateFace() {
        for state in [CompanionState.thriving, .okay, .tired, .resting, .sick] {
            let face = CompanionExpression.resolve(state: state, emotion: nil, settled: false, gentleDay: false)
            let lowEnergy = state == .tired || state == .resting || state == .sick
            #expect(face.leftEye == (lowEnergy ? .drooped : .round) && face.rightEye == face.leftEye)
            #expect(face.mouth == .state && face.blush == 0 && !face.sympatheticBrows)
        }
    }

    /// The accents that were flags keep their looks as emotions, and the settled pose keeps its
    /// droopy-happy face on an ordinary day.
    @Test func theOldAccentsKeepTheirLooks() {
        let calm = CompanionExpression.resolve(state: .okay, emotion: .calm, settled: false, gentleDay: false)
        #expect(calm.leftEye == .happyArc && calm.mouth == .state && calm.blush == 0.38)
        let frazzled = CompanionExpression.resolve(state: .okay, emotion: .frazzled, settled: false, gentleDay: false)
        #expect(frazzled == CompanionExpression.stateFace(.okay), "frazzled draws the state face plus its own accents")
        let settled = CompanionExpression.resolve(state: .okay, emotion: nil, settled: true, gentleDay: false)
        #expect(settled.leftEye == .happyArc && settled.mouth == .settledLens && settled.blush == 0.42)
    }

    /// Every emotion draws its own face (hungry and thirsty share one and differ by motif).
    @Test func everyEmotionHasItsOwnFace() {
        let distinct: [CompanionEmotion] = [.happy, .playful, .loved, .calm, .comforted, .sad, .tired, .sleepy, .hungry]
        let faces = distinct.map { CompanionExpression.resolve(state: .okay, emotion: $0, settled: false, gentleDay: false) }
        for (index, face) in faces.enumerated() {
            let twins = faces.indices.filter { faces[$0] == face && $0 != index }.map { distinct[$0] }
            #expect(twins.isEmpty, "\(distinct[index]) draws the same face as \(twins)")
        }
        #expect(CompanionExpression.resolve(state: .okay, emotion: .sad, settled: false, gentleDay: true).sympatheticBrows,
                "sad is sad WITH the person: brows lifted in sympathy")
    }

    // MARK: - The spoken status

    @Test func theSpokenStatusReadsTheStateThenTheFeeling() {
        #expect(CompanionEmotion.accessibilityValue(state: .okay, emotion: .sleepy) == "Okay, feeling sleepy")
        #expect(CompanionEmotion.accessibilityValue(state: .tired, emotion: .hungry) == "Tired, feeling hungry")
        #expect(CompanionEmotion.accessibilityValue(state: .thriving, emotion: nil) == "Thriving")
        for emotion in CompanionEmotion.allCases {
            let value = CompanionEmotion.accessibilityValue(state: .okay, emotion: emotion)
            #expect(value.hasPrefix("Okay, ") && value.hasSuffix(emotion.feelingPhrase), "\(emotion) reads \"\(value)\"")
        }
    }

    // MARK: - The store's inputs

    /// A fixed test day, and an instant on it.
    static let testDay = Date(timeIntervalSince1970: 1_790_000_000)

    static func onTestDay(hour: Int, minute: Int = 0) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: testDay) ?? testDay
    }

    @Test func aDayTaggedHardMakesTheHomeCompanionSad() {
        let store = makeTestStore(date: Self.testDay)
        store.addJournal(text: "A rough one", tag: .hard)
        let noon = Self.onTestDay(hour: 12)
        let emotion = store.companionEmotion(at: noon, bodySignal: nil, playfulUntil: nil,
                                             appetiteCuesEnabled: true, sleepWindow: .standard)
        #expect(emotion == .sad)
        let petted = store.companionEmotion(at: noon, bodySignal: nil, playfulUntil: noon.addingTimeInterval(60),
                                            appetiteCuesEnabled: true, sleepWindow: .standard)
        #expect(petted == .comforted, "a pet on a hard day comforts; it never cheers")
    }

    @Test func theCueSwitchSilencesHungerAndThirst() {
        let store = makeTestStore(date: Self.testDay)
        let afternoon = Self.onTestDay(hour: 15)
        let cuesOn = store.companionEmotion(at: afternoon, bodySignal: nil, playfulUntil: nil,
                                            appetiteCuesEnabled: true, sleepWindow: .standard)
        let cuesOff = store.companionEmotion(at: afternoon, bodySignal: nil, playfulUntil: nil,
                                             appetiteCuesEnabled: false, sleepWindow: .standard)
        #expect(cuesOn == .hungry, "no meal logged by mid-afternoon: hungry (got \(String(describing: cuesOn)))")
        #expect(cuesOff != .hungry && cuesOff != .thirsty, "cues off, yet \(String(describing: cuesOff))")
        store.setSick(true, on: store.todayKey)
        let unwell = store.companionEmotion(at: afternoon, bodySignal: nil, playfulUntil: nil,
                                            appetiteCuesEnabled: true, sleepWindow: .standard)
        #expect(unwell == nil, "unwell outranks every feeling")
    }

    @Test func preferencesDefaultToCuesOnAndTheStandardNight() throws {
        let suite = "CompanionEmotionPresentationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(CompanionEmotionPreferences.appetiteCuesEnabled(in: defaults))
        #expect(CompanionEmotionPreferences.sleepWindow(in: defaults) == .standard)
        defaults.set(false, forKey: CompanionEmotionPreferences.appetiteCuesKey)
        defaults.set(23 * 60, forKey: CompanionEmotionPreferences.bedtimeMinuteKey)
        defaults.set(6 * 60 + 15, forKey: CompanionEmotionPreferences.wakeMinuteKey)
        #expect(!CompanionEmotionPreferences.appetiteCuesEnabled(in: defaults))
        #expect(CompanionEmotionPreferences.sleepWindow(in: defaults) == CompanionSleepWindow(bedtimeMinute: 1_380, wakeMinute: 375))
    }

    // MARK: - The widget snapshot

    /// The published timeline covers the store's own day, carries only the six publishable tokens,
    /// includes the bedtime transition, and survives the app-group file's round trip exactly.
    @Test func theWidgetTimelineIsPublishableAndRoundTrips() throws {
        let store = makeTestStore(date: Self.testDay)
        store.addJournal(text: "A rough one", tag: .hard)
        let snapshot = store.currentWidgetSnapshot()
        let timeline = try #require(snapshot.companionEmotionTimeline)
        let publishable = Set(LocalizationBoundaryTests.frozenWidgetEmotionRawValues)
        #expect(timeline.allSatisfy { $0.emotionRaw.map(publishable.contains) ?? true }, "an app-only token reached the widget: \(timeline)")
        #expect(timeline.contains { $0.emotionRaw == "sad" }, "the hard day never reached the widget: \(timeline)")
        #expect(timeline.contains { $0.at == Self.onTestDay(hour: 22, minute: 30) && $0.emotionRaw == "sleepy" },
                "no moment at bedtime, so the widget would never turn sleepy with the app closed: \(timeline)")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompanionEmotionPresentationTests-\(UUID().uuidString)", isDirectory: true)
        let files = WidgetSnapshotFileStore(directory: directory)
        #expect(files.write(snapshot))
        let readBack = try #require(files.read())
        #expect(readBack.companionEmotionTimeline == snapshot.companionEmotionTimeline,
                "the timeline changed crossing the app-group file")
        #expect(readBack.contentEquals(snapshot), "a round trip must not look like a change to the refresh diff")
    }

    /// Two snapshots of an unchanged day, built at different times, are content-equal — so the
    /// background refresh never reloads the widget for the clock alone.
    @Test func anUnchangedDayPublishesTheSameEmotionTimeline() {
        let store = makeTestStore(date: Self.testDay)
        store.addJournal(text: "A quiet one", tag: .quiet)
        let first = store.currentWidgetSnapshot()
        let second = store.currentWidgetSnapshot()
        #expect(first.companionEmotionTimeline == second.companionEmotionTimeline)
        #expect(first.contentEquals(second))
    }

    /// The widget's half, read off disk because the extension links no FernletKit product and has no
    /// test target: the provider adds a timeline entry at every emotion transition, its lookup is the
    /// app's day-scoped rule character for character, and the Lock Screen keeps the state face (the
    /// owner's answer, 2026-09-24: "State face only").
    @Test func theWidgetFollowsTheAppsTimelineRulesAndTheLockScreenDecision() throws {
        let bundle = try RepoRoot.source("App/FernletWidgets/FernletWidgetsBundle.swift")
        let models = try RepoRoot.source("App/FernletWidgets/WidgetSharedModels.swift")
        let engine = try RepoRoot.source("FernletKit/Sources/FernletScoring/CompanionEmotionEngine.swift")
        let provider = try #require(CompanionEmotionPrivacyTests.body(of: "func getTimeline(", in: bundle), "getTimeline is gone")
        #expect(provider.contains("WidgetEmotionTimeline.transitionDates(in: snapshot?.companionEmotionTimeline"),
                "the provider no longer asks for the emotion transitions — a sleepy face would wait for the next reload")
        #expect(provider.contains("entries += transitions.map"), "the transitions no longer become timeline entries")
        let rule = "$0.at <= date && calendar.startOfDay(for: $0.at) == day"
        let widgetLookup = try #require(CompanionEmotionPrivacyTests.body(of: "static func emotion(in moments:", in: models))
        let appLookup = try #require(CompanionEmotionPrivacyTests.body(of: "public static func emotion(in timeline:", in: engine))
        #expect(widgetLookup.contains(rule) && appLookup.contains(rule),
                "the widget's lookup and the app's twin no longer scope a moment to its own day the same way")
        #expect(bundle.contains("static let lockScreenShowsEmotion = false"),
                "the Lock Screen now draws feelings — the owner chose the state face only (2026-09-24)")
        #expect(bundle.components(separatedBy: "FernletWidgetEmotionPolicy.lockScreenShowsEmotion ? entry.currentCompanionEmotion : nil").count == 3,
                "both Lock Screen families must route their emotion through the policy")
    }

    /// An older file with no emotion key decodes, and draws no emotion.
    @Test func aSnapshotWithoutTheEmotionKeyStillDecodes() throws {
        let legacy = """
        {"bottleCount":2,"companionStateRaw":"Okay","computedAt":"2026-09-20T12:00:00Z","dateKey":"2026-09-20",\
        "hydrationTarget":4,"macroSummary":{"carbs":1,"fat":1,"protein":1},"score":0.6}
        """
        let decoded = try WidgetBridgeFiles.makeDecoder().decode(WidgetSnapshot.self, from: Data(legacy.utf8))
        #expect(decoded.companionEmotionTimeline == nil)
        #expect(decoded.companionStateRaw == "Okay")
    }
}
