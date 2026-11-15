import Foundation

// AmbientFriendNudges.swift
//
// The pure half of Home's friend nudges (G8, owner's wording 2026-11-15): a gentle "send a heart?"
// card for a friend whose fuzzy vibe was low the last time you met (drafts A, B, C, picked by a stable
// hash so the card never flickers), and, at most once a week, for a friend you met in the last seven
// days (draft D). The card's words never mention anyone's feelings: no wording names the vibe.
//
// CAP-2: Home is not behind the lock, so the inputs are only what Friends already shows unlocked:
// the trust vault's names and last-met dates, and the fuzzy vibe a friend shared in person (the
// friend-state sidecar, never synced, expired after 30 days). `AmbientCardsView` gathers them;
// `AmbientRemindersTests` scans this file.
//
// The caps live in `AmbientReminderSchedule` (shared with the other gentle reminders): the same two a
// day, one friend card a day at most, a friend's low-vibe card once a month, the met-this-week card
// once a week in all, and "Not now" (or a sent heart) puts that friend away for a month.

/// The two friend nudges. The raw values are FROZEN persisted tokens in `AmbientReminderSchedule`.
nonisolated enum AmbientFriendNudgeKind: String, CaseIterable, Sendable {
    /// The friend's vibe was low the last time you met (drafts A, B, C).
    case lowVibe = "friendLowVibe"
    /// You met the friend in the last seven days (draft D).
    case metThisWeek = "friendMetThisWeek"
}

/// Which of the owner's approved wordings a friend card uses.
nonisolated enum AmbientFriendNudgeDraft: String, CaseIterable, Sendable {
    /// "Send {Name} a heart?" / "A little warmth goes a long way."
    case a
    /// "Thinking of {Name}" / "A heart could brighten {Name}'s day."
    case b
    /// "{Companion} has an idea" / "{Companion} thinks {Name} would love a heart today."
    case c
    /// "A heart for {Name}?" / "You and {Name} met this week. Want to send a little warmth?"
    case d

    /// The three low-vibe drafts, in rotation order.
    static let lowVibeRotation: [AmbientFriendNudgeDraft] = [.a, .b, .c]
}

/// One kept friend as the friend nudges see them, gathered on Home from unsealed reads only.
nonisolated struct AmbientFriend: Equatable, Sendable {
    /// The friend's fingerprint (the trust vault's key for them).
    let fingerprint: String
    /// The friend's first name as the app already shows it.
    let firstName: String
    /// Whether the fuzzy vibe they shared at your last meeting (at most 30 days old) was the low one.
    let lastVibeWasLow: Bool
    /// When you last met in person.
    let lastMetAt: Date
    /// Whether a heart can be sent to them right now: hearts and delivery while apart on and healthy,
    /// the friend not blocked or revoked, and no heart cooling down.
    let canReceiveHeart: Bool
}

/// A friend card chosen for Home.
nonisolated struct AmbientFriendNudge: Equatable, Sendable {
    /// Which nudge it is.
    let kind: AmbientFriendNudgeKind
    /// The friend's fingerprint, for the heart and for "Not now".
    let fingerprint: String
    /// The friend's first name, for the card's words.
    let firstName: String
    /// The wording the card uses.
    let draft: AmbientFriendNudgeDraft
}

/// Finds which friends could get a nudge today. Pure: the clock is injected.
nonisolated enum AmbientFriendNudgeFinder {
    /// "Met this week": a meeting within this many days.
    static let metWithinDays = 7

    /// Every friend nudge with something to say today, low-vibe cards first, then met-this-week;
    /// each group most recently met first. Only friends who can receive a heart now; at most one
    /// card per friend (the low-vibe one wins).
    static func candidates(friends: [AmbientFriend], dayKey: String, now: Date) -> [AmbientFriendNudge] {
        let ready = friends.filter(\.canReceiveHeart).sorted { lhs, rhs in
            lhs.lastMetAt != rhs.lastMetAt ? lhs.lastMetAt > rhs.lastMetAt : lhs.fingerprint < rhs.fingerprint
        }
        let low = ready.filter(\.lastVibeWasLow).map { friend in
            AmbientFriendNudge(kind: .lowVibe, fingerprint: friend.fingerprint, firstName: friend.firstName,
                               draft: lowVibeDraft(fingerprint: friend.fingerprint, dayKey: dayKey))
        }
        let weekAgo = now.addingTimeInterval(-Double(metWithinDays) * 86_400)
        let met = ready.filter { !$0.lastVibeWasLow && $0.lastMetAt >= weekAgo && $0.lastMetAt <= now }.map { friend in
            AmbientFriendNudge(kind: .metThisWeek, fingerprint: friend.fingerprint, firstName: friend.firstName, draft: .d)
        }
        let found = low + met
        assert(Set(found.map(\.fingerprint)).count == found.count, "one card per friend")
        return found
    }

    /// The low-vibe draft for a friend on a day: A, B or C by a stable hash of both, so the same card
    /// keeps its words all day and changes from one month's card to the next.
    ///
    /// FNV-1a over the UTF-8 bytes, not `hashValue` (which Swift seeds per launch).
    static func lowVibeDraft(fingerprint: String, dayKey: String) -> AmbientFriendNudgeDraft {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(fingerprint)|\(dayKey)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        let rotation = AmbientFriendNudgeDraft.lowVibeRotation
        return rotation[Int(hash % UInt64(rotation.count))]
    }
}

