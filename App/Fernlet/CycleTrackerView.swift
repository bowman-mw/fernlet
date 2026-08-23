import SwiftUI
import FernletFoundation
import FernletDomainModel
import FernletLock
import PrivateHealthStore
import PeriodContextBridge
import HealthKitGateway
import FernletUI

/// App-target display fork over ``PeriodFlowLevel`` (review A4 follow-up F4).
///
/// `PeriodFlowLevel` lives in `PrivateHealthStore` — a SEALED module with, deliberately, no string
/// catalog: its job is ciphertext and HealthKit samples, and giving it one would invite copy to
/// accumulate behind the seal. Its `title` is `rawValue.capitalized`, i.e. a storage token wearing
/// paint, and `CycleDayEntry.flowLabel` returns the same English words. So the fork lands HERE, in
/// the app target, where `Bundle.main` is the right bundle and every consumer already lives.
///
/// Switching on the CASE rather than matching the label string is the point: the sealed module can
/// reword `flowLabel` freely and this stays correct, and a new case is a compiler error rather than
/// a silently English row.
extension PeriodFlowLevel {
    /// The localized flow word shown on the cycle calendar and its day detail.
    var displayName: String {
        switch self {
        case PeriodFlowLevel.none:
            String(localized: "cycle.flow.none", defaultValue: "None",
                   comment: "Menstrual flow recorded as explicitly none for that day (a sample exists and says no flow).")
        case .light:
            String(localized: "cycle.flow.light", defaultValue: "Light",
                   comment: "Menstrual flow level: light")
        case .medium:
            String(localized: "cycle.flow.medium", defaultValue: "Medium",
                   comment: "Menstrual flow level: medium")
        case .heavy:
            String(localized: "cycle.flow.heavy", defaultValue: "Heavy",
                   comment: "Menstrual flow level: heavy")
        case .unspecified:
            String(localized: "cycle.flow.unspecified", defaultValue: "Unspecified",
                   comment: "Menstrual flow recorded without a level — the sample exists but says nothing about how heavy.")
        }
    }
}

extension CycleDayEntry {
    /// The localized replacement for the sealed store's English ``flowLabel``.
    ///
    /// Distinguishes "no sample at all" from a sample that records `PeriodFlowLevel.none`, exactly
    /// as `flowLabel` does — the two mean different things to someone reading their own history.
    var flowDisplayName: String {
        guard let flowLevel else {
            return String(localized: "cycle.flow.noFlow", defaultValue: "No flow",
                          comment: "Shown for a day with no menstrual-flow sample at all, as opposed to a sample recording no flow.")
        }
        return flowLevel.displayName
    }
}

