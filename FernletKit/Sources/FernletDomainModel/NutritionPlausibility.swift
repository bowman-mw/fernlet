import Foundation

// MARK: - Nutrition plausibility + completeness gate (fix 1.14)
//
// PROVENANCE — where each rule comes from, stated as engineering fact.
// Every check below was written against these public sources. They are recorded so a future
// maintainer can see what the arithmetic is implementing and check it against the same documents:
//
//   * 4/4/9 energy identity ......... W. O. Atwater, USDA Storrs Experiment Station (1896), as
//                                     recounted in FAO Food and Nutrition Paper 77 ch. 3; codified
//                                     for US labels at 21 CFR 101.9(c)(1)(i)(B) (general factors of
//                                     4, 4 and 9 kcal/g for protein, total carbohydrate and total
//                                     fat, per USDA Agriculture Handbook 74).
//   * tolerance band as a concept ... Greenfield & Southgate, "Food Composition Data" 2nd ed.
//                                     (FAO, 2003) ch. 8 — component summations are accepted inside
//                                     a band, not at an exact equality.
//   * total fat >= sum of its
//     reported fatty-acid fractions .. FAO/INFOODS "Guidelines for Checking Food Composition Data
//                                     prior to the Publication of a User Table/Database" v1.0
//                                     (2012); shipped as a release gate in Haytowitz, Lemar &
//                                     Pehrsson, USDA ARS, J. Food Composition and Analysis 22
//                                     (2009) 433-441, Table 4.
//   * total carbohydrate >= fibre
//     + sugars ....................... Rand, Pennington, Murphy & Klensin, "Compiling Data for Food
//                                     Composition Data Bases" (UNU/INFOODS, 1991); follows by
//                                     definition from 21 CFR 101.9(c)(6), where total carbohydrate
//                                     is the by-difference residue and fibre/sugars are declared as
//                                     its indented sub-components.
//   * non-negativity ................ Standard compiler practice; the nearest published anchor is
//                                     FAO/INFOODS 2012's proximates rule, which is narrower than the
//                                     check here — it bounds the CARBOHYDRATE-BY-DIFFERENCE residual
//                                     (a computed value outside ±5 g/100 g removes the entry) rather
//                                     than stating a general non-negativity rule for every nutrient.
//                                     It is cited for the practice it establishes — an impossible
//                                     computed value is grounds to reject an entry rather than store
//                                     it — and the generalisation to all reported values is ours.
//   * zero is not missing ........... Rand et al. 1991: MISSING and ZERO must always be kept
//                                     distinct, and the numeral 0 is never used to mean MISSING.
//                                     This is the rule the whole optional-typed API below exists to
//                                     honour, and the failure mode the completeness half catches.
//   * insignificant-nutrient
//     exemption ...................... 21 CFR 101.9(j)(4) — foods containing insignificant amounts of
//                                     all nutrients are exempt from the declaration this gate checks.
//                                     Its named examples are plain unsweetened INSTANT COFFEE AND
//                                     TEA and tea leaves; plain water is NOT among them. The
//                                     exemption also carries a proviso — it applies to a food that
//                                     bears no nutrition information — so a barcoded product with a
//                                     Nutrition Facts panel is definitionally outside it. Both facts
//                                     bound where the exemption may be wired; see
//                                     `NutritionPlausibility.insignificantNutrientNames`.
//   * per-portion ceilings .......... Evenepoel et al., J Med Internet Res 2020;22(10):e18237. Kept
//                                     ONLY as an outer absurdity guard: they are one-sided upper
//                                     bounds curve-fitted to one national food table, they are
//                                     structurally blind to an absent value, and two nutrients got
//                                     WORSE on the held-out set. They are not an accuracy standard
//                                     and must never be presented as one.
//
// DESIGN BOUNDARY — load-bearing, do not erode.
// These checks validate ONE food record, locally, on the device that holds it. Do not combine them
// with cross-device aggregation of user-created food records. Specifically, do not build: a shared
// or federated store that ingests food records from many users' devices; clustering of those
// records by name similarity; scoring of the records in a cluster (by how many peers logged one, or
// by similarity to its groupmates); election of a canonical representative record per cluster;
// merging of duplicates into an averaged record; or serving such an elected record in response to a
// search. Fernlet's proximity mesh is a plurality of health-tracking devices, so this boundary is a
// real one and not a hypothetical. Transfer a record directly into the receiving user's own store;
// never build an aggregated canonical catalog. The same line is drawn independently by Docs/ for
// DSA and App Store Guideline 1.2 reasons, so a feature request that crosses it crosses two walls
// at once.
//
// SCOPE — the gate WARNS and routes to review. It never silently drops or rewrites a user's food.

