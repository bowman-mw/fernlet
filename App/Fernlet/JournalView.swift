import SwiftUI
import FernletFoundation
import FernletDomainModel
import FernletUI
import FernletLock

/// The Journal screen: a one-tap mood row, a feeling-tinted month calendar, today's entries, and
/// the recent-previous list.
///
/// Hosted inside ``PrivateHubView`` (behind the hub's lock gate) with `isInHub` hiding the nav
/// bar. Reads entries from ``FernletStore`` — sealed journal text is already hydrated or stripped
/// by ``JournalSealingCoordinator`` before it gets here — and reloads its `allDays` calendar cache
/// on appear, on entry/meal count changes, and when an editor sheet dismisses. Calendar taps push
/// ``DayDetailView`` by dateKey; row taps open ``JournalEntryEditorSheet``; the plus button raises
/// the ``FernletSheet`` `.journal` compose sheet.
struct JournalView: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?
    var isInHub: Bool = false
    @Binding var isTabBarCompact: Bool
    @Binding var tabResetToken: Int
    /// The injected capture-friction state, read here only to RE-INJECT into the sheets this
    /// view presents (``JournalEntryEditorSheet``, and the DEBUG-only ``DayEditSheet``
    /// presenter) — the explicit per-presentation-site convention, because a missing
    /// environment object in a sheet is a runtime crash, not a compile error.
    @Environment(CaptureProtectionState.self) private var captureProtection
    @Environment(FernletLockService.self) private var lockService
    @State private var path = NavigationPath()
    @State private var displayedMonth: Date = .now
    @State private var allDays: [String: FernletDay] = [:]
    @State private var editingJournal: JournalEntryEditTarget?
    /// Coalesces lock hydration, store-count changes, and month navigation into one state write.
    /// Synchronous duplicates caused SwiftUI's NavigationRequestObserver to update twice per frame.
    @State private var calendarRefreshTask: Task<Void, Never>?
    #if DEBUG
    /// DEBUG-only: presents ``DayEditSheet`` directly under `FERNLET_UI_TEST_OPEN_DAY_EDIT=1` —
    /// the capture-protection UI test cannot reach it by navigation while the forced Tier-2
    /// cover blocks hits on the hub beneath it. Never set outside that hook.
    @State private var uiTestDayEditPresented = false
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                pageContent
                    .fernletTabBarBottomClearance()
            }
            .fernletTabBarCompaction($isTabBarCompact, resetToken: $tabResetToken)
            .background(Color.parchment)
            .navigationTitle("")
            .toolbar(isInHub ? .hidden : .visible, for: .navigationBar)
            .navigationDestination(for: String.self) { dateKey in
                DayDetailView(store: store, dateKey: dateKey)
                    .onDisappear { scheduleCalendarRefresh() }
            }
        }
        .onAppear { scheduleCalendarRefresh() }
        .onChange(of: displayedMonth) { scheduleCalendarRefresh() }
        .onChange(of: store.day.journals.count) { scheduleCalendarRefresh() }
        .onChange(of: store.day.meals.count) { scheduleCalendarRefresh() }
        .onChange(of: lockService.state) { _, state in
            if state.isUnlocked(for: .privateHub) {
                scheduleCalendarRefresh()
            } else {
                calendarRefreshTask?.cancel()
                allDays.removeAll(keepingCapacity: false)
                if !path.isEmpty { path = NavigationPath() }
                editingJournal = nil
            }
        }
        .sheet(item: $editingJournal, onDismiss: { scheduleCalendarRefresh() }) { target in
            // `.large` only: at `.medium` the feeling chips and the character counter pushed the
            // editor itself under the fold, and at accessibility sizes it was off-screen entirely.
            JournalEntryEditorSheet(store: store, dateKey: target.dateKey, entry: target.entry)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
                .environment(captureProtection)
        }
        #if DEBUG
        .task { presentUITestJournalSheetsIfRequested() }
        .sheet(isPresented: $uiTestDayEditPresented) {
            DayEditSheet(store: store, dateKey: store.todayKey, initialDay: store.day)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
                .environment(captureProtection)
        }
        #endif
    }

    /// The sealing coordinator activates on the next UI turn after unlock. A short newest-wins
    /// delay lets that activation land first and collapses all same-frame refresh triggers.
    private func scheduleCalendarRefresh() {
        calendarRefreshTask?.cancel()
        calendarRefreshTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(40))
            } catch {
                return
            }
            refreshCalendarDaysIfUnlocked()
        }
    }

    /// Retains only the displayed month. The former full-history snapshot duplicated every day in
    /// the app store and, more importantly, kept hydrated journal strings after the hub re-locked.
    private func refreshCalendarDaysIfUnlocked() {
        guard lockService.isUnlocked(for: .privateHub),
              let interval = Calendar.current.dateInterval(of: .month, for: displayedMonth) else {
            allDays.removeAll(keepingCapacity: false)
            return
        }
        var monthDays: [String: FernletDay] = [:]
        monthDays.reserveCapacity(31)
        // A month has at most 31 days. Loading those keys directly avoids materializing and then
        // filtering the app's entire uncapped day-history dictionary on every Journal entry.
        for offset in 0..<31 {
            guard let date = Calendar.current.date(byAdding: .day, value: offset, to: interval.start),
                  date < interval.end else { break }
            let key = FernletDate.dayKey(for: date)
            let day = store.loadDay(for: key)
            if day.hasLoggedContent { monthDays[key] = day }
        }
        allDays = monthDays
    }

    /// The scrolling page: header row, the one-tap mood card, the month calendar, and the two
    /// entry lists (R4: `body` keeps only the NavigationStack and its modifiers).
    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                ScreenHeader(title: "Journal", subtitle: "A small record of being.", identifier: "screen.journal")
                Spacer()
                HeaderActionButton(systemImage: "plus", accessibilityLabel: "New journal entry") { activeSheet = .journal }
            }
            .padding(.top, 4)

            // One-tap mood check-in — a tag-only entry, no writing required.
            FernletCard {
                QuickMoodRow(store: store)
            }

            JournalCalendarCard(
                displayedMonth: $displayedMonth,
                allDays: allDays,
                todayKey: store.todayKey,
                onDayTapped: { key in path.append(key) }
            )

            todaySection
            previousSection
        }
        .padding(20)
    }

    /// Today's entries, newest first — the one just saved sits at the top.
    ///
    /// `store.day.journals` is append-ordered (oldest first), so the list is reversed here rather
    /// than in the store, which other surfaces read in chronological order.
    private var todayEntries: [JournalEntry] {
        store.day.journals.reversed()
    }

    /// The recent EARLIER entries, newest first.
    ///
    /// `store.previousJournals` deliberately front-inserts today's entries (it is the "recent
    /// entries" pool feeding Home and the companion), so today has to be filtered out here — without
    /// it every entry written today rendered twice on this page: once under Today and again under
    /// Previous.
    private var previousEntries: [JournalEntry] {
        store.previousJournals
            .filter { FernletDate.dayKey(for: $0.date) != store.todayKey }
            .prefix(10)
            .map { $0 }
    }

    /// Today's entries, or the "How was today?" invitation when there are none.
    @ViewBuilder
    private var todaySection: some View {
        FernletScrollSection("Today") {
            let entries = todayEntries
            if entries.isEmpty {
                Button { activeSheet = .journal } label: {
                    Text("How was today?")
                        .font(.fernlet(.bubble))
                        .foregroundStyle(Color.slate)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            } else {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    Button { editingJournal = JournalEntryEditTarget(entry: entry, dateKey: store.todayKey) } label: {
                        JournalRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                    if index < entries.count - 1 {
                        FernletRowDivider()
                    }
                }
            }
        }
    }

    /// The ten most recent earlier entries; absent entirely when there are none.
    @ViewBuilder
    private var previousSection: some View {
        let entries = previousEntries
        if !entries.isEmpty {
            FernletScrollSection("Previous") {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    Button { editingJournal = JournalEntryEditTarget(entry: entry, dateKey: FernletDate.dayKey(for: entry.date)) } label: {
                        JournalRow(entry: entry, compact: true)
                    }
                    .buttonStyle(.plain)
                    if index < entries.count - 1 {
                        FernletRowDivider()
                    }
                }
            }
        }
    }

    #if DEBUG
    /// DEBUG-only capture-protection UI-test presenters (see `UITestSupport`): auto-opens
    /// ``JournalEntryEditorSheet`` (with today's first entry, or a synthetic one so the hook
    /// never depends on seeding) or ``DayEditSheet`` for today. Both sheets are otherwise only
    /// reachable by taps the forced Tier-2 cover deliberately blocks. No-ops without the flags.
    private func presentUITestJournalSheetsIfRequested() {
        if UITestSupport.shouldOpenJournalEditor {
            let entry = store.day.journals.first
                ?? JournalEntry(text: "Capture-protection UI-test entry", tag: .neutral)
            editingJournal = JournalEntryEditTarget(entry: entry, dateKey: store.todayKey)
        } else if UITestSupport.shouldOpenDayEditSheet {
            uiTestDayEditPresented = true
        }
    }
    #endif
}

