// MapWidget.swift
// FernletWidgets
//
// The large map widget (`b4-new-map`, approved 2026-10-24; built in round 6b on the owner's Q36: "Places +
// trails, not history"): Home in miniature. Sprout stands on a picture of the map around you, with your
// marked places (homes, the hotel of a stay, the places you keep to eat and train) and your saved trails,
// under Home's status plate (six hearts and a friend's gold hearts, the protein, carbs and fat bars, water)
// and "Map from 9:40". The picture is the app's (WidgetMapPicture.swift); everything else is drawn live
// from the snapshot, as the companion widget draws it.

import SwiftUI
import WidgetKit

/// One moment of the map widget: the companion widget's entry for that moment (the day gate, the
/// feeling, the hearts, water) and the picture as read when the timeline was built.
struct FernletMapEntry: TimelineEntry {
    /// The companion widget's entry for the same moment.
    let companion: FernletCompanionEntry
    /// The map's picture, none, or locked away with the phone.
    let picture: WidgetMapPictureRead

    var date: Date { companion.date }

    /// Today's protein, carbs and fat against their targets; empty bars on a stale day.
    var macros: WidgetMacros {
        guard let snapshot = companion.snapshot, WidgetDayGate.snapshotReflectsDay(snapshot.dateKey, at: date) else {
            return .empty
        }
        return WidgetMacros.make(summary: snapshot.macroSummary, targets: snapshot.macroTargets)
    }
}

/// Today's macros as Home's status plate draws them: the twin of the app's `WorldStatus.Macro`.
struct WidgetMacros: Equatable {
    /// One macro's grams today against the day's target.
    struct Macro: Equatable {
        let grams: Int
        let target: Int

        /// How full the bar is, 0...1 (an unset target reads as empty, never full).
        var fraction: Double {
            guard target > 0, grams > 0 else { return 0 }
            return min(1, Double(grams) / Double(target))
        }
    }

    let protein: Macro
    let carbs: Macro
    let fat: Macro

    /// Nothing eaten and no targets: three empty bars.
    static let empty = WidgetMacros(protein: Macro(grams: 0, target: 0), carbs: Macro(grams: 0, target: 0),
                                    fat: Macro(grams: 0, target: 0))

    /// The bars for `summary` against `targets` (none: empty bars).
    static func make(summary: WidgetSnapshot.MacroSummary, targets: WidgetSnapshot.MacroSummary?) -> WidgetMacros {
        func macro(_ grams: Double, _ target: Double?) -> Macro {
            Macro(grams: whole(grams), target: whole(target ?? 0))
        }
        return WidgetMacros(protein: macro(summary.protein, targets?.protein), carbs: macro(summary.carbs, targets?.carbs),
                            fat: macro(summary.fat, targets?.fat))
    }

    /// A finite, non-negative whole number of grams.
    private static func whole(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        return Int(min(value, 100_000).rounded())
    }
}

/// The map widget's timeline: the companion widget's moments (``FernletCompanionProvider/entryDates(for:now:calendar:)``),
/// each over the same snapshot and the same picture.
///
/// **Reloaded by the app, never on a schedule** (`.never`): the picture is locked away with the phone, so
/// a reload while locked would draw no map, and every moment the day needs is already in the timeline. The
/// app reloads it whenever it writes a picture or a snapshot, while the phone is unlocked. If a reload
/// finds the picture locked anyway (a water tap from the Lock Screen), it draws the plain ground and asks
/// again in fifteen minutes.
struct FernletMapProvider: TimelineProvider {
    func placeholder(in context: Context) -> FernletMapEntry {
        FernletMapEntry(companion: FernletCompanionEntry(date: Date(), snapshot: .placeholder), picture: .none)
    }

    func getSnapshot(in context: Context, completion: @escaping (FernletMapEntry) -> Void) {
        let snapshot = WidgetSnapshotStore().read() ?? (context.isPreview ? .placeholder : nil)
        let picture = context.isPreview ? WidgetMapPictureRead.none : WidgetMapPictureStore().read()
        completion(FernletMapEntry(companion: FernletCompanionEntry(date: Date(), snapshot: snapshot), picture: picture))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FernletMapEntry>) -> Void) {
        let snapshot = WidgetSnapshotStore().read()
        let picture = WidgetMapPictureStore().read()
        let now = Date()
        let entries = FernletCompanionProvider.entryDates(for: snapshot, now: now).map {
            FernletMapEntry(companion: FernletCompanionEntry(date: $0, snapshot: snapshot), picture: picture)
        }
        let policy: TimelineReloadPolicy = picture == .locked ? .after(now.addingTimeInterval(15 * 60)) : .never
        completion(Timeline(entries: entries, policy: policy))
    }
}

/// The large map widget (`b4-new-map`). A `StaticConfiguration` keyed by ``FernletWidgetKind/map``; the
/// Home Screen only (iOS offers no large widget on the Lock Screen or in StandBy). Content margins are off
/// so the map runs to the widget's edge under the paper's ink frame.
struct FernletMapWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: FernletWidgetKind.map, provider: FernletMapProvider()) { entry in
            FernletMapWidgetView(entry: entry)
        }
        .configurationDisplayName(Text("Your map", comment: "The large map widget's name in the widget gallery"))
        .description(Text("A picture of the map around you, with your marked places and saved trails.",
                          comment: "The large map widget's description in the widget gallery (the privacy policy's own words)"))
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}
