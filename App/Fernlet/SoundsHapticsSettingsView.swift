import SwiftUI
import FernletUI

/// Settings › Your day › Sounds & haptics (the app-wide haptics pass, 2026-10-20): the one page that
/// says how Fernlet feels in the hand.
///
/// It holds the app-wide Haptics level — *All / Fewer / Off*, the owner's decision 2 ("Like the three
/// way") — and shows, bound to the SAME keys rather than copies, the switches that already live with
/// their surfaces: the guided workout's Workout haptics, Workout sounds and Spoken cues
/// (``WorkoutCueSwitches``, also in Move › Workout setup), the cooking timer's sound
/// (``CookingSoundSwitch``, also on a cooking step's timer card, report C1) and the breathing timer's
/// Haptics (``BreathingHapticsSwitch``, also on the breathing screen, the owner's decision 5, "Keep it").
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

    /// The World's framed look (`b2-settings-sounds`): the level as the framed segmented control on
    /// a card, then each surface's switches as a framed section with its closing line under it.
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScreenHeader(
                    title: "Sounds & haptics",
                    subtitle: "Taps you can feel, and the few sounds Fernlet makes.",
                    identifier: "screen.settings.soundsHaptics"
                )
                levelCard
                surfaceSection("During a workout",
                               whenOff: "Haptics are off for all of Fernlet, so Workout haptics won't play. Sounds and spoken cues keep their own switches.",
                               closing: "The same switches as Move › Workout setup.") { WorkoutCueSwitches() }
                surfaceSection("Cooking",
                               whenOff: "Haptics are off for all of Fernlet, so the cooking timer's tap won't play. Its sound keeps its own switch.",
                               closing: "The same switch as on a step's timer while you cook.") { CookingSoundSwitch() }
                surfaceSection("Breathing",
                               whenOff: "Haptics are off for all of Fernlet, so breathing's taps won't play either.",
                               closing: nil) { BreathingHapticsSwitch() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 30)
        }
        .scrollContentBackground(.hidden)
        .fernletPageBackground()
        .fernletPushedPage("Sounds & haptics")
    }

    /// The app-wide level, with a line saying what the chosen level keeps.
    private var levelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Haptics")
                .font(FernletFramedFont.rowTitle.weight(.semibold))
                .foregroundStyle(look?.text ?? Color.bark)
            // The segments' own keys rather than the bare "All" / "Off" every other screen shares:
            // a segmented control's choice and a status readout can need different words ("Off" is
            // also the AI and Health status).
            FernletSegmentedPicker("Haptics", selection: $level, options: [.all, .fewer, .off]) { Self.levelName($0) }
                .accessibilityIdentifier("settings.soundsHaptics.level")
            Text(levelFootnote)
                .font(FernletFramedFont.note)
                .foregroundStyle(look?.dim ?? Color.slate)
                .fernletWrappingText()
                .accessibilityIdentifier("settings.soundsHaptics.levelFootnote")
            if !dynamicTypeSize.isAccessibilitySize {
                Text("Sounds play only in a workout or a cook you started, and only if you turn them on. Your phone's own sound and haptics settings still apply.")
                    .font(FernletFramedFont.note)
                    .foregroundStyle(look?.dim ?? Color.slate)
                    .fernletWrappingText()
            }
        }
        .settingsCard()
    }

    /// A level's name on its segment.
    private static func levelName(_ level: FernletHapticsLevel) -> Text {
        switch level {
        case .all:
            Text(LocalizedStringResource("settings.haptics.level.all", defaultValue: "All",
                                         comment: "Sounds & haptics: segmented control choice, every haptic plays."))
        case .fewer:
            Text(LocalizedStringResource("settings.haptics.level.fewer", defaultValue: "Fewer",
                                         comment: "Sounds & haptics: segmented control choice, only the important haptics play."))
        case .off:
            Text(LocalizedStringResource("settings.haptics.level.off", defaultValue: "Off",
                                         comment: "Sounds & haptics: segmented control choice, no haptics play. A choice on a switch-like control, not a status readout."))
        }
    }

    /// What the chosen level keeps, in one sentence.
    private var levelFootnote: LocalizedStringKey {
        switch level {
        case .all: "A soft tap when a log lands, and a firmer one for results and timers."
        case .fewer: "Results and timers only, without the small taps under your thumb."
        case .off: "No haptics anywhere in Fernlet."
        }
    }

    /// One surface's switches as a framed section (the same keys that surface edits), its closing
    /// line under the card, and — while the app-wide level is Off — the reason its haptics switch
    /// plays nothing. The Off line is kept at every text size: it explains a switch that reads "on"
    /// and does nothing.
    private func surfaceSection<Switches: View>(_ header: LocalizedStringKey, whenOff offNote: LocalizedStringKey,
                                                closing: LocalizedStringKey?,
                                                @ViewBuilder switches: () -> Switches) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            FernletFramedSection(header: Text(header),
                                 footer: dynamicTypeSize.isAccessibilitySize ? nil : closing.map { Text($0) }) {
                switches()
            }
            if level == .off {
                FernletNotice(offNote)
                    .accessibilityIdentifier("settings.soundsHaptics.offNote")
            }
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
        // One framed row (`.sr`): the name, and the footnote as its second line. VoiceOver hears the
        // name as the switch's label and the footnote as its Details, as before.
        Toggle(isOn: $isOn) {
            FernletRowLabel(title: Text(title), detail: dynamicTypeSize.isAccessibilitySize ? nil : Text(footnote))
                .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 0 : 7)
        }
        .accessibilityLabel(Text(title))
        .accessibilityCustomContent("Details", footnote)
        .accessibilityIdentifier(identifier)
    }
}
