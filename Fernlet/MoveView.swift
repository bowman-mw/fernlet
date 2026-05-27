import SwiftUI

struct MoveView: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?
    @State private var path = NavigationPath()
    @State private var displayedWeek: Date = .now
    @State private var allDays: [String: FernletDay] = [:]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        ScreenHeader(title: "Move", subtitle: "Enough to feel it, not enough to drain.")
                        Spacer()
                        HStack(spacing: 10) {
                            HeaderActionButton(title: "Log") { activeSheet = .workout }
                            HeaderActionButton(title: "Suggest") { activeSheet = .workoutSuggestion }
                        }
                    }
                    .padding(.top, 4)

                    WorkoutCalendarCard(
                        displayedWeek: $displayedWeek,
                        allDays: allDays,
                        todayKey: store.todayKey,
                        onDayTapped: { key in path.append(key) }
                    )

                    GoalsCard(store: store, activeSheet: $activeSheet)

                    FernletScrollSection("Today's movement") {
                        if store.day.workouts.isEmpty {
                            EmptyState(text: "No workouts today. No rush.")
                        } else {
                            ForEach(Array(store.day.workouts.enumerated()), id: \.element.id) { index, workout in
                                WorkoutRow(workout: workout)
                                if index < store.day.workouts.count - 1 {
                                    FernletRowDivider()
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.parchment)
            .navigationTitle("")
            .navigationDestination(for: String.self) { dateKey in
                MoveDayDetailView(store: store, dateKey: dateKey)
                    .onDisappear { allDays = store.loadDays() }
            }
        }
        .onAppear { allDays = store.loadDays() }
        .task {
            await store.refreshWorkoutsFromHealth()
            allDays = store.loadDays()
        }
        .onChange(of: store.day.workouts.count) { allDays = store.loadDays() }
    }
}