/// The nutrient a plausibility finding or a completeness gap is about.
///
/// `rawValue` is a **frozen English token** — a matching/diagnostic identifier used in audit
/// context, test expectations and (potentially) exports, so it stays English forever.
/// ``displayName`` is the display half of the fork and is the only thing that may reach a screen.
public nonisolated enum NutrientField: String, CaseIterable, Sendable {
    case calories
    case protein
    case carbs
    case fat
    case saturatedFat
    case transFat
    case polyunsaturatedFat
    case monounsaturatedFat
    case fiber
    case sugar
    case sodium
    case cholesterol
    case servingSize

    /// The localized nutrient name. Display only — never persist it, never match on it.
    public var displayName: String {
        switch self {
        case .calories: String(localized: "nutrient.calories", defaultValue: "Calories",
                               bundle: .module, comment: "Nutrition field name: energy")
        case .protein: String(localized: "nutrient.protein", defaultValue: "Protein",
                              bundle: .module, comment: "Nutrition field name: protein")
        case .carbs: String(localized: "nutrient.carbs", defaultValue: "Carbs",
                            bundle: .module, comment: "Nutrition field name: total carbohydrate")
        case .fat: String(localized: "nutrient.fat", defaultValue: "Fat",
                          bundle: .module, comment: "Nutrition field name: total fat")
        case .saturatedFat: String(localized: "nutrient.saturatedFat", defaultValue: "Saturated fat",
                                   bundle: .module, comment: "Nutrition field name: saturated fat")
        case .transFat: String(localized: "nutrient.transFat", defaultValue: "Trans fat",
                               bundle: .module, comment: "Nutrition field name: trans fat")
        case .polyunsaturatedFat: String(localized: "nutrient.polyunsaturatedFat", defaultValue: "Polyunsaturated fat",
                                         bundle: .module, comment: "Nutrition field name: polyunsaturated fat")
        case .monounsaturatedFat: String(localized: "nutrient.monounsaturatedFat", defaultValue: "Monounsaturated fat",
                                         bundle: .module, comment: "Nutrition field name: monounsaturated fat")
        case .fiber: String(localized: "nutrient.fiber", defaultValue: "Fiber",
                            bundle: .module, comment: "Nutrition field name: dietary fiber")
        case .sugar: String(localized: "nutrient.sugar", defaultValue: "Sugars",
                            bundle: .module, comment: "Nutrition field name: total sugars")
        case .sodium: String(localized: "nutrient.sodium", defaultValue: "Sodium",
                             bundle: .module, comment: "Nutrition field name: sodium")
        case .cholesterol: String(localized: "nutrient.cholesterol", defaultValue: "Cholesterol",
                                  bundle: .module, comment: "Nutrition field name: cholesterol")
        case .servingSize: String(localized: "nutrient.servingSize", defaultValue: "Serving size",
                                  bundle: .module, comment: "Nutrition field name: the serving the numbers describe")
        }
    }
}

// MARK: - The gate's input

/// One food's reported nutrition, per serving, with **absent kept distinct from zero**.
///
/// - Important: every numeric field is `Double?` and the distinction is the whole point of this
///   type. `nil` means *the value was never reported* — the label line was not read, the field was
///   left blank. `0` means *the value was reported as zero* — a genuine claim about the food. Rand
///   et al. (1991) state the rule this encodes: MISSING and ZERO must always be kept distinct, and
///   the numeral 0 must never stand in for MISSING. Collapsing the two is the failure mode this
///   gate exists to catch, so **never** build a `NutritionFacts` with `?? 0`; pass the optional
///   through.
///
/// Grams for the macros and their fractions, kilocalories for `calories`, milligrams for `sodium`
/// and `cholesterol` — the units the US nutrition panel declares them in.
public nonisolated struct NutritionFacts: Equatable, Sendable {
    public var calories: Double?
    public var protein: Double?
    public var carbs: Double?
    public var fat: Double?
    public var saturatedFat: Double?
    public var transFat: Double?
    public var polyunsaturatedFat: Double?
    public var monounsaturatedFat: Double?
    public var fiber: Double?
    public var sugar: Double?
    public var sodium: Double?
    public var cholesterol: Double?
    /// Whether the record says what one serving actually is. A number with no serving attached is
    /// not a completeness gap in a nutrient — it is a gap in what the nutrients describe.
    public var hasServingSize: Bool

    public init(
        calories: Double? = nil,
        protein: Double? = nil,
        carbs: Double? = nil,
        fat: Double? = nil,
        saturatedFat: Double? = nil,
        transFat: Double? = nil,
        polyunsaturatedFat: Double? = nil,
        monounsaturatedFat: Double? = nil,
        fiber: Double? = nil,
        sugar: Double? = nil,
        sodium: Double? = nil,
        cholesterol: Double? = nil,
        hasServingSize: Bool = false
    ) {
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.saturatedFat = saturatedFat
        self.transFat = transFat
        self.polyunsaturatedFat = polyunsaturatedFat
        self.monounsaturatedFat = monounsaturatedFat
        self.fiber = fiber
        self.sugar = sugar
        self.sodium = sodium
        self.cholesterol = cholesterol
        self.hasServingSize = hasServingSize
    }

    /// Every field that carries a value, paired with its frozen token. Absent fields are simply not
    /// in the list — no zero is invented for them.
    public var reportedValues: [(field: NutrientField, value: Double)] {
        let pairs: [(NutrientField, Double?)] = [
            (.calories, calories), (.protein, protein), (.carbs, carbs), (.fat, fat),
            (.saturatedFat, saturatedFat), (.transFat, transFat),
            (.polyunsaturatedFat, polyunsaturatedFat), (.monounsaturatedFat, monounsaturatedFat),
            (.fiber, fiber), (.sugar, sugar), (.sodium, sodium), (.cholesterol, cholesterol),
        ]
        return pairs.compactMap { field, value in value.map { (field, $0) } }
    }

    /// The reported fatty-acid fractions of ``fat``, for the total-fat inequality.
    public var reportedFatFractions: [(field: NutrientField, value: Double)] {
        let pairs: [(NutrientField, Double?)] = [
            (.saturatedFat, saturatedFat), (.transFat, transFat),
            (.polyunsaturatedFat, polyunsaturatedFat), (.monounsaturatedFat, monounsaturatedFat),
        ]
        return pairs.compactMap { field, value in value.map { (field, $0) } }
    }

    /// The reported sub-components of ``carbs``, for the total-carbohydrate inequality.
    public var reportedCarbComponents: [(field: NutrientField, value: Double)] {
        let pairs: [(NutrientField, Double?)] = [(.fiber, fiber), (.sugar, sugar)]
        return pairs.compactMap { field, value in value.map { (field, $0) } }
    }
}

// MARK: - Findings

