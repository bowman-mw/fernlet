import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

#if canImport(UIKit)
import UIKit
import FernletDomainModel

/// Everything one OCR pass managed to read off a nutrition-facts label: serving info, the three
/// macros, and the full micronutrient panel.
///
/// Every field is optional — `nil` means "not recognized", never zero — and the per-serving units
/// follow the label conventions the parser normalizes to (macros in grams, most minerals/vitamins in
/// mg, vitamin D/A/B12/folate in mcg, omega-3 in grams). Produced by ``NutritionLabelScanner``;
/// consumed by the app's `FoodCaptureRouter`, `NutritionLabelCameraSheet`, `FoodView`, and
/// `FoodProductWebImporter`, which fold it into the domain model via ``micronutrients()``.
public struct NutritionLabelResult: Equatable, Hashable {
    public var servingSize: String?
    public var servingsPerContainer: Int?
    public var calories: Int?

    public var protein: Int?
    public var carbs: Int?
    public var fat: Int?

    public var fiber: Double?
    public var sugar: Double?
    public var addedSugar: Double?
    public var saturatedFat: Double?
    public var transFat: Double?
    public var cholesterol: Double?
    public var vitaminA: Double?
    public var vitaminC: Double?
    public var vitaminD: Double?
    public var vitaminE: Double?
    public var vitaminB12: Double?
    public var thiamin: Double?
    public var riboflavin: Double?
    public var niacin: Double?
    public var folate: Double?
    public var calcium: Double?
    public var iron: Double?
    public var magnesium: Double?
    public var phosphorus: Double?
    public var potassium: Double?
    public var sodium: Double?
    public var zinc: Double?
    public var omega3: Double?

    public init(
        servingSize: String? = nil,
        servingsPerContainer: Int? = nil,
        calories: Int? = nil,
        protein: Int? = nil,
        carbs: Int? = nil,
        fat: Int? = nil,
        fiber: Double? = nil,
        sugar: Double? = nil,
        addedSugar: Double? = nil,
        saturatedFat: Double? = nil,
        transFat: Double? = nil,
        cholesterol: Double? = nil,
        vitaminA: Double? = nil,
        vitaminC: Double? = nil,
        vitaminD: Double? = nil,
        vitaminE: Double? = nil,
        vitaminB12: Double? = nil,
        thiamin: Double? = nil,
        riboflavin: Double? = nil,
        niacin: Double? = nil,
        folate: Double? = nil,
        calcium: Double? = nil,
        iron: Double? = nil,
        magnesium: Double? = nil,
        phosphorus: Double? = nil,
        potassium: Double? = nil,
        sodium: Double? = nil,
        zinc: Double? = nil,
        omega3: Double? = nil
    ) {
        self.servingSize = servingSize
        self.servingsPerContainer = servingsPerContainer
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
        self.sugar = sugar
        self.addedSugar = addedSugar
        self.saturatedFat = saturatedFat
        self.transFat = transFat
        self.cholesterol = cholesterol
        self.vitaminA = vitaminA
        self.vitaminC = vitaminC
        self.vitaminD = vitaminD
        self.vitaminE = vitaminE
        self.vitaminB12 = vitaminB12
        self.thiamin = thiamin
        self.riboflavin = riboflavin
        self.niacin = niacin
        self.folate = folate
        self.calcium = calcium
        self.iron = iron
        self.magnesium = magnesium
        self.phosphorus = phosphorus
        self.potassium = potassium
        self.sodium = sodium
        self.zinc = zinc
        self.omega3 = omega3
    }

    /// The single source of truth for "how many fields did the scan actually read" — the signal both
    /// `FoodCaptureRouter`'s label-confidence floor and `NutritionLabelCameraSheet`'s "< 3 fields = show
    /// tips" heuristic key off. Calories ARE counted (the user-facing sheet's long-standing precedent),
    /// so both call sites agree to the field. Keep the two heuristics reading the same number; a
    /// divergence here is what let a stray "protein 8g" on a meal photo route differently than it tipped.
    public var recognizedFieldCount: Int {
        [
            servingSize.map { _ in true },
            servingsPerContainer.map { _ in true },
            calories.map { _ in true },
            protein.map { _ in true },
            carbs.map { _ in true },
            fat.map { _ in true },
            fiber.map { _ in true },
            sugar.map { _ in true },
            addedSugar.map { _ in true },
            saturatedFat.map { _ in true },
            transFat.map { _ in true },
            cholesterol.map { _ in true },
            vitaminA.map { _ in true },
            vitaminC.map { _ in true },
            vitaminD.map { _ in true },
            vitaminE.map { _ in true },
            vitaminB12.map { _ in true },
            thiamin.map { _ in true },
            riboflavin.map { _ in true },
            niacin.map { _ in true },
            folate.map { _ in true },
            calcium.map { _ in true },
            iron.map { _ in true },
            magnesium.map { _ in true },
            phosphorus.map { _ in true },
            potassium.map { _ in true },
            sodium.map { _ in true },
            zinc.map { _ in true },
            omega3.map { _ in true }
        ]
        .compactMap { $0 }
        .count
    }

