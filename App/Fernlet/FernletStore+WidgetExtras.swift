import Foundation
import FernletDomainModel
import FernletSocial

/// What the World widgets add to the widget snapshot (World Review Batch 4, approved 2026-10-24): a
/// friend's gold hearts after the six (`b4-gold-widgets`) and the stamp book (`b4-new-stamp`).
///
/// Both are benign and unsealed: a gold heart is a time, never a friend's name or where you met; a
/// stamp is a frozen stat token and a day, never the number behind it. Both are empty while a decoy is
/// open, so the Home Screen of a duress session shows and keeps nothing real of either. The snapshot
/// file they ride in is deleted by "Delete everything" (`WidgetSnapshotMirror.clear()`), which is the
/// whole wipe story for both — no new file, no new key.
extension FernletStore {

    /// The most stamps the widget snapshot carries (R3): the twenty stats, with headroom for kinds
    /// a newer build adds. The stamp book itself is capped at `SillyStampStore.maxRows`.
    static let widgetStampLimit = 64

    /// When each gold heart showing at `date` fades, earliest first: at most two, each
    /// `GoldHeartRules.lifetime` after it was given (an arrival in the future counts as just
    /// arrived, as `GoldHeartRules.glowEnds` reads it). Empty in a decoy.
    func widgetGoldHeartEnds(at date: Date = Date()) -> [Date] {
        guard !duressSessionActive else { return [] }
        return Self.goldHeartEnds(arrivals: heartLedger.goldHeartArrivals(at: date), at: date).map(Self.wholeSecond)
    }

    /// `date` cut to its whole second, as the snapshot file's ISO 8601 dates keep it: a fraction would
    /// make every published snapshot differ from the one read back, and the background refresh would
    /// reload the widgets each time (`WidgetSnapshot.contentEquals`; found by lane 5c's full run on a
    /// simulator that had earned stamps).
    static func wholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// The pure half of ``widgetGoldHeartEnds(at:)``, for tests.
    static func goldHeartEnds(arrivals: [Date], at date: Date) -> [Date] {
        GoldHeartRules.activeArrivals(arrivals, at: date)
            .map { min($0, date).addingTimeInterval(GoldHeartRules.lifetime) }
            .sorted()
    }

    /// The stamp book as the stamp widget reads it, oldest first. Empty in a decoy.
    func widgetStamps() -> [WidgetSnapshot.StampMoment] {
        guard !duressSessionActive else { return [] }
        return Self.stampMoments(sillyStats.stamps).map {
            WidgetSnapshot.StampMoment(kindRaw: $0.kindRaw, dayKey: $0.dayKey, earnedAt: Self.wholeSecond($0.earnedAt))
        }
    }

    /// The pure half of ``widgetStamps()``: each stamp's frozen token, day and moment, oldest first,
    /// capped at ``widgetStampLimit``.
    static func stampMoments(_ entries: [SillyStampEntry]) -> [WidgetSnapshot.StampMoment] {
        let ordered = entries.sorted { ($0.dayKey, $0.createdAt, $0.id) < ($1.dayKey, $1.createdAt, $1.id) }
        return ordered.prefix(widgetStampLimit).map {
            WidgetSnapshot.StampMoment(kindRaw: $0.kind.rawValue, dayKey: $0.dayKey, earnedAt: $0.createdAt)
        }
    }
}
