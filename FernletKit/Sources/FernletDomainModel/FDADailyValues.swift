// FDADailyValues.swift
//
// The single reference table of FDA Daily Values shared by the two consumers that
// used to carry their own copies: `MicronutrientGapAnalyzer.trackedNutrients`
// (the gap-analysis denominators) and `NutritionLabelScanner.dvReference` (the
// "% Daily Value → absolute amount" back-solver). Before this table the two
// disagreed on calcium (1,000 vs 1,300) and potassium (3,400 vs 4,700); the
// analyzer carried the stale NASEM adult-19–50 figures while the scanner already
// used the FDA DVs that food packages print. Standardizing on the FDA DVs makes
// the analyzer match the scanner and the label the user is reading.
//
// Verified 2026-07-23 against **21 CFR 101.9** — the RDIs in (c)(8)(iv) and the
// DRVs in (c)(9), adults and children ≥ 4 years. These are a single flat adult
// reference set: there is no age / sex / pregnancy / life-stage adjustment and no
// Tolerable Upper Intake Level here, by design — this is the label-comparison
// reference, not clinical guidance.

import Foundation

public nonisolated enum FDADailyValues {

    // MARK: - Gap-analysis denominators (per-day intake targets)
    //
    // These feed `MicronutrientGapAnalyzer.trackedNutrients`. "keep" rows are
    // unchanged from the historical table; the two "update" rows carry the FDA DV.

    public static let fiberGrams: Double = 28              // DRV, keep
    public static let vitaminCMilligrams: Double = 90      // keep
    public static let vitaminDMicrograms: Double = 20      // keep
    public static let vitaminB12Micrograms: Double = 2.4   // keep
    public static let folateMicrogramsDFE: Double = 400    // keep
    public static let calciumMilligrams: Double = 1_300    // UPDATED from 1,000 (stale NASEM)
    public static let ironMilligrams: Double = 18          // keep
    public static let magnesiumMilligrams: Double = 420    // keep
    public static let potassiumMilligrams: Double = 4_700  // UPDATED from 3,400 (stale NASEM)
    public static let zincMilligrams: Double = 11          // keep

    /// **FDA has no omega-3 / ALA Daily Value.** This is the NASEM *Adequate
    /// Intake (AI)* for ALA (α-linolenic acid), retained so the omega-3 gap row
    /// keeps a denominator. It is a different reference system from the FDA DVs
    /// above and is intentionally the one carve-out (owner decision §11.2).
    public static let omega3ALAGrams: Double = 1.6

    // MARK: - Limit-style DRVs (rendered as ceilings, not targets)

    /// Sodium DRV. Matches `NutritionTargets.sodiumLimit`.
    public static let sodiumLimitMilligrams: Double = 2_300
    /// Saturated-fat DRV.
    public static let saturatedFatLimitGrams: Double = 20
    /// The **added-sugars** DRV. NOTE: this is the *added*-sugars limit; some UI
    /// (JournalView's sugar row) applies it to *total* sugar as an over-strict
    /// approximation — that row is annotated at its call site, not corrected here.
    public static let addedSugarsLimitGrams: Double = 50

    // MARK: - Label-scan-only DVs (not gap-tracked)
    //
    // The remaining RDIs/DRVs the label scanner back-solves from a printed "%DV".
    // They are not tracked by the gap analyzer but live here so the scanner reads
    // one source instead of scattering magic numbers through its parse cascade.

    public static let totalFatGrams: Double = 78           // DRV
    public static let saturatedFatGrams: Double = 20       // DRV (alias of the limit above)
    public static let totalCarbohydrateGrams: Double = 275 // DRV
    public static let addedSugarsGrams: Double = 50        // DRV (alias of the limit above)
    public static let proteinGrams: Double = 50            // DRV
    public static let cholesterolMilligrams: Double = 300  // DRV
    public static let vitaminAMicrogramsRAE: Double = 900
    public static let vitaminEMilligrams: Double = 15
    public static let thiaminMilligrams: Double = 1.2
    public static let riboflavinMilligrams: Double = 1.3
    public static let niacinMilligrams: Double = 16
    public static let phosphorusMilligrams: Double = 1_250
}