    public func micronutrients() -> Micronutrients {
        Micronutrients(
            fiber: fiber,
            sugar: sugar,
            saturatedFat: saturatedFat,
            cholesterol: cholesterol,
            vitaminA: vitaminA,
            vitaminC: vitaminC,
            vitaminD: vitaminD,
            vitaminE: vitaminE,
            vitaminB12: vitaminB12,
            thiamin: thiamin,
            riboflavin: riboflavin,
            niacin: niacin,
            folate: folate,
            calcium: calcium,
            iron: iron,
            magnesium: magnesium,
            phosphorus: phosphorus,
            potassium: potassium,
            sodium: sodium,
            zinc: zinc,
            omega3: omega3
        )
    }
}

/// Returned when the label has two side-by-side columns (e.g. "dry mix" vs "as prepared").
///
/// Carries both parsed columns plus best-effort header strings recovered from the label text, so
/// the app's `NutritionLabelCameraSheet` can let the user pick which column to log. Only produced
/// by ``NutritionLabelScanner/scanAll(image:)`` when the text contains an "as prepared" marker.
public struct DualColumnScanResult {
    public var col1Header: String
    public var col2Header: String
    public var col1: NutritionLabelResult
    public var col2: NutritionLabelResult

    public init(
        col1Header: String,
        col2Header: String,
        col1: NutritionLabelResult,
        col2: NutritionLabelResult
    ) {
        self.col1Header = col1Header
        self.col2Header = col2Header
        self.col1 = col1
        self.col2 = col2
    }
}

/// User-facing failures from the label-scan pipeline: no readable text, or an image that could not
/// be converted for Vision.
///
/// Both cases carry gentle, actionable `errorDescription` strings that the camera sheet shows
/// verbatim, so wording here is UI copy — not just a debug message.
public enum NutritionLabelScanError: LocalizedError {
    case noTextFound
    case imageConversionFailed

    public var errorDescription: String? {
        switch self {
        case .noTextFound:
            "Could not read any text from that image. Try a clearer photo of the nutrition label."
        case .imageConversionFailed:
            "Could not process the image. Please try again."
        }
    }
}

/// On-device OCR pipeline that turns a photo of a nutrition-facts label into a structured
/// ``NutritionLabelResult``.
///
/// The pipeline is: CoreImage preprocessing (document-rectangle perspective correction, contrast
/// boost, grayscale, noise reduction) → `VNRecognizeTextRequest` with a custom-words vocabulary of
/// label phrases → the pure line parser ``parse(lines:matchIndex:)``. The parser is deliberately
/// forgiving of OCR damage: fuzzy label matching (normalization, "rn"→"m" confusion, bounded
/// Levenshtein distance), split label/value line recovery, %-Daily-Value back-solving against the
/// shared `FDADailyValues` table (21 CFR 101.9, the same table `MicronutrientGapAnalyzer` reads),
/// locale-aware comma handling, and cross-field sanity clamps (saturated fat ≤ fat, sugar/fiber ≤
/// carbs, added sugar ≤ sugar).
///
/// A namespace in practice — every member is static and the class is never instantiated. Vision
/// work runs in a detached, user-initiated task (`recognizeText(in:workDidStart:)`); parsing is
/// pure and synchronous, which is what makes `NutritionLabelScannerTests` possible without a
/// camera. Callers: the app's `NutritionLabelCameraSheet`, `FoodCaptureRouter`, `FoodView`, and
/// `FoodProductWebImporter`, all via ``scanAll(image:)``. Failure mode: throws
/// ``NutritionLabelScanError`` when no text is readable; individual unrecognized fields simply
/// stay `nil`.
public final class NutritionLabelScanner {
    /// OCRs the image and returns the primary (left-column) result plus dual-column info when the
    /// label has two columns ("as prepared" marker detected).
    ///
    /// - Returns: `primary` is the left column when a dual-column layout is detected, otherwise the
    ///   whole-label parse; `dualColumn` is `nil` for ordinary single-column labels.
    public static func scanAll(image: UIImage) async throws -> (primary: NutritionLabelResult, dualColumn: DualColumnScanResult?) {
        let lines = try await recognizeText(in: image)
        guard lines.isEmpty == false else { throw NutritionLabelScanError.noTextFound }
        let dual = detectAndParseDualColumn(from: lines)
        return (dual?.col1 ?? parse(lines: lines), dual)
    }

