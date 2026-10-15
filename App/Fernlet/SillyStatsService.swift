//
//  SillyStatsService.swift
//  Fernlet
//
//  The silly stats' live state: the latest tally, which stats it reveals, and the line the
//  companion says today (when a mention is due). Owned by `FernletStore`, refreshed at launch and
//  whenever the stats page opens.
//

import Foundation
import Observation
import FernletDomainModel
import FernletFoundation
import LocalPersistence

/// Holds the silly stats for the Home card, the stats page and the companion's thought bubble.
///
/// In memory only. The tally mixes diary totals with Apple Health figures (lifetime steps, sleep
/// stages), and a Health value must never reach synced state, so nothing here is saved — it is
/// rebuilt from the diary and Health on every ``refresh(store:now:)``.
@MainActor
@Observable
final class SillyStatsService {
    private(set) var tally = SillyStatsTally()
    /// The stats with enough behind them to show, in page order.
    private(set) var revealed: [SillyStatKind] = []
    /// What the companion says about a silly stat today, or nil when no mention is due.
    private(set) var companionLine: String?
    @ObservationIgnored private let pacer: SillyStatsCompanionPacer

    init(pacer: SillyStatsCompanionPacer? = nil) {
        self.pacer = pacer ?? SillyStatsCompanionPacer()
    }

    /// Rebuilds the tally from the store's days, its settings, Apple Health's lifetime steps and
    /// this device's pat count.
    func refresh(store: FernletStore, now: Date = .now) async {
        let days = Array(store.loadDays().values)
        let todayKey = FernletDate.dayKey(for: now)
        let firstKey = days.filter(\.hasLoggedContent).map(\.date).min() ?? todayKey
        let start = FernletDate.date(fromDayKey: firstKey) ?? now
        let steps = await store.lifetimeHealthSteps(since: start, now: now)
        let inputs = SillyStatsTallier.Inputs(
            days: days,
            todayKey: todayKey,
            bottleOunces: store.settings.bottleOz,
            healthSteps: steps,
            pats: PetInteractionGovernor.lifetimePats(),
            unitlessLoadIsPounds: Locale.current.measurementSystem == .us)
        apply(SillyStatsTallier.tally(inputs))
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

    /// Forgets the tally and today's line ("Delete everything").
    func clear() {
        apply(SillyStatsTally())
        companionLine = nil
    }

    /// A day the companion keeps silly stats to itself: a rest or sick day, or a stretch the mood
    /// trend says needs gentleness. The signal values are the frozen derived-signal vocabulary.
    static func isQuietDay(signals: [DerivedSignalRecord]) -> Bool {
        signals.contains { signal in
            (signal.signalName == "intensityReadiness" && signal.value == "needs rest")
                || (signal.signalName == "moodTrend" && signal.value == "needs gentleness")
        }
    }

    private func apply(_ newTally: SillyStatsTally) {
        tally = newTally
        revealed = SillyStatsEngine.revealed(in: newTally)
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
