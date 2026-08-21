import SwiftUI
import FernletDomainModel
import FernletScoring
import FernletUI

/// Quick-log sheet for hydration: a transactional bottle-count editor (2026-08-21 redesign,
/// artboards 2c/2d).
///
/// The sheet edits a **draft**: the stepper changes only local state, Done (top-right) commits the
/// count via ``FernletStore/setTodayBottleCount(_:)``, and Cancel reverts — an accidental +3
/// followed by Cancel now costs nothing, where the old live-writing sheet made it unrecoverable.
/// Swipe-dismiss is blocked while the draft differs from the committed count, so the only exits are
/// the two explicit ones. Home's one-tap `+1` overlay still writes live; the draft is seeded from
/// the committed count at open, and Done overwrites with the drafted absolute count (clamped 0…30
/// at the store boundary). Bottle size and daily target come from settings and are edited in
/// ``SettingsSheet``, not here.
struct WaterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var store: FernletStore
    /// Nil until seeded on appear so a re-render before `onAppear` shows the committed count.
    @State private var draftCount: Int?

    private var committed: Int { store.day.bottleCount }
    private var draft: Int { draftCount ?? committed }
    private var target: Int { store.settings.hydrationTarget }
    private var totalOz: Int { draft * store.settings.bottleOz }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "Water",
                subtitle: "\(store.settings.bottleOz) oz each · target \(target) bottles",
                onCancel: { dismiss() },
                onDone: {
                    store.setTodayBottleCount(draft)
                    dismiss()
                }
            )
            ScrollView {
                VStack(spacing: 18) {
                    heroCount
                    if dynamicTypeSize.isAccessibilitySize {
                        accessibilityCountLines
                    } else {
                        bottleRow
                    }
                    stepper
                    if !dynamicTypeSize.isAccessibilitySize {
                        totalLine
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(20)
                .padding(.bottom, 10)
            }
        }
        .background(Color.parchment)
        .interactiveDismissDisabled(draft != committed)
        .onAppear { if draftCount == nil { draftCount = committed } }
    }

    /// The hero numeral IS the stepper's value, so the count is stated exactly once (2c).
    private var heroCount: some View {
        VStack(spacing: 2) {
            Text("\(draft)")
                .font(.fernletTimer(size: 56))
                .foregroundStyle(Color.bark)
                .contentTransition(.numericText())
            Text(draft == 1 ? "bottle" : "bottles")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
        }
        .accessibilityElement(children: .ignore)
        // Explicit `Text` so both branches localize — a bare ternary of string literals can land
        // on the non-localizing StringProtocol overload.
        .accessibilityLabel(draft == 1 ? Text("1 bottle") : Text("\(draft) bottles"))
    }

    /// Bottles as a row of glyphs with a goldenrod tick after the target position — the target is
    /// a marker, never a second number masquerading as intake (2c).
    private var bottleRow: some View {
        HStack(spacing: 8) {
            ForEach(0..<glyphCount, id: \.self) { index in
                Image(systemName: "waterbottle")
                    .font(.title2)
                    .foregroundStyle(index < draft ? Color.slate : Color.slate.opacity(0.25))
                if index == target - 1 && target < glyphCount {
                    Capsule()
                        .fill(Color.goldenrod)
                        .frame(width: 3, height: 24)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    /// At accessibility sizes the glyph row gives way to words: the count states itself once and
    /// the size/target caption merges into one line (2d).
    private var accessibilityCountLines: some View {
        VStack(spacing: 4) {
            Text(draft == 1 ? "1 bottle · \(totalOz) oz" : "\(draft) bottles · \(totalOz) oz")
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
            Text(draft >= target
                 ? "\(store.settings.bottleOz) oz each. Target \(target), met."
                 : "\(store.settings.bottleOz) oz each. Target \(target).")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
                .multilineTextAlignment(.center)
        }
    }

    /// Centred stepper directly under the bottle row: plus carries the moss fill because adding is
    /// what people come here to do; minus is the cream sibling, not a destructive control (2c).
    private var stepper: some View {
        HStack(spacing: 22) {
            stepButton(
                systemImage: "minus", accessibilityLabel: "Remove a bottle",
                fill: Color.cream, ink: Color.bark, stroke: 0.12, disabled: draft <= 0
            ) { draftCount = max(draft - 1, 0) }
            stepButton(
                systemImage: "plus", accessibilityLabel: "Add a bottle",
                fill: Color.mossFill, ink: Color.onMoss, stroke: 0, disabled: draft >= 30
            ) { draftCount = min(draft + 1, 30) }
        }
        .frame(maxWidth: .infinity)
    }

    /// One 56pt (64pt at accessibility sizes) circular stepper target.
    private func stepButton(
        systemImage: String,
        accessibilityLabel: LocalizedStringKey,
        fill: Color,
        ink: Color,
        stroke: Double,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let side: CGFloat = dynamicTypeSize.isAccessibilitySize ? 64 : 56
        return Button {
            withAnimation(FernletMotion.fast) { action() }
        } label: {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ink)
                .frame(width: side, height: side)
                .background(fill.opacity(disabled ? 0.45 : 1), in: Circle())
                .overlay(Circle().stroke(Color.bark.opacity(stroke), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .fernletIconButton(accessibilityLabel)
    }

    /// The one italic total line — "Plenty." only once the target is met (2c).
    private var totalLine: some View {
        Text(draft >= target ? "\(totalOz) oz today. Plenty." : "\(totalOz) oz today.")
            .font(.fernlet(.bubble))
            .foregroundStyle(Color.slate)
    }

    /// Enough glyphs to show the target and the count, floored at 4 and capped at 12 (2c keeps the
    /// row decorative — beyond 12 the words carry the number).
    private var glyphCount: Int {
        max(4, min(max(target, draft), 12))
    }
}

/// Quick-log sheet for sleep: a quality picker plus optional hours and note fields.
///
/// Presented from the main view's quick-log flow. Pre-fills from today's existing sleep entry on
/// appear (so reopening edits rather than resets) and commits everything in one
/// `FernletStore.setSleep` call on Save — a swipe-down with unsaved edits raises the shared discard
/// confirmation rather than throwing the draft away. Chrome is the 2026-08-21 template: the
/// draft-guard header carries Cancel and the title; Save commits bottom-right.
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
        .fernletDraftGuard(isDirty: draft != original, title: "Sleep") { dismiss() }
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
/// either phase changes nothing. The draft-guard header carries Cancel and the phase title.
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
        .fernletDraftGuard(
            isDirty: isDirty,
            title: proposed.isEmpty ? "Plan goals" : "Review goals"
        ) { dismiss() }
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
/// (`togglePersonalCareTask`), so this is a live-editing sheet under the 2026-08-21 template: Done
/// sits top-right in the header and is the whole exit — no bottom bar. The task list itself is
/// authored in ``SettingsSheet``'s personal-care section; this sheet only checks things off.
struct HygieneSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Personal care", onDone: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // Typed `CareGroup` rather than the raw `groups` strings: the heading now
                    // renders the localized label while the filter still matches the FROZEN
                    // persisted token, which is the whole point of the fork.
                    ForEach(PersonalCareTask.groupCases) { group in
                        let tasks = store.personalCareTasks.filter { $0.careGroup == group }
                        if !tasks.isEmpty {
                            SheetField(verbatim: group.label) {
                                VStack(spacing: 6) {
                                    ForEach(tasks) { task in
                                        careTaskRow(task)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }
        }
        .background(Color.parchment)
    }

    /// One tap-to-toggle completion row with the checkmark state exposed to VoiceOver.
    private func careTaskRow(_ task: PersonalCareTask) -> some View {
        let isDone = store.isPersonalCareTaskCompleted(task)
        return Button { store.togglePersonalCareTask(task) } label: {
            HStack {
                Label(task.displayLabel, systemImage: task.systemImage)
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
        // The checkmark glyph was the only "done" cue and it carries no label, so VoiceOver read a
        // finished task identically to an unfinished one.
        .accessibilityValue(isDone ? "completed" : "not done yet")
        .accessibilityAddTraits(isDone ? [.isSelected] : [])
    }
}
