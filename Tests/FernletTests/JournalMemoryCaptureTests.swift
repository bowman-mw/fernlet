// JournalMemoryCaptureTests.swift
// FernletTests
//
// Pins the owner decision of 2026-09-23 — "a journal entry should be summarized not copied to core
// memory. If ai is turned off, no journal text should be saved to core memory. The 'emotion' can be
// saved to core memory."
//
// Core Memory rides the aggregate blob, which CloudKit mirrors when sync is on and which carries no
// field encryption, so a memory that quoted an entry was the one road journal words still had into
// iCloud. The rules pinned here:
//   * every journal entry mints an EMOTION-ONLY memory first — its `FeelingTag` token, no text;
//   * with AI off, over budget (sleepy/resting — summaries are ambient), unavailable, failed, or
//     filtered, that is the whole memory;
//   * with AI on, an on-device summary may replace the empty text, but only if it passes
//     `JournalMemorySummaryPolicy` — never verbatim, never a prefix, never an excerpt, bounded, and
//     free of diagnostic language;
//   * the persisted blob never carries the entry through `memories`.
//
// The Foundation model never runs in the simulator, so a double stands in for the summarizer. It is
// a FAITHFUL double: it dispatches through the store's real `FernletAIGate` (same quota store, same
// stored intent) at the payload's pinned tier and invocation class, simulating only the device
// capability the simulator lacks — so off / sleepy / resting / incapable are exercised for real.

import Foundation
import Testing
import AIContext
import FernletDomainModel
import FernletPersistence
import CloudKitSync
@testable import Fernlet

/// A faithful ``JournalMemorySummarizing`` double: routes through the store's gate exactly as the
/// production stage does, then answers with a canned reply.
@MainActor
private final class FakeJournalSummarizer: JournalMemorySummarizing {
    /// What the "model" answers once the gate lets the call through; `nil` simulates a failed call.
    var reply: String?
    /// The capability the simulator cannot provide for real.
    var deviceCanRunModel = true
    /// Runs while the "model" is thinking — lets a test change the world mid-flight.
    var onSummarize: (() -> Void)?
    /// Every payload the store handed over.
    private(set) var payloads: [JournalSummaryPayload] = []
    /// What the gate resolved for each call (`nil` = deterministic fallback).
    private(set) var dispatched: [AIDestination?] = []

    init(reply: String?) { self.reply = reply }

    func summarize(_ payload: JournalSummaryPayload, gate: FernletAIGate) async -> String? {
        payloads.append(payload)
        // The store's quota store and stored intent, with the device capability this test pins.
        let device = FernletAIGate(
            router: FernletModelRouter(capabilityProvider: StaticAIDeviceCapabilityProvider(
                AIDeviceCapability(onDeviceFoundationModels: deviceCanRunModel)
            )),
            quotaStore: gate.quotaStore,
            intent: gate.intent
        )
        let destination = device.dispatch(
            tier: JournalSummaryPayload.capabilityTier,
            userInvoked: JournalSummaryPayload.isUserInvoked
        )
        dispatched.append(destination)
        onSummarize?()
        guard destination != nil else { return nil }
        return reply
    }
}

@MainActor
struct JournalMemoryCaptureTests {

    /// A long entry with distinctive phrases, so any copy of it is easy to find. `nonisolated` so it
    /// can be a default argument (those are evaluated outside the suite's main-actor isolation).
    private nonisolated static let entry =
        "Went for a long walk by the river with Sam after work and felt really proud of myself for getting outside."
    /// A reply that summarizes without copying: no five-word run of it appears in ``entry``.
    private nonisolated static let paraphrase = "A proud riverside stroll with Sam once the workday ended."

    private func makeStore(aiOn: Bool, summarizer: FakeJournalSummarizer) -> FernletStore {
        let store = makeTestStore()
        store.activateNoLockJournals()
        store.journalMemorySummarizer = summarizer
        if aiOn { store.settings.aiStatus = .ready }
        return store
    }

    /// Writes an entry today and waits for any summary upgrade to settle.
    private func write(_ text: String = Self.entry, tag: FeelingTag = .bright, to store: FernletStore) async {
        store.addJournal(text: text, tag: tag)
        await store.journalMemorySummaryTask?.value
    }

