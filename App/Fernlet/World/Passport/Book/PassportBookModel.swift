import FernletDomainModel
import Foundation
import WorldMapStore

/// One page of Sprout's passport (World-Passport-Spec §2): Sprout's own page, Your world, a stamp page (by its
/// place among the stamp pages, from 0) or the index at the back.
nonisolated enum PassportBookPage: Hashable, Sendable {
    case sprout
    case world
    case stamps(Int)
    case index
}

/// The book's pages, worked out from the stamps it holds (World-Passport-Spec §2, §6): page 1 Sprout, page 2 Your
/// world, then the stamp pages, six stamps each in visit order (at least one: a fresh passport's page 3 says "No
/// stamps yet"), then the index. A fresh passport has 4 pages and no ribbon.
///
/// A value built from a plain list of entries (the screens hand it `store.worldFog.atlas.book.stamps`, empty in a
/// decoy). Page numbers are 1-based, as the page bar prints them. Bounded by
/// ``PassportStampEntry/maxEntries``.
nonisolated struct PassportBookModel: Equatable, Sendable {
    /// The stamps in visit order.
    let ordered: [PassportStampEntry]
    /// The stamp pages, six a page; empty for a fresh passport.
    let stampPages: [[PassportStampEntry]]
    /// Each stamp's page number, by its identity (kind, token, trip).
    private let pageOfStamp: [PassportStampKey: Int]

    /// The first stamp page's number.
    static let firstStampPage = 3

    /// The book for `entries`, ordered by `calendar`'s days.
    init(entries: [PassportStampEntry], calendar: Calendar = .current) {
        let ordered = PassportStampEntry.ordered(entries, calendar: calendar)
        self.ordered = ordered
        stampPages = stride(from: 0, to: ordered.count, by: PassportStampEntry.perPage).map {
            Array(ordered[$0 ..< min($0 + PassportStampEntry.perPage, ordered.count)])
        }
        var pages: [PassportStampKey: Int] = [:]
        // Bounded: ordered holds at most PassportStampEntry.maxEntries.
        for (index, entry) in ordered.enumerated() {
            pages[PassportStampKey(entry)] = Self.firstStampPage + index / PassportStampEntry.perPage
        }
        pageOfStamp = pages
    }

    /// Whether no stamp has landed yet.
    var isFresh: Bool { ordered.isEmpty }
    /// How many stamp pages the book shows (a fresh one shows one, empty).
    var stampPageCount: Int { max(stampPages.count, 1) }
    /// How many pages in all: Sprout, Your world, the stamp pages, the index.
    var pageCount: Int { 2 + stampPageCount + 1 }
    /// The index's page number (the last).
    var indexPage: Int { pageCount }
    /// The stamp pages' numbers.
    var stampPageNumbers: ClosedRange<Int> { Self.firstStampPage ... Self.firstStampPage + stampPageCount - 1 }

    /// Page `number`, clamped into the book.
    func page(at number: Int) -> PassportBookPage {
        let number = clamped(number)
        switch number {
        case 1: return .sprout
        case 2: return .world
        case indexPage: return .index
        default: return .stamps(number - Self.firstStampPage)
        }
    }

    /// `number` clamped to 1 ... ``pageCount``.
    func clamped(_ number: Int) -> Int {
        min(max(number, 1), pageCount)
    }

    /// The stamps on stamp page `index` (from 0), or none.
    func stamps(onStampPage index: Int) -> [PassportStampEntry] {
        stampPages.indices.contains(index) ? stampPages[index] : []
    }

    /// The newest stamp (the last to land), or nil for a fresh passport.
    var newest: PassportStampEntry? { ordered.last }

    /// The page the ribbon marks: the newest stamp's; nil before the first stamp (no ribbon).
    var ribbonPage: Int? { newest.flatMap(pageNumber(of:)) }

    /// The page `entry` landed on (matched by kind, token and trip), or nil when the book doesn't hold it.
    func pageNumber(of entry: PassportStampEntry) -> Int? {
        pageOfStamp[PassportStampKey(entry)]
    }

    /// Whether stamp page `index` is the newest (it shows the dotted "next stamp" spot when it has room).
    func isNewestStampPage(_ index: Int) -> Bool {
        index == stampPages.count - 1
    }

    /// The first and last stamp dates on stamp page `index`, or nil when it holds none.
    func dates(onStampPage index: Int) -> (first: Date, last: Date)? {
        let stamps = stamps(onStampPage: index)
        guard let first = stamps.first?.date, let last = stamps.last?.date else { return nil }
        return (first, last)
    }

    /// The first and last stamp dates in the whole book, or nil for a fresh one.
    var dateSpan: (first: Date, last: Date)? {
        guard let first = ordered.first?.date, let last = ordered.last?.date else { return nil }
        return (first, last)
    }
}

