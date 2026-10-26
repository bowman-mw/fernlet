import FernletUI
import SwiftUI

/// The header of a tool page pushed inside the First aid sheet (World Review Batch 3: `b3-breathe-*`,
/// `b3-grounding`, `b3-worry-*`): "‹ First aid" top left where a sheet's Cancel sits, the tool's
/// title inside the sheet in Fraunces, and Done top right only where the page offers one. It stands
/// in for the navigation bar, which the page hides; the sheet's wooden grabber stays above it.
///
/// Built on ``SheetHeader`` (its leading accessory slot carries the Back), so it is the same chrome
/// every sheet draws, not a second one. Without a title (grounding) only the control row shows.
struct FirstAidToolHeader: View {
    /// The tool's title, or nil for a page whose own content names it.
    let title: Text?
    /// Done (top right): leaves the tool, as the page's own Done always did; nil hides it.
    var onDone: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let title {
            SheetHeader(title: title, onDone: onDone) { backLink }
        } else {
            HStack {
                backLink
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
        }
    }

    /// "‹ First aid": the pixel chevron and the menu's name in the dim ink, popping back to it.
    private var backLink: some View {
        Button { dismiss() } label: {
            HStack(spacing: 7) {
                FernletIcon(.back, scale: 2)
                    .accessibilityHidden(true)
                Text("First aid")
                    .font(FernletFramedFont.sheetControl)
                    .foregroundStyle(WorldPalette.dim)
            }
        }
        .buttonStyle(.plain)
        .fernletTapTarget()
        .accessibilityLabel(Text("Back to First aid"))
        .accessibilityInputLabels([Text("Back"), Text("First aid")])
        .accessibilityIdentifier("firstAid.back")
    }
}

/// One tool on the First aid menu (`b3-first-aid`): a framed row with the tool's pixel icon on a
/// tile (bare inside the row, the frame rule), its name in bold, the one-line caption in dim ink, and
/// the pixel chevron.
struct FirstAidToolCardLabel: View {
    let sprite: WorldSprite
    let title: LocalizedStringKey
    let caption: LocalizedStringKey

    var body: some View {
        HStack(spacing: 14) {
            FernletIconTile(size: 48) {
                WorldSpriteView(sprite: sprite, scale: 3)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(FernletFramedFont.rowTitleBold)
                    .foregroundStyle(WorldPalette.bark)
                Text(caption)
                    .font(FernletFramedFont.rowValue)
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
            }
            Spacer(minLength: 0)
            FernletIcon(.chevron, scale: 2)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The frame rule (ref-frames-rule): pieces inside this card draw flat.
        .environment(\.fernletInFramedSection, true)
        .fernletFramed(WorldTheme.framedLook, fill: WorldPalette.paper, cornerRadius: FernletFramedLook.cardRadius)
        .contentShape(Rectangle())
    }
}