/// How much of the completeness half is meaningful at the seam being checked.
///
/// Completeness only says something where a field CAN be absent. Feed it an input type that has
/// already collapsed absent into zero and it reports the same gaps for every record, which is noise
/// dressed up as a finding.
public nonisolated enum NutritionCompletenessScope: String, Sendable, CaseIterable {
    /// The full Nutrition Facts core — serving size, calories, and the three macros. Use on any path
    /// that reads a panel (OCR, a product record), where each of those can genuinely be missing.
    case corePanel
    /// Completeness is not computed. Use where the input type cannot express absence — the
    /// hand-typed editor row, whose macros are non-optional `Int` and whose serving fields belong to
    /// the recipe rather than to a nutrition panel — so only the arithmetic half runs.
    case notApplicable
}

/// Whether a food is exempt from the not-all-zero rule.
///
/// 21 CFR 101.9(j)(4) exempts foods containing insignificant amounts of all nutrients — plain water,
/// plain unsweetened instant coffee and tea are the named examples. For those an all-zero panel is
/// the correct answer, not a data-entry failure.
public nonisolated enum NutrientSignificanceExemption: String, Sendable, CaseIterable {
    /// The ordinary case: an all-zero food is implausible and gets a finding.
    case none
    /// 21 CFR 101.9(j)(4) applies — all-zero is expected and raises no finding.
    case insignificantNutrients
}

/// One way a food's numbers failed a check.
///
/// Each case is a WARNING for the user to look at, never a reason to discard their entry. The
/// associated values are diagnostics: what was claimed, and what the check expected.
public nonisolated enum NutritionPlausibilityFinding: Equatable, Sendable {
    /// A reported value is below zero (FAO/INFOODS 2012).
    case negativeValue(NutrientField, value: Double)
    /// A reported value is not a finite number — a parse or arithmetic accident, never real data.
    case unreadableValue(NutrientField)
    /// Every reported value is zero and no insignificant-nutrient exemption applies.
    case allReportedValuesZero
    /// Declared energy is further than `tolerance` from every permitted calculation of the reported
    /// macros (Atwater / 21 CFR 101.9); `nearestTarget` is the closest of them.
    case caloriesDisagreeWithMacros(declared: Double, nearestTarget: Double, tolerance: Double)
    /// Total fat is less than the sum of the fatty-acid fractions reported for it.
    case fatBelowReportedFractions(totalFat: Double, fractionSum: Double)
    /// Total carbohydrate is less than the sum of the sub-components reported for it.
    case carbsBelowReportedComponents(totalCarbs: Double, componentSum: Double)
    /// A single portion exceeds an outer absurdity ceiling. NOT an accuracy judgement — see the
    /// provenance note on ``NutritionPlausibility/portionCeilings``.
    case exceedsPortionCeiling(NutrientField, value: Double, ceiling: Double)

    /// Gentle, localized copy for the warning surface. Display only.
    public var message: String {
        switch self {
        case .negativeValue(let field, _):
            return String(localized: "nutritionCheck.negative", defaultValue: "\(field.displayName) can't be less than zero.",
                          bundle: .module, comment: "Food plausibility warning: a nutrient value is negative")
        case .unreadableValue(let field):
            return String(localized: "nutritionCheck.unreadable", defaultValue: "\(field.displayName) didn't come through as a number.",
                          bundle: .module, comment: "Food plausibility warning: a nutrient value could not be read as a number")
        case .allReportedValuesZero:
            return String(localized: "nutritionCheck.allZero", defaultValue: "Everything here is zero, so this food won't count toward your day.",
                          bundle: .module, comment: "Food plausibility warning: every reported nutrient is zero")
        case .caloriesDisagreeWithMacros:
            return String(localized: "nutritionCheck.caloriesVsMacros", defaultValue: "The calories don't match the protein, carbs and fat.",
                          bundle: .module, comment: "Food plausibility warning: declared calories disagree with the macro sum")
        case .fatBelowReportedFractions:
            return String(localized: "nutritionCheck.fatFractions", defaultValue: "The fat breakdown adds up to more than the total fat.",
                          bundle: .module, comment: "Food plausibility warning: fatty-acid fractions exceed total fat")
        case .carbsBelowReportedComponents:
            return String(localized: "nutritionCheck.carbComponents", defaultValue: "Fiber and sugars add up to more than the total carbs.",
                          bundle: .module, comment: "Food plausibility warning: fibre plus sugars exceed total carbohydrate")
        case .exceedsPortionCeiling(let field, _, _):
            return String(localized: "nutritionCheck.ceiling", defaultValue: "That's a lot of \(field.displayName) for one serving — worth a second look.",
                          bundle: .module, comment: "Food plausibility warning: one serving exceeds an outer absurdity ceiling")
        }
    }

    /// Whether this finding is an ADVISORY — a "that seems like a lot, have another look" prompt —
    /// rather than an arithmetic contradiction in the record.
    ///
    /// Only the outer ceilings are advisory, and separating them is not cosmetic. The ceilings are a
    /// curve-fitted heuristic (see the warning on ``NutritionPlausibility/portionCeilings``), and
    /// presenting a heuristic in the same breath as "these numbers don't add up" would tell the user
    /// their arithmetic is broken when nothing about it is. A large portion is not an error. Callers
    /// must give the two classes different copy; ``NutritionPlausibilityReport/contradictions`` and
    /// ``NutritionPlausibilityReport/advisories`` split them.
    public var isAdvisory: Bool {
        switch self {
        case .exceedsPortionCeiling: true
        case .negativeValue, .unreadableValue, .allReportedValuesZero,
             .caloriesDisagreeWithMacros, .fatBelowReportedFractions, .carbsBelowReportedComponents: false
        }
    }
}

