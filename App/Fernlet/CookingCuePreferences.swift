import Foundation
import SwiftUI
import FernletUI

/// The cooking timer's "Timer sound" switch (report C1, 2026-10-20): whether a step's timer running
/// out plays Fernlet's quiet chime beside its "time's up" haptic. Off until the person turns it on.
///
/// **Device-local `UserDefaults`, never synced and never in `FernletSettings`**, on the
/// ``WorkoutCuePreferences`` pattern and for the same reason: how a phone chimes belongs to the phone
/// in the person's hand. "Delete everything" keeps the key (see `Docs/PrivacyWipeCoverage.md`): a
/// preference, not a record.
///
/// Cooking has no haptics switch of its own: the timer's haptic answers to the app-wide Haptics level
/// alone, and this switch adds the sound. Both go through FernletUI's one resolver
/// (`FernletFeedbackPreferences.resolved(haptics:sounds:in:)`), read at the moment the timer runs out,
/// so a change made mid-cook reaches the next timer. The chime is an AudioServices system sound: it
/// follows the ring/silent switch and plays over the person's music without pausing it.
///
/// The key is a FROZEN persisted token — never rename or localize it. It is spelled once, here, and
/// read and written only in this file, so the wipe wall resolves every access to its literal.
enum CookingCuePreferences {
    /// `Bool`, default `false`: play the quiet chime when a cooking step's timer runs out.
    static let soundsKey = "fernlet.cookingCues.sounds"
    /// The switch until the person changes it: off.
    static let defaultSounds = false

    /// Whether the timer sound is on, falling back to ``defaultSounds`` for a switch never set.
    static func soundsEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: soundsKey) as? Bool ?? defaultSounds
    }

    /// What the cooking timer plays under right now: the haptic under the app-wide Haptics level, and
    /// the chime when this switch is on.
    static func current(in defaults: UserDefaults = .standard) -> FernletFeedbackPreferences {
        .resolved(haptics: true, sounds: soundsEnabled(in: defaults), in: defaults)
    }
}

/// The switch as Settings › Sounds & haptics shows it: bound straight to the stored key, so a change
/// here is the same change the cooking screen's own switch makes, with no copy anywhere.
struct CookingSoundSwitch: View {
    @AppStorage(CookingCuePreferences.soundsKey) private var sounds = CookingCuePreferences.defaultSounds

    var body: some View {
        SoundsHapticsSwitchRow(
            title: "Cooking timer sound",
            footnote: "A quiet chime when a step's timer runs out. It follows your ring/silent switch.",
            isOn: $sounds,
            identifier: "settings.soundsHaptics.cookingSounds"
        )
    }
}

/// The same switch on a cooking step's timer card — the shortcut, beside the timer it changes, for a
/// cook who wants to hear it across the kitchen. One line, so it never pushes the step off screen.
struct CookingTimerSoundToggle: View {
    @AppStorage(CookingCuePreferences.soundsKey) private var sounds = CookingCuePreferences.defaultSounds

    var body: some View {
        // World build (b3-cook-step): the name over its line, beside the framed switch the root's
        // toggle style draws. The line is drawn now, so it is no longer extra spoken content.
        Toggle(isOn: $sounds) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Timer sound")
                    .font(FernletFramedFont.rowTitle.weight(.semibold))
                    .foregroundStyle(WorldPalette.bark)
                Text("A quiet chime when the timer runs out. It follows your ring/silent switch.")
                    .font(FernletFramedFont.rowDetail)
                    .foregroundStyle(WorldPalette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Color.moss)
        .accessibilityIdentifier("cookingMode.timerSound")
    }
}
