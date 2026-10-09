// MeshSessionHearts.swift
// FernletSocial/HeartSharing
//
// ProximityKit plan step A0.5.10: the in-session hearts (TF b19 item 5; on the routed store since P6
// item 6), moved from the mesh manager with no byte, golden or audit change: the send to one recipient,
// which mints through the engine's public origination door, its state and failure vocabulary with their
// auto-clear, its in-flight claims and their test seams, the two reachability questions the camera's
// heart button asks (the engine's public addressability query and a seat's capability gate by token),
// and the heart row's ledger judge, a private adapter nested here that the composition
// (`FernletMeshFeatures`) registers under the host's heart row: hearts on and the ledger loaded as its
// readiness, a trusted, unblocked author as its admission, and the heart ledger's commit — the
// closeness feed above the ack's own proof guard — as its judgement.
//
// The engine keeps what it always decided: the ceremony's order (readiness, the ledger-resolved author
// with its removal and block legs, the judge's admission before any byte is read, the blob, its one
// open, the delivery, the judgement), every `mesh.routedHeart.*` line but the send's, every FINAL mark,
// and the stage's evidence, which it mints from the judge's `committed` answer alone. Resetting the
// state and the claims when a session ends is this object's, run by the composition's session observer
// as that moment's last leg.

import Foundation
import Observation
import FernletDomainModel
import FernletFoundation
import ProximityKit

// MARK: - MeshSessionHearts

/// Fernlet's in-session hearts (TF b19 item 5; on the routed store since P6 item 6): the send to one
/// recipient, its state and failure vocabulary, the in-flight claims and, through a private adapter, the
/// heart row's ledger judge.
///
/// Built by the composition (``FernletMeshFeatures``) over its mesh, held weakly, the features' host
/// holder, which answers the hearts opt-in and the trust questions and carries the namespace a sender's
/// name is moderated under, and the token of the host's heart row (FernletSocial's
/// ``FernletRoutedTypes``), which the sender mints under and the composition registers the judge under.
/// The app wires the ledger (``heartLedger``) and the closeness hooks (``onHeartSent``,
/// ``onHeartReceived``), asks the two reachability questions and sends; the judge and the session-end
/// reset are not its API.
///
/// `@MainActor` and `@Observable`, like the mesh manager that held all of this until plan step A0.5.10,
/// with its `@ObservationIgnored` annotations kept: the camera's heart affordance re-renders on
/// ``sessionHeartState`` alone.
@MainActor
@Observable
public final class MeshSessionHearts {

    /// Device-local hearts ledger (received-heart records + the 5-minute per-friend rate limit),
    /// SHARED with the presence path (TF b19 item 5). In-session hearts ride the live mesh channel
    /// instead of the fragile on-demand presence connect, but they record through the SAME ledger so
    /// cooldown + dedup state stay consistent across both transports. Set by the app; `nil` in tests
    /// that don't exercise hearts (send/receive then no-op).
    @ObservationIgnored public var heartLedger: ProximityHeartLedger?
    /// Fired with the friend's fingerprint when an in-session heart is SENT / RECEIVED over the mesh,
    /// so the app feeds the closeness signal — wired to the SAME closeness hooks the presence path
    /// uses, so both transports converge (TF b19 item 5).
    @ObservationIgnored public var onHeartSent: ((String) -> Void)?
    @ObservationIgnored public var onHeartReceived: ((String) -> Void)?
    /// Test seam: fires with the ORIGINATION OUTCOME whenever an in-session heart is minted — the
    /// last statement before the outcome is consumed, so a unit test can assert what the mint said
    /// without reaching into the store (mirrors the chat's `onTextSendForTesting`, and renamed from
    /// `onSessionHeartSendForTesting` so the retired spelling can be pinned at zero: there is no
    /// slot on the routed path, so a seam that fired with a slot id could not be re-aimed in place).
    @ObservationIgnored var onHeartSendForTesting: ((MeshRoutedOriginationOutcome) -> Void)?

