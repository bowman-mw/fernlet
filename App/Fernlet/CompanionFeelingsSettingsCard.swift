import SwiftUI
import FernletScoring
import FernletUI

/// Settings › Appearance › Companion feelings: the hunger-and-thirst cues switch and the bedtime
/// window (owner decision 2026-09-24).
///
/// Binds the three device-local `CompanionEmotionPreferences` keys directly through `@AppStorage`,
/// so Home redraws the companion the moment one changes; `onChange` lets the sheet republish the
/// widget snapshot, whose emotion timeline is built from the same keys.
///
/// The cue switch is the person's answer to a real tension: hungry and thirsty come from LOGGING
/// gaps, not from anything the app knows about their body, so they must stay gentle — waking hours
/// only, silent when unwell or resting, quiet in the evening — and they must be easy to turn off
/// entirely. Nothing here syncs.
struct CompanionFeelingsSettingsCard: View {
    /// Called after any change, so the widget's emotion timeline is republished at once.
    var onChange: () -> Void = {}

    @AppStorage(CompanionEmotionPreferences.appetiteCuesKey) private var appetiteCuesEnabled = true
    @AppStorage(CompanionEmotionPreferences.bedtimeMinuteKey) private var bedtimeMinute = CompanionSleepWindow.standard.bedtimeMinute
    @AppStorage(CompanionEmotionPreferences.wakeMinuteKey) private var wakeMinute = CompanionSleepWindow.standard.wakeMinute

    /// The current text size, used only as the two time pickers' identity (see `body`).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your companion shows how it feels — sleepy at bedtime, happy on a bright day, sad with you on a hard one. Its feelings are worked out on this phone and are never synced or sent to friends.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            Toggle("Hunger and thirst cues", isOn: $appetiteCuesEnabled)
                .font(.fernlet(.label))
                .accessibilityIdentifier("settings.companionFeelings.appetiteCues")
            Text("When it's been a while since a meal or some water, your companion can look a little hungry or thirsty — only in waking hours, never when you're unwell. Turn this off and it never will.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            // `.id(dynamicTypeSize)`: a compact DatePicker grows with the text size but never shrinks
            // back. Measured 2026-09-26 on iPhone 17: large, then the largest accessibility size,
            // then large again left each time picker 77.3pt tall instead of 36pt, with everything
            // below it pushed down, until the page was reopened. A fresh picker per text size is
            // measured at the size in force. The accessibility audit's own Dynamic Type pass does
            // the same round trip, which is why Settings · Appearance picked up a "Potentially
            // inaccessible text" finding whenever the pills stayed tall.
            DatePicker("Bedtime", selection: Self.clockBinding($bedtimeMinute), displayedComponents: .hourAndMinute)
                .font(.fernlet(.label))
                .accessibilityIdentifier("settings.companionFeelings.bedtime")
                .id(dynamicTypeSize)
            DatePicker("Wake-up", selection: Self.clockBinding($wakeMinute), displayedComponents: .hourAndMinute)
                .font(.fernlet(.label))
                .accessibilityIdentifier("settings.companionFeelings.wake")
                .id(dynamicTypeSize)
            Text("Your companion gets sleepy at bedtime and wakes with you. It never mentions food or water in the last hour and a half before bed.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
        .onChange(of: appetiteCuesEnabled) { onChange() }
        .onChange(of: bedtimeMinute) { onChange() }
        .onChange(of: wakeMinute) { onChange() }
    }

    /// A time-of-day picker binding over a stored "minutes after midnight" value.
    ///
    /// Only the hour and minute cross the binding, so a stored value is the same wall-clock time
    /// every day and in every time zone the phone visits.
    static func clockBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                // Folded first: a stored value is never trusted to be in range (R5).
                let value = CompanionSleepWindow(bedtimeMinute: minutes.wrappedValue, wakeMinute: 0).bedtimeMinute
                return Calendar.current.date(bySettingHour: value / 60, minute: value % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }
}
