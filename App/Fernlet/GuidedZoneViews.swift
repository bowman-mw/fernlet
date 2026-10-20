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
/// and one saying which sensors work (Apple Watch not yet); then "My max heart rate"
/// (``WorkoutMaxHeartRateField``).
///
/// "Heart rate during cardio" can only be turned on while Fernlet shares workouts with Apple Health
/// (it can always be turned off); "Zone nudges" only with it. Edits the sheet's drafts, so Cancel
/// discards a change like any other field; the sheet itself asks Health for heart-rate access when the
/// first switch goes on.
struct WorkoutZoneSettingsRows: View {
    @Binding var preferences: WorkoutZonePreferences
    /// The "My max heart rate" field's text draft.
    @Binding var maxHeartRate: String
    /// Whether Fernlet shares workouts with Apple Health right now.
    let sharingAllowed: Bool
    /// The age estimate of the maximum heart rate, in whole beats per minute.
    let estimatedMaximum: Int

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
            WorkoutMaxHeartRateField(text: $maxHeartRate, estimate: estimatedMaximum)
                .padding(.top, 6)
        }
    }
}

/// Workout setup's "My max heart rate": an optional whole number of beats per minute that guided
/// cardio's zones stand on in place of the age estimate, with a footnote naming that estimate's formula
/// and what it gives for this person.
///
/// Edits the sheet's text draft; the sheet's Save stores it through
/// ``WorkoutZonePreferences/saveMaxHeartRate(_:in:)``, where an empty field — or anything that is not a
/// whole number from 120 to 220, which a calm line here points out — clears it. The caption names the
/// field for VoiceOver (``SheetField``'s `namesControl`), Voice Control also answers to "Max heart
/// rate" and "Max" (A9), and every line wraps at any Dynamic Type size.
struct WorkoutMaxHeartRateField: View {
    /// The field's text draft.
    @Binding var text: String
    /// The age estimate, in whole beats per minute: what the zones use while the field is empty.
    let estimate: Int

    /// Whether the field holds something that is not a usable maximum (it would save as a clear).
    private var isUnusable: Bool {
        let typed = text.trimmingCharacters(in: .whitespaces)
        return !typed.isEmpty && WorkoutZonePreferences.maxHeartRate(typed: typed) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SheetField("My max heart rate (bpm)", namesControl: true) {
                TextField("My max heart rate", text: $text, prompt: .fieldPrompt("Optional"))
                    .keyboardType(.numberPad)
                    .sheetTextInput(font: .fernlet(.label))
                    .accessibilityIdentifier("workout.setup.maxHeartRate")
                    .accessibilityInputLabels([Text("Max heart rate"), Text("Max")])
            }
            Text("Left empty, Fernlet estimates it from your age with 208 − 0.7 × age (Tanaka): about \(estimate) bpm for you. If you know your own, from a lab test or a hard effort you measured, enter it and your zones use it instead.")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            if isUnusable {
                Text("Enter a whole number from 120 to 220, or leave it empty.")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
            }
        }
    }
}
