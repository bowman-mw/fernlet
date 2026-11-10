import FernletSocial
import Foundation
import Observation

/// An invite waiting for this person's Join or Not this time (`rt-join`): who sent it and what it says.
nonisolated struct RoadTripPendingInvite: Equatable, Identifiable, Sendable {
    /// The starter's member id (their verified fingerprint, lowercased).
    let from: String
    /// The invite.
    let invite: RoadTripInvitePayload

    /// The trip's id.
    var id: UUID { invite.tripID }
}

/// "Caught up: 84 km of road, 6 photos." (`rt-catchup`): what one catch-up leaves on this iPhone, shown once.
nonisolated struct RoadTripCaughtUpNote: Equatable, Identifiable, Sendable {
    /// Tells two notes apart, so a newer one restarts the note's clock.
    let id: UUID
    /// The trip's road on this iPhone after the swap, in metres.
    let metres: Double
    /// The trip's photos on this iPhone once the swap's photos have landed (PR 3).
    let photos: Int
}

/// Who the catch-up note asks about (`rt-catchup`, owner's pick "ask once when a member is nearby"). Pure.
nonisolated enum RoadTripCatchUpAsk {
    /// A catch-up with a member this recently asks about them no more.
    static let quietAfterCatchUp: TimeInterval = 10 * 60

    /// The first of `members` (the trip's order) heard nearby, not yet asked about while they have been nearby, and
    /// not caught up with in the last ``quietAfterCatchUp``; nil for none.
    static func next(members: [String], nearby: Set<String>, asked: Set<String>, caughtUpAt: [String: Date],
                     now: Date) -> String? {
        members.prefix(RoadTripPayload.maxMembers).first { member in
            guard nearby.contains(member), !asked.contains(member) else { return false }
            guard let last = caughtUpAt[member] else { return true }
            return now.timeIntervalSince(last) >= quietAfterCatchUp
        }
    }
}

/// The road trip's mesh moments as Home and the hangout show them (World-RoadTrip-Spec PR 2, owner-approved
/// 2026-11-10): the invite waiting for an answer, the member the catch-up note asks about, the last catch-up's note,
/// and the short hangout a one-tap catch-up opened. Memory only: nothing here is written, a decoy and every wipe
/// drop it (``forget()``), and the store's own rules (`FernletStore+RoadTripMesh.swift`) decide what goes in.
///
/// - **Ask once** (``refreshQuestion(members:nearby:isFree:now:)``): with Fernlet open and Home in front, a trip
///   member presence hears nearby is asked about once while they stay nearby; one who goes away and comes back may
///   be asked again, and one just caught up with is not (``RoadTripCatchUpAsk``). Never a notification.
/// - **The short hangout** (``beginHandOff(member:now:)``): which member a one-tap catch-up is for, so the store
///   leaves the hangout once the swap with them is done, or once ``handOffSeconds`` pass without one.
/// - **Photos settle first** (PR 3): a swap is done once its photos have landed and gone. After the road comes
///   (``didCatchUp(with:metres:now:photos:leave:)``) the note waits until no piece has landed
///   (``notePhotoActivity()``) and none is going (``beginSending()``, ``endSending()``) for ``settleQuiet``, at most
///   ``settleLongest`` in all, and then says "Caught up: 84 km of road, 6 photos." with the photos counted then; a
///   short hangout is left only after that, so leaving never cuts a photo off.
@MainActor
@Observable
final class RoadTripMeshState {
    /// How long a one-tap catch-up may take, from the tap to the swap, in seconds (the tap hand-off's minute and
    /// the swap's own half minute).
    static let handOffSeconds: TimeInterval = 90
    /// The pause between the swap and leaving the short hangout, so this phone's reply goes out first.
    static let leaveDelay: Duration = .seconds(2)
    /// How long a swap's photos stay quiet (none landing, none going) before the swap counts as done.
    static let settleQuiet: Duration = .seconds(5)
    /// The longest a swap's photos hold the note and a short hangout, from the swap.
    static let settleLongest: Duration = .seconds(120)
    /// The most photo sends counted at once (one per member, well over a trip's).
    static let maxSending = 16

    /// A swap whose photos may still be on their way: what its note will say and whether its short hangout is left
    /// after it.
    private struct Settling {
        /// The trip's road on this iPhone after the swap, in metres.
        var metres: Double
        /// Whether a one-tap catch-up's short hangout is left once it settles.
        var leaves: Bool
        /// When the first of the swaps settling now came.
        let began: ContinuousClock.Instant
        /// The trip's photos on this iPhone, counted when the note shows.
        var photos: () -> Int
        /// Leaves the short hangout.
        var leave: @MainActor () async -> Void
    }

    /// The invite waiting for Join or Not this time.
    private(set) var invite: RoadTripPendingInvite?
    /// The member the catch-up note asks about now.
    private(set) var question: String?
    /// The last catch-up's note, until it has shown.
    private(set) var caughtUp: RoadTripCaughtUpNote?
    /// The trips whose summary card was closed this session although "shown" couldn't be written (PR 4), so Done always
    /// closes it; at most ``RoadTripBook/maxTrips``.
    private(set) var closedSummaries: Set<UUID> = []
    /// The member a one-tap catch-up opened a short hangout with, and until when.
    @ObservationIgnored private(set) var handOff: (member: String, until: Date)?
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private var caughtUpAt: [String: Date] = [:]
    /// Leaves the short hangout after the swap, or when the hand-off runs out (a timer: its handle is kept).
    @ObservationIgnored private var leaveTask: Task<Void, Never>?
    /// The swap whose photos are settling, if any.
    @ObservationIgnored private var settling: Settling?
    /// How many photo sends are going now.
    @ObservationIgnored private var sending = 0
    /// Shows the note once the photos are quiet (a timer: its handle is kept).
    @ObservationIgnored private var settleTask: Task<Void, Never>?

