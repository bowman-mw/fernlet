import Foundation
import FernletDomainModel
import FernletFoundation
import FernletScoring
// `DerivedSignalRecord` (the mood trend) and `ReceivedHeartRecord` (the heart ledger's rows): the app
// target builds with member-import visibility, so their members need their modules named here.
import LocalPersistence
import ProximityKit

/// The companion's emotion, assembled from what the store already holds (owner decision
/// 2026-09-24).
///
/// The store supplies the inputs it owns — today's band, the latest journal tag, the mood trend, the
/// last meal, the water, and the person's cue and bedtime settings. The three app-only signals are
/// the Home companion's to add: the body-signal reading comes from the scene's `StressService`, the
/// pet from Home's own tap, and a friend's heart from the heart ledger. The widget path never reads
/// any of the three — ``widgetEmotionTimeline(defaults:)`` builds from the store-owned inputs alone,
/// so the background refresh touches neither the ledger (a ProximityKit sidecar) nor HealthKit.
/// Nothing here is stored: every value is read fresh and handed to the pure `CompanionEmotionEngine`.
extension FernletStore {

    /// When the newest received heart stops glowing (24 hours after it arrived), or nil when no heart
    /// is on record.
    ///
    /// Returned even once it has passed — the engine asks `now < until`. Read on the foreground Home
    /// path only, never by the widget path. Presentation only — hearts never feed `score` (spec §10).
    var heartGlowUntil: Date? {
        guard let newest = heartLedger.receivedHearts.map(\.receivedAt).max() else { return nil }
        return newest.addingTimeInterval(HeartGlowMath.decayWindow)
    }

    /// Whether today is a gentle day for the companion — tagged hard or tired, or no entry yet and a
    /// mood trend that needs gentleness (`CompanionEmotionInputs.isGentleDay`). The Home companion's
    /// settled pose reads it, so a pet on a hard day soothes rather than cheers.
    var isGentleCompanionDay: Bool {
        CompanionEmotionInputs(state: companionState, latestJournalTag: day.journals.last?.tag,
                               moodNeedsGentleness: moodNeedsGentleness).isGentleDay
    }

    /// Whether the derived mood trend currently reads "needs gentleness".
    var moodNeedsGentleness: Bool {
        derivedSignals.first { $0.signalName == "moodTrend" }?.value == "needs gentleness"
    }

    /// The engine inputs from the store's own state and the person's companion-feelings settings.
    /// The three app-only signals — the body signal, the pet and the heart — are left nil for the
    /// Home companion to add.
    ///
    /// - Parameters:
    ///   - appetiteCuesEnabled: The appetite and thirst cues switch.
    ///   - sleepWindow: The person's night.
    func companionEmotionInputs(appetiteCuesEnabled: Bool, sleepWindow: CompanionSleepWindow) -> CompanionEmotionInputs {
        CompanionEmotionInputs(
            state: companionState,
            latestJournalTag: day.journals.last?.tag,
            moodNeedsGentleness: moodNeedsGentleness,
            lastMealAt: day.meals.map(\.loggedAt).max(),
            bottleCount: day.bottleCount,
            hydrationTarget: settings.hydrationTarget,
            appetiteCuesEnabled: appetiteCuesEnabled,
            sleepWindow: sleepWindow
        )
    }

    /// The same inputs, with the companion-feelings settings read from `defaults`.
    ///
    /// - Parameter defaults: Where the settings live; injectable for tests.
    func companionEmotionInputs(defaults: UserDefaults = .standard) -> CompanionEmotionInputs {
        companionEmotionInputs(
            appetiteCuesEnabled: CompanionEmotionPreferences.appetiteCuesEnabled(in: defaults),
            sleepWindow: CompanionEmotionPreferences.sleepWindow(in: defaults)
        )
    }

    /// The Home companion's emotion at `now`, with the three app-only signals added (the heart is
    /// read from the ledger here, on the foreground path only).
    ///
    /// - Parameters:
    ///   - now: The instant to answer for.
    ///   - bodySignal: The opt-in body-signal reading, already gated on the setting; nil when off.
    ///   - playfulUntil: When the playful beat after the last pet ends; nil when there was no pet.
    ///   - appetiteCuesEnabled: The appetite and thirst cues switch, as Home read it.
    ///   - sleepWindow: The person's night, as Home read it.
    func companionEmotion(at now: Date, bodySignal: CompanionBodySignal?, playfulUntil: Date?,
                          appetiteCuesEnabled: Bool, sleepWindow: CompanionSleepWindow) -> CompanionEmotion? {
        var inputs = companionEmotionInputs(appetiteCuesEnabled: appetiteCuesEnabled, sleepWindow: sleepWindow)
        inputs.bodySignal = bodySignal
        inputs.playfulUntil = playfulUntil
        inputs.heartGlowUntil = heartGlowUntil
        return CompanionEmotionEngine.emotion(for: inputs, at: now)
    }

    /// The widget's emotion timeline for the store's own day (`todayKey`), built from the store-owned
    /// inputs made WIDGET-SAFE, so the body-signal, petting and heart emotions can never reach the
    /// app-group file — and the background refresh that calls this reads no heart ledger.
    ///
    /// Anchored on `todayKey` rather than the wall clock: a process that has not rolled its day yet
    /// publishes a snapshot stamped with yesterday's key, and its timeline must describe that same
    /// yesterday — never lend yesterday's feelings to a moment on today's date.
    ///
    /// - Parameter defaults: Where the companion-feelings settings live; injectable for tests.
    /// - Returns: The moments, each carrying the frozen emotion token.
    func widgetEmotionTimeline(defaults: UserDefaults = .standard) -> [WidgetSnapshot.EmotionMoment] {
        guard let midnight = FernletDate.date(fromDayKey: todayKey) else { return [] }
        let midday = midnight.addingTimeInterval(12 * 60 * 60)
        let inputs = companionEmotionInputs(defaults: defaults).widgetSafe
        return CompanionEmotionEngine.timeline(for: inputs, dayContaining: midday).map {
            WidgetSnapshot.EmotionMoment(at: $0.at, emotionRaw: $0.emotion?.rawValue)
        }
    }
}
