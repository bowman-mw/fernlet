import Testing
import FernletDomainModel
@testable import Fernlet

/// The Stamp book (design `b2-milestones`, draft 2): which medals sit on the shelves, the one dashed
/// "Next" slot, how the shelves break, and the stamp art the book draws.
@MainActor
struct StampBookTests {
    private func rows(_ counts: [MilestoneEventKind: Int], worries: Int = 0) -> [MilestoneRowModel] {
        MilestoneRowModel.rows(counts: counts, worriesLetGo: worries)
    }

    @Test func onlyEarnedKindsGetMedalsThenTheFirstMissingKindIsNext() {
        let slots = StampBookShelfSlot.slots(rows: rows([.journal: 2, .meal: 3, .workout: 1, .water: 1]))
        #expect(slots == [.medal(.journal), .medal(.meal), .medal(.workout), .medal(.water), .next(.breathing)])
    }

    @Test func aGapInTheOrderIsTheNextSlot() {
        let slots = StampBookShelfSlot.slots(rows: rows([.meal: 5], worries: 2))
        #expect(slots == [.medal(.meal), .medal(.worry), .next(.journal)])
    }

    @Test func everyKindKeptLeavesNoNextSlot() {
        let all: [MilestoneEventKind: Int] = [.journal: 1, .meal: 1, .workout: 1, .water: 1, .breathing: 1]
        let slots = StampBookShelfSlot.slots(rows: rows(all, worries: 1))
        #expect(slots.count == 6)
        #expect(!slots.contains { if case .next = $0 { true } else { false } })
    }

    @Test func nothingKeptShowsOnlyTheFirstNextSlot() {
        #expect(StampBookShelfSlot.slots(rows: rows([:])) == [.next(.journal)])
    }

    @Test func theResetMarkerNeverReachesAShelf() {
        let slots = StampBookShelfSlot.slots(rows: rows([.resetBoundary: 4, .journal: 1]))
        #expect(!slots.contains { $0.kind == .resetBoundary })
    }

    @Test func shelvesHoldThreeOrTwoAtAccessibilitySizes() {
        let slots = StampBookShelfSlot.slots(rows: rows([.journal: 2, .meal: 3, .workout: 1, .water: 1]))
        #expect(StampBookShelfSlot.shelves(slots, perShelf: 3).map(\.count) == [3, 2])
        #expect(StampBookShelfSlot.shelves(slots, perShelf: 2).map(\.count) == [2, 2, 1])
        #expect(StampBookShelfSlot.shelves([], perShelf: 3).isEmpty)
        #expect(StampBookShelfSlot.shelves(slots, perShelf: 0).count == slots.count)
    }

    @Test func oneColourArtStaysInkOnADiscAndColouredArtKeepsItsColours() {
        #expect(StampBookArt.discTint(for: WorldStampArt.sprite(for: .showerConcerts)) != nil)
        #expect(StampBookArt.discTint(for: WorldStampArt.sprite(for: .bathtubIndex)) == nil)
        #expect(StampBookArt.discTint(for: StampBookArt.keepsake(for: .breathing).sprite) != nil)
    }

    @Test func everyKindOfCareHasItsOwnMedalArtAndCaption() {
        let kinds = MilestoneEconomy.countedKinds
        let sprites = kinds.map { StampBookArt.keepsake(for: $0).sprite }
        #expect(Set(sprites.map(\.rows)).count == kinds.count)
        #expect(kinds.allSatisfy { !MilestonesCopy.shelfLabel(for: $0).isEmpty && !StampBookCopy.nextLabel(for: $0).isEmpty })
    }

    @Test func aMedalSpeaksItsSentenceAndItsGifts() {
        let row = MilestoneRowModel.rows(counts: [.journal: 2], worriesLetGo: 0, giftCounts: [.journal: 1])[0]
        let spoken = StampBookCopy.medalAccessibility(row)
        #expect(spoken.hasPrefix(row.headline))
        #expect(spoken.count > row.headline.count)
        let plain = MilestoneRowModel.rows(counts: [.journal: 2], worriesLetGo: 0)[0]
        #expect(StampBookCopy.medalAccessibility(plain) == plain.headline)
    }
}
