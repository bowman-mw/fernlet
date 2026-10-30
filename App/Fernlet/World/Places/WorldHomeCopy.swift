import Foundation
import WorldMapStore

/// The words of round 6's places screens (owner-approved 2026-10-25: `ref-tag-*`, `ref-home-*`, `ref-hotel`,
/// `ref-places-map`), in the person's language. Spanish drafts are in the lane's file for the integrator.
nonisolated enum WorldHomeCopy {
    // MARK: Remember this place (ref-tag-home, ref-tag-name)

    static let rememberButton = LocalizedStringResource("worldTag.remember", defaultValue: "Remember this place",
                                                        comment: "World Home: the quiet button beside the blue button at a spot Fernlet didn't name; opens the naming sheet")
    static let notHere = LocalizedStringResource("worldTag.notHere", defaultValue: "Not here",
                                                 comment: "World Home, VoiceOver: the small ✕ beside Remember this place; Fernlet stops asking at this spot")
    static let sheetTitle = LocalizedStringResource("worldTag.sheet.title", defaultValue: "Remember this place",
                                                    comment: "Sheet title: naming a place yourself")
    static let pinHint = LocalizedStringResource("worldTag.pin.hint",
                                                 defaultValue: "The pin is where you're standing. Move the map if it's a little off.",
                                                 comment: "Remember this place sheet: under the small map")
    static let mapLabel = LocalizedStringResource("worldTag.map.label", defaultValue: "Map, pin at your spot",
                                                  comment: "Remember this place sheet, VoiceOver: the small map")
    static let nameLabel = LocalizedStringResource("worldTag.name", defaultValue: "Name",
                                                   comment: "Remember this place sheet: the label over the name field")
    static let tagNote = LocalizedStringResource("worldTag.note",
                                                 defaultValue: "Fernlet didn't name this spot, to be careful. If you add it, it joins your places on this iPhone only, and you can delete it in Where you've been.",
                                                 comment: "Remember this place sheet: the lock note")
    static let rememberIt = LocalizedStringResource("worldTag.save", defaultValue: "Remember it",
                                                    comment: "Remember this place sheet: the main button")

    // MARK: The sheet's three cases (round 7: ref-tag-name d2, ref-tag-unnamed, ref-tag-named)

    static let promptRefused = LocalizedStringResource("worldTag.prompt.refused", defaultValue: "Name it",
                                                       comment: "Remember this place sheet, at a spot Fernlet won't name: the empty name field's prompt")
    static let promptUnnamed = LocalizedStringResource("worldTag.prompt.unnamed", defaultValue: "Name it, like “Our flat”",
                                                       comment: "Remember this place sheet, at a spot with no Apple name: the empty name field's prompt (Spanish: Ponle nombre, como «Nuestro piso»)")
    static let unnamedLine = LocalizedStringResource("worldTag.unnamed.line",
                                                     defaultValue: "Fernlet has no name for this spot. Is it home? Pick Home below.",
                                                     comment: "Remember this place sheet, at a spot with no Apple name: under the name field; Home is a choice below it")
    static let namedLine = LocalizedStringResource("worldTag.named.line", defaultValue: "The name from Apple Maps. Change it if you like.",
                                                   comment: "Remember this place sheet, at a named place: under the name field, filled in from Apple Maps")
    static let keptNote = LocalizedStringResource("worldTag.note.kept",
                                                  defaultValue: "Kept on this iPhone only, like your other places. Rename or delete it any time in Where you've been.",
                                                  comment: "Remember this place sheet, at a spot Fernlet could name: the lock note")
    static let iconNote = LocalizedStringResource("worldTag.note.icon",
                                                  defaultValue: "Kept on this iPhone only. A restaurant you remember gets its icon on your map straight away.",
                                                  comment: "Remember this place sheet, at a restaurant: the lock note")

    // MARK: A photo with no place (ref-tag-photo)

    static let noPlace = LocalizedStringResource("worldTag.photo.noPlace", defaultValue: "No place, to be careful",
                                                 comment: "A Just you photo kept with no place: the line after its date")
    static let putOnMap = LocalizedStringResource("worldTag.photo.put", defaultValue: "Put on the map",
                                                  comment: "A Just you photo with no place: the small button, the sheet's title and its main button")
    static let photoHint = LocalizedStringResource("worldTag.photo.hint", defaultValue: "Move the map to where you took the photo.",
                                                   comment: "Put on the map sheet: under the small map; the pin starts where the map is")
    static let optional = LocalizedStringResource("worldTag.photo.optional", defaultValue: "Optional",
                                                  comment: "Put on the map sheet: the name field's prompt; a name is optional")

    // MARK: This is (ref-home-set)

    static let thisIs = LocalizedStringResource("worldHome.thisIs", defaultValue: "This is",
                                                comment: "Remember this place sheet: the label over A place / Home / Hotel")
    /// The lock note with Home picked: "…and Sprout gets a house here." (the companion's name).
    static func homeNote(companion: String) -> String {
        String(localized: "worldHome.note",
               defaultValue: "Home stays encrypted on this iPhone only. Fernlet uncovers the map for 1 km around it, and \(companion) gets a house here.",
               comment: "Remember this place sheet with Home picked: the lock note; the companion's name, e.g. Sprout")
    }
    static let hotelNote = LocalizedStringResource("worldHome.hotel.note",
                                                   defaultValue: "Your hotel stays encrypted on this iPhone only. Fernlet uncovers the map for 1 km around it until you check out or get home.",
                                                   comment: "Remember this place sheet with Hotel picked: the lock note")
    static let makeHome = LocalizedStringResource("worldHome.save", defaultValue: "Make it home",
                                                  comment: "Remember this place sheet with Home picked: the main button")
    static let checkInHere = LocalizedStringResource("worldHome.hotel.save", defaultValue: "Check in here",
                                                     comment: "Remember this place sheet with Hotel picked: the main button")
    static let replaceTitle = LocalizedStringResource("worldHome.replace.title", defaultValue: "Which home does this replace?",
                                                      comment: "Confirmation when a third home is made: up to two homes; the person picks one to replace")

    /// The kind's chip.
    static func kind(_ kind: WorldTagKind) -> LocalizedStringResource {
        switch kind {
        case .place: LocalizedStringResource("worldHome.kind.place", defaultValue: "A place", comment: "Remember this place sheet: This is · A place")
        case .home: LocalizedStringResource("worldHome.kind.home", defaultValue: "Home", comment: "Remember this place sheet: This is · Home")
        case .hotel: LocalizedStringResource("worldHome.kind.hotel", defaultValue: "Hotel", comment: "Remember this place sheet: This is · Hotel")
        }
    }

    /// "1 of 3": a This is chip's place in the row, read by VoiceOver after its name and "selected".
    static func kindPosition(_ index: Int, of count: Int) -> String {
        String(localized: "worldHome.kind.position", defaultValue: "\(index) of \(count)",
               comment: "Remember this place sheet, VoiceOver: a This is choice's place in the row, e.g. 'A place, selected, 1 of 3'")
    }

    /// "Up to 2 homes. This is your first." under the choice.
    static func homeCount(_ homes: Int) -> String {
        switch homes {
        case 0: String(localized: "worldHome.count.first", defaultValue: "Up to 2 homes. This is your first.",
                       comment: "Remember this place sheet with Home picked and no home yet")
        case 1: String(localized: "worldHome.count.second", defaultValue: "Up to 2 homes. This is your second.",
                       comment: "Remember this place sheet with Home picked and one home already")
        default: String(localized: "worldHome.count.full", defaultValue: "Up to 2 homes. This one replaces one of them.",
                        comment: "Remember this place sheet with Home picked and two homes already")
        }
    }

    /// "One hotel at a time. This replaces the Ace." under the choice, while a stay goes on.
    static func hotelReplaces(_ name: String) -> String {
        String(localized: "worldHome.hotel.replaces", defaultValue: "One hotel at a time. This replaces \(name).",
               comment: "Remember this place sheet with Hotel picked while another hotel stay goes on; the current hotel's name")
    }

    /// A home's name before the person changes it.
    static var defaultHomeName: String {
        String(localized: "worldHome.defaultName", defaultValue: "Home", comment: "The name a new home starts with; the person can change it")
    }
}

/// What the Remember this place sheet makes of the spot (`ref-home-set`: "This is: A place · Home ·
/// Hotel"). A display choice only; nothing stores it.
nonisolated enum WorldTagKind: String, CaseIterable, Identifiable, Sendable {
    case place
    case home
    case hotel

    var id: String { rawValue }
}
