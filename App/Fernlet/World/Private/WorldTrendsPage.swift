import FernletDomainModel
import FernletScoring
import LocalPersistence
import FernletUI
import SwiftUI

/// Trends as a page pushed inside the World Today panel (World Review Batch 2, `b2-trends`): the plate
/// reads "‹ Today  Trends  ✕", the page opens with today's privacy line, then one framed card per
/// derived signal (``WorldSignalCard``). Read-only over the signals the store already computed, as the
/// sheet always was; outside the World frame ``TrendsModal`` keeps its sheet.
struct WorldTrendsPage: View {
    var signals: [DerivedSignalRecord]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Local signals from your logs — worked out on this device.")
                    .font(FernletFramedFont.field)
                    .foregroundStyle(WorldPalette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                if signals.isEmpty {
                    FernletCard { EmptyState(text: "More logs will make trends useful.") }
                } else {
                    ForEach(signals) { signal in
                        SignalDetailRow(signal: signal)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .fernletPageBackground()
        .fernletPushedPage(LocalizedStringResource("Trends"))
    }
}

/// The two pages the World Today panel pushes under its plate (Batch 2): Trends (`b2-trends`) and Body
/// signals (`b2-stress`). Applied inside the panel's navigation stack; everywhere else the two stay
/// root-presented sheets. Pushed, Body signals opens First aid straight from the root router, because
/// there is no sheet in the way to dismiss first.
struct WorldTodayPushedPages: ViewModifier {
    @Binding var isShowingTrends: Bool
    @Binding var isShowingBodySignals: Bool
    let signals: [DerivedSignalRecord]
    let assessment: StressAssessment?
    @Binding var activeSheet: FernletSheet?

    func body(content: Content) -> some View {
        content
            .navigationDestination(isPresented: $isShowingTrends) {
                TrendsModal(signals: signals, isPushed: true)
            }
            .navigationDestination(isPresented: $isShowingBodySignals) {
                StressExplainerSheet(assessment: assessment, onFirstAid: { activeSheet = .firstAid(nil) }, isPushed: true)
            }
    }
}

/// One derived signal in the World look (`b2-trends`): a framed card with the signal's pixel icon on a
/// framed tile, its Fraunces title and value, today's explanation, the five-step meter as framed
/// segments, the inputs as framed tags, and any nutrient gaps. Every value and line of the standard
/// ``SignalDetailRow`` is here.
struct WorldSignalCard: View {
    let signal: DerivedSignalRecord
    let look: FernletFramedLook
    @Environment(\.fernletTermOfAddress) private var termOfAddress

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    FernletIconTile(size: 52) {
                        WorldSpriteView(sprite: Self.sprite(for: signal.signalName), scale: 3)
                    }
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SignalPresentation.title(for: signal.signalName))
                            .font(FernletFramedFont.sheetTitle)
                            .foregroundStyle(look.text)
                        Text(SignalPresentation.valueLabel(for: signal.value, addressing: termOfAddress))
                            .font(FernletFramedFont.field.weight(.semibold))
                            .foregroundStyle(look.dim)
                    }
                }
                Text(SignalPresentation.explanation(for: signal))
                    .font(FernletFramedFont.body)
                    .foregroundStyle(look.dim)
                    .fernletWrappingText()
                WorldSignalMeter(strength: SignalPresentation.strength(for: signal.value), look: look)
                FlowLayout(spacing: 8) {
                    ForEach(signal.sourceFields, id: \.self) { field in
                        FernletTag(text: Text(SignalPresentation.sourceLabel(for: field)), fill: WorldPalette.gameCream)
                    }
                }
                gaps
            }
        }
    }

    /// Up to four nutrient gaps, each named with its status.
    @ViewBuilder private var gaps: some View {
        if signal.nutrientGaps.isEmpty == false {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(signal.nutrientGaps.prefix(4)) { gap in
                    HStack {
                        Text(gap.displayedName)
                        Spacer()
                        Text(SignalPresentation.nutrientStatusLabel(gap.status))
                    }
                    .font(FernletFramedFont.rowDetail)
                    .foregroundStyle(look.text)
                }
            }
        }
    }

    /// The signal's pixel icon: the face for mood, the star for energy, the onigiri for eating, the
    /// chart for progression and readiness, the leaf for anything newer.
    static func sprite(for signalName: String) -> WorldSprite {
        switch signalName {
        case "moodTrend": WorldSprites.face
        case "energyTrend": WorldSprites.star
        case "eatingPattern": WorldSprites.onigiri
        case "progressionTrend", "intensityReadiness": WorldSprites.chart
        default: WorldSprites.leaf
        }
    }
}

/// The five-step strength meter in the World look (`b2-trends`): five rounded segments, the filled
/// ones in ink and the rest in the paper's low tone. Decorative beside the value it repeats.
struct WorldSignalMeter: View {
    let strength: Int
    let look: FernletFramedLook

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(index < strength ? look.ink : look.paperLow)
                    .frame(height: 9)
            }
        }
        .accessibilityHidden(true)
    }
}
