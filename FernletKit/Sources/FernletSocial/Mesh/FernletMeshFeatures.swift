// FernletMeshFeatures.swift
// FernletSocial/Mesh
//
// ProximityKit plan step A0.5.5: the composition of Fernlet's mesh features over ProximityKit's routed
// mesh engine. The app builds one, lazily, as FernletStore's `meshFeatures`: it
// asks the host for the device identity once, builds the mesh through a factory with that identity,
// builds each feature object over the mesh and the same identity, and installs every engine role a
// feature plays before its initializer returns, so no restore, re-entry or radio start can see a mesh
// without them. It owns all of it: FernletStore reaches the mesh as `meshFeatures.mesh`.
//
// It holds the capability list the mesh
// advertises, the friend vouch list's content, the clothing shop, the moderation report relay, the
// fuzzy friend state, the Group Activities manager, the live-session chat, the in-session hearts and
// the session photos, registers the chat's and the photos' projection handlers and the hearts' ledger
// judge for the temporary-message, photo and heart rows it declares through the host
// (`FernletRoutedTypes`), and it is the mesh's session observer, through a private adapter, for the
// moments its features act on. Its host is FernletSocial's own refinement, `FernletSocialHost`, and
// the pending photo corpus's key provider is handed to it (nil in every shipping path), not to the
// mesh.

import Foundation
import FernletDomainModel
import FernletFoundation
import PrivateMediaStore
import ProximityKit

/// Fernlet's mesh features and the mesh engine they ride: the composition the app builds once and owns.
///
/// The initializer runs in a fixed order: the device identity (handed in, or asked of the host's
/// ``ProximityHost/makeProximityIdentity()`` exactly once), the mesh (built by the factory with that
/// identity, which checks and provisions it), the feature objects (over the mesh and the same
/// identity, the activity manager first, whose ledger loads, collects and may write as it is built,
/// then the session photos, whose wall, pending corpus and reconcile load as they are built), then
/// the installations on the mesh — the
/// capability provider, the vouch-list exchange, the clothing shop's two payload handlers, the
/// moderation report's, the friend state's, the activity manager's five and its two mesh seams, the
/// chat's projection handler, the photos' projection handler, the hearts' ledger judge and, last, the
/// session observer — all before the initializer returns. The mesh is reachable by no other code until
/// then.
///
/// **Ownership.** This object holds the mesh and every feature strongly, and the session observer, a
/// private adapter that holds this object `unowned`. The mesh retains only what it calls: the capability
/// provider's closure, which captures ``capabilities`` alone, the vouch-list exchange, a private adapter
/// that holds ``vouchList``, the nine payload handlers, which hold their features weakly (the activity
/// manager's hold the features' host holder too), the chat's and the photos' projection handlers,
/// private adapters that hold ``chat`` and ``photos``, and the hearts' ledger judge, a private adapter
/// that holds ``hearts``; it holds the session observer weakly, so the adapter lives exactly as long as
/// this object. Each feature holds the mesh weakly (the activity manager in its two seams), and the
/// host `unowned`, through the features' host holder as the mesh holds it (the activity manager in its
/// own reference), so nothing the mesh retains retains the mesh or this object.
///
/// Conforms to nothing of the engine's: each engine role a feature plays is a private adapter nested in
/// that feature, and the session observer one nested here (design rule 6), so the engine's entry points
/// are never API on an object the app holds.
@MainActor
public final class FernletMeshFeatures {

    /// The mesh engine this composition built and owns.
    public let mesh: MeshNetworkManager

    /// The capability tokens the mesh advertises in this device's identity introduction.
    public let capabilities: FernletMeshCapabilities

    /// The friend vouch list's content, and the "Friend of" labels it composes.
    public let vouchList: FernletVouchList

    /// The friend-mesh clothing shop (Phase 3a): catalogs exchanged during the session + the 1-hour
    /// post-session browse window. Its lifecycle follows the same moments that drive the friend-review
    /// batch — but the two deliberately diverge on session FORMATION (the first slot commit): the
    /// review batch survives it, the shop window closes. Search starts (startJoin/startNewMesh — which
    /// fire on every Social-tab entry and scene reactivation) touch NEITHER.
    public let clothingShop: MeshClothingShop

