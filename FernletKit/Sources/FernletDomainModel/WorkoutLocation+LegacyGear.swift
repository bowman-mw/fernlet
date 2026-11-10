// WorkoutLocation+LegacyGear.swift
// FernletDomainModel
//
// How a location saved before each machine had its own row (2026-11-10, the owner's fix e5) is
// read. Until then one leg press or chest press unlocked every machine exercise, a ticked barbell
// was all a barbell lift asked for, and Dip, Inverted row and Ab wheel asked for nothing. The new
// list is stricter, and a stricter list must not silently take away the exercises a person has
// been doing at a space they set up months ago. So a location with no `equipmentListVersion` is
// read ONCE, as it decodes, through `legacyGearGrant(for:)`: the pieces its old ticks stood for
// are ticked for it, the checklist shows them ticked, and from the next save on the list is
// literal (the version is written, so the grant never runs twice and an unticked machine stays
// unticked).
//
// What is deliberately NOT granted, because the old unlock was the mistake being fixed and the
// stricter reading is the safer one: a Smith machine, plates or a rack alone no longer stand for a
// barbell, and Dip, Inverted row and Ab wheel need their gear at every space that did not tick
// everything. When that leaves a saved space's day short, the planner's fill says so
// (`WorkoutProgram+Fill.swift`, the owner's fix s3).

import Foundation

public extension WorkoutLocation {
    /// The equipment list in which each machine has its own row (2026-11-10). FROZEN number.
    static let itemizedListVersion = 2

    /// The pieces a location saved before ``itemizedListVersion`` is read as owning on top of the
    /// ones it ticked — empty for a location that needs none.
    ///
    /// - A location with every one of the 22 older pieces is the Full gym preset (the default
    ///   location every install starts with): it gets the whole list, as that preset does now.
    /// - A location that ticked a leg press or a chest press — the two pieces that used to unlock
    ///   every machine exercise — gets every machine that had no row of its own, and the leg press
    ///   (a chest press alone used to unlock Leg press). The chest press and the Smith machine are
    ///   not granted: their exercises always named them.
    /// - A location that ticked the barbell gets the plates its barbell lifts now name.
    static func legacyGearGrant(for ticked: Set<GymEquipment>) -> Set<GymEquipment> {
        guard !ticked.isSuperset(of: GymEquipment.originalPieces) else {
            return Set(GymEquipment.allCases).subtracting(ticked)
        }
        var grant: Set<GymEquipment> = []
        if ticked.contains(.legPress) || ticked.contains(.chestPress) {
            grant.formUnion(GymEquipment.itemizedMachines)
            grant.insert(.legPress)
        }
        if ticked.contains(.barbell) { grant.insert(.weightPlates) }
        return grant.subtracting(ticked)
    }
}
