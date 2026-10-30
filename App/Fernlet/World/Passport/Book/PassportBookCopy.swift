import Foundation

/// The words of Sprout's passport book (World-Passport-Spec §10; Spanish drafts in the lane's
/// `r7-explore-ui-es-book.json`). Page names, the page bar, the chips, the headers, VoiceOver's and Voice
/// Control's names.
nonisolated enum PassportBookCopy {
    // MARK: The book

    /// "Passport": the book's own name, which a page pushed from page 1 reads on its Back.
    static let passport = LocalizedStringResource("Passport", comment: "Sprout's passport: Back on a page pushed from page 1")
    /// "PASSPORT", the cover's word (shown in capitals).
    static let coverWord = LocalizedStringResource("PASSPORT", comment: "Sprout's passport: the word on its cover")
    /// "Sprout's passport, closed" (the cover while it rises).
    static let closedBook = LocalizedStringResource("Sprout's passport, closed",
                                                    comment: "VoiceOver: Sprout's passport, before it opens")
    /// "Close the passport" (the ✕).
    static let close = LocalizedStringResource("Close the passport", comment: "VoiceOver: the passport's close button")
    /// "Close" (Voice Control's name for the ✕).
    static let closeShort = LocalizedStringResource("Close", comment: "Voice Control: the passport's close button")

    /// A page's name in the page bar: "Sprout", "Your world", "Stamps", "Index".
    static func name(of page: PassportBookPage) -> LocalizedStringResource {
        switch page {
        case .sprout: LocalizedStringResource("Sprout", comment: "Sprout's passport: page 1's name, the companion's own page")
        case .world: yourWorld
        case .stamps: stamps
        case .index: index
        }
    }

    /// "Your world".
    static let yourWorld = LocalizedStringResource("Your world", comment: "Sprout's passport: page 2's name")
    /// "Stamps".
    static let stamps = LocalizedStringResource("Stamps", comment: "Sprout's passport: a stamp page's name")
    /// "Index".
    static let index = LocalizedStringResource("Index", comment: "Sprout's passport: the index page's name")

    /// "Sprout's passport, page 1 of 6, Sprout" (the page, for VoiceOver).
    static func page(_ number: Int, of count: Int, named name: String) -> LocalizedStringResource {
        LocalizedStringResource("Sprout's passport, page \(number) of \(count), \(name)",
                                comment: "VoiceOver: the passport's open page: its number, the page count, its name")
    }

    /// "Page 3 of 6, Stamps" (read on a turn).
    static func turned(_ number: Int, of count: Int, named name: String) -> LocalizedStringResource {
        LocalizedStringResource("Page \(number) of \(count), \(name)",
                                comment: "VoiceOver: read when a passport page turns: number, count, name")
    }

    /// "Page 3 of 6, Stamps, 14 August to 21 September" (read on a turn to a stamp page).
    static func turned(_ number: Int, of count: Int, named name: String, from first: String,
                       to last: String) -> LocalizedStringResource {
        LocalizedStringResource("Page \(number) of \(count), \(name), \(first) to \(last)",
                                comment: "VoiceOver: read when a passport stamp page turns: number, count, name, first and last stamp dates")
    }

    // MARK: The page bar

    /// "of 6" (the page bar's quiet part).
    static func of(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("of \(count)", comment: "Sprout's passport page bar: of how many pages, after the page number")
    }

    /// "Page 3 of 6, Stamps. Contents" (the page name button).
    static func contentsButton(_ number: Int, of count: Int, named name: String) -> LocalizedStringResource {
        LocalizedStringResource("Page \(number) of \(count), \(name). Contents",
                                comment: "VoiceOver: the passport page bar's name button, which opens the contents")
    }

    /// "Pages" (the page bar's group).
    static let pages = LocalizedStringResource("Pages", comment: "VoiceOver: the passport's page bar")
    /// "Previous page".
    static let previousPage = LocalizedStringResource("Previous page", comment: "Sprout's passport: turns back a page")
    /// "Next page".
    static let nextPage = LocalizedStringResource("Next page", comment: "Sprout's passport: turns on a page")
    /// "Contents".
    static let contents = LocalizedStringResource("Contents", comment: "Sprout's passport: the list of its pages")
    /// "3 to 5 · 14 AUG to 24 OCT" (the stamps' row in the contents).
    static func stampsRange(_ first: Int, _ last: Int, from start: String, to end: String) -> LocalizedStringResource {
        LocalizedStringResource("\(first) to \(last) · \(start) to \(end)",
                                comment: "Sprout's passport contents: the stamp pages' numbers, then their first and last stamp days")
    }

    /// "Newest stamp, page 5" (the ribbon).
    static func newestStamp(page: Int) -> LocalizedStringResource {
        LocalizedStringResource("Newest stamp, page \(page)", comment: "VoiceOver: the passport's ribbon, which turns to the newest stamp")
    }

    /// "Newest stamp" (Voice Control's name for the ribbon).
    static let newestStampShort = LocalizedStringResource("Newest stamp", comment: "Voice Control: the passport's ribbon")

    // MARK: Chips

    /// "New stamp · Sea of Japan".
    static func newStampChip(_ name: String) -> LocalizedStringResource {
        LocalizedStringResource("New stamp · \(name)", comment: "Sprout's passport: the chip when a new stamp lands: its place's name")
    }

    /// "New stamp, Sea of Japan, 24 October 2026" (announced).
    static func newStampAnnouncement(_ name: String, on date: String) -> LocalizedStringResource {
        LocalizedStringResource("New stamp, \(name), \(date)",
                                comment: "VoiceOver: announced when a new stamp lands in the passport: the place, then the date")
    }

    /// "Every stamp found".
    static let everyStamp = LocalizedStringResource("Every stamp found", comment: "Sprout's passport: the chip on a full passport")
}
