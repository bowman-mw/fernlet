import FernletDomainModel
import LocalPersistence
import FernletUI
import SwiftUI

/// One derived signal on Settings › Signals in the one design language (`b2-settings-signals`,
/// approved 2026-10-23): a framed card with the signal's pixel icon in a framed tile, its name in
/// Fraunces and its value under it, the explanation, the five-segment strength strip, the framed
/// source tags, then any nutrient-gap lines.
///
/// Every word and number comes from ``SignalPresentation``, the same lookup Trends'
/// ``SignalDetailRow`` reads, so the two surfaces never disagree; only the drawing differs. Without
/// the framed look the page keeps ``SignalDetailRow``.
struct SettingsSignalCard: View {
    let signal: DerivedSignalRecord
    let look: FernletFramedLook
    /// The user's term of address, which the readiness values agree with.
    @Environment(\.fernletTermOfAddress) private var termOfAddress

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                FernletIconTile(size: 42) { WorldSpriteView(sprite: Self.sprite(for: signal.signalName), scale: 2) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(SignalPresentation.title(for: signal.signalName))
                        .font(FernletFramedFont.cardTitle)
                        .foregroundStyle(look.text)
                    Text(SignalPresentation.valueLabel(for: signal.value, addressing: termOfAddress))
                        .font(FernletFramedFont.rowValueBold)
                        .foregroundStyle(look.dim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(SignalPresentation.explanation(for: signal))
                .font(FernletFramedFont.body)
                .foregroundStyle(look.dim)
                .fernletWrappingText()
            strengthStrip
            FlowLayout(spacing: 6) {
                // The engine's raw keys ("journals.tag") never reach the card; these name what the
                // person actually logged.
                ForEach(signal.sourceFields, id: \.self) { field in
                    FernletTag(text: Text(SignalPresentation.sourceLabel(for: field)), fill: look.raised)
                }
            }
            nutrientGaps
        }
        .settingsCard()
    }

    /// The five-segment strip (`.segs`): filled segments in ink, the rest recessed paper.
    private var strengthStrip: some View {
        let filled = SignalPresentation.strength(for: signal.value)
        return HStack(spacing: 6) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(index < filled ? look.ink : look.paperLow)
                    .frame(height: 8)
            }
        }
        .accessibilityHidden(true)
    }

    /// Up to four nutrient lines (name, then gap or fine), as Trends shows them.
    @ViewBuilder
    private var nutrientGaps: some View {
        if !signal.nutrientGaps.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(signal.nutrientGaps.prefix(4).enumerated()), id: \.element.id) { index, gap in
                    FernletKeyValueRow(key: Text(gap.displayedName),
                                       value: Text(SignalPresentation.nutrientStatusLabel(gap.status)),
                                       showsRule: index > 0)
                }
            }
        }
    }

    /// The pixel icon for a signal (the sprite for the SF Symbol ``SignalPresentation`` names).
    static func sprite(for signalName: String) -> WorldSprite {
        switch signalName {
        case "moodTrend": WorldSprites.face
        case "energyTrend": WorldSprites.star
        case "eatingPattern": WorldSprites.onigiri
        case "progressionTrend": WorldSprites.chart
        case "intensityReadiness": WorldSprites.target
        default: WorldSprites.leaf
        }
    }
}
