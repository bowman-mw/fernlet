import Foundation
import FernletDomainModel

extension FernletStore {
    /// The companion's own line when nothing has just been said to it: Home's speech and the World
    /// map's speech bubble read this one function, so the two can never say different things.
    ///
    /// In order: a silly-stats stamp earned just now (until a journal entry comes after it, and never
    /// on a rest, sick or needs-gentleness day); the latest journal mood, as one whole sentence per
    /// mood (`HomeCopy`); the paced silly-stat line; the empty-day line on a day with nothing logged
    /// (BEFORE the companion thought, whose deterministic fallback is never nil and claimed notes
    /// existed on a fresh install); the companion thought; the signal line; the ordinary-day line.
    ///
    /// - Parameter termOfAddress: How the person is addressed, which the mood sentence agrees with.
    func companionAmbientThought(addressing termOfAddress: TermOfAddress) -> String {
        if let line = sillyStats.stampLine(todayKey: todayKey, latestJournal: day.journals.last?.date),
           !SillyStatsService.isQuietDay(signals: derivedSignals) {
            return line
        }
        if let last = day.journals.last {
            return HomeCopy.journalMoodThought(last.tag, addressing: termOfAddress)
        }
        if let line = sillyStats.companionLine {
            return line
        }
        if hasNoUserLogsToday {
            return HomeCopy.emptyDayThought
        }
        if let thought = companionThought {
            return thought
        }
        if let thought = HomeView.signalThought(for: derivedSignals) {
            return thought
        }
        return HomeCopy.ordinaryDayThought
    }

    /// Whether today holds nothing the person logged: no meal, workout, journal entry, sleep, water or
    /// care task. Home's intent prompt and the empty-day line read it.
    var hasNoUserLogsToday: Bool {
        day.meals.isEmpty &&
        day.workouts.isEmpty &&
        day.journals.isEmpty &&
        day.sleep == nil &&
        day.bottleCount == 0 &&
        day.hygiene.isEmpty
    }
}
