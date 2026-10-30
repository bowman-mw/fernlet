import FernletUI
import SwiftUI
import WorldMapStore

/// The page bar under the book (World-Passport-Spec §2, §3): a cream framed bar with ‹, the page's name ("3 of 6 ·
/// Stamps ▾", which opens the contents) and ›. Voice Control: "Previous page", "Contents", "Next page".
struct PassportPageBar: View {
    let number: Int
    let count: Int
    let name: String
    let onPrevious: () -> Void
    let onContents: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            PassportBarArrow(sprite: WorldSprites.chevL, label: PassportBookCopy.previousPage, enabled: number > 1,
                             action: onPrevious)
            Button(action: onContents) {
                HStack(spacing: 6) {
                    Text(verbatim: "\(number)").font(PassportBookType.bar)
                    Text(PassportBookCopy.of(count)).font(PassportBookType.barQuiet).foregroundStyle(WorldPalette.dim)
                    Text(verbatim: "· \(name)").font(PassportBookType.bar)
                    WorldSpriteView(sprite: WorldSprites.chevD, scale: 2, tint: WorldPalette.iconInk)
                }
                .foregroundStyle(WorldPalette.bark)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 10)
                .frame(minWidth: 150, minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(PassportBookCopy.contentsButton(number, of: count, named: name)))
            .accessibilityInputLabels([Text(PassportBookCopy.contents)])
            .accessibilityIdentifier("passport.contents")
            PassportBarArrow(sprite: WorldSprites.chevR, label: PassportBookCopy.nextPage, enabled: number < count,
                             action: onNext)
        }
        .padding(2)
        .background(PassportCreamPlate(radius: 12))
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(PassportBookCopy.pages))
    }
}

/// The continent bar (World-Passport-Spec §8): ‹ and › step between the seven continents ("North America · 1 of 7").
/// For the oceans and the seas it shows their name alone.
struct PassportContinentBar: View {
    let detail: PassportIndexDetail
    let onStep: (PassportIndexDetail) -> Void

    var body: some View {
        let order = AtlasContinent.passportOrder
        HStack(spacing: 2) {
            PassportBarArrow(sprite: WorldSprites.chevL, label: PassportPageCopy.previousContinent,
                             enabled: (position ?? 0) > 0) {
                if let position, position > 0 { onStep(.continent(order[position - 1])) }
            }
            HStack(spacing: 6) {
                Text(name).font(PassportBookType.bar).foregroundStyle(WorldPalette.bark)
                if let position {
                    Text(PassportPageCopy.continentStep(position + 1, of: order.count))
                        .font(PassportBookType.barQuiet).foregroundStyle(WorldPalette.dim)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 10)
            .frame(minWidth: 150, minHeight: 40)
            .accessibilityElement(children: .combine)
            PassportBarArrow(sprite: WorldSprites.chevR, label: PassportPageCopy.nextContinent,
                             enabled: position.map { $0 < order.count - 1 } ?? false) {
                if let position, position < order.count - 1 { onStep(.continent(order[position + 1])) }
            }
        }
        .padding(2)
        .background(PassportCreamPlate(radius: 12))
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(PassportPageCopy.continents))
    }

    /// The continent's place among the seven, or nil for the oceans and the seas.
    private var position: Int? {
        guard case .continent(let continent) = detail else { return nil }
        return AtlasContinent.passportOrder.firstIndex(of: continent)
    }

    private var name: LocalizedStringResource {
        switch detail {
        case .continent(let continent): continent.passportName
        case .oceans: PassportPageCopy.oceans
        case .seas: PassportPageCopy.seasRow
        }
    }
}

/// One of the bars' arrows: 44 × 40, dimmed and off at the end.
struct PassportBarArrow: View {
    let sprite: WorldSprite
    let label: LocalizedStringResource
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            WorldSpriteView(sprite: sprite, scale: 2, tint: WorldPalette.iconInk)
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.32)
        .accessibilityLabel(Text(label))
        .accessibilityInputLabels([Text(label)])
    }
}

/// The contents (World-Passport-Spec §2): Sprout 1, Your world 2, Stamps 3 to n with their date range, Index last;
/// the current page's row marked. Tapping a row turns there.
struct PassportContents: View {
    let book: PassportBookModel
    let current: Int
    let onPick: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            row(Text(PassportBookCopy.name(of: .sprout)), detail: Text(verbatim: "1"), page: 1, on: current == 1)
            row(Text(PassportBookCopy.yourWorld), detail: Text(verbatim: "2"), page: 2, on: current == 2)
            row(Text(PassportBookCopy.stamps), detail: stampsDetail, page: PassportBookModel.firstStampPage,
                on: book.stampPageNumbers.contains(current))
            row(Text(PassportBookCopy.index), detail: Text(verbatim: "\(book.indexPage)"), page: book.indexPage,
                on: current == book.indexPage)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(WorldPalette.paperLight))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorldPalette.ink, lineWidth: 2))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(PassportBookCopy.contents))
    }

    /// "3 to 5 · 14 AUG to 24 OCT", or the one page number.
    private var stampsDetail: Text {
        let range = book.stampPageNumbers
        guard let span = book.dateSpan, range.count > 1 || !book.isFresh else { return Text(verbatim: "\(range.lowerBound)") }
        return Text(PassportBookCopy.stampsRange(range.lowerBound, range.upperBound,
                                                 from: PassportBookDates.shortDay(span.first),
                                                 to: PassportBookDates.shortDay(span.last)))
    }

    private func row(_ name: Text, detail: Text, page: Int, on: Bool) -> some View {
        Button { onPick(page) } label: {
            HStack(spacing: 8) {
                name.font(Font.custom(FernletFontName.dmSansBold, size: 13.5, relativeTo: .footnote))
                    .foregroundStyle(WorldPalette.bark)
                Spacer(minLength: 8)
                detail.font(Font.custom(FernletFontName.dmSans, size: 13.5, relativeTo: .footnote))
                    .foregroundStyle(WorldPalette.dim)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 11)
            .frame(minHeight: 44)
            .background(on ? WorldPalette.sage : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .overlay(alignment: .top) { if page != 1 { WorldPalette.rule.frame(height: 1) } }
    }
}
