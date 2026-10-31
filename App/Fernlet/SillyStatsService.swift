//
//  SillyStatsService.swift
//  Fernlet
//
//  The silly stats' live state: the latest tally, which stats it reveals, the line the companion
//  says today (when a mention is due), and the stamp book with its banners waiting to show. Owned by
//  `FernletStore`, refreshed at launch and whenever the stats page opens, and re-tallied after each
//  save so a stat that just appeared earns its stamp at once.
//

import Foundation
import Observation
import FernletDomainModel
import FernletFoundation
import LocalPersistence

/// Holds the silly stats for the Home card, the stats page and the companion's thought bubble, and
/// the stamps they earn.
///
/// The tally is in memory only. It mixes diary totals with Apple Health figures (lifetime steps,
/// sleep stages), and a Health value must never reach synced state, so it is never saved — it is
/// rebuilt from the diary and Health on every ``refresh(store:now:)``. The stamp book is the one
/// thing kept, on this device only (``SillyStampStore`` says why).
@MainActor
@Observable
final class SillyStatsService {
    private(set) var tally = SillyStatsTally()
    /// The stats with enough behind them to show, in page order.
    private(set) var revealed: [SillyStatKind] = []
    /// What the companion says about a silly stat today, or nil when no mention is due.
    private(set) var companionLine: String?
    /// The stamp book, oldest first.
    private(set) var stamps: [SillyStampEntry] = []
    /// Stamps earned just now whose banner has not been shown yet; the first is the one showing.
    private(set) var pendingStampBanners: [SillyStatKind] = []
    /// The latest stamp earned just now, with the day and moment it was earned — the companion says
    /// its line that day. In memory only, like the banner.
    private(set) var latestAnnouncedStamp: (kind: SillyStatKind, dayKey: String, at: Date)?
    @ObservationIgnored private let pacer: SillyStatsCompanionPacer
    @ObservationIgnored private let stampStore: SillyStampStore
    /// The last lifetime step total Apple Health gave ``refresh(store:now:)``, reused by the
    /// after-save re-tally so a save never waits on a Health query. In memory only.
    @ObservationIgnored private var lastHealthSteps: Int?
    /// False until the first ``refresh(store:now:)`` has read Apple Health. Until then a re-tally
    /// would see the diary without Health's steps and could begin the stamp book short of them.
    @ObservationIgnored private var hasRefreshed = false
    /// Furthest from home as last worked out, with what it was worked out from (``furthestFromHome(store:)``).
    /// In memory only, like the tally.
    @ObservationIgnored var furthestKnown: (basis: SillyFurthestFromHome.Basis, meters: Double)?
    /// The pending after-save re-tally, replaced by each newer request (``scheduleRetally(store:)``).
    @ObservationIgnored private var retallyTask: Task<Void, Never>?

    /// How long a re-tally waits for more saves before it runs, so a burst of edits tallies once.
    static let retallyDelay: Duration = .milliseconds(400)

    init(pacer: SillyStatsCompanionPacer? = nil, stampStore: SillyStampStore? = nil) {
        self.pacer = pacer ?? SillyStatsCompanionPacer()
        self.stampStore = stampStore ?? SillyStampStore()
        self.stamps = self.stampStore.entries()
    }

    /// A pending re-tally ends with the service (the memory wall's ML1); it captures the service
    /// weakly, so this only stops a sleeping task outliving it.
    isolated deinit {
        retallyTask?.cancel()
    }

    /// Rebuilds the tally from the store's days, its settings, Apple Health's lifetime steps and
    /// this device's pat count, and stamps any stat that has just appeared.
    func refresh(store: FernletStore, now: Date = .now) async {
        let days = Array(store.loadDays().values)
        let todayKey = FernletDate.dayKey(for: now)
        let firstKey = days.filter(\.hasLoggedContent).map(\.date).min() ?? todayKey
        let start = FernletDate.date(fromDayKey: firstKey) ?? now
        let steps = await store.lifetimeHealthSteps(since: start, now: now)
        let furthest = await furthestFromHome(store: store)
        lastHealthSteps = steps
        hasRefreshed = true
        let held = stamps.count
        update(with: Self.inputs(store: store, days: days, todayKey: todayKey, healthSteps: steps, furthest: furthest), now: now)
        Self.publishNewStamps(to: store, held: held, now: stamps.count)
    }

    /// Republishes the widget snapshot when this check recorded a stamp, so the stamp widget shows it
    /// now rather than at the next save (the save that earned it published before the debounced
    /// re-tally ran). No mirror, no publish — `publishWidgetSnapshot()` is silent until it is wired.
    private static func publishNewStamps(to store: FernletStore, held: Int, now: Int) {
        guard now != held else { return }
        store.publishWidgetSnapshot()
    }

    /// Re-tallies from the diary and the pat count after a save or a pat, reusing Health's last
    /// step total — so the cookie just logged earns its stamp now, not at the next launch.
    ///
    /// Debounced by ``retallyDelay``; does nothing before the first ``refresh(store:now:)`` or once
    /// every stat has its stamp (the page's own refresh keeps the numbers current from there).
    func scheduleRetally(store: FernletStore) {
        guard hasRefreshed, stamps.count < SillyStatKind.allCases.count else { return }
        retallyTask?.cancel()
        retallyTask = Task { [weak self, weak store] in
            do {
                try await Task.sleep(for: Self.retallyDelay)
            } catch {
                // Superseded by a newer save, or the app is going away: the newer task tallies.
                return
            }
            guard let self, let store else { return }
            let furthest = await self.furthestFromHome(store: store)
            guard !Task.isCancelled else { return }
            let now = Date.now
            let inputs = Self.inputs(
                store: store, days: Array(store.loadDays().values), todayKey: FernletDate.dayKey(for: now),
                healthSteps: self.lastHealthSteps, furthest: furthest)
            let held = self.stamps.count
            self.update(with: inputs, now: now)
            Self.publishNewStamps(to: store, held: held, now: self.stamps.count)
        }
    }