    /// The one-hop moderation report relay (Phase 3b): this device's own signed reports, handed to a
    /// committed friend kept in person, and such a friend's verified rows, handed to the app.
    public let moderation: ModerationReportExchange

    /// The fuzzy friend state (Phase 4): this device's state + appearance, shared with a committed friend
    /// kept in person while the user opts in, and such a friend's state, handed to the app.
    public let friendState: FriendStateExchange

    /// Phase 6 (Group Activities): the state + host-authoritative roster/token brain. Rides this friend
    /// mesh (no new radio); constructed first among the features and attached to the mesh in `init`.
    /// Memory + a device-local sidecar (NEVER synced).
    public let activities: ProximityActivityManager

    /// The live-session chat (Phase 5): the session transcript, the 13+ gate and the text sender, and
    /// the temporary-message row's projection handler through a private adapter (plan step A0.5.9).
    /// Its transcript is dropped by this object's session observer at a session's formation, its end
    /// and a privacy wipe's start, right after the mesh advances its session-content generation.
    public let chat: MeshSessionChat

    /// The in-session hearts (TF b19 item 5; on the routed store since P6 item 6): the send to one
    /// recipient, its state and failure vocabulary, and the heart row's ledger judge through a private
    /// adapter (plan step A0.5.10). The app wires their ledger and closeness hooks; their feedback and
    /// in-flight claims are dropped by this object's session observer, last, when a session ends.
    public let hearts: MeshSessionHearts

    /// The session photos (P5 item 13; held for the person's answer since 2026-09-30): the friend-photo
    /// wall with its preferences and favourites, the sealed pending corpus and its answers, the film and
    /// its quota, the session-end review batch, the capture and its routed share, and the photo row's
    /// projection handler through a private adapter (plan step A0.5.11). Built right after the activity
    /// manager; this object's session observer runs its legs at each moment the mesh reports — the
    /// review merge and the photo move first when a session ends.
    public let photos: MeshSessionPhotos

    /// Phase 5: a friend session committed with this fingerprint (an in-person meeting) — feeds
    /// closeness. Called first at every slot commit, before any other feature's commit leg.
    public var onFriendSessionCommitted: ((String) -> Void)?

    /// The clothing shop's mesh wiring: its handlers, its commit-time sends and their tracking.
    /// Internal, not private, so the test target reaches its send seams and its offer gate through
    /// `@testable import`; the app never reaches it.
    let shopExchange: ClothingShopExchange

    /// The device identity the mesh holds, the one the host's door built (or the one handed in).
    private let identity: IdentityService

    /// The host the features read, held `unowned`, with its namespace read once.
    private let meshHost: FernletMeshHost

    /// Fernlet's routed-type rows over the host's namespace, read once: the chat mints under the text
    /// row's token and its projection adapter is registered under the same one; the photos mint under
    /// the photo row's token and their projection adapter is registered under the same one; the hearts
    /// mint under the heart row's token and their ledger judge is registered under the same one.
    private let routedRows: FernletRoutedTypes

    /// The routed registrations the mesh refused while this composition installed its roles, by
    /// token. Always empty for Fernlet's own rows, which the host declares beside the handlers and the
    /// judge (S9, S10): each refusal also writes one `meshFeatures.registrationRefused` line, and the
    /// test rig holds this empty. Internal, for that rig.
    private(set) var refusedRoutedRegistrations: [String] = []

    /// The mesh's session observer: the private adapter this composition installs on the mesh last,
    /// once every other stored property is set, and keeps for its own lifetime (the mesh holds it
    /// weakly).
    private var sessionObserver: SessionObserver?

    /// The factory the composition builds its mesh with, from the device identity it was handed or
    /// asked the host for.
    public typealias MakeMesh = @MainActor (IdentityService) -> MeshNetworkManager

