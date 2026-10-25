import FernletUI
import SwiftUI
import WorldMapStore

/// Why the Remember this place sheet is open.
nonisolated enum WorldPlaceSheetMode: Identifiable, Equatable {
    /// "Remember this place" at a spot Fernlet refused (`ref-tag-home` → `ref-tag-name`), or a home or
    /// hotel set from Settings (`ref-home-settings`), the pin starting at `start` with `kind` picked.
    case remember(start: GeoPoint, kind: WorldTagKind)
    /// "Put on the map" for a Just you photo that kept no place (`ref-tag-photo`).
    case photo(id: UUID, start: GeoPoint, takenAt: Date)
    /// A home or the hotel from Settings: move, rename or remove it; the hotel checks out.
    case edit(HomePlace)

    var id: String {
        switch self {
        case .remember(let start, let kind): "remember-\(kind.rawValue)-\(start.latitude),\(start.longitude)"
        case .photo(let id, _, _): "photo-\(id)"
        case .edit(let place): "edit-\(place.id)"
        }
    }
}

/// The sheet that keeps a place the person chose (approved 2026-10-25): `ref-tag-name` ("Remember this
/// place": a small map with the pin at their spot, their own name, the lock note, Remember it),
/// `ref-home-set` (its "This is: A place · Home · Hotel" row, "Make it home" or "Check in here"),
/// `ref-tag-photo` (titled "Put on the map", the pin starting where the map is, the name optional) and
/// Settings' edits of a home or the hotel (move, rename, remove, check out).
///
/// Fernlet never suggests Apple's name for a spot it refused: the name field starts empty (a home starts
/// as "Home"; a hotel stayed at before, within 150 m, starts with its own name). The pin is the small map's
/// middle: moving the map moves the spot. Full height, paper, Cancel top left.
struct WorldRememberPlaceSheet: View {
    var store: FernletStore
    let mode: WorldPlaceSheetMode
    let onClose: () -> Void
    @State private var camera: WorldCamera
    @State private var kind: WorldTagKind
    @State private var name: String
    @State private var choosesReplacement = false

    /// The sheet for `mode`.
    init(store: FernletStore, mode: WorldPlaceSheetMode, onClose: @escaping () -> Void) {
        self.store = store
        self.mode = mode
        self.onClose = onClose
        let start = Self.start(of: mode)
        _camera = State(initialValue: WorldCamera(center: start.point, distance: 450))
        _kind = State(initialValue: start.kind)
        _name = State(initialValue: start.name)
    }

