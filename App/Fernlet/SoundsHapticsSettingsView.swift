import SwiftUI
import FernletUI

/// Settings › Your day › Sounds & haptics (the app-wide haptics pass, 2026-10-20): the one page that
/// says how Fernlet feels in the hand.
///
/// It holds the app-wide Haptics level — *All / Fewer / Off*, the owner's decision 2 ("Like the three
/// way") — and shows, bound to the SAME keys rather than copies, the switches that already live with
/// their surfaces: the guided workout's Workout haptics, Workout sounds and Spoken cues
/// (``WorkoutCueSwitches``, also in Move › Workout setup) and the breathing timer's Haptics
/// (``BreathingHapticsSwitch``, also on the breathing screen, the owner's decision 5, "Keep it").
///
/// The level sits above every surface switch: FernletUI's one resolver
/// (`FernletFeedbackPreferences.resolved(haptics:sounds:in:)`) ANDs them at every play, so nothing on
/// this page is ever copied into another key. Device-local `UserDefaults`, never synced, kept by
/// "Delete everything" (`Docs/PrivacyWipeCoverage.md`): preferences, not records.
///
/// A pushed page in the ``NearbyFriendsSettingsView`` idiom (``ScreenHeader``, cream cards, one
/// footnote per row). The level is a segmented `Picker` — a system control, so it carries no haptic of
/// its own beyond the system's.
struct SoundsHapticsSettingsView: View {
    /// The app-wide level. The key's one reader for playing is `FernletHapticsLevel.current(in:)`;
    /// this binding is the page's writer.
    @AppStorage(FernletHapticsLevel.storageKey) private var level = FernletHapticsLevel.defaultLevel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(
                    title: "Sounds & haptics",
                    subtitle: "Taps you can feel, and the few sounds Fernlet makes.",
                    identifier: "screen.settings.soundsHaptics"
                )
                levelCard
                workoutCard
                breathingCard
            }
            .padding(20)
            .padding(.bottom, 20)
        }
        .scrollContentBackground(.hidden)
        .background(Color.parchment)
        .navigationTitle("Sounds & haptics")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The app-wide level, with a line saying what the chosen level keeps.
    private var levelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Haptics")
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
            Picker("Haptics", selection: $level) {
                Text("All").tag(FernletHapticsLevel.all)
                Text("Fewer").tag(FernletHapticsLevel.fewer)
                Text("Off").tag(FernletHapticsLevel.off)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.soundsHaptics.level")
            Text(levelFootnote)
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
                .accessibilityIdentifier("settings.soundsHaptics.levelFootnote")
            if !dynamicTypeSize.isAccessibilitySize {
                Text("Sounds play only in a workout you started, and only if you turn them on. Your phone's own sound and haptics settings still apply.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    /// What the chosen level keeps, in one sentence.
    private var levelFootnote: LocalizedStringKey {
        switch level {
        case .all: "A soft tap when a log lands, and a firmer one for results and timers."
        case .fewer: "Results and timers only, without the small taps under your thumb."
        case .off: "No haptics anywhere in Fernlet."
        }
    }

    /// The guided workout's switches, the same keys Workout setup edits.
    private var workoutCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("During a workout")
            WorkoutCueSwitches()
            surfaceNote(
                whenOff: "Haptics are off for all of Fernlet, so Workout haptics won't play. Sounds and spoken cues keep their own switches.",
                closing: "The same switches as Move › Workout setup."
            )
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    /// The breathing timer's own switch, the same key its screen edits.
    private var breathingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Breathing")
            BreathingHapticsSwitch()
            surfaceNote(
                whenOff: "Haptics are off for all of Fernlet, so breathing's taps won't play either.",
                closing: nil
            )
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    /// A card's closing line, plus — while the app-wide level is Off — the reason its haptics
    /// switch plays nothing. The Off line is kept at every text size: it explains a switch that
    /// reads "on" and does nothing.
    @ViewBuilder
    private func surfaceNote(whenOff offNote: LocalizedStringKey, closing: LocalizedStringKey?) -> some View {
        if level == .off {
            Text(offNote)
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
                .accessibilityIdentifier("settings.soundsHaptics.offNote")
        }
        if let closing, !dynamicTypeSize.isAccessibilitySize {
            Text(closing)
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
    }
}

/// One switch on the Sounds & haptics page with its one-line footnote, in the Nearby friends page's
/// row shape (5b·AX3): the footnote drops at accessibility sizes and rides the toggle as custom
/// content at every size, so VoiceOver's More Content rotor still has it (T2-2).
struct SoundsHapticsSwitchRow: View {
    let title: LocalizedStringKey
    let footnote: LocalizedStringKey
    @Binding var isOn: Bool
    let identifier: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(isOn: $isOn) {
                Text(title)
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
            }
            .accessibilityCustomContent("Details", footnote)
            .accessibilityIdentifier(identifier)
            if !dynamicTypeSize.isAccessibilitySize {
                Text(footnote)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
    }
}
