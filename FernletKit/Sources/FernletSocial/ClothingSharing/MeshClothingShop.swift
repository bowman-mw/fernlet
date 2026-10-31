import Foundation
import Observation
import FernletConnections
import FernletDomainModel
import ProximityKit

/// The friend-mesh clothing shop (Phase 3a, Docs/Proximity-Mesh-Redesign-2026-07-10.md). Replaces the
/// standalone `fernlet-clothes` radio (`ProximityClothingShareManager`, deleted): catalogs now ride the
/// friend mesh as `.clothingCatalog` payloads, exchanged pairwise-sealed during the live session, and each
/// friend's shop OPENS at the session's end — a 1-hour, memory-only browse window of its own, reached from
/// Home's gold shop button (World Friends §3, "whose shop is open").
///
/// Owned by FernletSocial's mesh composition (`FernletMeshFeatures`), whose shop exchange
/// (`ClothingShopExchange`) and session observer drive the whole lifecycle over the mesh:
///  - **Inbound** — the exchange's handler, registered on the mesh's Phase-1 payload registry, hands
///    verified `.clothingCatalog` envelopes here, but only from COMMITTED slots (the committed-slot gate
///    in the mesh's dispatch default is the security boundary — the coordinator dispatches known
///    non-core payloads with `connectedIdentity ?? pendingPeerIdentity` and no state gate) and only with
///    a transport-VERIFIED, unblocked sender fingerprint. Catalogs accumulate for the whole session;
///    there is no mid-session scene-dip clearing (radio privacy is the mesh lifecycle's job).
///  - **Outbound** — the exchange sends `localCatalogProvider()` once per slot at commit, pairwise
///    sealed, and only to peers advertising the `shop` capability.
///  - **One hour per seller** — `openWindowAtSessionEnd()` fires at the same last-committed-slot-gone
///    moment that promotes `pendingFriendReview` (the mesh's session end, told to the composition's
///    observer) and gives every seller whose catalog arrived in that session an hour of their own from
///    then (`windows`, keyed by the catalog's id). A hangout holds up to 16 people, so up to
///    `maxPeerCatalogs` sellers are held. A new session's FORMATION (`beginNewSession()`, from the
///    observer at the mesh's first slot commit — NOT from startJoin/startNewMesh, which fire
///    automatically on every Social-tab entry and scene reactivation) no longer closes the shops already
///    open (owner, Q35: "Meshes can have like 8+ people and each one can have their own shop"): each
///    stays for the rest of its own hour, and ``openShops(at:)`` lists them newest hangout first. A
///    seller met again re-sends their catalog, which replaces the held one, and their hour restarts at
///    the new session's end. App quit drops everything (state is memory-only). Expiry is lazy:
///    `openShops(at:)`, `isWindowOpen` and `remainingWindowMinutes` are pure reads and
///    `cleanupIfExpired()` drops the lapsed shops; no background timers.
///
/// Opt-out is payload-layer (`allowNearbyClothingShares` no longer stops a radio): the app wires
/// `isSharingEnabledProvider` + `localCatalogProvider` (both gate on the setting app-side, so
/// `ProximityHost` stays unchanged) — provider returns nil when off (nothing sent), inbound drops when
/// off, and the setting's OFF transition calls `clearAll()`.
///
/// Buying stays fully local (`FernletStore.buyClothingItem`); this type is pure receive/window state —
/// it never touches coins or the closet. Everything here is memory-only: never persisted, never synced.
@MainActor
@Observable
public final class MeshClothingShop {

    /// One seller's browse hour after their session. Value-typed and observable so views can key
    /// countdowns off it.
    public struct Window: Equatable {
        public let opensAt: Date
        public let expiresAt: Date
    }

    /// One friend's shop while its hour runs: the catalog they sent and their own window (World
    /// Friends §3). ``MeshClothingShop/openShops(at:)`` lists them newest hangout first.
    public struct OpenShop: Identifiable, Equatable {
        /// The seller's catalog, as held.
        public let catalog: ProximityClothingCatalog
        /// The seller's own hour.
        public let window: Window

        /// A shop open for `window`.
        public init(catalog: ProximityClothingCatalog, window: Window) {
            self.catalog = catalog
            self.window = window
        }

