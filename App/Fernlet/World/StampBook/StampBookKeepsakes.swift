import SwiftUI
import FernletDomainModel
import FernletUI

/// The Stamp book's first card, Care keepsakes (design `b2-milestones`, draft 2): a framed medal for each
/// kind of care kept, three to a wooden shelf, each with its lifetime count and a gold ★ tag for the gifts
/// it has added; then one dashed slot for the next kind to arrive, and the coins line.
///
/// Only kinds with something to show get a medal (no locked rows to goad a “collect them all”); the one
/// dashed slot is the next kind in the usual order, worded as a quiet “Next”, never a to-do. Receives its
/// rows and totals from ``StampBookPage`` so every figure comes from the same ledger read.
struct StampBookKeepsakesCard: View {
    let rows: [MilestoneRowModel]
    let totalGifts: Int
    let totalCoins: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let slots = StampBookShelfSlot.slots(rows: rows)
        let perShelf = dynamicTypeSize.isAccessibilitySize ? 2 : 3
        FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                header
                if !rows.contains(where: { $0.count > 0 }) {
                    Text("Nothing pressed onto the shelf just yet. Every bit of care will find a place here, in its own time.")
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(WorldPalette.dim)
                        .fernletWrappingText()
                }
                ForEach(StampBookShelfSlot.shelves(slots, perShelf: perShelf), id: \.self) { shelf in
                    StampBookShelf(slots: shelf, perShelf: perShelf, rows: rows)
                }
                StampBookCoinsLine(totalCoins: totalCoins)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stampBook.keepsakes")
    }

    /// "Care keepsakes" and, once a gift has landed, "★ 4 gifts".
    private var header: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            Text("Care keepsakes")
                .font(.fernlet(.headerMedium))
                .foregroundStyle(WorldPalette.bark)
                .accessibilityAddTraits(.isHeader)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            if totalGifts > 0 {
                HStack(spacing: 4) {
                    Text(verbatim: "★").accessibilityHidden(true)
                    Text(verbatim: MilestonesCopy.giftCount(totalGifts))
                }
                .font(.fernlet(.label).weight(.bold))
                .foregroundStyle(Color.goldenrodInk)
            }
        }
    }
}

/// One place on a keepsake shelf: an earned medal, or the dashed slot for the next kind.
enum StampBookShelfSlot: Hashable {
    case medal(MilestoneEventKind)
    case next(MilestoneEventKind)

    /// Every earned kind in the usual order, then the first kind with nothing yet (when there is one).
    static func slots(rows: [MilestoneRowModel]) -> [StampBookShelfSlot] {
        let earned = rows.filter { $0.count > 0 }.map { StampBookShelfSlot.medal($0.kind) }
        guard let next = rows.first(where: { $0.count == 0 }) else { return earned }
        return earned + [.next(next.kind)]
    }

    /// The slots in shelves of `perShelf` (three, or two at accessibility text sizes).
    static func shelves(_ slots: [StampBookShelfSlot], perShelf: Int) -> [[StampBookShelfSlot]] {
        let width = max(1, perShelf)
        return stride(from: 0, to: slots.count, by: width).map { start in
            Array(slots[start ..< min(start + width, slots.count)])
        }
    }

    /// The kind this slot shows.
    var kind: MilestoneEventKind {
        switch self {
        case .medal(let kind), .next(let kind): kind
        }
    }
}

/// One wooden shelf: its medals side by side, the ledge under them.
private struct StampBookShelf: View {
    let slots: [StampBookShelfSlot]
    let perShelf: Int
    /// The rows behind the medals, looked up by kind.
    let rows: [MilestoneRowModel]

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(slots, id: \.self) { slot in
                    slotView(slot)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                ForEach(slots.count ..< max(slots.count, perShelf), id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                }
            }
            .padding(.top, 8)
            StampBookLedge()
        }
    }

    @ViewBuilder
    private func slotView(_ slot: StampBookShelfSlot) -> some View {
        if let row = rows.first(where: { $0.kind == slot.kind }) {
            switch slot {
            case .medal: StampBookMedal(row: row)
            case .next: StampBookNextSlot(row: row)
            }
        }
    }
}