/// What the gate concluded about one food: what looked wrong, and what was never filled in.
///
/// The two halves are deliberately separate. `findings` are values that contradict each other or
/// themselves; `missingFields` are values that were never reported at all — the failure mode that a
/// ceiling-style check is structurally blind to, because an absent field that gets coerced to zero
/// looks perfectly plausible from above.
public nonisolated struct NutritionPlausibilityReport: Equatable, Sendable {
    /// Checks that failed, in check order.
    public let findings: [NutritionPlausibilityFinding]
    /// Core fields the record never reported — named, so the UI can say *which* rather than storing
    /// a silent zero.
    public let missingFields: [NutrientField]

    public init(findings: [NutritionPlausibilityFinding], missingFields: [NutrientField]) {
        self.findings = findings
        self.missingFields = missingFields
    }

    /// A clean bill: nothing contradicts and nothing core is missing.
    public static let clean = NutritionPlausibilityReport(findings: [], missingFields: [])

    /// Findings that are genuine arithmetic contradictions in the record — the five checks.
    /// Present these as "these numbers don't add up".
    public var contradictions: [NutritionPlausibilityFinding] { findings.filter { !$0.isAdvisory } }

    /// Findings from the outer ceiling guard — a heuristic second-look prompt, never a claim that
    /// the arithmetic is wrong. Present these separately and more softly; see
    /// ``NutritionPlausibilityFinding/isAdvisory``.
    public var advisories: [NutritionPlausibilityFinding] { findings.filter(\.isAdvisory) }

    /// At least one arithmetic contradiction. Advisory ceiling findings do NOT set this.
    public var isImplausible: Bool { !contradictions.isEmpty }

    /// At least one core field was never reported.
    public var isIncomplete: Bool { !missingFields.isEmpty }

    /// Whether this food is worth showing the user before it is saved. Warn-and-review only; no
    /// caller may read this as permission to drop or rewrite the entry.
    public var needsReview: Bool { !findings.isEmpty || isIncomplete }

    /// Localized "these are missing" copy, or nil when nothing core is missing. Display only.
    public var missingFieldsMessage: String? { Self.missingFieldsMessage(for: missingFields) }

    /// The same copy for an arbitrary field list, so a surface that can only meaningfully name SOME
    /// of the gaps (a screen that never shows calories, say) still says it in one voice rather than
    /// hand-rolling a second sentence.
    public static func missingFieldsMessage(for fields: [NutrientField]) -> String? {
        guard !fields.isEmpty else { return nil }
        let names = fields.map(\.displayName).formatted(.list(type: .and))
        return String(localized: "nutritionCheck.missing", defaultValue: "Still missing: \(names).",
                      bundle: .module, comment: "Food completeness note listing the nutrition fields that were never filled in")
    }

    /// At most `limit` findings' messages, one per line, with an honest "and N more" tail when the
    /// list was truncated — never a silent trim.
    ///
    /// The findings arrive in check order (see ``NutritionPlausibility/report(for:exemption:completeness:)``),
    /// which already ranks the arithmetic contradictions ahead of the advisory ceilings, so
    /// truncating the tail drops the least important thing rather than an arbitrary one. Callers
    /// normally pass a single class — ``contradictions`` or ``advisories`` — rather than `findings`.
    public static func message(for findings: [NutritionPlausibilityFinding], limit: Int) -> String? {
        guard limit > 0, !findings.isEmpty else { return nil }
        let shown = findings.prefix(limit).map(\.message).joined(separator: "\n")
        let hidden = findings.count - min(findings.count, limit)
        guard hidden > 0 else { return shown }
        let more = String(localized: "nutritionCheck.andMore", defaultValue: "…and \(hidden) more.",
                          bundle: .module, comment: "Tail on a truncated list of food plausibility warnings")
        return shown + "\n" + more
    }
}

// MARK: - The checks

