import Foundation
import FernletDomainModel
import FernletScoring

/// Which night a picture of the companion keeps (phone test W-06a, owner's pick "Match the map").
nonisolated enum WorldCompanionNight: Equatable, Sendable {
    /// The map's night: winding down from the map's night tint (or its own bedtime), asleep after the
    /// wind-down. The map, the close-up and the Today card.
    case map
    /// The companion's own bedtime only: sleepy, then asleep, as on the map after bedtime, and awake
    /// before it so every pick shows. Customize (`comp-cust-night`).
    case bedtime
    /// Always awake: Customize's "Hold to peek", the Creation Studio and Save item, where the person
    /// is looking at what they draw.
    case awake
}

/// One picture of the companion: its live state (a friend's gold heart lifts it), what it wears, its
/// pose and its feeling. Every World picture of it reads one of these, from
/// ``WorldCompanionLook/current(store:at:night:bodySignal:playfulUntil:items:mapNight:)``, so the map, the
/// close-up, the Today card, Customize and the Creation Studio cannot drift apart (W-06a).
struct WorldCompanionNow: Equatable {
    /// The live band (`FernletStore.liveCompanionState`).
    let state: CompanionState
    /// What it wears and its colours.
    let look: WorldCompanionLook
    /// Asleep and winding down (no breath and no settled slump: the drawing adds those).
    let pose: WorldCompanionPose
    /// Its feeling at the moment, from the same inputs Home's companion reads.
    let emotion: CompanionEmotion?

    /// Whether the night hides part of the look: the eyes closed (so no glasses), and asleep, the mood
    /// colour resting.
    var isSleeping: Bool { pose.asleep || pose.drowsy }
}

extension WorldCompanionLook {
    /// The companion as a World picture draws it at `date`.
    ///
    /// - Parameters:
    ///   - night: Which night the picture keeps (``WorldCompanionNight``).
    ///   - bodySignal: The opt-in body-signal reading, where the picture reads it (the map, the close-up).
    ///   - playfulUntil: When a pet's playfulness ends, where the picture is petted.
    ///   - items: Pieces to wear instead of the worn ones (the Studio's drawing before it is saved); a
    ///     decoy session wears none either way.
    ///   - mapNight: The map's own reading of its night, where the map has one; nil reads the clock as
    ///     the map does (``isMapNight(at:)``).
    /// - Returns: The picture. An awake picture (``WorldCompanionNight/awake``) reads no feeling: its pose
    ///   never depends on one, and the Studio redraws it on every stroke.
    @MainActor
    static func current(store: FernletStore, at date: Date, night: WorldCompanionNight = .map,
                        bodySignal: CompanionBodySignal? = nil, playfulUntil: Date? = nil,
                        items: [CustomizationItem]? = nil, mapNight: Bool? = nil) -> WorldCompanionNow {
        let emotion = night == .awake ? nil : store.companionEmotion(
            at: date, bodySignal: bodySignal, playfulUntil: playfulUntil,
            appetiteCuesEnabled: CompanionEmotionPreferences.appetiteCuesEnabled(),
            sleepWindow: CompanionEmotionPreferences.sleepWindow())
        let pose = pose(emotion: emotion, night: night, mapNight: mapNight ?? isMapNight(at: date))
        let state = store.liveCompanionState
        let worn = store.duressSessionActive ? [] : (items ?? store.wornCustomItems)
        let look = WorldCompanionLook(appearance: store.settings.companionAppearance, state: state,
                                      asleep: pose.asleep, items: worn)
        return WorldCompanionNow(state: state, look: look, pose: pose, emotion: emotion)
    }

    /// The night's pose for a feeling: asleep when the feeling hides the day; winding down when sleepy,
    /// or (on the map's night) whenever the map is dark.
    nonisolated static func pose(emotion: CompanionEmotion?, night: WorldCompanionNight, mapNight: Bool) -> WorldCompanionPose {
        switch night {
        case .awake:
            return WorldCompanionPose()
        case .bedtime:
            return WorldCompanionPose(asleep: emotion?.hidesTheDay == true, drowsy: emotion == .sleepy)
        case .map:
            return WorldCompanionPose(asleep: emotion?.hidesTheDay == true, drowsy: mapNight || emotion == .sleepy)
        }
    }

    /// The companion's sleep window, for the words that name its bedtime (Customize's night note).
    @MainActor
    static var sleepWindow: CompanionSleepWindow { CompanionEmotionPreferences.sleepWindow() }

    /// Whether the map is in its night (`b1-home-night`) at `date`: the DEBUG harness's fixed time of
    /// day, else the clock's.
    @MainActor
    static func isMapNight(at date: Date) -> Bool {
        (UITestSupport.worldMapHarnessPhase ?? CompanionDayPhase.current(date: date)) == .night
    }
}