    /// Runs preprocessing + Vision text recognition off the calling thread and returns the
    /// recognized lines, top candidate per observation.
    ///
    /// - Parameters:
    ///   - image: The label photo; throws ``NutritionLabelScanError/imageConversionFailed`` when it
    ///     has no backing `CGImage`.
    ///   - workDidStart: Optional hook invoked on the detached task just before the heavy work —
    ///     used by UI callers to flip a "scanning…" indicator only once work truly begins.
    nonisolated public static func recognizeText(
        in image: UIImage,
        workDidStart: (@Sendable () -> Void)? = nil
    ) async throws -> [String] {
        guard let rawCGImage = image.cgImage else {
            throw NutritionLabelScanError.imageConversionFailed
        }

        return try await Task.detached(priority: .userInitiated) {
            workDidStart?()
            let cgImage = preprocessImage(rawCGImage) ?? rawCGImage
            return try recognizeTextSynchronously(in: cgImage)
        }.value
    }

    nonisolated private static func recognizeTextSynchronously(in cgImage: CGImage) throws -> [String] {
        var recognitionError: Error?
        var recognizedLines: [String] = []
        let request = VNRecognizeTextRequest { request, error in
            if let error {
                recognitionError = error
                return
            }
            let observations = request.results as? [VNRecognizedTextObservation] ?? []
            recognizedLines = observations.compactMap { $0.topCandidates(1).first?.string }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.customWords = [
            "Calories", "Total Fat", "Saturated Fat", "Trans Fat",
            "Cholesterol", "Sodium", "Total Carbohydrate", "Dietary Fiber",
            "Total Sugars", "Added Sugars", "Protein", "Vitamin D",
            "Calcium", "Iron", "Potassium", "Vitamin A", "Vitamin C",
            "Vitamin E", "Vitamin B12", "Folate", "Magnesium", "Zinc",
            "Niacin", "Thiamin", "Riboflavin", "Phosphorus", "Omega-3",
            "DHA", "EPA", "% Daily Value", "%DV", "Serving size",
            "Servings per container", "Amount per serving"
        ]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        if let recognitionError {
            throw recognitionError
        }
        return recognizedLines
    }

    nonisolated private static func preprocessImage(_ image: CGImage) -> CGImage? {
        var ciImage = CIImage(cgImage: image)

        if let correctedImage = perspectiveCorrectedImage(from: ciImage) {
            ciImage = correctedImage
        }

        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = ciImage
        colorControls.contrast = 1.12
        colorControls.saturation = 0
        ciImage = colorControls.outputImage ?? ciImage

        let noiseReduction = CIFilter.noiseReduction()
        noiseReduction.inputImage = ciImage
        ciImage = noiseReduction.outputImage ?? ciImage

        let context = CIContext()
        return context.createCGImage(ciImage, from: ciImage.extent)
    }

    nonisolated private static func perspectiveCorrectedImage(from image: CIImage) -> CIImage? {
        guard let rectangle = detectedDocumentRectangle(in: image) else { return nil }

        let width = image.extent.width
        let height = image.extent.height
        let correction = CIFilter.perspectiveCorrection()
        correction.inputImage = image
        correction.topLeft = imagePoint(from: rectangle.topLeft, width: width, height: height)
        correction.topRight = imagePoint(from: rectangle.topRight, width: width, height: height)
        correction.bottomLeft = imagePoint(from: rectangle.bottomLeft, width: width, height: height)
        correction.bottomRight = imagePoint(from: rectangle.bottomRight, width: width, height: height)
        return correction.outputImage
    }

    nonisolated private static func detectedDocumentRectangle(in image: CIImage) -> VNRectangleObservation? {
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
            return request.results?.first
        } catch {
            return nil
        }
    }

    nonisolated private static func imagePoint(from normalizedPoint: CGPoint, width: CGFloat, height: CGFloat) -> CGPoint {
        CGPoint(x: normalizedPoint.x * width, y: normalizedPoint.y * height)
    }

    // Detects "as prepared" dual-column format and returns both column results.
    private static func detectAndParseDualColumn(from lines: [String]) -> DualColumnScanResult? {
        let lower = lines.map { $0.lowercased() }
        guard lower.contains(where: { $0.contains("as prepared") }) else { return nil }

        let col1Header: String = {
            guard let servingLine = lower.first(where: { $0.hasPrefix("serving size") }) else { return "Per serving" }
            let suffix = servingLine.dropFirst("serving size".count).trimmingCharacters(in: .whitespaces)
            return suffix.isEmpty ? "Per serving" : String(suffix.prefix(30)).capitalized
        }()

        let col2Header: String = {
            guard let line = lower.first(where: { $0.contains("as prepared") }) else { return "As prepared" }
            return String(line.trimmingCharacters(in: .whitespaces).prefix(30)).capitalized
        }()

        return DualColumnScanResult(
            col1Header: col1Header,
            col2Header: col2Header,
            col1: parse(lines: lines, matchIndex: 0),
            col2: parse(lines: lines, matchIndex: 1)
        )
    }

