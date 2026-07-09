import SwiftUI
import FernletFoundation
import FernletDomainModel

struct JournalView: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?
    var isInHub: Bool = false
    @Binding var isTabBarCompact: Bool
    @Binding var tabResetToken: Int
    @State private var path = NavigationPath()
    @State private var displayedMonth: Date = .now
    @State private var allDays: [String: FernletDay] = [:]
    @State private var editingJournal: JournalEntryEditTarget?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        ScreenHeader(title: "Journal", subtitle: "A small record of being.", identifier: "screen.journal")
                        Spacer()
                        HeaderActionButton(systemImage: "plus") { activeSheet = .journal }
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

                    FernletScrollSection("Today") {
                        if store.day.journals.isEmpty {
                            Button { activeSheet = .journal } label: {
                                Text("How was today?")
                                    .font(.fernlet(.bubble))
                                    .foregroundStyle(Color.slate)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                        } else {
                            ForEach(Array(store.day.journals.enumerated()), id: \.element.id) { index, entry in
                                Button { editingJournal = JournalEntryEditTarget(entry: entry, dateKey: store.todayKey) } label: {
                                    JournalRow(entry: entry)
                                }
                                .buttonStyle(.plain)
                                if index < store.day.journals.count - 1 {
                                    FernletRowDivider()
                                }
                            }
                        }
                    }

                    if !store.previousJournals.isEmpty {
                        FernletScrollSection("Previous") {
                            let entries = Array(store.previousJournals.prefix(10))
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
                .padding(20)
            }
            .fernletTabBarCompaction($isTabBarCompact, resetToken: $tabResetToken)
            .background(Color.parchment)
            .navigationTitle("")
            .toolbar(isInHub ? .hidden : .visible, for: .navigationBar)
            .navigationDestination(for: String.self) { dateKey in
                DayDetailView(store: store, dateKey: dateKey)
                    .onDisappear { allDays = store.loadDays() }
            }
        }
        .onAppear { allDays = store.loadDays() }
        .onChange(of: store.day.journals.count) { allDays = store.loadDays() }
        .onChange(of: store.day.meals.count) { allDays = store.loadDays() }
        .sheet(item: $editingJournal, onDismiss: { allDays = store.loadDays() }) { target in
            JournalEntryEditorSheet(store: store, dateKey: target.dateKey, entry: target.entry)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
    }
}

// MARK: - Journal Sheet