// MARK: - Journal Sheet

/// The compose sheet for a new journal entry: a feeling chip row, a free-text editor capped at
/// 800 characters, and the daily inspiration prompt.
///
/// Saves through ``FernletStore/addJournal(text:tag:)`` (sealing happens inside the store's mutation path).
/// The inspiration chip pulls the deterministic prompt of the day from ``JournalPromptLibrary``,
/// and ``JournalContinuationDetector`` watches the text to surface a one-time-per-reason
/// ``JournalPromptNotificationView`` banner suggesting the Moments app for long reflections.
/// Chrome is the 2026-08-21 template: the draft-guard header carries Cancel and the title;
/// Save commits bottom-right.
struct JournalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var store: FernletStore
    @State private var text = ""
    @State private var tag: FeelingTag
    @State private var promptedReasons: Set<JournalPromptReason> = []
    @State private var journalPromptNotification: JournalPromptNotification?
    @State private var inspirationDismissed = false
    /// The feeling the day already carried when the sheet opened — both the starting selection and
    /// the "is this dirty?" reference point.
    private let initialTag: FeelingTag

    /// Seeds the feeling chip from today's LAST entry rather than always from `.neutral`.
    ///
    /// Scoring, the calendar tint, and the companion all read the day's last tag, so a preselected
    /// `.neutral` meant that writing a note and tapping Save silently overwrote a day already marked
    /// Bright unless the user re-tapped a chip every time.
    init(store: FernletStore) {
        self.store = store
        let seed = store.day.journals.last?.tag ?? .neutral
        self.initialTag = seed
        _tag = State(initialValue: seed)
    }

    private var limitedText: Binding<String> {
        Binding(
            get: { text },
            set: { updateText($0) }
        )
    }

    /// Whether the sheet holds anything a swipe-down would throw away.
    private var isDirty: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tag != initialTag
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SheetField("Feeling") {
                        FlowLayout(spacing: 8) {
                            ForEach(FeelingTag.allCases) { option in
                                Button(option.label) { tag = option }
                                    .buttonStyle(ChipButtonStyle(selected: tag == option))
                            }
                        }
                    }

                    // Editor first, prompt under it: at the `.medium` detent the prompt card used to
                    // push the text field under the fold, so the sheet opened on everything except
                    // the thing the user came to write in.
                    SheetField("How was today?") {
                        VStack(alignment: .leading, spacing: 10) {
                            SheetTextEditor(text: limitedText, placeholder: "What happened today?", minHeight: 150)
                            inspirationChip
                        }
                    }

                    Text("\(text.count)/800")
                        .font(.fernlet(.stat))
                        .foregroundStyle(Color.slate)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(disabled: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                store.addJournal(text: text, tag: tag)
                dismiss()
            }
        }
        .background(Color.parchment)
        .overlay(alignment: .top) {
            if let journalPromptNotification {
                JournalPromptNotificationView(notification: journalPromptNotification) {
                    openJournalApp()
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: journalPromptNotification?.id)
        // A swipe-down used to throw away a typed entry with no warning. The guard also renders
        // the pinned template header (Cancel + title).
        .fernletDraftGuard(isDirty: isDirty, title: "Journal") { dismiss() }
        // Capture FRICTION (never a security control), attached at the sheet TYPE so every
        // presenter — the hub, Home's quick-log tile, the notification tap, the App Intent — is
        // covered by this one edit. A presented sheet is frontmost by construction.
        .captureProtected(surface: "journalSheet")
    }

    /// A dismissible "inspiration" chip: today's prompt from the static library (deterministic
    /// daily rotation — see `JournalPromptLibrary`; never AI, journal text is walled from models).
    /// "Start from this" inserts the prompt as a starter the user writes under; the chip hides once
    /// there's text, and dismissing it is remembered for this sheet only — never required.
    @ViewBuilder
    private var inspirationChip: some View {
        if !inspirationDismissed && text.isEmpty {
            let prompt = JournalPromptLibrary.prompt(for: store.todayKey)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.goldenrod)
                        .padding(.top, 2)
                    Text(prompt)
                        .font(.fernlet(.bubble))
                        .foregroundStyle(Color.bark)
                        .fernletWrappingText()
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            inspirationDismissed = true
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.slate)
                            .frame(width: 24, height: 24)
                            .background(Color.slate.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss the prompt")
                }
                Button("Start from this") {
                    text = prompt + "\n"
                }
                .font(.fernlet(.label))
                .foregroundStyle(Color.moss)
                .buttonStyle(.plain)
                .accessibilityHint("Inserts the prompt so you can write under it")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.goldenrod.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityIdentifier("journal.inspiration")
        }
    }

    private func updateText(_ newValue: String) {
        let cappedText = String(newValue.prefix(JournalContinuationDetector.maxCharacters))
        if cappedText != text {
            text = cappedText
        }

        if newValue.count > JournalContinuationDetector.maxCharacters {
            promptIfNeeded(.limitReached)
            return
        }

        if let reason = JournalContinuationDetector.reason(for: newValue) {
            promptIfNeeded(reason)
        }
    }

    private func promptIfNeeded(_ reason: JournalPromptReason) {
        guard promptedReasons.contains(reason) == false else { return }
        promptedReasons.insert(reason)
        showJournalPromptNotification(reason)
    }

    private func showJournalPromptNotification(_ reason: JournalPromptReason) {
        let notification = JournalPromptNotification(reason: reason)
        journalPromptNotification = notification

        // The banner offers an action — it opens the long-form journaling app — so it gets the
        // stretched ACTION window, not the notice one. A prompt that has gone by the time the
        // VoiceOver cursor reaches it is the same as no prompt at all.
        let window = FernletDismissalWindow.system.window(
            standard: .seconds(6),
            assistive: FernletDismissalWindow.assistiveActionWindow)
        Task { @MainActor in
            do {
                try await Task.sleep(for: window)
            } catch {
                // Cancelled: this sheet is gone or a newer banner owns the state — touch nothing.
                return
            }
            if journalPromptNotification?.id == notification.id {
                journalPromptNotification = nil
            }
        }
    }

    private func openJournalApp() {
        journalPromptNotification = nil
        guard let url = URL(string: "moments://") else { return }
        openURL(url)
    }
}

/// Pure heuristics that decide when a journal draft has outgrown Fernlet's short-note format.
///
/// Shared by ``JournalSheet``, ``JournalEntryEditorSheet``, and ``DayEditSheet``: ``maxCharacters``
/// is the hard 800-character cap those editors enforce, and ``reason(for:)`` classifies a draft as
/// `.longReflection` (word/length thresholds, or a shorter draft with an unfinished-sounding
/// ending) or `.limitReached` so the caller can suggest continuing in the Moments app. Entirely
/// deterministic and string-local — no AI, matching the S3 wall around journal text.
struct JournalContinuationDetector {
    /// The hard cap every journal text editor enforces (characters, post-truncation).
    static let maxCharacters = 800

    /// Classifies a draft, or returns nil when it is still comfortably short.
    ///
    /// - Returns: `.limitReached` at/over ``maxCharacters``; `.longReflection` for drafts of 90+
    ///   words, 680+ characters, or 520+ characters ending mid-thought; otherwise nil (drafts
    ///   under 220 trimmed characters never prompt).
    static func reason(for text: String) -> JournalPromptReason? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 220 else { return nil }

        if trimmed.count >= maxCharacters {
            return .limitReached
        }

        let wordCount = trimmed.split { $0.isWhitespace || $0.isNewline }.count
        if wordCount >= 90 || trimmed.count >= 680 || (trimmed.count >= 520 && hasUnfinishedEnding(trimmed)) {
            return .longReflection
        }

        return nil
    }

    private static func hasUnfinishedEnding(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let unfinishedSuffixes = [",", ":", ";", "-", " and", " but", " because", " so", " then", " when", " while"]
        return unfinishedSuffixes.contains { lowercased.hasSuffix($0) }
    }
}

/// Why a "keep going in Moments" banner is being shown: an organically long reflection, or the
/// hard character limit.
///
/// Produced by ``JournalContinuationDetector`` and consumed by ``JournalPromptNotificationView``,
/// which renders the per-reason title, message, and symbol. Each reason prompts at most once per
/// editing session (the editors track a `promptedReasons` set).
enum JournalPromptReason: Hashable {
    case longReflection
    case limitReached

    var title: String {
        switch self {
        case .longReflection: "Keep going in Moments"
        case .limitReached: "Journal limit reached"
        }
    }

    var message: String {
        switch self {
        case .longReflection:
            "This is getting long enough for a dedicated journal entry."
        case .limitReached:
            "Fernlet saved the short version here. Moments is better for the rest."
        }
    }

    var systemImage: String {
        switch self {
        case .longReflection: "book.pages"
        case .limitReached: "text.badge.plus"
        }
    }
}

/// One instance of the Moments-suggestion banner, identified so auto-dismissal can tell whether
/// the banner it timed out is still the one on screen.
///
/// The editors hold at most one as optional state; the fresh `id` per showing lets the 6-second
/// dismiss task no-op when a newer banner has replaced the one it was timing.
struct JournalPromptNotification: Identifiable, Equatable {
    let id = UUID()
    var reason: JournalPromptReason
}

