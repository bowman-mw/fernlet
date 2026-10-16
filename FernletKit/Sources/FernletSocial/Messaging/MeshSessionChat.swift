// MeshSessionChat.swift
// FernletSocial/Messaging
//
// ProximityKit plan step A0.5.9: the live-session chat (Phase 5; a routed item since P6 item 4): the
// transcript store, the 13+ chat gate, the text sender, which mints through the engine's public
// origination door, its send
// outcome and its test seam, and the per-origin message budget; and the temporary-message row's
// projection handler, a private adapter nested here that the composition (`FernletMeshFeatures`)
// registers under the host's text row: the 13+ gate before the engine opens an item, then the
// session liveness the engine computed, the budget and the transcript, in that order.
//
// The engine decides the rest: the whole guard chain above a handler (the privacy-wipe
// refusal, the decrypt predicate, the row, the projected set, the ledger's author with its removal
// and block legs, the resident bound, the mutation predicate, the blob), the one open, and the
// session-content generation the liveness reads, which it advances at the three moments the
// transcript goes — a session's formation, its end and a privacy wipe's start. Dropping the
// transcript itself is this object's, run by the composition's session observer right after each
// advance.

import Foundation
import Observation
import FernletFoundation
import ProximityKit

// MARK: - MeshTextSendOutcome

/// What ``MeshSessionChat/sendTempMessage(_:)`` did with one typed message (P6 item 4, plan §12).
///
/// **Returned, never published.** `routedShareRefusal` is the photo path's observable and has
/// exactly one consumer — a session `.alert` on `DisposableCameraView`, the view the chat panel is
/// presented *over*, so publishing a chat refusal there fires an alert on a covered presenter and
/// one of the two presentations is dropped. Its copy is photo-worded in every arm as well. The
/// panel reads this value instead and shows the non-staged cases inline at the top of the compose
/// bar — directly ABOVE the text field, between it and the transcript (P6 item 4 fix review, P3-2:
/// five docs said "beneath the compose bar", which is not where `SessionChatPanel` draws it) —
/// keeping the draft so "send again" is the retry.
///
/// Deliberately **not** `@discardableResult`: an unread outcome here is a message the user believes
/// was sent (R7, the mesh's `sendEnvelope(_:encodable:via:sealed:)`'s own precedent). The six cases
/// are frozen and each reaches a different sentence or none; `staged` and `empty` are the two the
/// panel says nothing about, the first because the echo in the transcript IS the feedback and the
/// second because the send control is already disabled for it. `filtered` joined the five on
/// 2026-10-15 (App Review guideline 1.2).
public nonisolated enum MeshTextSendOutcome: Equatable, Sendable {

    /// The item is in this device's routed store, complete, and pushed once to every committed
    /// slot. The local echo is in the transcript — appended **only** here.
    case staged
    /// The derived roster names nobody else yet: the founding window, or a genuinely solo session.
    /// Visible, because destinations are frozen at the mint and there is no offline queue.
    case noDestinations
    /// A mint was attempted and failed, with the routed path's own frozen cause.
    case refused(MeshRoutedShareRefusal)
    /// The 13+ chat gate refused. Unreachable from a gated UI, and enforced anyway.
    case ageGated
    /// Nothing survived the sanitizer and the wire byte bound — including the case the bound
    /// creates, a single grapheme cluster wider than the whole allowance.
    case empty
    /// The on-device send filter (`SessionMessageFilter`) found a listed word in the draft, so
    /// nothing was framed or minted. The panel says so in place, gently, and keeps the draft so the
    /// person can reword it.
    case filtered
}

// MARK: - MeshSessionChat

