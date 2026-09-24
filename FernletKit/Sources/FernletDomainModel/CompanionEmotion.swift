// CompanionEmotion.swift
// The companion's momentary feeling: a presentation layer over `CompanionState` (owner decision 2026-09-24).

import Foundation

/// How the companion feels right now — the face and the one small motif drawn over its
/// ``CompanionState``.
///
/// The state is the day's wellbeing BAND (body colour, breath, posture) and is persisted on every
/// ``DailyHealthScore``. The emotion is a separate, momentary layer on top of it: *sleepy* at
/// bedtime, *hungry* when no meal has been logged in a while, *sad* on a day the person tagged hard,
/// *loved* when a friend's heart arrived. `FernletScoring.CompanionEmotionEngine` derives it from
/// inputs the app already holds, as a pure function of those inputs and the clock.
///
/// **Never persisted, never synced — by construction, not by convention.** This enum is
/// deliberately NOT `Codable`, so it cannot be added to a persisted or synced model without a
/// compile error. It never reaches the friend wire (friends keep the three-way ``FriendFuzzyState``
/// fold of the state), an export, or ``DailyHealthScore``. Its one trip out of the app process is the
/// device-local widget snapshot in the app-group container, which carries the raw token and is
/// deleted by "Delete everything"; `CompanionEmotionPrivacyTests` pins the whole list of files that
/// may name this type.
///
/// **The raw values are FROZEN tokens.** They cross into the widget extension — a SEPARATE PROCESS
/// that links no FernletKit product — as each moment's `emotionRaw` in the app-group snapshot's
/// `companionEmotionTimeline`, where the widget's hand-copied `WidgetCompanionEmotion` re-parses them. Translating or renaming one makes
/// the widget fail that parse and fall back to the plain state face, with nothing in either process
/// to show why. Only ``displayName`` and ``feelingPhrase`` are ever read by a person, and they are
/// the only halves that localize. `LocalizationBoundaryTests` pins both sides.
///
/// **No streak or pride.** There is no *proud* emotion and no emotion that rewards a run of days:
/// the spec rules out optimization, and a companion that looked proud of a streak would turn the
/// gentle mirror back into a score.
public nonisolated enum CompanionEmotion: String, CaseIterable, Sendable {
    case happy
    case sad
    case tired
    case sleepy
    case hungry
    case thirsty
    case loved
    case comforted
    case playful
    case calm
    case frazzled

    /// The emotion's reader-facing name, standalone ("Sleepy") — the display half of the token fork.
    public var displayName: String {
        switch self {
        case .happy: String(localized: "companionEmotion.happy", defaultValue: "Happy", bundle: .module,
                            comment: "Companion feeling: cheerful. Shown beside the companion's state")
        case .sad: String(localized: "companionEmotion.sad", defaultValue: "Sad", bundle: .module,
                          comment: "Companion feeling on a day the person tagged hard — sad WITH them, never disappointed")
        case .tired: String(localized: "companionEmotion.tired", defaultValue: "Tired", bundle: .module,
                            comment: "Companion feeling: low on energy")
        case .sleepy: String(localized: "companionEmotion.sleepy", defaultValue: "Sleepy", bundle: .module,
                             comment: "Companion feeling during the person's bedtime hours")
        case .hungry: String(localized: "companionEmotion.hungry", defaultValue: "Hungry", bundle: .module,
                             comment: "Companion feeling when no meal has been logged in a while")
        case .thirsty: String(localized: "companionEmotion.thirsty", defaultValue: "Thirsty", bundle: .module,
                              comment: "Companion feeling when water is behind the day's pace")
        case .loved: String(localized: "companionEmotion.loved", defaultValue: "Loved", bundle: .module,
                            comment: "Companion feeling after a friend sent a heart")
        case .comforted: String(localized: "companionEmotion.comforted", defaultValue: "Comforted", bundle: .module,
                                comment: "Companion feeling on a hard day when a friend's heart or a pet arrives")
        case .playful: String(localized: "companionEmotion.playful", defaultValue: "Playful", bundle: .module,
                              comment: "Companion feeling right after being petted")
        case .calm: String(localized: "companionEmotion.calm", defaultValue: "Calm", bundle: .module,
                           comment: "Companion feeling when opt-in body signals read calm")
        case .frazzled: String(localized: "companionEmotion.frazzled", defaultValue: "A little frazzled", bundle: .module,
                               comment: "Companion feeling when opt-in body signals read tense — warm, never alarming")
        }
    }

    /// The emotion as the second half of a sentence ("feeling sleepy"), for "Okay, feeling sleepy".
    ///
    /// A whole localized phrase rather than a lowercased ``displayName``: case and word order are the
    /// translator's to decide, and lowercasing a localized adjective is wrong in several languages.
    public var feelingPhrase: String {
        switch self {
        case .happy: String(localized: "companionEmotion.feeling.happy", defaultValue: "feeling happy",
                            bundle: .module, comment: "Follows the companion's state: 'Okay, feeling happy'")
        case .sad: String(localized: "companionEmotion.feeling.sad", defaultValue: "feeling sad",
                          bundle: .module, comment: "Follows the companion's state: 'Okay, feeling sad'. Sad with the person, never disappointed")
        case .tired: String(localized: "companionEmotion.feeling.tired", defaultValue: "feeling tired",
                            bundle: .module, comment: "Follows the companion's state: 'Tired, feeling tired'")
        case .sleepy: String(localized: "companionEmotion.feeling.sleepy", defaultValue: "feeling sleepy",
                             bundle: .module, comment: "Follows the companion's state: 'Okay, feeling sleepy'")
        case .hungry: String(localized: "companionEmotion.feeling.hungry", defaultValue: "feeling hungry",
                             bundle: .module, comment: "Follows the companion's state: 'Okay, feeling hungry'")
        case .thirsty: String(localized: "companionEmotion.feeling.thirsty", defaultValue: "feeling thirsty",
                              bundle: .module, comment: "Follows the companion's state: 'Okay, feeling thirsty'")
        case .loved: String(localized: "companionEmotion.feeling.loved", defaultValue: "feeling loved",
                            bundle: .module, comment: "Follows the companion's state: 'Okay, feeling loved'")
        case .comforted: String(localized: "companionEmotion.feeling.comforted", defaultValue: "feeling comforted",
                                bundle: .module, comment: "Follows the companion's state: 'Okay, feeling comforted'")
        case .playful: String(localized: "companionEmotion.feeling.playful", defaultValue: "feeling playful",
                              bundle: .module, comment: "Follows the companion's state: 'Okay, feeling playful'")
        case .calm: String(localized: "companionEmotion.feeling.calm", defaultValue: "feeling calm",
                           bundle: .module, comment: "Follows the companion's state: 'Okay, feeling calm'")
        case .frazzled: String(localized: "companionEmotion.feeling.frazzled", defaultValue: "feeling a little frazzled",
                               bundle: .module, comment: "Follows the companion's state: 'Okay, feeling a little frazzled'")
        }
    }

    /// Whether the widget snapshot may carry this emotion.
    ///
    /// Five emotions stay inside the app:
    /// - ``calm`` and ``frazzled`` come from the opt-in body signals (HealthKit heart-rate
    ///   variability against the person's own baseline). The widget snapshot's standing contract is
    ///   "no stress data", and its file sits in the app-group container, outside the backup
    ///   exclusion the body-tension history carries — so these never leave the process.
    /// - ``loved`` and ``comforted`` come from a friend's heart (and ``comforted`` also from a pet).
    ///   The heart ledger is a ProximityKit sidecar, and the snapshot is rebuilt by the background
    ///   refresh on a cold wake, which reads no ProximityKit state and no disk beyond the store it
    ///   acquired. A friend's warmth is also social information the Home Screen does not need.
    /// - ``playful`` is the few minutes after a pet. It answers a touch on Home; on a widget it would
    ///   be a stale echo of something that already happened.
    ///
    /// The widget's hand-copied `WidgetCompanionEmotion` mirrors exactly the publishable cases:
    /// happy, sad, tired, sleepy, hungry and thirsty.
    public var isWidgetPublishable: Bool {
        switch self {
        case .calm, .frazzled, .playful, .loved, .comforted: false
        case .happy, .sad, .tired, .sleepy, .hungry, .thirsty: true
        }
    }

    /// Whether the face reads as happy: bright or smiling eyes and a smile.
    ///
    /// The derivation guarantees none of these on a gentle day (tagged hard or tired, or a mood trend
    /// that needs gentleness) or an unwell one — the owner's "a happy companion on a hard day seems
    /// wrong". ``comforted`` is deliberately NOT here: closed, soothed eyes and a small smile read as
    /// held, not as cheerful.
    public var isHappyLooking: Bool {
        switch self {
        case .happy, .playful, .loved, .calm: true
        case .sad, .tired, .sleepy, .hungry, .thirsty, .comforted, .frazzled: false
        }
    }

    /// The companion's spoken status: the state alone ("Okay"), or the state and the emotion
    /// ("Okay, feeling sleepy").
    ///
    /// Built only from the two display forks — never a `rawValue`, which is a frozen token and would
    /// be read aloud untranslated.
    public static func accessibilityValue(state: CompanionState, emotion: CompanionEmotion?) -> String {
        guard let emotion else { return state.displayName }
        return String(localized: "companionEmotion.stateAndFeeling",
                      defaultValue: "\(state.displayName), \(emotion.feelingPhrase)", bundle: .module,
                      comment: "The companion's spoken status: its state, then its feeling. Example: 'Okay, feeling sleepy'")
    }
}