    /// The single memory the entry left, which must be emotion-only.
    private func expectEmotionOnly(_ store: FernletStore, tag: FeelingTag = .bright) throws {
        #expect(store.memories.count == 1)
        let memory = try #require(store.memories.first)
        #expect(memory.text.isEmpty, "Core Memory must hold no journal text: \(memory.text)")
        #expect(memory.category == tag.rawValue)
        #expect(memory.emotionOnlyFeeling == tag)
    }

    private func recordCalls(_ count: Int, on store: FernletStore) {
        for _ in 0..<count { store.aiCallQuotaStore.recordCall() }
    }

    // MARK: - AI off: the emotion, and nothing is even asked

    @Test func aiOffKeepsOnlyTheEmotionAndNeverBuildsAPayload() async throws {
        let fake = FakeJournalSummarizer(reply: Self.paraphrase)
        let store = makeStore(aiOn: false, summarizer: fake)

        await write(to: store)

        try expectEmotionOnly(store)
        #expect(fake.payloads.isEmpty, "with AI off no payload may be built")
        #expect(store.journalMemorySummaryTask == nil)
        #expect(store.aiCallQuotaStore.currentQuota().count == 0)
    }

    // MARK: - AI on: the summary, never the entry

    @Test func aiOnStoresTheSummaryAndNeverTheEntry() async throws {
        let fake = FakeJournalSummarizer(reply: Self.paraphrase)
        let store = makeStore(aiOn: true, summarizer: fake)

        await write(to: store)

        #expect(store.memories.count == 1)
        let memory = try #require(store.memories.first)
        #expect(memory.text == Self.paraphrase)
        #expect(memory.category == FeelingTag.bright.rawValue, "the summary stays tagged with the emotion")
        #expect(memory.text != Self.entry)
        #expect(!Self.entry.hasPrefix(memory.text))
        #expect(!JournalMemorySummaryPolicy.reproduces(Self.entry, in: memory.text))
        #expect(fake.payloads.map(\.entryText) == [Self.entry])
        #expect(fake.dispatched == [.onDeviceFoundationModels])
        #expect(store.aiCallQuotaStore.currentQuota().count == 1, "exactly one budgeted call")
    }

    // MARK: - AI on but unable to run: the emotion only

    @Test func modelUnavailableKeepsOnlyTheEmotion() async throws {
        let fake = FakeJournalSummarizer(reply: Self.paraphrase)
        fake.deviceCanRunModel = false
        let store = makeStore(aiOn: true, summarizer: fake)

        await write(to: store)

        try expectEmotionOnly(store)
        #expect(fake.dispatched == [nil])
        #expect(store.aiCallQuotaStore.currentQuota().count == 0)
    }

    /// Summaries are AMBIENT memory work, so the sleepy band (≥30 calls) already stops them — the
    /// tail of the budget is kept for what the user taps.
    @Test func sleepyBudgetKeepsOnlyTheEmotionBecauseSummariesAreAmbient() async throws {
        let fake = FakeJournalSummarizer(reply: Self.paraphrase)
        let store = makeStore(aiOn: true, summarizer: fake)
        recordCalls(AICallQuota.sleepyThreshold, on: store)

        await write(to: store)

        try expectEmotionOnly(store)
        #expect(fake.dispatched == [nil])
        #expect(store.aiCallQuotaStore.currentQuota().count == AICallQuota.sleepyThreshold, "no charge on a fallback")
    }

    @Test func exhaustedBudgetKeepsOnlyTheEmotion() async throws {
        let fake = FakeJournalSummarizer(reply: Self.paraphrase)
        let store = makeStore(aiOn: true, summarizer: fake)
        recordCalls(AICallQuota.restingThreshold, on: store)

        await write(to: store)

        try expectEmotionOnly(store)
        #expect(fake.dispatched == [nil])
    }

    @Test func failedCallKeepsOnlyTheEmotion() async throws {
        let fake = FakeJournalSummarizer(reply: nil)
        let store = makeStore(aiOn: true, summarizer: fake)

        await write(to: store)

        try expectEmotionOnly(store)
        #expect(fake.dispatched == [.onDeviceFoundationModels], "the call ran; it just produced nothing")
    }