    /// Pure parser from recognized text lines to a ``NutritionLabelResult`` — the unit-testable
    /// heart of the scanner (no Vision, no UIKit state).
    ///
    /// - Parameters:
    ///   - lines: OCR output lines, one per text observation.
    ///   - matchIndex: Which numeric token on a line to read — 0 = first (left) column,
    ///     1 = second (right) column. Defaults to 0 so all existing callers are unaffected.
    public static func parse(lines: [String], matchIndex: Int = 0) -> NutritionLabelResult {
        // R5: OCR callers pick the column; a negative index passes the `matches.count > matchIndex`
        // guards in the extractors and then subscripts `matches[matchIndex]`. Nothing to read.
        guard matchIndex >= 0 else { return NutritionLabelResult() }
        var result = NutritionLabelResult()
        let normalized = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        // The three appliers below preserve the original single if/else-if chain's ORDER exactly —
        // each returns true for the same label match that used to claim the line.
        for line in normalized {
            let lower = line.lowercased()
            if applyHeaderLine(lower, line: line, matchIndex: matchIndex, into: &result) { continue }
            if applyMacroLine(lower, matchIndex: matchIndex, into: &result) { continue }
            if applyVitaminLine(lower, matchIndex: matchIndex, into: &result) { continue }
            _ = applyMineralLine(lower, matchIndex: matchIndex, into: &result)
        }

        recoverSplitLineValues(from: normalized, into: &result)
        applySanityLimits(to: &result)

        return result
    }

    /// Serving/calories header lines. Returns true when `lower` was one of them.
    private static func applyHeaderLine(
        _ lower: String,
        line: String,
        matchIndex: Int,
        into result: inout NutritionLabelResult
    ) -> Bool {
        if lower.hasPrefix("serving size") {
            result.servingSize = extractTrailingText(from: line, after: "serving size")
            return true
        }
        if lower.contains("servings per container") || lower.contains("servings per package") {
            result.servingsPerContainer = extractInt(from: lower, matchIndex: matchIndex)
            return true
        }
        if lower.hasPrefix("calories") && lower.contains("from fat") == false {
            result.calories = extractInt(from: lower, matchIndex: matchIndex)
            return true
        }
        return false
    }

    /// Macro rows plus the two macro-adjacent minerals that follow them on a Nutrition Facts panel
    /// (cholesterol, sodium). Returns true when `lower` matched one of them.
    ///
    /// Daily-Value back-solve references come from the single shared `FDADailyValues` table
    /// (21 CFR 101.9) that `MicronutrientGapAnalyzer` also reads.
    private static func applyMacroLine(
        _ lower: String,
        matchIndex: Int,
        into result: inout NutritionLabelResult
    ) -> Bool {
        if matchesLabel(lower, "total fat") {
            result.fat = extractGrams(from: lower, matchIndex: matchIndex)
                ?? extractFromDailyValue(from: lower, dvReference: FDADailyValues.totalFatGrams, matchIndex: matchIndex).flatMap { clampedInt($0) }
        } else if matchesLabel(lower, "saturated fat") {
            result.saturatedFat = extractGramsDouble(from: lower, matchIndex: matchIndex)
                ?? extractFromDailyValue(from: lower, dvReference: FDADailyValues.saturatedFatGrams, matchIndex: matchIndex)
        } else if matchesLabel(lower, "trans fat") {
            result.transFat = extractGramsDouble(from: lower, matchIndex: matchIndex)
        } else if matchesLabel(lower, "total carbohydrate") || matchesLabel(lower, "total carb") {
            result.carbs = extractGrams(from: lower, matchIndex: matchIndex)
                ?? extractFromDailyValue(from: lower, dvReference: FDADailyValues.totalCarbohydrateGrams, matchIndex: matchIndex).flatMap { clampedInt($0) }
        } else if matchesLabel(lower, "dietary fiber") {
            result.fiber = extractGramsDouble(from: lower, matchIndex: matchIndex)
                ?? extractFromDailyValue(from: lower, dvReference: FDADailyValues.fiberGrams, matchIndex: matchIndex)
        } else if matchesLabel(lower, "added sugars") || matchesLabel(lower, "added sugar") {
            result.addedSugar = extractGramsDouble(from: lower, matchIndex: matchIndex)
                ?? extractFromDailyValue(from: lower, dvReference: FDADailyValues.addedSugarsGrams, matchIndex: matchIndex)
        } else if matchesLabel(lower, "total sugars") || matchesLabel(lower, "sugars") {
            result.sugar = extractGramsDouble(from: lower, matchIndex: matchIndex)
        } else if matchesLabel(lower, "protein") {
            result.protein = extractGrams(from: lower, matchIndex: matchIndex)
                ?? extractFromDailyValue(from: lower, dvReference: FDADailyValues.proteinGrams, matchIndex: matchIndex).flatMap { clampedInt($0) }
        } else if matchesLabel(lower, "cholesterol") {
            result.cholesterol = extractMilligrams(from: lower, matchIndex: matchIndex)
                ?? extractFromDailyValue(from: lower, dvReference: FDADailyValues.cholesterolMilligrams, matchIndex: matchIndex)
        } else if matchesLabel(lower, "sodium") {
            result.sodium = extractMilligrams(from: lower, matchIndex: matchIndex)
                ?? extractFromDailyValue(from: lower, dvReference: FDADailyValues.sodiumLimitMilligrams, matchIndex: matchIndex)
        } else {
            return false
        }
        return true
    }

