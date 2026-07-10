import SwiftUI
import FernletFoundation
import FernletDomainModel
import FernletLock
import PrivateHealthStore
import PeriodContextBridge
import HealthKitGateway

struct PeriodTrackerView: View {
    var store: FernletStore
    var periodStore: PeriodTrackerStore
    var periodContext: PeriodContextBridge? = nil
    @Binding var activeSheet: FernletSheet?
    var isInHub: Bool = false
    @Binding var isTabBarCompact: Bool
    @Binding var tabResetToken: Int
    @Environment(FernletLockService.self) private var lockService
    @State private var authorization = HealthKitAuthorizationViewModel()
    @State private var selectedDay: SelectedPeriodDay?
    @State private var displayedMonth: Date = .now

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    periodAwarePrimer
                    if showsPrediction {
                        PredictionsCard(prediction: periodStore.prediction)
                    }
                    phaseTrendsCard
                    PeriodCalendarCard(
                        displayedMonth: $displayedMonth,
                        entriesByKey: entriesByKey,
                        todayKey: FernletDate.dayKey(for: Date()),
                        prediction: showsPrediction ? periodStore.prediction : nil,
                        onDayTapped: { date in selectedDay = SelectedPeriodDay(date: date) }
                    )
                    privacyBanner
                    recentEvents
                    if showsPrediction, let prediction = periodStore.prediction {
                        TrendsCard(prediction: prediction)
                    }
                }
                .padding(20)
            }
            .fernletTabBarCompaction($isTabBarCompact, resetToken: $tabResetToken)
            .background(Color.parchment)
            .toolbar(isInHub ? .hidden : .visible, for: .navigationBar)
            .navigationDestination(item: $selectedDay) { day in
                let dayEntry = entry(for: day.date)
                PeriodDayDetailView(
                    entry: dayEntry,
                    onEdit: { activeSheet = .logPeriod(targetDate: day.date, editingEntry: dayEntry) },
                    onDelete: {
                        Task {
                            try? await periodStore.deleteEntry(dayEntry)
                            // Keep the bridge's cached trends from outliving the deleted data (§5.3
                            // "deliberate forgetfulness"): recompute from the now-smaller entry set.
                            refreshContext()
                            selectedDay = nil
                        }
                    }
                )
            }
            .task(id: lockService.state) { await loadIfUnlocked() }
        }
    }

    var showsPrediction: Bool {
        !store.settings.hidePredictions
    }

    /// One-time first-use primer explaining period-aware care + the opt-in. Dismissal persists via
    /// `settings.periodContextPrimerSeen`.
    @ViewBuilder
    private var periodAwarePrimer: some View {
        if !store.settings.periodContextPrimerSeen {
            FernletCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Period-aware care", systemImage: "sparkles")
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)
                    Text("Once you've logged a few cycles, Fernlet can gently soften your daily score on the phases that tend to be harder for you, and show a cycle chip and outlook on Home. It's optional, stays on this device, and never leaves the app.")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                    HStack(spacing: 10) {
                        Button {
                            store.setPeriodAwareScoringEnabled(true)
                            store.markPeriodContextPrimerSeen()
                        } label: {
                            Text("Turn on")
                                .font(.fernlet(.label))
                                .foregroundStyle(Color.cream)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.moss, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Button {
                            store.markPeriodContextPrimerSeen()
                        } label: {
                            Text("Not now")
                                .font(.fernlet(.label))
                                .foregroundStyle(Color.slate)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.slate.opacity(0.10), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Per-phase wellbeing trends from the bridge — shown only when the user opted into period-aware care,
    /// isn't hiding predictions, and there are medium/high-confidence trends to report. Abstract phrasing
    /// only (no numbers): "Sleep tends to dip during your luteal phase."
    @ViewBuilder
    private var phaseTrendsCard: some View {
        let trends = reportableTrends
        if store.settings.periodAwareScoringEnabled, !store.settings.hidePredictions, !trends.isEmpty {
            FernletCard {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("How your phases tend to go")
                    ForEach(Array(trends.enumerated()), id: \.offset) { index, trend in
                        Text(phaseTrendSentence(trend))
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                        if index < trends.count - 1 { FernletRowDivider() }
                    }
                }
            }
        }
    }

    private var reportableTrends: [PeriodHealthTrend] {
        (periodContext?.currentTrends ?? [])
            .filter { $0.direction != .neutral && $0.confidence >= .medium && $0.phase != .unknown }
            .sorted { $0.confidence > $1.confidence }
            .prefix(4)
            .map { $0 }
    }

    private func phaseTrendSentence(_ trend: PeriodHealthTrend) -> String {
        let phase = trend.phase.title.lowercased()
        let verb: String
        switch trend.metric {
        case .sleep: verb = trend.direction == .worse ? "Sleep tends to dip" : "Sleep tends to be steadier"
        case .mood: verb = trend.direction == .worse ? "Mood tends to be tender" : "Mood tends to lift"
        case .exercise: verb = trend.direction == .worse ? "Movement tends to ease off" : "Movement tends to pick up"
        case .nutrition: verb = trend.direction == .worse ? "Eating tends to get lighter" : "Eating tends to feel steadier"
        case .symptomLoad: verb = trend.direction == .worse ? "Symptoms tend to gather" : "Symptoms tend to settle"
        }
        return "\(verb) during your \(phase) phase."
    }

    private var privacyBanner: some View {
        Text("Your period data stays on this device, behind your app lock.")
            .font(.fernlet(.bubble))
            .foregroundStyle(Color.slate)
            .fernletWrappingText()
    }

    private var header: some View {
        HStack(alignment: .top) {
            ScreenHeader(title: "Period", subtitle: phaseSubtitle, identifier: "screen.period")
            Spacer()
            HeaderActionButton(systemImage: "plus") { activeSheet = .logPeriod(targetDate: nil, editingEntry: nil) }
        }
    }

    private var phaseSubtitle: String {
        periodStore.currentPhase == .unknown ? "Your cycle, at a glance." : periodStore.currentPhase.title
    }

    private var entriesByKey: [String: CycleDayEntry] {
        Dictionary(uniqueKeysWithValues: periodStore.entries.map { ($0.dateKey, $0) })
    }

    private var recentEvents: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Recent events")
            FernletCard {
                let events = periodStore.entries.filter(\.hasObservedEvent).reversed().prefix(10)
                if events.isEmpty {
                    EmptyState(text: "No cycle events in the last 90 days.")
                } else {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.date.formatted(.dateTime.month(.abbreviated).day()))
                                .font(.fernlet(.label))
                                .foregroundStyle(Color.bark)
                            HStack(spacing: 6) {
                                Text(entry.flowLabel)
                                ForEach(entry.narrative?.symptomFlags.sorted() ?? []) { symptom in
                                    Text(symptom.title)
                                }
                            }
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.slate)
                            .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if index < events.count - 1 { FernletRowDivider() }
                    }
                }
            }
        }
    }

    private func loadIfUnlocked() async {
        periodStore.attachLockService(lockService)
        guard case .unlocked = lockService.state, let contentKey = lockService.contentKey() else { return }
        if !authorization.hasRequested(.cycleTracking) {
            await authorization.request(.cycleTracking)
        }
        await periodStore.loadEntries(unlockedContentKey: contentKey)
        refreshContext()
    }

    private func refreshContext() {
        let unlocked: Bool
        if case .unlocked = lockService.state { unlocked = true } else { unlocked = false }
        periodContext?.refresh(unlocked: unlocked, wellbeingByDay: store.periodWellbeingByDay)
    }

    private func entry(for date: Date) -> CycleDayEntry {
        let key = FernletDate.dayKey(for: date)
        return periodStore.entries.first { $0.dateKey == key } ?? CycleDayEntry(date: date, dateKey: key, samples: [], narrative: nil, phase: .unknown)
    }
}