    /// Takes `kind`'s banner off the queue once it has been shown, so the next one can show.
    func bannerShown(_ kind: SillyStatKind) {
        guard let index = pendingStampBanners.firstIndex(of: kind) else { return }
        pendingStampBanners.remove(at: index)
    }

    /// What the companion says about the stamp earned just now: on the day it was earned, until
    /// something newer happens — nil once a journal entry is written after it (the companion answers
    /// the latest thing), on any other day, or when no stamp has been earned since launch.
    ///
    /// - Parameter latestJournal: when today's last journal entry was written, if there is one.
    func stampLine(todayKey: String, latestJournal: Date?) -> String? {
        guard let latest = latestAnnouncedStamp, latest.dayKey == todayKey else { return nil }
        if let latestJournal, latestJournal >= latest.at { return nil }
        return SillyStampCopy.companionLine(for: latest.kind)
    }

    /// Picks today's companion mention, if one is due, and keeps its line for the Home bubble.
    func prepareCompanionLine(todayKey: String, isQuietDay: Bool) {
        let candidates = revealed.map { (kind: $0, value: SillyStatsEngine.value($0, in: tally)) }
        guard let kind = pacer.mention(from: candidates, todayKey: todayKey, isQuietDay: isQuietDay) else {
            companionLine = nil
            return
        }
        companionLine = SillyStatsCopy.text(for: kind, tally: tally).companionLine
    }

    /// Forgets the tally, today's line and the stamp book's in-memory half ("Delete everything";
    /// the store's wipe clears the book's persisted half with ``SillyStampStore/clearPersistentState(in:)``).
    func clear() {
        retallyTask?.cancel()
        furthestKnown = nil
        tally = SillyStatsTally()
        revealed = []
        companionLine = nil
        stamps = []
        pendingStampBanners = []
        latestAnnouncedStamp = nil
    }

    /// A day the companion keeps silly stats to itself: a rest or sick day, or a stretch the mood
    /// trend says needs gentleness. The signal values are the frozen derived-signal vocabulary.
    static func isQuietDay(signals: [DerivedSignalRecord]) -> Bool {
        signals.contains { signal in
            (signal.signalName == "intensityReadiness" && signal.value == "needs rest")
                || (signal.signalName == "moodTrend" && signal.value == "needs gentleness")
        }
    }

    private static func inputs(store: FernletStore, days: [FernletDay], todayKey: String, healthSteps: Int?,
                               furthest: Double?) -> SillyStatsTallier.Inputs {
        SillyStatsTallier.Inputs(
            days: days,
            todayKey: todayKey,
            bottleOunces: store.settings.bottleOz,
            healthSteps: healthSteps,
            pats: PetInteractionGovernor.lifetimePats(),
            unitlessLoadIsPounds: Locale.current.measurementSystem == .us,
            furthestFromHomeMeters: furthest)
    }

    /// Tallies `inputs`, reveals what it shows, and stamps any stat that has just appeared — the one
    /// step both ``refresh(store:now:)`` and the after-save re-tally end in, and the seam the stamp
    /// tests drive without a store.
    func update(with inputs: SillyStatsTallier.Inputs, now: Date) {
        tally = SillyStatsTallier.tally(inputs)
        revealed = SillyStatsEngine.revealed(in: tally)
        awardStamps(inputs, now: now)
    }

    /// Records the stamps the revealed stats have earned, and queues the banners for the ones
    /// earned just now (``SillyStampRules``). The book begins with its first check.
    private func awardStamps(_ inputs: SillyStatsTallier.Inputs, now: Date) {
        let award = SillyStampRules.award(
            revealed: revealed,
            held: Set(stamps.map(\.kind)),
            bookStartDay: stampStore.startDay,
            firstRevealDays: { SillyStatsTallier.firstRevealDays(inputs) },
            todayKey: inputs.todayKey,
            now: now)
        stampStore.begin(on: inputs.todayKey)
        guard !award.entries.isEmpty else { return }
        let added = Set(stampStore.record(award.entries).map(\.kind))
        stamps = stampStore.entries()
        let news = award.announced.filter { added.contains($0) && !pendingStampBanners.contains($0) }
        // Bounded by the twenty kinds: a kind is queued at most once, and only on the check that
        // first recorded its stamp.
        pendingStampBanners.append(contentsOf: news)
        if let last = news.last {
            latestAnnouncedStamp = (last, inputs.todayKey, now)
        }
    }
}

extension FernletStore {
    /// Rebuilds the silly stats and picks today's companion mention — at launch, and when a
    /// resident app rolls over to a new day.
    func refreshSillyStats(now: Date = .now) async {
        await sillyStats.refresh(store: self, now: now)
        // A journal entry today already gives the Home bubble its line (`ambientThought` reads it
        // first), so the mention waits for another day rather than being used up unseen.
        let quiet = SillyStatsService.isQuietDay(signals: derivedSignals) || !day.journals.isEmpty
        sillyStats.prepareCompanionLine(todayKey: FernletDate.dayKey(for: now), isQuietDay: quiet)
    }
}
