import SwiftUI
import FernletDomainModel
import FernletUI
#if canImport(UIKit)
import UIKit
#endif

/// The Trainer / Nutritionist export review + consent screen (Phase 7), and — when the manual coach
/// exchange is switched on — the two-way coach handoff. The user picks exactly what to include and
/// sees precisely what is and is NEVER shared, then prepares a curated summary to hand to a trainer
/// or nutritionist. Nothing leaves the device until the user shares it.
///
/// A coach is NOT a friend, so this deliberately does NOT ride the friend mesh. In-person sharing
/// over the dedicated `fernlet-coach` trainer channel (to a coach running the separate coaching app)
/// ships with that later feature; until then the reviewed summary goes out as a protected file
/// (AirDrop, email, …) or — behind `settings.coachExchangeEnabled` — onto the clipboard for an AI
/// assistant, with the returned plan pasted back through ``CoachPlanReviewView``.
///
/// The clipboard and paste sections are the SAME consent surface as the file share on purpose: when
/// the coach mesh ships, the transport under them changes and this screen's consent model doesn't.
struct TrainerExportView: View {
    var store: FernletStore
    @Environment(\.dismiss) private var dismiss

    @State private var options = TrainerExportOptions.coreOnly
    @State private var preparedFile: URL?
    @State private var prepareError = false
    @State private var showCopyConfirm = false
    @State private var didCopy = false
    @State private var sheet: TrainerSheet?
    /// A plan decoded by the paste sheet, held until that sheet has finished dismissing.
    ///
    /// Presenting the review sheet from inside the paste sheet's completion races its dismissal and
    /// the second sheet silently never appears; handing off in `onDismiss` serializes them.
    @State private var pendingPlan: CoachPlan?
    @State private var importResult: CoachPlanImportResult?

    /// Every sheet this screen presents, as ONE `.sheet(item:)`.
    ///
    /// Deliberately a single modifier rather than stacked `.sheet`s on the same view: SwiftUI only
    /// reliably drives one presentation per view, and stacking them is the classic way to get a
    /// sheet that never shows. The file-share sheet is folded in here for that reason, even though
    /// it predates the coach flow.
    private enum TrainerSheet: Identifiable {
        case share(SharePayload)
        case paste
        case review(CoachPlan)

        var id: String {
            switch self {
            case .share(let payload): payload.id.uuidString
            case .paste: "paste"
            case .review(let plan): plan.planID.uuidString
            }
        }
    }

    /// How many days the current options would export.
    ///
    /// Cached in state rather than recomputed in `body`: building the bundle now walks every logged
    /// day AND rolls up every exercise line, so doing it per render would re-scan the user's whole
    /// history on every toggle flip and sheet transition. Refreshed on appear and whenever `options`
    /// change — the only two things that move it.
    @State private var previewDayCount = 0

    private func refreshPreviewCount() {
        previewDayCount = store.buildTrainerExport(options: options).days.count
    }