    // MARK: - AI on, reply rejected by the filter: the emotion only

    @Test func verbatimReplyIsRejected() async throws {
        let store = makeStore(aiOn: true, summarizer: FakeJournalSummarizer(reply: Self.entry))
        await write(to: store)
        try expectEmotionOnly(store)
    }

    /// The exact shape the old `fromJournal` stored — a leading excerpt — and a word-boundary prefix.
    @Test func prefixRepliesAreRejected() async throws {
        for reply in [String(Self.entry.prefix(60)), "Went for a long walk by the river", String(Self.entry.prefix(120))] {
            let store = makeStore(aiOn: true, summarizer: FakeJournalSummarizer(reply: reply))
            await write(to: store)
            try expectEmotionOnly(store)
        }
    }

    @Test func excerptPaddedWithWordsOfItsOwnIsRejected() async throws {
        let store = makeStore(aiOn: true, summarizer: FakeJournalSummarizer(
            reply: "Today: felt really proud of myself, which was nice."
        ))
        await write(to: store)
        try expectEmotionOnly(store)
    }

    @Test func recasedRepunctuatedCopyIsRejected() async throws {
        let store = makeStore(aiOn: true, summarizer: FakeJournalSummarizer(reply: "WENT for a long-walk, by the river!"))
        await write(to: store)
        try expectEmotionOnly(store)
    }

    @Test func diagnosticReplyIsRejected() async throws {
        let store = makeStore(aiOn: true, summarizer: FakeJournalSummarizer(
            reply: "Worried the anxiety crept back in on the way home."
        ))
        await write(to: store)
        try expectEmotionOnly(store)
    }

    @Test func runawayReplyIsRejected() async throws {
        let runaway = String(repeating: "calm evening ", count: 20)
        #expect(runaway.count > JournalMemorySummaryPolicy.maxCharacters)
        let store = makeStore(aiOn: true, summarizer: FakeJournalSummarizer(reply: runaway))
        await write(to: store)
        try expectEmotionOnly(store)
    }

    // MARK: - The world changing mid-flight

    @Test func turningAIOffMidFlightDropsTheSummary() async throws {
        let fake = FakeJournalSummarizer(reply: Self.paraphrase)
        let store = makeStore(aiOn: true, summarizer: fake)
        fake.onSummarize = { [weak store] in store?.settings.aiStatus = .off }

        await write(to: store)

        try expectEmotionOnly(store)
    }

    @Test func wordsTheUserTypedMeanwhileAreNeverOverwritten() async throws {
        let fake = FakeJournalSummarizer(reply: Self.paraphrase)
        let store = makeStore(aiOn: true, summarizer: fake)
        fake.onSummarize = { [weak store] in
            guard let store, let memory = store.memories.first else { return }
            store.updateMemory(memory, category: "note", text: "Walks with Sam matter to me.")
        }

        await write(to: store)

        #expect(store.memories.map(\.text) == ["Walks with Sam matter to me."])
    }

    @Test func aMemoryDeletedMeanwhileIsNotResurrected() async {
        let fake = FakeJournalSummarizer(reply: Self.paraphrase)
        let store = makeStore(aiOn: true, summarizer: fake)
        fake.onSummarize = { [weak store] in
            guard let store, let memory = store.memories.first else { return }
            store.deleteMemory(memory)
        }

        await write(to: store)

        #expect(store.memories.isEmpty)
    }

    /// R3: at most one summary in flight. A newer entry supersedes the older request before it runs,
    /// and the older memory simply keeps its emotion.
    @Test func aNewerEntrySupersedesTheInFlightSummary() async throws {
        let fake = FakeJournalSummarizer(reply: Self.paraphrase)
        let store = makeStore(aiOn: true, summarizer: fake)

        store.addJournal(text: Self.entry, tag: .bright)
        let superseded = store.journalMemorySummaryTask
        store.addJournal(text: "Cooked dinner at home tonight and it turned out lovely.", tag: .good)
        await superseded?.value
        await store.journalMemorySummaryTask?.value

        #expect(store.memories.count == 2)
        #expect(store.memories.first?.text.isEmpty == true)
        #expect(store.memories.first?.category == FeelingTag.bright.rawValue)
        #expect(store.memories.last?.text == Self.paraphrase)
        #expect(fake.payloads.count == 1, "the superseded request never spent a call")
        #expect(store.aiCallQuotaStore.currentQuota().count == 1)
    }