    /// Vitamin rows, in the same order the original chain tested them. Returns true on a match.
    private static func applyVitaminLine(
        _ lower: String,
        matchIndex: Int,
        into result: inout NutritionLabelResult
    ) -> Bool {
        if matchesLabel(lower, "vitamin d") {
            result.vitaminD = extractMicrogramsOrMg(from: lower, matchIndex: matchIndex)
                ?? extractFromDailyValue(from: lower, dvReference: FDADailyValues.vitaminDMicrograms, matchIndex: matchIndex)
        } else if matchesLabel(lower, "vitamin a") {
            result.vitaminA = extractMicrogramsOrMg(from: lower, matchIndex: matchIndex)
                ?? extractFromDailyValue(from: lower, dvReference: FDADailyValues.vitaminAMicrogramsRAE, matchIndex: matchIndex)
        } else if matchesLabel(lower, "vitamin c") {
            result.vitaminC = extractMilligrams(from: lower, matchIndex: matchIndex)
                ?? extractFromDailyValue(from: lower, dvReference: FDADailyValues.vitaminCMilligrams, matchIndex: matchIndex)
        } else if matchesLabel(lower, "vitamin e") {
            result.vitaminE = extractMilligrams(from: lower, matchIndex: matchIndex)
                ?? extractFromDailyValue(from: lower, dvReference: FDADailyValues.vitaminEMilligrams, matchIndex: matchIndex)
        } else if matchesLabel(lower, "vitamin b12") || matchesLabel(lower, "vitamin b-12") {
            result.vitaminB12 = extractMicrogramsOrMg(from: lower, matchIndex: matchIndex)
                ?? extractFromDailyValue(from: lower, dvReference: FDADailyValues.vitaminB12Micrograms, matchIndex: matchIndex)
        } else if matchesLabel(lower, "thiamin") || matchesLabel(lower, "thiamine") {
            result.thiamin = extractMilligrams(from: lower, matchIndex: matchIndex)
                ?? extractFromDailyValue(from: lower, dvReference: FDADailyValues.thiaminMilligrams, matchIndex: matchIndex)
        } else if matchesLabel(lower, "riboflavin") {
            result.riboflavin = extractMilligrams(from: lower, matchIndex: matchIndex)
                ?? extractFromDailyValue(from: lower, dvReference: FDADailyValues.riboflavinMilligrams, matchIndex: matchIndex)
        } else if matchesLabel(lower, "niacin") {
            result.niacin = extractMilligrams(from: lower, matchIndex: matchIndex)
                ?? extractFromDailyValue(from: lower, dvReference: FDADailyValues.niacinMilligrams, matchIndex: matchIndex)
        } else if matchesLabel(lower, "folate") || matchesLabel(lower, "folic acid") {
            result.folate = extractMicrogramsOrMg(from: lower, matchIndex: matchIndex)
                ?? extractFromDailyValue(from: lower, dvReference: FDADailyValues.folateMicrogramsDFE, matchIndex: matchIndex)
        } else {
            return false
        }
        return true
    }