struct JournalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var store: FernletStore
    @State private var text = ""
    @State private var tag: FeelingTag = .neutral
    @State private var promptedReasons: Set<JournalPromptReason> = []
    @State private var journalPromptNotification: JournalPromptNotification?
    @State private var inspirationDismissed = false

    private var limitedText: Binding<String> {
        Binding(
            get: { text },
            set: { updateText($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Journal")
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

                    SheetField("Feeling") {
                        FlowLayout(spacing: 8) {
                            ForEach(FeelingTag.allCases) { option in
                                Button(option.label) { tag = option }
                                    .buttonStyle(ChipButtonStyle(selected: tag == option))
                            }
                        }
                    }

                    SheetField("How was today?") {
                        VStack(alignment: .leading, spacing: 10) {
                            inspirationChip
                            SheetTextEditor(text: limitedText, placeholder: "What happened today?", minHeight: 200)
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

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
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

struct JournalContinuationDetector {
    static let maxCharacters = 800

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

struct JournalPromptNotification: Identifiable, Equatable {
    let id = UUID()
    var reason: JournalPromptReason
}

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

struct JournalEntryEditTarget: Identifiable {
    var entry: JournalEntry
    var dateKey: String

    var id: UUID { entry.id }
}

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

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Edit journal")
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

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

                    Button(role: .destructive) {
                        store.deleteJournal(entry, date: dateKey)
                        dismiss()
                    } label: {
                        Label("Delete journal entry", systemImage: "trash")
                            .font(.fernlet(.label))
                            .foregroundStyle(Color.terracotta)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.terracotta.opacity(0.22), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
                .padding(.bottom, 10)
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

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
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

struct JournalCalendarCard: View {
    @Binding var displayedMonth: Date
    var allDays: [String: FernletDay]
    var todayKey: String
    var onDayTapped: (String) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private var cal: Calendar { .current }

    var body: some View {
        let model = JournalMonthModel(date: displayedMonth, allDays: allDays, todayKey: todayKey)
        return FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    Button {
                        displayedMonth = cal.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.slate)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)

                    Text(model.monthTitle)
                        .font(.fernlet(.headerMedium))
                        .foregroundStyle(Color.bark)
                        .frame(maxWidth: .infinity)

                    let isCurrentMonth = cal.isDate(displayedMonth, equalTo: .now, toGranularity: .month)
                    Button {
                        if !isCurrentMonth {
                            displayedMonth = cal.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(isCurrentMonth ? Color.slate.opacity(0.25) : Color.slate)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .disabled(isCurrentMonth)
                }

                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(Array(model.weekdaySymbols.enumerated()), id: \.offset) { _, day in
                        Text(day).font(.fernlet(.labelSmall)).foregroundStyle(Color.slate)
                    }
                    ForEach(model.cells) { cell in
                        JournalCalendarCell(cell: cell) {
                            if let key = cell.dateKey, !cell.isFuture {
                                onDayTapped(key)
                            }
                        }
                    }
                }
                tagLegend
            }
        }
    }

    private var tagLegend: some View {
        HStack {
            ForEach(FeelingTag.allCases) { tag in
                HStack(spacing: 4) {
                    Circle().fill(tag.color).frame(width: 8, height: 8)
                    Text(tag.label).font(.fernlet(.labelSmall)).foregroundStyle(Color.slate)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

// MARK: - Calendar Cell

struct JournalCalendarCell: View {
    var cell: JournalMonthCell
    var onTap: () -> Void

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
                            .font(.fernlet(.stat))
                            .fontWeight(cell.isToday ? .bold : .medium)
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
            }
        }
        .buttonStyle(.plain)
        .aspectRatio(1, contentMode: .fit)
        .disabled(cell.day == nil || cell.isFuture)
        .accessibilityLabel(cell.accessibilityLabel)
    }
}

// MARK: - Calendar Models

struct JournalMonthCell: Identifiable {
    let id = UUID()
    var day: Int?
    var dateKey: String?
    var tag: FeelingTag?
    var isToday: Bool
    var isFuture: Bool = false
    var hasData: Bool = false

    var fill: Color {
        if isFuture { return Color.softTaupe.opacity(0.05) }
        if let tag { return tag.color.opacity(isToday ? 0.38 : 0.28) }
        if isToday { return Color.moss.opacity(0.18) }
        if hasData { return Color.softTaupe.opacity(0.22) }
        return Color.softTaupe.opacity(day == nil ? 0.05 : 0.16)
    }

    var accessibilityLabel: String {
        guard let day else { return "Empty calendar cell" }
        if isFuture { return "Day \(day)" }
        return isToday ? "Today, day \(day)" : "Day \(day)\(hasData ? ", has data" : "")"
    }
}

struct JournalMonthModel {
    let monthTitle: String
    let todayText: String
    let weekdaySymbols: [String]
    let cells: [JournalMonthCell]

    init(date: Date, allDays: [String: FernletDay], todayKey: String, calendar: Calendar = .current) {
        let monthInterval = calendar.dateInterval(of: .month, for: date)
        assert(monthInterval != nil, "month interval required")
        let start = monthInterval?.start ?? date
        let range = calendar.range(of: .day, in: .month, for: date) ?? 1..<2
        let firstWeekday = calendar.component(.weekday, from: start)

        self.monthTitle = date.formatted(.dateTime.month(.wide).year())
        self.todayText = Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        self.weekdaySymbols = calendar.veryShortWeekdaySymbols

        let ymFormatter = DateFormatter()
        ymFormatter.locale = Locale(identifier: "en_US_POSIX")
        ymFormatter.dateFormat = "yyyy-MM"
        ymFormatter.calendar = Calendar(identifier: .gregorian)
        let yearMonth = ymFormatter.string(from: date)

        let blanks = (0..<(firstWeekday - 1)).map { _ in
            JournalMonthCell(day: nil, dateKey: nil, tag: nil, isToday: false, isFuture: false, hasData: false)
        }
        let days = range.map { d -> JournalMonthCell in
            let key = "\(yearMonth)-\(String(format: "%02d", d))"
            let dayData = allDays[key]
            let tag = (key == todayKey) ? nil : dayData?.journals.last?.tag
            let hasData: Bool = {
                guard let dayData else { return false }
                return !dayData.meals.isEmpty || !dayData.workouts.isEmpty
                    || dayData.sleep != nil || !dayData.journals.isEmpty
                    || dayData.bottleCount > 0 || !dayData.hygiene.isEmpty
            }()
            return JournalMonthCell(
                day: d,
                dateKey: key,
                tag: tag,
                isToday: key == todayKey,
                isFuture: key > todayKey,
                hasData: hasData
            )
        }
        self.cells = blanks + days
    }
}

// MARK: - Journal Row

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

struct DayDetailView: View {
    var store: FernletStore
    var dateKey: String
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
                DayMicronutrientBreakdownRow(name: "Sugar", value: $0, target: 50, unit: "g", isLimit: true)
            }
        ].compactMap { $0 }
        return Array((tracked + limitRows).prefix(12))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                reviewCard
                MacroCard(totals: dayMacros, targets: store.nutritionTargets, showCalories: store.settings.showCalories)
                micronutrientBreakdown
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
        }
        .sheet(item: $editingJournal, onDismiss: refresh) { target in
            JournalEntryEditorSheet(store: store, dateKey: target.dateKey, entry: target.entry)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
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
                if dayMicronutrients.completeness < 0.5 {
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
                        Text(meal.mealType.rawValue)
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
                        Text("\(workout.type.rawValue) · \(workout.intensity.rawValue.capitalized)")
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 6)], spacing: 6) {
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

struct DayMicronutrientBreakdownRow: Identifiable {
    var name: String
    var value: Double
    var target: Double
    var unit: String
    var isLimit: Bool

    var id: String { "\(name)-\(unit)" }

    var progress: Double {
        guard target > 0 else { return 0 }
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

    private static func formatted(_ value: Double) -> String {
        if value >= 100 || value.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(value.rounded()))"
        }
        return value.formatted(.number.precision(.fractionLength(1)))
    }
}

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

struct DayEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var store: FernletStore
    var dateKey: String
    let initialDay: FernletDay

    @State private var journalText = ""
    @State private var journalTag: FeelingTag = .neutral
    @State private var promptedReasons: Set<JournalPromptReason> = []
    @State private var journalPromptNotification: JournalPromptNotification?
    @State private var mealDescription = ""
    @State private var workoutName = ""
    @State private var workoutType: WorkoutType = .mixed
    @State private var workoutIntensity: WorkoutIntensity = .moderate
    @State private var bottleCount: Int
    @State private var sleepQuality: SleepQuality
    @State private var sleepHoursText: String
    @State private var sleepNote: String
    @State private var completedPersonalCareTaskIDs: Set<String>

    private var limitedJournalText: Binding<String> {
        Binding(
            get: { journalText },
            set: { updateJournalText($0) }
        )
    }

    init(store: FernletStore, dateKey: String, initialDay: FernletDay) {
        self.store = store
        self.dateKey = dateKey
        self.initialDay = initialDay
        _bottleCount = State(initialValue: initialDay.bottleCount)
        _sleepQuality = State(initialValue: initialDay.sleep?.quality ?? .ok)
        if let h = initialDay.sleep?.hours {
            _sleepHoursText = State(initialValue: h.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(h)) : String(h))
        } else {
            _sleepHoursText = State(initialValue: "")
        }
        _sleepNote = State(initialValue: initialDay.sleep?.note ?? "")
        _completedPersonalCareTaskIDs = State(initialValue: initialDay.completedPersonalCareTaskIDs)
    }

    private var formattedDate: String {
        guard let d = FernletDate.date(fromDayKey: dateKey) else { return dateKey }
        return d.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Edit \(formattedDate)")
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

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

                    SheetField("Add a meal") {
                        TextField("What did you eat?", text: $mealDescription)
                            .sheetTextInput()
                    }

                    SheetField("Add a workout") {
                        VStack(spacing: 8) {
                            TextField("Workout name (optional)", text: $workoutName)
                                .sheetTextInput()
                            HStack(spacing: 8) {
                                Menu {
                                    ForEach(WorkoutType.allCases) { type in
                                        Button(type.rawValue) { workoutType = type }
                                    }
                                } label: {
                                    HStack {
                                        Text(workoutType.rawValue)
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

                                Menu {
                                    ForEach(WorkoutIntensity.allCases) { intensity in
                                        Button(intensity.rawValue.capitalized) { workoutIntensity = intensity }
                                    }
                                } label: {
                                    HStack {
                                        Text(workoutIntensity.rawValue.capitalized)
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
                            }
                        }
                    }

                    SheetField("Water") {
                        Stepper("Bottles: \(bottleCount)", value: $bottleCount, in: 0...30)
                            .padding(14)
                            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                    }

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
                                    .sheetTextInput()
                                TextField("Note (optional)", text: $sleepNote)
                                    .sheetTextInput()
                            }
                        }
                    }

                    SheetField("Personal care") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 6)], spacing: 6) {
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

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
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

    private func saveAll() {
        store.setBottleCount(bottleCount, date: dateKey)
        store.setPersonalCareTaskIDs(completedPersonalCareTaskIDs, date: dateKey)

        let hasSleepEntry = initialDay.sleep != nil
        let hoursEntered = !sleepHoursText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let sleepNoteEntered = !sleepNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasSleepEntry || hoursEntered || sleepNoteEntered || sleepQuality != .ok {
            store.setSleep(hours: Double(sleepHoursText.replacingOccurrences(of: ",", with: ".")), quality: sleepQuality, note: sleepNote, date: dateKey)
        }

        let journalTrimmed = journalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !journalTrimmed.isEmpty {
            store.addJournal(text: journalTrimmed, tag: journalTag, date: dateKey)
        }

        let mealTrimmed = mealDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mealTrimmed.isEmpty {
            store.addMeal(from: mealTrimmed, date: dateKey)
        }

        let workoutTrimmed = workoutName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !workoutTrimmed.isEmpty {
            let workoutDate = FernletDate.date(fromDayKey: dateKey) ?? .now
            let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: workoutDate) ?? workoutDate
            var workout = Workout(
                name: workoutTrimmed, type: workoutType, exercises: "",
                rpe: nil, notes: "", duration: nil, intensity: workoutIntensity
            )
            workout.completedAt = noon
            store.addWorkout(workout, date: dateKey)
        }
    }
}