    // MARK: - The persisted blob

    /// Encodes the persisted snapshot and asserts no piece of the entry survives in it — in
    /// `memories`, and anywhere else a copy could hide.
    private func expectNoEntryText(in snapshot: FernletSnapshot) throws {
        let json = try #require(String(data: try JSONEncoder().encode(snapshot), encoding: .utf8))
        for fragment in [Self.entry, "long walk by the river", "really proud of myself", String(Self.entry.prefix(40))] {
            #expect(!json.contains(fragment), "the persisted blob carries journal text: \(fragment)")
        }
        #expect(snapshot.memories.allSatisfy { !JournalMemorySummaryPolicy.reproduces(Self.entry, in: $0.text) })
    }

    @Test func persistedBlobCarriesOnlyTheEmotionWithAIOff() async throws {
        let (store, repository, _) = makeTestStoreWithRepositories()
        store.activateNoLockJournals()

        await write(to: store)
        store.flushPendingSnapshotSave()

        let persisted = repository.loadSnapshot(todayKey: store.todayKey)
        try expectNoEntryText(in: persisted)
        #expect(persisted.memories.count == 1)
        #expect(persisted.memories.first?.text.isEmpty == true)
        #expect(persisted.memories.first?.category == FeelingTag.bright.rawValue)
    }

    @Test func persistedBlobNeverCarriesAVerbatimReply() async throws {
        let (store, repository, _) = makeTestStoreWithRepositories()
        store.activateNoLockJournals()
        store.journalMemorySummarizer = FakeJournalSummarizer(reply: Self.entry)
        store.settings.aiStatus = .ready

        await write(to: store)
        store.flushPendingSnapshotSave()

        let persisted = repository.loadSnapshot(todayKey: store.todayKey)
        try expectNoEntryText(in: persisted)
        #expect(persisted.memories.first?.text.isEmpty == true)
    }

    @Test func persistedBlobCarriesTheSummaryNotTheEntry() async throws {
        let (store, repository, _) = makeTestStoreWithRepositories()
        store.activateNoLockJournals()
        store.journalMemorySummarizer = FakeJournalSummarizer(reply: Self.paraphrase)
        store.settings.aiStatus = .ready

        await write(to: store)
        store.flushPendingSnapshotSave()

        let persisted = repository.loadSnapshot(todayKey: store.todayKey)
        try expectNoEntryText(in: persisted)
        #expect(persisted.memories.map(\.text) == [Self.paraphrase])
    }

    // MARK: - The payload contract (spec §7: typed per request, tested against forbidden fields)

    @Test func journalSummaryPayloadCarriesTheEntryAndNothingElse() {
        let payload = JournalSummaryPayload(entryText: "  \(Self.entry)\n")
        #expect(payload.payloadKind == "journal-memory-summary")
        #expect(payload.includedFieldNames == ["entryText"])
        let fields = Mirror(reflecting: payload).children.compactMap(\.label)
        #expect(Set(fields) == ["payloadKind", "entryText"])
        for forbidden in ["periodData", "tierTwoMemories", "narrative", "symptoms", "healthMetrics",
                          "memories", "journalTagLabel", "filteredMemorySummary", "cycle"] {
            #expect(!fields.contains(forbidden))
        }
        #expect(payload.entryText == Self.entry)
    }

    @Test func journalSummaryIsPinnedOnDeviceAndAmbient() {
        #expect(JournalSummaryPayload.capabilityTier == .light)
        #expect(!JournalSummaryPayload.capabilityTier.allowsOffDeviceEscalation)
        #expect(JournalSummaryPayload.capabilityTier.escalationLadder.allSatisfy { !$0.leavesDevice })
        #expect(JournalSummaryPayload.isUserInvoked == false)
    }