    /// Test seam: fires with the ACK whenever a heart's ledger judgement mints evidence (P6 item 6).
    ///
    /// It exists because the exactly-once claim has a trap: `MeshHeartCommit.commit` is a batch
    /// door, the ceremony hands it a one-element batch, and so `MeshHeartCommitOutcome.judgements`
    /// and `MeshRoutedHeartAck.judgementsForGift` coincide at every shipping call site — an
    /// invariant written against the batch counter would be green for an accident of this call site
    /// forever (`MeshRoutedHeartAck` forbids `outcome.judgements == 1` by name for the same reason).
    /// Counting this seam's firings PER GIFT witnesses the per-gift field, and it is a witness the
    /// heart ledger's own id-dedup cannot supply: a ledger asked twice answers "already held" and
    /// looks identical to a ledger asked once.
    @ObservationIgnored var onHeartJudgedForTesting: ((MeshRoutedHeartAck) -> Void)?
    @ObservationIgnored private var sessionHeartStateClearTask: Task<Void, Never>?
    /// Fingerprints with a session heart between the tap and the stage.
    ///
    /// Kept as a **fence** after P6 item 6 made the mint synchronous: the window it closes is empty
    /// today, and it is what keeps it closed if an `await` is ever reintroduced between the cooldown
    /// check and the stage. Deleting a fence whose absence is invisible is the change class this
    /// codebase refuses — and `sessionEndClearsAStrandedInFlightHeartClaim` still holds it to its
    /// lifetime.
    @ObservationIgnored private var sessionHeartSendsInFlight: Set<String> = []
    /// Why an in-session heart was not sent — a **frozen English token**, never copy (P6 item 6).
    ///
    /// The case this replaced, `failed(message: String)`, composed six sentences inside ProximityKit
    /// and handed them to a SwiftUI `Text` in the app: English in every language, and invisible to
    /// both halves of `LocalizationBoundaryTests` — `everyPackageLocalizedStringPassesModuleBundle`
    /// scans `String(localized:)` call sites and `packageDisplayLiteralsPassModuleBundle` scans
    /// display-literal call heads and held `LocalizedStringKey` members, and a bare `String`
    /// associated value matches neither. Exactly the D-13.15 defect, in a seam D-13.15 did not
    /// reach. `App/Fernlet/SessionHeartStatusCopy.swift` is the fork, and its exhaustive
    /// `CaseIterable` sweep makes a new case a build error until it has a sentence.
    ///
    /// `rawValue`s are audit vocabulary (`mesh.routedHeart.sendFailed`), so they are frozen.
    public enum SessionHeartFailure: String, CaseIterable, Equatable, Sendable {
        /// `store.allowNearbyHearts` is off — the send-side half of the opt-out.
        case heartsOff
        /// The heart ledger could not be read, so the cooldown could not be checked. Distinct from
        /// ``cooldown`` on purpose: nothing was sent, and the cooldown sentence would be a lie.
        case ledgerUnavailable
        /// A heart went to this friend inside the last five minutes.
        case cooldown
        /// A heart to this friend is already between the tap and the stage.
        case alreadySending
        /// The derived roster at capture no longer holds this friend — they left, or were removed.
        case recipientLeft
        /// No verified X25519 key for this friend is known to this device yet.
        case notReachableYet
        /// Two verified sources disagree about this friend's key, or the set marked them conflicted.
        case identityUnconfirmed
        /// The body would not frame, the registry named no token, the seal refused, or the mint's
        /// own guard chain refused the shape.
        case couldNotSend
        /// The routed store could not say what it holds: deferred protected data, a refused seal,
        /// or a corrupt index. Reached from `.refused(.storeUnavailable)`, and its sentence says the
        /// storage could not be reached — the two docs were swapped until the item 6 fix review.
        case storageUnreachable
        /// The routed store refused the manifest or a chunk — it is holding all it can. Reached from
        /// `.refused(.storeRefused)`, and its sentence says so.
        case holdingAllItCan
    }

    /// In-session heart send feedback (TF b19 item 5; rewritten for the routed store, P6 item 6).
    ///
    /// The routed mint is fully SYNCHRONOUS, so `.sending` is not reachable on the mesh path any
    /// more and the case is gone with it. The presence fallback has its own state
    /// (`PresenceManager.heartSendState`, a different type on a different object) and keeps its
    /// `.connecting` / `.verifying`, so the app's "a send is in flight" question is now
    /// **presence-only** — which is correct rather than a loss: there is no window on this path for
    /// it to describe.
    ///
    /// Observable so the in-session heart affordance surfaces state instead of failing silently.
    /// Memory-only, auto-clearing back to `.idle`.
    public enum SessionHeartState: Equatable, Sendable {
        case idle
        case sent(recipientName: String)
        case failed(SessionHeartFailure, recipientName: String)
    }
    public private(set) var sessionHeartState: SessionHeartState = .idle

