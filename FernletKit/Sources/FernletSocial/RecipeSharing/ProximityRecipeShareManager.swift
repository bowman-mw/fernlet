// ProximityRecipeShareManager.swift
// FernletSocial/RecipeSharing
//
// Fernlet's recipe sharing over ProximityKit's one-to-one pair session (ProximityKit plan step A0.7).
// The mechanism (discovery on the recipe radio, the two-device cap, the identity handshake, the
// status line and its clock, the send outcome) is the session's, run under Fernlet's recipe profile,
// FernletConnections' `ProximityPairProfile.recipeShare(in:)`; what is the recipe's is here: the
// payload and its signed summary, the inbound rules, and the English the share sheet shows, rendered
// from the session's typed status and events by the renderer at the foot of this file.

import FernletConnections
import FernletDomainModel
import Foundation
import Observation
import ProximityKit

// Pure diagnostics value type + a stateless ring-buffer helper — explicitly
// `nonisolated` so they are NOT swept into the target's `defaultIsolation(MainActor.self)`.
// They hold no main-actor state, so keeping them nonisolated preserves their off-main
// usability under Swift 6 mode (behaviour-identical to the prior Swift 5 language mode).
// Mirrors WI-9's nonisolated wire types; the @MainActor manager below still uses them freely.
/// One timestamped, identity-free line in a proximity manager's diagnostics ring.
///
/// Shared display shape across the recipe-share and presence managers' diagnostic surfaces;
/// messages never carry fingerprints or keys.
public struct ProximityRecipeShareDiagnosticEvent: Identifiable, Equatable {
    public nonisolated let id: UUID
    public nonisolated let timestamp: Date
    public nonisolated let message: String

    public nonisolated init(id: UUID = UUID(), timestamp: Date = Date(), message: String) {
        self.id = id
        self.timestamp = timestamp
        self.message = message
    }
}

/// Stateless ring-buffer helper for the diagnostics event list: append and trim to the newest
/// `maxEvents`.
///
/// Pure and `nonisolated` so any isolation domain can use it; both the recipe-share and
/// presence managers funnel their `recordDiagnostic` through it.
public enum ProximityRecipeShareDiagnostics {
    public nonisolated static let maxEvents = 40

    public nonisolated static func appending(
        _ event: ProximityRecipeShareDiagnosticEvent,
        to events: [ProximityRecipeShareDiagnosticEvent],
        maxCount: Int = maxEvents
    ) -> [ProximityRecipeShareDiagnosticEvent] {
        guard maxCount > 0 else { return [] }
        return Array((events + [event]).suffix(maxCount))
    }
}

/// Fernlet's recipe sharing over a pair session: sends a recipe to a nearby Fernlet and queues the
/// recipes nearby Fernlets send, for the user to review.
///
/// The mechanism (discovery on the recipe radio, the hard two-device cap, verification, the status
/// line and its 2.5 s clear, and the send outcome) is its session's, a ``ProximityPairSession`` under
/// Fernlet's recipe profile (FernletConnections' `ProximityPairProfile.recipeShare(in:)`, on the host's
/// own namespace). This manager adds what is the recipe's: the payload, its format and the signed
/// summary, the English it shows, and the inbound rules (a 1 MiB size gate before decoding, the format
/// and version check, the 512 KiB image drop, the review clamps, a 3 s per-sender rate limit and an
/// eight-share queue). Lifecycle is owned by the app (ContentView gates on tab/scene/lock).
/// `@MainActor @Observable`.
///
/// Every observable it publishes about a send is its session's, read through: ``nearbyRecipients``,
/// ``sendState`` (the session's typed status, rendered), ``lastShareOutcome`` and
/// ``engagedRecipientID``; so a view observing this manager re-renders on the session's writes. Its
/// own state is the diagnostics list and the inbound queue. Every share the user begins ends in exactly
/// one ``lastShareOutcome``. **Sent is not received**: `sent` means the sealed payload was handed to
/// the transport, and nothing ever comes back from the other device.
///
/// The English the share sheet shows, the ``SendState`` line and each diagnostic, is rendered from the
/// session's typed status and events in one place, the renderer at the foot of this file
/// (`sendState(for:)`, `statusMessage(for:)`, `diagnostic(for:)`), byte for byte the sentences the
/// share sheet and its tests read; the receive handler's four lines are its own.
@MainActor
@Observable
public final class ProximityRecipeShareManager: ProximityPayloadHandling {
    /// The observable send pipeline's STATUS LINE: connecting → sending → sent, or a failure
    /// message; `idle` between sends.
    ///
    /// Display copy, not a record: every terminal state is reset to `.idle` 2.5 s later (the pair
    /// session's clock), and `failed`'s message is an English sentence, rendered from the session's
    /// typed status by `sendState(for:)`. A surface that has to stay up until the user dismisses it,
    /// or has to be translated, reads ``lastShareOutcome`` instead. `sent` carries the same meaning as
    /// `ProximityPairSendOutcome.Result.sent`: handed to the transport, never "delivered".
    public enum SendState: Equatable {
        case idle
        case connecting(recipientName: String)
        case sending(recipientName: String)
        case sent(recipientName: String)
        case failed(message: String)
    }

