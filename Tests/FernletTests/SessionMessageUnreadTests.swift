// SessionMessageUnreadTests.swift
// FernletTests
//
// TF b19 item 6 — the memory-only unread signal added to SessionMessageStore so an arriving session
// message can raise a badge/haptic/notification instead of being silent. Covers: an inbound message
// increments unread while the panel is closed; no increment while viewing; beginViewing clears the
// standing count and suppresses; endViewing resumes counting; markAllRead clears; a local echo of an
// OUTGOING message never counts as unread; a row a GATE is filtering is held but never unread
// (P6 item 4 fix review, P3-8); and clear() (session end / formation) resets the badge.
// Pure store-level tests — no radios, no live session.

@testable import ProximityKit
import Foundation
import Testing

@MainActor
struct SessionMessageUnreadTests {

    private let day = Date(timeIntervalSince1970: 1_780_000_000)

    /// `receiveIncoming` answers a three-way ``SessionMessageStore/Acceptance`` since P6 item 4;
    /// these cells are about the unread BADGE, so they only ever need "did it land".
    private func receive(
        into store: SessionMessageStore,
        id: UUID,
        senderFingerprint: String,
        senderDisplayName: String,
        text: String,
        sentAt: Date,
        seenAt: Date
    ) -> Bool {
        store.receiveIncoming(
            id: id, senderFingerprint: senderFingerprint, senderDisplayName: senderDisplayName,
            text: text, sentAt: sentAt, seenAt: seenAt
        ) == .appended
    }

