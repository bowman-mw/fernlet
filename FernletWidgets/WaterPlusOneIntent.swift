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

struct WaterPlusOneIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a bottle of water"
    static let description = IntentDescription("Adds one bottle of water to today's Fernlet diary.")

    func perform() async throws -> some IntentResult {
        // Record the intent's OWN day key so a tap after midnight (app closed) lands on the
        // correct day when the app drains the queue later (day-rollover safety).
        let dayKey = WidgetDayKey.current()
        PendingWidgetActionWriter().append(
            PendingWidgetAction(
                id: UUID(),
                dateKey: dayKey,
                action: PendingWidgetAction.waterPlusOne,
                createdAt: Date()
            )
        )
        WidgetSnapshotStore().applyOptimisticWaterPlusOne(dayKey: dayKey)
        WidgetCenter.shared.reloadTimelines(ofKind: FernletWidgetKind.companion)
        return .result()
    }
}