    /// The picker's rows: the pair session's nearby peers, sorted by name, each re-filed under its
    /// verified fingerprint (and the name it disclosed, if it disclosed one) once its pairing verifies.
    public var nearbyRecipients: [ProximityPairPeer] { pairSession.nearbyPeers }
    /// The status line the share sheet shows: the pair session's typed status rendered (see
    /// ``SendState``).
    public var sendState: SendState { Self.sendState(for: pairSession.status) }
    /// How the most recent share the user began ended — the value the share sheet's confirmation
    /// is built from: the pair session's last send outcome.
    ///
    /// Published exactly once per share, at its terminal moment. Unlike ``sendState`` it is never
    /// auto-cleared, carries a frozen cause instead of English, and gets a fresh
    /// `ProximityPairSendOutcome.id` every time. Cleared at the start of each send and by
    /// ``wipeIdentityForDeleteAll()``. A teardown (`stop()`, a search restart) that ends a share still
    /// in flight publishes `interrupted` or `sendIncomplete` here, so an observer that was NOT waiting
    /// on that share (the sheet that is itself closing) must ignore it.
    public var lastShareOutcome: ProximityPairSendOutcome? { pairSession.lastSendOutcome }
    /// The diagnostics list: the pair session's events, rendered, and the receive handler's own lines,
    /// in the order they happened, capped at ``ProximityRecipeShareDiagnostics/maxEvents``.
    public private(set) var diagnosticEvents: [ProximityRecipeShareDiagnosticEvent] = []
    /// R6: read-only outside this file — the cap (`maxPendingShares`) and the dedup live in this
    /// file's writers, and the two `dismissRecipeShare` methods cover the external mutation need.
    public private(set) var pendingRecipeShares: [PendingProximityRecipeShare] = []
    /// The recipient the pair session is currently engaged with — connecting to, sending to, or
    /// holding the (hard-capped, one-at-a-time) verified connection with. The share sheet disables
    /// every other recipient row while this is set; nil when idle.
    public var engagedRecipientID: UUID? { pairSession.engagedPeerID }
    /// Whether the listener is up right now: the pair session's own account (see
    /// ``ProximityPairSession/isListening``), which the app's run-policy seam reads.
    public var isListening: Bool { pairSession.isListening }

    /// The pair session this manager drives, under Fernlet's recipe profile: built once, at
    /// construction, with this manager as its payload handler and its event sink.
    @ObservationIgnored let pairSession: ProximityPairSession
    /// The host's protocol identity, the pair session's: the receive handler coerces a sender's name
    /// under its peer-name policy. `nonisolated`: inert `Sendable` value data.
    @ObservationIgnored nonisolated let namespace: ProximityNamespace
    @ObservationIgnored private var lastAcceptedBySender: [String: Date] = [:]

