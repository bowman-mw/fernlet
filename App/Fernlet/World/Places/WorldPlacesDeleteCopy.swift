import Foundation
import WorldMapStore

/// The words of deleting one place, or one stop, in Where you've been (W-14, Refinements group 18,
/// owner-approved 2026-10-26: `ref-del-alert`, `ref-del-menu`, `ref-del-confirm`, `ref-del-stop`,
/// `ref-del-home`), in the person's language. Spanish drafts are in the lane's file for the integrator.
nonisolated enum WorldPlacesDeleteCopy {
    // MARK: One place (ref-del-alert, ref-del-menu, ref-del-confirm)

    /// The rename alert's button, the row's long-press menu item and its VoiceOver action.
    static let deletePlace = LocalizedStringResource("privatePlaces.deletePlace", defaultValue: "Delete this place",
                                                     comment: "Private, Places: deletes one of Places you return to, with every stop there (Spanish: Borrar este lugar)")
    /// The row's VoiceOver action that opens the rename alert.
    static let rename = LocalizedStringResource("privatePlaces.rename.action", defaultValue: "Rename",
                                                comment: "Private, Places, VoiceOver and Voice Control: the action on a place you return to that renames it")
    /// The confirmation's destructive button.
    static let confirmDelete = LocalizedStringResource("privatePlaces.deletePlace.confirm", defaultValue: "Delete",
                                                       comment: "Private, Places: the destructive button confirming one place's delete (Spanish: Borrar, as Places says it)")

    /// "Delete Burger Barn?": the confirmation's title, with the name the row shows.
    static func deletePlaceTitle(_ name: String) -> String {
        String(localized: "privatePlaces.deletePlace.title", defaultValue: "Delete \(name)?",
               comment: "Private, Places: the title confirming one place's delete; the name is the one its row shows")
    }

    /// What deleting the place does, with its visit count.
    static func deletePlaceMessage(visits: Int) -> String {
        String(localized: "privatePlaces.deletePlace.message",
               defaultValue: "It leaves Places you return to with its \(visits) visits, and its stops leave the last 30 days. Anything you logged there stays.",
               comment: "Private, Places: what deleting one place does. Plural on the number (its 1 visit)")
    }

    // MARK: One stop (ref-del-stop, ref-del-home)

    /// The stop's dialog button and its VoiceOver action.
    static let deleteStop = LocalizedStringResource("privatePlaces.deleteStop", defaultValue: "Delete this stop",
                                                    comment: "Private, Places: deletes one stop on a day's timeline (Spanish: Borrar esta parada)")

    /// "Burger Barn · 8:52": the stop's dialog title, its name as the timeline shows it and its time.
    static func stopTitle(_ name: String, at date: Date) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        return String(localized: "privatePlaces.deleteStop.title", defaultValue: "\(name) · \(time)",
                      comment: "Private, Places: the title of one stop's delete dialog: the stop's name, a middle dot, its time (e.g. 'Burger Barn · 8:52')")
    }

    /// What deleting `stop` does: for a visit, what is left on its place (`place`, shown as `name`); for a
    /// walk, run or bike ride, its line; for a leave or a return, that the home or hotel stays. Nil for a visit whose
    /// place is already gone.
    static func stopMessage(_ stop: PlaceStop, place: PlaceRecord?, name: String, homes: HomeBook) -> String? {
        switch stop.kind {
        case .visit:
            guard let place else { return nil }
            let left = max(0, place.visits - 1)
            return left == 0 ? lastVisit(name) : visitsStay(name, left: left)
        case .walk, .run:
            return String(localized: "privatePlaces.deleteStop.line", defaultValue: "Its line leaves the day's sketch. The workout stays in Move.",
                          comment: "Private, Places: deleting a walk or run from a day's timeline; its saved line goes, the workout stays")
        case .ride:
            return String(localized: "privatePlaces.deleteStop.line.ride", defaultValue: "Its line leaves the day's sketch. The ride stays in Move.",
                          comment: "Private, Places: deleting a bike ride from a day's timeline; its saved line goes, the cycling workout stays in Move (Spanish draft: Su línea sale del dibujo del día. El paseo en bici se queda en Moverse.)")
        case .leftHome, .cameHome:
            return stop.placeID.flatMap(homes.place)?.kind == .hotel ? hotelStays : homeStays
        }
    }

    /// The place has no other visit.
    private static func lastVisit(_ name: String) -> String {
        String(localized: "privatePlaces.deleteStop.lastVisit",
               defaultValue: "Takes 1 visit off \(name). It has no other visits, so it leaves Places you return to too.",
               comment: "Private, Places: deleting a place's only visit from the timeline; the place leaves Places you return to")
    }

    /// The place keeps `left` visits.
    private static func visitsStay(_ name: String, left: Int) -> String {
        String(localized: "privatePlaces.deleteStop.visitsStay", defaultValue: "Takes 1 visit off \(name); \(left) stay.",
               comment: "Private, Places: deleting one visit from the timeline; the number is the visits the place keeps. Plural on the number (1 stays, 2 stay)")
    }

    /// A leave or a return at a home.
    private static var homeStays: String {
        String(localized: "privatePlaces.deleteStop.home",
               defaultValue: "Only this stop goes. Your home stays: change or remove it in Settings › Home map.",
               comment: "Private, Places: deleting a 'you left' or 'you got back' stop at a home; the home is not deleted")
    }

    /// A leave or a return at the hotel.
    private static var hotelStays: String {
        String(localized: "privatePlaces.deleteStop.hotel",
               defaultValue: "Only this stop goes. Your hotel stays: change or remove it in Settings › Home map.",
               comment: "Private, Places: deleting a 'you left' or 'you got back' stop at the hotel; the hotel is not deleted")
    }
}

