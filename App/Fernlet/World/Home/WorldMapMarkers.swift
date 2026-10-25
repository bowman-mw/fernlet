import FernletConnections
import FernletDomainModel
import FernletSocial
import FernletUI
import ProximityKit
import SwiftUI
import WorldMapStore

/// A marker on the map (design `b1-markers`, approved 2026-10-23; `ref-places-map`, approved 2026-10-25): a
/// pixel icon on a cream tile where a place of the person's own is, with a crisp name tag.
///
/// The markers the phone has data for: the person's **workout spaces**, at the pins set at their first
/// guided workout there (`SpacePinStore`), drawn as a dumbbell, and their **favourite places to eat** (three
/// meals or more logged there, "Remember places I eat out"), drawn as a bowl, in place of the approved star
/// and space pin, with no limit. Each uncovers the map about ``uncoverRadius`` around it (drawn, never
/// written into the fog). The person's own **solo photos** taken at one of them sit on its icon as a small
/// print, newest on top with a count; photos taken anywhere else keep their own marker
/// (``WorldPhotoMarkerView``, step 5c). Places friends shared and named trail starts wait for the data behind
/// them. Never friends' photos.
nonisolated struct WorldMapMarker: Equatable, Identifiable, Sendable {
    /// How far around a kept place the map is uncovered, in metres ("not as much as a home or hotel").
    static let uncoverRadius = 300.0
    /// How near a photo must be to a kept place to sit on its icon, in metres.
    static let photoRadius = 75.0

    /// What the marker is.
    enum Kind: Equatable, Sendable {
        /// A workout space of the person's own.
        case space
        /// A favourite place to eat (Apple's reference, for its name).
        case eatingPlace(placeID: String)
    }

    let id: UUID
    let kind: Kind
    let name: String
    let point: GeoPoint
    /// The person's own photos taken here, when any have shown (newest first).
    var photos: WorldPhotoPlace? = nil

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

    /// Every kept place's marker (`ref-places-map`): the pinned workout spaces and the favourite places to
    /// eat, nearest to `fix` first, each with the solo photos taken there; and the photos taken anywhere
    /// else, on their own markers. None in a decoy.
    func worldPlaceMarkers(near fix: WorldFix?) -> (markers: [WorldMapMarker], loosePhotos: [WorldPhotoPlace]) {
        guard !duressSessionActive else { return ([], []) }
        let eating = worldPlaces.eatingPlaces.filter(\.isFavourite).map { place in
            WorldMapMarker(id: place.id, kind: .eatingPlace(placeID: place.placeID),
                           name: place.label ?? worldPlaces.eatingNames[place.id] ?? "", point: place.point)
        }
        var markers = worldSpaceMarkers(near: nil) + eating
        // DEBUG scene `places` (`ref-places-map`): three kept places round the person, display only.
        if WorldPlacesTestScenes.scenes.contains("places"), let fix = worldLocation.latest {
            markers += WorldPlacesTestScenes.markers(near: fix.point)
        }
        var loose: [WorldPhotoPlace] = []
        for group in worldPhotoMarkers(near: nil) {
            guard let index = markers.indices.min(by: { markers[$0].point.distance(to: group.point) < markers[$1].point.distance(to: group.point) }),
                  markers[index].point.distance(to: group.point) <= WorldMapMarker.photoRadius else {
                loose.append(group)
                continue
            }
            let held = markers[index].photos?.photoIDs ?? []
            markers[index].photos = WorldPhotoPlace(id: markers[index].photos?.id ?? group.id, point: markers[index].point,
                                                    photoIDs: held + group.photoIDs)
        }
        guard let here = fix?.point else { return (markers, loose) }
        return (markers.sorted { here.distance(to: $0.point) < here.distance(to: $1.point) },
                loose.sorted { here.distance(to: $0.point) < here.distance(to: $1.point) })
    }

    /// The cells drawn uncovered around the homes, the hotel and the kept places (round 6): 1 km round a
    /// home or the hotel, about 300 m round a place to eat or train. Drawn only, never written into the fog.
    func worldUncoveredCells(markers: [WorldMapMarker]) -> Set<HexCell> {
        guard !duressSessionActive else { return [] }
        var cells = Set<HexCell>()
        for base in worldHomes.bases { cells.formUnion(MercatorHexGrid.disc(around: base.point, radius: HomeBook.uncoverRadius)) }
        for marker in markers { cells.formUnion(MercatorHexGrid.disc(around: marker.point, radius: WorldMapMarker.uncoverRadius)) }
        return cells
    }
}

