import Foundation
import FernletDomainModel
import FernletScoring
import FernletSocial

/// Gold hearts and the live care score (World build, branch `world-ui`; World app plan step 2a).
///
/// A heart a friend gives in person shows as a gold heart for 12 hours, at most two at a time, and
/// each lifts the care score by one half heart while it lasts (`GoldHeartRules`). That boost lives
/// ONLY here, in ``liveCareScore`` and ``liveCompanionState``:
/// - `score` and `companionState` are unchanged, so everything that reads them (the nearby-friend
///   broadcast, exports, the trainer summary, scoring tests) never sees a boost;
/// - the saved day score is computed on its own path (`DiaryStore.storeDaySummary`, past days only)
///   and never reads either, so a friend's visit can't rewrite anyone's history.
///
/// The live pair feeds what shows the companion on this phone: the World Home, the widget snapshot
/// and the launch screen.
extension FernletStore {

    /// How many gold hearts are showing at `date`, 0...2.
    func goldHeartCount(at date: Date = Date()) -> Int {
        heartLedger.goldHeartArrivals(at: date).count
    }

    /// When the last gold heart showing at `date` fades, or nil when none is.
    func goldHeartsEnd(at date: Date = Date()) -> Date? {
        GoldHeartRules.glowEnds(heartLedger.goldHeartArrivals(at: date), at: date)
    }

    /// Today's care score with the gold-heart boost, 0...1. Display only; never saved.
    var liveCareScore: Double {
        GoldHeartRules.boosted(score: score, goldHearts: goldHeartCount())
    }

    /// The companion's state from ``liveCareScore``: two gold hearts can lift it a state. A sick day
    /// still reads as sick.
    var liveCompanionState: CompanionState {
        FernletScoring.state(for: liveCareScore, isSick: isSick(on: todayKey))
    }
}