/// The Private hub's merged Cycle page: ONE layered month calendar carrying both period flow
/// tints and a distinct intimacy marker, with the period predictions/trends cards below and a
/// single plus-menu that can log either kind of event.
///
/// Replaces the separate Period and Intimacy pages. Each half renders only when its own derived
/// gate allows (`isPeriodTrackingVisible` / `isIntimacyTrackingVisible`), the page itself exists
/// only while at least one is visible (``PrivateHubView`` owns that), and the hidden half gets NO
/// on-page mention — Settings' AgeGateNotice owns the true reason.
///
/// Data rules carried over unchanged from the two retired pages:
/// - Period reads go through `PeriodTrackerStore` (fail-closed `isVisible` seam), reloaded via
///   `.task(id:)` keyed on ``LoadTrigger`` — the lock state PLUS both DERIVED visibility gates,
///   so un-hiding a half mid-mount restarts the load by construction (pre-merge the hub
///   re-created each page on un-hide; the merged page survives via the other half, so the flip
///   itself must be a load trigger). The view additionally skips the HealthKit *authorization
///   request* while period is hidden, since that prompt is view-level and outside the seam.
/// - Intimacy presence max-merges the sealed `IntimacyLogStore` funnel with HealthKit per-day
///   counts, and the view-level guard in `loadIntimacyCalendar` both SKIPS the HealthKit read
///   while hidden (the sealed seam never covered that read) and scrubs the decrypted @State the
///   moment the derived gate flips off.
/// Day taps push ``CycleDayDetailView`` with both halves, each gated the same way; the header
/// plus-menu routes through ``FernletSheet`` `.logPeriod` / `.logIntimacy` so the sheets own all
/// writes. The optional `PeriodContextBridge` is refreshed after loads and deletes so cached
/// phase trends never outlive the entries they were computed from.
struct CycleTrackerView: View {
    var store: FernletStore
    var periodStore: PeriodTrackerStore
    /// The gated funnel for intimacy sealed-note reads. Owned by `ContentView`, threaded through
    /// `PrivateHubView`. Its `isVisible` is wired to the derived gate in `ContentView`'s launch
    /// task, so the `logs()` call in `loadIntimacyCalendar` decrypts nothing while hidden.
    var intimacyStore: IntimacyLogStore
    var periodContext: PeriodContextBridge? = nil
    @Binding var activeSheet: FernletSheet?
    var isInHub: Bool = false
    @Binding var isTabBarCompact: Bool
    @Binding var tabResetToken: Int
    @Environment(FernletLockService.self) private var lockService
    @Environment(StoragePreferencesStore.self) private var storagePreferencesStore
    @State private var authorization = HealthKitAuthorizationViewModel()
    @State private var selectedDay: SelectedCycleDay?
    @State private var displayedMonth: Date = .now
    /// Merged per-day intimacy event counts (sealed logs max-merged with HealthKit). Plaintext-
    /// adjacent view state: scrubbed the moment the derived intimacy gate flips off.
    @State private var intimacyEventsByDay: [String: Int] = [:]
    /// Decrypted intimacy logs resident for the day detail. Scrubbed with `intimacyEventsByDay`.
    @State private var intimacyLogs: [IntimacyLog] = []
    /// Set when a day delete failed, so the detail stays open with an honest message instead of
    /// popping as though the entry were gone.
    @State private var deleteErrorMessage: String?