        /// The seller's id: the catalog's (the transport-verified fingerprint).
        public var id: String { catalog.id }

        /// Whole minutes left in this shop's hour at `now`, rounded up and floored at 1, as the
        /// switcher's chip and the passport's row read it.
        public func minutesLeft(at now: Date) -> Int {
            MeshClothingShop.wholeMinutes(until: window.expiresAt, from: now)
        }
    }

    public static let windowDuration: TimeInterval = 60 * 60
    /// The most sellers held at once (Power of 10, rule 3): a whole hangout's membership, the mesh
    /// engine's own member cap (16, public so a feature bounds by the engine's number rather than a copy
    /// that could drift), so every friend in the largest hangout keeps a shop. Over it — only possible
    /// across hangouts inside one hour — the shop from the oldest hangout gives way.
    static let maxPeerCatalogs = MeshNetworkManager.maxMeshMembers
    static let perSenderRateLimitSeconds: TimeInterval = 3

    /// Catalogs received from committed peers, keyed by VERIFIED fingerprint only (a re-broadcast
    /// replaces the sender's prior catalog rather than stacking), most recently received first. Held
    /// during the session and through each seller's own hour after it.
    public private(set) var peerCatalogs: [ProximityClothingCatalog] = []
    /// Each seller's own hour, keyed by their catalog's id: set at their session's end, dropped by
    /// `cleanupIfExpired()` once it lapses. Lazy-expired: read `openShops(at:)`, not the raw map.
    public private(set) var windows: [String: Window] = [:]

    /// The newest seller's hour — the one that closes last — or nil when no shop holds one. Kept for the
    /// readers that ask about the shops as a whole (the pushed shop page closes when it lapses).
    /// Lazy-expired: check `isWindowOpen`, not just nil-ness.
    public var window: Window? {
        windows.values.max { $0.expiresAt < $1.expiresAt }
    }

    /// The app supplies this device's current shop catalog; the shop's exchange sends it once per slot
    /// at commit. Returning `nil` (sharing disabled) sends nothing.
    @ObservationIgnored public var localCatalogProvider: (() -> ClothingCatalogPayload?)?
    /// App-side opt-out gate (`allowNearbyClothingShares`): gates inbound accept and the `shop`
    /// capability advertisement. Wired as a closure so the settings read stays app-side and
    /// `ProximityHost` is unchanged. Absent (tests without wiring) = disabled.
    @ObservationIgnored public var isSharingEnabledProvider: (() -> Bool)?

    @ObservationIgnored private var lastAcceptedBySender: [String: Date] = [:]
    /// The sellers whose catalog arrived in the live session: their hour starts at its end. Never
    /// larger than `peerCatalogs` (an evicted or dropped seller leaves it too).
    @ObservationIgnored private var awaitingSessionEnd: Set<String> = []

    public init() {}

    public var isSharingEnabled: Bool { isSharingEnabledProvider?() ?? false }

    /// Whether any friend's shop is open now.
    public var isWindowOpen: Bool { isWindowOpen(at: Date()) }

    /// Whether any friend's shop is open at `now`.
    public func isWindowOpen(at now: Date) -> Bool {
        guard let window else { return false }
        return now < window.expiresAt
    }

    /// Whole minutes until the last open shop closes (rounded up, floored at 1 so "Shop open — 0 min"
    /// never renders), or nil when none is open. Pure read — pair with `cleanupIfExpired()`.
    public func remainingWindowMinutes(at now: Date = Date()) -> Int? {
        guard let window, now < window.expiresAt else { return nil }
        return Self.wholeMinutes(until: window.expiresAt, from: now)
    }

    /// The friends' shops open at `now`, newest hangout first (and, within one hangout, the catalog
    /// received last first). Pure read: a lapsed shop is left out before `cleanupIfExpired()` drops it.
    public func openShops(at now: Date = Date()) -> [OpenShop] {
        guard !windows.isEmpty else { return [] }
        let open = peerCatalogs.compactMap { catalog -> OpenShop? in
            guard let window = windows[catalog.id], now < window.expiresAt else { return nil }
            return OpenShop(catalog: catalog, window: window)
        }
        return open.sorted(by: Self.isNewer)
    }