struct WorkoutSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    var dateKey: String?
    @State private var name = ""
    @State private var exerciseRows: [WorkoutExerciseEntry] = []
    @State private var draftExercise: ExerciseTarget?
    @State private var draftSets = ""
    @State private var draftReps = ""
    @State private var draftWeight = ""
    @State private var draftSpeed = ""
    @State private var draftIncline = ""
    @State private var draftDetails = ""
    @State private var exerciseResetToken = 0
    @State private var rpe = ""
    @State private var duration = ""
    @State private var distance = ""
    @State private var energyKcal = ""
    @State private var effort = ""
    @State private var notes = ""
    @State private var selectedActivityType: WorkoutActivityType?
    @State private var logMode: WorkoutMode = .strengthTraining

    var intensity: WorkoutIntensity {
        guard let value = Double(rpe) else { return .moderate }
        if value >= 8 { return .hard }
        if value >= 5 { return .moderate }
        return .light
    }

    private var inferredCategory: WorkoutType {
        if logMode == .activity, let selectedActivityType {
            return selectedActivityType.fernletCategory
        }
        if !aggregatedMuscleGroups.isEmpty {
            return Workout(
                name: workoutName,
                type: .fullBody,
                exercises: exerciseText,
                rpe: nil,
                notes: "",
                duration: nil,
                muscleGroups: aggregatedMuscleGroups,
                intensity: .moderate
            ).inferredCategory
        }
        return WorkoutExerciseCatalog.inferredCategory(for: "\(name)\n\(exerciseText)")
    }

    private var exerciseText: String {
        exerciseRows.map(\.summary).joined(separator: "\n")
    }

    private var aggregatedMuscleGroups: Set<MuscleGroup> {
        WorkoutSheetRules.aggregatedMuscleGroups(from: exerciseRows)
    }

    private var targetDateKey: String {
        dateKey ?? store.todayKey
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Log workout")
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(Color.bark)

                    SheetField("Workout") {
                        TextField(logMode == .activity ? "Optional, e.g. Saturday ride" : "e.g. Upper strength", text: $name)
                            .sheetTextInput()
                    }

                    WorkoutCategoryPreview(category: inferredCategory)

                    SheetField("Kind") {
                        FlowLayout(spacing: 8) {
                            ForEach(WorkoutMode.allCases) { mode in
                                Button(mode.label) { logMode = mode }
                                    .buttonStyle(ChipButtonStyle(selected: logMode == mode))
                                    .accessibilityIdentifier("workout.kind.\(mode.rawValue)")
                            }
                        }
                    }

                    if logMode == .strengthTraining {
                        WorkoutExerciseBuilder(
                            selectedExercise: $draftExercise,
                            sets: $draftSets,
                            reps: $draftReps,
                            weight: $draftWeight,
                            speed: $draftSpeed,
                            incline: $draftIncline,
                            details: $draftDetails,
                            resetToken: $exerciseResetToken,
                            pickerTitle: logMode.pickerTitle,
                            searchPlaceholder: logMode.searchPlaceholder,
                            mode: logMode,
                            addLabel: logMode.addLabel,
                            onAdd: addDraftExercise
                        )

                        if !exerciseRows.isEmpty {
                            SheetField("Workout exercises") {
                                VStack(spacing: 8) {
                                    ForEach(exerciseRows) { entry in
                                        LoggedExerciseRow(entry: entry) {
                                            exerciseRows.removeAll { $0.id == entry.id }
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        ActivityPickerSection(
                            selectedActivityType: $selectedActivityType,
                            duration: $duration,
                            distance: $distance,
                            energyKcal: $energyKcal,
                            effort: $effort
                        )
                    }

                    if logMode == .strengthTraining {
                        HStack(alignment: .top, spacing: 12) {
                            SheetField("RPE (1–10)") {
                                TextField("7", text: $rpe)
                                    .sheetTextInput()
                            }
                            SheetField("Duration (min)") {
                                TextField("45", text: $duration)
                                    .sheetTextInput()
                            }
                        }
                    }

                    SheetField("Workout notes") {
                        SheetTextEditor(
                            text: $notes,
                            placeholder: "Pain, form issues, stopped early...",
                            minHeight: 100
                        )
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(disabled: saveDisabled) {
                var workout = Workout(
                    name: workoutName,
                    type: inferredCategory,
                    mode: logMode,
                    activityType: logMode == .activity ? selectedActivityType : nil,
                    exercises: exerciseText,
                    rpe: Double(rpe),
                    notes: notes,
                    duration: Int(duration),
                    distanceMiles: logMode == .activity ? Double(distance) : nil,
                    activeEnergyKcal: logMode == .activity ? Double(energyKcal) : nil,
                    effort: Int(effort),
                    muscleGroups: logMode == .strengthTraining ? aggregatedMuscleGroups : [],
                    intensity: intensity
                )
                workout.completedAt = completedAtDate
                workout.loggedAt = completedAtDate
                store.addWorkout(workout, date: targetDateKey)
                dismiss()
            }
        }
        .background(Color.parchment)
        .onChange(of: logMode) { _, _ in
            clearDraftExercise()
        }
    }

    private var workoutName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if logMode == .activity, let selectedActivityType {
            return selectedActivityType.displayName
        }
        return trimmed
    }

    private var saveDisabled: Bool {
        WorkoutSheetRules.saveDisabled(
            mode: logMode,
            workoutName: workoutName,
            exerciseRows: exerciseRows,
            selectedActivityType: selectedActivityType,
            duration: duration,
            distance: distance
        )
    }

    private var completedAtDate: Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        let date = formatter.date(from: targetDateKey) ?? .now
        return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
    }

    private func addDraftExercise() {
        guard let draftExercise else { return }
        let entry = WorkoutExerciseEntry(
            exercise: draftExercise,
            sets: logMode == .strengthTraining ? draftSets : "",
            reps: logMode == .strengthTraining ? draftReps : "",
            weight: draftExercise.inputKind == .strength ? draftWeight : "",
            speed: draftExercise.inputKind == .treadmill ? draftSpeed : "",
            incline: draftExercise.inputKind == .treadmill ? draftIncline : "",
            details: draftDetails
        )
        exerciseRows.append(entry)
        clearDraftExercise()
    }

    private func clearDraftExercise() {
        self.draftExercise = nil
        draftSets = ""
        draftReps = ""
        draftWeight = ""
        draftSpeed = ""
        draftIncline = ""
        draftDetails = ""
        exerciseResetToken += 1
    }
}

enum WorkoutSheetRules {
    static func saveDisabled(
        mode: WorkoutMode,
        workoutName: String,
        exerciseRows: [WorkoutExerciseEntry],
        selectedActivityType: WorkoutActivityType?,
        duration: String,
        distance: String
    ) -> Bool {
        switch mode {
        case .strengthTraining:
            return workoutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || exerciseRows.isEmpty
        case .activity:
            guard selectedActivityType != nil else { return true }
            let parsedDuration = Int(duration.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let parsedDistance = Double(distance.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            return parsedDuration <= 0 && parsedDistance <= 0
        }
    }

    static func aggregatedMuscleGroups(from exerciseRows: [WorkoutExerciseEntry]) -> Set<MuscleGroup> {
        exerciseRows.reduce(into: Set<MuscleGroup>()) { acc, row in
            acc.formUnion(row.exercise.primaryMuscles)
            acc.formUnion(row.exercise.secondaryMuscles)
        }
    }
}

struct QuickExerciseSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    @State private var selectedExercise: ExerciseTarget?
    @State private var sets = ""
    @State private var reps = ""
    @State private var weight = ""
    @State private var speed = ""
    @State private var incline = ""
    @State private var details = ""
    @State private var exerciseResetToken = 0
    @State private var rpe = ""

    private var entry: WorkoutExerciseEntry? {
        selectedExercise.map {
            WorkoutExerciseEntry(exercise: $0, sets: sets, reps: reps, weight: weight, speed: speed, incline: incline, details: details)
        }
    }

    private var intensity: WorkoutIntensity {
        guard let value = Double(rpe) else { return .moderate }
        if value >= 8 { return .hard }
        if value >= 5 { return .moderate }
        return .light
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Quick exercise")
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(Color.bark)

                    WorkoutExerciseBuilder(
                        selectedExercise: $selectedExercise,
                        sets: $sets,
                        reps: $reps,
                        weight: $weight,
                        speed: $speed,
                        incline: $incline,
                        details: $details,
                        resetToken: $exerciseResetToken,
                        pickerTitle: "Exercise",
                        searchPlaceholder: "Search exercise or muscle",
                        showAddButton: false,
                        onAdd: {}
                    )

                    SheetField("RPE (1-10)") {
                        TextField("7", text: $rpe)
                            .sheetTextInput()
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(disabled: entry == nil) {
                guard let entry else { return }
                store.addWorkout(QuickExerciseWorkoutFactory.workout(from: entry, rpe: Double(rpe), intensity: intensity))
                dismiss()
            }
        }
        .background(Color.parchment)
    }
}

enum QuickExerciseWorkoutFactory {
    static func workout(from entry: WorkoutExerciseEntry, rpe: Double?, intensity: WorkoutIntensity) -> Workout {
        Workout(
            name: entry.exercise.name,
            type: WorkoutExerciseCatalog.inferredCategory(for: entry.summary),
            mode: .strengthTraining,
            exercises: entry.summary,
            rpe: rpe,
            notes: "",
            duration: nil,
            muscleGroups: entry.exercise.primaryMuscles.union(entry.exercise.secondaryMuscles),
            intensity: intensity
        )
    }
}

struct WorkoutSuggestionSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    @State private var energy: WorkoutIntensity = .moderate
    @State private var context = ""
    @State private var suggestion: WorkoutSuggestion?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(suggestion == nil ? "Suggest workout" : "Suggestion")
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(Color.bark)

                    if let suggestion {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(suggestion.name)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color.bark)
                            Text(suggestion.exercises)
                                .foregroundStyle(Color.bark)
                            Text(suggestion.notes)
                                .font(.callout.italic())
                                .foregroundStyle(Color.slate)
                                .fernletWrappingText()
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
                    } else {
                        SheetField("How are you feeling?") {
                            FlowLayout(spacing: 8) {
                                ForEach(WorkoutIntensity.allCases) { intensity in
                                    Button(intensity.rawValue.capitalized) { energy = intensity }
                                        .buttonStyle(ChipButtonStyle(selected: energy == intensity))
                                }
                            }
                        }

                        SheetField("Goal") {
                            Text(store.settings.selectedGoal.displayName)
                                .sheetTextInput()
                                .foregroundStyle(Color.bark)
                        }

                        SheetField("Anything else?") {
                            TextField("Context...", text: $context)
                                .sheetTextInput()
                        }

                        Text(FernletVoice.message(for: .workoutSuggestionUnavailable))
                            .font(.caption.italic())
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            if let suggestion {
                SheetSaveBar(label: "Mark done") {
                    store.addWorkout(suggestion.workout(intensity: energy))
                    dismiss()
                }
            } else {
                SheetSaveBar(label: "Suggest") {
                    self.suggestion = WorkoutSuggestionLibrary.suggestions(
                        for: store.settings.selectedGoal, intensity: energy
                    ).first
                }
            }
        }
        .background(Color.parchment)
    }
}

