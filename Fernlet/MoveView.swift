import SwiftUI
import LocalPersistence
import FernletFoundation
import FernletDomainModel
import AIProviders
import PrivateMediaStore

struct MoveView: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?
    @Binding var isTabBarCompact: Bool
    @Binding var tabResetToken: Int
    @State private var path = NavigationPath()
    @State private var displayedWeek: Date = .now
    @State private var allDays: [String: FernletDay] = [:]
    @State private var showingLocations = false
    @State private var progressPhotos: [ProgressPhotoRecord] = []
    // Surfaced when a progress-photo capture couldn't be sealed to disk (fail-closed store returned nil):
    // the photo would otherwise vanish silently. A clear per-capture alert, never a silent drop.
    @State private var showPhotoSaveFailedAlert = false

    private var hasRecentCoachInteraction: Bool {
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: .now) ?? .now
        return store.trainerAuditEvents.contains { event in
            event.timestamp >= cutoff && [.peerAccepted, .envelopeReceived, .envelopeSent].contains(event.kind)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        ScreenHeader(title: "Move", subtitle: "Enough to feel it, not enough to drain.", identifier: "screen.move")
                        Spacer()
                        HStack(spacing: 10) {
                            HeaderActionButton(title: "Log") { activeSheet = .workout }
                            HeaderActionButton(title: "Suggest") { activeSheet = .workoutSuggestion }
                        }
                    }
                    .padding(.top, 4)

                    MoveContextStrip(
                        store: store,
                        onEditGoal: { activeSheet = .goals },
                        onEditSpace: { showingLocations = true }
                    )

                    WorkoutCalendarCard(
                        displayedWeek: $displayedWeek,
                        allDays: allDays,
                        todayKey: store.todayKey,
                        selectedGoal: store.settings.selectedGoal,
                        goals: store.goals,
                        showsPlanSourceTag: hasRecentCoachInteraction,
                        onDayTapped: { key in path.append(key) }
                    )

                    FernletScrollSection("Today's movement") {
                        if store.day.plannedWorkouts.isEmpty && store.day.workouts.isEmpty {
                            EmptyState(text: "No workouts today. No rush.")
                        } else {
                            ForEach(Array(store.day.plannedWorkouts.enumerated()), id: \.element.id) { index, plannedWorkout in
                                PlannedWorkoutRow(
                                    plannedWorkout: plannedWorkout,
                                    showsPlanSourceTag: hasRecentCoachInteraction,
                                    showsCompleteAction: true,
                                    onComplete: {
                                        store.completePlannedWorkout(plannedWorkout, date: store.todayKey)
                                        allDays = store.loadDays()
                                    },
                                    onEdit: {
                                        path.append(store.todayKey)
                                    },
                                    onDelete: {
                                        store.deletePlannedWorkout(plannedWorkout, date: store.todayKey)
                                        allDays = store.loadDays()
                                    }
                                )
                                if index < store.day.plannedWorkouts.count - 1 || !store.day.workouts.isEmpty {
                                    FernletRowDivider()
                                }
                            }
                            ForEach(Array(store.day.workouts.enumerated()), id: \.element.id) { index, workout in
                                WorkoutRow(workout: workout)
                                if index < store.day.workouts.count - 1 {
                                    FernletRowDivider()
                                }
                            }
                        }
                    }

                    #if canImport(UIKit)
                    ProgressPhotoSection(
                        records: progressPhotos,
                        loadData: { store.progressPhotoData(for: $0) },
                        onCapture: { image in
                            if store.addProgressPhoto(image) == nil {
                                showPhotoSaveFailedAlert = true
                            }
                            progressPhotos = store.progressPhotoRecords()
                        },
                        onCaptureData: { data, capturedAt in
                            // Library pick: seal the raw bytes (bounded ImageIO decode) and stamp the
                            // photo's own date when EXIF carried one, else default to now.
                            if store.addProgressPhoto(data: data, capturedAt: capturedAt ?? Date()) == nil {
                                showPhotoSaveFailedAlert = true
                            }
                            progressPhotos = store.progressPhotoRecords()
                        },
                        onOpen: { record in path.append(record) }
                    )
                    #endif
                }
                .padding(20)
            }
            .fernletTabBarCompaction($isTabBarCompact, resetToken: $tabResetToken)
            .background(Color.parchment)
            .navigationTitle("")
            .navigationDestination(for: String.self) { dateKey in
                MoveDayDetailView(store: store, dateKey: dateKey, showsPlanSourceTag: hasRecentCoachInteraction)
                    .onDisappear { allDays = store.loadDays() }
            }
            #if canImport(UIKit)
            .navigationDestination(for: ProgressPhotoRecord.self) { record in
                // The detail view refreshes us itself after each persisted change (save → refresh in one
                // step), so there's no racing `onDisappear` and no stale caption on return.
                ProgressPhotoDetailView(
                    store: store,
                    record: record,
                    onChanged: { progressPhotos = store.progressPhotoRecords() }
                )
            }
            #endif
        }
        .onAppear {
            allDays = store.loadDays()
            progressPhotos = store.progressPhotoRecords()
        }
        .alert("Couldn't save this photo", isPresented: $showPhotoSaveFailedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Fernlet couldn't seal this photo to your private timeline. Please try again.")
        }
        .sheet(isPresented: $showingLocations) {
            WorkoutLocationSetupView(store: store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
        .task {
            await store.refreshWorkoutsFromHealth()
            allDays = store.loadDays()
        }
        .onChange(of: store.day.workouts.count) { allDays = store.loadDays() }
        .onChange(of: store.day.plannedWorkouts.count) { allDays = store.loadDays() }
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
        if logMode == .activity {
            guard let value = Double(effort) else { return .moderate }
            if value >= 8 { return .hard }
            if value >= 5 { return .moderate }
            return .light
        }
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
                        .font(.fernlet(.displayMedium))
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
                    exercises: logMode == .strengthTraining ? exerciseText : "",
                    rpe: logMode == .strengthTraining ? Double(rpe) : nil,
                    notes: notes,
                    duration: Int(duration),
                    distanceMiles: logMode == .activity ? Double(distance) : nil,
                    activeEnergyKcal: logMode == .activity ? Double(energyKcal) : nil,
                    effort: logMode == .activity ? Int(effort) : nil,
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
        guard targetDateKey != store.todayKey else { return .now }
        let date = FernletDate.date(fromDayKey: targetDateKey) ?? .now
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
                        .font(.fernlet(.displayMedium))
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
    @State private var dayPlan: WorkoutProgram.DayPlan?
    @State private var showingSetup = false
    @State private var adjustRequest = ""
    @State private var isAdjusting = false
    @State private var didApplyReadiness = false
    // Set when the user taps "Start guided workout"; presents the guided runner sheet. nil = closed.
    @State private var guidedSession: WorkoutProgram.SessionSuggestion?
    // Sessions already logged through the guided runner. The save bar and the guided-workout button
    // both skip these, so a guided session can't be logged a second time on a multi-session day.
    @State private var guidedCompletedSessionIDs: Set<UUID> = []

    private var aiAdjustAvailable: Bool {
        store.settings.aiStatus != .off && FoodSelectionAvailability.isFoundationModelAvailable
    }

    /// The session in the current plan worth *guiding* through — the first with real, set-based
    /// exercises that hasn't already been guided to completion. Pure cardio/mobility/rest days have
    /// only descriptor lines (sets == 0) and return nil, so the guided button is absent (the
    /// retroactive "Mark done" path still works).
    private func guidableSession(in plan: WorkoutProgram.DayPlan) -> WorkoutProgram.SessionSuggestion? {
        plan.sessions.first { session in
            !guidedCompletedSessionIDs.contains(session.id)
                && session.exercises.contains { $0.fromCatalog && $0.sets >= 1 }
        }
    }

    /// Maps the derived intensity-readiness signal to a recommended workout intensity, if present.
    private var recommendedIntensity: WorkoutIntensity? {
        guard let r = store.derivedSignals.first(where: { $0.signalName == "intensityReadiness" }) else { return nil }
        switch r.value {
        case "ready for hard": return .hard
        case "ready for light": return .light
        case "ready for moderate": return .moderate
        default: return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(dayPlan == nil ? "Suggest workout" : "Today's session")
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

                    if let dayPlan {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("\(dayPlan.splitName) · \(dayPlan.dayTitle)")
                                .font(.fernlet(.labelSmall))
                                .foregroundStyle(Color.moss)
                            ForEach(dayPlan.sessions) { session in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(session.suggestion.name)
                                        .font(.fernlet(.headerMedium))
                                        .foregroundStyle(Color.bark)
                                    Text(session.suggestion.exercises)
                                        .foregroundStyle(Color.bark)
                                    Text(session.suggestion.notes)
                                        .font(.fernlet(.bubble))
                                        .foregroundStyle(Color.slate)
                                        .fernletWrappingText()
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
                            }

                            if let guidable = guidableSession(in: dayPlan) {
                                Button {
                                    guidedSession = guidable
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "play.circle.fill")
                                            .font(.body.weight(.semibold))
                                        Text("Start guided workout")
                                            .font(.fernlet(.label))
                                    }
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 15)
                                    .background(Color.moss, in: RoundedRectangle(cornerRadius: 14))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("workout.startGuided")

                                Text("We'll walk you through it set by set and time your rests. Or mark it done below if you'd rather log it yourself.")
                                    .font(.fernlet(.bubble))
                                    .foregroundStyle(Color.slate)
                                    .fernletWrappingText()
                            }

                            if aiAdjustAvailable {
                                SheetField("Adjust") {
                                    VStack(alignment: .leading, spacing: 8) {
                                        TextField("e.g. swap the squat, 30 minutes, no barbell", text: $adjustRequest)
                                            .sheetTextInput()
                                            .disabled(isAdjusting)
                                        Button {
                                            runAdjustment()
                                        } label: {
                                            HStack(spacing: 8) {
                                                if isAdjusting { ProgressView().controlSize(.small) }
                                                Image(systemName: "wand.and.stars")
                                                    .font(.caption.weight(.semibold))
                                                Text(isAdjusting ? "Adjusting…" : "Adjust with AI")
                                                    .font(.fernlet(.label))
                                            }
                                            .foregroundStyle(Color.moss)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 9)
                                            .background(Color.moss.opacity(0.12), in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(isAdjusting || adjustRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    }
                                }
                            }
                        }
                    } else {
                        SheetField("How are you feeling?") {
                            VStack(alignment: .leading, spacing: 8) {
                                if let rec = recommendedIntensity {
                                    Text("Today's readiness suggests \(rec.rawValue.lowercased()).")
                                        .font(.fernlet(.bodySmall))
                                        .foregroundStyle(Color.slate)
                                }
                                FlowLayout(spacing: 8) {
                                    ForEach(WorkoutIntensity.allCases) { intensity in
                                        Button(intensity.rawValue.capitalized) { energy = intensity }
                                            .buttonStyle(ChipButtonStyle(selected: energy == intensity))
                                    }
                                }
                            }
                            .onAppear {
                                guard !didApplyReadiness else { return }
                                didApplyReadiness = true
                                if let rec = recommendedIntensity { energy = rec }
                            }
                        }

                        SheetField("Goal") {
                            Text(store.settings.selectedGoal.displayName)
                                .sheetTextInput()
                                .foregroundStyle(Color.bark)
                        }

                        SheetField("Anything else?") {
                            TextField("e.g. sore left knee, short on time", text: $context)
                                .sheetTextInput()
                        }

                        Button {
                            showingSetup = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "dumbbell")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.moss)
                                Text("Equipment & limits · \(store.settings.activeWorkoutLocation.name)")
                                    .font(.fernlet(.label))
                                    .foregroundStyle(Color.bark)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.82)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.slate)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.cream.opacity(0.86), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.bark.opacity(0.08), lineWidth: 1))
                        }
                        .buttonStyle(.plain)

                        Text("Built from your \(store.settings.selectedGoal.displayName.lowercased()) split, your equipment, and anything you note here.")
                            .font(.fernlet(.bubble))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            if let dayPlan {
                // Sessions the guided runner already logged are excluded, so "Mark all done" after
                // a guided session only logs what's actually left.
                let remainingSessions = dayPlan.sessions.filter { !guidedCompletedSessionIDs.contains($0.id) }
                SheetSaveBar(label: remainingSessions.count > 1 ? "Mark all done" : "Mark done") {
                    for session in remainingSessions {
                        store.addWorkout(session.workout(intensity: energy))
                        store.recordCompletedExercises(session.catalogExerciseNames)
                    }
                    dismiss()
                }
            } else {
                SheetSaveBar(label: "Suggest") {
                    self.dayPlan = store.workoutDayPlan(intensity: energy, context: context)
                }
            }
        }
        .background(Color.parchment)
        .sheet(isPresented: $showingSetup) {
            WorkoutSetupSheet(store: store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
        .sheet(item: $guidedSession, onDismiss: {
            // Every session in the plan went through the runner (always the case on a
            // single-session day once it's guided) → nothing left to mark done, so close the whole
            // Suggest flow. Otherwise stay up so the remaining sessions can be marked.
            if let plan = dayPlan, !plan.sessions.isEmpty,
               plan.sessions.allSatisfy({ guidedCompletedSessionIDs.contains($0.id) }) {
                dismiss()
            }
        }) { session in
            GuidedWorkoutSheet(
                session: session,
                goal: store.settings.selectedGoal,
                sessionsRemain: dayPlan.map { plan in
                    plan.sessions.contains { $0.id != session.id && !guidedCompletedSessionIDs.contains($0.id) }
                } ?? false,
                onComplete: {
                    // Reuse the exact retroactive "Mark done" logging path so the guided session
                    // counts identically. The runner's one-shot latch keeps this from re-firing,
                    // and recording the ID keeps the save bar from logging this session again.
                    // Dismissal happens when the user closes the done screen.
                    store.addWorkout(session.workout(intensity: energy))
                    store.recordCompletedExercises(session.catalogExerciseNames)
                    guidedCompletedSessionIDs.insert(session.id)
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(20)
        }
    }

    private func runAdjustment() {
        guard let plan = dayPlan, isAdjusting == false else { return }
        let request = adjustRequest
        isAdjusting = true
        Task {
            let adjusted = await store.adjustWorkoutDayPlan(plan, request: request)
            dayPlan = adjusted
            adjustRequest = ""
            isAdjusting = false
        }
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
                Text(workout.name).font(.fernlet(.headerMedium))
                Spacer()
                if let rpe = workout.rpe {
                    Text("RPE \(rpe, specifier: "%.1g")")
                        .font(.fernlet(.stat))
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
            .font(.fernlet(.labelSmall))
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
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
            }
            if !workout.notes.isEmpty {
                Text(workout.notes)
                    .font(.fernlet(.bubble))
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
                .font(.fernlet(.body))
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
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                Text(category.rawValue)
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
            }
            Spacer()
            Text("Auto")
                .font(.fernlet(.labelSmall))
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

/// The three look-alike cream boxes above the calendar — a navigational goal, a passive readiness
/// band, and a navigational location — collapse into one thin two-segment context strip
/// (Goal · Space). Readiness, already surfaced on Home and inside Suggest, no longer claims a band
/// or caption here.
struct MoveContextStrip: View {
    var store: FernletStore
    var onEditGoal: () -> Void
    var onEditSpace: () -> Void

    /// Goal segment value, mirroring the prior summary logic; nil renders the empty "Tap to plan"
    /// treatment so a first-run goal reads as an invitation, not a set value.
    private var goalValue: String? {
        if let goal = store.goals.first {
            return "\(goal.goal) · \(goal.timeframe)"
        }
        return store.settings.selectedGoal == .exploring ? nil : store.settings.selectedGoal.displayName
    }

    private var spaceValue: String {
        "\(store.settings.activeWorkoutLocation.name) · \(store.settings.activeWorkoutLocation.ownedEquipment.count) items"
    }

    var body: some View {
        HStack(spacing: 0) {
            MoveContextSegment(
                icon: "target",
                label: "Goal",
                value: goalValue,
                emptyPrompt: "Tap to plan",
                action: onEditGoal
            )
            .accessibilityLabel("Edit movement goals")

            Rectangle()
                .fill(Color.bark.opacity(0.10))
                .frame(width: 1)
                .padding(.vertical, 10)

            MoveContextSegment(
                icon: "mappin.and.ellipse",
                label: "Space",
                value: spaceValue,
                emptyPrompt: "Set up your space",
                action: onEditSpace
            )
            .accessibilityLabel(spaceValue)
            // Stable id: the label is the location's NAME, which the user can now rename, so a test that
            // matched on it would break the moment it exercised the rename it's there to check.
            .accessibilityIdentifier("move.space")
        }
        .background(Color.cream.opacity(0.86), in: RoundedRectangle(cornerRadius: FernletMetrics.radiusSm))
        .overlay(RoundedRectangle(cornerRadius: FernletMetrics.radiusSm).stroke(Color.bark.opacity(0.08), lineWidth: 1))
    }
}

/// One tappable half of the context strip: a small uppercase label over a value line, with a
/// leading icon. Each segment truncates independently; the icon never clips.
private struct MoveContextSegment: View {
    var icon: String
    var label: String
    /// The set value; nil shows the italic empty prompt.
    var value: String?
    var emptyPrompt: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(value == nil ? Color.slate.opacity(0.5) : Color.moss)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label.uppercased())
                        .font(.fernlet(.labelSmall))
                        .tracking(0.6)
                        .foregroundStyle(value == nil ? Color.slate.opacity(0.5) : Color.slate)
                    if let value {
                        Text(value)
                            .font(.fernlet(.label))
                            .foregroundStyle(Color.bark)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Text(emptyPrompt)
                            .font(.fernlet(.bubble))
                            .foregroundStyle(Color.slate)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

                SheetField("Weight") {
                    TextField("30 lb", text: $weight)
                        .sheetTextInput()
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
                        .font(.fernlet(.label))
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
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                    Text("\(exercise.category.rawValue) - \(exercise.muscles.joined(separator: ", "))")
                        .font(.fernlet(.labelSmall))
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
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                Text(entry.summary.replacingOccurrences(of: entry.exercise.name, with: "").trimmingCharacters(in: .whitespaces))
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                Text(entry.exercise.muscles.joined(separator: ", "))
                    .font(.fernlet(.labelSmall))
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

struct EditablePlannedExerciseRow: View {
    @Binding var entry: WorkoutExerciseEntry
    var onRemove: () -> Void
    var onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.exercise.name)
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                    Text(entry.exercise.muscles.joined(separator: ", "))
                        .font(.fernlet(.labelSmall))
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

            switch entry.exercise.inputKind {
            case .strength:
                HStack(alignment: .top, spacing: 10) {
                    editableField("Sets", text: $entry.sets, keyboard: .numberPad)
                    editableField("Reps", text: $entry.reps, keyboard: .numberPad)
                    editableField("Weight", text: $entry.weight)
                }
            case .treadmill:
                HStack(alignment: .top, spacing: 10) {
                    editableField("Speed", text: $entry.speed, keyboard: .decimalPad)
                    editableField("Incline", text: $entry.incline, keyboard: .decimalPad)
                }
            case .none:
                EmptyView()
            }

            editableField("Details", text: $entry.details)
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }

    private func editableField(
        _ label: String,
        text: Binding<String>,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
            TextField(label, text: text)
                .keyboardType(keyboard)
                .sheetTextInput()
                .onChange(of: text.wrappedValue) { _, _ in onChange() }
        }
    }
}

struct WorkoutCalendarCard: View {
    @Binding var displayedWeek: Date
    var allDays: [String: FernletDay]
    var todayKey: String
    var selectedGoal: GoalType
    var goals: [FitnessGoal]
    var showsPlanSourceTag: Bool
    var onDayTapped: (String) -> Void

    private var cal: Calendar { .current }
    private let defaultLegendSplits: [WorkoutSplit] = [.fullBody, .upper, .lower, .workout]

    private var legendSplits: [WorkoutSplit] {
        let today = FernletDate.date(fromDayKey: todayKey) ?? .now
        let cutoff = cal.date(byAdding: .month, value: -1, to: today) ?? today
        let cutoffKey = FernletDate.dayKey(for: cutoff)

        let recentSplits = allDays
            .filter { $0.key >= cutoffKey && $0.key <= todayKey }
            .flatMap { $0.value.plannedWorkouts.map(\.split) }

        return WorkoutSplit.allCases.filter { split in
            defaultLegendSplits.contains(split) || recentSplits.contains(split)
        }
    }

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
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Previous week")

                    Text(model.weekTitle)
                        .font(.fernlet(.headerMedium))
                        .foregroundStyle(Color.bark)
                        .frame(maxWidth: .infinity)

                    Button {
                        displayedWeek = cal.date(byAdding: .weekOfYear, value: 1, to: displayedWeek) ?? displayedWeek
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.slate)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next week")
                }

                HStack(spacing: 6) {
                    ForEach(model.cells) { cell in
                        WorkoutCalendarCell(cell: cell) {
                            onDayTapped(cell.dateKey)
                        }
                    }
                }
                workoutLegend
            }
        }
    }

    private var workoutLegend: some View {
        HStack {
            ForEach(legendSplits) { split in
                HStack(spacing: 4) {
                    Circle().fill(split.color).frame(width: 8, height: 8)
                    Text(split.title).font(.fernlet(.labelSmall)).foregroundStyle(Color.slate)
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
                    .font(.fernlet(.labelSmall))
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
                                .font(.fernlet(.stat))
                                .foregroundStyle(
                                    cell.isFuture ? Color.bark.opacity(0.28)
                                        : cell.isToday ? Color.moss
                                        : Color.bark.opacity(0.68)
                                )
                            if !cell.categories.isEmpty || !cell.plannedCategories.isEmpty {
                                HStack(spacing: 2) {
                                    ForEach(Array(cell.categories.prefix(3).enumerated()), id: \.offset) { _, category in
                                        Circle()
                                            .fill(category.color)
                                            .frame(width: 5, height: 5)
                                    }
                                    ForEach(Array(cell.plannedCategories.prefix(max(0, 3 - cell.categories.count)).enumerated()), id: \.offset) { _, category in
                                        Circle()
                                            .fill(category.color.opacity(0.38))
                                            .frame(width: 5, height: 5)
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: 46)
                Text(cell.summaryText)
                    .font(.fernlet(.labelSmall))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(cell.categories.isEmpty && cell.plannedCategories.isEmpty ? Color.slate.opacity(0.45) : Color.slate)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(cell.accessibilityLabel)
    }
}

struct WorkoutWeekCell: Identifiable {
    let id = UUID()
    var day: Int
    var dateKey: String
    var weekdayText: String
    var longWeekdayText: String
    var monthDayText: String
    var categories: [WorkoutType]
    var plannedWorkouts: [PlannedWorkout]
    var plannedSplits: [WorkoutSplit]
    var plannedCategories: [WorkoutType]
    var workoutCount: Int
    var plannedCount: Int
    var isToday: Bool
    var isFuture: Bool = false

    var fill: Color {
        if let first = categories.first { return first.color.opacity(isToday ? 0.34 : 0.24) }
        if let first = plannedCategories.first { return first.color.opacity(isToday ? 0.18 : 0.12) }
        if isToday { return Color.moss.opacity(0.18) }
        return Color.softTaupe.opacity(0.16)
    }

    var summaryText: String {
        if workoutCount == 0 && plannedCount == 0 { return "Rest" }
        if workoutCount == 0 { return plannedCount == 1 ? "1 plan" : "\(plannedCount) plans" }
        return workoutCount == 1 ? "1 log" : "\(workoutCount) logs"
    }

    var accessibilityLabel: String {
        let categoryText = categories.map(\.rawValue).joined(separator: ", ")
        let planText = plannedSplits.map(\.title).joined(separator: ", ")
        if categoryText.isEmpty && !planText.isEmpty { return "\(weekdayText), day \(day), planned \(planText)" }
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

        if let first = dates.first, let last = dates.last {
            weekTitle = "\(first.formatted(.dateTime.month(.abbreviated).day())) - \(last.formatted(.dateTime.month(.abbreviated).day()))"
        } else {
            weekTitle = date.formatted(.dateTime.month(.abbreviated).day())
        }

        cells = dates.map { date in
            let key = FernletDate.dayKey(for: date)
            let workouts = allDays[key]?.workouts ?? []
            let plannedWorkouts = allDays[key]?.plannedWorkouts ?? []
            let categories = workouts.reduce(into: [WorkoutType]()) { result, workout in
                let category = WorkoutExerciseCatalog.inferredCategory(for: workout)
                if !result.contains(category) { result.append(category) }
            }
            let plannedSplits = plannedWorkouts.reduce(into: [WorkoutSplit]()) { result, workout in
                let split = workout.split
                if !result.contains(split) { result.append(split) }
            }
            let plannedCategories = plannedWorkouts.reduce(into: [WorkoutType]()) { result, workout in
                let category = workout.workoutType
                if !result.contains(category) { result.append(category) }
            }
            return WorkoutWeekCell(
                day: calendar.component(.day, from: date),
                dateKey: key,
                weekdayText: date.formatted(.dateTime.weekday(.narrow)),
                longWeekdayText: date.formatted(.dateTime.weekday(.abbreviated)),
                monthDayText: date.formatted(.dateTime.month(.abbreviated).day()),
                categories: categories,
                plannedWorkouts: plannedWorkouts,
                plannedSplits: plannedSplits,
                plannedCategories: plannedCategories,
                workoutCount: workouts.count,
                plannedCount: plannedWorkouts.count,
                isToday: key == todayKey,
                isFuture: key > todayKey
            )
        }
    }
}

struct MoveDayDetailView: View {
    var store: FernletStore
    var dateKey: String
    var showsPlanSourceTag: Bool
    @State private var showWorkoutSheet = false
    @State private var showPlanSheet = false
    @State private var editingPlannedWorkout: PlannedWorkout?

    private var day: FernletDay {
        store.loadDay(for: dateKey)
    }

    private var isFuture: Bool {
        dateKey > store.todayKey
    }

    private var navigationTitle: String {
        if dateKey == store.todayKey { return "Today" }
        let date = FernletDate.date(fromDayKey: dateKey) ?? .now
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(title: navigationTitle, subtitle: "Movement only.")

                FernletScrollSection("Plan") {
                    if day.plannedWorkouts.isEmpty {
                        Button {
                            editingPlannedWorkout = nil
                            showPlanSheet = true
                        } label: {
                            EmptyState(text: "No workouts planned")
                        }
                        .buttonStyle(.plain)
                    } else {
                        ForEach(Array(day.plannedWorkouts.enumerated()), id: \.element.id) { index, workout in
                            PlannedWorkoutRow(
                                plannedWorkout: workout,
                                showsPlanSourceTag: showsPlanSourceTag,
                                showsCompleteAction: !isFuture,
                                onComplete: { store.completePlannedWorkout(workout, date: dateKey) },
                                onEdit: {
                                    editingPlannedWorkout = workout
                                    showPlanSheet = true
                                },
                                onDelete: { store.deletePlannedWorkout(workout, date: dateKey) }
                            )
                            if index < day.plannedWorkouts.count - 1 { FernletRowDivider() }
                        }
                    }
                }

                if !isFuture {
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
            }
            .padding(20)
        }
        .background(Color.parchment)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    Button {
                        editingPlannedWorkout = nil
                        showPlanSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "calendar.badge.plus")
                            Text("Plan")
                        }
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.bark)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.cream.opacity(0.9), in: Capsule())
                        .overlay(Capsule().stroke(Color.bark.opacity(0.10), lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    if !isFuture {
                        Button { showWorkoutSheet = true } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "plus")
                                Text("Log")
                            }
                            .font(.fernlet(.label))
                            .foregroundStyle(Color.bark)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.cream.opacity(0.9), in: Capsule())
                            .overlay(Capsule().stroke(Color.bark.opacity(0.10), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(isPresented: $showWorkoutSheet) {
            WorkoutSheet(store: store, dateKey: dateKey)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
        .sheet(isPresented: $showPlanSheet) {
            WorkoutPlanSheet(
                store: store,
                dateKey: dateKey,
                showsPlanSourceTag: showsPlanSourceTag,
                editingPlan: editingPlannedWorkout
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
    }
}

struct PlannedWorkoutRow: View {
    var plannedWorkout: PlannedWorkout
    var showsPlanSourceTag: Bool
    var showsCompleteAction: Bool
    var onComplete: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    private var stepLines: [String] {
        plannedWorkout.exercises
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showsCompleteAction {
                Button(action: onComplete) {
                    ZStack {
                        Circle()
                            .fill(plannedWorkout.workoutType.color.opacity(0.14))
                            .frame(width: 34, height: 34)
                        Circle()
                            .stroke(plannedWorkout.workoutType.color, lineWidth: 2)
                            .frame(width: 34, height: 34)
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(plannedWorkout.workoutType.color)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mark \(plannedWorkout.name) complete")
            } else {
                Circle()
                    .fill(plannedWorkout.workoutType.color.opacity(0.42))
                    .frame(width: 18, height: 18)
                    .padding(.top, 6)
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plannedWorkout.name)
                        .font(.fernlet(.headerMedium))
                        .foregroundStyle(Color.bark)
                    HStack(spacing: 8) {
                        Text(plannedWorkout.split.title)
                        if showsPlanSourceTag {
                            Text(plannedWorkout.source.title)
                        }
                        if let duration = plannedWorkout.duration {
                            Text("\(duration) min")
                        }
                    }
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                }

                if !stepLines.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(stepLines.prefix(4).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.fernlet(.bodySmall))
                                .foregroundStyle(Color.bark.opacity(0.82))
                                .lineLimit(2)
                        }
                    }
                }

                if !plannedWorkout.notes.isEmpty {
                    Text(plannedWorkout.notes)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }

                HStack(spacing: 10) {
                    Button("Edit", action: onEdit)
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.moss)
                    Button("Remove", role: .destructive, action: onDelete)
                        .font(.fernlet(.label))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

struct WorkoutPlanSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    var dateKey: String
    var showsPlanSourceTag: Bool
    var editingPlan: PlannedWorkout?
    @State private var split: WorkoutSplit
    @State private var name = ""
    @State private var exerciseRows: [WorkoutExerciseEntry] = []
    @State private var plannedExerciseText = ""
    @State private var draftExercise: ExerciseTarget?
    @State private var draftSets = ""
    @State private var draftReps = ""
    @State private var draftWeight = ""
    @State private var draftSpeed = ""
    @State private var draftIncline = ""
    @State private var draftDetails = ""
    @State private var exerciseResetToken = 0
    @State private var duration = ""
    @State private var distance = ""
    @State private var energyKcal = ""
    @State private var effort = ""
    @State private var notes = ""
    @State private var selectedActivityType: WorkoutActivityType?
    @State private var logMode: WorkoutMode
    private let previousWeekPlan: PlannedWorkout?

    init(store: FernletStore, dateKey: String, showsPlanSourceTag: Bool, editingPlan: PlannedWorkout? = nil) {
        self.store = store
        self.dateKey = dateKey
        self.showsPlanSourceTag = showsPlanSourceTag
        self.editingPlan = editingPlan
        self.previousWeekPlan = store.previousWeekPlannedWorkout(for: dateKey)
        let copiedSplit = editingPlan?.split ?? store.copiedForwardWorkoutSplit(before: dateKey) ?? .fullBody
        _split = State(initialValue: copiedSplit)
        _logMode = State(initialValue: editingPlan?.mode ?? (copiedSplit == .workout ? .activity : .strengthTraining))
        _name = State(initialValue: editingPlan?.name ?? "")
        _plannedExerciseText = State(initialValue: editingPlan?.exercises ?? "")
        _exerciseRows = State(initialValue: Self.exerciseEntries(from: editingPlan?.exercises ?? ""))
        _duration = State(initialValue: editingPlan?.duration.map(String.init) ?? "")
        _distance = State(initialValue: editingPlan?.targetDistanceMiles.map { String($0) } ?? "")
        _energyKcal = State(initialValue: editingPlan?.targetEnergyKcal.map { String($0) } ?? "")
        _effort = State(initialValue: editingPlan?.targetEffort.map(String.init) ?? "")
        _notes = State(initialValue: editingPlan?.notes ?? "")
        _selectedActivityType = State(initialValue: editingPlan?.activityType)
    }

    private var targetDateTitle: String {
        if dateKey == store.todayKey { return "Today" }
        let date = FernletDate.date(fromDayKey: dateKey) ?? .now
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private var plannedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if logMode == .activity, let selectedActivityType {
            return selectedActivityType.displayName
        }
        return "\(split.title) workout"
    }

    private var exerciseText: String {
        if logMode == .activity {
            return selectedActivityType?.displayName ?? ""
        }
        return plannedExerciseText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var aggregatedMuscleGroups: Set<MuscleGroup> {
        WorkoutSheetRules.aggregatedMuscleGroups(from: exerciseRows)
    }

    private var plannedMuscleGroups: Set<MuscleGroup> {
        if exerciseRows.isEmpty {
            return editingPlan?.muscleGroups ?? []
        }
        return aggregatedMuscleGroups
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(editingPlan == nil ? "Plan workout" : "Edit plan")
                            .font(.fernlet(.displayMedium))
                            .foregroundStyle(Color.bark)
                        Text(targetDateTitle)
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.slate)
                        if showsPlanSourceTag {
                            Text("User plan")
                                .font(.fernlet(.labelSmall))
                                .foregroundStyle(Color.moss)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.moss.opacity(0.12), in: Capsule())
                        }
                    }

                    if let previousWeekPlan {
                        Button {
                            copyPreviousWeekPlan(previousWeekPlan)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.moss)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Copy previous week")
                                        .font(.fernlet(.label))
                                        .foregroundStyle(Color.bark)
                                    Text(previousWeekPlan.name)
                                        .font(.fernlet(.labelSmall))
                                        .foregroundStyle(Color.slate)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(12)
                            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }

                    SheetField("Split") {
                        FlowLayout(spacing: 8) {
                            ForEach(WorkoutSplit.allCases) { option in
                                Button(option.title) {
                                    split = option
                                    logMode = option == .workout ? .activity : .strengthTraining
                                }
                                    .buttonStyle(ChipButtonStyle(selected: split == option))
                            }
                        }
                    }

                    SheetField("Kind") {
                        FlowLayout(spacing: 8) {
                            ForEach(WorkoutMode.allCases) { mode in
                                Button(mode.label) {
                                    logMode = mode
                                    if mode == .activity {
                                        split = .workout
                                    } else if split == .workout {
                                        split = .fullBody
                                    }
                                }
                                    .buttonStyle(ChipButtonStyle(selected: logMode == mode))
                            }
                        }
                    }

                    SheetField("Workout") {
                        TextField("\(split.title) workout", text: $name)
                            .sheetTextInput()
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
                            SheetField("Planned exercises") {
                                VStack(spacing: 8) {
                                    ForEach($exerciseRows) { $entry in
                                        EditablePlannedExerciseRow(entry: $entry) {
                                            exerciseRows.removeAll { $0.id == entry.id }
                                            plannedExerciseText = exerciseRows.map(\.summary).joined(separator: "\n")
                                        } onChange: {
                                            plannedExerciseText = exerciseRows.map(\.summary).joined(separator: "\n")
                                        }
                                    }
                                }
                            }
                        }

                        SheetField("Plan steps") {
                            SheetTextEditor(
                                text: $plannedExerciseText,
                                placeholder: "Exercises, sets, reps, or trainer cues...",
                                minHeight: 100
                            )
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
                        SheetField("Duration (min)") {
                            TextField("45", text: $duration)
                                .keyboardType(.numberPad)
                                .sheetTextInput()
                        }
                    }

                    SheetField("Plan notes") {
                        SheetTextEditor(
                            text: $notes,
                            placeholder: "Exercises, coach cues, target pace, or recovery focus...",
                            minHeight: 120
                        )
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: editingPlan == nil ? "Save plan" : "Update plan") {
                store.planWorkout(
                    PlannedWorkout(
                        id: editingPlan?.id ?? UUID(),
                        name: plannedName,
                        split: split,
                        source: editingPlan?.source ?? .user,
                        mode: logMode,
                        activityType: selectedActivityType,
                        exercises: exerciseText,
                        muscleGroups: plannedMuscleGroups,
                        notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                        duration: Int(duration),
                        targetDistanceMiles: Double(distance),
                        targetEnergyKcal: Double(energyKcal),
                        targetEffort: Int(effort),
                        createdAt: editingPlan?.createdAt ?? Date()
                    ),
                    date: dateKey
                )
                dismiss()
            }
        }
        .background(Color.parchment)
        .onChange(of: logMode) { _, _ in
            clearDraftExercise()
        }
    }

    private func addDraftExercise() {
        guard let draftExercise else { return }
        exerciseRows.append(WorkoutExerciseEntry(
            exercise: draftExercise,
            sets: draftSets,
            reps: draftReps,
            weight: draftExercise.inputKind == .strength ? draftWeight : "",
            speed: draftExercise.inputKind == .treadmill ? draftSpeed : "",
            incline: draftExercise.inputKind == .treadmill ? draftIncline : "",
            details: draftDetails
        ))
        plannedExerciseText = (plannedExerciseText.components(separatedBy: .newlines) + [exerciseRows.last?.summary ?? ""])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        clearDraftExercise()
    }

    private func copyPreviousWeekPlan(_ plan: PlannedWorkout) {
        split = plan.split
        logMode = plan.mode
        name = plan.name
        plannedExerciseText = plan.exercises
        exerciseRows = Self.exerciseEntries(from: plan.exercises)
        duration = plan.duration.map(String.init) ?? ""
        notes = plan.notes
        selectedActivityType = plan.activityType
    }

    private func clearDraftExercise() {
        draftExercise = nil
        draftSets = ""
        draftReps = ""
        draftWeight = ""
        draftSpeed = ""
        draftIncline = ""
        draftDetails = ""
        exerciseResetToken += 1
    }

    private static func exerciseEntries(from text: String) -> [WorkoutExerciseEntry] {
        text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let exercise = WorkoutExerciseCatalog.search(trimmed).first else {
                return nil
            }

            let setRep = firstMatch(in: trimmed, pattern: #"(\d+)\s*x\s*(\d+)"#)
            let weight = trimmed
                .split(separator: "@", maxSplits: 1)
                .dropFirst()
                .first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            var details = trimmed.replacingOccurrences(of: exercise.name, with: "")
            if let fullMatch = setRep.fullMatch {
                details = details.replacingOccurrences(of: fullMatch, with: "")
            }
            if !weight.isEmpty {
                details = details.replacingOccurrences(of: "@\(weight)", with: "")
            }
            details = details.trimmingCharacters(in: .whitespacesAndNewlines)

            return WorkoutExerciseEntry(
                exercise: exercise,
                sets: setRep.groups.first ?? "",
                reps: setRep.groups.dropFirst().first ?? "",
                weight: exercise.inputKind == .strength ? weight : "",
                speed: exercise.inputKind == .treadmill ? weight : "",
                incline: "",
                details: details
            )
        }
    }

    private static func firstMatch(in text: String, pattern: String) -> (fullMatch: String?, groups: [String]) {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return (nil, [])
        }
        let fullMatch = Range(match.range(at: 0), in: text).map { String(text[$0]) }
        let groups = (1..<match.numberOfRanges).compactMap { index -> String? in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        return (fullMatch, groups)
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
                        .font(.fernlet(.label))
                }
                if store.goals.isEmpty {
                    Button { activeSheet = .goals } label: {
                        Text("Tap to craft fitness goals")
                            .font(.fernlet(.bubble))
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
            Text(goal.goal).font(.fernlet(.headerMedium))
            Text("\(goal.timeframe) - \(goal.metric)")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
            if !goal.milestones.isEmpty {
                Text(goal.milestones.joined(separator: " - "))
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.moss)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.parchment, in: RoundedRectangle(cornerRadius: 10))
    }
}