/// Five internal-consistency checks plus a completeness check, run over one food record, on the
/// device that holds it.
///
/// Pure functions throughout: no I/O, no persistence, no network, no shared state. Each check is a
/// separate `static func` so it can be tested and reasoned about on its own, and
/// ``report(for:exemption:)`` composes them in a fixed order.
///
/// Read the file-header provenance block before changing any threshold — every constant here traces
/// to a published document, and the design boundary in that block is load-bearing.
public nonisolated enum NutritionPlausibility {

    // MARK: Constants

    /// The Atwater general factors, kcal per gram of protein / total carbohydrate / total fat
    /// (21 CFR 101.9(c)(1)(i)(B), after USDA Agriculture Handbook 74).
    public static let kcalPerGramProtein = 4.0
    public static let kcalPerGramCarb = 4.0
    public static let kcalPerGramFat = 9.0

    /// kcal per gram carried by the low-energy carbohydrate bucket in the second energy target.
    ///
    /// - Important: this is OUR engineering choice, not a figure the regulation hands out, and an
    ///   earlier version of this comment was wrong to call it "the general factor the regulation
    ///   gives sugar alcohols". 21 CFR 101.9(c)(1)(i)(F) gives a PER-POLYOL table and **no** general
    ///   factor for an unlisted sugar alcohol: isomalt 2.0, lactitol 2.0, maltitol 2.1, xylitol 2.4,
    ///   sorbitol 2.6, mannitol 1.6, hydrogenated starch hydrolysates 3.0, erythritol 0 cal/g. 2.0
    ///   is isomalt's and lactitol's own value, taken here as a midpoint of that table because the
    ///   panel parser has no polyol field — which polyol a product used is simply not knowable at
    ///   this seam — and a midpoint puts the maltitol and high-fibre labels this bucket exists for
    ///   inside the window.
    ///
    /// See ``energyTargets(for:)`` for what goes in the bucket and why the value is not zero, and
    /// ``checkEnergyMatchesMacros(_:)`` for the bounded false positive the choice leaves behind.
    public static let kcalPerGramSugarAlcohol = 2.0

    /// Relative width of the energy window, as a fraction of the declared calories. A window rather
    /// than an equality is the standard treatment of a computed summation (Greenfield & Southgate
    /// 2003). Floored by ``declarationRoundingSlackKcal(declaredCalories:protein:carbs:fat:)``.
    public static let energyToleranceFraction = 0.10

    /// Half the increment 21 CFR 101.9(c)(1)(i) permits a calorie declaration to be rounded to:
    /// 5-cal increments up to and including 50 calories, 10-cal increments above it. So an honest
    /// declaration is within ±2.5 kcal of the computed value in the small regime, ±5 above it.
    ///
    /// - Note: the regime is chosen on the DECLARED value, which is the only figure a reader has.
    public static func calorieRoundingSlackKcal(declaredCalories: Double) -> Double {
        guard declaredCalories > 50 else { return 2.5 }
        return 5.0
    }

    /// Which of 21 CFR 101.9's two gram-declaration rules a nutrient is rounded under.
    ///
    /// The distinction is load-bearing and was got wrong once here: the macros do NOT share one
    /// rule. Deriving protein and carbohydrate slack from the fat rule under-states them on a
    /// small serving, and an under-stated floor warns on honest labels.
    public enum RoundingRegime: Sendable, CaseIterable {
        /// 21 CFR 101.9(c)(2), total fat and its fatty-acid sub-declarations: "Amounts shall be
        /// expressed to the nearest 0.5 (1/2) gram increment below 5 grams and to the nearest gram
        /// increment above 5 grams." Half those increments: ±0.25 g below 5 g, ±0.5 g at or above.
        case halfGramIncrementsBelowFiveGrams
        /// 21 CFR 101.9(c)(6) total carbohydrate (with its fibre and sugars sub-declarations) and
        /// (c)(7) protein. Each is "expressed to the nearest gram" at EVERY amount — neither has a
        /// small-amount half-gram tier — so half the increment is a flat ±0.5 g.
        case nearestGram
    }

    /// Half the increment 21 CFR 101.9 permits a gram declaration to be rounded to, per value and
    /// per ``RoundingRegime`` — because the macros are NOT all rounded the same way.
    ///
    /// So an honest fat figure ((c)(2)) is within ±0.25 g of the true amount below 5 g and ±0.5 g at
    /// or above it, while an honest carbohydrate ((c)(6)) or protein ((c)(7)) figure is within
    /// ±0.5 g at any amount at all.
    ///
    /// This is the per-value slack used both under the energy window and by the two inequality
    /// checks. It is per VALUE, not per food — a label can declare 2 g of fat and 30 g of
    /// carbohydrate on the same panel — and only the fat regime varies with the value's own size.
    public static func declarationSlackGrams(
        forGrams grams: Double,
        regime: RoundingRegime
    ) -> Double {
        guard regime == .halfGramIncrementsBelowFiveGrams else { return 0.5 }
        guard grams >= 5 else { return 0.25 }
        return 0.5
    }

    /// The widest gap between a declared calorie figure and a recomputed one that label rounding
    /// alone explains — the floor under the energy window, derived rather than tuned.
    ///
    /// It is the calorie declaration's own rounding plus each macro's rounding carried through its
    /// energy factor: `calorieSlack + 4·slack(P) + 4·slack(C) + 9·slack(F)`. Protein and
    /// carbohydrate are declared to the nearest gram at every amount, so their slack is a flat
    /// ±0.5 g; only fat has a small-amount regime (see ``RoundingRegime``). Worked, for the two
    /// CALORIE regimes: a 40-kcal serving with every macro under 5 g gives
    /// 2.5 + 4(0.5) + 4(0.5) + 9(0.25) = **8.75 kcal**; a 300-kcal serving with every macro at or
    /// above 5 g gives 5 + 0.5(4+4+9) = **13.5 kcal**.
    ///
    /// - Important: this covers the LABEL's rounding only. On the OCR path the parser hands back
    ///   protein/carbs/fat as `Int`, so a panel declaring 4.5 g is re-rounded a second time, adding
    ///   up to a further 0.5 g per macro (as much as 8.5 kcal) that this floor deliberately does not
    ///   absorb. Inflating the floor to swallow it would blind the check on small servings; the
    ///   consequence of leaving it out is an occasional dismissible warning on a half-gram label,
    ///   which is the right direction for a gate that only ever warns.
    public static func declarationRoundingSlackKcal(
        declaredCalories: Double,
        protein: Double,
        carbs: Double,
        fat: Double
    ) -> Double {
        let macroSlack = kcalPerGramProtein * declarationSlackGrams(forGrams: protein, regime: .nearestGram)
            + kcalPerGramCarb * declarationSlackGrams(forGrams: carbs, regime: .nearestGram)
            + kcalPerGramFat * declarationSlackGrams(forGrams: fat, regime: .halfGramIncrementsBelowFiveGrams)
        return calorieRoundingSlackKcal(declaredCalories: declaredCalories) + macroSlack
    }

    /// The fields a record needs before its numbers describe anything. Calories are included even
    /// though Fernlet derives energy from macros: a scanned or typed food that never reported one is
    /// exactly the record whose energy identity cannot be checked at all.
    public static let coreFields: [NutrientField] = [.servingSize, .calories, .protein, .carbs, .fat]

    /// Outer absurdity ceilings for ONE logged portion (Evenepoel et al. 2020).
    ///
    /// - Warning: these are an outer guard and nothing more. They are one-sided upper bounds that
    ///   were curve-fitted against a single national food table to maximise correlation, they cannot
    ///   see an absent or understated value at all, and on the paper's own held-out set two
    ///   nutrients scored *worse* after they were applied. Never present them to a user, or in
    ///   documentation, as a validated accuracy standard. The five internal-consistency checks are
    ///   the gate; this is the "surely not" backstop behind them.
    public static let portionCeilings: [(field: NutrientField, ceiling: Double)] = [
        (.calories, 1_500), (.carbs, 95), (.fat, 92), (.protein, 52),
        (.fiber, 22), (.sugar, 70), (.cholesterol, 600), (.sodium, 3_600),
    ]

    // MARK: Composition

    /// Runs every check over one food record and returns what it found.
    ///
    /// Order is fixed, and it is the order the UI ranks findings in: unreadable and negative values,
    /// then all-zero, then the energy identity, then the two component inequalities, and the outer
    /// ceilings LAST — so a caller that shows only the first few always shows the arithmetic
    /// contradictions ahead of the heuristic guard. Completeness is computed independently: a record
    /// can be perfectly self-consistent and still be missing half its panel.
    public static func report(
        for facts: NutritionFacts,
        exemption: NutrientSignificanceExemption = .none,
        completeness: NutritionCompletenessScope = .corePanel
    ) -> NutritionPlausibilityReport {
        let missing = missingFields(facts, scope: completeness)
        var findings = checkValuesAreReadableAndNonNegative(facts)
        // A record carrying an unreadable or negative value has already failed at the most basic
        // level; running arithmetic on top of it would produce noise, not information.
        guard findings.isEmpty else {
            return NutritionPlausibilityReport(findings: findings, missingFields: missing)
        }
        findings.append(contentsOf: checkNotAllZero(facts, exemption: exemption))
        findings.append(contentsOf: checkEnergyMatchesMacros(facts))
        findings.append(contentsOf: checkFatCoversItsFractions(facts))
        findings.append(contentsOf: checkCarbsCoverTheirComponents(facts))
        findings.append(contentsOf: checkPortionCeilings(facts))
        return NutritionPlausibilityReport(findings: findings, missingFields: missing)
    }

    /// The completeness gaps meaningful at the seam being checked, per ``NutritionCompletenessScope``.
    public static func missingFields(
        _ facts: NutritionFacts,
        scope: NutritionCompletenessScope
    ) -> [NutrientField] {
        guard scope == .corePanel else { return [] }
        return missingCoreFields(facts)
    }

    // MARK: (a) non-negativity

    /// Every reported value must be a finite number and at least zero (FAO/INFOODS 2012 — an
    /// impossible value is grounds to reject the entry, not to store it).
    ///
    /// Absent values are skipped, not treated as zero.
    public static func checkValuesAreReadableAndNonNegative(_ facts: NutritionFacts) -> [NutritionPlausibilityFinding] {
        let reported = facts.reportedValues
        guard !reported.isEmpty else { return [] }
        var findings: [NutritionPlausibilityFinding] = []
        for entry in reported {
            if !entry.value.isFinite {
                findings.append(.unreadableValue(entry.field))
            } else if entry.value < 0 {
                findings.append(.negativeValue(entry.field, value: entry.value))
            }
        }
        return findings
    }

    // MARK: (b) not all zero, with the insignificant-nutrient exemption

    /// A record that reports values and reports every one of them as zero is a food that logs as
    /// nothing.
    ///
    /// Two things this deliberately does NOT do. It does not fire when nothing was reported at all —
    /// that is missing data, which the completeness half names (Rand et al. 1991: MISSING and ZERO
    /// stay distinct). And it does not fire for a food exempt under 21 CFR 101.9(j)(4), where an
    /// all-zero panel is the truth about the food.
    public static func checkNotAllZero(
        _ facts: NutritionFacts,
        exemption: NutrientSignificanceExemption
    ) -> [NutritionPlausibilityFinding] {
        guard exemption == .none else { return [] }
        let reported = facts.reportedValues
        guard !reported.isEmpty else { return [] }
        guard reported.allSatisfy({ $0.value == 0 }) else { return [] }
        return [.allReportedValuesZero]
    }

    // MARK: (c) the energy identity

    /// The energy values the two applicable calculation methods in 21 CFR 101.9(c)(1)(i) produce for
    /// these macros, in ascending order.
    ///
    /// They are alternative TARGETS, not the ends of one interval — see
    /// ``checkEnergyMatchesMacros(_:)`` for why that distinction is load-bearing.
    ///
    /// * **(B), the general factors.** 4P + 4C + 9F, every gram of carbohydrate at 4 kcal.
    /// * **(C), general factors less low-energy carbohydrate — as adapted here.** Current text reads
    ///   "less the amount of non-digestible carbohydrates and sugar alcohols", so the carbohydrate
    ///   term splits: sugars stay at 4 kcal/g, while declared fibre and the carbohydrate no declared
    ///   sub-component accounts for — `total − fibre − sugars`, which is where sugar alcohols sit,
    ///   since the panel parser has no polyol field to read — go into a low-energy bucket.
    ///
    ///   Method (C) itself SUBTRACTS that bucket entirely, i.e. carries it at 0 kcal/g. This target
    ///   deliberately does not: it carries the bucket at ``kcalPerGramSugarAlcohol`` (2.0), which is
    ///   our midpoint of the per-polyol table in (c)(1)(i)(F) — 0 to 3.0 cal/g depending on which
    ///   polyol, a fact no panel line reveals — rather than a general factor, because the regulation
    ///   gives none. A target at literal zero would miss the maltitol and specific-factor labels this
    ///   bucket exists for, and the cost of the choice is stated and pinned: a label computed at a
    ///   true 0 kcal/g lands between the two windows (see ``checkEnergyMatchesMacros(_:)``).
    ///
    /// When nothing is reported below the carbohydrate line the two targets separate the most,
    /// because the whole carbohydrate figure falls into the low-energy bucket; when fibre is zero and
    /// sugars account for all of the carbohydrate they coincide.
    public static func energyTargets(for facts: NutritionFacts) -> [Double] {
        guard let protein = facts.protein, let carbs = facts.carbs, let fat = facts.fat else { return [] }
        let fixed = kcalPerGramProtein * protein + kcalPerGramFat * fat
        let general = fixed + kcalPerGramCarb * carbs
        let sugars = facts.sugar ?? 0
        let lowEnergyCarb = max(carbs - (facts.fiber ?? 0) - sugars, 0) + (facts.fiber ?? 0)
        let availableCarb = max(carbs - lowEnergyCarb, 0)
        let lowEnergy = fixed + kcalPerGramCarb * availableCarb + kcalPerGramSugarAlcohol * lowEnergyCarb
        return [min(general, lowEnergy), max(general, lowEnergy)]
    }

    /// Declared energy must land within tolerance of ONE of the permitted calculation methods.
    ///
    /// - Important: the targets are checked as separate narrow windows, never as one interval
    ///   spanning both. Treating them as the ends of a single band is the failure this design exists
    ///   to avoid: for a food whose two methods are far apart (a fibre supplement, a sugar-free
    ///   sweet) the hull swallows everything between them, and a calorie figure mistyped by a factor
    ///   of ten lands inside it and passes clean. Two windows with a gap between them keep the check
    ///   live exactly where the spread is widest.
    ///
    /// Each window is ±`max(10% of declared, derived rounding slack)` around its target — see
    /// ``declarationRoundingSlackKcal(declaredCalories:protein:carbs:fat:)``.
    ///
    /// Requires all three macros: an absent macro is not zero, and substituting one would
    /// manufacture a disagreement out of missing data. A partially-read panel is a completeness
    /// problem, and the completeness half reports it as one.
    ///
    /// - Note: a stated, bounded false positive. A label that computed its energy with the
    ///   low-energy bucket at 0 kcal/g rather than 2 — which is what method (C) literally
    ///   prescribes, and is seen on some very-high-fibre products — can land below both windows and
    ///   draw a warning. The gate only ever warns, and widening the low window to reach zero would
    ///   re-open the hole above.
    public static func checkEnergyMatchesMacros(_ facts: NutritionFacts) -> [NutritionPlausibilityFinding] {
        guard let calories = facts.calories,
              let protein = facts.protein, let carbs = facts.carbs, let fat = facts.fat else { return [] }
        let targets = energyTargets(for: facts)
        guard !targets.isEmpty else { return [] }
        let slack = declarationRoundingSlackKcal(
            declaredCalories: calories, protein: protein, carbs: carbs, fat: fat
        )
        let tolerance = max(calories * energyToleranceFraction, slack)
        guard !targets.contains(where: { abs(calories - $0) <= tolerance }) else { return [] }
        let nearest = targets.min(by: { abs(calories - $0) < abs(calories - $1) }) ?? targets[0]
        return [.caloriesDisagreeWithMacros(
            declared: calories, nearestTarget: nearest, tolerance: tolerance
        )]
    }

    // MARK: (d) total fat covers its fractions

    /// Total fat must be at least the sum of the fatty-acid fractions actually reported for it
    /// (FAO/INFOODS 2012; USDA ARS release gate, Haytowitz 2009 Table 4).
    ///
    /// Only reported fractions are summed — an unreported fraction contributes nothing rather than a
    /// zero, which is the same statement in this direction but matters if a fraction is ever added.
    ///
    /// The slack is per VALUE and size-aware (``declarationSlackGrams(forGrams:regime:)``): a 2 g
    /// saturated-fat figure was rounded to 0.5 g increments and a 30 g total to 1 g increments, so a
    /// flat allowance would be wrong in both directions. Everything summed here — the total and all
    /// four fatty-acid fractions — is declared under 21 CFR 101.9(c)(2), so every term takes the fat
    /// regime.
    public static func checkFatCoversItsFractions(_ facts: NutritionFacts) -> [NutritionPlausibilityFinding] {
        guard let fat = facts.fat else { return [] }
        let fractions = facts.reportedFatFractions
        guard !fractions.isEmpty else { return [] }
        let sum = fractions.reduce(0.0) { $0 + $1.value }
        let regime = RoundingRegime.halfGramIncrementsBelowFiveGrams
        let slack = fractions.reduce(declarationSlackGrams(forGrams: fat, regime: regime)) {
            $0 + declarationSlackGrams(forGrams: $1.value, regime: regime)
        }
        guard sum > fat + slack else { return [] }
        return [.fatBelowReportedFractions(totalFat: fat, fractionSum: sum)]
    }

    // MARK: (e) total carbohydrate covers its components

    /// Total carbohydrate must be at least fibre plus sugars (Rand et al. 1991; follows from
    /// 21 CFR 101.9(c)(6), where fibre and sugars are indented sub-components of the by-difference
    /// carbohydrate total).
    ///
    /// The total and both sub-components are declared "to the nearest gram" under (c)(6), with no
    /// small-amount tier, so every term here takes the flat ±0.5 g regime — unlike the fat
    /// inequality above.
    public static func checkCarbsCoverTheirComponents(_ facts: NutritionFacts) -> [NutritionPlausibilityFinding] {
        guard let carbs = facts.carbs else { return [] }
        let components = facts.reportedCarbComponents
        guard !components.isEmpty else { return [] }
        let sum = components.reduce(0.0) { $0 + $1.value }
        let regime = RoundingRegime.nearestGram
        let slack = components.reduce(declarationSlackGrams(forGrams: carbs, regime: regime)) {
            $0 + declarationSlackGrams(forGrams: $1.value, regime: regime)
        }
        guard sum > carbs + slack else { return [] }
        return [.carbsBelowReportedComponents(totalCarbs: carbs, componentSum: sum)]
    }

    // MARK: The outer absurdity guard

    /// The Evenepoel per-portion ceilings, as a backstop behind the five checks and nothing more.
    /// See the warning on ``portionCeilings``: one-sided, curve-fitted, blind to omission.
    public static func checkPortionCeilings(_ facts: NutritionFacts) -> [NutritionPlausibilityFinding] {
        let reported = facts.reportedValues
        guard !reported.isEmpty else { return [] }
        var findings: [NutritionPlausibilityFinding] = []
        for ceiling in portionCeilings {
            guard let entry = reported.first(where: { $0.field == ceiling.field }) else { continue }
            guard entry.value > ceiling.ceiling else { continue }
            findings.append(.exceedsPortionCeiling(ceiling.field, value: entry.value, ceiling: ceiling.ceiling))
        }
        return findings
    }

    // MARK: Completeness

    /// The core fields this record never reported.
    ///
    /// This is the half that catches the failure mode a ceiling cannot see: a field that is absent,
    /// gets coerced to zero somewhere downstream, and then looks entirely plausible from above. It
    /// reads ``NutritionFacts`` optionals directly, so a caller that already collapsed nil to 0
    /// defeats it — which is why ``NutritionFacts`` is optional-typed all the way through.
    /// Reported in ``coreFields`` order; a test pins the two together so neither can drift.
    public static func missingCoreFields(_ facts: NutritionFacts) -> [NutrientField] {
        var missing: [NutrientField] = []
        if !facts.hasServingSize { missing.append(.servingSize) }
        if facts.calories == nil { missing.append(.calories) }
        if facts.protein == nil { missing.append(.protein) }
        if facts.carbs == nil { missing.append(.carbs) }
        if facts.fat == nil { missing.append(.fat) }
        return missing
    }

    // MARK: The 21 CFR 101.9(j)(4) exemption

    /// Whole food names treated as containing insignificant amounts of all nutrients.
    ///
    /// Two different things are in this list and the difference matters. **Coffee and tea are the
    /// regulation's own examples** — 21 CFR 101.9(j)(4) names plain unsweetened instant coffee and
    /// tea, and tea leaves. **Water is not**, and the earlier version of this comment was wrong to
    /// say so; it is here as a pragmatic heuristic, on the same everyday reasoning, and is labelled
    /// as ours rather than the regulation's. The sparkling/mineral/seltzer entries are ours too.
    ///
    /// Also note the regulation's proviso: the exemption is for a food that bears no nutrition
    /// information. A barcoded packaged product carrying a Nutrition Facts panel is outside it by
    /// definition, so this must not be wired into a scanned-product screen — its home is the
    /// hand-typed custom-food seam, where the user is naming a food that has no panel at all.
    ///
    /// A **frozen English token list**: this is a matching input, not display text, so it never
    /// localizes. Matching is on the whole normalized name, never a substring, so "sweet tea",
    /// "tea cake" and "coffee ice cream" correctly get no exemption.
    ///
    /// - Note: the honest ceiling on this. Coverage is a fixed list of 15 English strings, so it is
    ///   fragile in exactly the way a list is: "iced tea", "decaf", "hot water", "americano", "chai"
    ///   and every misspelling miss it, and so does every non-English name — a Spanish or French user
    ///   typing "agua" or "thé" never matches, and because the list is a frozen matching input that
    ///   is PERMANENT, not a gap awaiting translation. The measured coverage is pinned by a test so
    ///   the list cannot quietly shrink. All a miss costs is one dismissible warning: the gate never
    ///   blocks. No fuzzy matching or language detection is worth adding for that.
    public static let insignificantNutrientNames: Set<String> = [
        "water", "sparkling water", "mineral water", "seltzer", "club soda", "soda water",
        "tea", "black tea", "green tea", "herbal tea", "unsweetened tea",
        "coffee", "black coffee", "espresso", "instant coffee",
    ]

    /// The exemption that applies to a food with this name, per ``insignificantNutrientNames``.
    public static func exemption(forFoodNamed name: String) -> NutrientSignificanceExemption {
        let normalized = FoodItemSearch.normalized(name)
        guard !normalized.isEmpty else { return .none }
        guard insignificantNutrientNames.contains(normalized) else { return .none }
        return .insignificantNutrients
    }
}