/// The floating banner card that suggests continuing a long entry in the Moments app.
///
/// Overlaid at the top of ``JournalSheet``, ``JournalEntryEditorSheet``, and ``DayEditSheet``;
/// renders the ``JournalPromptReason``'s title/message/symbol and forwards the open-app button to
/// the hosting sheet's `moments://` launcher.
struct JournalPromptNotificationView: View {
    var notification: JournalPromptNotification
    var openJournalApp: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: notification.reason.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.moss)
                .frame(width: 30, height: 30)
                .background(Color.moss.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(notification.reason.title)
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)
                Text(notification.reason.message)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }

            Spacer(minLength: 8)

            Button(action: openJournalApp) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.bark)
                    .frame(width: 34, height: 34)
                    .background(Color.bark.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Moments")
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.bark.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Color.bark.opacity(0.12), radius: 18, x: 0, y: 8)
    }
}

/// Sheet-item wrapper pairing a journal entry with the dateKey of the day it belongs to.
///
/// ``JournalView`` and ``DayDetailView`` set this as their `.sheet(item:)` state to open
/// ``JournalEntryEditorSheet``; the dateKey rides along because updating or deleting an entry
/// must target the owning day, and identity follows the entry's own id.
struct JournalEntryEditTarget: Identifiable {
    var entry: JournalEntry
    var dateKey: String

    var id: UUID { entry.id }
}

/// The edit sheet for an existing journal entry: feeling tag, capped text, and a delete action.
///
/// The editing counterpart of ``JournalSheet``, opened via ``JournalEntryEditTarget`` from today's
/// list, the previous list, or ``DayDetailView``. Saves through ``FernletStore/updateJournal(_:text:tag:date:)``
/// (which re-seals the narrative when the entry is sealed) and deletes through
/// ``FernletStore/deleteJournal(_:date:)``; shares the ``JournalContinuationDetector`` long-entry banner
/// with the compose sheet. Chrome is the 2026-08-21 template: the draft-guard header carries
/// Cancel and the title; Save commits bottom-right.
struct JournalEntryEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var store: FernletStore
    var dateKey: String
    var entry: JournalEntry

    @State private var text: String
    @State private var tag: FeelingTag
    @State private var promptedReasons: Set<JournalPromptReason> = []
    @State private var journalPromptNotification: JournalPromptNotification?
    /// The pending delete, held until the user confirms it — a sealed entry must never go on a
    /// mis-tap while scrolling this sheet.
    @State private var pendingDelete: DestructiveConfirmation?

    init(store: FernletStore, dateKey: String, entry: JournalEntry) {
        self.store = store
        self.dateKey = dateKey
        self.entry = entry
        _text = State(initialValue: entry.text)
        _tag = State(initialValue: entry.tag)
    }

    private var limitedText: Binding<String> {
        Binding(
            get: { text },
            set: { updateText($0) }
        )
    }

    /// Whether the sheet holds edits a swipe-down would throw away.
    private var isDirty: Bool {
        text != entry.text || tag != entry.tag
    }

    /// Feeling chips, the editor, its counter, and the delete affordance — the scrolling half
    /// of the editor sheet (the title lives in the pinned draft-guard header).
    private var editorScrollContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            SheetField("Feeling") {
                FlowLayout(spacing: 8) {
                    ForEach(FeelingTag.allCases) { option in
                        Button(option.label) { tag = option }
                            .buttonStyle(ChipButtonStyle(selected: tag == option))
                    }
                }
            }

            SheetField("Entry") {
                SheetTextEditor(text: limitedText, placeholder: "What happened today?", minHeight: 200)
            }

            Text("\(text.count)/800")
                .font(.fernlet(.stat))
                .foregroundStyle(Color.slate)
                .frame(maxWidth: .infinity, alignment: .trailing)

            deleteEntryButton
        }
        .padding(20)
        .padding(.bottom, 10)
    }

    /// Destructive delete, gated behind the shared confirmation sheet. Rendered as the one
    /// full-width destructive token, ``DestructiveCardButtonStyle`` (2026-08-21 template, 2b).
    private var deleteEntryButton: some View {
        Button(role: .destructive) {
            pendingDelete = DestructiveConfirmation(
                title: "Delete this entry?",
                message: "The words you wrote for this day are sealed on this device — deleting them can't be undone.",
                confirmLabel: "Delete",
                auditEvent: "journal.entryDeleteConfirmed",
                perform: {
                    store.deleteJournal(entry, date: dateKey)
                    dismiss()
                }
            )
        } label: {
            Label("Delete journal entry", systemImage: "trash")
        }
        .buttonStyle(DestructiveCardButtonStyle())
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                editorScrollContent
            }

            SheetSaveBar(disabled: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                store.updateJournal(entry, text: text, tag: tag, date: dateKey)
                dismiss()
            }
        }
        .background(Color.parchment)
        .overlay(alignment: .top) {
            if let journalPromptNotification {
                JournalPromptNotificationView(notification: journalPromptNotification) {
                    openJournalApp()
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: journalPromptNotification?.id)
        // A swipe-down used to throw away the edit with no warning. The guard also renders the
        // pinned template header (Cancel + title).
        .fernletDraftGuard(isDirty: isDirty, title: "Edit journal") { dismiss() }
        .destructiveConfirmation($pendingDelete)
        // Capture FRICTION (never a security control), attached at the sheet TYPE so both
        // presenters (JournalView's entry rows and DayDetailView's) are covered by one edit.
        .captureProtected(surface: "journalEditor")
    }

    private func updateText(_ newValue: String) {
        let cappedText = String(newValue.prefix(JournalContinuationDetector.maxCharacters))
        if cappedText != text {
            text = cappedText
        }

        if newValue.count > JournalContinuationDetector.maxCharacters {
            promptIfNeeded(.limitReached)
            return
        }

        if let reason = JournalContinuationDetector.reason(for: newValue) {
            promptIfNeeded(reason)
        }
    }

    private func promptIfNeeded(_ reason: JournalPromptReason) {
        guard promptedReasons.contains(reason) == false else { return }
        promptedReasons.insert(reason)
        showJournalPromptNotification(reason)
    }

    private func showJournalPromptNotification(_ reason: JournalPromptReason) {
        let notification = JournalPromptNotification(reason: reason)
        journalPromptNotification = notification

        // The banner offers an action — it opens the long-form journaling app — so it gets the
        // stretched ACTION window, not the notice one. A prompt that has gone by the time the
        // VoiceOver cursor reaches it is the same as no prompt at all.
        let window = FernletDismissalWindow.system.window(
            standard: .seconds(6),
            assistive: FernletDismissalWindow.assistiveActionWindow)
        Task { @MainActor in
            do {
                try await Task.sleep(for: window)
            } catch {
                // Cancelled: this sheet is gone or a newer banner owns the state — touch nothing.
                return
            }
            if journalPromptNotification?.id == notification.id {
                journalPromptNotification = nil
            }
        }
    }

    private func openJournalApp() {
        journalPromptNotification = nil
        guard let url = URL(string: "moments://") else { return }
        openURL(url)
    }
}

// MARK: - Calendar Card

/// The journal month-grid card: feeling-tinted day cells, month paging, and a tag legend.
///
/// Builds a ``JournalMonthModel`` per render from the `allDays` cache and forwards day taps
/// (by dateKey, past/today only) up to ``JournalView``, which pushes ``DayDetailView``. The card
/// chrome and paging (forward past the current month disabled) come from the shared
/// ``MonthCalendarCard``.
struct JournalCalendarCard: View {
    @Binding var displayedMonth: Date
    var allDays: [String: FernletDay]
    var todayKey: String
    var onDayTapped: (String) -> Void

