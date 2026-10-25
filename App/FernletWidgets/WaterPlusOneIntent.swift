// WaterPlusOneIntent.swift
// FernletWidgets
//
// Interactive "+1 water" App Intent for the companion widget (iOS 17+ Button(intent:)).
// Widget-target-local by design: it only appends a pending-action row to the app-group queue
// (the app drains it via FernletStore.processPendingWidgetActions and applies the canonical
// DiaryStore water mutation against the row's OWN dateKey), then bumps the mirrored snapshot
// optimistically so the widget reflects the tap instantly.

import AppIntents
import WidgetKit

/// The water widget's "+" button, its Lock Screen circle and its Control Center control: logs one
/// bottle of water without opening the app.
///
/// Runs in the WIDGET process (a plain `AppIntent`, unlike the Live Activity intents), so it never
/// touches the diary directly. Instead it appends a ``PendingWidgetAction`` row — stamped with the
/// tap's OWN day key for day-rollover safety — to the app-group queue that
/// `FernletStore.processPendingWidgetActions` drains idempotently, bumps the mirrored snapshot
/// optimistically via ``WidgetSnapshotStore/applyOptimisticWaterPlusOne(dayKey:)`` so the ring
/// updates instantly, and reloads the companion timeline. The app remains the source of truth and
/// republishes the real snapshot on its next save/foreground.
struct WaterPlusOneIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a bottle of water"
    static let description = IntentDescription("Adds one bottle of water to today's Fernlet diary.")

    func perform() async throws -> some IntentResult {
        // Record the intent's OWN day key so a tap after midnight (app closed) lands on the
        // correct day when the app drains the queue later (day-rollover safety).
        let dayKey = WidgetDayKey.current()
        let queued = PendingWidgetActionWriter().append(
            PendingWidgetAction(
                id: UUID(),
                dateKey: dayKey,
                action: PendingWidgetAction.waterPlusOne,
                createdAt: Date()
            )
        )
        // Only show the bottle the app will actually see. A failed queue write (logged by the writer)
        // means nothing recorded the tap, so bumping the ring here would promise a bottle the app
        // overwrites away on its next publish; leaving the widget truthful lets the user tap again.
        guard queued else { return .result() }
        WidgetSnapshotStore().applyOptimisticWaterPlusOne(dayKey: dayKey)
        // Every surface that shows the count: both widgets and the Control Center control.
        WidgetCenter.shared.reloadTimelines(ofKind: FernletWidgetKind.companion)
        WidgetCenter.shared.reloadTimelines(ofKind: FernletWidgetKind.water)
        // The map widget's drops too — but not from the Lock Screen while its picture is locked away with
        // the phone: it keeps its last drawing rather than redrawing without its map.
        if WidgetMapPictureStore().mayReload {
            WidgetCenter.shared.reloadTimelines(ofKind: FernletWidgetKind.map)
        }
        ControlCenter.shared.reloadControls(ofKind: FernletWidgetKind.waterControl)
        return .result()
    }
}