/// Fernlet's live-session chat (Phase 5): the session's transcript, the 13+ gate, the text sender and,
/// through a private adapter, the temporary-message row's projection handler.
///
/// Built by the composition (``FernletMeshFeatures``) over its mesh, held weakly, the features' host
/// holder, which answers the blocked-fingerprint question and carries the namespace a sender's name is
/// moderated under, and the token of the host's text row (FernletSocial's ``FernletRoutedTypes``),
/// which the sender mints under and the composition registers the adapter under. The app wires the
/// gate (``chatAllowedProvider``), reads the transcript (``sessionMessages``) and sends
/// (``sendTempMessage(_:)``); the projection handler and the transcript's drop are not its API.
///
/// `@MainActor` and `@Observable`, like the mesh manager, with its providers, test seam, budget and
/// references `@ObservationIgnored`: the panel re-renders on the store's own observation
/// (``sessionMessages`` is a constant), never on this object's providers or budget.
@MainActor
@Observable
public final class MeshSessionChat {

    /// The live-session temporary-message store (Phase 5): the current session's chat transcript.
    /// Memory-only and deliberately NOT Codable — it can never enter a snapshot. Dropped at EVERY
    /// session-end path (the same last-committed-slot-gone moment that promotes `pendingFriendReview`
    /// and opens the shop window), on the next session formation and when a privacy wipe begins, each
    /// time by the composition's session observer right after the mesh advances its session-content
    /// generation. Unlike the shop's 1-hour window, messages do NOT outlive the session — they vanish.
    public let sessionMessages = SessionMessageStore()

    /// Whether this device may take part in live-session chat at all — the 13+ age gate (see
    /// `AgeAssuranceRecord`). Optional-and-nil means NOT allowed, as with the host's away-hearts
    /// consent: a chat nobody wired stays silent rather than opening a messaging surface to a child.
    ///
    /// Enforced in FOUR places since P6 item 4, because any one alone is insufficient:
    /// 1. the advertised capability list (the composition's ``FernletMeshCapabilities``, which reads
    ///    ``isChatAllowed``) withholds `.messages` — now an **advertisement only**: it is a truthful
    ///    statement that this device is above the line and will show a transcript, and nothing reads
    ///    it to decide a destination any more, because a routed manifest binds wraps ≡ destinations
    ///    and the roster carries no capabilities.
    /// 2. ``sendTempMessage(_:)`` refuses by name (``MeshTextSendOutcome/ageGated``), so nothing
    ///    leaves this device.
    /// 3. the **projection** refuses before the unwrap, so a gated device decrypts nothing rather
    ///    than decrypting and discarding — the leg the retired `.tempMessage` handler used to hold,
    ///    and still necessary for the same reason: (1) is only an advertisement, and a peer on a
    ///    modified build or with cached capabilities can still address us. It is the text row's
    ///    projection handler's pre-open verdict (since plan step A0.5.2; this object's adapter's
    ///    since plan step A0.5.9).
    /// 4. the engine's projectable set leaves the text row out entirely while the gate is shut —
    ///    the adapter's `isProjectable` reads this gate — so a gated device's text items never
    ///    spend a projection allowance slot either (R-19 applied to a device that cannot finish a
    ///    type rather than a build that cannot).
    ///
    /// Consequence, named for the owner rather than fixed here: a below-13 member of a mesh still
    /// STORES and acknowledges the ciphertext of every message, because destinations are
    /// `.fullRosterAtCreation`. Addressing only chat-capable members would need a subset delivery
    /// target and capabilities on the roster, and the roster carries none.
    @ObservationIgnored public var chatAllowedProvider: (() -> Bool)?

    /// Resolved once per decision point so the four enforcement seams can never disagree. Public so
    /// the in-session UI can withhold the chat affordance from the same value the transport enforces.
    public var isChatAllowed: Bool { chatAllowedProvider?() == true }

    /// Test seam: fires ONCE per `sendTempMessage(_:)` call with what the send decided (P6 item 4).
    ///
    /// Re-aimed from the retired per-slot fan-out, which fired once per addressed slot with that
    /// slot's id: there are no per-slot sends any more — the mint stages one item and the engine
    /// pushes it — so the observable fact is the outcome, not a slot list. The name changed with
    /// the meaning so the retirement wall can pin the old one at zero.
    @ObservationIgnored var onTextSendForTesting: ((MeshTextSendOutcome) -> Void)?