    /// Whether the manual coach exchange (clipboard out, paste back) is switched on.
    private var coachExchangeEnabled: Bool { store.settings.coachExchangeEnabled }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FernletMetrics.spaceLg) {
                    intro
                    alwaysIncludedCard
                    optionalCard
                    neverSharedCard
                    prepareSection
                    if coachExchangeEnabled {
                        aiCoachCard
                        importCard
                    }
                    comingSoonNote
                }
                .padding(20)
            }
            .background(Color.parchment)
            .navigationTitle("Share with a trainer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Leaving with a prepared-but-never-shared summary shouldn't strand the plaintext
                    // file either. Swipe-to-dismiss still falls through to the purge backstops.
                    Button("Done") { discardPreparedFile(); dismiss() }
                }
            }
            .sheet(item: $sheet, onDismiss: {
                // Hand the just-decoded plan to the review gate only once the paste sheet is gone.
                if let plan = pendingPlan {
                    pendingPlan = nil
                    sheet = .review(plan)
                }
            }) { presented in
                switch presented {
                case .share(let payload):
                    ActivityShareView(items: [payload.url]) {
                        // The summary is plaintext training + nutrition data (and, when opted in,
                        // sickness days and wellbeing scores). Delete it here — after the chosen
                        // activity has finished reading the file, on both the shared and cancelled
                        // paths — instead of letting it linger until the next launch/pre-export/
                        // delete-everything sweep. Only THIS file: a full data export may be prepared
                        // or in flight in Privacy & Data, and `purgeDataExports()` would take that too.
                        store.discardExportedFile(at: payload.url)
                        preparedFile = nil
                    }
                case .paste:
                    CoachPlanPasteSheet { plan in pendingPlan = plan }
                case .review(let plan):
                    CoachPlanReviewView(store: store, plan: plan) { result in importResult = result }
                }
            }
            .alert("Copy your training summary?", isPresented: $showCopyConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Copy") { copyForAssistant() }
            } message: {
                Text("This copies your training data as plain text so you can paste it somewhere else. "
                     + "Once you paste it into another app, that app has it — Fernlet can't take it back. "
                     + "It never leaves your device on its own.")
            }
            .alert("Plan added", isPresented: Binding(
                get: { importResult != nil },
                set: { if !$0 { importResult = nil } }
            )) {
                Button("OK", role: .cancel) { importResult = nil }
            } message: {
                if let result = importResult { Text(Self.importSummary(result)) }
            }
            .onAppear { refreshPreviewCount() }
            // Options changed → the prepared file no longer matches what the screen describes, so it must
            // not be shareable. Delete it rather than just forgetting it: a stale plaintext summary
            // outliving the choice that produced it is the exact lifetime this screen is trying to shorten.
            .onChange(of: options) { _, _ in
                discardPreparedFile()
                refreshPreviewCount()
            }
            .alert("Couldn't prepare the summary", isPresented: $prepareError) {
                Button("OK", role: .cancel) {}
            } message: { Text("Please try again.") }
        }
    }

    /// Removes the prepared plaintext summary and returns the screen to its "Prepare summary" state.
    private func discardPreparedFile() {
        if let url = preparedFile { store.discardExportedFile(at: url) }
        preparedFile = nil
    }

    /// Puts the prompt + data blob on the clipboard, after the user has confirmed the alert.
    private func copyForAssistant() {
        guard let text = store.coachHandoffClipboardText(options: options) else {
            prepareError = true
            return
        }
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
        didCopy = true
    }

    /// Confirmation copy after a plan is applied — states what actually changed, including the
    /// things a user would otherwise have to go looking for (struck exercises, new catalog entries).
    private static func importSummary(_ result: CoachPlanImportResult) -> String {
        var parts: [String] = []
        if result.plannedWorkoutCount > 0 {
            parts.append("Added \(result.plannedWorkoutCount) workout\(result.plannedWorkoutCount == 1 ? "" : "s") "
                         + "across \(result.dayCount) day\(result.dayCount == 1 ? "" : "s").")
        }
        if result.editedCount > 0 {
            parts.append("Changed \(result.editedCount) workout\(result.editedCount == 1 ? "" : "s") you'd already planned.")
        }
        if result.deletedCount > 0 {
            parts.append("Removed \(result.deletedCount) planned workout\(result.deletedCount == 1 ? "" : "s").")
        }
        if result.newExerciseCount > 0 {
            parts.append("\(result.newExerciseCount) new exercise\(result.newExerciseCount == 1 ? "" : "s") "
                         + "added to your list.")
        }
        if result.struckExerciseCount > 0 {
            parts.append("\(result.struckExerciseCount) exercise\(result.struckExerciseCount == 1 ? "" : "s") "
                         + "you turned off " + (result.struckExerciseCount == 1 ? "was" : "were") + " left out.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Sections

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Share your training")
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
            Text("Prepare a summary of your workouts and nutrition to give to a trainer or nutritionist. "
                 + "You control exactly what goes in it, and nothing is shared until you choose to.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var alwaysIncludedCard: some View {
        card {
            // Must stay in step with `TrainerExportBundle.About.includes` in TrainerExportBuilder —
            // this card is the consent surface, and a list shorter than what actually ships is the
            // one kind of inaccuracy this screen cannot afford.
            cardTitle("Always included")
            bullet("Your workouts (names, sets/reps/weights as logged, duration, effort)")
            bullet("Per-day nutrition summaries (calories, macros, micronutrient totals, meal names)")
            bullet("Your daily calorie and macro targets")
            bullet("Where you train, the equipment you have, and the split you follow")
            bullet("How each exercise has progressed (frequency, recent and best sets)")
            bullet("Workouts you've already planned for the coming weeks, so they can be adjusted")
            bullet("Training-safety notes (injuries, muscles and movements to avoid)")
        }
    }

    private var optionalCard: some View {
        card {
            cardTitle("Also include (optional)")
            Toggle("Your goal", isOn: $options.includeGoal).tint(Color.moss)
            Toggle("Hydration", isOn: $options.includeHydration).tint(Color.moss)
            Toggle("Sleep summaries", isOn: $options.includeSleep).tint(Color.moss)
            Toggle("Days you were unwell", isOn: $options.includeSickness).tint(Color.moss)
            Toggle("Wellbeing score", isOn: $options.includeWellbeing).tint(Color.moss)
        }
        .font(.fernlet(.body))
        .foregroundStyle(Color.bark)
    }

    private var neverSharedCard: some View {
        card {
            cardTitle("Never shared")
            bullet("Journal entries and private notes", tint: Color.terracotta)
            bullet("Period, cycle, and intimate-activity data", tint: Color.terracotta)
            bullet("Photos, friends, and location", tint: Color.terracotta)
            bullet("Recipe ingredients and your private keys", tint: Color.terracotta)
        }
    }

    private var prepareSection: some View {
        VStack(spacing: 10) {
            Text("\(previewDayCount) day\(previewDayCount == 1 ? "" : "s") of training will be included.")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .frame(maxWidth: .infinity, alignment: .center)

            if let url = preparedFile {
                // Deliberately NOT a `ShareLink`: that has no completion callback, so the plaintext
                // summary would have no seam to be deleted at. `ActivityShareView`'s `onFinish` is that
                // seam — see the `.sheet(item:)` above.
                Button {
                    sheet = .share(SharePayload(url: url))
                } label: {
                    Label("Share summary…", systemImage: "square.and.arrow.up")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.parchment)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.moss, in: RoundedRectangle(cornerRadius: FernletMetrics.radiusSm))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("trainer.share")
            } else {
                Button {
                    if let url = store.writeTrainerExportFile(options: options) {
                        preparedFile = url
                    } else {
                        prepareError = true
                    }
                } label: {
                    Text("Prepare summary")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.parchment)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.moss, in: RoundedRectangle(cornerRadius: FernletMetrics.radiusSm))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("trainer.prepare")
            }
        }
    }

    /// The clipboard half of the manual coach exchange.
    ///
    /// Deliberately blunt about the destination: everything else on this screen keeps data on the
    /// device until an explicit share, and this doesn't — it hands plain text to another app. Saying
    /// that plainly, before the copy rather than after, is the price of the convenience.
    private var aiCoachCard: some View {
        card {
            cardTitle("Ask an AI for a plan")
            Text("Copy your training summary along with instructions, paste it into an AI assistant, "
                 + "and paste the plan it writes back into Fernlet below.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fixedSize(horizontal: false, vertical: true)
            bullet("Includes the last 8 weeks of workouts, 2 weeks of meals, and how each exercise has "
                   + "progressed — plus your targets, equipment, and the muscles and movements you avoid.",
                   tint: Color.moss)
            bullet("This is plain text on your clipboard. Whatever app you paste it into will have it.",
                   tint: Color.terracotta)

            Button {
                showCopyConfirm = true
            } label: {
                Label(didCopy ? "Copied — copy again" : "Copy summary + prompt",
                      systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.parchment)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.moss, in: RoundedRectangle(cornerRadius: FernletMetrics.radiusSm))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("trainer.copyForAI")
        }
    }

    /// The receiving half: paste a plan back in.
    private var importCard: some View {
        card {
            cardTitle("Bring a plan back")
            Text("Paste a workout plan and Fernlet will show it to you day by day — checked against the "
                 + "muscles and movements you avoid and the equipment you have — before anything is added.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                sheet = .paste
            } label: {
                Label("Paste a plan…", systemImage: "square.and.arrow.down")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.parchment, in: RoundedRectangle(cornerRadius: FernletMetrics.radiusSm))
                    .overlay(RoundedRectangle(cornerRadius: FernletMetrics.radiusSm)
                        .stroke(Color.bark.opacity(0.15), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("trainer.pastePlan")
        }
    }

    private var comingSoonNote: some View {
        Text("Sharing in person with a coach who uses Fernlet Coach is coming soon.")
            .font(.fernlet(.labelSmall))
            .foregroundStyle(Color.slate)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
    }

    // MARK: - Building blocks

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: FernletMetrics.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: FernletMetrics.radiusMd).stroke(Color.bark.opacity(0.08), lineWidth: 1))
    }

    private func cardTitle(_ text: String) -> some View {
        Text(text).font(.fernlet(.label)).foregroundStyle(Color.slate)
    }

    /// The prepared summary's URL, wrapped `Identifiable` so `.sheet(item:)` can present the share
    /// sheet for it. A fresh `id` per tap means re-sharing the same file re-presents.
    private struct SharePayload: Identifiable {
        let id = UUID()
        let url: URL
    }

    private func bullet(_ text: String, tint: Color = Color.moss) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(tint).padding(.top, 7)
            Text(text).font(.fernlet(.bodySmall)).foregroundStyle(Color.bark)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
