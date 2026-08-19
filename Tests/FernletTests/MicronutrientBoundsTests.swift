// MicronutrientBoundsTests.swift
// FernletTests
//
// M11: micronutrient amounts arrive from two untrusted sources — a peer's `.saved` recipe payload
// and a web page's JSON-LD nutrition label — and were carried into the synced snapshot unbounded.
// Two independent halves are under test here:
//
//  * the WIRE half (`Micronutrients.sanitizedForImport()`), which drops an implausible amount to
//    "not measured" rather than clamping it to a fabricated number, and
//  * the PRESENTATION half, which must be TOTAL: `Int(_: Double)` traps outside `Int`'s range, and a
//    day record poisoned before the wire fix existed is already persisted and CloudKit-synced. A
//    wire fix cannot heal it, so the renderers themselves have to survive it.

import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

@MainActor
struct MicronutrientBoundsTests {

    // MARK: - Wire half

    @Test func micronutrientsSanitizeDropsImplausibleAmounts() {
        let hostile = Micronutrients(fiber: 12, iron: -3, sodium: 1e300)

        let clean = hostile.sanitizedForImport()

        #expect(clean.fiber == 12, "An honest amount must survive untouched")
        #expect(clean.iron == nil, "A negative amount is not a measurement")
        #expect(clean.sodium == nil, "Dropped, NOT clamped — clamping would persist a fabricated value")
    }

    @Test func micronutrientsSanitizeKeepsTheBoundaryValueAndDropsNonFinite() {
        let atLimit = Micronutrients(sodium: SharedRecipeLimits.maxMicronutrientAmount).sanitizedForImport()
        #expect(atLimit.sodium == SharedRecipeLimits.maxMicronutrientAmount, "The bound is inclusive")

        let overLimit = Micronutrients(sodium: SharedRecipeLimits.maxMicronutrientAmount + 1).sanitizedForImport()
        #expect(overLimit.sodium == nil)

        let nonFinite = Micronutrients(fiber: .infinity, sugar: .nan).sanitizedForImport()
        #expect(nonFinite.fiber == nil)
        #expect(nonFinite.sugar == nil)
    }

    // MARK: - Presentation half (the renderers that trap)

    /// The day-detail row: `Int(value.rounded())` traps for 1e300, and the row is built from a SUM
    /// of persisted meal snapshots, so the input can already be poisoned on disk.
    @Test func dayMicronutrientRowFormatsHostileValueWithoutTrapping() {
        let hostile = DayMicronutrientBreakdownRow(
            name: "Sodium", value: 1e300, target: 2300, unit: "mg", isLimit: true)
        #expect(!hostile.displayValue.isEmpty)

        let infinite = DayMicronutrientBreakdownRow(
            name: "Sodium", value: .infinity, target: 2300, unit: "mg", isLimit: true)
        #expect(infinite.displayValue == "—mg", "A non-finite total reads as unknown, not as a number")

        let negative = DayMicronutrientBreakdownRow(
            name: "Fiber", value: -1, target: 30, unit: "g", isLimit: false)
        #expect(negative.displayValue == "0g")

        let honest = DayMicronutrientBreakdownRow(
            name: "Fiber", value: 12.5, target: 30, unit: "g", isLimit: false)
        #expect(honest.displayValue == "12.5g", "The clamp must not change an ordinary reading")
    }

    /// The HOME tab's fiber footer — the same trap on the app's first screen, so a single poisoned
    /// meal would crash on render rather than merely on opening a day.
    @Test func fiberFooterSurvivesHostileTotal() {
        #expect(MacroCard.fiberFooterText(intake: 1e300, target: 30) == "Fiber 1000000000g of 30g")
        #expect(MacroCard.fiberFooterText(intake: .infinity, target: 30) == "Fiber target 30g")
        #expect(MacroCard.fiberFooterText(intake: nil, target: 30) == "Fiber target 30g")
        #expect(MacroCard.fiberFooterText(intake: -5, target: 30) == "Fiber 0g of 30g")
        #expect(MacroCard.fiberFooterText(intake: 18.4, target: 30) == "Fiber 18g of 30g")
    }
}
