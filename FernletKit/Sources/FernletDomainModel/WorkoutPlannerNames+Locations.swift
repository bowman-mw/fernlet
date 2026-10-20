// WorkoutPlannerNames+Locations.swift
// FernletDomainModel
//
// The built-in location names drawn in the user's language (2026-10-20, idea 16). A location is
// SAVED under an English name — "Full gym" and "Home" for the two defaults, a template's name
// ("Hotel gym") when one is added from the presets — and the user can rename it. The stored name is
// also how the location editor tells which presets are already saved (`availableTemplates`), and it
// is the trainer export's `locationName`. So the stored name never changes: a location whose name is
// still exactly a built-in English name draws it localized, and any other name, a rename included,
// draws as stored — the shape `StoredWorkoutName` gives workout names, with no schema change.

import Foundation

/// The localized names of the built-in locations and the location presets.
public nonisolated enum WorkoutLocationNames {

    /// The localized form of a built-in location name, or nil for any other name.
    public static func displayed(_ name: String) -> String? {
        switch name {
        case "Full gym": String(localized: "workoutLocation.fullGym", defaultValue: "Full gym", bundle: .module, comment: "Name of a built-in workout location: a gym with all the usual equipment")
        case "Home": String(localized: "workoutLocation.home", defaultValue: "Home", bundle: .module, comment: "Name of a built-in workout location: training at home")
        case "Hotel gym": String(localized: "workoutLocation.hotelGym", defaultValue: "Hotel gym", bundle: .module, comment: "Name of a workout location preset: a small hotel gym")
        case "Apartment gym": String(localized: "workoutLocation.apartmentGym", defaultValue: "Apartment gym", bundle: .module, comment: "Name of a workout location preset: the gym in an apartment building")
        case "Home setup": String(localized: "workoutLocation.homeSetup", defaultValue: "Home setup", bundle: .module, comment: "Name of a workout location preset: equipment kept at home")
        default: nil
        }
    }

    /// The localized subtitle of a location preset, by its id, or nil for an unknown id.
    static func subtitle(templateID: String) -> String? {
        switch templateID {
        case "full-gym": String(localized: "workoutLocation.fullGym.subtitle", defaultValue: "Commercial or studio", bundle: .module, comment: "Subtitle of the 'Full gym' location preset")
        case "hotel-gym": String(localized: "workoutLocation.hotelGym.subtitle", defaultValue: "Small, shared space", bundle: .module, comment: "Subtitle of the 'Hotel gym' location preset")
        case "apartment-gym": String(localized: "workoutLocation.apartmentGym.subtitle", defaultValue: "Building amenity", bundle: .module, comment: "Subtitle of the 'Apartment gym' location preset")
        case "home-setup": String(localized: "workoutLocation.homeSetup.subtitle", defaultValue: "Your own space", bundle: .module, comment: "Subtitle of the 'Home setup' location preset")
        default: nil
        }
    }
}

public extension WorkoutLocation {
    /// The name a screen draws for this location: ``name``, unless it is still a built-in English
    /// name, which is drawn in the user's language. Display only: the planner's note text may carry
    /// it, but nothing persists, exports or matches against it.
    var displayedName: String {
        WorkoutLocationNames.displayed(name) ?? name
    }

    /// The name to SAVE when a name field seeded with ``displayedName`` comes back as `typed`: the
    /// stored ``name`` while the drawn text is untouched, else what was typed. Opening the editor on a
    /// translated device never stores the translation.
    func savedName(editing typed: String) -> String {
        typed == displayedName ? name : typed
    }
}

public extension LocationTemplate {
    /// The preset's name on screen, localized. ``name`` is the English a saved location takes.
    var displayName: String {
        WorkoutLocationNames.displayed(name) ?? name
    }

    /// The preset's subtitle on screen, localized.
    var displaySubtitle: String {
        WorkoutLocationNames.subtitle(templateID: id) ?? subtitle
    }
}
