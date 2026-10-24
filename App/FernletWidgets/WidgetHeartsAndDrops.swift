// WidgetHeartsAndDrops.swift
// FernletWidgets
//
// Home's status plate in the widgets (World Review Batch 4, cross-batch link: "the widgets use the six
// pixel hearts from Home, each heart two of today's 12 care segments, and Home's pixel drops for
// water"). The math is the app's `WorldStatus`, copied: the 12 steps drawn as six hearts with halves,
// or four with thirds at the largest text sizes; one drop per bottle up to eight, else "n / target".

import SwiftUI
import WidgetKit

/// The care score as hearts — the twin of the app's `WorldStatus.heartFill(at:of:)` and
/// `WorldHeartRow.fill`.
enum WidgetHearts {
    /// The most gold hearts shown at once (`GoldHeartRules.maxActive`).
    static let maxGold = 2

    /// The score in `HealthBar`'s 12 steps (two per heart of six).
    static func steps(_ score: Double) -> Int {
        guard score.isFinite else { return 0 }
        return Int((min(max(score, 0), 1) * 12).rounded())
    }

    /// Full, half or empty for heart `index` of `hearts` (six with halves, or four with thirds, where a
    /// third or two counts as half). Any count that doesn't divide 12 draws empty hearts.
    static func fill(steps: Int, at index: Int, of hearts: Int) -> WidgetHeartFill {
        guard hearts > 0, 12 % hearts == 0, (0..<hearts).contains(index) else { return .empty }
        let perHeart = 12 / hearts
        let amount = Double(min(perHeart, max(0, steps - perHeart * index))) / Double(perHeart)
        if amount >= 1 { return .full }
        return amount > 0 ? .half : .empty
    }

    /// The gold hearts showing at `date`: each published end still ahead, at most ``maxGold``.
    static func gold(ends: [Date], at date: Date) -> Int {
        min(ends.filter { $0 > date }.count, maxGold)
    }

    /// What VoiceOver calls the hearts.
    static var label: String {
        String(localized: "widget.hearts.label", defaultValue: "Care",
               comment: "VoiceOver name for the row of pixel hearts on a Fernlet widget: the day's care score")
    }

    /// "58 percent", then the gold hearts: "58 percent, one gold heart from a friend".
    static func value(score: Double, goldHearts: Int) -> String {
        let percent = Int((min(max(score.isFinite ? score : 0, 0), 1) * 100).rounded())
        let base = String(localized: "widget.hearts.percent", defaultValue: "\(percent) percent",
                          comment: "VoiceOver value of the widget's hearts: the care score as a percentage. Example: '58 percent'")
        guard let gold = goldPhrase(goldHearts) else { return base }
        return String(localized: "widget.hearts.percentAndGold", defaultValue: "\(base), \(gold)",
                      comment: "VoiceOver value of the widget's hearts with a friend's gold hearts: the percentage, then the gold hearts. Example: '58 percent, one gold heart from a friend'")
    }

    /// The gold hearts in words, or nil with none. Two whole sentences rather than a plural rule:
    /// there are never more than two.
    static func goldPhrase(_ count: Int) -> String? {
        switch count {
        case ..<1: nil
        case 1: String(localized: "widget.hearts.oneGold", defaultValue: "one gold heart from a friend",
                       comment: "VoiceOver, after the care percentage: one gold heart a friend gave in person, shown after the six hearts")
        default: String(localized: "widget.hearts.twoGold", defaultValue: "two gold hearts from friends",
                        comment: "VoiceOver, after the care percentage: two gold hearts friends gave in person, shown after the six hearts")
        }
    }
}