    /// The list the send filter consults: ``SessionMessageFilter/List/shipping``, always, in the app.
    /// Test seam: a cell swaps in a list built from placeholder words, because the shipping list's
    /// words are kept out of the repository — its tests included — so no cell can type one.
    @ObservationIgnored var sendFilterList: SessionMessageFilter.List = .shipping

    /// How many messages one origin may project into one mesh's transcript. See
    /// ``allowIncomingRoutedText(_:from:)`` for why this replaced a per-second token bucket and for
    /// everything else that bounds a hostile origin.
    ///
    /// Twenty times the photo cap (`maxPhotosPerSenderPerSession`, 10) because a conversation is not
    /// a film roll: the ring the transcript shows is 500 rows and `maxSeenIDs` is 2000, so a cap
    /// materially above 500 would be decoration.
    static let maxTextMessagesPerSenderPerSession = 200

    /// The incoming per-`(mesh, origin)` MESSAGE budget — the twin of the session photos' budget, with
    /// the same keying, the same bounds and the same reason for both: keyed on the ITEM's signed
    /// mesh (D-13.23), memory-only, never cleared by a mesh change, so a deferred projection cannot
    /// buy a fresh budget, and owed no wipe row because nothing here reaches disk.
    @ObservationIgnored private var routedOriginTextQuota: [MeshRoutedOriginQuotaKey: Set<UUID>] = [:]

    /// The mesh the sender mints through. Weak: the composition owns the mesh, and the mesh retains
    /// this object's projection adapter, which holds this object.
    @ObservationIgnored private weak var mesh: MeshNetworkManager?

    /// The host the blocked fingerprints and the display name are read from, and the namespace a
    /// sender's display name is re-moderated under.
    @ObservationIgnored private let meshHost: FernletMeshHost

    /// The token of the host's temporary-message row (``FernletRoutedTypes/text``), which the sender
    /// mints under, behind the mesh's `isRoutedTypeRegistered(_:)`.
    @ObservationIgnored private let textToken: String

    /// A chat over `mesh` and `meshHost`, minting under `textToken`.
    ///
    /// - Parameters:
    ///   - mesh: The composition's mesh, held weakly.
    ///   - meshHost: The features' host holder.
    ///   - textToken: The token of the host's temporary-message row.
    init(mesh: MeshNetworkManager, meshHost: FernletMeshHost, textToken: String) {
        self.mesh = mesh
        self.meshHost = meshHost
        self.textToken = textToken
    }

    /// The display name a message is sent under, resolved from the host at each read.
    private var displayName: String { meshHost.host.resolvedProximityDisplayName }

    // MARK: - Sending

