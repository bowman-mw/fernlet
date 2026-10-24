import Foundation

/// Who one nearby phone is to this person, as the Friends nearby page draws it (World Review Batch 4,
/// `b4-mem-blue-friend`, `b4-mem-blue-join`, `b4-mem-blue-new`, approved 2026-10-24): a kept friend
/// ("Start a session with Sam"), someone in an open hangout ("Join Sam's hangout"), or someone with
/// Fernlet who isn't a friend yet ("Make a friend").
///
/// Read only from what the discovery radio already exposes while the page is on screen (the slot's
/// handshake identity and the hangout name an OPEN mesh advertises, `MeshNetworkManager
/// .currentDiscoveryInfo()`); a closed hangout advertises nothing, so it reads as the person alone.
/// Nothing new is sent or listened for.
nonisolated enum FriendsNearbyKind: Equatable, Sendable {
    /// The phones haven't exchanged who they are yet: "Someone nearby".
    case unknown
    /// A kept friend, by first name.
    case friend(name: String)
    /// Someone in an open hangout: the friend's first name (nil for someone who isn't a friend), the
    /// hangout's name and how many others are in it.
    case hangout(friend: String?, hangoutName: String, others: Int)
    /// Someone with Fernlet who isn't a friend yet.
    case newPerson

    /// The kind for one nearby phone.
    ///
    /// - Parameters:
    ///   - friendName: The first name of a kept (not blocked, not removed) friend, or nil.
    ///   - identified: Whether the phones have exchanged who they are.
    ///   - discoveryInfo: What the peer's radio advertises; an open hangout carries `meshName` and
    ///     `memberCount`.
    /// - Returns: The kind.
    static func classify(friendName: String?, identified: Bool, discoveryInfo: [String: String]?) -> FriendsNearbyKind {
        let hangout = discoveryInfo?["meshName"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !hangout.isEmpty {
            let members = Int(discoveryInfo?["memberCount"] ?? "") ?? 1
            return .hangout(friend: friendName, hangoutName: String(hangout.prefix(40)), others: max(0, members - 1))
        }
        if let friendName { return .friend(name: friendName) }
        return identified ? .newPerson : .unknown
    }
}

/// The Friends nearby page's words for each ``FriendsNearbyKind``, in the person's language: the
/// approved blue-button cards' copy (`b4-mem-blue-*`).
nonisolated enum FriendsNearbyCopy {
    /// The card's heading: "Sam is nearby", or "Someone with Fernlet is nearby".
    static func heading(_ kind: FriendsNearbyKind, someoneNearby: String) -> String {
        switch kind {
        case .unknown:
            return someoneNearby
        case .friend(let name), .hangout(.some(let name), _, _):
            return isNearby(name)
        case .hangout(.none, _, _), .newPerson:
            return String(localized: "friendsNearby.heading.someone", defaultValue: "Someone with Fernlet is nearby",
                          comment: "Friends nearby: a card heading for a nearby person with Fernlet who isn't a friend yet")
        }
    }

    /// "Sam is nearby".
    static func isNearby(_ name: String) -> String {
        String(localized: "friendsNearby.heading.friend", defaultValue: "\(name) is nearby",
               comment: "Friends nearby and the blue button: a card heading for a friend nearby; their first name")
    }

    /// The line under the heading, if any.
    static func note(_ kind: FriendsNearbyKind) -> String? {
        switch kind {
        case .unknown, .friend:
            return nil
        case .newPerson:
            return String(localized: "friendsNearby.note.new", defaultValue: "Not a friend yet. Nothing is shared until you both say yes.",
                          comment: "Friends nearby: under the heading for someone with Fernlet who isn't a friend yet")
        case .hangout(let friend, _, let others):
            return hangoutNote(friend: friend, others: others)
        }
    }

    /// "Sam is in a hangout with 1 other person." Who's in it stays private: a count, never names.
    private static func hangoutNote(friend: String?, others: Int) -> String {
        let who = friend ?? String(localized: "friendsNearby.note.they", defaultValue: "They",
                                   comment: "Friends nearby: the subject of 'They're in a hangout' for someone who isn't a friend")
        guard others > 0 else {
            return String(localized: "friendsNearby.note.hangoutAlone", defaultValue: "\(who) is in a hangout.",
                          comment: "Friends nearby: a nearby person is in a hangout of their own; their first name, or 'They'")
        }
        return String(localized: "friendsNearby.note.hangout", defaultValue: "\(who) is in a hangout with \(others) other people.",
                      comment: "Friends nearby: a nearby person is in a hangout; their first name (or 'They'), then how many others are in it. Plural on the number (1: 'with 1 other person')")
    }

    /// The choice's name: "Start a session with Sam", "Join Sam's hangout", "Make a friend".
    static func title(_ kind: FriendsNearbyKind, someoneNearby: String) -> String {
        switch kind {
        case .unknown:
            return someoneNearby
        case .friend(let name):
            return startSession(with: name)
        case .hangout(.some(let name), _, _):
            return String(localized: "friendsNearby.join.friend", defaultValue: "Join \(name)'s hangout",
                          comment: "Friends nearby: asks to join a nearby friend's hangout; their first name")
        case .hangout(.none, _, _):
            return String(localized: "friendsNearby.join.someone", defaultValue: "Join this hangout",
                          comment: "Friends nearby: asks to join the hangout of someone nearby who isn't a friend")
        case .newPerson:
            return String(localized: "friendsNearby.makeFriend", defaultValue: "Make a friend",
                          comment: "Friends nearby: starts the in-person code exchange with someone who isn't a friend yet")
        }
    }

    /// "Start a session with Sam".
    static func startSession(with name: String) -> String {
        String(localized: "friendsNearby.startSession", defaultValue: "Start a session with \(name)",
               comment: "Friends nearby and the blue button: start a friend session with a friend nearby; their first name")
    }

    /// The choice's line: what it is, as the approved cards say it.
    static func detail(_ kind: FriendsNearbyKind) -> String? {
        switch kind {
        case .unknown:
            return nil
        case .friend:
            return sessionDetail
        case .hangout(let friend, let hangoutName, _):
            guard let friend else {
                return String(localized: "friendsNearby.join.someone.detail", defaultValue: "\(hangoutName) · they say yes before you're in",
                              comment: "Friends nearby: under 'Join this hangout'; the hangout's name")
            }
            return String(localized: "friendsNearby.join.friend.detail", defaultValue: "\(hangoutName) · \(friend) says yes before you're in",
                          comment: "Friends nearby: under 'Join Sam's hangout'; the hangout's name, then the friend's first name")
        case .newPerson:
            return String(localized: "friendsNearby.makeFriend.detail", defaultValue: "Show each other a code, in person",
                          comment: "Friends nearby: under 'Make a friend'")
        }
    }

    /// "Photos, messages and walks together, while you're in person".
    static var sessionDetail: String {
        String(localized: "friendsNearby.startSession.detail", defaultValue: "Photos, messages and walks together, while you're in person",
               comment: "Friends nearby and the blue button: under 'Start a session with Sam'")
    }
}