    /// Mineral rows (plus omega-3), in the same order the original chain tested them. Returns true
    /// on a match.
    private static func applyMineralLine(
        _ lower: String,
        matchIndex: Int,
        into result: inout NutritionLabelResult
    ) -> Bool {
        if matchesLabel(lower, "calcium") {
            result.calcium = extractMilligrams(from: lower, matchIndex: matchIndex)
                ?? extractFromDailyValue(from: lower, dvReference: FDADailyValues.calciumMilligrams, matchIndex: matchIndex)
        } else if matchesLabel(lower, "iron") {
            result.iron = extractMilligrams(from: lower, matchIndex: matchIndex)
                ?? extractFromDailyValue(from: lower, dvReference: FDADailyValues.ironMilligrams, matchIndex: matchIndex)
        } else if matchesLabel(lower, "potassium") {
            result.potassium = extractMilligrams(from: lower, matchIndex: matchIndex)
                ?? extractFromDailyValue(from: lower, dvReference: FDADailyValues.potassiumMilligrams, matchIndex: matchIndex)
        } else if matchesLabel(lower, "magnesium") {
            result.magnesium = extractMilligrams(from: lower, matchIndex: matchIndex)
                ?? extractFromDailyValue(from: lower, dvReference: FDADailyValues.magnesiumMilligrams, matchIndex: matchIndex)
        } else if matchesLabel(lower, "phosphorus") {
            result.phosphorus = extractMilligrams(from: lower, matchIndex: matchIndex)
                ?? extractFromDailyValue(from: lower, dvReference: FDADailyValues.phosphorusMilligrams, matchIndex: matchIndex)
        } else if matchesLabel(lower, "zinc") {
            result.zinc = extractMilligrams(from: lower, matchIndex: matchIndex)
                ?? extractFromDailyValue(from: lower, dvReference: FDADailyValues.zincMilligrams, matchIndex: matchIndex)
        } else if matchesLabel(lower, "omega-3") || matchesLabel(lower, "omega 3") || matchesLabel(lower, "dha") || matchesLabel(lower, "epa") {
            result.omega3 = extractGramsOrMilligramsAsGrams(from: lower, matchIndex: matchIndex)
        } else {
            return false
        }
        return true
    }

    private static func matchesLabel(_ line: String, _ label: String) -> Bool {
        if line.hasPrefix(label) {
            return true
        }

        if line.contains(label) {
            return true
        }

        let normalizedLine = normalizedLabelText(line)
        let normalizedLabel = normalizedLabelText(label)
        if normalizedLine.hasPrefix(normalizedLabel) || normalizedLine.contains(normalizedLabel) {
            return true
        }

        let compactLine = normalizedLine.replacingOccurrences(of: " ", with: "")
        let compactLabel = normalizedLabel.replacingOccurrences(of: " ", with: "")
        if compactLine.hasPrefix(compactLabel) || compactLine.contains(compactLabel) {
            return true
        }

        let labelWordCount = normalizedLabel.split(separator: " ").count
        guard labelWordCount > 0 else { return false }

        let lineWords = normalizedLine.split(separator: " ").map(String.init)
        guard lineWords.count >= labelWordCount else { return false }

        let maxDistance = normalizedLabel.count <= 6 ? 1 : 2
        for startIndex in 0...(lineWords.count - labelWordCount) {
            let candidateWords = Array(lineWords[startIndex..<(startIndex + labelWordCount)])
            guard canFuzzyMatch(candidateWords: candidateWords, label: normalizedLabel) else { continue }

            let candidate = candidateWords.joined(separator: " ")
            if levenshteinDistance(candidate, normalizedLabel, maximumDistance: maxDistance) <= maxDistance {
                return true
            }
        }

        return false
    }

    private static func recoverSplitLineValues(from lines: [String], into result: inout NutritionLabelResult) {
        guard lines.count > 1 else { return }

        for index in lines.indices.dropLast() {
            let labelLine = lines[index].lowercased()
            let valueLine = lines[lines.index(after: index)].lowercased()

            guard isOrphanLabelLine(labelLine) else { continue }

            if result.calories == nil, labelLine.hasPrefix("calories") {
                result.calories = bareCalories(in: lines, around: index)
            } else if result.saturatedFat == nil, matchesLabel(labelLine, "saturated fat") {
                result.saturatedFat = extractGramsDouble(from: valueLine)
                    ?? extractFromDailyValue(from: valueLine, dvReference: FDADailyValues.saturatedFatGrams)
            } else if result.transFat == nil, matchesLabel(labelLine, "trans fat") {
                result.transFat = extractGramsDouble(from: valueLine)
            } else if result.fiber == nil, matchesLabel(labelLine, "dietary fiber") {
                result.fiber = extractGramsDouble(from: valueLine)
                    ?? extractFromDailyValue(from: valueLine, dvReference: FDADailyValues.fiberGrams)
            } else if result.addedSugar == nil, matchesLabel(labelLine, "added sugars") || matchesLabel(labelLine, "added sugar") {
                result.addedSugar = extractGramsDouble(from: valueLine)
                    ?? extractFromDailyValue(from: valueLine, dvReference: FDADailyValues.addedSugarsGrams)
            } else if result.cholesterol == nil, matchesLabel(labelLine, "cholesterol") {
                result.cholesterol = extractMilligrams(from: valueLine)
                    ?? extractFromDailyValue(from: valueLine, dvReference: FDADailyValues.cholesterolMilligrams)
            }
        }
    }