    private static let maxPendingShares = 8
    private static let perSenderRateLimitSeconds: TimeInterval = 3

    /// The recipe-share manager for `store`: a pair session over the host under Fernlet's recipe
    /// profile on the host's own namespace, `ProximityPairProfile.recipeShare(in:)`.
    public convenience init(store: any ProximityHost) {
        self.init(pairSession: ProximityPairSession(
            host: store, profile: .recipeShare(in: store.proximityNamespace)))
    }

    /// The manager over a built `pairSession`: it becomes the session's payload handler (the recipe
    /// envelopes its pairings verify come here) and its event sink (each event is rendered and
    /// appended to the diagnostics list, synchronously, in the order the session acts). The sink
    /// captures this manager weakly: the manager holds the session.
    init(pairSession: ProximityPairSession) {
        self.pairSession = pairSession
        self.namespace = pairSession.namespace
        pairSession.payloadHandler = self
        pairSession.onEvent = { [weak self] event in
            self?.recordDiagnostic(Self.diagnostic(for: event))
        }
    }

    /// Delete-all seam (Docs/PrivacyWipeCoverage.md): the pair session's, which drops the last
    /// share's outcome and the live share's context, then clears its in-memory identity key cache;
    /// keychain rows are shared with the mesh/presence instances (idempotent).
    public func wipeIdentityForDeleteAll() throws {
        try pairSession.wipeIdentityForDeleteAll()
    }

    /// Brings the recipe radio up (the pair session's `start()`).
    public func start() {
        pairSession.start()
    }

    /// Stands the recipe radio down (the pair session's `stop()`): a share still in flight is
    /// published as `interrupted` or `sendIncomplete`.
    public func stop() {
        pairSession.stop()
    }

    /// Restarts the search (the pair session's `refreshDiscovery()`); refused visibly while paired.
    public func refreshDiscovery() {
        pairSession.refreshDiscovery()
    }

    /// Sends `payload` to the picked row through the recipe pair session: the token
    /// `fernlet.recipe.share.v1`, the summary `Recipe share` over the recipe's ingredient count, the
    /// recipe's title as the send's subject, and the payload's JSON from a default `JSONEncoder`,
    /// encoded when the pairing has verified.
    ///
    /// Every way this share can end publishes exactly one ``lastShareOutcome``; the previous outcome
    /// is cleared first.
    public func sendRecipeShare(_ payload: ProximityRecipeSharePayload, to recipient: ProximityPairPeer) {
        let outgoing = ProximityPairSession.Outgoing(
            payloadTypeToken: PayloadType.recipeShare.rawValue,
            // DO NOT LOCALIZE "Recipe share" — it is signed into the envelope's canonical bytes and
            // rendered in the RECEIVING device's Connection Inspector, so translating it here would
            // put the sender's language in a stranger's audit log. The recipient-facing consent copy
            // is built on the receiving side and is free to localize; this is not it. See
            // `FernletIdentityEnvelope.payloadSummary`.
            summary: PayloadSummary(
                title: "Recipe share",
                subtitle: nil,
                itemCount: payload.recipe.ingredientCount
            ),
            subject: payload.recipe.title,
            encode: { try JSONEncoder().encode(payload) }
        )
        pairSession.send(outgoing, to: recipient)
    }

    public func dismissRecipeShare(_ share: PendingProximityRecipeShare) {
        pendingRecipeShares.removeAll { $0.id == share.id }
    }

    public func dismissRecipeShare(id: UUID) {
        pendingRecipeShares.removeAll { $0.id == id }
    }

