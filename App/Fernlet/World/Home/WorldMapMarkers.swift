import FernletConnections
import FernletDomainModel
import FernletSocial
import FernletUI
import ProximityKit
import SwiftUI
import WorldMapStore

/// A marker on the map (design `b1-markers`, approved 2026-10-23): a pixel sprite where something of the
/// person's own is, with a crisp name tag.
///
/// This round draws the markers the phone has data for: the person's **workout spaces**, at the pins set
/// at their first guided workout there (`SpacePinStore`), and the person's own **solo photos** where they were taken
/// (``WorldPhotoMarkerView``, step 5c). Favourite restaurants, places friends shared and named trail starts wait
/// for the data behind them (a later round). Never friends' photos.
nonisolated struct WorldMapMarker: Equatable, Identifiable, Sendable {
    /// What the marker is.
    enum Kind: Equatable, Sendable {
        /// A workout space of the person's own.
        case space
    }

    let id: UUID
    let kind: Kind
    let name: String
    let point: GeoPoint

    /// The space whose marker is nearest a precise `fix` within the pins' match radius (100 m), or nil.
    /// In memory, over markers already read: the blue button asks on every map update.
    @MainActor
    static func space(near fix: WorldFix?, in markers: [WorldMapMarker]) -> UUID? {
        guard let fix, fix.isPrecise else { return nil }
        return markers.filter { $0.kind == .space }
            .map { (id: $0.id, metres: $0.point.distance(to: fix.point)) }
            .filter { $0.metres <= SpacePinStore.matchRadius }
            .min { $0.metres < $1.metres }?.id
    }
}

extension FernletStore {
    /// The person's pinned workout spaces as map markers, nearest to `fix` first (VoiceOver's order).
    /// None in a decoy, and none that cannot be read now.
    func worldSpaceMarkers(near fix: WorldFix?) -> [WorldMapMarker] {
        guard !duressSessionActive else { return [] }
        let pins: [UUID: GeoPoint]
        do {
            pins = try worldSpacePins.all()
        } catch {
            return []
        }
        let markers = settings.workoutLocations.compactMap { location -> WorldMapMarker? in
            guard let point = pins[location.id] else { return nil }
            return WorldMapMarker(id: location.id, kind: .space, name: location.displayedName, point: point)
        }
        guard let here = fix?.point else { return markers }
        return markers.sorted { here.distance(to: $0.point) < here.distance(to: $1.point) }
    }
}

/// One marker on the map: its sprite over its name tag, one button named for the place. Tapping it
/// opens its card.
struct WorldMapMarkerView: View {
    let marker: WorldMapMarker
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 4) {
                WorldSpriteView(sprite: WorldSprites.pin, scale: 3)
                WorldNameTag(name: marker.name)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: marker.name))
        .accessibilityIdentifier("world.marker.space")
    }
}

/// A crisp name tag on the map (the kit's tag: paper in a 3-pt ink frame, 15 pt bold).
struct WorldNameTag: View {
    let name: String

    var body: some View {
        Text(verbatim: name)
            .font(Font.custom(FernletFontName.dmSansBold, size: 15, relativeTo: .subheadline))
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .foregroundStyle(WorldPalette.bark)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(WorldPalette.paperLight, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorldPalette.ink, lineWidth: 3))
    }
}

/// A friend nearby, beside the companion (design `b1-home-friend`, draft 2): their companion with their
/// first name only. It comes from the presence radio's "nearby" set, which already says who is in
/// radio range and nothing about where: so it is drawn beside your companion, never at a position,
/// with no distance, and it goes when they leave range, with no trail.
nonisolated struct WorldNearbyFriend: Equatable, Identifiable, Sendable {
    let id: String
    let firstName: String
}

extension FernletStore {
    /// Friends the presence radio hears nearby right now, by first name (at most two; none in a decoy).
    var worldNearbyFriends: [WorldNearbyFriend] {
        guard !duressSessionActive, settings.allowNearbyPresence else { return [] }
        let presence = presenceManager
        return trustedProximityPeers
            .filter { presence.isReachable(fingerprint: $0.fingerprint) }
            .prefix(Self.worldNearbyFriendLimit)
            .map { WorldNearbyFriend(id: $0.fingerprint,
                                     firstName: PeerNameDisplay.firstName($0.displayName, fingerprint: $0.fingerprint,
                                                                          placeholder: .met, in: .fernlet)) }
    }

    /// The most friends drawn beside the companion.
    static let worldNearbyFriendLimit = 2
}

/// A nearby friend's companion and name tag. VoiceOver: "Sam, nearby."
struct WorldNearbyFriendView: View {
    let friend: WorldNearbyFriend

    var body: some View {
        VStack(spacing: 4) {
            WorldCompanionSprite(state: .thriving,
                                 look: WorldCompanionLook(appearance: .standard, state: .thriving, asleep: false),
                                 isActive: false)
            WorldNameTag(name: friend.firstName)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Self.spoken(friend)))
        .accessibilityInputLabels([Text(verbatim: friend.firstName)])
        .accessibilityIdentifier("world.friend")
    }

    /// What VoiceOver says: "Sam, nearby."
    static func spoken(_ friend: WorldNearbyFriend) -> String {
        String(localized: "worldFriend.nearby", defaultValue: "\(friend.firstName), nearby",
               comment: "World Home, VoiceOver: a friend's companion beside yours; their first name")
    }
}