/// A stamp's identity in the book: kind, token and trip (two trips to one country are two stamps).
nonisolated struct PassportStampKey: Hashable, Sendable {
    let kind: PassportStampEntry.Kind
    let token: String
    let trip: Int

    /// The key of `entry`.
    init(_ entry: PassportStampEntry) {
        kind = entry.kind
        token = entry.token
        trip = entry.trip
    }
}

extension PassportStampEntry {
    /// The page entry for one stamp of the per-trip store (`PassportBook.stamps`), the specials mapped to this
    /// layer's tokens; nil for an airport's stamp, which this layer doesn't draw yet (its ticket stamp,
    /// World-Airports-Spec §4.1, comes with the airports' screens).
    nonisolated init?(stamp: PassportStamp) {
        switch stamp.kind {
        case .airport: return nil
        case .country: self.init(kind: .country, token: stamp.token, date: stamp.date, trip: stamp.trip)
        case .continent: self.init(kind: .continent, token: stamp.token, date: stamp.date)
        case .ocean: self.init(kind: .ocean, token: stamp.token, date: stamp.date)
        case .sea: self.init(kind: .sea, token: stamp.token, date: stamp.date)
        case .allContinents: self.init(kind: .special, token: Self.allContinentsToken, date: stamp.date)
        case .allOceans: self.init(kind: .special, token: Self.allOceansToken, date: stamp.date)
        }
    }

    /// Every stamp `book` holds, as page entries (the book's own visit order; ``PassportBookModel`` orders them
    /// again by day), airports' stamps left out until this layer draws them. Bounded by the book's caps.
    nonisolated static func entries(of book: PassportBook) -> [PassportStampEntry] {
        Array(book.stamps.compactMap(PassportStampEntry.init(stamp:)).prefix(maxEntries))
    }
}

/// The words the page bar, the headers and VoiceOver build from dates (World-Passport-Spec §3, §5, §6): "AUG – SEP
/// 2026" over a stamp page, "Since 14 AUG 2026" on page 2, "14 August to 21 September" for VoiceOver, from the
/// passport's own month tables (``PassportDates``), never ICU's.
nonisolated enum PassportBookDates {
    /// A stamp page's months: "AUG – SEP 2026", "OCT 2026", "DEC 2026 – JAN 2027".
    static func months(from first: Date, to last: Date, calendar: Calendar = .current,
                       language: FernletLanguage = .app) -> String {
        let months = PassportDates.shortMonths(language)
        let start = calendar.dateComponents([.month, .year], from: first)
        let end = calendar.dateComponents([.month, .year], from: last)
        let startMonth = months[min(max((start.month ?? 1) - 1, 0), 11)]
        let endMonth = months[min(max((end.month ?? 1) - 1, 0), 11)]
        let startYear = start.year ?? 0, endYear = end.year ?? 0
        if startYear != endYear { return "\(startMonth) \(startYear) – \(endMonth) \(endYear)" }
        if startMonth == endMonth { return "\(startMonth) \(startYear)" }
        return "\(startMonth) – \(endMonth) \(startYear)"
    }

    /// "14 August" / "14 de agosto" (VoiceOver's day and month, no year).
    static func dayMonth(_ date: Date, calendar: Calendar = .current, language: FernletLanguage = .app) -> String {
        let parts = calendar.dateComponents([.day, .month], from: date)
        let months = PassportDates.longMonths(language), month = min(max((parts.month ?? 1) - 1, 0), 11)
        let day = parts.day ?? 1
        return language == .spanish ? "\(day) de \(months[month])" : "\(day) \(months[month])"
    }

    /// "14 AUG" (the contents list's short day, no year).
    static func shortDay(_ date: Date, calendar: Calendar = .current, language: FernletLanguage = .app) -> String {
        let parts = calendar.dateComponents([.day, .month], from: date)
        let months = PassportDates.shortMonths(language), month = min(max((parts.month ?? 1) - 1, 0), 11)
        return "\(parts.day ?? 1) \(months[month])"
    }
}
