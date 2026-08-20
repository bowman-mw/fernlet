import SwiftUI
import FernletDomainModel
import FernletScoring
import FernletUI

/// Quick-log sheet for hydration: today's bottle count with add/remove buttons and a bottle-row
/// visual against the target.
///
/// Presented from the main view's quick-log flow. Every tap mutates ``FernletStore`` immediately
/// (`addBottle`/`removeBottle`) — the Done bar only dismisses, so there is no unsaved draft to lose.
/// Bottle size and daily target come from settings and are edited in ``SettingsSheet``, not here.
struct WaterSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Water")
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

                    VStack(spacing: 4) {
                        Text("\(store.day.bottleCount)")
                            .font(.fernlet(.display))
                            .foregroundStyle(Color.bark)
                        Text("\(store.day.bottleCount == 1 ? "bottle" : "bottles") - \(store.day.bottleCount * store.settings.bottleOz) oz total")
                            .font(.fernlet(.bubble))
                            .foregroundStyle(Color.slate)
                        Text("\(store.settings.bottleOz) oz each · target \(store.settings.hydrationTarget)")
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.slate)
                    }
                    .frame(maxWidth: .infinity)

                    HStack(spacing: 8) {
                        ForEach(0..<max(4, min(max(store.settings.hydrationTarget, store.day.bottleCount), 12)), id: \.self) { index in
                            Image(systemName: "waterbottle")
                                .font(.title2)
                                .foregroundStyle(index < store.day.bottleCount ? Color.slate : Color.slate.opacity(0.25))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    HStack(spacing: 10) {
                        Button("Remove") { store.removeBottle() }
                            .buttonStyle(ChipButtonStyle(selected: false))
                            .disabled(store.day.bottleCount == 0)
                        Button("Add a bottle") { store.addBottle() }
                            .buttonStyle(ChipButtonStyle(selected: true))
                    }

                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: "Done") { dismiss() }
        }
        .background(Color.parchment)
    }
}