    /// Send a live-session chat message to the room, as a **routed item** (P6 item 4, plan §12).
    ///
    /// The same three lines the session photos' sender uses (`MeshSessionPhotos`'
    /// `shareRoutedPhoto`): take the host's temporary-message row's
    /// token and ask the mesh whether that row is registered, frame a `MeshRoutedTextBody` under the
    /// family's frozen framing, and hand it to the mesh's
    /// `originateRoutedItem(body:typeToken:itemID:audience:now:)`, which pushes it once to every
    /// committed slot and leaves the drain to carry it to everyone else. The legacy per-slot sealed
    /// `.tempMessage` fan-out — and with it the `messages` capability read, the live-slot requirement
    /// and the "no offline queue" rule — is **gone**: a message to an admitted member who is not
    /// linked right now is sealed, wrapped and custodied until a link forms, which is the whole point
    /// of the routed store.
    ///
    /// Four things the sanitizer and the sender do in order, and the order matters: sanitize (500
    /// `Character`s), byte-bound for the wire (`MeshRoutedTextBody.boundedText(_:)`), re-check
    /// emptiness — because the byte bound can empty a message the Character cap admitted, and
    /// minting an empty body would echo an empty row the user cannot dismiss — then the send filter
    /// (`SessionMessageFilter`, App Review guideline 1.2) over the WHOLE sanitized draft, so the
    /// byte bound cannot cut a listed word in half and let it through, and before anything is
    /// framed, so a refused draft never reaches the mesh. The filter's refusal is not audited: a
    /// line saying a person typed a listed word would itself be a record about them.
    ///
    /// **The byte bound TRUNCATES rather than refuses, and it is audited when it bites** (P6 item 4
    /// fix review, P3-4). "Never a surprise refusal for honest input" is bought with a silent edit:
    /// the bounded text is what is minted *and* what the local echo shows, so sender and recipient
    /// agree and the user sees the shortened row with no label. Only a draft whose whole allowance
    /// is one grapheme cluster becomes `.empty`. The audit line is the honest half — a diagnostic,
    /// never user copy, and never a second refusal path.
    ///
    /// **It RETURNS its outcome and publishes nothing.** `routedShareRefusal` is the photo path's
    /// seam and is consumed by one `.alert` on `DisposableCameraView` — the very view the chat panel
    /// is presented *over*, so a refusal published there would fire an alert on a covered presenter
    /// — and every one of its sentences is photo-worded. The panel shows the non-staged outcomes
    /// inline instead, at the top of the compose bar (i.e. directly ABOVE the text field, between it
    /// and the transcript), and keeps the draft so "send again" is the retry. A mesh that is gone
    /// (only after the composition that owns it is) answers as an unregistered row does.
    ///
    /// - Parameter rawText: What the user typed.
    /// - Returns: what happened, including `.noDestinations` — which for text is **not** silent:
    ///   the founding window (commit → found → grant → adopt) is a real second or two in which a
    ///   roster of one has nobody to address, destinations are immutable at the mint, and there is
    ///   no offline queue, so the item can never acquire one later.
    public func sendTempMessage(_ rawText: String) -> MeshTextSendOutcome {
        // The 13+ age gate. The compose bar is withheld below the line, so this is the defense-in-depth
        // re-check at the point of use rather than the primary gate; the projection re-applies it.
        guard isChatAllowed else {
            FernletAuditLog.log("mesh.routedShare.textBlockedAgeGated")
            return noteTextSendOutcome(.ageGated)
        }
        let sanitized = SessionMessageStore.sanitize(rawText)
        let text = MeshRoutedTextBody.boundedText(sanitized)
        guard !text.isEmpty else { return noteTextSendOutcome(.empty) }
        guard !SessionMessageFilter.refuses(sanitized, list: sendFilterList) else {
            return noteTextSendOutcome(.filtered)
        }
        if text != sanitized {
            FernletAuditLog.log(
                "mesh.routedShare.textByteBounded",
                context: ["characters": String(sanitized.count),
                          "bytes": String(sanitized.utf8.count)]
            )
        }
        let id = UUID()
        let now = Date()
        let typeToken = textToken
        guard let mesh, mesh.isRoutedTypeRegistered(typeToken) else {
            return noteTextSendOutcome(.refused(.mintFailed))
        }
        let body: Data
        do {
            body = try MeshRoutedTextBody(
                header: MeshRoutedTextHeader(
                    id: id, sentAt: now,
                    senderName: MeshRoutedTextBody.boundedSenderName(displayName)
                ),
                text: text
            ).encoded()
        } catch {
            FernletAuditLog.log(
                "mesh.routedShare.textRefused",
                context: ["reason": MeshRoutedShareRefusal.sealFailed.rawValue,
                          "error": String(describing: error)]
            )
            return noteTextSendOutcome(.refused(.sealFailed))
        }
        switch mesh.originateRoutedItem(
            body: body, typeToken: typeToken, itemID: id, audience: .fullRoster, now: now
        ) {
        case .staged:
            sessionMessages.appendOutgoing(
                id: id, senderFingerprint: mesh.localFingerprint,
                senderDisplayName: displayName, text: text, sentAt: now
            )
            return noteTextSendOutcome(.staged)
        case .skipped:
            return noteTextSendOutcome(.noDestinations)
        case .refused(let refusal):
            FernletAuditLog.log(
                "mesh.routedShare.textRefused", context: ["reason": refusal.rawValue]
            )
            return noteTextSendOutcome(.refused(refusal))
        }
    }