    /// Read ONCE for the whole card and used only by ``tagLegend``; ``JournalCalendarCell`` reads
    /// it once for itself. The same deliberate arrangement as ``WorkoutCalendarCard`` — the flag is
    /// threaded down as a plain `Bool` rather than read again per swatch. See
    /// ``FeelingTag/differentiatingSymbol`` for what it changes.
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        let model = JournalMonthModel(date: displayedMonth, allDays: allDays, todayKey: todayKey)
        MonthCalendarCard(displayedMonth: $displayedMonth, todayKey: todayKey) { gridDay in
            let cell = model.cell(for: gridDay)
            JournalCalendarCell(cell: cell) {
                if let key = cell.dateKey, !cell.isFuture {
                    onDayTapped(key)
                }
            }
        } footer: {
            tagLegend
        }
    }

    /// The feeling key under the grid. Wraps onto new rows rather than shrinking: at accessibility
    /// sizes the old `lineLimit(1)` + `minimumScaleFactor(0.7)` row read "Work…"/"Ten…".
    ///
    /// Under **Differentiate Without Color** the swatch becomes the same mark the day cells draw
    /// for that feeling, in the same ink, so the legend stays a working key: otherwise the cells
    /// would show shapes the legend explained only in hue. The default swatch is untouched.
    private var tagLegend: some View {
        FlowLayout(spacing: 10) {
            ForEach(FeelingTag.allCases) { tag in
                HStack(spacing: 4) {
                    if differentiateWithoutColor {
                        Image(systemName: tag.differentiatingSymbol)
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(Color.bark)
                            .frame(width: 10, height: 10)
                    } else {
                        Circle().fill(tag.color).frame(width: 8, height: 8)
                    }
                    Text(tag.label).font(.fernlet(.labelSmall)).foregroundStyle(Color.slate)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

/// The shape vocabulary that stands in for hue when **Differentiate Without Color** is on.
///
/// The journal month grid encodes all six feelings as a wash of ``FeelingTag/color`` over the card
/// surface and nothing else, so in greyscale the six categories are not merely *hard* to tell
/// apart — they are, pairwise, the same value. Measured on the light palette (`#FBF7EE` box, the
/// 28% non-today wash): `quiet` vs `hard` separate by **1.0028:1**, `neutral` vs `tired` by
/// 1.031:1 on the dark palette, and the WORST pair anywhere — across both appearances and both wash
/// strengths — reaches only **1.4205:1** (dark, the 38% today-wash; the dark 28% wash tops out at
/// 1.3046:1). Three is the WCAG 1.4.11 floor for a graphic that carries meaning; nothing here
/// reaches half of it. These symbols do.
///
/// The six are chosen for SILHOUETTE at 9pt, which is the only channel that survives that size:
/// spiky, round, square, elongated, rotated-square, three-sided. `star`/`circle`/`square`/
/// `capsule`/`diamond`/`triangle` are the same family ``WorkoutType`` already draws from in the
/// workout calendar, so the two calendars speak one visual language. The mapping is a `switch`
/// with no `default:` — a seventh feeling is a compile error, not a silent grey blob.
private extension FeelingTag {
    /// The filled SF Symbol drawn on a day cell (and in the card legend) under Differentiate
    /// Without Color. Always filled: there is no planned/logged second axis here as there is in the
    /// workout calendar, so the mark spends its whole budget on being a legible shape.
    var differentiatingSymbol: String {
        switch self {
        case .bright: "star.fill"
        case .good: "circle.fill"
        case .neutral: "square.fill"
        case .quiet: "capsule.fill"
        case .tired: "diamond.fill"
        case .hard: "triangle.fill"
        }
    }
}

// MARK: - Calendar Cell

/// A single tappable day cell in the journal calendar grid.
///
/// Pure presentation over one ``JournalMonthCell``: feeling-tag fill, today ring, a small dot for
/// days with non-journal data, and future-day dimming/disabling all come from the model.
struct JournalCalendarCell: View {
    var cell: JournalMonthCell
    var onTap: () -> Void
    /// Read ONCE per cell and consumed only by ``feelingMark`` — never re-read per mark. See
    /// ``FeelingTag/differentiatingSymbol``.
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(cell.fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(cell.isToday ? Color.moss : Color.clear, lineWidth: 1.5)
                    )
                if let day = cell.day {
                    VStack(spacing: 1) {
                        Text("\(day)")
                            // Today's numeral gets real weight via the heavier bundled Fraunces face
                            // — `.fontWeight(.bold)` is a silent no-op on the single-weight DM Sans
                            // Medium that `.stat` resolves to.
                            .font(cell.isToday
                                  ? .custom(FernletFontName.frauncesSemiBold, size: 14, relativeTo: .subheadline)
                                  : .fernlet(.stat))
                            .foregroundStyle(
                                cell.isFuture ? Color.bark.opacity(0.28)
                                    : cell.isToday ? Color.moss
                                    : Color.bark.opacity(0.68)
                            )
                        if cell.hasData && cell.tag == nil {
                            Circle()
                                .fill(Color.slate.opacity(0.45))
                                .frame(width: 3, height: 3)
                        } else {
                            Color.clear.frame(width: 3, height: 3)
                        }
                    }
                    .padding(.bottom, 2)
                }
                feelingMark
            }
        }
        .buttonStyle(.plain)
        .aspectRatio(1, contentMode: .fit)
        .disabled(cell.day == nil || cell.isFuture)
        .accessibilityLabel(cell.accessibilityLabel)
    }

    /// The feeling's shape mark, drawn ONLY under **Differentiate Without Color**.
    ///
    /// With the setting off this is an `EmptyView` and the cell renders exactly as it always has —
    /// same fill, same numeral, same has-data dot — so the default appearance carries no visual
    /// risk at all. With it on the tint is *kept* and the shape is added on top: colour is never
    /// removed, it simply stops being the only channel.
    ///
    /// Ink is ``Color/bark``, not the feeling's own tint. Drawing the mark in `tag.color` (the
    /// workout calendar's choice, where the mark sits on a plain card rather than on a wash of its
    /// own hue) measures as low as **1.497:1** against the cell it sits in — a `sun` glyph on a
    /// 28% `sun` wash is very nearly invisible. `bark` measures **≥4.93:1** against all six washes
    /// in both appearances and at both wash strengths, clearing the 3:1 non-text floor everywhere.
    ///
    /// Overlaid inside the `ZStack` on an infinite frame rather than added to the numeral's
    /// `VStack`: an extra 9pt row inside that stack would grow the cell's ideal height and could
    /// push the square out of the grid at accessibility text sizes. This way the geometry and the
    /// tap target are byte-identical to the default. `isFuture` is checked first, exactly as
    /// ``JournalMonthCell/fill`` does, so a mark can never appear on a day drawn with the
    /// future wash.
    @ViewBuilder private var feelingMark: some View {
        if differentiateWithoutColor, !cell.isFuture, let tag = cell.tag {
            Image(systemName: tag.differentiatingSymbol)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(Color.bark)
                .padding(3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }
}

// MARK: - Calendar Models

/// One cell of the journal month grid: a day number (or blank pad), the day's last feeling tag,
/// and whether the day holds any logged data at all.
///
/// Built by ``JournalMonthModel`` and rendered by ``JournalCalendarCell``. `fill` encodes the
/// hierarchy — feeling-tag tint first, then today, then a neutral "has data" wash — so the color
/// logic stays out of the view.
struct JournalMonthCell: Identifiable {
    let id = UUID()
    var day: Int?
    var dateKey: String?
    var tag: FeelingTag?
    var isToday: Bool
    var isFuture: Bool = false
    var hasData: Bool = false
    /// The already-localized ABBREVIATED weekday NAME for this day ("Wed"), spoken but never drawn
    /// — see ``accessibilityLabel``. Empty for a blank pad cell, and for the (unreachable in
    /// practice) day whose `Date` the layout calendar could not resolve; ``weekdaylessLabel`` is
    /// the honest fallback for that case rather than a sentence with a hole in it.
    var weekdayName: String = ""

    var fill: Color {
        if isFuture { return Color.softTaupe.opacity(0.05) }
        if let tag { return tag.color.opacity(isToday ? 0.38 : 0.28) }
        if isToday { return Color.moss.opacity(0.18) }
        if hasData { return Color.softTaupe.opacity(0.22) }
        return Color.softTaupe.opacity(day == nil ? 0.05 : 0.16)
    }

    /// The spoken cell. The feeling tag is named here because the grid encodes it as a tint alone —
    /// without it the mood a day carries is invisible to VoiceOver and to anyone who can't
    /// distinguish the tints.
    /// `Text` rather than `String`, and built by CHOOSING a whole sentence rather than appending
    /// clauses (review T2-1): a `String` reaches `.accessibilityLabel(_:)` through the verbatim
    /// overload, and a clause appended with `+=` can never be a catalog key at all. The feeling
    /// name is no longer lower-cased on the way in — `tag.label` is already localized, and
    /// case-folding a translated word is wrong in every language that capitalizes nouns.
    ///
    /// Every sentence now opens with the WEEKDAY (review T2-17). The drawn weekday initials came
    /// off the cells in that same review, which left "Day 14" as the entire utterance: a month
    /// grid whose cells name only an ordinal cannot be navigated by anyone who cannot see the
    /// column the cell sits in. The name comes from ``weekdayName`` — the ABBREVIATED weekday NAME
    /// ("Wed"), deliberately NOT the narrow symbol the header row draws, which VoiceOver reads out
    /// as the single letter "W". Same idiom, and the same reason, as ``WorkoutWeekCell``'s
    /// `longWeekdayText`. Today keeps saying "Today" in that slot, which is the more useful fact.
    var accessibilityLabel: Text {
        guard let day, !weekdayName.isEmpty else { return weekdaylessLabel }
        let dayName = isToday ? Text("Today") : Text(verbatim: weekdayName)
        if isFuture { return Text("\(dayName), day \(day)") }
        if let tag { return Text("\(dayName), day \(day), feeling \(tag.label)") }
        if hasData { return Text("\(dayName), day \(day), has data") }
        return Text("\(dayName), day \(day)")
    }

    /// The sentence family for a cell with no weekday to open with: a blank pad cell, or the day
    /// whose `Date` the layout calendar could not resolve.
    ///
    /// Kept as whole sentences rather than degrading to `Text("\(Text(verbatim: "")), day 5")`,
    /// which would put a leading comma into a translated string and into speech. A computed
    /// property rather than a `func` taking the day, so the `guard` that unwraps it lives here
    /// once.
    private var weekdaylessLabel: Text {
        guard let day else { return Text("Empty calendar cell") }
        if isFuture { return Text("Day \(day)") }
        if let tag {
            return isToday
                ? Text("Today, day \(day), feeling \(tag.label)")
                : Text("Day \(day), feeling \(tag.label)")
        }
        if hasData {
            return isToday ? Text("Today, day \(day), has data") : Text("Day \(day), has data")
        }
        return isToday ? Text("Today, day \(day)") : Text("Day \(day)")
    }
}

/// Pure month-layout model for the journal calendar: title, weekday symbols, and the padded cell
/// grid with feeling tags and has-data flags attached.
///
/// Layered over the shared ``MonthGridModel`` (which owns the calendar math and canonical day
/// keys) and computed fresh each render from the `allDays` map. Today's cell deliberately carries
/// no tag (today is highlighted by the ring instead); `hasData` counts meals, workouts, sleep,
/// journals, bottles, and hygiene. A plain struct so the layout math is testable without SwiftUI.
struct JournalMonthModel {
    let monthTitle: String
    let weekdaySymbols: [String]
    let cells: [JournalMonthCell]

    private let cellsByDay: [Int: JournalMonthCell]

    init(date: Date, allDays: [String: FernletDay], todayKey: String, calendar: Calendar = .current) {
        let grid = MonthGridModel(date: date, todayKey: todayKey, calendar: calendar)

        self.monthTitle = grid.monthTitle
        self.weekdaySymbols = grid.weekdaySymbols

        let blanks = (0..<grid.leadingBlanks).map { _ in
            JournalMonthCell(day: nil, dateKey: nil, tag: nil, isToday: false, isFuture: false, hasData: false)
        }
        let days = grid.days.map { gridDay -> JournalMonthCell in
            let dayData = allDays[gridDay.dateKey]
            let tag = gridDay.isToday ? nil : dayData?.journals.last?.tag
            let hasData: Bool = {
                guard let dayData else { return false }
                return !dayData.meals.isEmpty || !dayData.workouts.isEmpty
                    || dayData.sleep != nil || !dayData.journals.isEmpty
                    || dayData.bottleCount > 0 || !dayData.hygiene.isEmpty
            }()
            return JournalMonthCell(
                day: gridDay.day,
                dateKey: gridDay.dateKey,
                tag: tag,
                isToday: gridDay.isToday,
                isFuture: gridDay.isFuture,
                hasData: hasData,
                // Spoken, never drawn (T2-17). The ABBREVIATED NAME, not the narrow initial the
                // header row uses: VoiceOver reads a narrow symbol out as one letter. `.formatted`
                // follows the user's locale, which is what a spoken weekday should do — the
                // canonical `dateKey` above is the thing that must stay locale-independent.
                weekdayName: gridDay.date?.formatted(.dateTime.weekday(.abbreviated)) ?? ""
            )
        }
        self.cells = blanks + days
        self.cellsByDay = Dictionary(uniqueKeysWithValues: zip(grid.days.map(\.day), days))
    }

    /// Returns the cell for one shared-grid slot: the blank pad cell for `nil`, else the computed
    /// cell for that day of the month.
    func cell(for gridDay: MonthGridDay?) -> JournalMonthCell {
        guard let gridDay, let cell = cellsByDay[gridDay.day] else {
            return JournalMonthCell(day: nil, dateKey: nil, tag: nil, isToday: false, isFuture: false, hasData: false)
        }
        return cell
    }
}

// MARK: - Journal Row

/// A single journal entry row: tag dot and label, the entry text (or an honest placeholder), and
/// any emotion labels.
///
/// Shared by today's list, the previous list (compact, with a date), and ``DayDetailView``. The
/// empty-text branch is deliberately two-way: `isQuickMood` marks a genuine tag-only check-in,
/// while empty text without that marker means the words are sealed and unavailable right now
/// (locked, or synced ahead of the sealed narrative) — the row must never claim a sealed entry
/// was "just a check-in".
struct JournalRow: View {
    var entry: JournalEntry
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(entry.tag.color).frame(width: 10, height: 10)
                Text(entry.tag.label).font(.fernlet(.labelSmall)).foregroundStyle(Color.slate)
                if compact {
                    Text(FernletDate.shortDate(for: entry.date)).font(.fernlet(.labelSmall)).foregroundStyle(Color.slate)
                }
            }
            if entry.text.isEmpty {
                if entry.isQuickMood {
                    // Positively a tag-only mood check-in (one-tap mood): no text, just the feeling above.
                    Text("A quick mood check-in.")
                        .font(.fernlet(.bubble))
                        .foregroundStyle(Color.slate)
                } else {
                    // Empty text without the check-in marker: the words are sealed and unavailable in
                    // this state (locked, or synced from another device before the sealed narrative
                    // restored) — never claim the entry was "just a check-in".
                    Text("This entry is sealed.")
                        .font(.fernlet(.bubble))
                        .foregroundStyle(Color.slate)
                }
            } else {
                Text(entry.text)
                    .font(.fernlet(.body))
                    .lineLimit(compact ? 3 : nil)
            }
            if !entry.emotions.isEmpty {
                Text(entry.emotions.joined(separator: ", "))
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.moss)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Day Detail View

/// The full-day review screen for one dateKey: summary blurb and daily score, macros and
/// micronutrients, meals, movement, water, sleep, journal entries, and the care checklist.
///
/// Pushed from the journal calendar. Loads its day via
/// ``FernletStore/loadDayWithDecryptedJournals(for:)``, so sealed journal text is hydrated when a key is
/// active, and refreshes after its ``DayEditSheet`` or ``JournalEntryEditorSheet`` dismisses. The
/// score card recomputes ``FernletStore/dailyHealthScore(for:day:)`` for the day; the sugar limit row
/// knowingly applies the FDA added-sugars reference to total sugar (see the inline note).
struct DayDetailView: View {
    var store: FernletStore
    var dateKey: String
    /// The injected capture-friction state, read here only to RE-INJECT into the two sheets this
    /// view presents (``DayEditSheet``, ``JournalEntryEditorSheet``) — the explicit
    /// per-presentation-site convention; a missing environment object in a sheet is a runtime
    /// crash, not a compile error.
    @Environment(CaptureProtectionState.self) private var captureProtection
    @State private var day: FernletDay
    @State private var showEditSheet = false
    @State private var editingJournal: JournalEntryEditTarget?

    init(store: FernletStore, dateKey: String) {
        self.store = store
        self.dateKey = dateKey
        _day = State(initialValue: store.loadDayWithDecryptedJournals(for: dateKey))
    }

    private func refresh() {
        day = store.loadDayWithDecryptedJournals(for: dateKey)
    }

    private var date: Date {
        FernletDate.date(fromDayKey: dateKey) ?? .now
    }

    private var navigationTitle: String {
        if dateKey == store.todayKey { return "Today" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private var reviewTitle: String {
        if dateKey == store.todayKey { return "Today so far" }
        let cal = Calendar.current
        if let yesterday = cal.date(byAdding: .day, value: -1, to: .now),
           FernletDate.dayKey(for: yesterday) == dateKey { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return "Your \(formatter.string(from: date))"
    }

    private var reviewBlurb: String {
        if let summary = dailyHealthScore.daySummaryText?.trimmingCharacters(in: .whitespacesAndNewlines), summary.isEmpty == false {
            return summary
        }
        var parts: [String] = []
        if let tag = day.journals.last?.tag { parts.append("Feeling \(tag.label.lowercased())") }
        if day.meals.count > 0 { parts.append("\(day.meals.count) \(day.meals.count == 1 ? "meal" : "meals")") }
        if day.workouts.count > 0 { parts.append(day.workouts.count == 1 ? "a workout" : "\(day.workouts.count) workouts") }
        if let sleep = day.sleep { parts.append("\(sleep.quality.label.lowercased()) sleep") }
        if day.bottleCount > 0 { parts.append("\(day.bottleCount) \(day.bottleCount == 1 ? "bottle" : "bottles")") }
        if parts.isEmpty { return "Nothing logged yet. Tap \"Edit day\" to add missed details." }
        return parts.joined(separator: " · ")
    }

    private var dailyHealthScore: DailyHealthScore {
        store.dailyHealthScore(for: dateKey, day: day)
    }

    /// Whether anything at all was logged for this day — the domain model's own definition, shared
    /// with active-day accrual and fresh-install detection so this screen can't drift from it.
    ///
    /// A day the user simply didn't track must not be graded: the computed score for an empty day
    /// lands in the terracotta band, so an untouched Tuesday used to open on a red "DAILY SCORE 31%"
    /// bar plus a macro card and a partial-nutrition warning for meals that don't exist.
    private var hasLoggedData: Bool {
        day.hasLoggedContent
    }

    private var dayScore: Double { dailyHealthScore.score }
    private var scoreState: CompanionState { dailyHealthScore.companionState }

    private var dayMacros: MacroTotals {
        day.meals.reduce(into: MacroTotals()) { totals, meal in
            totals.protein += meal.macros.protein
            totals.carbs += meal.macros.carbs
            totals.fat += meal.macros.fat
        }
    }

    private var dayMicronutrients: Micronutrients {
        Micronutrients.totals(for: day.meals)
    }

    private var micronutrientRows: [DayMicronutrientBreakdownRow] {
        let tracked = MicronutrientGapAnalyzer.trackedNutrients.compactMap { nutrient -> DayMicronutrientBreakdownRow? in
            guard let value = nutrient.value(dayMicronutrients) else { return nil }
            return DayMicronutrientBreakdownRow(
                name: nutrient.name,
                value: value,
                target: nutrient.recommendedDailyAmount,
                unit: nutrient.unit,
                isLimit: false
            )
        }
        let limitRows: [DayMicronutrientBreakdownRow] = [
            dayMicronutrients.sodium.map {
                DayMicronutrientBreakdownRow(name: "Sodium", value: $0, target: Double(store.nutritionTargets.sodiumLimit), unit: "mg", isLimit: true)
            },
            dayMicronutrients.saturatedFat.map {
                DayMicronutrientBreakdownRow(name: "Saturated fat", value: $0, target: Double(store.nutritionTargets.saturatedFatLimit), unit: "g", isLimit: true)
            },
            dayMicronutrients.sugar.map {
                // The 50 g reference is the FDA **added-sugars** DRV
                // (`FDADailyValues.addedSugarsLimitGrams`). This row shows *total* sugar
                // (`dayMicronutrients.sugar`), so applying the added-sugars ceiling here is
                // an intentional over-strict approximation — the catalog does not separate
                // added from total sugar per food. Kept as-is (not redesigned); the label
                // stays "Sugar" because the value is total sugar, not added sugar.
                DayMicronutrientBreakdownRow(name: "Sugar", value: $0, target: FDADailyValues.addedSugarsLimitGrams, unit: "g", isLimit: true)
            }
        ].compactMap { $0 }
        return Array((tracked + limitRows).prefix(12))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                reviewCard
                // Nutrition cards only when there is nutrition: an untracked day showed a full
                // macro card of targets (read as intake) and a micronutrient warning about meals
                // that were never logged.
                if hasLoggedData {
                    // "Macros", not "Macros today" — this screen shows a PAST day — and the fiber
                    // footer names what was actually eaten rather than reprinting the target. Both
                    // are what `MacroCard`'s `title:` / `fiberIntake:` parameters exist for.
                    MacroCard(
                        totals: dayMacros,
                        targets: store.nutritionTargets,
                        showCalories: store.settings.showCalories,
                        title: "Macros",
                        fiberIntake: dayMicronutrients.fiber
                    )
                    micronutrientBreakdown
                }
                mealsSection
                movementSection
                HStack(alignment: .top, spacing: 12) {
                    waterCard.frame(maxWidth: .infinity)
                    sleepCard.frame(maxWidth: .infinity)
                }
                journalsSection
                careCard
            }
            .padding(20)
        }
        .background(Color.parchment)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        // Opaque parchment bar: without it the review card's score pills scrolled up THROUGH the
        // transparent title bar, between the back button and "Edit day".
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color.parchment, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showEditSheet = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "pencil")
                        Text("Edit day")
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
        .sheet(isPresented: $showEditSheet, onDismiss: refresh) {
            DayEditSheet(store: store, dateKey: dateKey, initialDay: day)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
                .environment(captureProtection)
        }
        .sheet(item: $editingJournal, onDismiss: refresh) { target in
            // `.large` only — see the note on JournalView's presentation of the same sheet.
            JournalEntryEditorSheet(store: store, dateKey: target.dateKey, entry: target.entry)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
                .environment(captureProtection)
        }
    }

    private var micronutrientBreakdown: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Micronutrients")
                    Spacer()
                    Text(micronutrientRows.isEmpty ? "No snapshots" : "\(micronutrientRows.count) tracked")
                        .font(.fernlet(.stat))
                        .foregroundStyle(Color.slate)
                }
                // Only meaningful once meals exist: with none, "some meals were logged without
                // micronutrients" describes meals that were never logged at all.
                if !day.meals.isEmpty, dayMicronutrients.completeness < 0.5 {
                    Text("Partial nutrition data — some meals were logged without micronutrients.")
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
                if micronutrientRows.isEmpty {
                    EmptyState(text: "Meal micronutrient snapshots will appear here.")
                } else {
                    VStack(spacing: 10) {
                        ForEach(micronutrientRows) { row in
                            DayMicronutrientRow(row: row)
                        }
                    }
                }
            }
        }
    }

    private var reviewCard: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(reviewTitle)
                    .font(.fernlet(.header))
                    .foregroundStyle(Color.bark)
                Text(reviewBlurb)
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                    .overlay(Color.bark.opacity(0.08))
                    .padding(.vertical, 2)
                if hasLoggedData {
                    HStack {
                        Text("Daily score")
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.slate)
                            .tracking(0.5)
                            .textCase(.uppercase)
                        Spacer()
                        Text("\(Int(dayScore * 100))%")
                            .font(.fernlet(.stat))
                            .foregroundStyle(scoreState.color)
                    }
                    HealthBar(state: scoreState, value: dayScore)
                } else {
                    // A day nobody logged isn't a bad day — never grade it.
                    Text("No score — nothing was logged")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                        .tracking(0.5)
                        .textCase(.uppercase)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var mealsSection: some View {
        FernletScrollSection("Food eaten") {
            if day.meals.isEmpty {
                EmptyState(text: "No meals logged")
            } else {
                ForEach(Array(day.meals.enumerated()), id: \.element.id) { index, meal in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meal.name)
                                .font(.fernlet(.body))
                                .foregroundStyle(Color.bark)
                            Text("P \(meal.macros.protein)g · C \(meal.macros.carbs)g · F \(meal.macros.fat)g")
                                .font(.fernlet(.stat))
                                .foregroundStyle(Color.slate)
                        }
                        Spacer()
                        Text(verbatim: meal.mealType.displayName)
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(meal.mealType.color)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(meal.mealType.color.opacity(0.12), in: Capsule())
                    }
                    .padding(.vertical, 4)
                    if index < day.meals.count - 1 { FernletRowDivider() }
                }
            }
        }
    }

    private var movementSection: some View {
        FernletScrollSection("Movement") {
            if day.workouts.isEmpty {
                EmptyState(text: "No workouts logged")
            } else {
                ForEach(Array(day.workouts.enumerated()), id: \.element.id) { index, workout in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workout.name)
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.bark)
                        // `displayWord`, not the frozen `rawValue`: the type beside it was already
                        // localized, so this line read half-translated.
                        Text(verbatim: "\(workout.type.displayName) · \(workout.intensity.displayWord.localizedCapitalized)")
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.slate)
                    }
                    .padding(.vertical, 4)
                    if index < day.workouts.count - 1 { FernletRowDivider() }
                }
            }
        }
    }

    private var waterCard: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionLabel("Water")
                    Spacer()
                    Image(systemName: "drop.fill")
                        .font(.caption)
                        .foregroundStyle(day.bottleCount > 0 ? Color.slate : Color.slate.opacity(0.3))
                }
                Text(day.bottleCount == 0 ? "None logged" : "\(day.bottleCount) \(day.bottleCount == 1 ? "bottle" : "bottles")")
                    .font(.fernlet(.stat))
                    .foregroundStyle(day.bottleCount == 0 ? Color.slate.opacity(0.45) : Color.bark)
                if day.bottleCount > 0 {
                    Text("\(day.bottleCount * store.settings.bottleOz) oz total")
                        .font(.fernlet(.stat))
                        .foregroundStyle(Color.slate)
                }
            }
        }
    }

    private var sleepCard: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionLabel("Rest")
                    Spacer()
                    Image(systemName: "moon.fill")
                        .font(.caption)
                        .foregroundStyle(day.sleep != nil ? Color.slate : Color.slate.opacity(0.3))
                }
                if let sleep = day.sleep {
                    Text(sleep.quality.label)
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                    if let hours = sleep.hours {
                        let h = hours.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(hours)) : String(hours)
                        Text("\(h)h")
                            .font(.fernlet(.stat))
                            .foregroundStyle(Color.slate)
                    }
                } else {
                    Text("Not logged")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.slate.opacity(0.45))
                }
            }
        }
    }

    private var journalsSection: some View {
        FernletScrollSection("Journal entries") {
            if day.journals.isEmpty {
                EmptyState(text: "No journal entries")
            } else {
                ForEach(Array(day.journals.enumerated()), id: \.element.id) { index, entry in
                    Button { editingJournal = JournalEntryEditTarget(entry: entry, dateKey: dateKey) } label: {
                        JournalRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                    if index < day.journals.count - 1 { FernletRowDivider() }
                }
            }
        }
    }

    private var careCard: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                let progress = store.personalCareProgress(for: day)
                HStack {
                    SectionLabel("Care checklist")
                    Spacer()
                    Text("\(progress.completed)/\(progress.total)")
                        .font(.fernlet(.stat))
                        .foregroundStyle(progress.completed == progress.total ? Color.moss : Color.slate)
                }
                HStack(spacing: 3) {
                    ForEach(store.personalCareTasks) { task in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(store.isPersonalCareTaskCompleted(task, in: day) ? Color.moss : Color.bark.opacity(0.1))
                            .frame(height: 6)
                    }
                }
                PersonalCareTaskGrid {
                    ForEach(store.personalCareTasks) { task in
                        Label(task.label, systemImage: task.systemImage)
                            .font(.fernlet(.labelSmall))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(store.isPersonalCareTaskCompleted(task, in: day) ? Color.moss : Color.slate.opacity(0.5))
                            .background(
                                store.isPersonalCareTaskCompleted(task, in: day) ? Color.moss.opacity(0.12) : Color.bark.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                    }
                }
            }
        }
    }
}

