import SwiftUI
import FernletDomainModel

struct WaterSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Water")
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(Color.bark)

                    VStack(spacing: 4) {
                        Text("\(store.day.bottleCount)")
                            .font(.system(size: 72, weight: .semibold, design: .serif))
                            .foregroundStyle(Color.bark)
                        Text("\(store.day.bottleCount == 1 ? "bottle" : "bottles") - \(store.day.bottleCount * store.settings.bottleOz) oz total")
                            .font(.callout.italic())
                            .foregroundStyle(Color.slate)
                        Text("\(store.settings.bottleOz) oz each · target \(store.settings.hydrationTarget)")
                            .font(.caption)
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

struct SleepSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    @State private var hours = ""
    @State private var quality: SleepQuality = .ok
    @State private var note = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Sleep")
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(Color.bark)

                    SheetField("Quality") {
                        VStack(spacing: 8) {
                            ForEach(SleepQuality.allCases) { option in
                                Button {
                                    quality = option
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(option.label)
                                                .font(.body.weight(.medium))
                                                .foregroundStyle(Color.bark)
                                            Text(option.description)
                                                .font(.caption)
                                                .foregroundStyle(Color.slate)
                                        }
                                        Spacer()
                                        if quality == option {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(Color.moss)
                                        }
                                    }
                                    .padding(14)
                                    .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(quality == option ? Color.moss.opacity(0.4) : Color.bark.opacity(0.08), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    HStack(alignment: .top, spacing: 12) {
                        SheetField("Hours (optional)") {
                            TextField("7.5", text: $hours)
                                .sheetTextInput()
                        }
                        SheetField("Note (optional)") {
                            TextField("woke up twice...", text: $note)
                                .sheetTextInput()
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }
            .onAppear {
                if let sleep = store.day.sleep {
                    quality = sleep.quality
                    note = sleep.note
                    if let h = sleep.hours { hours = String(h) }
                }
            }

            SheetSaveBar {
                store.setSleep(hours: Double(hours), quality: quality, note: note)
                dismiss()
            }
        }
        .background(Color.parchment)
    }
}

struct GoalsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    @State private var level = "intermediate"
    @State private var interests = ""
    @State private var constraints = ""
    @State private var proposed: [FitnessGoal] = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(proposed.isEmpty ? "Plan goals" : "Review goals")
                        .font(.system(size: 28, weight: .bold, design: .serif))
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

                        Text("Goals are generated locally for now. They mirror the website's structure without sending health data to an external service.")
                            .font(.caption.italic())
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
    }
}

struct HygieneSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Personal care")
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(Color.bark)

                    ForEach(PersonalCareTask.groups, id: \.self) { group in
                        let tasks = store.personalCareTasks.filter { $0.group == group }
                        if !tasks.isEmpty {
                            SheetField(group) {
                                VStack(spacing: 6) {
                                    ForEach(tasks) { task in
                                        Button { store.togglePersonalCareTask(task) } label: {
                                            HStack {
                                                Label(task.label, systemImage: task.systemImage)
                                                    .foregroundStyle(Color.bark)
                                                Spacer()
                                                if store.isPersonalCareTaskCompleted(task) {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .foregroundStyle(Color.moss)
                                                }
                                            }
                                            .padding(14)
                                            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12)
                                                    .stroke(store.isPersonalCareTaskCompleted(task) ? Color.moss.opacity(0.3) : Color.bark.opacity(0.08), lineWidth: 1)
                                            )
                                        }
                                        .buttonStyle(.plain)
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

