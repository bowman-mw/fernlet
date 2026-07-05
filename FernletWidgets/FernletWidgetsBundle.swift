// FernletWidgetsBundle.swift
// FernletWidgets
//
// v1 companion widget: systemSmall (interactive +1 water) + lock-screen accessories.
// DESIGN PLACEHOLDER: the companion renders as a per-state SF Symbol glyph — the full vector
// companion (CompanionVectorAssets) is app-only for now; swap in real artwork in a design pass.

import SwiftUI
import WidgetKit

enum FernletWidgetKind {
    static let companion = "FernletCompanion"
}

@main
struct FernletWidgetsBundle: WidgetBundle {
    var body: some Widget {
        FernletCompanionWidget()
    }
}

struct FernletCompanionEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?

    /// Water progress only counts when the mirrored snapshot is for the CURRENT day; after a day
    /// rollover with the app closed, the fresh day starts at zero bottles.
    var bottleCount: Int {
        guard let snapshot else { return 0 }
        return snapshot.dateKey == WidgetDayKey.current(date) ? snapshot.bottleCount : 0
    }

    var hydrationTarget: Int { max(snapshot?.hydrationTarget ?? 4, 1) }
}

struct FernletCompanionProvider: TimelineProvider {
    func placeholder(in context: Context) -> FernletCompanionEntry {
        FernletCompanionEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (FernletCompanionEntry) -> Void) {
        let snapshot = WidgetSnapshotStore().read() ?? (context.isPreview ? .placeholder : nil)
        completion(FernletCompanionEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FernletCompanionEntry>) -> Void) {
        let entry = FernletCompanionEntry(date: Date(), snapshot: WidgetSnapshotStore().read())
        // Single entry; refreshes are pushed by the app via WidgetCenter.reloadTimelines on every
        // snapshot mirror — the hourly policy just re-evaluates day rollover while the app is closed.
        let nextHour = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(nextHour)))
    }
}

struct FernletCompanionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: FernletWidgetKind.companion, provider: FernletCompanionProvider()) { entry in
            FernletCompanionWidgetView(entry: entry)
        }
        .configurationDisplayName("Fernlet")
        .description("Your companion's mood and today's water, at a glance.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

// MARK: - Views

struct FernletCompanionWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FernletCompanionEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                CircularCompanionView(entry: entry)
            case .accessoryRectangular:
                RectangularCompanionView(entry: entry)
            default:
                SmallCompanionView(entry: entry)
            }
        }
        // Companion state encodes wellbeing (incl. sickness) — redact on a locked Lock Screen.
        .privacySensitive()
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }
}

/// Per-state glyph + tint. DESIGN PLACEHOLDER: gentle SF Symbols standing in for companion artwork.
private struct CompanionGlyph {
    let symbol: String
    let tint: Color

    init(state: WidgetCompanionState?) {
        switch state {
        case .thriving: self.symbol = "sun.max.fill"; self.tint = .yellow
        case .okay: self.symbol = "leaf.fill"; self.tint = .green
        case .tired: self.symbol = "moon.zzz.fill"; self.tint = .indigo
        case .resting: self.symbol = "moon.fill"; self.tint = .purple
        case .sick: self.symbol = "bandage.fill"; self.tint = .orange
        case nil: self.symbol = "leaf"; self.tint = .green
        }
    }
}

private struct WaterDots: View {
    let filled: Int
    let target: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<min(target, 8), id: \.self) { index in
                Image(systemName: index < filled ? "drop.fill" : "drop")
                    .font(.system(size: 9))
                    .foregroundStyle(index < filled ? Color.blue : Color.secondary.opacity(0.55))
            }
        }
    }
}

private struct SmallCompanionView: View {
    let entry: FernletCompanionEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            VStack(spacing: 6) {
                let glyph = CompanionGlyph(state: snapshot.companionState)
                Image(systemName: glyph.symbol)
                    .font(.system(size: 34))
                    .foregroundStyle(glyph.tint)
                WaterDots(filled: entry.bottleCount, target: entry.hydrationTarget)
                Button(intent: WaterPlusOneIntent()) {
                    Label("Water", systemImage: "plus")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .tint(.blue)
            }
        } else {
            PlaceholderView()
        }
    }
}

private struct CircularCompanionView: View {
    let entry: FernletCompanionEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            Gauge(value: Double(min(entry.bottleCount, entry.hydrationTarget)), in: 0...Double(entry.hydrationTarget)) {
                Image(systemName: CompanionGlyph(state: snapshot.companionState).symbol)
            } currentValueLabel: {
                Text("\(entry.bottleCount)")
            }
            .gaugeStyle(.accessoryCircular)
        } else {
            Image(systemName: "leaf")
                .font(.title2)
        }
    }
}

private struct RectangularCompanionView: View {
    let entry: FernletCompanionEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            HStack(spacing: 8) {
                Image(systemName: CompanionGlyph(state: snapshot.companionState).symbol)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Water \(entry.bottleCount) of \(entry.hydrationTarget)")
                        .font(.caption.weight(.semibold))
                    let macros = snapshot.macroSummary
                    Text("P \(Int(macros.protein)) · C \(Int(macros.carbs)) · F \(Int(macros.fat))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            PlaceholderView()
        }
    }
}

private struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "leaf")
                .font(.title3)
                .foregroundStyle(.green)
            Text("Open Fernlet to say hi")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