    /// The mesh the sender mints through and the two questions ask. Weak: the composition owns the
    /// mesh, and the mesh retains this object's ledger judge, which holds this object.
    @ObservationIgnored private weak var mesh: MeshNetworkManager?

    /// The host the hearts opt-in, the trust questions and the display name are read from, and the
    /// namespace a sender's display name is re-moderated under and a seat's capabilities are read by.
    @ObservationIgnored private let meshHost: FernletMeshHost

    /// The token of the host's heart row (``FernletRoutedTypes/heart``), which the sender mints under,
    /// behind the mesh's `isRoutedTypeRegistered(_:)`.
    @ObservationIgnored private let heartToken: String

    /// The hearts over `mesh` and `meshHost`, minting under `heartToken`.
    ///
    /// - Parameters:
    ///   - mesh: The composition's mesh, held weakly.
    ///   - meshHost: The features' host holder.
    ///   - heartToken: The token of the host's heart row.
    init(mesh: MeshNetworkManager, meshHost: FernletMeshHost, heartToken: String) {
        self.mesh = mesh
        self.meshHost = meshHost
        self.heartToken = heartToken
    }

    /// Ends the state's clear task if these hearts are released mid-countdown (today they never are:
    /// the composition that owns them lives as long as its host), so its sleep cannot outlive its
    /// owner. `isolated`: the handle is main-actor state. The mesh manager cancelled it in its own
    /// teardown until plan step A0.5.10.
    isolated deinit {
        sessionHeartStateClearTask?.cancel()
    }

    /// The display name a heart is sent under, resolved from the host at each read.
    private var displayName: String { meshHost.host.resolvedProximityDisplayName }

    // MARK: - Sending (TF b19 item 5; on the routed store since P6 item 6)

    /// Whether a heart can ride the MESH to this friend right now — and since P6 item 6 that means
    /// "are they a member this device can address", not "are they linked".
    ///
    /// The live-slot requirement went with the legacy transport. A heart to an admitted member with
    /// no live slot is now sealed, wrapped, staged and custodied until a link forms or the origin
    /// departs and hands custody on, which is the whole point of the routed store.
    ///
    /// **What that costs, named rather than hidden.** Capabilities arrive with a slot (the
    /// composition's capability list, ``FernletMeshCapabilities``, lists `.hearts` only while
    /// `allowNearbyHearts` is on), `MeshSessionRosterEntry` carries none and is memory-only, and item
    /// 1's key advertisement carries a key rather than a capability — so for a member with no live slot
    /// this device knows neither their build nor their opt-out. The heart may therefore be staged for a
    /// peer that will refuse it (hearts off) or never judge it (a build with no heart arm), and the
    /// sender sees "Sent" and spends five minutes of cooldown. The real fix is a capability bit on the
    /// key-advertisement family, which is a wire decision and is P9's / the owner's.
    ///
    /// **It is not the app's whole ordering.** `DisposableCameraView` prefers a live `.hearts` slot
    /// (delivered now, capability known), then the presence path while the friend is presence-
    /// reachable (also delivered now), and only then a routed custodied heart — because a
    /// custodied heart is strictly worse than a delivered one in the one case the presence path was
    /// best at. This answers the third question truthfully; it does not decide the order.
    ///
    /// **The answer is the engine's.** This is the mesh's
    /// ``MeshNetworkManager/isAddressableRoutedRecipient(_:)``, asked verbatim (plan step A0.5.1, S6):
    /// the addressability rule belongs to the routed origination door, and this is the heart's name
    /// for it, so the button's query and the mint cannot disagree. A mesh that is gone (only after the
    /// composition that owns it is) addresses nobody.
    ///
    /// - Parameter fingerprint: The friend.
    /// - Returns: whether a single-recipient heart could address them now.
    public func canSendSessionHeart(toFingerprint fingerprint: String) -> Bool {
        guard let mesh else { return false }
        return mesh.isAddressableRoutedRecipient(fingerprint)
    }