    /// Fires the send seam and returns the outcome, so every `return` in ``sendTempMessage(_:)``
    /// reports exactly once and none can forget to.
    private func noteTextSendOutcome(_ outcome: MeshTextSendOutcome) -> MeshTextSendOutcome {
        onTextSendForTesting?(outcome)
        return outcome
    }

    /// Re-folds the transcript's view gates — the 13+ gate and the block list — from the live seams
    /// and re-derives what the panel shows. The text arm calls it at every ingest; the app calls it
    /// right after a Report or a block made from inside the session (App Review guideline 1.2), so
    /// the person's own action hides the author's rows at once rather than at the next message.
    ///
    /// Folded here so the gate value cannot disagree with the seam it came from.
    /// `isBlockedFingerprint` ONLY: `ModerationBanStore.isPeerBanned` is not reachable from
    /// `ProximityHost`, so the routed path consults the block half and not the ban half — inherited
    /// from the photo arm, which has the same gap, and named rather than papered over. Closing it is a
    /// host-protocol widening, not an item-4 edit.
    public func refreshVisibleTranscript() {
        sessionMessages.refreshGates(chatAllowed: isChatAllowed) { [meshHost] fingerprint in
            meshHost.host.isBlockedFingerprint(fingerprint)
        }
    }

    // MARK: - The session's moments (called by the composition's session observer)

    /// Drops the live transcript (Phase 5): the session ended (messages vanish), a new one formed, or
    /// a privacy wipe began. The composition's session observer calls it at each of those moments,
    /// right after the mesh advanced its session-content generation there, so an item offered to the
    /// projection before the drop can never project into what follows it. Memory only; nothing to
    /// flush.
    func clearTranscript() {
        sessionMessages.clear()
    }

    // MARK: - Receiving (the temporary-message row's projection)

    /// The temporary-message row's projection handler, for the composition to register under the
    /// host's text row's token (plan step A0.5.9, S9). Opaque, so its private type and its engine
    /// entry points stay off this object's API (design rule 6).
    ///
    /// - Returns: A new adapter over this chat.
    func makeProjector() -> some MeshRoutedProjectionHandler {
        TextProjector(chat: self)
    }

