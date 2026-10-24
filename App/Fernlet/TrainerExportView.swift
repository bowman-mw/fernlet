import SwiftUI
import FernletDomainModel
import FernletFoundation
import FernletUI
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

/// The actions a foreground App Shortcut can request when it opens the trainer handoff.
nonisolated enum TrainerExportLaunchAction: String {
    case prepareSummary
    case copySummaryAndPrompt
    case pastePlan
}

/// The Trainer / Nutritionist export screen (Phase 7), and — when the manual coach exchange is switched
/// on — the two-way coach handoff. The user prepares a curated summary to hand to a trainer or
/// nutritionist; the optional categories and the coach-exchange gate live in Settings › Sharing.
/// Nothing leaves the device until the user shares it.
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
    var initialAction: TrainerExportLaunchAction? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var preparedFile: URL?
    @State private var prepareError = false
    @State private var showCopyConfirm = false
    @State private var didCopy = false
    /// True once a share has completed. Sharing deletes the prepared file, which used to flip the
    /// button back to "Prepare summary" — reading as though the summary had been lost.
    @State private var didShare = false
    /// Whether the "What's included" list is expanded. The intro promises control over the contents;
    /// this is where the contents are actually named.
    @State private var showsIncluded = false
    /// World build (`b3-trainer-export`): the sheet's paper, framed cards and buttons.
    @Environment(\.fernletFramedLook) private var look
    @State private var sheet: TrainerSheet?
    /// A plan decoded by the paste sheet, held until that sheet has finished dismissing.
    ///
    /// Presenting the review sheet from inside the paste sheet's completion races its dismissal and
    /// the second sheet silently never appears; handing off in `onDismiss` serializes them.
    @State private var pendingPlan: CoachPlan?
    @State private var importResult: CoachPlanImportResult?
    /// Prevents a Shortcut-requested action from firing again when a child sheet dismisses and this
    /// view appears a second time.
    @State private var didRunInitialAction = false
    @State private var showCoachExchangeDisabled = false

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

    /// The body of whichever sheet ``TrainerSheet`` is presenting: file share, paste, or review.
    ///
    /// Split out of `body` so the screen's own body stays within the Power-of-10 length budget; the
    /// owning screen keeps every piece of `@State` and receives each outcome through a closure.
    private struct SheetContent: View {
        let store: FernletStore
        let presented: TrainerSheet
        let onShareFinished: (URL) -> Void
        let onDecoded: (CoachPlan) -> Void
        let onImported: (CoachPlanImportResult) -> Void

        var body: some View {
            switch presented {
            case .share(let payload):
                ActivityShareView(items: [payload.url]) { onShareFinished(payload.url) }
            case .paste:
                // World build: the paste and review sheets in the sheet frame, full height.
                CoachPlanPasteSheet { plan in onDecoded(plan) }
                    .fernletSheet()
            case .review(let plan):
                CoachPlanReviewView(store: store, plan: plan) { result in onImported(result) }
                    .fernletSheet()
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
        previewDayCount = store.buildTrainerExport(options: trainerExportOptions).days.count
    }

    /// Whether the manual coach exchange (clipboard out, paste back) is switched on.
    private var coachExchangeEnabled: Bool { store.settings.coachExchangeEnabled }

    private var trainerExportOptions: TrainerExportOptions {
        TrainerExportOptions(
            includeGoal: store.settings.trainerExportIncludesGoal,
            includeHydration: store.settings.trainerExportIncludesHydration,
            includeSleep: store.settings.trainerExportIncludesSleep,
            includeSickness: store.settings.trainerExportIncludesSickness,
            includeWellbeing: store.settings.trainerExportIncludesWellbeing
        )
    }

    /// The scrolling body of the screen: intro, prepare/share, and the optional coach-exchange cards.
    private var sections: some View {
        VStack(alignment: .leading, spacing: FernletMetrics.spaceLg) {
            intro
            prepareSection
            if coachExchangeEnabled {
                aiCoachCard
                importCard
            }
            comingSoonNote
        }
        .padding(20)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                sections
            }
            .background((look?.paper ?? Color.parchment).ignoresSafeArea())
            // World build (`b3-trainer-export`, redrawn for the button rule): the title in the sheet and
            // Done top right. Leaving with a prepared-but-never-shared summary shouldn't strand the
            // plaintext file either; swipe-to-dismiss still falls through to the purge backstops.
            .fernletSheetToolbar(title: "Share with a trainer", onDone: { discardPreparedFile(); dismiss() })
            .sheet(item: $sheet, onDismiss: {
                // Hand the just-decoded plan to the review gate only once the paste sheet is gone.
                if let plan = pendingPlan {
                    pendingPlan = nil
                    sheet = .review(plan)
                }
            }) { presented in
                SheetContent(
                    store: store,
                    presented: presented,
                    // Delete the plaintext summary as soon as the chosen activity has finished reading
                    // it — on both the shared and cancelled paths — rather than letting it linger
                    // until the next sweep. A failed delete keeps the file on screen so it can be
                    // retried. Only THIS file: a full data export may be in flight in Privacy & Data.
                    onShareFinished: handleShareFinished,
                    onDecoded: { plan in pendingPlan = plan },
                    onImported: { result in importResult = result }
                )
            }
            .alert("Copy your training summary?", isPresented: $showCopyConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Copy") { copyForAssistant() }
            } message: {
                // One literal, not `"…" + "…"`: a concatenated `String` binds `Text`'s verbatim
                // overload and never reaches the catalog.
                Text("This copies your training data as plain text so you can paste it somewhere else. Once you paste it into another app, that app has it — Fernlet can't take it back. The copy stays on this iPhone — it isn't shared to your other Apple devices. To get it onto another device, use Prepare summary instead.")
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
            // Settings changed elsewhere → the prepared file no longer matches what this screen would
            // export, so delete it rather than leaving a stale plaintext summary shareable.
            .onChange(of: trainerExportOptions) { _, _ in handleExportOptionsChange() }
            .alert("Couldn't prepare the summary", isPresented: $prepareError) {
                Button("OK", role: .cancel) {}
            } message: { Text("Please try again.") }
            .alert("Manual plan exchange is off", isPresented: $showCoachExchangeDisabled) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Turn it on in Settings › Sharing to copy a summary or paste a plan.")
            }
            .task { runInitialActionIfNeeded() }
        }
    }

    private func handleShareFinished(_ url: URL) {
        guard discardExportedFile(at: url) else { return }
        preparedFile = nil
        didShare = true
    }

    private func handleExportOptionsChange() {
        discardPreparedFile()
        refreshPreviewCount()
    }

    /// Runs the one action requested by Shortcuts after the foreground sheet has mounted. Copying
    /// still stops at the existing confirmation, and the two manual-exchange actions never bypass
    /// their Settings gate.
    private func runInitialActionIfNeeded() {
        guard !didRunInitialAction, let initialAction else { return }
        didRunInitialAction = true
        switch initialAction {
        case .prepareSummary:
            prepareSummary()
        case .copySummaryAndPrompt:
            guard coachExchangeEnabled else { showCoachExchangeDisabled = true; return }
            showCopyConfirm = true
        case .pastePlan:
            guard coachExchangeEnabled else { showCoachExchangeDisabled = true; return }
            sheet = .paste
        }
    }

    /// Removes the prepared plaintext summary and returns the screen to its "Prepare summary" state.
    ///
    /// A delete that fails leaves `preparedFile` set: the screen keeps offering Share/Done so the
    /// user can try again, rather than showing the file as gone while plaintext sits on disk.
    private func discardPreparedFile() {
        guard let url = preparedFile else { return }
        guard discardExportedFile(at: url) else { return }
        preparedFile = nil
    }

    /// Deletes one prepared export, naming a failure instead of dropping it. The launch / pre-export
    /// / delete-everything sweeps remain the backstop.
    private func discardExportedFile(at url: URL) -> Bool {
        guard store.discardExportedFile(at: url) else {
            FernletAuditLog.log("trainerExport.discardFailed")
            return false
        }
        return true
    }

    /// Builds the same temporary plaintext file as the visible Prepare summary button.
    private func prepareSummary() {
        guard let url = store.writeTrainerExportFile(options: trainerExportOptions) else {
            prepareError = true
            return
        }
        preparedFile = url
    }

    /// Puts the prompt + data blob on the clipboard, after the user has confirmed the alert.
    private func copyForAssistant() {
        guard let text = store.coachHandoffClipboardText(options: trainerExportOptions) else {
            prepareError = true
            return
        }
        #if canImport(UIKit)
        // The general pasteboard is Handoff-synced to every device on the same Apple Account unless
        // the item is written localOnly. A blob carrying injury notes and eight weeks of training is
        // not something to advertise to a shared family Mac, and the alert above now promises the
        // copy stays here. No `expirationDate` on purpose: a summary that silently
        // vanishes mid-flow makes the user paste their PREVIOUS clipboard into a chatbot — a worse
        // leak than the one the expiry would close, and a silent one.
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]],
                                      options: [.localOnly: true])
        #endif
        didCopy = true
    }

    /// Confirmation copy after a plan is applied — states what actually changed, including the
    /// things a user would otherwise have to go looking for (struck exercises, new catalog entries).
    ///
    /// One whole sentence per fact, each plural-ruled in the catalog (the English "s", and the
    /// "was"/"were", used to be spliced in by count); the sentences are joined with a space.
    static func importSummary(_ result: CoachPlanImportResult) -> String {
        var parts: [String] = []
        if result.plannedWorkoutCount > 0 {
            let workouts = String(localized: "coachPlan.count.workouts", defaultValue: "\(result.plannedWorkoutCount) workouts",
                                  comment: "A number of workouts, e.g. '3 workouts', placed inside 'Added … across …'. Needs a plural variation.")
            let days = String(localized: "coachPlan.count.days", defaultValue: "\(result.dayCount) days",
                              comment: "Coach plan review subtitle item: how many days the plan covers, e.g. '7 days'. Needs a plural variation.")
            parts.append(String(localized: "coachPlan.imported.added", defaultValue: "Added \(workouts) across \(days).",
                                comment: "Coach plan added. Arguments: a count of workouts ('3 workouts'), then a count of days ('2 days')."))
        }
        if result.editedCount > 0 {
            parts.append(String(localized: "coachPlan.imported.changed", defaultValue: "Changed \(result.editedCount) workouts you'd already planned.",
                                comment: "Coach plan added: how many already-planned workouts it changed. Needs a plural variation."))
        }
        if result.deletedCount > 0 {
            parts.append(String(localized: "coachPlan.imported.removed", defaultValue: "Removed \(result.deletedCount) planned workouts.",
                                comment: "Coach plan added: how many planned workouts it removed. Needs a plural variation."))
        }
        if result.newExerciseCount > 0 {
            parts.append(String(localized: "coachPlan.imported.newExercises", defaultValue: "\(result.newExerciseCount) new exercises added to your list.",
                                comment: "Coach plan added: how many new exercises joined the person's list. Needs a plural variation."))
        }
        if result.struckExerciseCount > 0 {
            parts.append(String(localized: "coachPlan.imported.struck", defaultValue: "\(result.struckExerciseCount) exercises you turned off were left out.",
                                comment: "Coach plan added: how many exercises the person switched off in the review were left out. Needs a plural variation (English: '1 exercise … was left out')."))
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Sections

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Share your training")
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
            Text("Prepare a summary of your workouts and nutrition to give to a trainer or nutritionist. You control exactly what goes in it, and nothing is shared until you choose to.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(look?.dim ?? Color.slate)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var prepareSection: some View {
        VStack(spacing: 10) {
            // A plural-ruled key: the English "s" used to be passed in as an argument, which no other
            // language can use.
            Text(String(localized: "trainerExport.preview.dayCount",
                        defaultValue: "\(previewDayCount) days of training will be included.",
                        comment: "Trainer summary screen: how many days of training the summary will carry. Needs a plural variation."))
                .font(look == nil ? .fernlet(.labelSmall) : MoveFont.body)
                .foregroundStyle(look?.dim ?? Color.slate)
                .frame(maxWidth: .infinity, alignment: .center)

            includedDisclosure

            if let url = preparedFile {
                // Deliberately NOT a `ShareLink`: that has no completion callback, so the plaintext
                // summary would have no seam to be deleted at. `ActivityShareView`'s `onFinish` is that
                // seam — see the `.sheet(item:)` above.
                Button {
                    sheet = .share(SharePayload(url: url))
                } label: {
                    Text("Share summary…").frame(maxWidth: .infinity)
                }
                // The framed primary under the World look; today's moss bar without it.
                .buttonStyle(ActionPillButtonStyle(.primary))
                .accessibilityIdentifier("trainer.share")
            } else {
                Button {
                    prepareSummary()
                } label: {
                    // "Share again" after a completed share: the button reverting to its untouched
                    // label read as the summary having been lost, when what happened is that the
                    // plaintext file was deleted on purpose.
                    Text(didShare ? "Share again" : "Prepare summary").frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .accessibilityIdentifier("trainer.prepare")

                if didShare {
                    Text("Shared — the file has been removed from Fernlet.")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(look?.dim ?? Color.slate)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The "What's included" expander under the count line.
    ///
    /// The intro promises the user controls exactly what goes in the summary, but the toggles live in
    /// Settings → Move and nothing on this screen said what was in it. This names the contents where
    /// the decision to share is made, and says where to change them.
    private var includedDisclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showsIncluded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("What's included")
                        .font(look == nil ? .fernlet(.label) : MoveFont.rowTitle)
                        .foregroundStyle(look?.text ?? Color.bark)
                    if look != nil {
                        Spacer(minLength: 0)
                        FernletIcon(showsIncluded ? .chevronDown : .chevron)
                    } else {
                        Image(systemName: showsIncluded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(look?.dim ?? Color.slate)
                        Spacer(minLength: 0)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("trainer.whatsIncluded")

            if showsIncluded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(includedLines, id: \.self) { line in
                        bullet(verbatim: line)
                    }
                    Text("Change what's included in Settings › Sharing.")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(look?.dim ?? Color.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // World build: the list sits in its own framed card (`b3-trainer-export`).
        .padding(.horizontal, look == nil ? 0 : 15)
        .padding(.vertical, look == nil ? 0 : 6)
        .modifier(TrainerCardFrame(isFramed: look != nil))
    }

    /// What this summary would carry right now — the always-included core plus whichever optional
    /// categories are switched on.
    private var includedLines: [String] {
        var lines = [
            String(localized: "trainerExport.included.workouts", defaultValue: "Your workouts, and how each exercise has progressed",
                   comment: "Trainer summary screen, What's included: always included"),
            String(localized: "trainerExport.included.nutrition", defaultValue: "What you've eaten, and the targets you're aiming at",
                   comment: "Trainer summary screen, What's included: always included"),
            String(localized: "trainerExport.included.setup",
                   defaultValue: "Your equipment and weights, your session length, and the muscles, movements and areas you avoid or train around",
                   comment: "Trainer summary screen, What's included: always included"),
        ]
        let settings = store.settings
        if settings.trainerExportIncludesGoal {
            lines.append(String(localized: "trainerExport.included.goal", defaultValue: "Your goal", comment: "Trainer summary screen, What's included: optional, switched on in Settings"))
        }
        if settings.trainerExportIncludesHydration {
            lines.append(String(localized: "trainerExport.included.hydration", defaultValue: "Hydration", comment: "Trainer summary screen, What's included: optional, switched on in Settings"))
        }
        if settings.trainerExportIncludesSleep {
            lines.append(String(localized: "trainerExport.included.sleep", defaultValue: "Sleep", comment: "Trainer summary screen, What's included: optional, switched on in Settings"))
        }
        if settings.trainerExportIncludesSickness {
            lines.append(String(localized: "trainerExport.included.sickness", defaultValue: "Days you were unwell", comment: "Trainer summary screen, What's included: optional, switched on in Settings"))
        }
        if settings.trainerExportIncludesWellbeing {
            lines.append(String(localized: "trainerExport.included.wellbeing", defaultValue: "How you've been feeling", comment: "Trainer summary screen, What's included: optional, switched on in Settings"))
        }
        return lines
    }

    /// The clipboard half of the manual coach exchange.
    ///
    /// Deliberately blunt about the destination: everything else on this screen keeps data on the
    /// device until an explicit share, and this doesn't — it hands plain text to another app. Saying
    /// that plainly, before the copy rather than after, is the price of the convenience.
    private var aiCoachCard: some View {
        card {
            cardTitle("Ask an AI for a plan")
            Text("Copy your training summary along with instructions, paste it into an AI assistant, and paste the plan it writes back into Fernlet below.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(look?.dim ?? Color.slate)
                .fixedSize(horizontal: false, vertical: true)
            bullet("Includes the last 8 weeks of workouts, 2 weeks of meals, and how each exercise has progressed — plus your targets, equipment and weights, session length, and the muscles, movements and areas you avoid or train around.",
                   tint: Color.moss)
            bullet("This is plain text on your clipboard. Whatever app you paste it into will have it.",
                   tint: Color.terracotta)

            Button {
                showCopyConfirm = true
            } label: {
                Text(didCopy ? "Copied — copy again" : "Copy summary + prompt")
            }
            // `b3-trainer-export`: a framed secondary — Prepare summary stays the screen's one primary.
            .buttonStyle(ActionPillButtonStyle(look == nil ? .primary : .secondary))
            .accessibilityIdentifier("trainer.copyForAI")
        }
    }

    /// The receiving half: paste a plan back in.
    private var importCard: some View {
        card {
            cardTitle("Bring a plan back")
            Text("Paste a workout plan and Fernlet will show it to you day by day — checked against the muscles and movements you avoid and the equipment you have — before anything is added.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(look?.dim ?? Color.slate)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                sheet = .paste
            } label: {
                Text("Paste a plan…")
            }
            .buttonStyle(ActionPillButtonStyle(.secondary))
            .accessibilityIdentifier("trainer.pastePlan")
        }
    }

    private var comingSoonNote: some View {
        Text("Sharing in person with a coach who uses Fernlet Coach is coming soon.")
            .font(.fernlet(.labelSmall))
            .foregroundStyle(look?.dim ?? Color.slate)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
    }

    // MARK: - Building blocks

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .modifier(MoveInsetCardFrame(cornerRadius: look == nil ? FernletMetrics.radiusMd : FernletFramedLook.cardRadius))
    }

    /// A card's heading line. Takes `LocalizedStringKey` so every literal title localizes and
    /// harvests into the string catalog automatically — a `String` parameter would silently render
    /// verbatim English forever (the localization wall's call-site opt-out trap).
    private func cardTitle(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(look == nil ? .fernlet(.label) : MoveFont.rowTitle)
            .foregroundStyle(look?.text ?? Color.slate)
    }

    /// The prepared summary's URL, wrapped `Identifiable` so `.sheet(item:)` can present the share
    /// sheet for it. A fresh `id` per tap means re-sharing the same file re-presents.
    private struct SharePayload: Identifiable {
        let id = UUID()
        let url: URL
    }

    /// A bulleted line of literal copy. `LocalizedStringKey`, so the literal reaches the catalog; a
    /// line already resolved at runtime goes through ``bullet(verbatim:tint:)``.
    private func bullet(_ text: LocalizedStringKey, tint: Color = Color.moss) -> some View {
        bulletRow(Text(text), tint: tint)
    }

    /// A bulleted line of already-localized runtime text (the What's included list).
    private func bullet(verbatim text: String, tint: Color = Color.moss) -> some View {
        bulletRow(Text(verbatim: text), tint: tint)
    }

    private func bulletRow(_ text: Text, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if look != nil {
                // World build: a pixel square in an ink frame, in the bullet's colour.
                MoveSwatch(color: tint, size: 12).padding(.top, 4)
            } else {
                Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(tint).padding(.top, 7)
            }
            text.font(.fernlet(.bodySmall)).foregroundStyle(look?.text ?? Color.bark)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// The trainer screen's "What's included" card under the World look; nothing around it today.
private struct TrainerCardFrame: ViewModifier {
    let isFramed: Bool

    func body(content: Content) -> some View {
        if isFramed {
            content.modifier(MoveInsetCardFrame())
        } else {
            content
        }
    }
}
