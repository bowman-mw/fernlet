import Testing
import Foundation
import FernletDomainModel
@testable import Fernlet

/// G9-3 forget by filters (owner call M4 = B): words, a date range and feeling chips narrow each other,
/// an empty filter matches nothing, and matching never deletes: only the "Forget these" tap does.
@MainActor
struct MemoryForgetFilterTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    private func day(_ value: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: value, hour: 15)) ?? .distantPast
    }

    private var memories: [MemoryNote] {
        [
            MemoryNote(category: "note", text: "Dinner with my sister", sourceDate: day(3)),
            MemoryNote(category: FeelingTag.hard.rawValue, text: "", sourceDate: day(10)),
            MemoryNote(category: FeelingTag.bright.rawValue, text: "Sister's birthday picnic", sourceDate: day(20)),
            MemoryNote(category: FeelingTag.bright.rawValue, text: "", sourceDate: day(28)),
        ]
    }

    @Test func anEmptyFilterMatchesNothing() {
        #expect(MemoryForgetFilter().isEmpty)
        #expect(MemoryForgetFilter(words: "   ").matches(in: memories, calendar: calendar).isEmpty)
    }

    @Test func wordsMatchTextAndCategoryIgnoringCaseAndAccents() {
        let matches = MemoryForgetFilter(words: "SISTER").matches(in: memories, calendar: calendar)
        #expect(matches.map(\.sourceDate) == [day(3), day(20)])
        let accented = MemoryForgetFilter(words: "Sístér").matches(in: memories, calendar: calendar)
        #expect(accented.count == 2)
        #expect(MemoryForgetFilter(words: "hard").matches(in: memories, calendar: calendar).map(\.sourceDate) == [day(10)])
    }

    @Test func theDateRangeIsInclusiveByDayAndEitherEndMayBeOpen() {
        let both = MemoryForgetFilter(from: day(10), to: day(20)).matches(in: memories, calendar: calendar)
        #expect(both.map(\.sourceDate) == [day(10), day(20)])
        let fromOnly = MemoryForgetFilter(from: day(20)).matches(in: memories, calendar: calendar)
        #expect(fromOnly.map(\.sourceDate) == [day(20), day(28)])
        let toOnly = MemoryForgetFilter(to: day(3)).matches(in: memories, calendar: calendar)
        #expect(toOnly.map(\.sourceDate) == [day(3)])
    }

    @Test func feelingChipsMatchTheFeelingToken() {
        let bright = MemoryForgetFilter(feelings: [.bright]).matches(in: memories, calendar: calendar)
        #expect(bright.map(\.sourceDate) == [day(20), day(28)])
        let two = MemoryForgetFilter(feelings: [.bright, .hard]).matches(in: memories, calendar: calendar)
        #expect(two.count == 3)
    }

    @Test func criteriaNarrowEachOther() {
        let filter = MemoryForgetFilter(words: "sister", from: day(15), feelings: [.bright])
        #expect(filter.matches(in: memories, calendar: calendar).map(\.sourceDate) == [day(20)])
    }

    @Test func onlyFeelingsThatArePresentBecomeChips() {
        #expect(MemoryForgetFilter.feelings(presentIn: memories) == [.bright, .hard])
        #expect(MemoryForgetFilter.feelings(presentIn: []).isEmpty)
    }

    @Test func matchingNeverDeletesOnlyForgetTheseDoes() {
        let store = makeTestStore()
        store.memories = memories
        let matches = MemoryForgetFilter(feelings: [.bright]).matches(in: store.memories, calendar: calendar)
        #expect(matches.count == 2)
        #expect(store.memories.count == 4, "building the preview must not delete anything")

        // The person unticks one of the two and taps "Forget these".
        let ticked = matches.dropFirst().map(\.id)
        #expect(store.forgetMemories(ids: Set(ticked)) == 1)
        #expect(store.memories.count == 3)
        #expect(store.memories.contains { $0.id == matches[0].id })
    }
}