    public func proximityCoordinator(
        _ coordinator: ProximityCoordinator,
        didReceive envelope: FernletIdentityEnvelope,
        plaintext: Data,
        from peer: ProximityCoordinator.PeerIdentity?
    ) {
        guard envelope.payloadType == .recipeShare else { return }
        // Size gate BEFORE the decoder: the transport floor is 16 MiB, and JSONDecoder on a
        // multi-megabyte body is itself the denial-of-service. An honest share is far under 1 MiB
        // (see ProximityRecipeSharePayload.maxWireBytes for the derivation).
        // Peer-supplied name, rendered in the review sheet and every diagnostic below: coerce ONCE
        // here (control/zero-width/bidi out, the host's peer-name cap). Never coerce it before
        // `verify` — the raw field is signature-covered.
        let senderName = ProximityDisplayName.peerDisplayName(envelope.senderDisplayName, in: namespace)
        guard plaintext.count <= ProximityRecipeSharePayload.maxWireBytes else {
            recordDiagnostic("Dropped an oversized recipe share from \(senderName).")
            return
        }
        guard let decoded = try? JSONDecoder().decode(ProximityRecipeSharePayload.self, from: plaintext),
              decoded.format == "fernlet.proximity.recipe",
              decoded.version == 1 else { return }
        // Enforce the wire image cap AT THE DOOR, not just at import time: the pending queue holds
        // payloads until the user reviews them, and the sealed-frame layer alone would let a
        // hostile peer park multi-MB images (bytes an honest sender never produces) in memory.
        // clampedForReview() bounds the strings the review sheet renders for the same reason.
        let payload = decoded.droppingOversizeImage().clampedForReview()

        // DELIBERATELY RAW: this is the per-sender RATE-LIMIT key, never rendered. Sanitizing it
        // would collapse distinct unfingerprinted senders — names differing only by a zero-width
        // character — into one bucket, which is the opposite of what the limiter is for.
        let senderFP = peer?.fingerprint ?? envelope.senderDisplayName
        let now = Date()
        if let lastAccepted = lastAcceptedBySender[senderFP],
           now.timeIntervalSince(lastAccepted) < Self.perSenderRateLimitSeconds {
            recordDiagnostic("Rate-limited recipe share from \(senderName).")
            return
        }
        guard pendingRecipeShares.count < Self.maxPendingShares else {
            recordDiagnostic("Dropped recipe share from \(senderName): queue full.")
            return
        }
        // R3: prune before inserting — entries older than the rate-limit window gate nothing, so
        // without this the map grows one entry per distinct sender for the manager's lifetime.
        lastAcceptedBySender = lastAcceptedBySender.filter {
            now.timeIntervalSince($0.value) < Self.perSenderRateLimitSeconds
        }
        lastAcceptedBySender[senderFP] = now

        let pending = PendingProximityRecipeShare(
            senderDisplayName: senderName,
            senderFingerprint: peer?.fingerprint,
            receivedAt: now,
            payload: payload
        )
        pendingRecipeShares.removeAll { $0.id == pending.id }
        pendingRecipeShares.insert(pending, at: 0)
        if pendingRecipeShares.count > Self.maxPendingShares {
            pendingRecipeShares = Array(pendingRecipeShares.prefix(Self.maxPendingShares))
        }
        recordDiagnostic("Received recipe share from \(senderName).")
    }

    /// Appends one line to the capped diagnostics list: a rendered pair-session event, or one of the
    /// receive handler's own lines.
    private func recordDiagnostic(_ message: String) {
        diagnosticEvents = ProximityRecipeShareDiagnostics.appending(
            ProximityRecipeShareDiagnosticEvent(message: message),
            to: diagnosticEvents
        )
    }
}

// MARK: - The English the share sheet shows

/// The renderer: the one place the recipe share's status line and diagnostics become English.
///
/// Every sentence is a frozen literal the share sheet renders verbatim (`Text(verbatim:)`) and the
/// recipe battery asserts by substring, so each is byte for byte the sentence the mechanism once
/// composed at its site. The switches are exhaustive with no `default`: a new
/// ``ProximityPairSession/Status/Failure`` or ``ProximityPairSession/Event`` case is a build error
/// here until it has its sentence. `FernletFeatureGoldenTests` 31e renders every case with distinct
/// arguments against its frozen sentence.
extension ProximityRecipeShareManager {

