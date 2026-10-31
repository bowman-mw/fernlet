import FernletUI
import SwiftUI
import WorldMapStore

/// A page's header (`.pphd`): its name in moss small caps on the left, its detail on the right ("AUG – SEP 2026"),
/// a hairline under. Decoration: VoiceOver reads the page's own label instead.
struct PassportPageHeader: View {
    let title: Text
    var detail: Text?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        VStack(spacing: 6) {
            layout {
                title.foregroundStyle(PassportBookPalette.moss).tracking(1.5)
                if !stacked { Spacer(minLength: 4) }
                detail?.foregroundStyle(PassportBookPalette.dim).tracking(0.9)
                    .multilineTextAlignment(stacked ? .leading : .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(PassportBookType.header)
            .textCase(.uppercase)
            PassportBookPalette.rule.frame(height: 1.5)
        }
        .accessibilityHidden(true)
    }
}

/// A heading inside a page (`.pph`): "TWO TO AIM FOR".
struct PassportPageHeading: View {
    let text: Text

    var body: some View {
        text.font(PassportBookType.heading)
            .tracking(1.3)
            .textCase(.uppercase)
            .foregroundStyle(PassportBookPalette.moss)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Page 2, Your world (World-Passport-Spec §5): the header with the first stamp's date, the approved description,
/// the world preview, the four approved counts (countries, continents and oceans with their bars, the seas with
/// none), the airports found once there is one ("6 airports", no total: World-Airports-Spec §4.2) and the two
/// specials, greyed with how many to go until earned.
struct PassportWorldPage: View {
    let book: PassportBookModel
    let progress: PassportProgress
    /// Where the world preview's data comes from (the person's passport and fog, or the DEBUG demo).
    let world: WorldAtlasMapView.Source
    /// Opens the full-screen world view (the preview's tap).
    let onOpenMap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PassportPageHeader(title: Text(PassportBookCopy.yourWorld),
                               detail: book.dateSpan.map { Text(PassportPageCopy.since(PassportDates.short($0.first))) })
            Text(PassportPageCopy.description)
                .font(PassportBookType.body)
                .foregroundStyle(PassportBookPalette.dim)
                .fernletWrappingText()
            WorldAtlasPreview(source: world, onOpen: onOpenMap)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 7) {
                PassportCountLine(count: progress.countryCount, total: PassportProgress.countryTotal,
                                  words: Text(PassportPageCopy.ofCountries(PassportProgress.countryTotal)))
                PassportCountLine(count: progress.continentCount, total: PassportProgress.continentTotal,
                                  words: Text(PassportPageCopy.ofContinents(PassportProgress.continentTotal)))
                PassportCountLine(count: progress.oceanCount, total: PassportProgress.oceanTotal,
                                  words: Text(PassportPageCopy.ofOceans(PassportProgress.oceanTotal)))
                PassportCountLine(count: progress.seaCount, total: nil, words: Text(PassportPageCopy.seas(progress.seaCount)))
                if progress.airportCount > 0 {
                    PassportCountLine(count: progress.airportCount, total: nil,
                                      words: Text(PassportPageCopy.airports(progress.airportCount)))
                }
            }
            PassportPageHeading(text: Text(PassportPageCopy.twoToAimFor))
            HStack(alignment: .top, spacing: 8) {
                PassportAimFor(allOceans: false, earned: progress.hasAllContinents,
                               toGo: PassportProgress.continentTotal - progress.continentCount)
                PassportAimFor(allOceans: true, earned: progress.hasAllOceans,
                               toGo: PassportProgress.oceanTotal - progress.oceanCount)
            }
        }
    }
}

/// One count (`.exprog`): the big number, its words, and a bar when it has a total (the seas have none). One
/// VoiceOver element: "6 of 194 countries".
struct PassportCountLine: View {
    let count: Int
    let total: Int?
    let words: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "\(count)")
                    .font(PassportBookType.count)
                    .foregroundStyle(PassportBookPalette.text)
                words.font(PassportBookType.countWords)
                    .foregroundStyle(PassportBookPalette.text)
                    .fernletWrappingText()
            }
            if let total, total > 0 {
                GeometryReader { proxy in
                    let share = max(0.02, min(Double(count) / Double(total), 1))
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(PassportBookPalette.paper)
                        WorldPalette.moss.frame(width: max(proxy.size.width - 4, 0) * share).padding(2)
                        RoundedRectangle(cornerRadius: 3).strokeBorder(WorldPalette.ink, lineWidth: 2)
                    }
                }
                .frame(height: 9)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A special to aim for (`.pppair`): its picture (grey until earned), its name, and "3 to go" while not earned.
struct PassportAimFor: View {
    let allOceans: Bool
    let earned: Bool
    let toGo: Int

    var body: some View {
        VStack(spacing: 3) {
            PassportSpecialArt(allOceans: allOceans, earned: earned, scale: 2.4)
                .accessibilityHidden(true)
            Text(PassportCopy.specialName(allOceans: allOceans))
                .font(PassportBookType.rowName)
                .foregroundStyle(PassportBookPalette.text)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
            if !earned {
                Text(PassportPageCopy.toGo(max(toGo, 0)))
                    .font(PassportBookType.rowSmall)
                    .foregroundStyle(PassportBookPalette.dim)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(PassportCopy.special(allOceans: allOceans, earned: earned)))
        .accessibilityValue(earned ? Text(verbatim: "") : Text(PassportPageCopy.toGo(max(toGo, 0))))
    }
}