struct WorkoutRow: View {
    var workout: Workout

    private var category: WorkoutType {
        WorkoutExerciseCatalog.inferredCategory(for: workout)
    }

    private var targetSummary: String {
        WorkoutExerciseCatalog.targetSummary(for: workout)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(workout.name).font(.headline)
                Spacer()
                if let rpe = workout.rpe {
                    Text("RPE \(rpe, specifier: "%.1g")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(rpe >= 8 ? Color.terracotta : Color.moss)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background((rpe >= 8 ? Color.terracotta : Color.moss).opacity(0.12), in: Capsule())
                }
            }
            HStack(spacing: 12) {
                Text(category.rawValue)
                    .foregroundStyle(category.color)
                if let duration = workout.duration { Text("\(duration) min") }
                Text(workout.intensity.rawValue)
            }
            .font(.caption)
            .foregroundStyle(Color.slate)
            if !workout.exerciseLines.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(workout.exerciseLines.enumerated()), id: \.offset) { _, exercise in
                        WorkoutExerciseRow(exercise: exercise)
                    }
                }
            }
            if !targetSummary.isEmpty {
                Text("Targets: \(targetSummary)")
                    .font(.caption)
                    .foregroundStyle(Color.slate)
            }
            if !workout.notes.isEmpty {
                Text(workout.notes)
                    .font(.caption.italic())
                    .foregroundStyle(Color.slate)
            }
        }
        .padding(.vertical, 4)
    }
}