/// Quick-log sheet for sleep: a quality picker plus optional hours and note fields.
///
/// Presented from the main view's quick-log flow. Pre-fills from today's existing sleep entry on
/// appear (so reopening edits rather than resets) and commits everything in one
/// `FernletStore.setSleep` call on Save — a swipe-down with unsaved edits raises the shared discard
/// confirmation rather than throwing the draft away.
struct SleepSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    @State private var hours = ""
    @State private var quality: SleepQuality = .ok
    @State private var note = ""
    /// What `prefillFromToday` landed, so the dirty guard fires on real edits only (and never on the
    /// pre-fill itself).
    @State private var original = Draft()

    /// The three editable fields as one comparable value — the dirty check for the draft guard.
    private struct Draft: Equatable {
        var hours = ""
        var quality: SleepQuality = .ok
        var note = ""
    }

    private var draft: Draft { Draft(hours: hours, quality: quality, note: note) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Sleep")
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

                    qualityPicker

                    HStack(alignment: .top, spacing: 12) {
                        SheetField("Hours (optional)") {
                            TextField("7.5", text: $hours)
                                // A decimal pad, not the full alphabetic keyboard: "7.5" is the
                                // expected value and there are no letters in it.
                                .keyboardType(.decimalPad)
                                .sheetTextInput(font: .fernlet(.label))
                        }
                        SheetField("Note (optional)") {
                            TextField("woke up twice...", text: $note)
                                .submitLabel(.done)
                                .onSubmit { save() }
                                .sheetTextInput()
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }
            .onAppear(perform: prefillFromToday)

            SheetSaveBar { save() }
        }
        .background(Color.parchment)
        .fernletDraftGuard(isDirty: draft != original) { dismiss() }
    }

    /// The four quality options as one wrapping row of chips, with the chosen option's description
    /// as a single line beneath.
    ///
    /// Four two-line cards pushed "Great", Hours and Note below the fold of a medium sheet (and left
    /// 1.5 options visible at accessibility sizes); chips fit the whole choice on one or two rows.
    /// ``ChipButtonStyle`` also carries the `.isSelected` trait, which the checkmark-only rows never
    /// exposed to VoiceOver.
    private var qualityPicker: some View {
        SheetField("Quality") {
            VStack(alignment: .leading, spacing: 8) {
                FlowLayout(spacing: 8) {
                    ForEach(SleepQuality.allCases) { option in
                        Button(option.label) { quality = option }
                            .buttonStyle(ChipButtonStyle(selected: quality == option))
                    }
                }
                Text(quality.description)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
    }

    private func save() {
        store.setSleep(hours: validatedHours, quality: quality, note: note)
        dismiss()
    }

    /// Pre-fills the draft from today's existing sleep entry so reopening edits rather than resets.
    private func prefillFromToday() {
        guard let sleep = store.day.sleep else { return }
        let recordedHours = sleep.hours.map { String($0) } ?? ""
        quality = sleep.quality
        note = sleep.note
        hours = recordedHours
        // The baseline the discard prompt compares against — the values just landed, so an untouched
        // reopen of an existing entry is clean and dismisses without a dialog.
        original = Draft(hours: recordedHours, quality: sleep.quality, note: sleep.note)
    }

    /// The typed hours, validated at this boundary (R5): `Double("nan")` is NaN and `Double("1e400")`
    /// is infinity, and a non-finite value in the day record makes the snapshot's `JSONEncoder` throw
    /// — losing the whole day's save. Out-of-range or unparseable text saves as "no hours recorded"
    /// rather than as a number nothing downstream can use.
    private var validatedHours: Double? {
        guard let parsed = LocaleTolerantNumber.double(from: hours),
              parsed.isFinite, (0...24).contains(parsed) else { return nil }
        return parsed
    }
}

/// Two-phase sheet for re-planning fitness goals: describe level/interests/constraints, then review
/// and accept the crafted set.
///
/// Presented from the main view's quick-log flow. "Craft" runs `WorkoutPlanner.defaultGoals`
/// on-device (the copy says so explicitly — health details never leave the phone); only "Accept"
/// commits, replacing the store's goals wholesale via `FernletStore.replaceGoals`. Dismissing at
/// either phase changes nothing.
struct GoalsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    /// Kept in sync with `isDirty`'s untouched-level check below.
    @State private var level = "intermediate"
    @State private var interests = ""
    @State private var constraints = ""
    @State private var proposed: [FitnessGoal] = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(proposed.isEmpty ? "Plan goals" : "Review goals")
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

                    if proposed.isEmpty {
                        SheetField("Current level") {
                            FlowLayout(spacing: 8) {
                                ForEach(["beginner", "intermediate", "advanced"], id: \.self) { l in
                                    Button(l.capitalized) { level = l }
                                        .buttonStyle(ChipButtonStyle(selected: level == l))
                                }
                            }
                        }

                        SheetField("Interests") {
                            TextField("strength, running, mobility", text: $interests)
                                .sheetTextInput()
                        }

                        SheetField("Constraints") {
                            TextField("shoulder issues, hotel gyms only", text: $constraints)
                                .sheetTextInput()
                        }

                        Text("Goals are crafted entirely on your device — your health details never leave your phone.")
                            .font(.fernlet(.bubble))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    } else {
                        VStack(spacing: 8) {
                            ForEach(proposed) { goal in
                                GoalRow(goal: goal)
                            }
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            if proposed.isEmpty {
                SheetSaveBar(label: "Craft") {
                    proposed = WorkoutPlanner.defaultGoals(level: level, interests: interests, constraints: constraints)
                }
            } else {
                SheetSaveBar(label: "Accept") {
                    store.replaceGoals(proposed)
                    dismiss()
                }
            }
        }
        .background(Color.parchment)
        .fernletDraftGuard(isDirty: isDirty) { dismiss() }
    }

    /// Anything typed, picked, or crafted but not yet accepted. A crafted-but-unaccepted set counts:
    /// swiping the sheet away there silently discards the plan the user just asked for.
    private var isDirty: Bool {
        !proposed.isEmpty
            || level != "intermediate"
            || !interests.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !constraints.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Quick-log sheet for personal care: the user's tasks grouped by time of day, each a tap-to-toggle
/// completion row.
///
/// Presented from the main view's quick-log flow. Toggles commit to ``FernletStore`` immediately
/// (`togglePersonalCareTask`), so Done only dismisses. The task list itself is authored in
/// ``SettingsSheet``'s personal-care section; this sheet only checks things off.
struct HygieneSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Personal care")
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

                    ForEach(PersonalCareTask.groups, id: \.self) { group in
                        let tasks = store.personalCareTasks.filter { $0.group == group }
                        if !tasks.isEmpty {
                            SheetField(group) {
                                VStack(spacing: 6) {
                                    ForEach(tasks) { task in
                                        let isDone = store.isPersonalCareTaskCompleted(task)
                                        Button { store.togglePersonalCareTask(task) } label: {
                                            HStack {
                                                Label(task.label, systemImage: task.systemImage)
                                                    .foregroundStyle(Color.bark)
                                                Spacer()
                                                if isDone {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .foregroundStyle(Color.moss)
                                                }
                                            }
                                            .padding(14)
                                            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12)
                                                    .stroke(isDone ? Color.moss.opacity(0.3) : Color.bark.opacity(0.08), lineWidth: 1)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        // The checkmark glyph was the only "done" cue and it carries
                                        // no label, so VoiceOver read a finished task identically to
                                        // an unfinished one.
                                        .accessibilityValue(isDone ? "completed" : "not done yet")
                                        .accessibilityAddTraits(isDone ? [.isSelected] : [])
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: "Done") { dismiss() }
        }
        .background(Color.parchment)
    }
}