    /// Whether a friend holds a LIVE committed slot advertising the `hearts` capability right now —
    /// the question `canSendSessionHeart(toFingerprint:)` used to answer, kept as its own seam
    /// (P6 item 6).
    ///
    /// It is no longer the send gate: the routed path does not need a link. It is the **ordering**
    /// question the app asks first, because a live `.hearts` slot is the one case where a mesh heart
    /// is both deliverable now and known to be acceptable to the far end's build and opt-out — the
    /// two facts capabilities carry and neither the session roster nor the key advertisement does.
    /// Each of the mesh's seats is asked by the capability's token, under the namespace the features'
    /// host holder read once (plan step A0.5.1, S3); a mesh that is gone seats nobody.
    ///
    /// - Parameter fingerprint: The friend.
    /// - Returns: whether a linked, hearts-capable slot faces them.
    public func hasLiveHeartSlot(forFingerprint fingerprint: String) -> Bool {
        guard let mesh else { return false }
        let capabilities = meshHost.namespace.family.vocabulary.capabilities
        return mesh.slots.contains {
            $0.fingerprint == fingerprint && $0.supports(ProximityCapability.hearts.rawValue, in: capabilities)
        }
    }

    /// Sends one in-session heart over the ROUTED store (P6 item 6, plan §12).
    ///
    /// Every gate the legacy sealed send had is kept, in the same order: the `allowNearbyHearts`
    /// opt-out, the active-record-only check, the shared `heartLedger`'s five-minute per-friend
    /// cooldown, and the fingerprint-keyed in-flight claim. Two things are new and one is gone.
    ///
    /// **New, and a bug fix:** the ledger's loaded-ness is now its own refusal.
    /// `canSendHeart(to:)` is fail-closed and answers false for an UNLOADED ledger as well as for a
    /// live cooldown, and the cooldown sentence is a lie there — nothing was sent.
    /// `DisposableCameraView` already distinguished the two for its accessibility label; the send
    /// did not. Since the item 6 fix review an **absent** ledger is refused the same way, rather
    /// than optional-chained past into a send with no cooldown (P3-5).
    ///
    /// **New:** the delivery is the three lines every routed sender uses — take the host's heart
    /// row's token and ask the mesh whether that row is registered, frame a body, call the mesh's one
    /// origination door — with the audience stated as a single recipient, which is what the heart
    /// row's `.singleRecipient` column means. A mesh that is gone (only after the composition that
    /// owns it is) answers as an unregistered row does.
    ///
    /// **Gone:** the live-slot lookup, and with it `.sending`. The mint is fully synchronous, so
    /// `.sending` was never an observable state on this path; the presence fallback keeps its own.
    ///
    /// One `UUID` is minted and used three times — the routed item id, the body header's id and the
    /// gift id — because for ``ProximityNamespace/RoutedTypes/heart`` those are one value by frozen contract.
    ///
    /// - Parameter friend: The trusted friend's record.
    public func sendSessionHeart(to friend: ProximityTrustedPeerRecord) {
        guard meshHost.host.allowNearbyHearts else { return failSessionHeart(.heartsOff, friend) }
        // Active record only — never send to a blocked or revoked (unfriended) peer. Silent: the
        // affordance is not drawn for such a record at all, so reaching here is a caller bug.
        guard friend.blockedAt == nil, friend.revokedAt == nil else { return }
        // Both ledger gates are fail-CLOSED on a nil ledger since the item 6 fix review (P3-5).
        // `heartLedger?.isLoaded != false` and `?? true` both passed a manager with no ledger wired,
        // so it staged a heart with no cooldown at all — and this function's own doc claims every
        // gate the legacy sealed send had is kept. Production always wires one (`init`), so this is
        // not a live defect; it is the guard that makes the doc true and that fails safely if a
        // future entry point forgets.
        guard let heartLedger, heartLedger.isLoaded else {
            return failSessionHeart(.ledgerUnavailable, friend)
        }
        guard heartLedger.canSendHeart(to: friend.fingerprint) else {
            return failSessionHeart(.cooldown, friend)
        }
        // The in-flight claim, kept as a FENCE. The window it closes is empty while the mint is
        // synchronous — everything from here to the stage is one main-actor turn with no suspension
        // — and it is kept because the absence of a fence is invisible: it is what keeps the window
        // closed if an `await` is ever reintroduced between the cooldown check and the stage.
        guard sessionHeartSendsInFlight.insert(friend.fingerprint).inserted else {
            return failSessionHeart(.alreadySending, friend)
        }
        defer { sessionHeartSendsInFlight.remove(friend.fingerprint) }
        let giftID = UUID()
        let typeToken = heartToken
        guard let mesh, mesh.isRoutedTypeRegistered(typeToken),
              let body = framedSessionHeartBody(giftID: giftID, typeToken: typeToken) else {
            return failSessionHeart(.couldNotSend, friend)
        }
        let outcome = mesh.originateRoutedItem(
            body: body, typeToken: typeToken, itemID: giftID,
            audience: .recipient(friend.fingerprint), now: Date()
        )
        onHeartSendForTesting?(outcome)
        consumeSessionHeart(outcome, friend)
    }