    /// Identity for the page's load task: any change restarts it. Folds the DERIVED
    /// `sensitiveSurfaceVisibility` in alongside the lock state, so flipping either half visible
    /// mid-mount reloads that half's data — no reliance on a page re-appearance, and every writer
    /// of the derived value is a trigger by construction (the house rule: key off the derived
    /// value, never the setter). Internal so the reload-on-flip identity is unit-testable.
    struct LoadTrigger: Equatable {
        var lockState: FernletLockState
        var visibility: SensitiveSurfaceVisibility
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                pageContent
                    .fernletTabBarBottomClearance()
            }
            .fernletTabBarCompaction($isTabBarCompact, resetToken: $tabResetToken)
            .background(Color.parchment)
            .toolbar(isInHub ? .hidden : .visible, for: .navigationBar)
            .navigationDestination(item: $selectedDay) { day in
                dayDetail(for: day)
            }
            // Keyed on the DERIVED visibility gates alongside the lock state so un-hiding a half
            // while the page stays mounted (it survives via the other half) restarts the load —
            // every writer of the derived value (Settings toggle, profile edit, a multi-device
            // settings sync) is covered by construction, never just the setter. Without this the
            // just-un-hidden period half would render affirmatively wrong empty states over
            // existing data until a re-appearance or lock cycle happened to restart the task.
            .task(id: LoadTrigger(lockState: lockService.state, visibility: store.sensitiveSurfaceVisibility)) {
                await loadPeriodIfUnlocked()
                await loadIntimacyCalendar()
            }
            .task(id: displayedMonth) { await loadIntimacyCalendar() }
            // Period entries reload on `.logPeriod` dismiss globally in ContentView (the sheet can
            // also be opened from Home); the month-scoped intimacy merge is this view's own.
            .onChange(of: activeSheet?.id) { _, newValue in
                if newValue == nil { Task { await loadIntimacyCalendar() } }
            }
            // Hiding must drop plaintext already on screen, not just refuse the next load — this
            // view holds decrypted logs in @State for as long as it stays in the hierarchy. Keyed
            // on the DERIVED value so every writer (Settings toggle, profile edit, age change,
            // HealthKit import) is covered by construction.
            .onChange(of: store.isIntimacyTrackingVisible) { _, visible in
                if !visible { scrubIntimacyState() }
            }
            .alert("Couldn't delete this day",
                   isPresented: Binding(get: { deleteErrorMessage != nil },
                                        set: { if !$0 { deleteErrorMessage = nil } })) {
                Button("OK", role: .cancel) { deleteErrorMessage = nil }
            } message: {
                Text(deleteErrorMessage ?? "")
            }
        }
    }

    /// The scrolling page: header, the period-only cards, the calendar, and the privacy banner
    /// (R4: `body` keeps only the NavigationStack and its modifiers).
    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            // The calendar is what a daily user comes for, so nothing optional sits above it: the
            // one-time primer moved below, and an empty predictions card (a whole FernletCard
            // holding one "log 3 cycles" line) is now a single slate line under the grid.
            if store.isPeriodTrackingVisible {
                if showsPrediction, let prediction = periodStore.prediction {
                    PredictionsCard(prediction: prediction)
                }
                phaseTrendsCard
            }
            CycleCalendarCard(
                displayedMonth: $displayedMonth,
                entriesByKey: entriesByKey,
                intimacyDayKeys: intimacyDayKeys,
                todayKey: FernletDate.dayKey(for: Date()),
                prediction: store.isPeriodTrackingVisible && showsPrediction ? periodStore.prediction : nil,
                showsFlowLegend: store.isPeriodTrackingVisible,
                showsIntimacyLegend: store.isIntimacyTrackingVisible,
                onDayTapped: { date in selectedDay = SelectedCycleDay(date: date) }
            )
            if store.isPeriodTrackingVisible {
                predictionHint
                periodAwarePrimer
            }
            privacyBanner
            if store.isPeriodTrackingVisible {
                recentEvents
                if showsPrediction, let prediction = periodStore.prediction {
                    TrendsCard(prediction: prediction)
                }
            }
        }
        .padding(20)
    }

    /// The "not enough cycles yet" line, under the calendar. A card's worth of chrome for one
    /// sentence used to push the grid — and today's cell — off the bottom of the screen.
    @ViewBuilder
    private var predictionHint: some View {
        if showsPrediction, periodStore.prediction == nil {
            Text("Log at least 3 cycles to see predictions.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
    }

    /// The pushed day detail for a tapped calendar day, with both halves gated the same way the
    /// calendar is.
    private func dayDetail(for day: SelectedCycleDay) -> some View {
        let dayEntry = entry(for: day.date)
        let dayKey = FernletDate.dayKey(for: day.date)
        return CycleDayDetailView(
            entry: dayEntry,
            showsPeriodHalf: store.isPeriodTrackingVisible,
            showsIntimacyHalf: store.isIntimacyTrackingVisible,
            intimacyLogs: store.isIntimacyTrackingVisible
                ? intimacyLogs.filter { $0.dayKey == dayKey }.sorted { $0.eventDate < $1.eventDate }
                : [],
            intimacyEventCount: store.isIntimacyTrackingVisible ? (intimacyEventsByDay[dayKey] ?? 0) : 0,
            // A day with nothing logged opens "Log period" for that date, not "Edit period" over a
            // placeholder entry — `entry(for:)` synthesizes an empty entry for every untouched day.
            onEdit: {
                let hasLog = dayEntry.hasObservedEvent || dayEntry.narrative != nil
                activeSheet = .logPeriod(targetDate: day.date, editingEntry: hasLog ? dayEntry : nil)
            },
            onDelete: { deleteDay(dayEntry, dayKey: dayKey) }
        )
    }

    /// Deletes a day's cycle entry, keeping the detail open (and saying so) when the delete fails.
    private func deleteDay(_ dayEntry: CycleDayEntry, dayKey: String) {
        Task {
            do {
                try await periodStore.deleteEntry(dayEntry)
            } catch {
                // The entry (HealthKit sample and/or sealed narrative) is still there: leave the
                // detail open rather than popping as if the day were gone.
                FernletAuditLog.log("cycle.deleteEntry.failed", context: ["dayKey": dayKey])
                deleteErrorMessage = "That day is still here — try again in a moment."
                return
            }
            // Keep the bridge's cached trends from outliving the deleted data (§5.3
            // "deliberate forgetfulness"): recompute from the now-smaller entry set.
            refreshContext()
            selectedDay = nil
        }
    }

    var showsPrediction: Bool {
        !store.settings.hidePredictions
    }

    private var header: some View {
        HStack(alignment: .top) {
            ScreenHeader(title: Text("Cycle"), subtitle: headerSubtitle, identifier: "screen.cycle")
            Spacer()
            logButton
        }
    }

    /// Phase-aware while period is visible; a neutral line otherwise (never mentions the hidden half).
    ///
    /// Typed `Text` rather than `String` because the three branches are not the same kind of
    /// string: two are authored copy that should translate, while the phase title is a domain
    /// display property that has already resolved its own. Only `Text` can carry both without
    /// feeding a runtime value into a catalog lookup that could never match it.
    private var headerSubtitle: Text {
        guard store.isPeriodTrackingVisible else { return Text("Your private calendar.") }
        return periodStore.currentPhase == .unknown
            ? Text("Your cycle, at a glance.")
            : Text(verbatim: periodStore.currentPhase.title)
    }

    /// ONE plus button for the whole page: a menu when both halves can log, a direct button when
    /// only one is visible. The hidden half's option simply doesn't exist — no explanation.
    @ViewBuilder
    private var logButton: some View {
        if store.isPeriodTrackingVisible && store.isIntimacyTrackingVisible {
            Menu {
                Button {
                    activeSheet = .logPeriod(targetDate: nil, editingEntry: nil)
                } label: {
                    Label("Log period", systemImage: "drop.fill")
                }
                Button {
                    activeSheet = .logIntimacy
                } label: {
                    Label("Log intimacy", systemImage: "heart.fill")
                }
            } label: {
                // Mirrors HeaderActionButton's chrome so the pill looks identical either way.
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.bark)
                    .frame(minWidth: 58, minHeight: 58)
                    .background(Color.cream.opacity(0.9), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Color.bark.opacity(0.08), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Log")
        } else if store.isPeriodTrackingVisible {
            HeaderActionButton(systemImage: "plus", accessibilityLabel: "Log period") {
                activeSheet = .logPeriod(targetDate: nil, editingEntry: nil)
            }
        } else if store.isIntimacyTrackingVisible {
            HeaderActionButton(systemImage: "plus", accessibilityLabel: "Log intimacy") { activeSheet = .logIntimacy }
        }
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
                                .foregroundStyle(Color.onMoss)
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

    /// Names only the visible halves — mentioning the hidden one here would leak its existence.
    private var privacyBanner: some View {
        let subject: String
        if store.isPeriodTrackingVisible && store.isIntimacyTrackingVisible {
            subject = "Your period and intimacy data stay"
        } else if store.isIntimacyTrackingVisible {
            subject = "Your intimacy data stays"
        } else {
            subject = "Your period data stays"
        }
        return Text("\(subject) on this device, behind your app lock.")
            .font(.fernlet(.bubble))
            .foregroundStyle(Color.slate)
            .fernletWrappingText()
    }

    /// Flow-tint inputs for the calendar card, keyed by day key. Empty while the period half is
    /// hidden — a view-seam BACK-STOP mirroring the intimacy half's gated inputs in the day-detail
    /// push. The authoritative enforcement stays `PeriodTrackerStore`'s fail-closed `isVisible`
    /// seam plus ContentView's value-keyed scrub, but a non-setter writer can flip the derived
    /// gate off with the store's entries still resident in the same update; this by-construction
    /// empty map keeps flow tints from rendering in that window. Internal so the gate is testable.
    var entriesByKey: [String: CycleDayEntry] {
        guard store.isPeriodTrackingVisible else { return [:] }
        // R5: `entries` is another module's `public var`, so a duplicate dateKey would TRAP here
        // with `uniqueKeysWithValues`. Keeping the first entry degrades to a stale cell, not a crash.
        return Dictionary(periodStore.entries.map { ($0.dateKey, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Days with at least one intimacy event, from the merged sealed + HealthKit counts. Empty
    /// while intimacy is hidden (the state is scrubbed), so the calendar layer simply vanishes.
    private var intimacyDayKeys: Set<String> {
        Set(intimacyEventsByDay.filter { $0.value > 0 }.keys)
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
                                Text(verbatim: entry.flowDisplayName)
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

    private func loadPeriodIfUnlocked() async {
        periodStore.attachLockService(lockService)
        // The store's own `isVisible` seam already refuses hidden loads (fail-closed), but the
        // HealthKit AUTHORIZATION prompt below is view-level and outside that seam — never ask
        // for cycle-tracking permission while the user has the period surface hidden.
        guard store.isPeriodTrackingVisible else { return }
        guard let contentKey = lockService.contentKey(for: .privateHub) else { return }
        if !authorization.hasRequested(.cycleTracking) {
            await authorization.request(.cycleTracking)
        }
        await periodStore.loadEntries(unlockedContentKey: contentKey)
        refreshContext()
    }

    /// Drops the intimacy plaintext held in view state. Safe to call when already empty.
    private func scrubIntimacyState() {
        intimacyLogs = []
        intimacyEventsByDay = [:]
    }

    private func loadIntimacyCalendar() async {
        // Back-stop to the authoritative gate. The sealed-note decrypt is gated at the seam by
        // `intimacyStore` (fail-closed), so this view-level check no longer guards the plaintext — but
        // it still does real extra work: it scrubs the logs already resident in @State (hiding
        // mid-session must drop them, not leave them readable until process death) and skips the
        // HealthKit read below, which the sealed store never covered.
        guard store.isIntimacyTrackingVisible else {
            scrubIntimacyState()
            return
        }
        let contentKey = lockService.contentKey(for: .privateHub)
        let localLogs: [IntimacyLog]
        do {
            localLogs = try intimacyStore.logs(contentKey: contentKey)
        } catch {
            // Fail closed (no plaintext fallback), but audited: without this line a failed decrypt
            // renders as "no intimacy events this month", which is affirmatively wrong.
            FernletAuditLog.log("intimacy.read.failed", context: [:])
            localLogs = []
        }
        intimacyLogs = localLogs
        let localEventsByDay = Dictionary(grouping: localLogs, by: \.dayKey).mapValues(\.count)
        do {
            let service = HealthKitService(preferencesStore: storagePreferencesStore)
            let healthEventsByDay = try await service.loadIntimacyEventsByDay(for: displayedMonth)
            intimacyEventsByDay = healthEventsByDay.merging(localEventsByDay) { max($0, $1) }
        } catch {
            intimacyEventsByDay = localEventsByDay
        }
    }

    private func refreshContext() {
        let unlocked = lockService.isUnlocked(for: .privateHub)
        periodContext?.refresh(unlocked: unlocked, wellbeingByDay: store.periodWellbeingByDay)
    }

    /// The day-detail entry for a tapped date. While the period half is hidden this returns the
    /// blank placeholder even if `periodStore.entries` still holds a real entry mid-flip — the
    /// same view-seam back-stop as `entriesByKey`, so a stale render can never carry period
    /// plaintext into the detail push. Internal so the gate is testable.
    func entry(for date: Date) -> CycleDayEntry {
        let key = FernletDate.dayKey(for: date)
        let placeholder = CycleDayEntry(date: date, dateKey: key, samples: [], narrative: nil, phase: .unknown)
        guard store.isPeriodTrackingVisible else { return placeholder }
        return periodStore.entries.first { $0.dateKey == key } ?? placeholder
    }
}

// MARK: - Prediction Cards

/// Card showing the likely next-period date range, a confidence chip, and the cycles-tracked count.
///
/// Rendered by ``CycleTrackerView`` only when the period half is visible, predictions aren't hidden
/// in settings, and `PeriodTrackerStore` actually produced a `CyclePrediction`. Before that the page
/// carries a single "log at least 3 cycles" line under the calendar instead — a card holding one
/// sentence pushed the grid below the fold.
private struct PredictionsCard: View {
    var prediction: CyclePrediction

    var body: some View {
        FernletCard {
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

/// Card summarizing average cycle length and typical day-to-day variation.
///
/// The statistical companion to ``PredictionsCard``, shown at the bottom of ``CycleTrackerView``
/// once a prediction exists (and the period half + predictions are visible).
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

/// The layered month-grid calendar card: flow-tinted day cells, projected-period shading, a
/// distinct intimacy marker per day, month paging, and a per-half legend.
///
/// Builds a ``CycleMonthModel`` per render and forwards day taps (past/today only — future cells
/// are disabled) back to ``CycleTrackerView`` via `onDayTapped`. Each legend half appears only
/// when its surface is visible, so a hidden half leaves no trace on the card. The card chrome and
/// paging (forward past the current month disabled) come from the shared ``MonthCalendarCard``.
private struct CycleCalendarCard: View {
    @Binding var displayedMonth: Date
    var entriesByKey: [String: CycleDayEntry]
    var intimacyDayKeys: Set<String>
    var todayKey: String
    var prediction: CyclePrediction?
    var showsFlowLegend: Bool
    var showsIntimacyLegend: Bool
    var onDayTapped: (Date) -> Void

    var body: some View {
        let model = CycleMonthModel(
            date: displayedMonth,
            entriesByKey: entriesByKey,
            intimacyDayKeys: intimacyDayKeys,
            todayKey: todayKey,
            prediction: prediction
        )
        MonthCalendarCard(displayedMonth: $displayedMonth, todayKey: todayKey) { gridDay in
            let cell = model.cell(for: gridDay)
            CycleCalendarCell(cell: cell) {
                if let date = cell.date, !cell.isFuture {
                    onDayTapped(date)
                }
            }
        } footer: {
            legend
        }
    }

    /// The flow/intimacy key under the grid. Wraps onto new rows rather than shrinking: the old
    /// `lineLimit(1)` + `minimumScaleFactor(0.7)` row shrank to "Med…"/"Intim…" at larger text sizes.
    private var legend: some View {
        FlowLayout(spacing: 12) {
            if showsFlowLegend {
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
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            if showsIntimacyLegend {
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.terracotta)
                    Text("Intimacy").font(.fernlet(.labelSmall)).foregroundStyle(Color.slate)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

// MARK: - Calendar Cell

/// A single tappable day cell in the layered cycle calendar grid.
///
/// Pure presentation over one ``CycleMonthCell``: the model supplies the fill, today ring, future
/// dimming, intimacy flag, and accessibility label; the cell just draws them — the intimacy
/// marker is a tiny terracotta heart pinned to the cell's bottom edge, deliberately NOT the
/// dusty-rose flow tint so the two layers can never be confused — and disables itself for blanks
/// and future days.
private struct CycleCalendarCell: View {
    var cell: CycleMonthCell
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
            .overlay(alignment: .bottom) {
                if cell.hasIntimacyEvent {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(Color.terracotta)
                        .padding(.bottom, 1.5)
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

/// One cell of the layered cycle month grid: a day number (or blank leading pad), its logged
/// period entry if any, a projected flow level for predicted future days, and whether the day has
/// an intimacy event.
///
/// Built by ``CycleMonthModel`` and rendered by `CycleCalendarCell`. `fill` maps observed flow
/// levels to graduated dusty-rose tints and predicted days to a flat projection tint, so the flow
/// encoding lives in one place; the intimacy layer is the separate `hasIntimacyEvent` flag drawn
/// as a distinct marker, never a fill.
struct CycleMonthCell: Identifiable {
    let id = UUID()
    var day: Int?
    var date: Date?
    var dateKey: String?
    var entry: CycleDayEntry?
    var projectedLevel: PredictedFlowLevel?
    /// Whether at least one intimacy event (sealed log or HealthKit sample) exists on this day.
    /// Always false while the intimacy surface is hidden — the model receives an empty key set.
    var hasIntimacyEvent: Bool
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

    /// `Text` rather than `String` (review T2-1) — see ``JournalMonthCell/accessibilityLabel`` for
    /// why appending clauses cannot localize, and why whole sentences are chosen instead.
    var accessibilityLabel: Text {
        guard let day else { return Text("Empty calendar cell") }
        let flow = (!isFuture && entry?.hasObservedEvent == true) ? entry?.flowDisplayName : nil
        switch (flow, hasIntimacyEvent) {
        case let (flow?, true):
            return isToday
                ? Text("Today, day \(day), \(flow), intimacy logged")
                : Text("Day \(day), \(flow), intimacy logged")
        case let (flow?, false):
            return isToday ? Text("Today, day \(day), \(flow)") : Text("Day \(day), \(flow)")
        case (nil, true):
            return isToday
                ? Text("Today, day \(day), intimacy logged")
                : Text("Day \(day), intimacy logged")
        case (nil, false):
            return isToday ? Text("Today, day \(day)") : Text("Day \(day)")
        }
    }
}

/// Pure month-layout model for the layered cycle calendar: title, weekday symbols, and the padded
/// cell grid with period entries, projected flow, and intimacy presence attached.
///
/// Layered over the shared ``MonthGridModel`` (which owns the calendar math and canonical day
/// keys) and computed fresh each render from the entries-by-dayKey map, the intimacy day-key set,
/// and an optional `CyclePrediction`; projected levels are only attached to days without a real
/// entry, inside the prediction's likely start range (defaulting to `.medium` when the prediction
/// has no per-day level). Extracted as a plain struct so the layout math is testable without
/// SwiftUI.
struct CycleMonthModel {
    let monthTitle: String
    let weekdaySymbols: [String]
    let cells: [CycleMonthCell]

    private let cellsByDay: [Int: CycleMonthCell]

    init(
        date: Date,
        entriesByKey: [String: CycleDayEntry],
        intimacyDayKeys: Set<String> = [],
        todayKey: String,
        prediction: CyclePrediction?,
        calendar: Calendar = .current
    ) {
        let grid = MonthGridModel(date: date, todayKey: todayKey, calendar: calendar)

        self.monthTitle = grid.monthTitle
        self.weekdaySymbols = grid.weekdaySymbols

        let projectedLevelsByDay = Self.projectedLevelsByDay(for: prediction, calendar: calendar)
        let blanks = (0..<grid.leadingBlanks).map { _ in
            CycleMonthCell(day: nil, date: nil, dateKey: nil, entry: nil, projectedLevel: nil, hasIntimacyEvent: false, isToday: false, isFuture: false)
        }
        let days = grid.days.map { gridDay -> CycleMonthCell in
            let entry = entriesByKey[gridDay.dateKey]
            return CycleMonthCell(
                day: gridDay.day,
                date: gridDay.date,
                dateKey: gridDay.dateKey,
                entry: entry,
                projectedLevel: entry == nil ? projectedLevelsByDay[gridDay.dateKey] : nil,
                hasIntimacyEvent: intimacyDayKeys.contains(gridDay.dateKey),
                isToday: gridDay.isToday,
                isFuture: gridDay.isFuture
            )
        }
        self.cells = blanks + days
        self.cellsByDay = Dictionary(uniqueKeysWithValues: zip(grid.days.map(\.day), days))
    }

    /// Returns the cell for one shared-grid slot: the blank pad cell for `nil`, else the computed
    /// cell for that day of the month.
    func cell(for gridDay: MonthGridDay?) -> CycleMonthCell {
        guard let gridDay, let cell = cellsByDay[gridDay.day] else {
            return CycleMonthCell(day: nil, date: nil, dateKey: nil, entry: nil, projectedLevel: nil, hasIntimacyEvent: false, isToday: false, isFuture: false)
        }
        return cell
    }

    private static func projectedLevelsByDay(for prediction: CyclePrediction?, calendar: Calendar) -> [String: PredictedFlowLevel] {
        guard let prediction else { return [:] }
        // R5: two predicted flow days could map to one day key (the uniqueness invariant lives in
        // CyclePredictionEngine, another module) — keep the first rather than trapping.
        let flowByDay = Dictionary(prediction.predictedFlow.map { day in
            (FernletDate.dayKey(for: day.date), day.level)
        }, uniquingKeysWith: { first, _ in first })
        var result: [String: PredictedFlowLevel] = [:]
        let range = DateInterval(start: prediction.likelyStartRange.lowerBound, end: prediction.likelyStartRange.upperBound)
        for key in FernletDate.dayKeys(in: range, calendar: calendar) {
            result[key] = flowByDay[key] ?? .medium
        }
        return result
    }
}

// MARK: - Supporting Types

/// Identifiable wrapper around a tapped calendar date, used as the navigation-destination item.
///
/// Exists so `navigationDestination(item:)` has a `Hashable`/`Identifiable` value to drive the
/// push into ``CycleDayDetailView``; identity is the date's time interval.
private struct SelectedCycleDay: Identifiable, Hashable {
    var date: Date
    var id: TimeInterval { date.timeIntervalSinceReferenceDate }
}
