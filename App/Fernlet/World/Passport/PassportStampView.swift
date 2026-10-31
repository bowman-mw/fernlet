import FernletUI
import Foundation
import SwiftUI
import WorldMapStore

/// What one passport stamp is (World-Exploration-Spec §3): a country by its alpha-2 code, a continent, an ocean, a
/// sea by its atlas token, one of the two specials, or an airport by its frozen token (World-Airports-Spec §4.1),
/// whose ticket says TRANSIT for a layover's trip.
nonisolated enum PassportStampKind: Hashable, Sendable {
    /// An airport by its frozen `WorldAirport.token`; `transit` when the trip was a layover.
    case airport(String, transit: Bool)
    case country(String)
    case continent(AtlasContinent)
    case ocean(AtlasOcean)
    case sea(String)
    /// All seven continents (`false`) or all five oceans (`true`).
    case special(allOceans: Bool)

    /// The postmark's shape (a special has none: it is a full-colour picture).
    var shape: PassportPostmarkShape {
        switch self {
        case .airport: .ticket
        case .country: .rect
        case .continent: .round
        case .ocean, .sea, .special: .hex
        }
    }

    /// The key the stamp's tilt, nudge and wear are seeded from (a frozen token, never shown): a country's
    /// lower-case code, a continent's mockup key, an ocean's rawValue, a sea's token, a special's mockup key, an
    /// airport's "ap:" key (a layover's with "t", the mockup's `apEntry`).
    var seedKey: String {
        switch self {
        case .airport(let token, let transit): PassportAirportStamp.seedKey(token, transit: transit)
        case .country(let code): code.lowercased()
        case .continent(let continent): continent.stampKey
        case .ocean(let ocean): ocean.rawValue
        case .sea(let token): token
        case .special(let allOceans): allOceans ? "oceans!" : "continents!"
        }
    }

    /// Whether it is one of the two specials (drawn untilted, in full colour).
    var isSpecial: Bool {
        if case .special = self { return true }
        return false
    }

    /// Whether it is a country's (which carries its own name; the others show theirs underneath on a page).
    var isCountry: Bool {
        if case .country = self { return true }
        return false
    }

    /// Whether it is an airport's ticket.
    var isAirport: Bool {
        if case .airport = self { return true }
        return false
    }

    /// Whether the stamp prints its own name (a country's label, an airport's code and city), so a page shows no
    /// name under it.
    var carriesOwnName: Bool { isCountry || isAirport }
}

/// One stamp to show: what it is and when it was earned (a first visit, or a trip's start).
///
/// `wear` is an input kept for later: the approved faces draw the same seeded ~7 % wear whatever it says.
nonisolated struct PassportStampModel: Hashable, Sendable {
    let kind: PassportStampKind
    /// When it was earned; nil for a stamp not earned yet (an empty dashed space; a special drawn grey).
    let firstVisit: Date?
    /// How worn the stamp looks, 0 (crisp) to 1; not drawn yet.
    let wear: Double

    /// A stamp of `kind` earned at `firstVisit` (nil: not yet), with `wear` clamped to 0...1.
    init(kind: PassportStampKind, firstVisit: Date?, wear: Double = 0) {
        self.kind = kind
        self.firstVisit = firstVisit
        self.wear = wear.isFinite ? min(max(wear, 0), 1) : 0
    }

    /// Whether it is earned.
    var isEarned: Bool { firstVisit != nil }
}

/// Any passport stamp's art, earned or not (World-Exploration-Spec §3, `ex-pass-stamps` draft 2 and `ex-pass-country`),
/// at any scale (Sprout's passport draws 1.9 on a page, 0.66 in the index): a country's rounded-rectangle postmark
/// from `WorldCountryStamps.json`, a continent's round postmark with its silhouette, an ocean's hexagon with its sign,
/// a sea's hexagon of waves, or a full-colour special (its `scale` is points per pixel); each at its stable tilt.
/// Not earned, a postmark is an empty dashed space (``PassportEmptySpace``) and never named; a special is grey.
///
/// VoiceOver reads it by name ("United States, stamp"); an empty space as "A country not reached yet"; a special
/// says whether it is earned. On a page, ``PassportPlacedStamp`` wraps it and speaks for it instead.
struct PassportStampView: View {
    let model: PassportStampModel
    let library: PassportLibrary
    /// The drawing's scale (points per postmark point; a special's points per pixel).
    let scale: CGFloat