    /// The app's composition: one identity from the host's door, the mesh over the host's radio, then
    /// the features.
    ///
    /// - Parameter host: The app's host, which owns this composition and keeps it alive.
    public convenience init(host: any FernletSocialHost) {
        self.init(host: host, identity: nil, heldPhotoKeys: nil) { identity in
            MeshNetworkManager(store: host, identity: identity)
        }
    }

    /// The composition over a mesh the factory builds: the seam the test rig uses to inject an
    /// identity, the pending photo corpus's key provider and a mesh over a fake radio.
    ///
    /// - Parameters:
    ///   - host: The app's host; the caller keeps it alive.
    ///   - injected: The device identity, or nil to ask the host's door once.
    ///   - heldPhotoKeys: The pending photo corpus's key provider, handed to the session photos: nil (the
    ///     app's) for the device-bound keychain row; a test passes an in-memory or wrong key.
    ///   - makeMesh: Builds the mesh with the identity.
    init(
        host: any FernletSocialHost, identity injected: IdentityService?,
        heldPhotoKeys: (any PrivateMediaKeyProviding)?, makeMesh: MakeMesh
    ) {
        let identity = injected ?? host.makeProximityIdentity()
        let mesh = makeMesh(identity)
        // Per-HOST root like the photo wall: `FernletStore.resetAll` calls
        // `meshFeatures.activities.clearAll()`, which removes this sidecar.
        let activities = ProximityActivityManager(
            store: host,
            identity: identity,
            fileURL: ProximityActivityManager.fileURL(in: host.proximitySupportDirectory)
        )
        let meshHost = FernletMeshHost(host: host)
        let routedRows = FernletRoutedTypes(meshHost.namespace.family.vocabulary.routedTypes)
        // Right after the activity manager, as the mesh manager's initializer ordered them: the wall,
        // the pending corpus and the reconcile load as the photo object is built.
        let photos = MeshSessionPhotos(
            mesh: mesh, meshHost: meshHost, photoToken: routedRows.photo.token, heldPhotoKeys: heldPhotoKeys
        )
        let clothingShop = MeshClothingShop()
        let friendState = FriendStateExchange(mesh: mesh, meshHost: meshHost)
        let chat = MeshSessionChat(mesh: mesh, meshHost: meshHost, textToken: routedRows.text.token)
        let hearts = MeshSessionHearts(mesh: mesh, meshHost: meshHost, heartToken: routedRows.heart.token)
        self.identity = identity
        self.meshHost = meshHost
        self.routedRows = routedRows
        self.mesh = mesh
        self.clothingShop = clothingShop
        self.moderation = ModerationReportExchange(mesh: mesh, meshHost: meshHost, identity: identity)
        self.friendState = friendState
        self.activities = activities
        self.chat = chat
        self.hearts = hearts
        self.photos = photos
        self.capabilities = FernletMeshCapabilities(
            mesh: mesh, meshHost: meshHost, clothingShop: clothingShop, friendState: friendState, chat: chat)
        self.vouchList = FernletVouchList(meshHost: meshHost, identity: identity)
        self.shopExchange = ClothingShopExchange(shop: clothingShop, mesh: mesh, meshHost: meshHost)
        installOnMesh()
    }

    /// Installs every engine role a feature plays on the mesh, before the initializer returns: the
    /// capability provider, in a closure that captures the capability list alone, the vouch-list
    /// exchange, the payload handlers (the clothing shop's two, then the moderation report's, the
    /// friend state's and the activity manager's five),
    /// the activity manager's two mesh seams, the chat's projection handler under the text row's token
    /// (plan step A0.5.9), the photos' projection handler under the photo row's token (plan step
    /// A0.5.11), the hearts' ledger judge under the heart row's token (plan step A0.5.10) and, last, the
    /// session observer, created here once every stored property is set, so it may hold this object
    /// `unowned`.
    private func installOnMesh() {
        let capabilities = self.capabilities
        mesh.localCapabilitiesProvider = { capabilities.localCapabilities() }
        mesh.vouchListExchange = vouchList.makeExchange()
        shopExchange.registerHandlers(on: mesh)
        moderation.registerHandler(on: mesh)
        friendState.registerHandler(on: mesh)
        activities.attach(to: mesh, meshHost: meshHost)
        registerProjector(chat.makeProjector(), forToken: routedRows.text.token)
        registerProjector(photos.makeProjector(), forToken: routedRows.photo.token)
        registerJudge(hearts.makeJudge(), forToken: routedRows.heart.token)
        let observer = SessionObserver(features: self)
        sessionObserver = observer
        mesh.sessionObserver = observer
    }

