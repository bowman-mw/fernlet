import Foundation

/// The words on the passport's pages (World-Passport-Spec §5–§8, §10; Spanish drafts in the lane's
/// `r7-explore-ui-es-book.json`, the mockup's own where it has them).
nonisolated enum PassportPageCopy {
    // MARK: Page 2

    /// "Since 14 AUG 2026" (page 2's header, the first stamp's date).
    static func since(_ date: String) -> LocalizedStringResource {
        LocalizedStringResource("Since \(date)", comment: "Sprout's passport page 2: since the first stamp's date")
    }

    /// The approved description on page 2.
    static let description = LocalizedStringResource(
        "Every country, continent and ocean you reach gets a stamp. It only adds up, and it stays on this iPhone.",
        comment: "Sprout's passport page 2: what the passport is")
    /// "of 194 countries" (after the big number).
    static func ofCountries(_ total: Int) -> LocalizedStringResource {
        LocalizedStringResource("of \(total) countries", comment: "Sprout's passport: after the countries found, out of how many")
    }

    /// "of 7 continents".
    static func ofContinents(_ total: Int) -> LocalizedStringResource {
        LocalizedStringResource("of \(total) continents", comment: "Sprout's passport: after the continents found, out of how many")
    }

    /// "of 5 oceans".
    static func ofOceans(_ total: Int) -> LocalizedStringResource {
        LocalizedStringResource("of \(total) oceans", comment: "Sprout's passport: after the oceans found, out of how many")
    }

    /// "seas, each its own stamp" ("sea, …" for one).
    static func seas(_ count: Int) -> LocalizedStringResource {
        count == 1 ? LocalizedStringResource("sea, each its own stamp", comment: "Sprout's passport: after one sea found")
            : LocalizedStringResource("seas, each its own stamp", comment: "Sprout's passport: after the seas found (not one)")
    }

    /// "Two to aim for".
    static let twoToAimFor = LocalizedStringResource("Two to aim for", comment: "Sprout's passport page 2: the two special stamps")
    /// "3 to go".
    static func toGo(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("\(count) to go", comment: "Sprout's passport page 2: how many more for a special stamp")
    }

    // MARK: Stamp pages

    /// "The next stamp lands here".
    static let nextStamp = LocalizedStringResource("The next stamp lands here",
                                                   comment: "Sprout's passport: the dotted spot where the next stamp lands")
    /// "No stamps yet".
    static let noStamps = LocalizedStringResource("No stamps yet", comment: "Sprout's passport: a fresh passport's stamp page")
    /// Where stamps come from (a fresh passport).
    static let freshWhere = LocalizedStringResource(
        "When you reach a new country, continent, ocean or sea, its stamp lands here with the date, in the order you visit. Your own country is usually the first.",
        comment: "Sprout's passport: a fresh passport, where stamps come from")
    /// That stamps need location (a fresh passport).
    static let freshLocation = LocalizedStringResource(
        "Stamps come from where you go, so they need location. While Using is enough.",
        comment: "Sprout's passport: a fresh passport, stamps need location access While Using")

    // MARK: The index

    /// "6 of 194 countries" (the index's header; the continent's).
    static func countries(_ count: Int, of total: Int) -> LocalizedStringResource {
        LocalizedStringResource("\(count) of \(total) countries", comment: "Sprout's passport index: countries found out of how many")
    }

    /// "3 of 23" (a row's count).
    static func count(_ count: Int, of total: Int) -> LocalizedStringResource {
        LocalizedStringResource("\(count) of \(total)", comment: "Sprout's passport index: a row's count, found out of how many")
    }

    /// "None yet".
    static let noneYet = LocalizedStringResource("None yet", comment: "Sprout's passport index: a continent with no countries found")
    /// Antarctica's rule.
    static let antarcticaRule = LocalizedStringResource("The continent itself, south of 60°S",
                                                        comment: "Sprout's passport index: what counts as Antarctica")
    /// "Oceans".
    static let oceans = LocalizedStringResource("Oceans", comment: "Sprout's passport index: the oceans row")
    /// "Seas".
    static let seasRow = LocalizedStringResource("Seas", comment: "Sprout's passport index: the seas row")
    /// "Turns to its page." (a name's hint).
    static let turnsToPage = LocalizedStringResource("Turns to its page.", comment: "VoiceOver hint: a passport index name turns to its stamp's page")
    /// "Opens its countries A to Z." (a continent row's hint).
    static let opensAToZ = LocalizedStringResource("Opens its countries A to Z.",
                                                   comment: "VoiceOver hint: a passport index row opens the continent's countries")
    /// "Canada, page 3" (a name in the index).
    static func onPages(_ name: String, pages: String) -> LocalizedStringResource {
        LocalizedStringResource("\(name), page \(pages)", comment: "VoiceOver: a place in the passport index and the pages its stamps are on")
    }

    // MARK: A to Z

    /// "A to Z".
    static let aToZ = LocalizedStringResource("A to Z", comment: "Sprout's passport: a continent's countries in alphabetical order")
    /// "2 trips".
    static func trips(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("\(count) trips", comment: "Sprout's passport: how many trips to a country (always more than one)")
    }

    /// "Canada, stamp" (an earned space) and "Canada, stamp, 2 trips".
    static func earnedCell(_ name: String, trips: Int) -> LocalizedStringResource {
        trips > 1 ? LocalizedStringResource("\(name), stamp, \(trips) trips",
                                            comment: "VoiceOver: an earned country in the A to Z view, with its trips")
            : LocalizedStringResource("\(name), stamp", comment: "VoiceOver: an earned country in the A to Z view")
    }

    /// "Back to the index" and Voice Control's "Index".
    static let backToIndex = LocalizedStringResource("Back to the index", comment: "VoiceOver: leaves a continent's A to Z view")
    /// "Previous continent".
    static let previousContinent = LocalizedStringResource("Previous continent",
                                                           comment: "Sprout's passport: steps to the previous continent's A to Z")
    /// "Next continent".
    static let nextContinent = LocalizedStringResource("Next continent", comment: "Sprout's passport: steps to the next continent's A to Z")
    /// "Continents" (the continent bar's group).
    static let continents = LocalizedStringResource("Continents", comment: "VoiceOver: the passport's continent bar")
    /// "· 1 of 7" (the continent bar's quiet part).
    static func continentStep(_ number: Int, of count: Int) -> LocalizedStringResource {
        LocalizedStringResource("· \(number) of \(count)", comment: "Sprout's passport: which continent of the seven, in the continent bar")
    }

    // MARK: The stamp book's row

    /// "Sprout's passport".
    static let stampBookRow = LocalizedStringResource("Sprout's passport", comment: "Stamp book: the row that opens Sprout's passport")
    /// "6 countries" ("1 country").
    static func countriesFound(_ count: Int) -> LocalizedStringResource {
        count == 1 ? LocalizedStringResource("1 country", comment: "Stamp book: Sprout's passport row, one country found")
            : LocalizedStringResource("\(count) countries", comment: "Stamp book: Sprout's passport row, countries found (not one)")
    }
}