    /// The canonical-store write for a routed TEXT item: the same effects the legacy `.tempMessage`
    /// handler produced, reached through the same store function (P6 item 4, plan §12).
    ///
    /// Nothing here re-implements what `SessionMessageStore` already owns — dedup by id, the
    /// sanitizer, the display-name moderation, the 500-row cap and §10.3's ordering all live there,
    /// and the arm would be a second copy of each. What it adds is the two things the store cannot
    /// know: whether this device's session is still the one the message belongs to (the engine's
    /// `MeshRoutedDelivery.sessionLiveness`, computed by the mesh for the text row since plan step
    /// A0.5.2), and whether the origin has spent its per-mesh message budget.
    ///
    /// Two things are corrected rather than reproduced. The attribution's FINGERPRINT comes from
    /// the origin's signed manifest resolved against `admissions − removals`, where the legacy
    /// handler used the live transport identity — which is what makes a message from a member who
    /// has since walked out of the room still attributable. And the block list is applied by the
    /// engine's projection author check **before** the content key is unwrapped, where the legacy
    /// handler checked it after decoding; the arm therefore adds no second block check, and must
    /// not grow one.
    ///
    /// The one call site is the adapter's `projectRoutedItem(_:delivery:)`, which the engine calls
    /// only from its dispatch, behind its mutation predicate; the pins in
    /// `MeshRoutedLockedDeviceTests` are what make a second, ungated one a build failure. It reads
    /// the delivery the engine built, field for field.
    ///
    /// It takes **no clock**: `sentAt` is the origin's own claim and `seenAt` is a stored fact
    /// about the item (the index's `firstSeenAt`, or the delivery pass's injected instant), carried
    /// in the delivery rather than read here.
    private func routedCanonicalDispatch(
        _ body: MeshRoutedTextBody,
        delivery: MeshRoutedDelivery
    ) -> MeshRoutedProjectionVerdict {
        // The engine computes the liveness for every `.session` row and the text row is one, so a
        // nil is unreachable: it answers the retryable refusal rather than guess a FINAL one.
        guard let liveness = delivery.sessionLiveness else { return .refusedForNow }
        switch liveness {
        case .live:
            break
        case .endedForGood:
            FernletAuditLog.log(
                "mesh.routedProjection.transcriptSessionEnded",
                context: ["type": delivery.typeToken, "mesh": delivery.meshID.uuidString]
            )
            return .refusedForGood
        case .notLiveRightNow:
            FernletAuditLog.log("mesh.routedProjection.transcriptNotLiveYet")
            return .refusedForNow
        }
        guard allowIncomingRoutedText(body.header.id, from: delivery.quotaKey) else {
            return .refusedForGood
        }
        refreshVisibleTranscript()
        let accepted = sessionMessages.receiveIncoming(
            id: body.header.id,
            senderFingerprint: delivery.author.fingerprint,
            senderSigningPublicKey: delivery.author.signingPublicKey,
            senderDisplayName: body.header.senderName,
            text: body.text,
            sentAt: body.header.sentAt,
            seenAt: delivery.seenAt,
            in: meshHost.namespace
        )
        if accepted != .appended {
            FernletAuditLog.log(
                "mesh.routedProjection.transcriptRefused",
                context: ["reason": accepted.rawValue]
            )
        }
        return .handedOn
    }

    /// The incoming per-origin MESSAGE budget, keyed on the ITEM's mesh (D-13.23) — the twin of the
    /// session photos' budget (`MeshSessionPhotos`), and the routed path's replacement for the
    /// retired per-sender token bucket.
    ///
    /// **A policy act, stated plainly** (P6 item 4): a per-SECOND rate limit is replaced by a
    /// per-session TOTAL. The bucket that went with the live transport (burst 5, refill 1/s) is
    /// wrong twice over on a store-and-forward path — a single drain answer carries up to
    /// `MeshRoutedDrainBounds.increment1.maxItems` (16) items, so a chatty pair's backlog reaching a
    /// joining third device would have 11 legitimate messages dropped; and feeding it a *fixed*
    /// per-item `firstSeenAt` makes `elapsed` zero forever, so the bucket would never refill. What
    /// bounds the RATE now is the drain's own 16-item answer and its pacing, not a token count.
    ///
    /// Re-sends of an already-accepted id are free, exactly as the photo quota allows, so a
    /// re-projection after a restart cannot cost a slot it already spent.
    ///
    /// Bounded on both axes: `MeshRoutedStoreFormat.maxItems` (1024) keys × this cap (200) ids, i.e.
    /// at most 204 800 UUIDs if every possible origin in every possible mesh filled its budget.
    /// What else bounds a hostile origin: the per-peer session frame budget
    /// (`sessionFramesPerPeer` 1056, and a 9 065-byte item is one chunk), the store's item and byte
    /// caps, the replay window, the 500-row transcript ring and `maxSeenIDs` (2000).
    ///
    /// Counted against `budget`, the delivery's `MeshRoutedDelivery.quotaKey` — the item's signed
    /// `(mesh, origin)`. Internal rather than private so its three legs have a behavioural cell
    /// rather than only a constants pin: making the body `return true` used to redden nothing (P6
    /// item 4 fix review, finding P2-4); the test target keeps the cells' manifest spelling in one
    /// binding over this form. **Not a door** — no shipping caller outside this type.
    ///
    /// - Parameters:
    ///   - messageID: The message's id, as its body signed it.
    ///   - budget: The item's `(mesh, origin)` budget key.
    /// - Returns: whether the message may enter the transcript.
    func allowIncomingRoutedText(_ messageID: UUID, from budget: MeshRoutedOriginQuotaKey) -> Bool {
        var accepted = routedOriginTextQuota[budget] ?? []
        if accepted.contains(messageID) { return true }
        guard accepted.count < Self.maxTextMessagesPerSenderPerSession else {
            FernletAuditLog.log("mesh.routedProjection.textQuotaSpent")
            return false
        }
        guard routedOriginTextQuota[budget] != nil
                || routedOriginTextQuota.count < MeshRoutedStoreFormat.maxItems else {
            FernletAuditLog.log("mesh.routedProjection.textQuotaMapFull")
            return false
        }
        accepted.insert(messageID)
        routedOriginTextQuota[budget] = accepted                      // R3: bounded map
        return true
    }