    /// Registers one feature's routed projection adapter on the mesh and checks the answer (S9).
    ///
    /// A refusal is unreachable for Fernlet's rows — the host declares each row beside its handler,
    /// and none it hands a projection adapter is a judge row — so it is not silent either: it writes one
    /// `meshFeatures.registrationRefused` line naming the token and the role, and is kept in
    /// ``refusedRoutedRegistrations``, which the test rig holds empty. A refused row then answers
    /// `noDispatchArm` at the engine's dispatch, as a row with no handler always has.
    ///
    /// - Parameters:
    ///   - projector: The feature's adapter.
    ///   - token: The routed type token of the feature's row.
    private func registerProjector<H: MeshRoutedProjectionHandler>(_ projector: H, forToken token: String) {
        let registered = mesh.registerRoutedProjectionHandler(projector, forToken: token)
        guard !registered else { return }
        FernletAuditLog.log("meshFeatures.registrationRefused", context: ["token": token, "kind": "projector"])
        refusedRoutedRegistrations.append(token)
    }

    /// Registers one feature's routed ledger judge on the mesh and checks the answer (S10), the way
    /// ``registerProjector(_:forToken:)`` checks a projection adapter's.
    ///
    /// A refusal is unreachable for Fernlet's rows — the host declares the heart row beside its judge,
    /// and it is a judge row — so it is not silent either: it writes one
    /// `meshFeatures.registrationRefused` line naming the token and the role, and is kept in
    /// ``refusedRoutedRegistrations``, which the test rig holds empty. A refused row's items then wait,
    /// counted as pending and never judged, as a judge row with no judge always has.
    ///
    /// - Parameters:
    ///   - judge: The feature's adapter.
    ///   - token: The routed type token of the feature's row.
    private func registerJudge<J: MeshRoutedLedgerJudge>(_ judge: J, forToken token: String) {
        let registered = mesh.registerRoutedLedgerJudge(judge, forToken: token)
        guard !registered else { return }
        FernletAuditLog.log("meshFeatures.registrationRefused", context: ["token": token, "kind": "judge"])
        refusedRoutedRegistrations.append(token)
    }

    /// The mesh's session observer (S15): each moment of a session's life the mesh reports, fanned out
    /// to the features in one fixed order, written here. Private and nested,
    /// so the engine's entry points stay off this object's public API (design rule 6), and so it
    /// reaches this object's private members.
    private final class SessionObserver: MeshSessionObserver {

        /// The composition whose features each moment reaches. `unowned`: the composition owns this
        /// adapter and the mesh holds it weakly, so it never outlives the composition.
        unowned let features: FernletMeshFeatures

        /// An observer over `features`.
        ///
        /// - Parameter features: The composition, every stored property already set.
        init(features: FernletMeshFeatures) {
            self.features = features
        }

        /// A slot committed: the closeness hook first (this committed friend is physically present —
        /// feed closeness, day-capped downstream); on a formation, the shop's new session, the chat
        /// transcript's drop and the shop's send tracking cleared (the mesh advanced its
        /// session-content generation just before this call); then the shop's
        /// catalog offer to this slot, this device's own moderation reports and its friend state, each
        /// send spawned in that order; and, last, the activities this device hosts, offered to this
        /// peer with a roster version digest, their sends spawned after the others.
        ///
        /// - Parameter commit: The committed slot, its peer and whether it formed the session.
        func meshSlotDidCommit(_ commit: MeshSlotCommit) {
            features.onFriendSessionCommitted?(commit.peer.fingerprint)
            if commit.formsSession {
                features.clothingShop.beginNewSession()
                features.chat.clearTranscript()
                features.shopExchange.clearShopSendTracking()
            }
            features.shopExchange.offerCatalog(to: commit.slot, peer: commit.peer)
            features.moderation.offerReports(to: commit.slot, peer: commit.peer)
            features.friendState.offerState(to: commit.slot, peer: commit.peer)
            // Phase 6: offer any activities we host to this committed peer + exchange a roster version digest
            // so the highest verified snapshot converges. The manager sends via its wired `send` closure.
            if commit.peer.supports(ProximityCapability.activities.rawValue,
                                    in: features.meshHost.namespace.family.vocabulary.capabilities) {
                features.activities.onPeerCommitted(fingerprint: commit.peer.fingerprint)
            }
        }

