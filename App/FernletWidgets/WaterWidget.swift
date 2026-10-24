// WaterWidget.swift
// FernletWidgets
//
// Water on its own, in the World design language (World Review Batch 4, approved 2026-10-24): the
// small water card with Home's pixel drops and a framed moss "+" (`b4-w-water-small`), the Lock Screen
// "+1" circle as a pixel drop and plus (`b4-w-lock`), and the Control Center / Action button control
// with a pixel-drop symbol (`b4-w-control`). All three log through the one `WaterPlusOneIntent`, so
// the app drains a single queue whichever surface was tapped.

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
        .contentMarginsDisabled()
    }
}

/// Picks the water widget's family layout and its background.
struct WaterWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: FernletCompanionEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                WaterLockView()
            default:
                if entry.snapshot == nil {
                    PlaceholderView(mono: renderingMode.drawsInOneColour)
                } else {
                    WaterSmallView(entry: entry, mono: renderingMode.drawsInOneColour)
                }
            }
        }
        .containerBackground(for: .widget) {
            if family == .accessoryCircular { Color.clear } else { WidgetTheme.current(scheme).paper }
        }
    }
}

/// The small water card: the bottle and "Water", today's count and "of 4 bottles", Home's drops (one
/// per bottle of the target, every one full once the goal is passed; one drop and "9 / 12" past eight
/// or at the largest text sizes) and the framed moss "+".
///
/// Only the button logs — the rest of the tile opens Water in the app, where a mis-tap can be undone (a
/// whole-tile button could never open the app, and a widget has no undo).
struct WaterSmallView: View {
    let entry: FernletCompanionEntry
    let mono: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let theme = mono ? WidgetTheme.mono : WidgetTheme.current(scheme, contrast: contrast)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    WidgetSpriteView(sprite: WidgetSprites.bottle, scale: 2, paint: mono ? .solid(0xFFFFFF) : .plain)
                    Text("Water")
                        .font(WidgetFont.label(12.5))
                        .foregroundStyle(theme.muted)
                }
                Text(entry.bottleCount, format: .number)
                    .font(WidgetFont.display(34))
                    .foregroundStyle(theme.text)
                    .contentTransition(.numericText())
                Text(WaterWords.ofTarget(entry.hydrationTarget))
                    .font(WidgetFont.label(12.5))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Water"))
            .accessibilityValue(Text(WaterWords.progress(entry.bottleCount, of: entry.hydrationTarget)))
            Spacer(minLength: 4)
            HStack(alignment: .bottom, spacing: 6) {
                WidgetDropRow(water: WidgetWater.make(bottles: entry.bottleCount, target: entry.hydrationTarget,
                                                      accessibilitySize: typeSize.isAccessibilitySize),
                              mono: mono, ink: theme.text)
                Spacer(minLength: 0)
                WaterPlusButton(mono: mono)
            }
        }
        .widgetPaperFrame(theme, padding: EdgeInsets(top: 14, leading: 15, bottom: 14, trailing: 14))
        .widgetURL(FernletWidgetLink.water)
    }
}

/// The framed moss "+" (`.hsbtn`): a pixel plus on moss in a 3-point ink frame with a shade below; in
/// one colour, an outline. Runs ``WaterPlusOneIntent``; the app does not open.
struct WaterPlusButton: View {
    let mono: Bool

    var body: some View {
        Button(intent: WaterPlusOneIntent()) {
            WidgetSpriteView(sprite: WidgetSprites.plus, scale: 3, paint: .solid(0xFFFFFF))
                .frame(width: 48, height: 48)
                .background(mono ? Color.white.opacity(0.22) : WidgetFixedInk.moss, in: RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottom) {
                    if !mono {
                        Rectangle().fill(Color.black.opacity(0.18)).frame(height: 4)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(mono ? Color.white.opacity(0.5) : WidgetFixedInk.bubbleFrame, lineWidth: 3))
                .background {
                    if !mono {
                        RoundedRectangle(cornerRadius: 12).fill(WidgetFixedInk.shade).offset(y: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        // The intent's own title says what the tap does, in every language the catalog carries.
        .accessibilityLabel(Text(WaterPlusOneIntent.title))
    }
}

/// The Lock Screen "+1 water" circle: a pixel drop with a pixel plus. One tap logs a bottle, without
/// unlocking.
///
/// Says nothing about the day — no count — so it stays within the Lock Screen's face-only rule.
struct WaterLockView: View {
    var body: some View {
        Button(intent: WaterPlusOneIntent()) {
            ZStack {
                AccessoryWidgetBackground()
                WidgetSpriteView(sprite: WidgetSprites.drop, scale: 4, paint: .solid(0xFFFFFF))
                    .overlay(alignment: .bottomTrailing) {
                        WidgetSpriteView(sprite: WidgetSprites.plus, scale: 2, paint: .solid(0xFFFFFF))
                            .offset(x: 12, y: 4)
                    }
                    .offset(x: -3)
                    .widgetAccentable()
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(WaterPlusOneIntent.title))
    }
}

/// The Control Center and Action button control: "+1 water", with today's count beside it. Its icon is
/// the pixel drop, shipped as a custom symbol (`Assets.xcassets/fernlet.drop.pixel`) — iOS draws the
/// tile and tints the symbol.
struct FernletWaterControl: ControlWidget {
    /// The pixel drop's custom-symbol name in the extension's asset catalog.
    static let symbolName = "fernlet.drop.pixel"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: FernletWidgetKind.waterControl, provider: WaterControlValueProvider()) { count in
            ControlWidgetButton(action: WaterPlusOneIntent()) {
                Label {
                    Text("Water")
                    Text(WaterWords.progress(count.bottles, of: count.target))
                } icon: {
                    Image(Self.symbolName)
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