/// The personal-care task grid's shared layout: one adaptive column whose minimum width grows
/// with Dynamic Type.
///
/// The same chip grid is drawn twice — read-only on ``DayDetailView``'s care card and tappable in
/// the journal sheet's personal-care field — and both stated the adaptive column's minimum as a
/// bare `108`. A bare number cannot scale, so at accessibility text sizes the cell held its 108pt
/// while the label inside it grew, and `.lineLimit(1)` turned "Brush teeth" into "Brush…"
/// (accessibility review T2-11 / wall rule A5-GRID-SCALES).
///
/// The wrapper exists so ONE ``cellMinimum`` serves both call sites: `@ScaledMetric` reads the
/// environment, so it has to live on a view — it cannot be a shared constant without becoming a
/// mutable global, which the Power-of-10 wall forbids. Callers supply only the cells.
private struct PersonalCareTaskGrid<Content: View>: View {
    /// The grid's cells, supplied by the call site.
    private let content: () -> Content
    /// The adaptive column's minimum width. `108` is the value at the default text size, so
    /// nothing moves for a user who never changed it; `relativeTo: .caption` is the style
    /// `.fernlet(.labelSmall)` — the chips' own font — resolves against, so cell and label grow
    /// together.
    @ScaledMetric(relativeTo: .caption) private var cellMinimum: CGFloat = 108