struct WorkoutExerciseRow: View {
    var exercise: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.moss)
            Text(exercise)
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.bark)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }
}

struct WorkoutCategoryPreview: View {
    var category: WorkoutType

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(category.color)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text("Category")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.slate)
                Text(category.rawValue)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.bark)
            }
            Spacer()
            Text("Auto")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(category.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(category.color.opacity(0.12), in: Capsule())
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }
}

struct WorkoutExerciseEntry: Identifiable, Equatable {
    var id = UUID()
    var exercise: ExerciseTarget
    var sets: String
    var reps: String
    var weight: String
    var speed: String
    var incline: String
    var details: String

    var summary: String {
        var parts: [String] = [exercise.name]
        let cleanSets = sets.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanReps = reps.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanWeight = weight.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSpeed = speed.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanIncline = incline.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)

        switch exercise.inputKind {
        case .strength:
            if !cleanSets.isEmpty && !cleanReps.isEmpty {
                parts.append("\(cleanSets)x\(cleanReps)")
            } else if !cleanSets.isEmpty {
                parts.append("\(cleanSets) sets")
            } else if !cleanReps.isEmpty {
                parts.append("\(cleanReps) reps")
            }
            if !cleanWeight.isEmpty { parts.append("@\(cleanWeight)") }
        case .treadmill:
            if !cleanSpeed.isEmpty { parts.append("\(cleanSpeed) mph") }
            if !cleanIncline.isEmpty { parts.append("\(cleanIncline)% incline") }
        case .none:
            break
        }
        if !cleanDetails.isEmpty { parts.append(cleanDetails) }
        return parts.joined(separator: " ")
    }
}