    /// The heart's framed plaintext, or nil when its own encode failed.
    ///
    /// The display name is bounded at the mint as well as on the wire: the heart row's cap is
    /// arithmetic over `MeshRoutedHeartBody.maxSenderNameUTF8ByteCount`, so an unbounded local name
    /// could push the header past its allowance and fail the sender's own row.
    ///
    /// `typeToken` is passed IN rather than spelled here, and it is not a style choice:
    /// `noShippingCodeBranchesOnARoutedTypeToken` forbids the token type's qualified constants
    /// anywhere in this file — **including inside an audit context**, which is where the first draft
    /// of this function put one and where the wall caught it — so the caller's row token (the host's
    /// heart row's, asked of the mesh's registry first) is the only spelling these hearts may hold.
    private func framedSessionHeartBody(giftID: UUID, typeToken: String) -> Data? {
        let header = MeshRoutedHeartHeader(
            id: giftID,
            sentAtDayKey: FernletDate.dayKey(for: Date()),
            senderName: MeshRoutedHeartBody.bounded(senderName: displayName)
        )
        do {
            return try MeshRoutedHeartBody(header: header).encoded()
        } catch {
            FernletAuditLog.log(
                "mesh.routedShare.mintFailed",
                context: ["type": typeToken, "error": String(describing: error)]
            )
            return nil
        }
    }

    /// **Consume-on-stage** (§5d): `.staged` arms the cooldown, feeds closeness and says "Sent".
    ///
    /// The legacy path consumed on the wire write because the wire write was the only durable
    /// moment it had. The routed store's stage is durable-before-acknowledged: a `.staged` outcome
    /// means the sealed item is on disk under a signed manifest and will be pushed, drained or
    /// custody-transferred until it is delivered or expires. That is "sent" in every sense the
    /// cooldown protects — the cooldown exists to stop a second *gift* being minted, and a second
    /// tap inside the window would mint one the recipient's ledger dedups by id. The UI has never
    /// claimed receipt ("Sent … some good vibes") and still does not.
    ///
    /// Two honest costs ride with it:
    ///
    /// 1. **`.staged` is not delivered**, and for a heart the gap is wide: a recipient who never
    ///    foregrounds before the mesh ends never judges it, and it expires at
    ///    `hardDeadline + 20 min` as `custodied(by: self)` (D-4.5). Nothing here lies; nothing here
    ///    tells the sender either, and no delivery surface is built for it.
    /// 2. **A refusal at the recipient does not refund the cooldown.** Hearts-off at the far end
    ///    refuses FINAL, five minutes after this ledger armed. That is already the accepted shape
    ///    for a mid-session opt-out, and a refund would need a wire message the routed path
    ///    deliberately lacks.
    ///
    /// Exhaustive over both `MeshRoutedShareSkip` and `MeshRoutedShareRefusal`, so item 1's next
    /// refusal case is a build error here as well as in the app's copy fork.
    private func consumeSessionHeart(
        _ outcome: MeshRoutedOriginationOutcome, _ friend: ProximityTrustedPeerRecord
    ) {
        switch outcome {
        case .staged:
            heartLedger?.recordHeartSent(to: friend.fingerprint)
            onHeartSent?(friend.fingerprint)
            sessionHeartState = .sent(recipientName: friend.displayName)
            scheduleSessionHeartStateClear()
        case .skipped(.noDestinations):
            failSessionHeart(.recipientLeft, friend)
        case .refused(.destinationNotAddressable):
            failSessionHeart(.notReachableYet, friend)
        case .refused(.keyMismatch):
            failSessionHeart(.identityUnconfirmed, friend)
        case .refused(.sealFailed), .refused(.mintFailed):
            failSessionHeart(.couldNotSend, friend)
        case .refused(.storeRefused):
            failSessionHeart(.holdingAllItCan, friend)
        case .refused(.storeUnavailable):
            failSessionHeart(.storageUnreachable, friend)
        }
    }