/// What can be done to one of Places you return to from its row (W-14): the long-press menu's items and
/// VoiceOver's actions, in their order. Voice Control says the same names.
nonisolated enum WorldPlaceRowAction: Hashable, Sendable {
    /// Opens the rename alert.
    case rename
    /// Opens the place in Apple Maps by its reference.
    case openInMaps
    /// Asks to delete the place.
    case delete

    /// VoiceOver's actions on the row: Rename, Open in Apple Maps (with Apple's reference), Delete this place.
    static func spoken(for place: PlaceRecord) -> [WorldPlaceRowAction] {
        place.placeID == nil ? [.rename, .delete] : [.rename, .openInMaps, .delete]
    }

    /// The row's long-press menu: Open in Apple Maps (with Apple's reference), then Delete this place.
    static func menu(for place: PlaceRecord) -> [WorldPlaceRowAction] {
        place.placeID == nil ? [.delete] : [.openInMaps, .delete]
    }

    /// The action's name.
    var title: LocalizedStringResource {
        switch self {
        case .rename: WorldPlacesDeleteCopy.rename
        case .openInMaps: WorldPlacesCopy.openInMaps
        case .delete: WorldPlacesDeleteCopy.deletePlace
        }
    }

    /// The menu item's symbol, or nil for none.
    var symbol: String? {
        switch self {
        case .rename: nil
        case .openInMaps: "map"
        case .delete: "trash"
        }
    }

    /// Whether it deletes.
    var isDestructive: Bool { self == .delete }
}

/// The rename alert's buttons after its text field (`ref-del-alert`), in their order: Save, Make it home,
/// Open in Apple Maps (only with Apple's reference), Delete this place, Cancel.
nonisolated enum WorldPlaceRenameButton: Hashable, Sendable {
    /// Saves the new name.
    case save
    /// Opens Remember this place to make it a home.
    case makeHome
    /// Opens the place in Apple Maps.
    case openInMaps
    /// Asks to delete the place.
    case delete
    /// Closes the alert.
    case cancel

    /// The buttons for `place`, in order.
    static func order(for place: PlaceRecord) -> [WorldPlaceRenameButton] {
        place.placeID == nil ? [.save, .makeHome, .delete, .cancel] : [.save, .makeHome, .openInMaps, .delete, .cancel]
    }
}