struct WorkoutExerciseBuilder: View {
    @Binding var selectedExercise: ExerciseTarget?
    @Binding var sets: String
    @Binding var reps: String
    @Binding var weight: String
    @Binding var speed: String
    @Binding var incline: String
    @Binding var details: String
    @Binding var resetToken: Int
    var pickerTitle = "Exercise"
    var searchPlaceholder = "Search exercise or muscle"
    var mode: WorkoutMode = .strengthTraining
    var addLabel = "Add exercise"
    var showAddButton = true
    var onAdd: () -> Void

    private var inputKind: ExerciseInputKind {
        selectedExercise?.inputKind ?? .strength
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ExerciseSearchPicker(
                selectedExercise: $selectedExercise,
                resetToken: $resetToken,
                title: pickerTitle,
                placeholder: searchPlaceholder
            )

            switch inputKind {
            case .strength:
                HStack(alignment: .top, spacing: 12) {
                    SheetField("Sets") {
                        TextField("3", text: $sets)
                            .keyboardType(.numberPad)
                            .sheetTextInput()
                    }
                    SheetField("Reps") {
                        TextField("8", text: $reps)
                            .keyboardType(.numberPad)
                            .sheetTextInput()
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    SheetField("Weight") {
                        TextField("30 lb", text: $weight)
                            .sheetTextInput()
                    }
                    SheetField("Details") {
                        TextField("tempo, distance, incline", text: $details)
                        .sheetTextInput()
                    }
                }

                SheetField("Details") {
                    TextField("tempo, form note", text: $details)
                        .sheetTextInput()
                }
            case .treadmill:
                HStack(alignment: .top, spacing: 12) {
                    SheetField("Speed") {
                        TextField("5.5 mph", text: $speed)
                            .keyboardType(.decimalPad)
                            .sheetTextInput()
                    }
                    SheetField("Incline") {
                        TextField("2", text: $incline)
                            .keyboardType(.decimalPad)
                            .sheetTextInput()
                    }
                }

                SheetField("Details") {
                    TextField("intervals, distance, notes", text: $details)
                        .sheetTextInput()
                }
            case .none:
                EmptyView()
            }

            if showAddButton {
                Button(action: onAdd) {
                    Label(addLabel, systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selectedExercise == nil ? Color.slate.opacity(0.45) : Color.moss)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(selectedExercise == nil)
            }
        }
    }
}

struct ExerciseSearchPicker: View {
    @Binding var selectedExercise: ExerciseTarget?
    @Binding var resetToken: Int
    @State private var query = ""
    var title = "Exercise"
    var placeholder = "Search exercise or muscle"

    private var results: [ExerciseTarget] {
        Array(WorkoutExerciseCatalog.search(query).prefix(8))
    }

    var body: some View {
        SheetField(title) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.slate)
                    TextField(placeholder, text: $query)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled(false)
                        .accessibilityIdentifier("exercise.search")
                }
                .sheetTextInput()

                if let selectedExercise {
                    ExerciseSearchResultRow(exercise: selectedExercise, isSelected: true) {
                        self.selectedExercise = nil
                    }
                }

                if selectedExercise == nil {
                    VStack(spacing: 6) {
                        ForEach(results) { exercise in
                            ExerciseSearchResultRow(exercise: exercise, isSelected: false) {
                                selectedExercise = exercise
                                query = exercise.name
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: resetToken) { _, _ in
            query = ""
        }
    }
}

struct ExerciseSearchResultRow: View {
    var exercise: ExerciseTarget
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(exercise.category.color)
                    .frame(width: 9, height: 9)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.bark)
                    Text("\(exercise.category.rawValue) - \(exercise.muscles.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(Color.slate)
                }
                Spacer()
                Image(systemName: isSelected ? "xmark.circle" : "plus.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.slate : Color.moss)
            }
            .padding(10)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.bark.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct LoggedExerciseRow: View {
    var entry: WorkoutExerciseEntry
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.exercise.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.bark)
                Text(entry.summary.replacingOccurrences(of: entry.exercise.name, with: "").trimmingCharacters(in: .whitespaces))
                    .font(.caption)
                    .foregroundStyle(Color.slate)
                Text(entry.exercise.muscles.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(entry.exercise.category.color)
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.slate)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }
}