/// Home's hearts in a widget: six pixel hearts (four, larger, at the largest text sizes), then a
/// friend's gold hearts. With gold hearts the hearts shrink a little so all eight fit on one line
/// (`b4-gold-widgets`). One VoiceOver element: "Care, 58 percent, one gold heart from a friend".
struct WidgetHeartRow: View {
    /// The published live care score, 0...1.
    let score: Double
    /// Gold hearts showing, 0...2.
    let goldHearts: Int
    /// One-colour rendering: outlines, fills, and a checked gold heart.
    let mono: Bool
    /// Points per sprite pixel at the standard text sizes without gold hearts.
    var scale: CGFloat = 7.0 / 3.0
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.redactionReasons) private var redaction

    var body: some View {
        let count = typeSize.isAccessibilitySize ? 4 : 6
        let gold = min(max(goldHearts, 0), WidgetHearts.maxGold)
        let steps = WidgetHearts.steps(score)
        // A Canvas is not redacted by iOS on its own: under the privacy reason (a locked Lock Screen,
        // StandBy) the hearts give way to one placeholder bar, as text does.
        let hidden = redaction.contains(.privacy)
        HStack(spacing: 1) {
            ForEach(0..<count, id: \.self) { index in
                heart(WidgetHearts.fill(steps: steps, at: index, of: count), count: count, gold: gold)
            }
            ForEach(0..<gold, id: \.self) { _ in
                heart(.gold, count: count, gold: gold)
            }
        }
        .opacity(hidden ? 0 : 1)
        .overlay { if hidden { Capsule().fill(.tertiary) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(WidgetHearts.label))
        .accessibilityValue(Text(WidgetHearts.value(score: score, goldHearts: gold)))
    }

    private func heart(_ fill: WidgetHeartFill, count: Int, gold: Int) -> some View {
        let size: CGFloat = count == 4 ? scale + 2.0 / 3.0 : (gold > 0 ? scale - 1.0 / 3.0 : scale)
        return WidgetSpriteView(sprite: WidgetSprites.heart, scale: size, paint: mono ? .monoHeart(fill) : .heart(fill))
            .widgetAccentable(fill == .gold)
    }
}

/// How the water row reads: the twin of the app's `WorldStatus.Water`.
enum WidgetWater: Equatable {
    /// One drop per bottle of the target, `filled` of them full.
    case drops(filled: Int, total: Int)
    /// "n / target": a target above ``maxDrops``, or the largest text sizes.
    case count(bottles: Int, target: Int)

    /// The most drops drawn before the row switches to "n / target".
    static let maxDrops = 8

    /// The row for `bottles` against `target`.
    static func make(bottles: Int, target: Int, accessibilitySize: Bool) -> WidgetWater {
        let bottles = max(bottles, 0), target = max(target, 0)
        guard !accessibilitySize, target > 0, target <= maxDrops else { return .count(bottles: bottles, target: target) }
        return .drops(filled: min(bottles, target), total: target)
    }

    /// "2 / 4", drawn beside one drop.
    static func fraction(_ bottles: Int, of target: Int) -> String {
        String(localized: "widget.water.fraction", defaultValue: "\(bottles) / \(target)",
               comment: "Today's bottles of water over the day's target, beside one water drop on a widget. Example: '2 / 4'")
    }
}

/// Home's pixel drops in a widget: one per bottle of the target (wrapping), or one drop and "2 / 4".
/// Hidden from VoiceOver: the element around it says "Water, 2 of 4 bottles".
struct WidgetDropRow: View {
    let water: WidgetWater
    let mono: Bool
    /// The text colour of "2 / 4".
    let ink: Color
    /// Points per sprite pixel.
    var scale: CGFloat = 3
    /// Drops per line before the row wraps.
    var perLine = 5

    var body: some View {
        Group {
            switch water {
            case .drops(let filled, let total):
                drops(filled: filled, total: total)
            case .count(let bottles, let target):
                HStack(spacing: 4) {
                    drop(full: bottles > 0)
                    Text(verbatim: WidgetWater.fraction(bottles, of: target))
                        .font(WidgetFont.label(15))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func drops(filled: Int, total: Int) -> some View {
        let lines = (total + perLine - 1) / max(perLine, 1)
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(0..<lines, id: \.self) { line in
                HStack(spacing: 3) {
                    ForEach((line * perLine)..<min(total, (line + 1) * perLine), id: \.self) { index in
                        drop(full: index < filled)
                    }
                }
            }
        }
    }

    private func drop(full: Bool) -> some View {
        WidgetSpriteView(sprite: WidgetSprites.drop, scale: scale, paint: mono ? .monoDrop(full: full) : .drop(full: full))
            .widgetAccentable(full)
    }
}