// MARK: - Prediction Cards

private struct PredictionsCard: View {
    var prediction: CyclePrediction?

    var body: some View {
        FernletCard {
            if let prediction {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Likely next period")
                                .font(.fernlet(.labelSmall))
                                .foregroundStyle(Color.slate)
                            Text(formattedRange(prediction.likelyStartRange))
                                .font(.fernlet(.stat))
                                .foregroundStyle(Color.bark)
                        }
                        Spacer(minLength: 8)
                        Text(confidenceLabel(for: prediction.confidence))
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.bark)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.moss.opacity(0.14), in: Capsule())
                    }

                    Text("Cycles tracked: \(prediction.cyclesObserved)")
                        .font(.fernlet(.stat))
                        .foregroundStyle(Color.slate)
                }
            } else {
                EmptyState(text: "Log at least 3 cycles to see predictions.")
            }
        }
    }

    private func formattedRange(_ range: ClosedRange<Date>) -> String {
        if Calendar.current.isDate(range.lowerBound, inSameDayAs: range.upperBound) {
            return range.lowerBound.formatted(.dateTime.month(.abbreviated).day())
        }
        return "\(range.lowerBound.formatted(.dateTime.month(.abbreviated).day())) – \(range.upperBound.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private func confidenceLabel(for confidence: Double) -> String {
        if confidence < 0.4 { return "Low confidence" }
        if confidence < 0.7 { return "Building confidence" }
        return "High confidence"
    }
}

private struct TrendsCard: View {
    var prediction: CyclePrediction

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Average cycle length: \(prediction.averageCycleLength) days")
                    .font(.fernlet(.stat))
                    .foregroundStyle(Color.bark)
                Text("Your cycles vary by about ±\(prediction.variationDays) days.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
    }
}

// MARK: - Calendar Card

private struct PeriodCalendarCard: View {
    @Binding var displayedMonth: Date
    var entriesByKey: [String: CycleDayEntry]
    var todayKey: String
    var prediction: CyclePrediction?
    var onDayTapped: (Date) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private var cal: Calendar { .current }