    var body: some View {
        switch model.kind {
        case .special(let allOceans):
            PassportSpecialArt(allOceans: allOceans, earned: model.isEarned, scale: scale)
                .accessibilityElement()
                .accessibilityLabel(Text(PassportCopy.special(allOceans: allOceans, earned: model.isEarned)))
        default:
            if model.isEarned, let drawing = library.drawing(of: model.kind) {
                PassportPostmark(stamp: drawing, shape: model.kind.shape, scale: scale)
                    .accessibilityElement()
                    .accessibilityLabel(Text(library.stampLabel(of: model.kind)))
            } else {
                PassportEmptySpace(kind: model.kind, scale: scale)
            }
        }
    }
}

/// A stamp as it lands on a page of Sprout's passport (World-Passport-Spec §6): the art at 1.9×, nudged off the grid
/// by its seed (−7…+7 pt across, −5…+5 down), the name underneath for a continent, ocean or sea (DM Sans Bold 12; a
/// country's stamp and an airport's ticket carry their own), and its date box. One VoiceOver element: "Canada,
/// stamp, 2 September 2026"; an airport's "Heathrow, LHR, stamp, 3 October 2026" or "Helsinki Airport, HEL,
/// transit stamp, 21 October 2026" (World-Airports-Spec §4.2).
///
/// `still` drops the nudge (the moment a new stamp lands, before it settles). The page around it is another
/// piece's; this view only places itself.
struct PassportPlacedStamp: View {
    let entry: PassportStampEntry
    let library: PassportLibrary
    /// The page's stamp scale (1.9 in the book); a special is drawn at 4 pt a pixel at 1.9.
    var scale: CGFloat = 1.9
    var still = false

    var body: some View {
        if let kind = entry.stampKind {
            let nudge = still ? (across: 0, down: 0) : PassportStampSeed.nudge(kind.seedKey)
            let name = library.name(of: kind, onPage: true)
            VStack(spacing: 4) {
                PassportStampView(model: PassportStampModel(kind: kind, firstVisit: entry.date), library: library,
                                  scale: kind.isSpecial ? scale * 4 / 1.9 : scale)
                if !kind.carriesOwnName {
                    Text(verbatim: name)
                        .font(.custom(FernletFontName.dmSansBold, size: 12, relativeTo: .caption))
                        .foregroundStyle(WorldPalette.bark)
                        .multilineTextAlignment(.center)
                        .fernletWrappingText()
                }
                PassportDateBox(date: entry.date, ink: library.ink(of: kind),
                                tilt: kind.isSpecial ? 0 : PassportStampSeed.tilt(kind.seedKey))
            }
            .offset(x: CGFloat(nudge.across), y: CGFloat(nudge.down))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(library.placedLabel(of: kind, on: PassportDates.long(entry.date))))
        }
    }
}

/// A stamp's date box (World-Passport-Spec §6): "14 AUG 2026" in DM Sans Bold 11 with 0.07 em letter spacing, in a
/// 1.5 pt box on the passport's paper, in the stamp's ink made readable (``PassportInk/dateInk(_:dark:increasedContrast:)``:
/// 4.6:1, 7:1 with Increase Contrast), turned 0.6 × the stamp's tilt. It grows with Dynamic Type.
struct PassportDateBox: View {
    let date: Date
    /// The stamp's light-mode ink.
    let ink: UInt32
    /// The stamp's tilt in degrees.
    let tilt: Int
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .caption2) private var tracking: CGFloat = 0.77

    var body: some View {
        let dark = colorScheme == .dark
        let colour = PassportInk.color(PassportInk.dateInk(ink, dark: dark, increasedContrast: contrast == .increased))
        Text(verbatim: PassportDates.short(date))
            .font(.custom(FernletFontName.dmSansBold, size: 11, relativeTo: .caption2))
            .tracking(tracking)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(colour)
            .padding(EdgeInsets(top: 3, leading: 5, bottom: 2, trailing: 5))
            .background(RoundedRectangle(cornerRadius: 3).fill(PassportInk.color(PassportInk.paper(dark: dark))))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(colour, lineWidth: 1.5))
            .rotationEffect(.degrees(0.6 * Double(tilt)))
            .accessibilityHidden(true)
    }
}

/// A stamp not earned yet: its shape dashed with a "?", never named. VoiceOver: "A country not reached yet" (and
/// the same for a continent, an ocean, a sea).
struct PassportEmptySpace: View {
    let kind: PassportStampKind
    let scale: CGFloat

    var body: some View {
        PassportPostmark(stamp: nil, shape: kind.shape, scale: scale)
            .accessibilityElement()
            .accessibilityLabel(Text(PassportCopy.notReached(kind)))
    }
}