    /// Where the pin starts, the kind picked and the name the field starts with, for `mode`.
    private static func start(of mode: WorldPlaceSheetMode) -> (point: GeoPoint, kind: WorldTagKind, name: String) {
        switch mode {
        case .remember(let point, let picked): (point, picked, picked == .home ? WorldHomeCopy.defaultHomeName : "")
        case .photo(_, let point, _): (point, .place, "")
        case .edit(let place): (place.point, place.kind == .home ? .home : .hotel, place.label)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    WorldPinMap(store: store, camera: $camera)
                    Text(mode.isPhoto ? WorldHomeCopy.photoHint : WorldHomeCopy.pinHint)
                        .font(FernletFramedFont.note)
                        .foregroundStyle(WorldPalette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    if mode.offersKind { kindRow }
                    SectionLabel(verbatim: String(localized: WorldHomeCopy.nameLabel)).padding(.top, 4)
                    TextField(text: $name, prompt: .fieldPrompt(verbatim: String(localized: mode.isPhoto ? WorldHomeCopy.optional : WorldHomeCopy.nameLabel))) {
                        Text(WorldHomeCopy.nameLabel)
                    }
                    .sheetTextInput()
                    .accessibilityIdentifier("worldTag.name")
                    FernletNotice(text: Text(verbatim: note)) { FernletIcon(.lock) }
                    if case .edit(let place) = mode { WorldBaseEditActions(store: store, place: place, onDone: onClose) }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }
            // The design's full-width primary ("Remember it", "Make it home", "Check in here").
            FernletSheetFooter {
                Button { save() } label: { Text(verbatim: saveLabel).frame(maxWidth: .infinity) }
                    .buttonStyle(ActionPillButtonStyle(.primary))
                    .disabled(!canSave)
                    .accessibilityIdentifier("worldTag.save")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SheetHeader(title: Text(verbatim: title), onCancel: onClose)
        }
        .fernletSheet()
        .confirmationDialog(Text(WorldHomeCopy.replaceTitle), isPresented: $choosesReplacement, titleVisibility: .visible) {
            ForEach(store.worldHomes.homes) { home in
                Button { saveHome(replacing: home.id) } label: { Text(verbatim: home.label) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: kind) { _, picked in kindChanged(picked) }
    }

    /// "This is: A place · Home · Hotel", and the line under it.
    private var kindRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(verbatim: String(localized: WorldHomeCopy.thisIs)).padding(.top, 4)
            HStack(spacing: 8) {
                ForEach(WorldTagKind.allCases) { option in
                    Button { kind = option } label: { Text(WorldHomeCopy.kind(option)) }
                        .buttonStyle(ChipButtonStyle(selected: kind == option))
                        .accessibilityAddTraits(kind == option ? .isSelected : [])
                }
            }
            if let line = kindLine {
                Text(verbatim: line)
                    .font(FernletFramedFont.note)
                    .foregroundStyle(WorldPalette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension WorldRememberPlaceSheet {
    /// The sheet's title.
    private var title: String {
        mode.isPhoto ? String(localized: WorldHomeCopy.putOnMap) : String(localized: WorldHomeCopy.sheetTitle)
    }

    /// The line under the kind: how many homes, or the hotel this one replaces.
    private var kindLine: String? {
        switch kind {
        case .place: return nil
        case .home: return WorldHomeCopy.homeCount(store.worldHomes.homes.count)
        case .hotel: return store.worldHomes.hotel.map { WorldHomeCopy.hotelReplaces($0.label) }
        }
    }

    /// The lock note for the kind.
    private var note: String {
        switch kind {
        case .place: String(localized: WorldHomeCopy.tagNote)
        case .home: WorldHomeCopy.homeNote(companion: store.worldCompanionName)
        case .hotel: String(localized: WorldHomeCopy.hotelNote)
        }
    }

    /// The main button's word.
    private var saveLabel: String {
        if mode.isPhoto { return String(localized: WorldHomeCopy.putOnMap) }
        if case .edit = mode { return String(localized: "Save") }
        switch kind {
        case .place: return String(localized: WorldHomeCopy.rememberIt)
        case .home: return String(localized: WorldHomeCopy.makeHome)
        case .hotel: return String(localized: WorldHomeCopy.checkInHere)
        }
    }

    /// Whether the main button works: a spot on the globe, and a name unless it is a photo's.
    private var canSave: Bool {
        camera.center.isValid && (mode.isPhoto || PlaceRecord.validLabel(name) != nil)
    }

    /// Picking Home starts the name as "Home"; picking Hotel near a hotel stayed at before starts it with
    /// that hotel's name. A name the person typed stays.
    private func kindChanged(_ picked: WorldTagKind) {
        let untouched = name.isEmpty || name == WorldHomeCopy.defaultHomeName
        guard untouched else { return }
        switch picked {
        case .home: name = WorldHomeCopy.defaultHomeName
        case .hotel:
            name = store.worldHomes.pastHotels.first { $0.point.distance(to: camera.center) <= HomeBook.sameHotelRadius }?.label ?? ""
        case .place: name = ""
        }
    }

    /// Keeps the spot as the mode and kind say, then closes.
    private func save() {
        let point = camera.center
        switch (mode, kind) {
        case (.photo(let id, _, let takenAt), _):
            finish(store.putSoloPhotoOnMap(id, at: point, named: name, takenAt: takenAt))
        case (.edit(let place), _):
            var moved = place
            moved.label = PlaceRecord.validLabel(name) ?? place.label
            moved.point = point
            finish(place.kind == .home ? store.saveWorldHome(moved) : store.checkInWorldHotel(moved))
        case (_, .place): finish(store.rememberWorldPlace(named: name, at: point))
        case (_, .home):
            guard store.worldHomes.homes.count < HomeBook.maxHomes else {
                choosesReplacement = true
                return
            }
            saveHome(replacing: nil)
        case (_, .hotel): finish(store.checkInWorldHotel(HomePlace(kind: .hotel, label: name, point: point)))
        }
    }

    /// Makes the spot a home, in place of `replacing` when two are kept.
    private func saveHome(replacing: UUID?) {
        finish(store.saveWorldHome(HomePlace(kind: .home, label: name, point: camera.center), replacing: replacing))
    }

    /// Plays the outcome and closes.
    private func finish(_ saved: Bool) {
        FernletFeedback.system.play(saved ? .done : .failed)
        onClose()
    }
}

extension WorldPlaceSheetMode {
    /// Whether this is a photo's "Put on the map".
    var isPhoto: Bool {
        if case .photo = self { return true }
        return false
    }

    /// Whether the "This is" row shows: only while remembering a spot.
    var offersKind: Bool {
        if case .remember = self { return true }
        return false
    }
}

/// The small framed map on the sheet (170 pt): Apple's muted map with the fog the person lifted, and the
/// pixel pin fixed in its middle, so moving the map moves the spot. VoiceOver reads it as "Map, pin at
/// your spot"; the spot starts where they stand, which needs no moving.
struct WorldPinMap: View {
    var store: FernletStore
    @Binding var camera: WorldCamera
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        WorldMapStack(kind: .appleMuted, camera: $camera,
                      ground: WorldGround(lifted: store.duressSessionActive ? [] : store.worldFog.visibleCells),
                      phase: .day, darkMode: colorScheme == .dark, creditInset: 6) { _, size in
            WorldSpriteView(sprite: WorldSprites.pin, scale: 4)
                .position(x: size.width / 2, y: size.height / 2 - 14)
                .allowsHitTesting(false)
        }
        .frame(height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(WorldPalette.ink, lineWidth: 2))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(WorldHomeCopy.mapLabel))
        .accessibilityIdentifier("worldTag.map")
    }
}

/// A home's or the hotel's edit actions on the sheet from Settings: the hotel checks out (remembered for a
/// welcome back); either can be removed (its circle fogs again except where the person has been).
struct WorldBaseEditActions: View {
    var store: FernletStore
    let place: HomePlace
    let onDone: () -> Void

    var body: some View {
        FernletFramedSection(header: nil) {
            if place.kind == .hotel {
                Button {
                    FernletFeedback.system.play(store.checkOutWorldHotel() ? .done : .failed)
                    onDone()
                } label: { FernletRowLabel(title: Text(WorldHomeSettingsCopy.checkOut)) }
                .buttonStyle(FernletRowButtonStyle(showsChevron: false))
                .accessibilityIdentifier("worldHome.checkOut")
            }
            Button {
                FernletFeedback.system.play(store.removeWorldHome(place.id) ? .done : .failed)
                onDone()
            } label: { FernletRowLabel(title: Text(WorldHomeSettingsCopy.remove(place.kind)), destructive: true) }
            .buttonStyle(FernletRowButtonStyle(showsChevron: false))
            .accessibilityIdentifier("worldHome.remove")
        }
        .padding(.top, 6)
    }
}