    private static func bareCalories(in lines: [String], around caloriesIndex: Int) -> Int? {
        lines.indices
            .filter { $0 != caloriesIndex }
            .sorted { abs($0 - caloriesIndex) < abs($1 - caloriesIndex) }
            .compactMap { index -> Int? in
                let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil,
                      let calories = Int(line),
                      calories <= 2_000 else {
                    return nil
                }
                return calories
            }
            .first
    }

    private static func applySanityLimits(to result: inout NutritionLabelResult) {
        if let fat = result.fat.map(Double.init), let saturatedFat = result.saturatedFat, saturatedFat > fat {
            result.saturatedFat = fat
        }

        if let carbs = result.carbs.map(Double.init) {
            if let sugar = result.sugar, sugar > carbs {
                result.sugar = carbs
            }

            if let fiber = result.fiber, fiber > carbs {
                result.fiber = carbs
            }
        }

        if let sugar = result.sugar, let addedSugar = result.addedSugar, addedSugar > sugar {
            result.addedSugar = sugar
        }
    }

    private static func isOrphanLabelLine(_ line: String) -> Bool {
        extractFirstBareNumber(from: line) == nil &&
        extractFromDailyValue(from: line, dvReference: 1) == nil
    }

    private static func normalizedLabelText(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "rn", with: "m")
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }

    private static func canFuzzyMatch(candidateWords: [String], label: String) -> Bool {
        let labelWords = label.split(separator: " ").map(String.init)
        guard let labelLastWord = labelWords.last, let candidateLastWord = candidateWords.last else {
            return true
        }

        if labelWords.first == "vitamin", labelLastWord.count == 1 {
            return candidateLastWord == labelLastWord
        }

        return true
    }

    private static func levenshteinDistance(_ lhs: String, _ rhs: String, maximumDistance: Int) -> Int {
        let lhs = Array(lhs)
        let rhs = Array(rhs)

        if abs(lhs.count - rhs.count) > maximumDistance {
            return maximumDistance + 1
        }

        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)

        for lhsIndex in 1...lhs.count {
            current[0] = lhsIndex
            var rowMinimum = current[0]

            for rhsIndex in 1...rhs.count {
                let substitutionCost = lhs[lhsIndex - 1] == rhs[rhsIndex - 1] ? 0 : 1
                current[rhsIndex] = min(
                    previous[rhsIndex] + 1,
                    current[rhsIndex - 1] + 1,
                    previous[rhsIndex - 1] + substitutionCost
                )
                rowMinimum = min(rowMinimum, current[rhsIndex])
            }

            if rowMinimum > maximumDistance {
                return maximumDistance + 1
            }

            swap(&previous, &current)
        }

        return previous[rhs.count]
    }

    private static func extractTrailingText(from line: String, after label: String) -> String? {
        guard let range = line.range(of: label, options: .caseInsensitive) else { return nil }
        let after = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return after.isEmpty ? nil : after
    }

    /// The largest label value the parser will believe. Anything past it is OCR garbage (a lot
    /// number, a misread barcode, a digit run the `\d+` number pattern happily accepts).
    private static let maxPlausibleLabelValue = 1_000_000.0

    /// `Int(value.rounded())` with the trap removed.
    ///
    /// R5: OCR text is external input and the number pattern accepts any digit run, so a 20-digit
    /// token would overflow `Int` and crash the scan. A value that is not finite, or beyond
    /// ``maxPlausibleLabelValue``, reads as "not recognized" — the same `nil` every other
    /// unparseable field produces.
    private static func clampedInt(_ value: Double) -> Int? {
        guard value.isFinite, abs(value) <= maxPlausibleLabelValue else { return nil }
        return Int(value.rounded())
    }

    private static func extractInt(from text: String, matchIndex: Int = 0) -> Int? {
        guard let value = extractFirstBareNumber(from: text, matchIndex: matchIndex) else { return nil }
        return clampedInt(value)
    }

    private static func extractGrams(from text: String, matchIndex: Int = 0) -> Int? {
        guard let value = extractGramsDouble(from: text, matchIndex: matchIndex) else { return nil }
        return clampedInt(value)
    }

    private static func extractGramsDouble(from text: String, matchIndex: Int = 0) -> Double? {
        extractNumericBeforeUnit(from: text, unitPattern: #"g(?!\w)"#, excludePattern: #"m\s*g|mc\s*g|u\s*g"#, matchIndex: matchIndex)
            ?? extractFirstNumericWithUnit(from: text, unit: "g", matchIndex: matchIndex)
    }

    private static func extractMilligrams(from text: String, matchIndex: Int = 0) -> Double? {
        extractFirstNumericWithUnit(from: text, unit: "mg", matchIndex: matchIndex)
    }

    private static func extractMicrogramsOrMg(from text: String, matchIndex: Int = 0) -> Double? {
        if let mcg = extractFirstNumericWithUnit(from: text, unit: "mcg", matchIndex: matchIndex) {
            return mcg
        }
        if let ug = extractFirstNumericWithUnit(from: text, unit: "ug", matchIndex: matchIndex) {
            return ug
        }
        if let mg = extractFirstNumericWithUnit(from: text, unit: "mg", matchIndex: matchIndex) {
            return mg * 1000  // convert mg to mcg (canonical unit for vitaminD/A/B12/folate)
        }
        return text.contains("%") ? nil : extractFirstBareNumber(from: text, matchIndex: matchIndex)
    }

    private static func extractGramsOrMilligramsAsGrams(from text: String, matchIndex: Int = 0) -> Double? {
        if let grams = extractGramsDouble(from: text, matchIndex: matchIndex) {
            return grams
        }
        if let milligrams = extractMilligrams(from: text, matchIndex: matchIndex) {
            return milligrams / 1000
        }
        return nil
    }

    /// Parses a captured numeric token into a `Double`, treating a single comma followed by
    /// exactly three digits as a thousands separator (US "1,150" -> 1150) and any other comma
    /// as a decimal separator (European "12,5" -> 12.5). A blind comma->dot replacement would
    /// misread comma-grouped sodium/potassium values ~1000x too low.
    private static func normalizedNumber(_ token: Substring) -> Double? {
        let string = String(token)
        guard string.contains(",") else { return Double(string) }
        if string.filter({ $0 == "," }).count > 1 {
            return Double(string.replacingOccurrences(of: ",", with: ""))
        }
        let isThousands = string.range(of: #",\d{3}(?!\d)"#, options: .regularExpression) != nil
        return Double(string.replacingOccurrences(of: ",", with: isThousands ? "" : "."))
    }

    private static func extractFromDailyValue(from text: String, dvReference: Double, matchIndex: Int = 0) -> Double? {
        let pattern = #"(\d+(?:[.,]\d+)?)\s*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)
        guard matches.count > matchIndex,
              let range = Range(matches[matchIndex].range(at: 1), in: text),
              let percent = normalizedNumber(text[range]) else { return nil }
        return dvReference * percent / 100
    }

    private static func extractFirstNumericWithUnit(from text: String, unit: String, matchIndex: Int = 0) -> Double? {
        let escaped = NSRegularExpression.escapedPattern(for: unit)
        let pattern = #"(\d+(?:[.,]\d+)?)\s*"# + escaped
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)
        guard matches.count > matchIndex,
              let range = Range(matches[matchIndex].range(at: 1), in: text) else { return nil }
        return normalizedNumber(text[range])
    }

    // Only counts matches that don't satisfy excludePattern toward matchIndex.
    private static func extractNumericBeforeUnit(from text: String, unitPattern: String, excludePattern: String, matchIndex: Int = 0) -> Double? {
        let pattern = #"(\d+(?:[.,]\d+)?)\s*"# + unitPattern
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        let allMatches = regex.matches(in: text, range: nsRange)
        let excludeRegex = try? NSRegularExpression(pattern: excludePattern, options: .caseInsensitive)

        var validCount = 0
        for match in allMatches {
            guard let numberRange = Range(match.range(at: 1), in: text),
                  let fullRange = Range(match.range, in: text) else { continue }
            let fullMatch = String(text[fullRange])
            if let excludeRegex,
               excludeRegex.firstMatch(in: fullMatch, range: NSRange(fullMatch.startIndex..., in: fullMatch)) != nil {
                continue
            }
            if validCount == matchIndex {
                return normalizedNumber(text[numberRange])
            }
            validCount += 1
        }
        return nil
    }

    // Forward iteration; matchIndex selects which non-percentage numeric token to return.
    private static func extractFirstBareNumber(from text: String, matchIndex: Int = 0) -> Double? {
        let pattern = #"(\d+(?:[.,]\d+)?)"#
        let components = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var count = 0
        for component in components {
            guard component.contains("%") == false,
                  let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: component, range: NSRange(component.startIndex..., in: component)),
                  let range = Range(match.range(at: 1), in: component) else { continue }
            if count == matchIndex { return normalizedNumber(component[range]) }
            count += 1
        }
        return nil
    }
}
#endif