    @Test func inboundMessageIncrementsUnreadWhileClosed() {
        let s = SessionMessageStore()
        #expect(s.unreadCount == 0)
        #expect(!s.hasUnread)

        #expect(receive(into: s, id: UUID(), senderFingerprint: "fp", senderDisplayName: "Robin",
                                  text: "hi", sentAt: day, seenAt: day))
        #expect(s.unreadCount == 1)
        #expect(s.hasUnread)

        #expect(receive(into: s, id: UUID(), senderFingerprint: "fp", senderDisplayName: "Robin",
                                  text: "again", sentAt: day, seenAt: day.addingTimeInterval(1)))
        #expect(s.unreadCount == 2)
    }

    @Test func noIncrementWhileViewing() {
        let s = SessionMessageStore()
        s.beginViewing()
        #expect(receive(into: s, id: UUID(), senderFingerprint: "fp", senderDisplayName: "Robin",
                                  text: "seen live", sentAt: day, seenAt: day))
        #expect(s.unreadCount == 0, "A message that arrives while the panel is open is read live, never unread")
        #expect(!s.hasUnread)
        // The message itself is still in the transcript — only the badge is suppressed.
        #expect(s.messages.count == 1)
    }

    @Test func beginViewingClearsStandingUnreadThenSuppresses() {
        let s = SessionMessageStore()
        #expect(receive(into: s, id: UUID(), senderFingerprint: "fp", senderDisplayName: "Robin",
                                  text: "one", sentAt: day, seenAt: day))
        #expect(s.unreadCount == 1)

        s.beginViewing()   // opening the panel clears the badge...
        #expect(s.unreadCount == 0)

        // ...and keeps it at zero for messages that arrive while it stays open.
        #expect(receive(into: s, id: UUID(), senderFingerprint: "fp", senderDisplayName: "Robin",
                                  text: "two", sentAt: day, seenAt: day.addingTimeInterval(1)))
        #expect(s.unreadCount == 0)
    }

    @Test func endViewingResumesCounting() {
        let s = SessionMessageStore()
        s.beginViewing()
        s.endViewing()   // panel dismissed
        #expect(receive(into: s, id: UUID(), senderFingerprint: "fp", senderDisplayName: "Robin",
                                  text: "after close", sentAt: day, seenAt: day))
        #expect(s.unreadCount == 1, "Once the panel closes, later inbound messages are unread again")
    }

    @Test func markAllReadClearsTheBadge() {
        let s = SessionMessageStore()
        #expect(receive(into: s, id: UUID(), senderFingerprint: "fp", senderDisplayName: "Robin",
                                  text: "one", sentAt: day, seenAt: day))
        #expect(s.hasUnread)
        s.markAllRead()
        #expect(s.unreadCount == 0)
        #expect(!s.hasUnread)
    }

    @Test func outgoingEchoNeverCountsAsUnread() {
        let s = SessionMessageStore()
        s.appendOutgoing(id: UUID(), senderFingerprint: "me", senderDisplayName: "Me",
                         text: "sent by me", sentAt: day)
        #expect(s.unreadCount == 0, "A local echo of my own message is never unread")
        #expect(s.messages.count == 1)
    }

    @Test func droppedInboundDoesNotIncrementUnread() {
        let s = SessionMessageStore()
        // Empty-after-sanitize is dropped entirely — it must not bump the badge.
        #expect(!receive(into: s, id: UUID(), senderFingerprint: "fp", senderDisplayName: "Robin",
                                   text: "\u{200B}\n ", sentAt: day, seenAt: day))
        #expect(s.unreadCount == 0)
    }

    /// The clause a gate-filtered row is never unread by (P6 item 4 fix review, P3-8): deleting
    /// `messages.contains(where:)` from `receiveIncoming`'s badge line used to redden nothing.
    ///
    /// An unread badge is an invitation to go and read something. A row the age gate or a block is
    /// filtering is not something the user can go and read — it is held, not shown — so counting it
    /// would put a badge on a panel that opens empty and never clears honestly.
    @Test func aGateFilteredRowIsHeldButNeverUnread() {
        let s = SessionMessageStore()
        // The 13+ chat gate shut: `MeshContentGates.folding` filters every row out of the view.
        s.refreshGates(chatAllowed: false, isRefused: { _ in false })

        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "fp", senderDisplayName: "Robin",
                                  text: "held, not shown", sentAt: day, seenAt: day) == .appended,
                "the row enters the HELD union — a gate is a view filter, not a drop")
        #expect(s.messages.isEmpty, "and the view shows nothing")
        #expect(s.unreadCount == 0, """
            so nothing is unread: a badge is an invitation to read, and there is nothing the user \
            could open the panel and see
            """)

        // The same row surfaces — and is still not retroactively unread — when the gate re-opens,
        // because the badge is counted at ingest and the derivation carries no second delivery.
        s.refreshGates(chatAllowed: true, isRefused: { _ in false })
        #expect(s.messages.count == 1, "the row was never destroyed")
        #expect(s.unreadCount == 0)

        // A BLOCKED sender is the other half of the same filter — and it takes two rows to reach,
        // because `MeshContentGates.folding` folds `isRefused` over the senders the ledger ALREADY
        // holds. A sender's very first row is therefore never filtered by the store's own gate;
        // what refuses it is `routedProjectionAuthor`, which applies the block list before the
        // content key is unwrapped. The store's gate is deliberately the SECOND of two ends.
        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "blocked",
                                  senderDisplayName: "Nope", text: "before the block",
                                  sentAt: day, seenAt: day) == .appended)
        s.markAllRead()
        s.refreshGates(chatAllowed: true, isRefused: { $0 == "blocked" })
        #expect(s.messages.map(\.senderFingerprint) == ["fp"],
                "the blocked sender's rows stop rendering, held rather than destroyed")

        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "blocked",
                                  senderDisplayName: "Nope", text: "after the block",
                                  sentAt: day, seenAt: day) == .appended)
        #expect(s.messages.map(\.senderFingerprint) == ["fp"], "the new row does not render either")
        #expect(s.unreadCount == 0, "and it is not unread: there is nothing for the user to go read")
    }

    @Test func clearResetsUnread() {
        let s = SessionMessageStore()
        #expect(receive(into: s, id: UUID(), senderFingerprint: "fp", senderDisplayName: "Robin",
                                  text: "one", sentAt: day, seenAt: day))
        #expect(s.hasUnread)
        s.clear()   // session end / new-session formation
        #expect(s.unreadCount == 0)
        #expect(!s.hasUnread)
        #expect(s.messages.isEmpty)
    }
}