    /// Creates the grid around caller-supplied cells.
    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: cellMinimum), spacing: 6)], spacing: 6, content: content)
    }
}

/// Row model for one micronutrient in the day breakdown: value, target-or-limit, and derived
/// progress, display strings, and status color.
///
/// Built by ``DayDetailView`` from the day's summed `Micronutrients` (tracked nutrients get
/// targets; sodium, saturated fat, and sugar get limits) and rendered by ``DayMicronutrientRow``.
/// For limits the status flips at the ceiling; for targets it grades by progress.
struct DayMicronutrientBreakdownRow: Identifiable {
    var name: String
    var value: Double
    var target: Double
    var unit: String
    var isLimit: Bool

    var id: String { "\(name)-\(unit)" }

    var progress: Double {
        // Same reasoning as `formatted(_:)`: a persisted non-finite total must not reach the bar's
        // width (a NaN fraction paints a CoreGraphics error, not a bar).
        guard target > 0, value.isFinite else { return 0 }
        return min(max(value / target, 0), 1)
    }

    var displayValue: String {
        "\(Self.formatted(value))\(unit)"
    }

    var targetText: String {
        "\(isLimit ? "limit" : "target") \(Self.formatted(target))\(unit)"
    }

    var statusColor: Color {
        if isLimit {
            return value <= target ? .moss : .terracotta
        }
        if progress >= 0.7 { return .moss }
        if progress >= 0.35 { return .goldenrod }
        return .slate
    }