struct WorkoutCalendarCard: View {
    @Binding var displayedWeek: Date
    var allDays: [String: FernletDay]
    var todayKey: String
    var onDayTapped: (String) -> Void

    private var cal: Calendar { .current }

    var body: some View {
        let model = WorkoutWeekModel(date: displayedWeek, allDays: allDays, todayKey: todayKey)
        return FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    Button {
                        displayedWeek = cal.date(byAdding: .weekOfYear, value: -1, to: displayedWeek) ?? displayedWeek
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.slate)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)

                    Text(model.weekTitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.bark)
                        .frame(maxWidth: .infinity)

                    let isCurrentWeek = cal.isDate(displayedWeek, equalTo: .now, toGranularity: .weekOfYear)
                    Button {
                        if !isCurrentWeek {
                            displayedWeek = cal.date(byAdding: .weekOfYear, value: 1, to: displayedWeek) ?? displayedWeek
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(isCurrentWeek ? Color.slate.opacity(0.25) : Color.slate)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .disabled(isCurrentWeek)
                }

                HStack(spacing: 6) {
                    ForEach(model.cells) { cell in
                        WorkoutCalendarCell(cell: cell) {
                            if !cell.isFuture {
                                onDayTapped(cell.dateKey)
                            }
                        }
                    }
                }
                workoutLegend
            }
        }
    }

    private var workoutLegend: some View {
        HStack {
            ForEach(WorkoutType.allCases) { type in
                HStack(spacing: 4) {
                    Circle().fill(type.color).frame(width: 8, height: 8)
                    Text(type.rawValue).font(.caption2).foregroundStyle(Color.slate)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

struct WorkoutCalendarCell: View {
    var cell: WorkoutWeekCell
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                Text(cell.weekdayText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.slate)
                RoundedRectangle(cornerRadius: 8)
                    .fill(cell.fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(cell.isToday ? Color.moss : Color.clear, lineWidth: 1.5)
                    )
                    .overlay {
                        VStack(spacing: 4) {
                            Text("\(cell.day)")
                                .font(.caption.weight(cell.isToday ? .bold : .medium))
                                .foregroundStyle(
                                    cell.isFuture ? Color.bark.opacity(0.28)
                                        : cell.isToday ? Color.moss
                                        : Color.bark.opacity(0.68)
                                )
                            if !cell.categories.isEmpty {
                                HStack(spacing: 2) {
                                    ForEach(Array(cell.categories.prefix(3).enumerated()), id: \.offset) { _, category in
                                        Circle()
                                            .fill(category.color)
                                            .frame(width: 5, height: 5)
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: 46)
                Text(cell.summaryText)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(cell.categories.isEmpty ? Color.slate.opacity(0.45) : Color.slate)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .disabled(cell.isFuture)
        .accessibilityLabel(cell.accessibilityLabel)
    }
}

struct WorkoutWeekCell: Identifiable {
    let id = UUID()
    var day: Int
    var dateKey: String
    var weekdayText: String
    var categories: [WorkoutType]
    var workoutCount: Int
    var isToday: Bool
    var isFuture: Bool = false

    var fill: Color {
        if isFuture { return Color.softTaupe.opacity(0.05) }
        if let first = categories.first { return first.color.opacity(isToday ? 0.34 : 0.24) }
        if isToday { return Color.moss.opacity(0.18) }
        return Color.softTaupe.opacity(0.16)
    }

    var summaryText: String {
        if workoutCount == 0 { return "Rest" }
        return workoutCount == 1 ? "1 log" : "\(workoutCount) logs"
    }

    var accessibilityLabel: String {
        let categoryText = categories.map(\.rawValue).joined(separator: ", ")
        if isFuture { return "\(weekdayText), day \(day)" }
        if categoryText.isEmpty { return isToday ? "Today, day \(day), no workouts" : "\(weekdayText), day \(day), no workouts" }
        return isToday ? "Today, day \(day), \(categoryText)" : "\(weekdayText), day \(day), \(categoryText)"
    }
}

struct WorkoutWeekModel {
    let weekTitle: String
    let cells: [WorkoutWeekCell]

    init(date: Date, allDays: [String: FernletDay], todayKey: String, calendar: Calendar = .current) {
        let weekInterval = calendar.dateInterval(of: .weekOfYear, for: date)
        assert(weekInterval != nil, "week interval required")
        let start = weekInterval?.start ?? date
        let dates = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)

        if let first = dates.first, let last = dates.last {
            weekTitle = "\(first.formatted(.dateTime.month(.abbreviated).day())) - \(last.formatted(.dateTime.month(.abbreviated).day()))"
        } else {
            weekTitle = date.formatted(.dateTime.month(.abbreviated).day())
        }

        cells = dates.map { date in
            let key = formatter.string(from: date)
            let workouts = allDays[key]?.workouts ?? []
            let categories = workouts.reduce(into: [WorkoutType]()) { result, workout in
                let category = WorkoutExerciseCatalog.inferredCategory(for: workout)
                if !result.contains(category) { result.append(category) }
            }
            return WorkoutWeekCell(
                day: calendar.component(.day, from: date),
                dateKey: key,
                weekdayText: date.formatted(.dateTime.weekday(.narrow)),
                categories: categories,
                workoutCount: workouts.count,
                isToday: key == todayKey,
                isFuture: key > todayKey
            )
        }
    }
}

struct MoveDayDetailView: View {
    var store: FernletStore
    var dateKey: String
    @State private var showWorkoutSheet = false

    private var day: FernletDay {
        store.loadDay(for: dateKey)
    }

    private var navigationTitle: String {
        if dateKey == store.todayKey { return "Today" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        let date = formatter.date(from: dateKey) ?? .now
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(title: navigationTitle, subtitle: "Movement only.")
                FernletScrollSection("Workouts") {
                    if day.workouts.isEmpty {
                        EmptyState(text: "No workouts logged")
                    } else {
                        ForEach(Array(day.workouts.enumerated()), id: \.element.id) { index, workout in
                            WorkoutRow(workout: workout)
                            if index < day.workouts.count - 1 { FernletRowDivider() }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color.parchment)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showWorkoutSheet = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                        Text("Log")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.bark)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.cream.opacity(0.9), in: Capsule())
                    .overlay(Capsule().stroke(Color.bark.opacity(0.10), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showWorkoutSheet) {
            WorkoutSheet(store: store, dateKey: dateKey)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
    }
}

struct GoalsCard: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Goals")
                    Spacer()
                    Button(store.goals.isEmpty ? "Plan goals" : "Recraft") { activeSheet = .goals }
                        .font(.caption.weight(.semibold))
                }
                if store.goals.isEmpty {
                    Button { activeSheet = .goals } label: {
                        Text("Tap to craft fitness goals")
                            .font(.callout.italic())
                            .foregroundStyle(Color.slate)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.bark.opacity(0.14), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                            )
                    }
                    .buttonStyle(.plain)
                } else {
                    ForEach(store.goals) { goal in
                        GoalRow(goal: goal)
                    }
                }
            }
        }
    }
}

struct GoalRow: View {
    var goal: FitnessGoal

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(goal.goal).font(.subheadline.weight(.semibold))
            Text("\(goal.timeframe) - \(goal.metric)")
                .font(.caption)
                .foregroundStyle(Color.slate)
            if !goal.milestones.isEmpty {
                Text(goal.milestones.joined(separator: " - "))
                    .font(.caption2)
                    .foregroundStyle(Color.moss)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.parchment, in: RoundedRectangle(cornerRadius: 10))
    }
}
