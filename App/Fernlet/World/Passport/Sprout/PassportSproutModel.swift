import FernletDomainModel
import FernletUI
import Foundation

/// The passport's four counts as page 1's second machine-readable line carries them (World-Passport-Spec §4):
/// countries, continents, oceans and seas, each counted once however many stamps it has.
nonisolated struct PassportSproutCounts: Equatable, Sendable {
    var countries = 0
    var continents = 0
    var oceans = 0
    var seas = 0

    /// Nothing found: a fresh passport, or a decoy's.
    static let zero = PassportSproutCounts()

    /// The counts of `progress` (``PassportProgress``).
    init(progress: PassportProgress) {
        self.init(countries: progress.countryCount, continents: progress.continentCount, oceans: progress.oceanCount,
                  seas: progress.seaCount)
    }

    /// Counts given by hand (tests, the zero passport).
    init(countries: Int = 0, continents: Int = 0, oceans: Int = 0, seas: Int = 0) {
        self.countries = max(0, countries)
        self.continents = max(0, continents)
        self.oceans = max(0, oceans)
        self.seas = max(0, seas)
    }
}

/// Page 1's two machine-readable lines (§4), drawn like a real passport's: 44 characters each, filled with "<".
/// Decoration: VoiceOver never reads them.
///
/// - Line 1: `P<FRN` and the companion's name in capitals (`P<FRNSPROUT` for Sprout): letters folded to A–Z
///   (é → E), digits kept, spaces and dashes as "<", everything else dropped.
/// - Line 2: `FRN<C006<K03<O02<S02`: countries in three digits, continents, oceans and seas in two.
nonisolated enum PassportMachineLines {
    /// Every line's length.
    static let width = 44
    /// The filler.
    static let filler: Character = "<"

    /// Both lines for `name` and `counts`.
    static func lines(name: String, counts: PassportSproutCounts) -> [String] {
        [padded("P<FRN" + nameField(name)), padded(countsField(counts))]
    }

    /// The name as the line spells it: upper case A–Z and 0–9, spaces and dashes as "<", nothing else.
    static func nameField(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .uppercased(with: Locale(identifier: "en_US_POSIX"))
        var out = ""
        // Bounded: at most `width` characters are kept.
        for character in folded.prefix(width * 2) where out.count < width {
            if character.isASCII, character.isLetter || character.isNumber {
                out.append(character)
            } else if character == " " || character == "-", out.last != filler, !out.isEmpty {
                out.append(filler)
            }
        }
        return out.last == filler ? String(out.dropLast()) : out
    }

    /// `FRN<C006<K03<O02<S02`.
    static func countsField(_ counts: PassportSproutCounts) -> String {
        "FRN<C" + digits(counts.countries, 3) + "<K" + digits(counts.continents, 2) + "<O" + digits(counts.oceans, 2)
            + "<S" + digits(counts.seas, 2)
    }

    /// `line` cut or filled with "<" to ``width``.
    static func padded(_ line: String) -> String {
        let cut = String(line.prefix(width))
        return cut + String(repeating: String(filler), count: width - cut.count)
    }

    /// `value` in `places` digits, zero-filled, held to the largest number that fits.
    private static func digits(_ value: Int, _ places: Int) -> String {
        let largest = places >= 3 ? 999 : 99
        let text = String(min(max(value, 0), largest))
        return String(repeating: "0", count: max(0, places - text.count)) + text
    }
}

/// What can be done from page 1 of Sprout's passport: the close-up's, Customize's and the shop's actions in
/// their new home (`ps-parity`). ``PassportSproutModel/actions`` lists the ones the page offers right now, and
/// the page draws exactly those.
nonisolated enum PassportSproutAction: Hashable, Sendable {
    /// Tap the photo to pet (the close-up's tap).
    case pet
    /// One of the four slot buttons, opening its approved page.
    case slot(CustomizeSlot)
    case wardrobe
    case creationStudio
    /// Your shop (`b2-shop-editor`).
    case yourShop
    /// Friend shops (`b2-friend-shop`), for the hour after a session.
    case friendShops
    /// This is home (`ref-comp-home-add`).
    case thisIsHome
    /// Manage, at a home or the hotel (`ref-comp-home-at`).
    case manageHomes
    case appColors
}

