import SwiftUI
import WorldMapStore

/// The system alert before one of Places you return to goes (`ref-del-confirm`), from its rename alert or
/// its long-press menu: "Delete <name>?", what goes and what stays, then Cancel and Delete. The name is the
/// one its row shows (the person's own, else Apple's, else "A place you return to").
struct WorldPlaceDeleteConfirmation: ViewModifier {
    /// The place being asked about; nil when no alert is up.
    @Binding var place: PlaceRecord?
    /// The names Apple Maps gave again for this look, by place id.
    let names: [UUID: WorldPlaceName]
    let onDelete: (PlaceRecord) -> Void

    func body(content: Content) -> some View {
        content.alert(Text(verbatim: title), isPresented: isPresented, presenting: place) { place in
            Button("Cancel", role: .cancel) {}
            Button(role: .destructive) { onDelete(place) } label: { Text(WorldPlacesDeleteCopy.confirmDelete) }
        } message: { place in
            Text(verbatim: WorldPlacesDeleteCopy.deletePlaceMessage(visits: place.visits))
        }
    }

    /// "Delete <name>?".
    private var title: String {
        place.map { WorldPlacesDeleteCopy.deletePlaceTitle(WorldPlacesCopy.placeTitle($0, name: names[$0.id])) } ?? ""
    }

    /// Whether the alert is up.
    private var isPresented: Binding<Bool> {
        Binding(get: { place != nil }, set: { if !$0 { place = nil } })
    }
}

/// The dialog a tap on one stop of a day's timeline opens (`ref-del-stop`, `ref-del-home`): "<name> ·
/// <time>", what deleting it does, then Delete this stop and Cancel.
struct WorldStopDeleteDialog: ViewModifier {
    /// The stop being asked about; nil when no dialog is up.
    @Binding var stop: PlaceStop?
    /// The stop's name as the timeline shows it.
    let title: (PlaceStop) -> String
    /// What deleting it does (``WorldPlacesDeleteCopy/stopMessage(_:place:name:homes:)``), or nil.
    let message: (PlaceStop) -> String?
    let onDelete: (PlaceStop) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(Text(verbatim: dialogTitle), isPresented: isPresented, titleVisibility: .visible,
                                   presenting: stop) { stop in
            Button(role: .destructive) { onDelete(stop) } label: { Text(WorldPlacesDeleteCopy.deleteStop) }
            Button("Cancel", role: .cancel) {}
        } message: { stop in
            if let message = message(stop) { Text(verbatim: message) }
        }
    }

    /// "Burger Barn · 8:52".
    private var dialogTitle: String {
        stop.map { WorldPlacesDeleteCopy.stopTitle(title($0), at: $0.at) } ?? ""
    }

    /// Whether the dialog is up.
    private var isPresented: Binding<Bool> {
        Binding(get: { stop != nil }, set: { if !$0 { stop = nil } })
    }
}
