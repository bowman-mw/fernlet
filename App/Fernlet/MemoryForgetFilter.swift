import Foundation
import FernletDomainModel

/// The Core memory page's "forget by filters" query (G9-3, owner call M4 = B): words, an optional date
/// range and feeling chips, with no AI anywhere, so it behaves the same on every device and runs in the
/// simulator.
///
/// Every criterion that is set must hold (they narrow each other). An EMPTY filter matches nothing, on
/// purpose: forgetting everything is "Delete all memories", which has its own confirmation. Words match
/// what a row SHOWS (`displayText`, the sentence an emotion-only memory is drawn as) and the stored
/// category token, case- and diacritic-insensitively, as the page's search always has. The date range is
/// by calendar day and inclusive at both ends; either end may be left open. A memory's feeling is its
/// category read as a ``FeelingTag`` (a journal memory keeps its feeling token as its category even
/// after a summary fills its text).
///
/// A pure value: matching never deletes. The page lists the matches as a ticked checklist, and only the
/// "Forget these" tap removes the ticked ones (pinned by `MemoryForgetFilterTests`).
struct MemoryForgetFilter: Equatable {
    /// The words to look for; surrounding whitespace is ignored, and an empty string sets no criterion.
    var words = ""
    /// The first day to include, or nil for no lower bound.
    var from: Date?
    /// The last day to include, or nil for no upper bound.
    var to: Date?
    /// The feelings to include; empty sets no criterion.
    var feelings: Set<FeelingTag> = []

    /// The trimmed words.
    var trimmedWords: String {
        words.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether no criterion is set (and so nothing matches).
    var isEmpty: Bool {
        trimmedWords.isEmpty && from == nil && to == nil && feelings.isEmpty
    }

    /// The memories in `memories` this filter matches, in their order; none for an empty filter.
    func matches(in memories: [MemoryNote], calendar: Calendar = .current) -> [MemoryNote] {
        guard !isEmpty else { return [] }
        return memories.filter { matches($0, calendar: calendar) }
    }

    /// Whether `memory` meets every criterion that is set.
    func matches(_ memory: MemoryNote, calendar: Calendar = .current) -> Bool {
        let needle = trimmedWords
        if !needle.isEmpty {
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            guard memory.displayText.range(of: needle, options: options) != nil
                    || memory.category.range(of: needle, options: options) != nil else { return false }
        }
        let day = calendar.startOfDay(for: memory.sourceDate)
        if let from, day < calendar.startOfDay(for: from) { return false }
        if let to, day > calendar.startOfDay(for: to) { return false }
        if !feelings.isEmpty {
            guard let feeling = FeelingTag(rawValue: memory.category), feelings.contains(feeling) else { return false }
        }
        return true
    }

    /// The feelings at least one of `memories` carries, in the chips' fixed order — the only chips the
    /// page offers, so a chip never leads to an empty list.
    static func feelings(presentIn memories: [MemoryNote]) -> [FeelingTag] {
        let present = Set(memories.compactMap { FeelingTag(rawValue: $0.category) })
        return FeelingTag.allCases.filter { present.contains($0) }
    }
}
