// SessionMessageUnreadTests.swift
// FernletTests
//
// TF b19 item 6 — the memory-only unread signal added to SessionMessageStore so an arriving session
// message can raise a badge/haptic/notification instead of being silent. Covers: an inbound message
// increments unread while the panel is closed; no increment while viewing; beginViewing clears the
// standing count and suppresses; endViewing resumes counting; markAllRead clears; a local echo of an
// OUTGOING message never counts as unread; and clear() (session end / formation) resets the badge.
// Pure store-level tests — no radios, no live session.

@testable import ProximityKit
import Foundation
import Testing

@MainActor
struct SessionMessageUnreadTests {

    private let day = Date(timeIntervalSince1970: 1_780_000_000)

    @Test func inboundMessageIncrementsUnreadWhileClosed() {
        let s = SessionMessageStore()
        #expect(s.unreadCount == 0)
        #expect(!s.hasUnread)

        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "fp", senderDisplayName: "Robin",
                                  text: "hi", sentAt: day, now: day))
        #expect(s.unreadCount == 1)
        #expect(s.hasUnread)

        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "fp", senderDisplayName: "Robin",
                                  text: "again", sentAt: day, now: day.addingTimeInterval(1)))
        #expect(s.unreadCount == 2)
    }

    @Test func noIncrementWhileViewing() {
        let s = SessionMessageStore()
        s.beginViewing()
        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "fp", senderDisplayName: "Robin",
                                  text: "seen live", sentAt: day, now: day))
        #expect(s.unreadCount == 0, "A message that arrives while the panel is open is read live, never unread")
        #expect(!s.hasUnread)
        // The message itself is still in the transcript — only the badge is suppressed.
        #expect(s.messages.count == 1)
    }

    @Test func beginViewingClearsStandingUnreadThenSuppresses() {
        let s = SessionMessageStore()
        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "fp", senderDisplayName: "Robin",
                                  text: "one", sentAt: day, now: day))
        #expect(s.unreadCount == 1)

        s.beginViewing()   // opening the panel clears the badge...
        #expect(s.unreadCount == 0)

        // ...and keeps it at zero for messages that arrive while it stays open.
        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "fp", senderDisplayName: "Robin",
                                  text: "two", sentAt: day, now: day.addingTimeInterval(1)))
        #expect(s.unreadCount == 0)
    }

    @Test func endViewingResumesCounting() {
        let s = SessionMessageStore()
        s.beginViewing()
        s.endViewing()   // panel dismissed
        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "fp", senderDisplayName: "Robin",
                                  text: "after close", sentAt: day, now: day))
        #expect(s.unreadCount == 1, "Once the panel closes, later inbound messages are unread again")
    }

    @Test func markAllReadClearsTheBadge() {
        let s = SessionMessageStore()
        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "fp", senderDisplayName: "Robin",
                                  text: "one", sentAt: day, now: day))
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
        #expect(!s.receiveIncoming(id: UUID(), senderFingerprint: "fp", senderDisplayName: "Robin",
                                   text: "\u{200B}\n ", sentAt: day, now: day))
        #expect(s.unreadCount == 0)
    }

    @Test func clearResetsUnread() {
        let s = SessionMessageStore()
        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "fp", senderDisplayName: "Robin",
                                  text: "one", sentAt: day, now: day))
        #expect(s.hasUnread)
        s.clear()   // session end / new-session formation
        #expect(s.unreadCount == 0)
        #expect(!s.hasUnread)
        #expect(s.messages.isEmpty)
    }
}