/// One kept place on the map (`ref-places-map`): its icon (a bowl or a dumbbell) on a cream tile, the
/// photos taken there on top as a small print with a count when there are more than one, and its name
/// tag, one button. Tapping it opens those photos when there are any, else its card. VoiceOver: "Hoshi
/// Noodle Bar, a restaurant. 3 of your photos." / "Full gym, a gym".
struct WorldMapMarkerView: View {
    let marker: WorldMapMarker
    /// A place to eat's name as Apple Maps gave it again (in memory), when the person hasn't named it.
    var resolvedName: String? = nil
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 4) {
                WorldPlaceIconTile(marker: marker)
                if !name.isEmpty { WorldNameTag(name: name) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: WorldPlaceIconCopy.spoken(marker, name: name)))
        .accessibilityIdentifier(marker.kind == .space ? "world.marker.space" : "world.marker.eating")
    }

    /// The tag's name: the marker's own, else the one Apple Maps gave again.
    private var name: String {
        marker.name.isEmpty ? (resolvedName ?? "") : marker.name
    }
}

/// The cream tile with the place's icon and, on its corner, the photos taken there.
struct WorldPlaceIconTile: View {
    let marker: WorldMapMarker

    var body: some View {
        ZStack(alignment: .topTrailing) {
            WorldSpriteView(sprite: marker.kind == .space ? WorldPlaceSprites.dumbbell : WorldPlaceSprites.bowl, scale: 2)
                .frame(width: 34, height: 34)
                .background(WorldPalette.paperLight, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorldPalette.ink, lineWidth: 3))
                .shadow(color: WorldPalette.ink.opacity(0.3), radius: 0, x: 0, y: 3)
            if let photos = marker.photos, !photos.photoIDs.isEmpty {
                WorldMiniPrint(count: photos.photoIDs.count)
                    .offset(x: 16, y: -18)
            }
        }
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// A photo print on a place's icon (newest on top), with a count badge when it holds more than one. Drawn,
/// never decoded from the photo itself (the map draws no one's picture on its tiles).
struct WorldMiniPrint: View {
    let count: Int

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Rectangle()
                .fill(WorldPalette.rgb(0xE2C08E))
                .frame(width: 20, height: 15)
                .padding(EdgeInsets(top: 3, leading: 3, bottom: 6, trailing: 3))
                .background(WorldPalette.rgb(0xFFFDF8))
                .rotationEffect(.degrees(6))
                .shadow(color: WorldPalette.ink.opacity(0.35), radius: 2, x: 0, y: 2)
            if count > 1 {
                Text(count, format: .number)
                    .font(Font.custom(FernletFontName.dmSansBold, size: 11, relativeTo: .caption2))
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(WorldPalette.rgb(0x46683A), in: Capsule())
                    .overlay(Capsule().strokeBorder(WorldPalette.rgb(0xFFFDF8), lineWidth: 2))
                    .offset(x: 6, y: -6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// What VoiceOver says for a kept place's icon (`ref-places-map`).
nonisolated enum WorldPlaceIconCopy {
    /// "Hoshi Noodle Bar, a restaurant. 3 of your photos." / "Full gym, a gym".
    static func spoken(_ marker: WorldMapMarker, name shown: String) -> String {
        let name = shown.isEmpty ? String(localized: unnamedPlace) : shown
        let place: String
        switch marker.kind {
        case .space: place = String(localized: "worldMarker.gym", defaultValue: "\(name), a gym",
                                    comment: "World Home, VoiceOver: a workout space's icon on the map; its name")
        case .eatingPlace: place = String(localized: "worldMarker.restaurant", defaultValue: "\(name), a restaurant",
                                          comment: "World Home, VoiceOver: a favourite place to eat on the map; its name")
        }
        guard let count = marker.photos?.photoIDs.count, count > 0 else { return place }
        let photos = String(localized: "worldMarker.yourPhotos", defaultValue: "\(count) of your photos.",
                            comment: "World Home, VoiceOver: after a place's name, how many of the person's own photos were taken there. Plural on the number (1 of your photos.)")
        return "\(place). \(photos)"
    }

    /// A place to eat whose name can't be had (offline, and not named by the person).
    static let unnamedPlace = LocalizedStringResource("worldMarker.unnamedEating", defaultValue: "A place you eat",
                                                      comment: "World Home: a favourite place to eat whose name can't be shown (offline) and that the person hasn't named")
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