    /// Largest amount this row will render as a number. R5: the value is a SUM of meal snapshots,
    /// which can carry peer- or page-supplied numbers persisted (and CloudKit-synced) before the
    /// import sanitisers existed, and `Int(_: Double)` TRAPS outside `Int`'s range. A wire fix
    /// cannot heal an already-poisoned row, so this renderer must be total.
    private static let maxDisplayableAmount = 1_000_000_000.0

    private static func formatted(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let bounded = min(max(value, 0), maxDisplayableAmount)
        if bounded >= 100 || bounded.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(bounded.rounded()))"
        }
        return bounded.formatted(.number.precision(.fractionLength(1)))
    }
}

/// The rendered micronutrient row: name, value, a thin progress bar, and the target/limit caption.
///
/// Pure presentation over one ``DayMicronutrientBreakdownRow``; all color and progress decisions
/// live in the model.
struct DayMicronutrientRow: View {
    var row: DayMicronutrientBreakdownRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.name)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.bark)
                Spacer()
                Text(row.displayValue)
                    .font(.fernlet(.stat))
                    .foregroundStyle(row.statusColor)
            }
            HStack(spacing: 8) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.bark.opacity(0.10))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(row.statusColor.opacity(0.85))
                            .frame(width: proxy.size.width * row.progress)
                    }
                }
                .frame(height: 7)
                Text(row.targetText)
                    .font(.fernlet(.stat))
                    .foregroundStyle(Color.slate)
                    .frame(width: 82, alignment: .trailing)
            }
        }
    }
}

// MARK: - Day Edit Sheet

