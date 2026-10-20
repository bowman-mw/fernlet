//
//  GuidedZoneViews.swift
//  Fernlet
//
//  The runner's heart-rate readout and the Workout setup switches for guided cardio's zone cue
//  (comparison report idea 9, 2026-10-20; the rules are in `GuidedZones.swift`). Calm by rule: the
//  reading and where it sits are always words, never colour alone, and nothing here animates, so
//  Reduce Motion has nothing to stop.
//

import SwiftUI
import FernletUI

/// The live heart rate on the runner's card during a cardio part: "118 bpm · aim 110–125" over a calm
/// word — "in range", "a little high", "a little low". Drawn only while there is a live reading; without
/// one the card shows no number and the line under it is the talk test (``GuidedZoneWords``).
///
/// One VoiceOver element that says it all in words ("Heart rate 118, aiming for 110 to 125, in range"),
/// marked as updating, so a focused reader hears the current reading.
struct GuidedZoneReadout: View {
    /// The cue to draw; nothing is drawn unless it carries a live reading.
    let zone: WorkoutActivityAttributes.ContentState.Zone

    var body: some View {
        if let readout = WorkoutActivityZoneText.readout(zone), let band = zone.band {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: readout)
                    .font(.fernlet(.stat))
                    .foregroundStyle(Color.bark)
                Text(verbatim: WorkoutActivityZoneText.bandWord(band))
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate)
            }
            .fernletWrappingText()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: WorkoutActivityZoneText.spoken(zone) ?? readout))
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("workout.guided.heartRate")
        }
    }
}

/// Workout setup's two heart-rate switches, under "Cues during a workout": "Heart rate during cardio"
/// and "Zone nudges", with a line saying what they do, where the reading comes from and where it goes,
/// and one saying which sensors work (Apple Watch not yet).
///
/// "Heart rate during cardio" can only be turned on while Fernlet shares workouts with Apple Health
/// (it can always be turned off); "Zone nudges" only with it. Edits the sheet's draft, so Cancel
/// discards a change like any other field; the sheet itself asks Health for heart-rate access when the
/// first switch goes on.
struct WorkoutZoneSettingsRows: View {
    @Binding var preferences: WorkoutZonePreferences
    /// Whether Fernlet shares workouts with Apple Health right now.
    let sharingAllowed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $preferences.liveHeartRate) {
                Text("Heart rate during cardio")
                    .foregroundStyle(Color.bark)
            }
            .disabled(!sharingAllowed && !preferences.liveHeartRate)
            .accessibilityIdentifier("workout.setup.liveHeartRate")
            Toggle(isOn: $preferences.zoneNudges) {
                Text("Zone nudges")
                    .foregroundStyle(Color.bark)
            }
            .disabled(!preferences.liveHeartRate)
            .accessibilityIdentifier("workout.setup.zoneNudges")
            Text("During guided cardio, see your heart rate against a gentle target, from AirPods Pro 3, Powerbeats Pro 2 or a Bluetooth heart-rate strap paired with this iPhone. Turning it on asks Apple Health to let Fernlet read your heart rate. Apple Health keeps the readings, as it does for any workout; Fernlet keeps none. With no reading, the talk test guides you instead. Zone nudges add one light tap when you've drifted out of range for a while.")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            Text("Apple Watch isn't supported yet; AirPods Pro 3, Powerbeats Pro 2 and Bluetooth chest straps are.")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            if !sharingAllowed {
                Text("Needs workout sharing with Apple Health — turn it on in Settings › Health.")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
    }
}