/// One of the two specials, the only full-colour stamps: 18 × 18 pixels at `scale` points each, grey until earned.
/// Named for VoiceOver by ``PassportStampView``.
struct PassportSpecialArt: View {
    let allOceans: Bool
    let earned: Bool
    let scale: CGFloat

    var body: some View {
        let pixels = PassportStampArt.special(allOceans: allOceans)
        let side = CGFloat(pixels.count)
        Canvas { context, _ in
            for (row, line) in pixels.enumerated() {
                for (col, colour) in line.enumerated() {
                    guard let colour else { continue }
                    let rect = CGRect(x: CGFloat(col) * scale, y: CGFloat(row) * scale, width: scale, height: scale)
                    let ink = earned ? colour : PassportStampArt.specialGrey
                    context.fill(Path(rect), with: .color(PassportInk.color(ink)))
                }
            }
        }
        .frame(width: side * scale, height: side * scale)
    }
}

/// The passport stamps' words (Spanish drafts in the lane's `r7-explore-ui-es-passport.json`).
enum PassportCopy {
    /// "United States, stamp".
    static func stamp(named name: String) -> LocalizedStringResource {
        LocalizedStringResource("\(name), stamp", comment: "VoiceOver: a passport stamp, by the place's name")
    }

    /// "Canada, stamp, 2 September 2026".
    static func placed(named name: String, on date: String) -> LocalizedStringResource {
        LocalizedStringResource("\(name), stamp, \(date)",
                                comment: "VoiceOver: a stamp on a passport page: the place's name, then the stamp's date")
    }

    /// "Heathrow, LHR, stamp" (an airport's ticket, by its name and code).
    static func airportStamp(named name: String, code: String) -> LocalizedStringResource {
        LocalizedStringResource("\(name), \(code), stamp",
                                comment: "VoiceOver: an airport's passport stamp: the airport's name, then its code (Heathrow, LHR, stamp)")
    }

    /// "Heathrow, LHR, stamp, 3 October 2026" (an airport's ticket on a page).
    static func placedAirport(named name: String, code: String, on date: String) -> LocalizedStringResource {
        LocalizedStringResource("\(name), \(code), stamp, \(date)",
                                comment: "VoiceOver: an airport's stamp on a passport page: its name, its code, then the stamp's date")
    }

    /// "Helsinki Airport, HEL, transit stamp, 21 October 2026" (a layover's ticket on a page).
    static func placedTransit(named name: String, code: String, on date: String) -> LocalizedStringResource {
        LocalizedStringResource("\(name), \(code), transit stamp, \(date)",
                                comment: "VoiceOver: a layover's airport stamp on a passport page (it says TRANSIT): its name, its code, then the date")
    }

    /// "A country not reached yet" (a continent, an ocean, a sea; "An airport not found yet").
    static func notReached(_ kind: PassportStampKind) -> LocalizedStringResource {
        switch kind {
        case .airport: LocalizedStringResource("An airport not found yet",
                                               comment: "VoiceOver: a dashed airport ticket in the passport, not found yet")
        case .country: LocalizedStringResource("A country not reached yet",
                                               comment: "VoiceOver: an empty passport space for a country")
        case .continent: LocalizedStringResource("A continent not reached yet",
                                                 comment: "VoiceOver: an empty passport space for a continent")
        case .ocean: LocalizedStringResource("An ocean not reached yet",
                                             comment: "VoiceOver: an empty passport space for an ocean")
        case .sea: LocalizedStringResource("A sea not reached yet",
                                           comment: "VoiceOver: an empty passport space for a sea")
        case .special(let allOceans): specialName(allOceans: allOceans)
        }
    }

    /// "All seven continents" or "All five oceans".
    static func specialName(allOceans: Bool) -> LocalizedStringResource {
        allOceans ? LocalizedStringResource("All five oceans", comment: "Passport: the special stamp for every ocean")
            : LocalizedStringResource("All seven continents", comment: "Passport: the special stamp for every continent")
    }

    /// "All five oceans, earned" or "All five oceans, not earned yet".
    static func special(allOceans: Bool, earned: Bool) -> LocalizedStringResource {
        let name = String(localized: specialName(allOceans: allOceans))
        return earned ? LocalizedStringResource("\(name), earned", comment: "VoiceOver: a passport special, earned")
            : LocalizedStringResource("\(name), not earned yet", comment: "VoiceOver: a passport special, not earned yet")
    }
}