    /// Whole minutes from `now` until `end`, rounded up and floored at 1.
    static func wholeMinutes(until end: Date, from now: Date) -> Int {
        max(1, Int((end.timeIntervalSince(now) / 60).rounded(.up)))
    }

    /// The switcher's order: the later hangout first, then the catalog received later, then the id, so
    /// the order never wobbles between two reads.
    static func isNewer(_ lhs: OpenShop, _ rhs: OpenShop) -> Bool {
        if lhs.window.opensAt != rhs.window.opensAt { return lhs.window.opensAt > rhs.window.opensAt }
        if lhs.catalog.receivedAt != rhs.catalog.receivedAt { return lhs.catalog.receivedAt > rhs.catalog.receivedAt }
        return lhs.id < rhs.id
    }

    // MARK: - Inbound (called by ClothingShopExchange's registered handler)

    /// Accepts a verified `.clothingCatalog` envelope from a committed, unblocked peer. The caller
    /// (the shop exchange's handler, behind the mesh's committed-slot gate) has already enforced the
    /// committed-slot gate and the blocked-fingerprint drop (mirroring `.tempMessage`; the `.friendPhoto`
    /// dispatch this once named retired with P5 item 13); `verifiedFingerprint` is the
    /// transport-authenticated identity, never a wire-claimed value — catalogs are keyed by it exclusively.
    public func receiveCatalog(
        _ envelope: ProximityIdentityEnvelope,
        plaintext: Data,
        verifiedFingerprint: String,
        now: Date = Date()
    ) {
        // Payload-layer opt-out: inbound drops while sharing is off.
        guard isSharingEnabled else { return }
        guard envelope.payloadType == .clothingCatalog,
              let payload = try? JSONDecoder().decode(ClothingCatalogPayload.self, from: plaintext),
              payload.format == "fernlet.proximity.clothing.catalog",
              payload.version == 1 else { return }

        if let lastAccepted = lastAcceptedBySender[verifiedFingerprint],
           now.timeIntervalSince(lastAccepted) < Self.perSenderRateLimitSeconds {
            return
        }
        lastAcceptedBySender[verifiedFingerprint] = now

        // Never trust the wire: bound the item count to the shop maximum FIRST (the send side caps at the
        // same limit, so a larger array is a protocol violation / hostile amplification — decoding, mapping,
        // storing, and re-sorting an unbounded array on the main actor would be a remote DoS), then clamp
        // every kept item (texture dims/indices/palette, price, name) before holding it.
        var sanitized = payload
        sanitized.items = payload.items.prefix(ClothingShopLimits.maxListedItems).map { ClothingShopLimits.sanitizedForShop($0) }

        let catalog = ProximityClothingCatalog(
            senderDisplayName: envelope.senderDisplayName,
            senderFingerprint: verifiedFingerprint,
            senderSigningPublicKey: envelope.senderSigningPublicKey,
            receivedAt: now,
            payload: sanitized
        )
        // A seller met again keeps any hour still running until this session's end restarts it.
        peerCatalogs.removeAll { $0.id == catalog.id }
        peerCatalogs.insert(catalog, at: 0)
        awaitingSessionEnd.insert(catalog.id)
        evictOldestIfOverCap()
    }

    /// Holds at most `maxPeerCatalogs` sellers. One catalog arrives at a time, so the list is at most one
    /// over: the seller from the oldest hangout goes (``isOlder(_:than:)``), never one from the live
    /// session while an earlier hangout's shop is held.
    private func evictOldestIfOverCap() {
        guard peerCatalogs.count > Self.maxPeerCatalogs else { return }
        guard let oldest = peerCatalogs.min(by: { isOlder($0, than: $1) }) else { return }
        forget(oldest.id)
    }

    /// Whether `lhs` belongs to an earlier hangout than `rhs`: a shop from an ended session before one
    /// from the live session; among ended ones, the earlier hour; then the catalog received earlier.
    private func isOlder(_ lhs: ProximityClothingCatalog, than rhs: ProximityClothingCatalog) -> Bool {
        let lhsLive = awaitingSessionEnd.contains(lhs.id)
        let rhsLive = awaitingSessionEnd.contains(rhs.id)
        if lhsLive != rhsLive { return rhsLive }
        let lhsOpens = windows[lhs.id]?.opensAt ?? .distantFuture
        let rhsOpens = windows[rhs.id]?.opensAt ?? .distantFuture
        if lhsOpens != rhsOpens { return lhsOpens < rhsOpens }
        return lhs.receivedAt < rhs.receivedAt
    }