/// Everything page 1 shows (World-Passport-Spec §4), read once from the store so the view and the tests read
/// one value. In a decoy session it is a fresh passport with nothing real (§9): the companion as it first looked
/// (Circle, the sprout, nothing else), nothing listed, 0 coins, no gold hearts, every count 0, no friend shops
/// and no home row.
struct PassportSproutModel: Equatable {
    /// The companion's name (or Fernlet).
    let name: String
    /// "Thriving · happy" (``PassportSproutCopy/feeling(state:word:)``).
    let feeling: String
    /// The day's band, for the photo's spoken label.
    let state: CompanionState
    /// What it wears, as the page draws it (the standard look in a decoy).
    let appearance: CompanionAppearance
    /// The four slot buttons, in order.
    let slots: [CustomizeSlotSummary]
    /// The hearts and gold hearts.
    let status: WorldStatus
    /// Items listed in Your shop.
    let listed: Int
    /// The coin balance.
    let coins: Int
    /// Minutes left in the friend-shop window, or nil when it is shut.
    let friendShopMinutes: Int?
    /// Where the person stands, for the bottom row.
    let place: WorldCloseUpPlace
    /// The passport's counts, for the second machine line.
    let counts: PassportSproutCounts
    let isDecoy: Bool

    /// The body shape, as the Shape field reads it.
    var shape: String { appearance.bodyStyle.label }

    /// The two machine-readable lines.
    var machineLines: [String] { PassportMachineLines.lines(name: name, counts: counts) }

    /// What the page offers now, in its order.
    var actions: [PassportSproutAction] {
        var list: [PassportSproutAction] = [.pet] + slots.map { .slot($0.slot) } + [.wardrobe, .creationStudio, .yourShop]
        if friendShopMinutes != nil { list.append(.friendShops) }
        switch place {
        case .away: list.append(.thisIsHome)
        case .home, .hotel: list.append(.manageHomes)
        case .unknown: break
        }
        list.append(.appColors)
        return list
    }

    /// The page for these readings. A decoy replaces everything that is the person's with a fresh passport's.
    static func make(name: String, feeling: String, state: CompanionState, appearance: CompanionAppearance,
                     equipped: [CustomizationItem], status: WorldStatus, listed: Int, coins: Int,
                     friendShopMinutes: Int?, place: WorldCloseUpPlace, counts: PassportSproutCounts,
                     isDecoy: Bool) -> PassportSproutModel {
        let look = isDecoy ? CompanionAppearance.standard : appearance
        let worn = isDecoy ? [] : equipped
        return PassportSproutModel(
            name: name, feeling: feeling, state: state, appearance: look,
            slots: CustomizeSlot.allCases.map { CustomizeSlotSummary.make($0, appearance: look, equipped: worn) },
            status: status, listed: isDecoy ? 0 : max(0, listed), coins: isDecoy ? 0 : max(0, coins),
            friendShopMinutes: isDecoy ? nil : friendShopMinutes, place: isDecoy ? .unknown : place,
            counts: isDecoy ? .zero : counts, isDecoy: isDecoy)
    }
}