// MARK: - Domain adapters

extension NutritionFacts {
    /// The facts a stored ``FoodItem``-shaped record carries.
    ///
    /// - Important: `macros` is a non-optional triple, so protein/carbs/fat are always *reported*
    ///   here — by the time a value reaches ``Macros`` the absent/zero distinction is already gone.
    ///   That is exactly why the gate runs at the entry seams, over the optional-typed input, and
    ///   why this adapter takes `declaredCalories` separately: ``Macros/calories`` is *derived* via
    ///   4/4/9, so passing it in would make the energy check compare a number with itself. Pass a
    ///   calorie figure only when one was independently declared (a scanned panel, a product
    ///   record); pass nil otherwise and the energy check correctly stands down.
    public init(
        macros: Macros,
        micronutrients: Micronutrients,
        declaredCalories: Double? = nil,
        hasServingSize: Bool = false
    ) {
        self.init(
            calories: declaredCalories,
            protein: Double(macros.protein),
            carbs: Double(macros.carbs),
            fat: Double(macros.fat),
            saturatedFat: micronutrients.saturatedFat,
            fiber: micronutrients.fiber,
            sugar: micronutrients.sugar,
            sodium: micronutrients.sodium,
            cholesterol: micronutrients.cholesterol,
            hasServingSize: hasServingSize
        )
    }
}
