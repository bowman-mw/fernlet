import SwiftUI
import FernletDomainModel
import FernletUI

/// The "Equipment & limits" setup sheet — captures the durable workout context the suggestion
/// engine reads.
///
/// Covers the chosen split (auto or an explicit pick from the recommendations), where the user
/// trains and the equipment there (via ``WorkoutLocationSetupView``), weekly frequency, experience,
/// sport/interests, and areas to work around: a None · Mild · Severe picker per body area, the
/// rested-muscle chips and the free-text note (``WorkoutInjurySection``, ``WorkoutInjuryDraft``), and
/// the way into the user's own exercises, hidden exercises and saved swaps
/// (``WorkoutExercisePreferencesEntry``), which save as they change rather than with this draft —
/// plus the guided runner's cue switches (Workout haptics, Workout sounds and
/// Spoken cues, ``WorkoutCueSettingsSection``), which are device-local rather than part of the synced profile and are
/// stored on Save like the rest. Changing the split is a plain edit — a neutral note beside the options
/// says training has been consistent, where a confirmation dialog used to interrupt the save; the sheet
/// guards its draft like the other entry sheets instead.
struct WorkoutSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore

    @State private var profile: WorkoutProfile
    @State private var interestsText: String
    @State private var injuryDraft: WorkoutInjuryDraft
    @State private var selectedSplitID: String?
    /// Session length and the stretch switches (``WorkoutSessionOptions``), saved with the rest.
    @State private var sessionOptions: WorkoutSessionOptions
    @State private var showingLocations = false
    /// The runner's cue switches, a draft like every other field: device-local, stored on Save.
    @State private var cuePreferences: FernletFeedbackPreferences
    /// The "Spoken cues" switch, a draft the same way.
    @State private var spokenCues: Bool
    private let recommendedSplits: [TrainingSplit]
    private let originalSelectedSplitID: String?
    private let currentSplitName: String
    /// Computed once at init, not in `body`: the consistency read walks recent days, and the body
    /// re-evaluates on every keystroke in the interests / sport / injury fields.
    private let isTrainingConsistently: Bool
    /// The seeded values, so a swipe-away can tell an untouched sheet from typed days / experience /
    /// injury notes — which used to be thrown away silently, this sheet having neither a Cancel nor
    /// an `interactiveDismissDisabled`.
    private let initialProfile: WorkoutProfile
    private let initialInterestsText: String
    private let initialInjuryDraft: WorkoutInjuryDraft
    private let initialCuePreferences: FernletFeedbackPreferences
    private let initialSessionOptions: WorkoutSessionOptions
    private let initialSpokenCues: Bool

    init(store: FernletStore) {
        self.store = store
        self.recommendedSplits = store.recommendedSplits()
        let settings = store.settings
        let selected = settings.workoutProfile.selectedSplitID
        let active = selected.flatMap { id in WorkoutSplitCatalog.all.first { $0.id == id } }
            ?? recommendedSplits.first ?? WorkoutSplitCatalog.fallback
        self.originalSelectedSplitID = selected
        self.currentSplitName = active.name
        self.isTrainingConsistently = store.workoutConsistency() != .low
        _selectedSplitID = State(initialValue: settings.workoutProfile.selectedSplitID)
        _profile = State(initialValue: settings.workoutProfile)
        let seedInterests = settings.workoutProfile.interests.joined(separator: ", ")
        _interestsText = State(initialValue: seedInterests)
        let draft = WorkoutInjuryDraft(profile: settings.workoutProfile)
        _injuryDraft = State(initialValue: draft)
        self.initialProfile = settings.workoutProfile
        self.initialInterestsText = seedInterests
        self.initialInjuryDraft = draft
        let cues = WorkoutCuePreferences.current()
        _cuePreferences = State(initialValue: cues)
        self.initialCuePreferences = cues
        _sessionOptions = State(initialValue: settings.workoutSessionOptions)
        self.initialSessionOptions = settings.workoutSessionOptions
        let spoken = WorkoutCuePreferences.spokenEnabled()
        _spokenCues = State(initialValue: spoken)
        self.initialSpokenCues = spoken
    }

    /// Any field diverges from what the sheet opened on. Shallow by design — a swipe-away guard,
    /// not a change tracker.
    private var isDirty: Bool {
        profile != initialProfile
            || interestsText != initialInterestsText
            || injuryDraft != initialInjuryDraft
            || selectedSplitID != originalSelectedSplitID
            || cuePreferences != initialCuePreferences
            || sessionOptions != initialSessionOptions
            || spokenCues != initialSpokenCues
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    splitSection
                    locationsEntry
                    frequencySection
                    WorkoutSessionSection(options: $sessionOptions)
                    sportInterestsSection
                    WorkoutInjurySection(draft: $injuryDraft, notes: $profile.injuryNotes)
                    WorkoutExercisePreferencesEntry(store: store)
                    WorkoutCueSettingsSection(preferences: $cuePreferences, spoken: $spokenCues)
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: "Save") { commit() }
        }
        .background(Color.parchment)
        // Presented from another sheet, so it inherits none of the app's tint: without this the
        // Stepper's +/- render iOS blue against the parchment palette.
        .tint(Color.moss)
        .keyboardDoneToolbar()
        // The 2026-08-21 template chrome in one line: the pinned SheetHeader (Cancel + title),
        // blocked swipe-dismiss while dirty, and the discard prompt on Cancel.
        .fernletDraftGuard(isDirty: isDirty, title: "Workout setup") { dismiss() }
        .sheet(isPresented: $showingLocations) {
            WorkoutLocationSetupView(store: store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
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

                if let consistencyNote {
                    Text(consistencyNote)
                        .font(.fernlet(.bubble))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
            }
        }
    }

    /// A neutral note beside the options, where a confirmation dialog used to sit.
    ///
    /// Changing your split is not destructive, so it doesn't earn a dialog — and the old one said
    /// switching "restarts that momentum", which is the guilt framing this app doesn't do. It also
    /// rendered without its cancel button on iOS 26, so tapping outside abandoned the whole save.
    private var consistencyNote: String? {
        guard isTrainingConsistently else { return nil }
        return "You've been consistent with \(currentSplitName) — keep it unless something changed."
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
                        // F3: text ink, not the `moss` accent (3.74:1, fails 4.5:1 small text).
                        Text(tag).font(.fernlet(.labelSmall)).foregroundStyle(Color.mossInk)
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
        // T1-5: a hand-rolled radio row — the filled/outline circle glyph is the only visual
        // selection cue, invisible to VoiceOver and Differentiate Without Color without this.
        .accessibilityAddTraits(selected ? .isSelected : [])
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

            if profile.experience != .beginner {
                OneRepMaxOptIn(isOn: $profile.oneRepMaxTesting)
            }
        }
    }

    private var sportInterestsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            if store.settings.selectedGoal == .sportsPrep {
                SheetField("Sport") {
                    TextField("e.g. basketball, soccer, climbing", text: $profile.sport,
                              prompt: .fieldPrompt("e.g. basketball, soccer, climbing"))
                        .sheetTextInput()
                }
            }
            SheetField("Interests") {
                TextField("e.g. kettlebells, mobility, running", text: $interestsText,
                          prompt: .fieldPrompt("e.g. kettlebells, mobility, running"))
                    .sheetTextInput()
            }
        }
    }

    // MARK: Helpers

    private func commit() {
        var updated = profile
        updated.interests = interestsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }
        updated = injuryDraft.applied(to: updated)

        store.setWorkoutProfile(updated)
        store.setSelectedSplit(selectedSplitID)
        WorkoutCuePreferences.save(cuePreferences)
        store.setWorkoutSessionOptions(sessionOptions)
        WorkoutCuePreferences.saveSpoken(spokenCues)
        dismiss()
    }
}

/// The opt-in for true one-rep-max tests at the monthly strength check, for intermediate and
/// advanced lifters only. Turning it on asks for a confirmation that carries the safety warnings;
/// turning it off is immediate. Off, the check stays submaximal — which Fernlet treats as the better
/// guide to training loads anyway.
private struct OneRepMaxOptIn: View {
    @Binding var isOn: Bool
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { isOn }, set: { wantsOn in
                if wantsOn { confirming = true } else { isOn = false }
            })) {
                Text("True max at monthly strength checks")
                    .foregroundStyle(Color.bark)
            }
            .accessibilityIdentifier("workout.setup.oneRepMax")
            Text("Off, the check is a few lighter sets and one hard set — easier on you, and usually the better guide to your training weights.")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
        .alert("Test a true max?", isPresented: $confirming) {
            Button("Turn on") { isOn = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only with a spotter or safety arms. Stop if your form breaks, and skip it when you're sore, sick or short on sleep.")
        }
    }
}