    var body: some View {
        let model = PeriodMonthModel(date: displayedMonth, entriesByKey: entriesByKey, todayKey: todayKey, prediction: prediction)
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
                        PeriodCalendarCell(cell: cell) {
                            if let date = cell.date, !cell.isFuture {
                                onDayTapped(date)
                            }
                        }
                    }
                }

                flowLegend
            }
        }
    }

    private var flowLegend: some View {
        HStack(spacing: 12) {
            ForEach([
                (Color.dustyRose.opacity(0.22), "Light"),
                (Color.dustyRose.opacity(0.40), "Medium"),
                (Color.dustyRose.opacity(0.60), "Heavy")
            ], id: \.1) { color, label in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: 10, height: 10)
                    Text(label).font(.fernlet(.labelSmall)).foregroundStyle(Color.slate)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

// MARK: - Calendar Cell

private struct PeriodCalendarCell: View {
    var cell: PeriodMonthCell
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

// MARK: - Month Models

struct PeriodMonthCell: Identifiable {
    let id = UUID()
    var day: Int?
    var date: Date?
    var dateKey: String?
    var entry: CycleDayEntry?
    var projectedLevel: PredictedFlowLevel?
    var isToday: Bool
    var isFuture: Bool

    var fill: Color {
        guard day != nil else { return Color.softTaupe.opacity(0.05) }
        switch entry?.flowLevel {
        case .some(.heavy): return Color.dustyRose.opacity(0.60)
        case .some(.medium): return Color.dustyRose.opacity(0.40)
        case .some(.light): return Color.dustyRose.opacity(0.22)
        case .some(PeriodFlowLevel.none): return Color.bark.opacity(0.10)
        case .some(.unspecified): return Color.bark.opacity(0.14)
        case nil:
            if isFuture, let projectedLevel {
                return projectedFill(for: projectedLevel)
            }
            if isFuture { return Color.softTaupe.opacity(0.05) }
            return isToday ? Color.moss.opacity(0.18) : Color.softTaupe.opacity(0.16)
        }
    }

    private func projectedFill(for level: PredictedFlowLevel) -> Color {
        switch level {
        case .heavy: return Color.dustyRose.opacity(0.35)
        case .medium: return Color.dustyRose.opacity(0.35)
        case .light, .spotting: return Color.dustyRose.opacity(0.35)
        case .none: return Color.bark.opacity(0.35)
        }
    }

    var accessibilityLabel: String {
        guard let day else { return "Empty calendar cell" }
        if isFuture { return "Day \(day)" }
        if isToday { return "Today, day \(day)" }
        if let entry, entry.hasObservedEvent { return "Day \(day), \(entry.flowLabel)" }
        return "Day \(day)"
    }
}

struct PeriodMonthModel {
    let monthTitle: String
    let weekdaySymbols: [String]
    let cells: [PeriodMonthCell]

    init(date: Date, entriesByKey: [String: CycleDayEntry], todayKey: String, prediction: CyclePrediction?, calendar: Calendar = .current) {
        let monthInterval = calendar.dateInterval(of: .month, for: date)
        let start = monthInterval?.start ?? date
        let range = calendar.range(of: .day, in: .month, for: date) ?? 1..<2
        let firstWeekday = calendar.component(.weekday, from: start)

        self.monthTitle = date.formatted(.dateTime.month(.wide).year())
        self.weekdaySymbols = calendar.veryShortWeekdaySymbols

        let projectedLevelsByDay = Self.projectedLevelsByDay(for: prediction, calendar: calendar)
        let blanks = (0..<(firstWeekday - 1)).map { _ in
            PeriodMonthCell(day: nil, date: nil, dateKey: nil, entry: nil, projectedLevel: nil, isToday: false, isFuture: false)
        }
        let year = calendar.component(.year, from: start)
        let month = calendar.component(.month, from: start)
        let days = range.map { d -> PeriodMonthCell in
            let cellDate = calendar.date(from: DateComponents(year: year, month: month, day: d))
            let key = cellDate.map { FernletDate.dayKey(for: $0) } ?? String(format: "%04d-%02d-%02d", year, month, d)
            let entry = entriesByKey[key]
            return PeriodMonthCell(
                day: d,
                date: cellDate,
                dateKey: key,
                entry: entry,
                projectedLevel: entry == nil ? projectedLevelsByDay[key] : nil,
                isToday: key == todayKey,
                isFuture: key > todayKey
            )
        }
        self.cells = blanks + days
    }

    private static func projectedLevelsByDay(for prediction: CyclePrediction?, calendar: Calendar) -> [String: PredictedFlowLevel] {
        guard let prediction else { return [:] }
        let flowByDay = Dictionary(uniqueKeysWithValues: prediction.predictedFlow.map { day in
            (FernletDate.dayKey(for: day.date), day.level)
        })
        var result: [String: PredictedFlowLevel] = [:]
        let range = DateInterval(start: prediction.likelyStartRange.lowerBound, end: prediction.likelyStartRange.upperBound)
        for key in FernletDate.dayKeys(in: range, calendar: calendar) {
            result[key] = flowByDay[key] ?? .medium
        }
        return result
    }
}

// MARK: - Supporting Types

private struct SelectedPeriodDay: Identifiable, Hashable {
    var date: Date
    var id: TimeInterval { date.timeIntervalSinceReferenceDate }
}
