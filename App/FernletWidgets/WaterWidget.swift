// WaterWidget.swift
// FernletWidgets
//
// Water on its own (design round 2, 2026-10-21): the small water card (2d), the Lock Screen "+1"
// circle (2i), and the Control Center / Action button control (2j). All three log through the one
// `WaterPlusOneIntent`, so the app drains a single queue whichever surface was tapped.

import AppIntents
import SwiftUI
import WidgetKit

/// The water widget: the small card and the Lock Screen "+1" circle.
///
/// Reuses ``FernletCompanionProvider`` and ``FernletCompanionEntry``: the same snapshot, the same
/// midnight entry, the same day gate on the bottle count.
struct FernletWaterWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: FernletWidgetKind.water, provider: FernletCompanionProvider()) { entry in
            WaterWidgetView(entry: entry)
        }
        .configurationDisplayName("Water")
        .description("Today's water, with a button to add a bottle.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

/// Picks the water widget's family layout and its background.
struct WaterWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    let entry: FernletCompanionEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                WaterLockView()
            default:
                if entry.snapshot == nil { PlaceholderView() } else { WaterSmallView(entry: entry) }
            }
        }
        .containerBackground(for: .widget) {
            if family == .accessoryCircular { Color.clear } else { WidgetTheme.current(scheme).card }
        }
    }
}

/// The small water card: a bottle that fills toward the person's own target, the count, and the
/// "+" button.
///
/// Only the button logs — the rest of the tile opens Water in the app, where a mis-tap can be
/// undone (a whole-tile button could never open the app, and a widget has no undo).
struct WaterSmallView: View {
    let entry: FernletCompanionEntry
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = WidgetTheme.current(scheme)
        ZStack(alignment: .bottomTrailing) {
            HStack(alignment: .top, spacing: 12) {
                WaterBottle(fraction: fraction, water: FernletWidgetPalette.waterFill, line: theme.line)
                    .frame(width: 40)
                    .accessibilityHidden(true)     // the count beside it is the reading
                VStack(alignment: .leading, spacing: 2) {
                    Text("Water")
                        .font(WidgetFont.label(12))
                        .foregroundStyle(theme.muted)
                    Text(entry.bottleCount, format: .number)
                        .font(WidgetFont.display(30))
                        .foregroundStyle(theme.ink)
                        .contentTransition(.numericText())
                    Text(WaterWords.ofTarget(entry.hydrationTarget))
                        .font(WidgetFont.body(12))
                        .foregroundStyle(theme.ink)
                        // One line, so the "+" below never sits on it.
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Water"))
                .accessibilityValue(Text(WaterWords.progress(entry.bottleCount, of: entry.hydrationTarget)))
                Spacer(minLength: 0)
            }
            Button(intent: WaterPlusOneIntent()) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.accentInk)
                    .frame(width: 48, height: 48)
                    .background(theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            // The intent's own title says what the tap does, in every language the catalog carries.
            .accessibilityLabel(Text(WaterPlusOneIntent.title))
        }
        .widgetURL(FernletWidgetLink.water)
    }

    /// How full the bottle is: the day's bottles against the target, capped at full.
    private var fraction: Double {
        let target = max(entry.hydrationTarget, 1)
        return min(Double(entry.bottleCount) / Double(target), 1)
    }
}

/// The water bottle the small card draws: a cap, an outlined body, and water that rises with a
/// spring when a new entry arrives.
struct WaterBottle: View {
    /// 0–1: how far the water has risen.
    let fraction: Double
    /// The water's colour.
    let water: Color
    /// The outline's colour.
    let line: Color

    var body: some View {
        VStack(spacing: 0) {
            UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4, style: .continuous)
                .strokeBorder(line, lineWidth: 2)
                .frame(width: 18, height: 10)
            GeometryReader { geo in
                let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                ZStack(alignment: .bottom) {
                    Rectangle()
                        .fill(water)
                        .frame(height: geo.size.height * fraction)
                        .widgetAccentable()
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
                .clipShape(shape)
                .overlay(shape.strokeBorder(line, lineWidth: 2))
            }
        }
        .animation(.spring(duration: 0.7, bounce: 0.35), value: fraction)
    }
}

/// The Lock Screen "+1 water" circle: one tap logs a bottle, without unlocking.
///
/// Says nothing about the day — no count — so it stays within the Lock Screen's face-only rule.
struct WaterLockView: View {
    var body: some View {
        Button(intent: WaterPlusOneIntent()) {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "drop.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                            .offset(x: 6, y: 4)
                    }
                    .widgetAccentable()
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(WaterPlusOneIntent.title))
    }
}

/// The Control Center and Action button control: "+1 water", with today's count beside it.
struct FernletWaterControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: FernletWidgetKind.waterControl, provider: WaterControlValueProvider()) { count in
            ControlWidgetButton(action: WaterPlusOneIntent()) {
                Label {
                    Text("Water")
                    Text(WaterWords.progress(count.bottles, of: count.target))
                } icon: {
                    Image(systemName: "drop.fill")
                }
            }
        }
        .displayName("Log a bottle of water")
        .description("Adds one bottle of water to today's Fernlet diary.")
    }
}

/// The water surfaces' count words, as plural-ruled catalog keys: the count decides the wording
/// ("of 1 bottle", "of 4 bottles"), so the plural belongs in the catalog, never in a Swift branch.
enum WaterWords {
    /// "of 4 bottles" — under the big number on the small card.
    static func ofTarget(_ target: Int) -> String {
        String(localized: "widget.water.ofTarget", defaultValue: "of \(target) bottles",
               comment: "Under today's bottle count on the water widget: the day's target. Plural on the target ('of 1 bottle')")
    }

    /// "2 of 4 bottles" — the spoken value, and the control's line.
    static func progress(_ bottles: Int, of target: Int) -> String {
        String(localized: "widget.water.progress", defaultValue: "\(bottles) of \(target) bottles",
               comment: "Today's water against the day's target, spoken by VoiceOver and shown on the Control Center control. The noun follows the TARGET ('1 of 1 bottle', '2 of 4 bottles')")
    }
}

/// Today's water as the control shows it.
struct WaterControlCount: Sendable, Equatable {
    /// Bottles logged today (day-gated: zero after midnight until the app publishes).
    let bottles: Int
    /// The day's target in bottles.
    let target: Int
}

/// Reads today's water for the control from the same mirrored snapshot the widgets read.
struct WaterControlValueProvider: ControlValueProvider {
    var previewValue: WaterControlCount { WaterControlCount(bottles: 2, target: 4) }

    func currentValue() async throws -> WaterControlCount {
        let entry = FernletCompanionEntry(date: Date(), snapshot: WidgetSnapshotStore().read())
        return WaterControlCount(bottles: entry.bottleCount, target: entry.hydrationTarget)
    }
}