/// The wooden ledge under a row of medals: wood in a 2-pt ink frame with a lighter top edge.
private struct StampBookLedge: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(WorldPalette.wood)
            .overlay(alignment: .top) { WorldPalette.woodHigh.frame(height: 2).padding(.horizontal, 2).padding(.top, 2) }
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(WorldPalette.ink, lineWidth: 2))
            .frame(height: 10)
            .accessibilityHidden(true)
    }
}

/// A medal: the kind's pixel art on its coloured disc in a 3-pt ink ring, the gift tag, the count and
/// what it counts. One VoiceOver element: the warm sentence and the gifts (“You've written 2 journal
/// moments. 1 gift on the shelf”).
private struct StampBookMedal: View {
    let row: MilestoneRowModel

    var body: some View {
        let art = StampBookArt.keepsake(for: row.kind)
        VStack(spacing: 4) {
            StampBookDisc(fill: WorldPalette.rgb(art.fill)) {
                WorldSpriteView(sprite: art.sprite, scale: 3, tint: StampBookArt.discTint(for: art.sprite))
            }
            .overlay(alignment: .bottomTrailing) {
                if row.giftCount > 0 { StampBookGiftTag(count: row.giftCount).offset(x: 8, y: 6) }
            }
            .padding(.bottom, 4)
            Text(row.count, format: .number)
                .font(.custom(FernletFontName.frauncesSemiBold, size: 18, relativeTo: .headline))
                .foregroundStyle(WorldPalette.bark)
            Text(verbatim: row.shelfLabel)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(WorldPalette.dim)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: StampBookCopy.medalAccessibility(row)))
    }
}

/// The dashed slot for the next kind: its art faded in a dashed ring, “Next” and what will land.
private struct StampBookNextSlot: View {
    let row: MilestoneRowModel

    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .strokeBorder(WorldPalette.ink.opacity(0.35), style: StrokeStyle(lineWidth: 3, dash: [7, 6]))
                .frame(width: 74, height: 74)
                .overlay { WorldSpriteView(sprite: StampBookArt.keepsake(for: row.kind).sprite, scale: 3).opacity(0.75) }
                .padding(.bottom, 4)
            Text("Next")
                .font(.custom(FernletFontName.frauncesSemiBold, size: 15, relativeTo: .subheadline))
                .foregroundStyle(WorldPalette.bark)
            Text(verbatim: StampBookCopy.nextLabel(for: row.kind))
                .font(.fernlet(.labelSmall))
                .foregroundStyle(WorldPalette.dim)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: row.emptyPrompt))
    }
}

/// A medal's disc: 74 pt, the fill, a 3-pt ink ring and a solid shadow 3 pt down.
struct StampBookDisc<Art: View>: View {
    let fill: Color
    var diameter: CGFloat = 74
    @ViewBuilder let art: Art

    var body: some View {
        art
            .frame(width: diameter, height: diameter)
            .background(fill, in: Circle())
            .overlay(Circle().strokeBorder(WorldPalette.ink, lineWidth: 3))
            .background(Circle().fill(WorldPalette.ink.opacity(0.25)).offset(y: 3))
    }
}

/// The gold ★ tag on a medal: how many gifts this kind has added. Ink text on gold in both appearances.
private struct StampBookGiftTag: View {
    let count: Int

    var body: some View {
        HStack(spacing: 1) {
            Text(verbatim: "★")
            Text(count, format: .number)
        }
        .font(.custom(FernletFontName.dmSansMedium, size: 12.5, relativeTo: .caption).weight(.bold))
        .foregroundStyle(WorldPalette.rgb(0x3A2414))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(WorldPalette.rgb(0xF2D58A), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(WorldPalette.ink, lineWidth: 2))
        .accessibilityHidden(true)
    }
}

/// The coins line under the shelves: the pixel coin and what milestone gifts have added, or the gentle
/// note before the first.
private struct StampBookCoinsLine: View {
    let totalCoins: Int

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            WorldSpriteView(sprite: WorldSprites.coin, scale: 3)
            if totalCoins > 0 {
                Text(verbatim: MilestonesCopy.coinsAdded(totalCoins))
            } else {
                Text("No milestone gifts yet — the first lands with your very first log. No rush.")
            }
        }
        .font(.fernlet(.bodySmall))
        .foregroundStyle(WorldPalette.bark)
        .fernletWrappingText()
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }
}
