import SwiftUI
import FernletDomainModel

/// Captures the durable workout context the suggestion engine reads: chosen split, where the user
/// trains and the equipment there (via the location flow), weekly frequency, experience,
/// sport/interests, and areas to work around.
struct WorkoutSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore

    @State private var profile: WorkoutProfile
    @State private var interestsText: String
    @State private var avoidedAreas: Set<String>
    @State private var selectedSplitID: String?
    @State private var showingLocations = false
    @State private var pendingSwitch = false
    private let recommendedSplits: [TrainingSplit]
    private let originalSelectedSplitID: String?
    private let currentActiveSplitID: String
    private let currentSplitName: String

    private struct InjuryArea: Identifiable {
        var id: String { name }
        var name: String
        var muscles: Set<MuscleGroup>
        var movements: Set<MovementPattern>
    }

    private static let injuryAreas: [InjuryArea] = [
        InjuryArea(name: "Shoulders", muscles: [.frontDelts, .sideDelts, .rearDelts], movements: [.push]),
        InjuryArea(name: "Knees", muscles: [.quads, .hamstrings], movements: [.squat, .lunge]),
        InjuryArea(name: "Lower back", muscles: [.lowerBack], movements: [.hinge]),
        InjuryArea(name: "Elbows", muscles: [.biceps, .triceps], movements: []),
        InjuryArea(name: "Wrists", muscles: [.forearms], movements: []),
        InjuryArea(name: "Hips", muscles: [.glutes, .adductors, .abductors], movements: []),
        InjuryArea(name: "Hamstrings", muscles: [.hamstrings], movements: []),
        InjuryArea(name: "Calves", muscles: [.calves], movements: []),
        InjuryArea(name: "Chest", muscles: [.chest], movements: []),
    ]

    init(store: FernletStore) {
        self.store = store
        self.recommendedSplits = store.recommendedSplits()
        let settings = store.settings
        let selected = settings.workoutProfile.selectedSplitID
        let active = selected.flatMap { id in WorkoutSplitCatalog.all.first { $0.id == id } }
            ?? recommendedSplits.first ?? WorkoutSplitCatalog.fallback
        self.originalSelectedSplitID = selected
        self.currentActiveSplitID = active.id
        self.currentSplitName = active.name
        _selectedSplitID = State(initialValue: settings.workoutProfile.selectedSplitID)
        _profile = State(initialValue: settings.workoutProfile)
        _interestsText = State(initialValue: settings.workoutProfile.interests.joined(separator: ", "))
        let avoided = settings.workoutProfile.avoidedMuscles
        let preselected = Self.injuryAreas
            .filter { $0.muscles.isEmpty == false && $0.muscles.isSubset(of: avoided) }
            .map(\.name)
        _avoidedAreas = State(initialValue: Set(preselected))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Workout setup")
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

                    splitSection
                    locationsEntry
                    frequencySection
                    sportInterestsSection
                    injurySection
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: "Save") { save() }
        }
        .background(Color.parchment)
        .sheet(isPresented: $showingLocations) {
            WorkoutLocationSetupView(store: store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
        .confirmationDialog("Switch your routine?", isPresented: $pendingSwitch, titleVisibility: .visible) {
            Button("Switch to \(pendingNewSplitName)") { commit() }
            Button("Keep \(currentSplitName)", role: .cancel) {
                selectedSplitID = originalSelectedSplitID
                commit()
            }
        } message: {
            Text("You've been consistent with \(currentSplitName). Sticking with one routine is where progress comes from — switching restarts that momentum.")
        }
    }

    // MARK: Sections

    private var splitSection: some View {
        SheetField("Your split") {
            VStack(alignment: .leading, spacing: 8) {
                splitOption(
                    title: "Auto — recommended",
                    subtitle: recommendedSplits.first.map { "Currently: \($0.name)" } ?? "Picks the best split for you",
                    tag: "",
                    selected: selectedSplitID == nil,
                    badge: nil
                ) { selectedSplitID = nil }

                ForEach(recommendedSplits) { split in
                    splitOption(
                        title: split.name,
                        subtitle: split.summary,
                        tag: "\(split.specificity.label) · \(split.frequencySummary)",
                        selected: selectedSplitID == split.id,
                        badge: split.id == recommendedSplits.first?.id ? "Recommended" : nil
                    ) { selectedSplitID = split.id }
                }
            }
        }
    }

    private func splitOption(
        title: String,
        subtitle: String,
        tag: String,
        selected: Bool,
        badge: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.moss : Color.slate)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.fernlet(.headerMedium))
                            .foregroundStyle(Color.bark)
                        if let badge {
                            Text(badge)
                                .font(.fernlet(.labelSmall))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.moss.opacity(0.18), in: Capsule())
                                .foregroundStyle(Color.moss)
                        }
                    }
                    if subtitle.isEmpty == false {
                        Text(subtitle).font(.fernlet(.bodySmall)).foregroundStyle(Color.slate)
                    }
                    if tag.isEmpty == false {
                        Text(tag).font(.fernlet(.labelSmall)).foregroundStyle(Color.moss)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.parchment.opacity(selected ? 0.95 : 0.55), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.moss.opacity(0.5) : Color.bark.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var locationsEntry: some View {
        SheetField("Locations & equipment") {
            Button { showingLocations = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.moss)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.settings.activeWorkoutLocation.name)
                            .font(.fernlet(.headerMedium))
                            .foregroundStyle(Color.bark)
                        Text("\(store.settings.activeWorkoutLocation.ownedEquipment.count) pieces of equipment")
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.slate)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.slate)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var frequencySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetField("Days per week") {
                Stepper(value: $profile.trainingDaysPerWeek, in: 1...6) {
                    Text("\(profile.trainingDaysPerWeek) day\(profile.trainingDaysPerWeek == 1 ? "" : "s") a week")
                        .foregroundStyle(Color.bark)
                }
            }

            SheetField("Experience") {
                FlowLayout(spacing: 8) {
                    ForEach(ExperienceLevel.allCases) { level in
                        Button(level.displayName) { profile.experience = level }
                            .buttonStyle(ChipButtonStyle(selected: profile.experience == level))
                    }
                }
            }
        }
    }

    private var sportInterestsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            if store.settings.selectedGoal == .sportsPrep {
                SheetField("Sport") {
                    TextField("e.g. basketball, soccer, climbing", text: $profile.sport)
                        .sheetTextInput()
                }
            }
            SheetField("Interests") {
                TextField("e.g. kettlebells, mobility, running", text: $interestsText)
                    .sheetTextInput()
            }
        }
    }

    private var injurySection: some View {
        SheetField("Areas to work around") {
            VStack(alignment: .leading, spacing: 8) {
                FlowLayout(spacing: 8) {
                    ForEach(Self.injuryAreas) { area in
                        Button(area.name) { toggleArea(area.name) }
                            .buttonStyle(ChipButtonStyle(selected: avoidedAreas.contains(area.name)))
                    }
                }
                TextField("Anything else to keep in mind (not medical advice)", text: $profile.injuryNotes)
                    .sheetTextInput()
            }
        }
    }

    // MARK: Helpers

    private func toggleArea(_ name: String) {
        if avoidedAreas.contains(name) { avoidedAreas.remove(name) } else { avoidedAreas.insert(name) }
    }

    /// The split id that `selectedSplitID` would actually resolve to (auto → top recommendation).
    private func resolvedActiveSplitID(for selection: String?) -> String {
        if let selection, WorkoutSplitCatalog.all.contains(where: { $0.id == selection }) { return selection }
        return recommendedSplits.first?.id ?? WorkoutSplitCatalog.fallback.id
    }

    private var pendingNewSplitName: String {
        let id = resolvedActiveSplitID(for: selectedSplitID)
        return WorkoutSplitCatalog.all.first(where: { $0.id == id })?.name ?? "the new routine"
    }

    private func save() {
        // Gentle friction: if the active split is actually changing and the user has been training
        // consistently, confirm before switching (consistency beats novelty). Never a hard block.
        let newActiveID = resolvedActiveSplitID(for: selectedSplitID)
        if newActiveID != currentActiveSplitID, store.workoutConsistency() != .low {
            pendingSwitch = true
            return
        }
        commit()
    }

    private func commit() {
        var updated = profile
        updated.interests = interestsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }
        let selected = Self.injuryAreas.filter { avoidedAreas.contains($0.name) }
        updated.avoidedMuscles = selected.reduce(into: Set<MuscleGroup>()) { $0.formUnion($1.muscles) }
        updated.avoidedMovements = selected.reduce(into: Set<MovementPattern>()) { $0.formUnion($1.movements) }

        store.setWorkoutProfile(updated)
        store.setSelectedSplit(selectedSplitID)
        dismiss()
    }
}