/// Page 1's words (World-Passport-Spec §10), resolved here so the views and the tests read one copy.
nonisolated enum PassportSproutCopy {
    /// "Passport": the header (in capitals) and the title the pushed pages' Back reads.
    static var passport: String {
        String(localized: "passport.title", defaultValue: "Passport",
               comment: "Sprout's passport: the book's name, shown in capitals on page 1's header and read by Back on the pages it opens. Spanish: Pasaporte")
    }

    /// "Name", "Feeling", "Shape", "Care": the details' labels.
    static var nameLabel: String {
        String(localized: "passport.field.name", defaultValue: "Name", comment: "Sprout's passport, page 1: the companion's name field. Spanish: Nombre")
    }
    static var feelingLabel: String {
        String(localized: "passport.field.feeling", defaultValue: "Feeling", comment: "Sprout's passport, page 1: the companion's state and feeling. Spanish: Ánimo")
    }
    static var shapeLabel: String {
        String(localized: "passport.field.shape", defaultValue: "Shape", comment: "Sprout's passport, page 1: the companion's body shape. Spanish: Forma")
    }
    static var careLabel: String {
        String(localized: "passport.field.care", defaultValue: "Care", comment: "Sprout's passport, page 1: the six hearts and gold hearts. Spanish: Cuidado")
    }

    /// "Thriving · happy": the state, then the feeling's word; nil `word` (asleep) is the word alone.
    static func feeling(state: String, word: String?) -> String {
        guard let word else { return state }
        return String(localized: "passport.feeling", defaultValue: "\(state) · \(word)",
                      comment: "Sprout's passport, page 1, the Feeling field: the companion's state, then its feeling in a word, e.g. 'Thriving · happy' (Spanish: 'Radiante · contento')")
    }

    /// What VoiceOver reads for the hearts: "Care 92 percent, one gold heart from a friend."
    static func spokenCare(percent: Int, goldHearts: Int) -> String {
        switch goldHearts {
        case ..<1:
            String(localized: "passport.care.a11y", defaultValue: "Care \(percent) percent.",
                   comment: "Sprout's passport, page 1, VoiceOver: the hearts as a care score")
        case 1:
            String(localized: "passport.care.a11y.oneGold", defaultValue: "Care \(percent) percent, one gold heart from a friend.",
                   comment: "Sprout's passport, page 1, VoiceOver: the care score with one gold heart a friend gave in person")
        default:
            String(localized: "passport.care.a11y.gold", defaultValue: "Care \(percent) percent, \(goldHearts) gold hearts from friends.",
                   comment: "Sprout's passport, page 1, VoiceOver: the care score with two gold hearts friends gave in person")
        }
    }

    /// The photo's spoken name: "Sprout, Thriving."
    static func photoLabel(name: String, state: String) -> String {
        String(localized: "passport.photo.a11y", defaultValue: "\(name), \(state).",
               comment: "Sprout's passport, page 1, VoiceOver: the companion's photo, its name then its state, e.g. 'Sprout, thriving.'")
    }

    /// The photo's hint: "Tap to pet."
    static var photoHint: String {
        String(localized: "passport.photo.hint", defaultValue: "Tap to pet.",
               comment: "Sprout's passport, page 1, VoiceOver hint on the companion's photo. Spanish: Toca para acariciar.")
    }

    /// "What Sprout's wearing".
    static func wearingHeader(name: String) -> String {
        String(localized: "passport.wearing", defaultValue: "What \(name)'s wearing",
               comment: "Sprout's passport, page 1: heading over the four slot buttons; the companion's name. Spanish: 'Lo que lleva Sprout'")
    }

    /// "Shop".
    static var shopHeader: String {
        String(localized: "passport.shop", defaultValue: "Shop", comment: "Sprout's passport, page 1: heading over the shop rows. Spanish: Tienda")
    }

    /// "Your shop".
    static var yourShop: String {
        String(localized: "passport.yourShop", defaultValue: "Your shop",
               comment: "Sprout's passport, page 1: the row that opens the person's own shop. Spanish: Tu tienda")
    }

    /// "3 of 6 listed", or "Nothing listed".
    static func listed(_ count: Int, of total: Int) -> String {
        guard count > 0 else {
            return String(localized: "passport.listed.none", defaultValue: "Nothing listed",
                          comment: "Sprout's passport, page 1, Your shop row: no items in the shop. Spanish: Nada a la venta")
        }
        return String(localized: "passport.listed", defaultValue: "\(count) of \(total) listed",
                      comment: "Sprout's passport, page 1, Your shop row: items in the shop of its six spots. Spanish: 'N de 6 a la venta'")
    }

    /// VoiceOver for the Your shop row: "Your shop, 3 of 6 listed, 25 coins".
    @MainActor
    static func yourShopSpoken(listed: String, coins: Int) -> String {
        String(localized: "passport.yourShop.a11y", defaultValue: "\(yourShop), \(listed), \(FernletUICopy.coinBalance(coins))",
               comment: "Sprout's passport, page 1, VoiceOver: 'Your shop', how many are listed, then the coin balance ('25 coins')")
    }

    /// "Friend shops".
    static var friendShops: String {
        String(localized: "passport.friendShops", defaultValue: "Friend shops",
               comment: "Sprout's passport, page 1: the gold row opening friends' shops, for the hour after a session. Spanish: Tiendas de amigos")
    }

    /// "Open · 52 min left".
    static func friendShopsOpen(minutes: Int) -> String {
        String(localized: "passport.friendShops.open", defaultValue: "Open · \(minutes) min left",
               comment: "Sprout's passport, page 1, Friend shops row: the shops are open, minutes left. Spanish: 'Abiertas · quedan N min'")
    }

    /// VoiceOver for the Friend shops row: "Friend shops, open, 52 minutes left".
    static func friendShopsSpoken(minutes: Int) -> String {
        String(localized: "passport.friendShops.a11y", defaultValue: "Friend shops, open, \(minutes) minutes left",
               comment: "Sprout's passport, page 1, VoiceOver: the Friend shops row. Spanish: 'Tiendas de amigos, abiertas, quedan N minutos'")
    }

    /// "App colors".
    static var appColors: String {
        String(localized: "passport.appColors", defaultValue: "App colors",
               comment: "Sprout's passport, page 1: the row opening App colors (paper, wood and accent). Spanish: Colores de la app")
    }
}
