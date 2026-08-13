import Foundation
import Testing
import FernletFoundation
import FernletDomainModel
@testable import Fernlet

/// Pins the behaviour of the ONE journal-append path.
///
/// `addJournal(text:tag:)`, `addJournal(text:tag:date:)`, and `logQuickMood`'s new-entry branch each
/// used to hand-roll the same seal + append + `previousJournals` + `memories` bookkeeping. They now
/// funnel through a single private core, and the today-vs-past-date difference is left entirely to
/// `DiaryStore.mutateDay` — today mutates the live day and schedules one debounced snapshot save,
/// a past date round-trips that day's repository row through the `SanitizedDay` privacy barrier.
///
/// These tests exist so that consolidation cannot quietly change what any of the three call sites
/// does: in particular that back-dating an entry does NOT touch the today-scoped `previousJournals`
/// strip or mint a memory, and that today's path still does both.
@MainActor
struct JournalAppendPathTests {

    /// Today's append does the full today-scoped bookkeeping: the entry lands on the live day, heads
    /// the `previousJournals` strip, and (being long enough) mints a memory.
    @Test func todayAppendUpdatesDayPreviousJournalsAndMemories() throws {
        let store = makeTestStore()
        store.activateNoLockJournals()

        store.addJournal(text: "A long enough entry to mint a tier-one memory note.", tag: .good)

        #expect(store.day.journals.count == 1)
        #expect(store.day.journals.first?.text == "A long enough entry to mint a tier-one memory note.")
        #expect(store.previousJournals.first?.text == "A long enough entry to mint a tier-one memory note.")
        #expect(store.memories.count == 1)
        #expect(store.memories.first?.category == FeelingTag.good.rawValue)
    }

    /// The two-argument overload is exactly the `date == todayKey` case of the three-argument one, so
    /// both must produce identical state. (It now literally delegates; this pins that it stays true.)
    @Test func todayOverloadMatchesExplicitTodayKey() {
        let implicitStore = makeTestStore()
        implicitStore.activateNoLockJournals()
        implicitStore.addJournal(text: "Same words, two entry points, one code path.", tag: .neutral)

        let explicitStore = makeTestStore()
        explicitStore.activateNoLockJournals()
        explicitStore.addJournal(
            text: "Same words, two entry points, one code path.",
            tag: .neutral,
            date: explicitStore.todayKey
        )

        #expect(implicitStore.day.journals.count == explicitStore.day.journals.count)
        #expect(implicitStore.day.journals.first?.text == explicitStore.day.journals.first?.text)
        #expect(implicitStore.previousJournals.count == explicitStore.previousJournals.count)
        #expect(implicitStore.memories.count == explicitStore.memories.count)
        #expect(implicitStore.memories.first?.text == explicitStore.memories.first?.text)
    }

    /// The load-bearing asymmetry: a back-dated entry is written to that day's row and NOWHERE else.
    /// `previousJournals` is the "recent entries" strip and `memories` feeds the companion — both are
    /// today-scoped, so a past-day write must leave them alone (and must not touch today's day).
    @Test func pastDateAppendSkipsTheTodayScopedBookkeeping() {
        let now = Date()
        let store = makeTestStore(date: now)
        store.activateNoLockJournals()
        let pastKey = FernletDate.dayKey(for: now.addingTimeInterval(-3 * 86_400))
        #expect(pastKey != store.todayKey)

        store.addJournal(text: "A back-dated entry long enough to mint a memory.", tag: .good, date: pastKey)

        #expect(store.day.journals.isEmpty, "a past-day write must not touch today's day")
        #expect(store.previousJournals.isEmpty, "previousJournals is the today-scoped recent strip")
        #expect(store.memories.isEmpty, "back-dating must not mint a memory as if just written")

        // It really was persisted to that day (text sealed out of the synced row, hydrated on read).
        #expect(store.loadDayWithDecryptedJournals(for: pastKey).journals.count == 1)
        #expect(
            store.loadDayWithDecryptedJournals(for: pastKey).journals.first?.text
                == "A back-dated entry long enough to mint a memory."
        )
    }

    /// Short entries mint no memory, on either path — `MemoryNote.fromJournal` rejects anything under
    /// 20 characters. Pinned because the consolidated core now runs that call for every append,
    /// including the quick-mood one that never used to reach it.
    @Test func shortEntryAppendsWithoutMintingAMemory() {
        let store = makeTestStore()
        store.activateNoLockJournals()

        store.addJournal(text: "ok", tag: .neutral)

        #expect(store.day.journals.count == 1)
        #expect(store.previousJournals.count == 1)
        #expect(store.memories.isEmpty)
    }

    /// The quick-mood check-in now shares the same core. It must still produce a tag-only, marked
    /// entry that heads `previousJournals` and mints no memory (empty text can never reach the
    /// 20-character floor), and it must still work with no journal key active.
    @Test func quickMoodGoesThroughTheSharedCoreWithoutMintingAMemory() throws {
        let store = makeTestStore()

        store.logQuickMood(.bright)

        let entry = try #require(store.day.journals.first)
        #expect(store.day.journals.count == 1)
        #expect(entry.text.isEmpty)
        #expect(entry.tag == .bright)
        #expect(entry.isQuickMood)
        #expect(store.previousJournals.first?.id == entry.id)
        #expect(store.memories.isEmpty)
    }
}