    /// Publishes one frozen failure cause and schedules its clear. **No sentence is composed here**
    /// — a `String` written inside the package renders English in every language, which is the live
    /// defect D-13.15 closed for the share refusal and which this seam carried until P6 item 6.
    private func failSessionHeart(
        _ cause: SessionHeartFailure, _ friend: ProximityTrustedPeerRecord
    ) {
        sessionHeartState = .failed(cause, recipientName: friend.displayName)
        FernletAuditLog.log("mesh.routedHeart.sendFailed", context: ["reason": cause.rawValue])
        scheduleSessionHeartStateClear()
    }

    private func scheduleSessionHeartStateClear() {
        sessionHeartStateClearTask?.cancel()
        // host-pin: timer — stored handle, synchronous main-actor body; a task-lifetime pin would cycle (HP2)
        sessionHeartStateClearTask = Task { [weak self] in
            // Cancelled: a newer heart state replaced this one, so leave it alone (R7).
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            self?.sessionHeartState = .idle
        }
    }

    // MARK: - The session's end (called by the composition's session observer)

    /// Drops the in-session heart's feedback and its in-flight claims: the session ended. The
    /// composition's session observer calls it as the ending's last leg, after the shop's window and
    /// the chat transcript's drop, the position the mesh manager ran it at until plan step A0.5.10.
    func resetSessionHeartState() {
        // TF b19 item 5: drop any lingering in-session heart feedback so a "Sent"/failure line
        // can't outlive the session that produced it (there is no "Sending…" state on this path any
        // more — P6 item 6 made the mint synchronous).
        sessionHeartStateClearTask?.cancel()
        sessionHeartStateClearTask = nil
        sessionHeartState = .idle
        // The slots these claims named are gone; a stale claim would refuse the first heart of the
        // NEXT session (the deliver task's own `defer` never runs if its slot died mid-flight).
        sessionHeartSendsInFlight.removeAll()
    }

    // MARK: - Receiving (the heart row's ledger judge)

    /// The heart row's ledger judge, for the composition to register under the host's heart row's
    /// token (plan step A0.5.10, S10). Opaque, so its private type and its engine entry points stay
    /// off this object's API (design rule 6).
    ///
    /// - Returns: A new adapter over these hearts.
    func makeJudge() -> some MeshRoutedLedgerJudge {
        HeartJudge(hearts: self)
    }

    /// The heart row's ledger judge (plan step A0.5.10, S10; the mesh manager's built-in judge since
    /// plan step A0.5.3 before it): the hearts setting and the ledger's load as its readiness, the trust
    /// vault as its admission, and the heart ledger's commit as its judgement, each as the ceremony ran
    /// it. Private and nested (design rule 6), so the engine's entry points stay off the hearts' public
    /// API, and so it reaches the hearts' private host holder.
    ///
    /// Holds its hearts strongly: the mesh retains this adapter through its judge map, and the hearts
    /// hold the mesh weakly, so nothing the mesh retains retains the mesh.
    private final class HeartJudge: MeshRoutedLedgerJudge {

        /// The routed heart body this row decodes to.
        typealias Body = MeshRoutedHeartBody

        /// The hearts whose host, heart ledger and hooks this reads.
        let hearts: MeshSessionHearts

        /// An adapter over `hearts`.
        ///
        /// - Parameter hearts: The hearts that make it.
        init(hearts: MeshSessionHearts) {
            self.hearts = hearts
        }

        /// The heart stage's two legs beyond the engine's predicate: nearby hearts are on, and the
        /// heart ledger has finished loading. Both reversible, so neither is ever a mark.
        var isReadyToJudge: Bool {
            hearts.meshHost.host.allowNearbyHearts && hearts.heartLedger?.isLoaded == true
        }