    isolated deinit {
        leaveTask?.cancel()
        settleTask?.cancel()
    }

    /// Whether a swap's photos are still settling (its note not shown yet).
    var isSettling: Bool { settling != nil }

    /// Holds `invite` for an answer (a newer one replaces it).
    func offer(_ invite: RoadTripPendingInvite) {
        self.invite = invite
    }

    /// The waiting invite, taken for its answer.
    func takeInvite() -> RoadTripPendingInvite? {
        defer { invite = nil }
        return invite
    }

    /// Re-decides who the note asks about: `members` are the trip's members to catch up with (none with no trip),
    /// `nearby` the kept friends presence hears now, `isFree` whether Home is in front of an open app with no hangout
    /// or hand-off in the way. A member who went away may be asked again when back.
    func refreshQuestion(members: [String], nearby: Set<String>, isFree: Bool, now: Date = Date()) {
        asked.formIntersection(nearby)
        if let question, !nearby.contains(question) || !members.contains(question) || !isFree { self.question = nil }
        guard question == nil, isFree else { return }
        question = RoadTripCatchUpAsk.next(members: members, nearby: nearby, asked: asked, caughtUpAt: caughtUpAt, now: now)
        if let question { asked.insert(question) }
    }

    /// The note was answered or closed.
    func clearQuestion() {
        question = nil
    }

    /// A one-tap catch-up with `member` began at `now`; `leave` runs if no swap with them comes within
    /// ``handOffSeconds``.
    func beginHandOff(member: String, now: Date = Date(), leave: @escaping @MainActor () async -> Void) {
        handOff = (member, now.addingTimeInterval(Self.handOffSeconds))
        question = nil
        scheduleLeave(after: .seconds(Self.handOffSeconds), leave: leave)
    }

    /// The road of a swap with `member` came at `now`, leaving `metres` of road on this iPhone: noted for the ask, and
    /// the swap settles (its photos landing and going) before the note shows with `photos()` counted then; when a
    /// one-tap catch-up opened the hangout for them, `leave` runs ``leaveDelay`` after that.
    func didCatchUp(with member: String, metres: Double, now: Date = Date(), photos: @escaping () -> Int,
                    leave: @escaping @MainActor () async -> Void) {
        if caughtUpAt.count >= RoadTripPayload.maxMembers * 4 { caughtUpAt.removeAll() }
        caughtUpAt[member] = now
        if question == member { question = nil }
        let leaves = handOff?.member == member
        if leaves {
            handOff = nil
            leaveTask?.cancel()   // the hand-off's own timeout: the settle leaves instead
            leaveTask = nil
        }
        settling = Settling(metres: metres, leaves: leaves || (settling?.leaves ?? false),
                            began: settling?.began ?? ContinuousClock.now, photos: photos, leave: leave)
        scheduleSettle()
    }

    /// A piece of a friend's photo landed: the swap is still under way.
    func notePhotoActivity() {
        guard let settled = settling else { return }
        guard ContinuousClock.now - settled.began < Self.settleLongest else {
            settleNow()
            return
        }
        scheduleSettle()
    }

    /// This iPhone began sending a friend its photos.
    func beginSending() {
        sending = min(sending + 1, Self.maxSending)
    }

    /// A send of this iPhone's photos is over.
    func endSending() {
        sending = max(0, sending - 1)
        if sending == 0, settling != nil { scheduleSettle() }
    }

    /// The settling swap is done: its note shows now, and its short hangout, if one is owed a leave, is left after
    /// ``leaveDelay``.
    func settleNow() {
        guard let settled = settling else { return }
        settling = nil
        settleTask?.cancel()
        settleTask = nil
        caughtUp = RoadTripCaughtUpNote(id: UUID(), metres: settled.metres, photos: settled.photos())
        guard settled.leaves else { return }
        scheduleLeave(after: Self.leaveDelay, leave: settled.leave)
    }

    /// Checks the swap again after ``settleQuiet``, replacing a check already waiting.
    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.settleQuiet)
            } catch {
                return   // cancelled: newer activity, or a forget
            }
            self?.settleIfQuiet()
        }
    }

    /// The quiet check: the swap settles unless photos are still going and it has not waited ``settleLongest``.
    private func settleIfQuiet() {
        guard let settled = settling else { return }
        guard sending > 0, ContinuousClock.now - settled.began < Self.settleLongest else {
            settleNow()
            return
        }
        scheduleSettle()
    }

    /// The note with `id` has shown.
    func clearCaughtUp(_ id: UUID) {
        if caughtUp?.id == id { caughtUp = nil }
    }

    /// The summary card of trip `id` was closed though "shown" wasn't written: it stays closed this session.
    func closeSummary(_ id: UUID) {
        if closedSummaries.count >= RoadTripBook.maxTrips { closedSummaries.removeAll() }
        closedSummaries.insert(id)
    }

    /// A decoy began or ended, or a wipe: everything here goes.
    func forget() {
        invite = nil
        question = nil
        caughtUp = nil
        handOff = nil
        asked = []
        caughtUpAt = [:]
        leaveTask?.cancel()
        leaveTask = nil
        settling = nil
        sending = 0
        settleTask?.cancel()
        settleTask = nil
        closedSummaries = []
    }

    /// Runs `leave` after `delay`, replacing any leave already waiting.
    private func scheduleLeave(after delay: Duration, leave: @escaping @MainActor () async -> Void) {
        leaveTask?.cancel()
        leaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return   // cancelled: a newer leave, or a forget
            }
            self?.handOff = nil
            await leave()
        }
    }
}