/// The catch-up editor for a whole (usually past) day: add a journal entry, a meal, a workout,
/// and set water, sleep, and personal-care completion in one pass.
///
/// Opened from ``DayDetailView``'s "Edit day" button. Water and care are always written on save;
/// sleep only when it existed or the user actually entered something; journal/meal/workout only
/// when non-empty — all through the corresponding ``FernletStore`` dated mutation methods, so a
/// past day's journal text still flows through the sealing path. Backfilled workouts are pinned to noon
/// of the target day. Shares the ``JournalContinuationDetector`` long-entry banner. Chrome is the
/// 2026-08-21 template: the draft-guard header carries Cancel and the dated title; Save commits
/// bottom-right.
struct DayEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var store: FernletStore
    var dateKey: String
    let initialDay: FernletDay

    @State private var journalText = ""
    /// Nil until the user taps a chip: a preselected "Neutral" made a day with no journal look
    /// pre-filled, and saving one then wrote a feeling the user never chose.
    @State private var journalTag: FeelingTag?
    @State private var promptedReasons: Set<JournalPromptReason> = []
    @State private var journalPromptNotification: JournalPromptNotification?
    @State private var mealDescription = ""
    @State private var workoutName = ""
    @State private var workoutType: WorkoutType = .mixed
    @State private var workoutIntensity: WorkoutIntensity = .moderate
    /// Whether the user actually picked a workout type or intensity. The name field is optional, so
    /// this is what tells a deliberate "I did a mixed workout" apart from an untouched section.
    @State private var workoutTouched = false
    @State private var bottleCount: Int
    /// Nil when the day has no sleep entry and the user hasn't chosen one — an unselected row means
    /// "no change", never "Ok".
    @State private var sleepQuality: SleepQuality?
    @State private var sleepHoursText: String
    @State private var sleepNote: String
    @State private var completedPersonalCareTaskIDs: Set<String>

    private var limitedJournalText: Binding<String> {
        Binding(
            get: { journalText },
            set: { updateJournalText($0) }
        )
    }

    /// R3: the optional sleep note is bounded where the text enters, so an unbounded paste never
    /// reaches the day snapshot.
    private static let maxSleepNoteLength = 200

    private var limitedSleepNote: Binding<String> {
        Binding(
            get: { sleepNote },
            set: { sleepNote = String($0.prefix(Self.maxSleepNoteLength)) }
        )
    }

    init(store: FernletStore, dateKey: String, initialDay: FernletDay) {
        self.store = store
        self.dateKey = dateKey
        self.initialDay = initialDay
        _bottleCount = State(initialValue: initialDay.bottleCount)
        _sleepQuality = State(initialValue: initialDay.sleep?.quality)
        _sleepHoursText = State(initialValue: Self.hoursText(initialDay.sleep?.hours))
        _sleepNote = State(initialValue: initialDay.sleep?.note ?? "")
        _completedPersonalCareTaskIDs = State(initialValue: initialDay.completedPersonalCareTaskIDs)
    }

    /// The editable text for a stored sleep duration. Shared by the initial value and the
    /// dirty-check, so "unchanged" can never drift from "what was seeded".
    private static func hoursText(_ hours: Double?) -> String {
        guard let hours else { return "" }
        return hours.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(hours)) : String(hours)
    }

    /// Whether this catch-up sheet holds anything a swipe-down would throw away.
    private var isDirty: Bool {
        !journalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || journalTag != nil
            || !mealDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !workoutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || workoutTouched
            || bottleCount != initialDay.bottleCount
            || sleepQuality != initialDay.sleep?.quality
            || sleepHoursText != Self.hoursText(initialDay.sleep?.hours)
            || sleepNote != (initialDay.sleep?.note ?? "")
            || completedPersonalCareTaskIDs != initialDay.completedPersonalCareTaskIDs
    }

    private var formattedDate: String {
        guard let d = FernletDate.date(fromDayKey: dateKey) else { return dateKey }
        return d.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    journalField
                    mealField
                    workoutField
                    waterField
                    sleepField
                    personalCareField
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: "Save") {
                saveAll()
                dismiss()
            }
        }
        .background(Color.parchment)
        .overlay(alignment: .top) {
            if let journalPromptNotification {
                JournalPromptNotificationView(notification: journalPromptNotification) {
                    openJournalApp()
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: journalPromptNotification?.id)
        // A swipe-down used to throw away a whole day's catch-up with no warning. The guard also
        // renders the pinned template header (Cancel + title; "Edit %@" localizes around the
        // runtime date).
        .fernletDraftGuard(isDirty: isDirty, title: "Edit \(formattedDate)") { dismiss() }
        // Capture FRICTION (never a security control): a past day's edit sheet can hold that
        // day's journal text, so it is one of the six in-scope surfaces.
        .captureProtected(surface: "dayEdit")
    }

    /// Feeling chips + the 800-character journal editor for the edited day.
    private var journalField: some View {
        SheetField("Journal entry") {
            VStack(alignment: .leading, spacing: 10) {
                FlowLayout(spacing: 8) {
                    ForEach(FeelingTag.allCases) { option in
                        Button(option.label) { journalTag = option }
                            .buttonStyle(ChipButtonStyle(selected: journalTag == option))
                    }
                }
                SheetTextEditor(text: limitedJournalText, placeholder: "Add a note about this day…", minHeight: 100)
                Text("\(journalText.count)/800")
                    .font(.fernlet(.stat))
                    .foregroundStyle(Color.slate)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// The single free-text meal line added to the edited day.
    private var mealField: some View {
        SheetField("Add a meal") {
            TextField("What did you eat?", text: $mealDescription)
                .submitLabel(.done)
                .sheetTextInput()
        }
    }

    /// Optional workout name plus the type and intensity menus.
    ///
    /// The name really is optional now: picking a type or intensity is enough to log the workout,
    /// and the type's own label stands in for the name.
    private var workoutField: some View {
        SheetField("Add a workout") {
            VStack(spacing: 8) {
                TextField("Workout name (optional)", text: $workoutName)
                    .submitLabel(.done)
                    .sheetTextInput()
                HStack(spacing: 8) {
                    Menu {
                        ForEach(WorkoutType.allCases) { type in
                            Button {
                                workoutType = type
                                workoutTouched = true
                            } label: {
                                Text(verbatim: type.displayName)
                            }
                        }
                    } label: {
                        menuLabel(workoutType.displayName)
                    }

                    Menu {
                        ForEach(WorkoutIntensity.allCases) { intensity in
                            Button(intensity.displayWord.localizedCapitalized) {
                                workoutIntensity = intensity
                                workoutTouched = true
                            }
                        }
                    } label: {
                        menuLabel(workoutIntensity.displayWord.localizedCapitalized)
                    }
                }
            }
        }
    }

    /// The shared chrome for the two workout menus (title + chevron in a cream capsule).
    private func menuLabel(_ title: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(Color.bark)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption)
                .foregroundStyle(Color.slate)
        }
        .font(.fernlet(.label))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }

    /// The water-bottle stepper (0…30).
    private var waterField: some View {
        SheetField("Water") {
            Stepper("Bottles: \(bottleCount)", value: $bottleCount, in: 0...30)
                .padding(14)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// Sleep quality chips, the hours field, and the optional sleep note.
    private var sleepField: some View {
        SheetField("Sleep") {
            VStack(spacing: 10) {
                FlowLayout(spacing: 8) {
                    ForEach(SleepQuality.allCases) { option in
                        Button(option.label) { sleepQuality = option }
                            .buttonStyle(ChipButtonStyle(selected: sleepQuality == option))
                    }
                }
                HStack(spacing: 12) {
                    TextField("Hours (e.g. 7.5)", text: $sleepHoursText)
                        .keyboardType(.decimalPad)
                        .sheetTextInput(font: .fernlet(.label))
                    TextField("Note (optional)", text: limitedSleepNote)
                        .submitLabel(.done)
                        .sheetTextInput()
                }
            }
        }
    }

    /// The personal-care task grid for the edited day.
    private var personalCareField: some View {
        SheetField("Personal care") {
            PersonalCareTaskGrid {
                ForEach(store.personalCareTasks) { task in
                    Button { togglePersonalCareTask(task) } label: {
                        Label(task.label, systemImage: task.systemImage)
                            .font(.fernlet(.labelSmall))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(completedPersonalCareTaskIDs.contains(task.id) ? Color.moss : Color.slate)
                            .background(
                                completedPersonalCareTaskIDs.contains(task.id) ? Color.moss.opacity(0.12) : Color.bark.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func togglePersonalCareTask(_ task: PersonalCareTask) {
        if completedPersonalCareTaskIDs.contains(task.id) {
            completedPersonalCareTaskIDs.remove(task.id)
        } else {
            completedPersonalCareTaskIDs.insert(task.id)
        }
    }

    private func updateJournalText(_ newValue: String) {
        let cappedText = String(newValue.prefix(JournalContinuationDetector.maxCharacters))
        if cappedText != journalText {
            journalText = cappedText
        }

        if newValue.count > JournalContinuationDetector.maxCharacters {
            promptIfNeeded(.limitReached)
            return
        }

        if let reason = JournalContinuationDetector.reason(for: newValue) {
            promptIfNeeded(reason)
        }
    }

    private func promptIfNeeded(_ reason: JournalPromptReason) {
        guard promptedReasons.contains(reason) == false else { return }
        promptedReasons.insert(reason)
        showJournalPromptNotification(reason)
    }

    private func showJournalPromptNotification(_ reason: JournalPromptReason) {
        let notification = JournalPromptNotification(reason: reason)
        journalPromptNotification = notification

        // The banner offers an action — it opens the long-form journaling app — so it gets the
        // stretched ACTION window, not the notice one. A prompt that has gone by the time the
        // VoiceOver cursor reaches it is the same as no prompt at all.
        let window = FernletDismissalWindow.system.window(
            standard: .seconds(6),
            assistive: FernletDismissalWindow.assistiveActionWindow)
        Task { @MainActor in
            do {
                try await Task.sleep(for: window)
            } catch {
                // Cancelled: this sheet is gone or a newer banner owns the state — touch nothing.
                return
            }
            if journalPromptNotification?.id == notification.id {
                journalPromptNotification = nil
            }
        }
    }

    private func openJournalApp() {
        journalPromptNotification = nil
        guard let url = URL(string: "moments://") else { return }
        openURL(url)
    }

    /// The typed sleep hours, or nil when they are unusable.
    ///
    /// R5: the value is stored verbatim in the day snapshot, and `JSONEncoder`'s default
    /// non-conforming-float strategy throws on a non-finite double, so `Double("nan")`,
    /// `Double("1e400")` and negatives (all reachable by paste or a hardware keyboard) are rejected
    /// here instead of corrupting the day.
    private func validatedSleepHours() -> Double? {
        guard let parsed = LocaleTolerantNumber.double(from: sleepHoursText) else { return nil }
        guard parsed.isFinite, (0...24).contains(parsed) else { return nil }
        return parsed
    }

    private func saveAll() {
        store.setBottleCount(bottleCount, date: dateKey)
        store.setPersonalCareTaskIDs(completedPersonalCareTaskIDs, date: dateKey)

        let hasSleepEntry = initialDay.sleep != nil
        let hoursEntered = !sleepHoursText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let sleepNoteEntered = !sleepNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // An untouched sleep row (no existing entry, no chip tapped, nothing typed) is "no change",
        // not a silent "Ok".
        if hasSleepEntry || hoursEntered || sleepNoteEntered || sleepQuality != nil {
            store.setSleep(hours: validatedSleepHours(), quality: sleepQuality ?? .ok, note: sleepNote, date: dateKey)
        }

        let journalTrimmed = journalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !journalTrimmed.isEmpty {
            store.addJournal(text: journalTrimmed, tag: journalTag ?? .neutral, date: dateKey)
        }

        let mealTrimmed = mealDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mealTrimmed.isEmpty {
            store.addMeal(from: mealTrimmed, date: dateKey)
        }

        // The name is genuinely optional: a touched type/intensity logs the workout under the
        // type's own label. Without this, choosing "Cardio · Hard" and tapping Save recorded
        // nothing at all.
        let workoutTrimmed = workoutName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !workoutTrimmed.isEmpty || workoutTouched {
            let workoutDate = FernletDate.date(fromDayKey: dateKey) ?? .now
            let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: workoutDate) ?? workoutDate
            var workout = Workout(
                name: workoutTrimmed.isEmpty ? workoutType.rawValue : workoutTrimmed,
                type: workoutType, exercises: "",
                rpe: nil, notes: "", duration: nil, intensity: workoutIntensity
            )
            workout.completedAt = noon
            store.addWorkout(workout, date: dateKey)
        }
    }
}
