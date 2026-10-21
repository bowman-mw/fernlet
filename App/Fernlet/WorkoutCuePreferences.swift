import Foundation
import SwiftUI
import FernletUI

/// The guided runner's cue switches: "Workout haptics" (on until the person turns it off), "Workout
/// sounds" and "Spoken cues" (each off until they turn it on).
///
/// **Device-local `UserDefaults`, never synced and never in `FernletSettings`**, on the
/// `CompanionEmotionPreferences` pattern. The closest existing setting, the breathing timer's
/// haptics switch (`fernlet.breathing.haptics`), is device-local, and for the same reason: how a phone
/// buzzes or chimes belongs to the device in the person's hand — iOS keeps its own Sounds & Haptics
/// settings per device — while the synced workout fields (`WorkoutProfile`) describe the training
/// itself, which should follow the person to another device. A chime switched on for the gym phone
/// should not start chiming on the iPad. "Delete everything" keeps both keys, like the breathing switch
/// (see `Docs/PrivacyWipeCoverage.md`): a preference, not a record.
///
/// The keys are FROZEN persisted tokens — never rename or localize them. They are spelled once, here,
/// and read and written only through this type, so the wipe wall resolves every access to its literal.
enum WorkoutCuePreferences {
    /// `Bool`, default `true`: play haptic cues during a guided workout.
    static let hapticsKey = "fernlet.workoutCues.haptics"
    /// `Bool`, default `false`: play quiet sound cues during a guided workout.
    static let soundsKey = "fernlet.workoutCues.sounds"
    /// `Bool`, default `false`: say the runner's moments aloud (`GuidedRunSpokenCue`) — the next
    /// exercise and its weight, a rest's or a hold's end. Off until the person turns it on: a voice in
    /// the room is a bigger thing to switch on for someone than a buzz.
    static let spokenKey = "fernlet.workoutCues.spoken"
    /// Spoken cues until the person changes them: off.
    static let defaultSpoken = false

    /// The switches until the person changes them: haptics on, sounds off.
    static let defaultSwitches = FernletFeedbackPreferences(hapticsEnabled: true, soundsEnabled: false)

    /// The person's current switches, falling back to ``defaultSwitches`` for a switch never set.
    static func current(in defaults: UserDefaults = .standard) -> FernletFeedbackPreferences {
        let haptics = defaults.object(forKey: hapticsKey) as? Bool ?? defaultSwitches.hapticsEnabled
        let sounds = defaults.object(forKey: soundsKey) as? Bool ?? defaultSwitches.soundsEnabled
        return FernletFeedbackPreferences(hapticsEnabled: haptics, soundsEnabled: sounds)
    }

    /// Stores both switches — the Workout setup sheet's Save.
    static func save(_ preferences: FernletFeedbackPreferences, in defaults: UserDefaults = .standard) {
        defaults.set(preferences.hapticsEnabled, forKey: hapticsKey)
        defaults.set(preferences.soundsEnabled, forKey: soundsKey)
    }

    /// Whether spoken cues are on, falling back to ``defaultSpoken`` (off) for a switch never set.
    /// Read at every spoken moment, so a change in Workout setup reaches a run already going.
    static func spokenEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: spokenKey) as? Bool ?? defaultSpoken
    }

    /// Stores the spoken-cues switch — the Workout setup sheet's Save, beside ``save(_:in:)``.
    static func saveSpoken(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: spokenKey)
    }
}

/// The Workout setup sheet's "Cues during a workout" field: the haptics, sounds and spoken-cue
/// switches, with one line saying what the taps and sounds do and one saying what is spoken and how
/// it sits with the person's music, then guided cardio's heart-rate switches and "My max heart rate"
/// (``WorkoutZoneSettingsRows``).
///
/// Edits drafts the sheet owns, so Cancel discards a change here like any other field and Save
/// stores them through ``WorkoutCuePreferences/save(_:in:)``,
/// ``WorkoutCuePreferences/saveSpoken(_:in:)``, ``WorkoutZonePreferences/save(_:in:)`` and
/// ``WorkoutZonePreferences/saveMaxHeartRate(_:in:)``.
struct WorkoutCueSettingsSection: View {
    @Binding var preferences: FernletFeedbackPreferences
    /// The "Spoken cues" switch's draft.
    @Binding var spoken: Bool
    /// The heart-rate switches' draft.
    @Binding var zones: WorkoutZonePreferences
    /// The "My max heart rate" field's text draft.
    @Binding var maxHeartRate: String
    /// Whether Fernlet shares workouts with Apple Health right now — the heart-rate switch needs it.
    let healthSharingAllowed: Bool
    /// The age estimate of the maximum heart rate, in whole beats per minute.
    let estimatedMaximum: Int

    var body: some View {
        SheetField("Cues during a workout") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $preferences.hapticsEnabled) {
                    Text("Workout haptics")
                        .foregroundStyle(Color.bark)
                }
                .accessibilityIdentifier("workout.setup.cueHaptics")
                Toggle(isOn: $preferences.soundsEnabled) {
                    Text("Workout sounds")
                        .foregroundStyle(Color.bark)
                }
                .accessibilityIdentifier("workout.setup.cueSounds")
                Toggle(isOn: $spoken) {
                    Text("Spoken cues")
                        .foregroundStyle(Color.bark)
                }
                .accessibilityIdentifier("workout.setup.cueSpoken")
                Text("A tap when a rest or a hold ends. Sounds stay quiet, follow your ring/silent switch, and play over your music without pausing it. The screen stays on while a workout runs. If you lock your phone, the end of a rest or a hold comes as a notification when Fernlet's notifications are allowed, and the workout waits on that step until you open Fernlet again.")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                Text("Spoken cues say the next exercise and side, its suggested weight and last time, an interval's pace and round, and when a rest or a hold ends, only while Fernlet is open. In headphones your music dips while they speak and a podcast pauses, then both carry on; on the phone's speaker they follow your ring/silent switch. With VoiceOver on, VoiceOver says them instead.")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                WorkoutZoneSettingsRows(
                    preferences: $zones, maxHeartRate: $maxHeartRate,
                    sharingAllowed: healthSharingAllowed, estimatedMaximum: estimatedMaximum
                )
                .padding(.top, 6)
            }
        }
    }
}