    /// Fail-closed by absence: the summary prompt receives zero Tier-2 behavioral context.
    @Test func journalSummaryPayloadGetsNoTierTwoContext() {
        let kind = JournalSummaryPayload(entryText: Self.entry).payloadKind
        #expect(!MemoryAgent.allowedPayloadKinds.contains(kind))
        let record = TierTwoMemoryRecord(category: "movement", text: "Tends to walk daily", evidence: "", confidence: "high")
        #expect(MemoryAgent.filteredContext(from: [record], destinedFor: kind).isEmpty)
    }

    @Test func journalSummaryPayloadCapsTheEntryForTheContextWindow() {
        let long = String(repeating: "word ", count: 1_000)
        #expect(JournalSummaryPayload(entryText: long).entryText.count == JournalSummaryPayload.maxEntryCharacters)
    }

    // MARK: - The acceptance policy, directly

    @Test func policyAcceptsAParaphraseOnOneLineWithoutWrappingQuotes() {
        #expect(JournalMemorySummaryPolicy.accepted(Self.paraphrase, entryText: Self.entry) == Self.paraphrase)
        #expect(JournalMemorySummaryPolicy.accepted(
            "  \u{201C}A calm\nevening at home.\u{201D}  ", entryText: Self.entry
        ) == "A calm evening at home.")
    }

    @Test func policyRejectsEmptyAndWordlessReplies() {
        #expect(JournalMemorySummaryPolicy.accepted("", entryText: Self.entry) == nil)
        #expect(JournalMemorySummaryPolicy.accepted("   \n ", entryText: Self.entry) == nil)
        #expect(JournalMemorySummaryPolicy.accepted("…!?", entryText: Self.entry) == nil)
    }

    /// Copy detection works on whole words: a shared word is not a copy, a shared RUN of words is.
    @Test func copyDetectionRespectsWordBoundaries() {
        #expect(!JournalMemorySummaryPolicy.reproduces("I started my class today", in: "Art"))
        #expect(JournalMemorySummaryPolicy.reproduces("I started my art class today", in: "art class"))
        #expect(JournalMemorySummaryPolicy.reproduces("Café by the water with Mia", in: "cafe BY the water"))
        #expect(!JournalMemorySummaryPolicy.reproduces(Self.entry, in: Self.paraphrase))
    }

    // MARK: - The Core memory page's display text (built at render time)

    @Test func anEmotionOnlyMemoryReadsAsItsFeelingsSentence() {
        let memory = MemoryNote(category: FeelingTag.bright.rawValue, text: "")
        #expect(memory.displayText == FeelingTag.bright.memorySentence)
        #expect(!memory.displayText.isEmpty)
        #expect(memory.displayText != memory.category, "the token is never what a person reads")
    }

    @Test func aMemoryWithTextReadsAsItsText() {
        let memory = MemoryNote(category: FeelingTag.bright.rawValue, text: Self.paraphrase)
        #expect(memory.displayText == Self.paraphrase)
        #expect(memory.emotionOnlyFeeling == nil)
    }

    @Test func aTextlessMemoryWithAnUnknownCategoryStillReadsAsASentence() {
        let memory = MemoryNote(category: "telepathy", text: "")
        #expect(memory.emotionOnlyFeeling == nil)
        #expect(!memory.displayText.isEmpty)
        #expect(memory.displayText != "telepathy")
    }

    @Test func everyFeelingHasItsOwnSentence() {
        let sentences = FeelingTag.allCases.map(\.memorySentence)
        #expect(sentences.allSatisfy { !$0.isEmpty })
        #expect(Set(sentences).count == FeelingTag.allCases.count)
    }

    /// The AI activity log names the new call in plain language rather than as a raw token.
    @Test func theAuditLogNamesTheJournalSummaryCall() throws {
        let entry = AIAuditEntry(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            payloadKind: JournalSummaryPayload(entryText: "x").payloadKind,
            destination: .onDeviceFoundationModels,
            includedFields: ["entryText"]
        )
        let row = try #require(AIAuditRow.rows(from: [entry]).first)
        #expect(!row.kind.isRecordedToken)
        #expect(row.boundary == .stayedOnDevice)
    }
}