        /// The trust-vault leg: the heart's sender must be a trusted, unblocked vault friend,
        /// asked with the admission ledger's signing key. FINAL when not, under the frozen reason
        /// `notAFriend` — the ceremony's doc carries the two-session argument.
        ///
        /// - Parameter author: The origin, as the admission ledger resolved it.
        /// - Returns: `admitted`, or the FINAL `notAFriend` refusal.
        func admits(_ author: MeshRoutedAuthor) -> MeshRoutedAdmission {
            guard hearts.meshHost.host.isTrustedUnblockedPeer(
                signingPublicKey: author.signingPublicKey,
                fingerprint: author.fingerprint
            ) else {
                return .refusedForGood(reason: "notAFriend")
            }
            return .admitted
        }

        /// The heart ledger's judgement of one opened gift: the ONE ledger door, the closeness feed
        /// on first acceptance above the ack's own guard, and the per-gift test seam where the ack
        /// is built.
        ///
        /// - Parameters:
        ///   - body: The opened heart body.
        ///   - delivery: The gift's signed facts, the ledger's author and the engine's `seenAt`.
        /// - Returns: `committed` when the ledger judged this gift exactly once and stands behind
        ///   it, `notYet` otherwise.
        func judgeRoutedItem(
            _ body: MeshRoutedHeartBody, delivery: MeshRoutedDelivery
        ) -> MeshRoutedJudgement {
            // Unreachable without a ledger: the engine asked `isReadyToJudge` first, in this ceremony.
            guard let ledger = hearts.heartLedger else { return .notYet }
            let merged = MeshMergedHeart(
                giftID: delivery.itemID,
                senderFingerprint: delivery.author.fingerprint,
                senderDisplayName: ProximityDisplayName.peerDisplayName(
                    body.header.senderName, in: hearts.meshHost.namespace
                ),
                firstSeenAt: delivery.seenAt
            )
            let outcome = MeshHeartCommit.commit([merged], into: ledger)
            // Closeness is fed on FIRST ACCEPTANCE only, never on every ack mint. `commitProof` answers
            // non-nil for an already-stored gift, so a pass that re-reaches this ceremony (the store
            // answered `.unavailable` after the row was written, say) re-mints the ack — and the hook
            // behind this is `closenessLedger.recordHeartReceived`, which is not idempotent.
            //
            // **Above the ack guard, and that is the fix review's P2-1.** `recordReceivedHeart` answers
            // true for an applied-but-UNPERSISTED mutation while `commitProof(for:)` answers nil for
            // exactly that state (`ProximityHeartLedger`'s own docs on both), so a dirty sidecar makes
            // this gift accepted and the ack nil in the same pass. Fed below the guard, the feed is not
            // deferred to the flush — it is lost for good, because the re-judgement that follows finds
            // the gift already stored and puts it in `refusedGiftIDs`, where `receivedGiftIDs.contains`
            // is false forever. The R1 gate still holds: a second judgement of the same gift is a
            // refusal, not a receipt, so this cannot double-feed.
            if outcome.receivedGiftIDs.contains(delivery.itemID) {
                hearts.onHeartReceived?(delivery.author.fingerprint)
            }
            guard let ack = MeshRoutedHeartAck(
                outcome: outcome, giftID: delivery.itemID, ledger: ledger
            ) else {
                return .notYet
            }
            hearts.onHeartJudgedForTesting?(ack)
            return .committed
        }
    }

    // MARK: - Test seams

    /// Takes the in-flight heart claim for one fingerprint and leaves it held, so a cell can assert
    /// the SESSION-END clear rather than a `defer` that has already run (P6 item 6).
    ///
    /// The claim's own window is empty now that the mint is synchronous, which is exactly why the
    /// clear needs its own seam: no production sequence can strand a claim any more, and the
    /// `clearAll` that releases a stranded one would otherwise be untestable. `internal` for
    /// `@testable` unit tests only.
    func claimSessionHeartForTesting(_ fingerprint: String) {
        sessionHeartSendsInFlight.insert(fingerprint)
    }

    /// Whether the in-flight heart claim for one fingerprint is held. `internal` for `@testable`
    /// unit tests only.
    func holdsSessionHeartClaimForTesting(_ fingerprint: String) -> Bool {
        sessionHeartSendsInFlight.contains(fingerprint)
    }
}