    /// The temporary-message row's projection handler (plan step A0.5.9, S9): the 13+ age gate
    /// before the open, then the text arm, called as it is. Private and nested (design rule 6), so
    /// the engine's entry points stay off the chat's public API, and so it reaches the chat's
    /// private arm.
    ///
    /// Holds its chat strongly: the mesh retains this adapter through its projector map, and the chat
    /// holds the mesh weakly, so nothing the mesh retains retains the mesh.
    private final class TextProjector: MeshRoutedProjectionHandler {

        /// The routed text body this row decodes to.
        typealias Body = MeshRoutedTextBody

        /// The chat whose age gate and text arm this calls.
        let chat: MeshSessionChat

        /// An adapter over `chat`.
        ///
        /// - Parameter chat: The chat that makes it.
        init(chat: MeshSessionChat) {
            self.chat = chat
        }

        /// Leg 4 of the 13+ gate: below the line the text row is not enumerated for projection at
        /// all, so a gated device's text items never spend an allowance slot.
        var isProjectable: Bool { chat.isChatAllowed }

        /// Leg 3 of the 13+ gate — advertisement, send, projection, and leg 4 is ``isProjectable``.
        /// Applied BEFORE the unwrap, so a device below the line decrypts nothing rather than
        /// decrypting and discarding, and it is the ONE place an item's projection reads it: a second
        /// check with nothing saying which is live is the shape the retired handler's block check
        /// had. FINAL, because the gate is a durable product rule about this recipient and the
        /// transcript it would have entered belongs to this session.
        ///
        /// - Parameter delivery: The item's signed facts.
        /// - Returns: `refusedForGood` below the line, nil to open the item.
        func verdictBeforeOpen(_ delivery: MeshRoutedDelivery) -> MeshRoutedProjectionVerdict? {
            guard chat.isChatAllowed else {
                FernletAuditLog.log("mesh.routedProjection.transcriptAgeGated")
                return .refusedForGood
            }
            return nil
        }

        /// The text arm: the engine's session liveness, the per-origin budget, then the transcript.
        ///
        /// - Parameters:
        ///   - body: The opened text body.
        ///   - delivery: The item's signed facts and its session liveness.
        /// - Returns: the arm's verdict.
        func projectRoutedItem(
            _ body: MeshRoutedTextBody, delivery: MeshRoutedDelivery
        ) -> MeshRoutedProjectionVerdict {
            chat.routedCanonicalDispatch(body, delivery: delivery)
        }
    }
}