        /// A slot was dropped: the shop forgets it sent to that slot, so a rejoining friend
        /// re-exchanges.
        ///
        /// - Parameter slotID: The dropped slot's id.
        func meshSlotDidLeave(slotID: UUID) {
            features.shopExchange.pruneShopSendTracking(for: slotID)
        }

        /// The search stopped: the shop forgets every slot it sent to and every request it answered.
        func meshSearchDidStop() {
            features.shopExchange.clearShopSendTracking()
        }

        /// The session ended: first the review promotion — the roster the mesh drained merges into the
        /// pending review and the session's unreviewed photos move in with it — then the shop's one-hour
        /// browse window opens over the catalogs it holds, then the chat transcript is dropped (messages
        /// vanish), then, last, the in-session heart's feedback and its in-flight claims go; the mesh
        /// drained its roster, ended the formed-session epoch and advanced its session-content
        /// generation just before this call, none of which the promotion reads.
        ///
        /// - Parameter end: The ending, with the roster the mesh drained.
        func meshSessionDidEnd(_ end: MeshSessionEnd) {
            features.photos.promoteEndedSessionIntoPendingReview(drainedRoster: end.drainedRoster)
            features.clothingShop.openWindowAtSessionEnd()
            features.chat.clearTranscript()
            features.hearts.resetSessionHeartState()
        }

        /// A privacy wipe began: the chat transcript is dropped. The mesh raised its projection
        /// refusal and advanced its session-content generation just before this call, so nothing
        /// projects into the transcript again while the wipe runs, or after it from before it.
        func meshPrivacyWipeDidBegin() {
            features.chat.clearTranscript()
        }

        /// A new search began: the session photos reset the film, move a photo still listed into the
        /// pending review and mint the new photo session's ids, told by the mesh's `startJoin()` before
        /// it resets its roster and removal tallies.
        func meshSessionWillBegin() {
            features.photos.beginNewPhotoSession()
        }

        /// This device left its session: the session photos forget the photo session's ids, after the
        /// teardown and the ending the mesh's `leaveSession()` ran.
        func meshSessionDidLeave() {
            features.photos.forgetPhotoSession()
        }

        /// The mesh the session counts against changed: the session photos' film follows it, at the
        /// mesh's founding, abandoned founding and `leaveMesh()`.
        ///
        /// - Parameter change: The change.
        func meshScopeDidChange(_ change: MeshScopeChange) {
            features.photos.noteScopeChange(change)
        }

        /// A signed removal took effect: the removed member leaves the session photos' pending review,
        /// right after the mesh purged it from its live roster.
        ///
        /// - Parameter fingerprint: The removed member's fingerprint.
        func meshMemberWasRemoved(fingerprint: String) {
            features.photos.dropRemovedMemberFromReview(fingerprint: fingerprint)
        }

        /// The host pushed a changed routed access gate: the session photos mirror it, re-read their
        /// indexes on a rising edge and recompute whether held photos can be shown, before the re-entry
        /// pass the edge owes.
        ///
        /// - Parameters:
        ///   - gate: The gate as the host now knows it.
        ///   - isRising: Whether a ciphertext leg rose.
        ///   - now: The instant the host pushed it.
        func meshRoutedAccessGateDidChange(_ gate: MeshRoutedAccessGate, isRising: Bool, now: Date) {
            features.photos.applyAccessGate(gate, isRising: isRising, now: now)
        }
    }
}