    /// The status line the share sheet shows for `status`: the same case with the same name, and a
    /// failure's sentence from ``statusMessage(for:)``.
    static func sendState(for status: ProximityPairSession.Status) -> SendState {
        switch status {
        case .idle: return .idle
        case .connecting(let name): return .connecting(recipientName: name)
        case .sending(let name): return .sending(recipientName: name)
        case .sent(let name): return .sent(recipientName: name)
        case .failed(let failure): return .failed(message: statusMessage(for: failure))
        }
    }

    /// The status line's sentence for `failure`.
    static func statusMessage(for failure: ProximityPairSession.Status.Failure) -> String {
        switch failure {
        case .searchRefusedWhilePaired(let name):
            return "Connected to \(name) — recipe sharing links two Fernlets at a time."
        case .recipientUnavailable:
            return "That nearby Fernlet is no longer available."
        case .connectingToAnother:
            return "Still connecting to another Fernlet — recipe sharing links two Fernlets at a time."
        case .pairedWithAnother(let name):
            return "Still sharing with \(name) — recipe sharing links two Fernlets at a time."
        case .noAnswer(let name):
            return "No answer from \(name) — that Fernlet may be busy sharing with someone else."
        case .couldNotConnect(let name):
            return "Could not connect securely to \(name)."
        case .duplicateSend, .sendFailed:
            return "Could not send that recipe."
        }
    }

    /// The diagnostics line for `event`; a radio failure's message is the radio's own, verbatim.
    static func diagnostic(for event: ProximityPairSession.Event) -> String {
        switch event {
        case .discoveryStarted: return "Recipe share discovery started."
        case .discoveryStopped: return "Recipe share discovery stopped."
        case .discoveryRefreshed: return "Recipe share discovery refreshed."
        case .listeningWillRetry: return "Recipe share radio failed to start — listening will retry on the next app event."
        case .radioDidNotStart(let error): return "The recipe share radio could not start: \(error)"
        case .radioFailed(let message): return message
        case .searchSkippedWhilePaired(let name): return "Search skipped — already paired with \(name)."
        case .connecting(let name): return "Connecting to \(name)."
        case .recipientUnavailable(let name): return "Recipe share failed: \(name) is no longer available."
        case .connectingToAnother(let name): return "Refused share to \(name): another connection attempt is in flight."
        case .sendRefusedWhilePaired(recipientName: let recipient, pairedWith: let name):
            return "Refused share to \(recipient): already paired with \(name)."
        case .noAnswer(let name): return "Connect timeout: \(name) did not answer."
        case .couldNotConnect(let name):
            return "Recipe share to \(name) ended before sending: the connection closed during setup."
        case .sending(subject: let subject, recipientName: let name): return "Sending \(subject) to \(name)."
        case .duplicateSendRefused(let subject): return "Refused a second send of \(subject)."
        case .completionNotCounted: return "A send completed against a newer share record — completion not counted."
        case .sent(subject: let subject, recipientName: let name): return "Sent \(subject) to \(name)."
        case .sendFailed(let name): return "Recipe share failed while sending to \(name)."
        case .outcomeSuperseded: return "A share outcome arrived for a superseded share — not shown."
        case .discovered(let name): return "Discovered \(name)."
        case .lost(let name): return "\(name) is no longer nearby."
        case .disconnected(let name): return "\(name) disconnected."
        case .turnedAway(let name): return "Turned away \(name) — recipe sharing links two Fernlets at a time."
        case .channelOpened(let name): return "Secure recipe-share channel opened with \(name)."
        case .closedToOthers(let name): return "Recipe sharing closed to others while paired with \(name)."
        case .confirming: return "Recipe share recipient verified; confirming selected recipient."
        case .verified(let name): return "Verified \(name)."
        case .reopened: return "Recipe sharing reopened to nearby Fernlets."
        case .droppedStalled(let name): return "Dropped stalled connection to \(name)."
        }
    }
}