    /// Drops one seller: their catalog, their hour and their wait for a session's end.
    private func forget(_ id: String) {
        peerCatalogs.removeAll { $0.id == id }
        windows[id] = nil
        awaitingSessionEnd.remove(id)
    }

    // MARK: - Session lifecycle (called by the composition's session observer)

    /// A NEW session has FORMED — the first slot COMMIT after a no-session state (the spec's
    /// "'Next session start' = first slot COMMIT, not search start"). The shops already open stay open,
    /// each for the rest of its own hour (World Friends §3); what goes is any catalog still waiting for
    /// a session's end that never came (it has no hour to run) and the per-sender rate limiter's memory,
    /// so the fresh session accumulates cleanly. The caller (the composition's session observer, on the
    /// mesh's session-formation fact) fires this exactly once per formation; startJoin/startNewMesh
    /// (which run on every Social-tab entry / scene reactivation) must NOT call it, mirroring why
    /// `pendingFriendReview` deliberately survives them.
    public func beginNewSession() {
        let unopened = awaitingSessionEnd.filter { windows[$0] == nil }
        peerCatalogs.removeAll { unopened.contains($0.id) }
        awaitingSessionEnd.removeAll()
        lastAcceptedBySender.removeAll()
    }

    /// The last committed slot is gone (the same moment `pendingFriendReview` promotes): every seller
    /// whose catalog arrived in the session just ended gets their own 1-hour browse window from now.
    /// A seller's catalog marks them waiting only when it arrives, which needs a committed slot, so
    /// repeated teardown funnels with no intervening catalog find nobody waiting and can never extend
    /// an open window; and a seller met again restarts their hour here, over the catalog they re-sent.
    public func openWindowAtSessionEnd(now: Date = Date()) {
        cleanupIfExpired(now: now)
        guard !awaitingSessionEnd.isEmpty else { return }
        let window = Window(opensAt: now, expiresAt: now.addingTimeInterval(Self.windowDuration))
        for catalog in peerCatalogs where awaitingSessionEnd.contains(catalog.id) {
            windows[catalog.id] = window
        }
        awaitingSessionEnd.removeAll()
    }

    /// Lazy expiry: every shop whose hour has lapsed closes — its catalog and its hour go (memory-only
    /// state, gone an hour after its session regardless of anyone looking). A seller in the live session
    /// keeps the catalog they just sent; its next hour starts at that session's end. Safe to call any
    /// time.
    ///
    /// - Returns: The shops that closed, newest hangout first — the ones whose hours lapsed together, which
    ///   the shop page announces in one toast.
    @discardableResult
    public func cleanupIfExpired(now: Date = Date()) -> [OpenShop] {
        let lapsed = windows.filter { now >= $0.value.expiresAt }
        guard !lapsed.isEmpty else { return [] }
        let closed = peerCatalogs.compactMap { catalog -> OpenShop? in
            guard let window = lapsed[catalog.id], !awaitingSessionEnd.contains(catalog.id) else { return nil }
            return OpenShop(catalog: catalog, window: window)
        }
        for id in lapsed.keys { windows[id] = nil }
        let closedIDs = Set(closed.map(\.id))
        peerCatalogs.removeAll { closedIDs.contains($0.id) }
        if peerCatalogs.isEmpty { lastAcceptedBySender.removeAll() }
        return closed.sorted(by: Self.isNewer)
    }

    /// The opt-out's OFF transition (`setAllowNearbyClothingShares(false)`): drop every held catalog and
    /// close every shop immediately — WITHOUT touching the mesh radio, which belongs to the friend
    /// session lifecycle.
    public func clearAll() {
        windows.removeAll()
        peerCatalogs.removeAll()
        awaitingSessionEnd.removeAll()
        lastAcceptedBySender.removeAll()
    }
}