extension AmbientReminderSchedule {
    /// The met-this-week card shows at most once in this many days, whoever it is for.
    static let friendWeekDays = 7

    /// The token "Not now" (or a sent heart) hides a friend under, for every friend card.
    static func friendHideToken(_ fingerprint: String) -> String { "friend.\(fingerprint)" }

    /// The token a friend card is shown under: its kind and the friend.
    static func friendShownToken(_ nudge: AmbientFriendNudge) -> String { "\(nudge.kind.rawValue).\(nudge.fingerprint)" }

    /// Whether a stored token is a per-friend one (hide or shown), which ``pruneFriendTokens(now:)`` ages out.
    private static func isPerFriendToken(_ token: String) -> Bool {
        let prefixes = ["friend."] + AmbientFriendNudgeKind.allCases.map { "\($0.rawValue)." }
        return prefixes.contains { token.hasPrefix($0) }
    }

    /// Picks today's friend card from `candidates` (in priority order) and records it.
    ///
    /// One friend card a day at most, inside the shared daily limit: a card already shown today stays
    /// (unless put away); otherwise the first candidate whose friend is not put away and whose rest
    /// is over — a low-vibe card once a month per friend, the met-this-week card once a week in all.
    mutating func chooseFriend(from candidates: [AmbientFriendNudge], dayKey: String, now: Date) -> AmbientFriendNudge? {
        assert(!dayKey.isEmpty, "a schedule needs the day it is choosing for")
        roll(to: dayKey)
        pruneFriendTokens(now: now)
        let shownFriendToday = shownToday.contains { token in
            AmbientFriendNudgeKind.allCases.contains { token.hasPrefix("\($0.rawValue).") }
        }
        if shownFriendToday {
            return candidates.first { shownToday.contains(Self.friendShownToken($0)) && !isFriendHidden($0.fingerprint, now: now) }
        }
        guard shownToday.count < Self.dailyLimit else { return nil }
        guard let pick = candidates.first(where: { !isFriendHidden($0.fingerprint, now: now) && isFriendRested($0, now: now) }) else {
            return nil
        }
        let token = Self.friendShownToken(pick)
        shownToday.append(token)
        lastShown[token] = now
        if pick.kind == .metThisWeek { lastShown[pick.kind.rawValue] = now }
        return pick
    }

    /// "Not now" or a sent heart: puts every card for this friend away for a month from `now`.
    mutating func hideFriend(_ fingerprint: String, now: Date) {
        hiddenUntil[Self.friendHideToken(fingerprint)] = now.addingTimeInterval(Double(Self.restDays) * 86_400)
    }

    /// Whether the friend's cards are put away until after `now`.
    func isFriendHidden(_ fingerprint: String, now: Date) -> Bool {
        guard let until = hiddenUntil[Self.friendHideToken(fingerprint)] else { return false }
        return until > now
    }

    /// Whether `nudge` has rested: its friend's low-vibe card a month, the met-this-week card a week.
    func isFriendRested(_ nudge: AmbientFriendNudge, now: Date) -> Bool {
        switch nudge.kind {
        case .lowVibe:
            guard let shown = lastShown[Self.friendShownToken(nudge)] else { return true }
            return now.timeIntervalSince(shown) >= Double(Self.restDays) * 86_400
        case .metThisWeek:
            guard let shown = lastShown[nudge.kind.rawValue] else { return true }
            return now.timeIntervalSince(shown) >= Double(Self.friendWeekDays) * 86_400
        }
    }

    /// Drops per-friend entries whose month is over, so a friend's fingerprint is not kept past the
    /// rest it was recorded for (a removed friend leaves nothing behind for long).
    mutating func pruneFriendTokens(now: Date) {
        let rest = Double(Self.restDays) * 86_400
        hiddenUntil = hiddenUntil.filter { !Self.isPerFriendToken($0.key) || $0.value > now }
        lastShown = lastShown.filter { !Self.isPerFriendToken($0.key) || now.timeIntervalSince($0.value) < rest }
    }
}
