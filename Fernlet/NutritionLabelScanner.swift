import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

#if canImport(UIKit)
import UIKit

struct NutritionLabelResult: Equatable, Hashable {
    var servingSize: String?
    var servingsPerContainer: Int?
    var calories: Int?

    var protein: Int?
    var carbs: Int?
    var fat: Int?

    var fiber: Double?
    var sugar: Double?
    var addedSugar: Double?
    var saturatedFat: Double?
    var transFat: Double?
    var cholesterol: Double?
    var vitaminA: Double?
    var vitaminC: Double?
    var vitaminD: Double?
    var vitaminE: Double?
    var vitaminB12: Double?
    var thiamin: Double?
    var riboflavin: Double?
    var niacin: Double?
    var folate: Double?
    var calcium: Double?
    var iron: Double?
    var magnesium: Double?
    var phosphorus: Double?
    var potassium: Double?
    var sodium: Double?
    var zinc: Double?
    var omega3: Double?

    func micronutrients() -> Micronutrients {
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

// Returned when the label has two side-by-side columns (e.g. "dry mix" vs "as prepared").
struct DualColumnScanResult {
    var col1Header: String
    var col2Header: String
    var col1: NutritionLabelResult
    var col2: NutritionLabelResult
}

enum NutritionLabelScanError: LocalizedError {
    case noTextFound
    case imageConversionFailed

    var errorDescription: String? {
        switch self {
        case .noTextFound:
            "Could not read any text from that image. Try a clearer photo of the nutrition label."
        case .imageConversionFailed:
            "Could not process the image. Please try again."
        }
    }
}

@MainActor
final class NutritionLabelScanner {
    static func scan(image: UIImage) async throws -> NutritionLabelResult {
        let lines = try await recognizeText(in: image)
        guard lines.isEmpty == false else { throw NutritionLabelScanError.noTextFound }
        return parse(lines: lines)
    }

    // Returns the primary result plus dual-column info when the label has two columns.
    static func scanAll(image: UIImage) async throws -> (primary: NutritionLabelResult, dualColumn: DualColumnScanResult?) {
        let lines = try await recognizeText(in: image)
        guard lines.isEmpty == false else { throw NutritionLabelScanError.noTextFound }
        let dual = detectAndParseDualColumn(from: lines)
        return (dual?.col1 ?? parse(lines: lines), dual)
    }

    private static func recognizeText(in image: UIImage) async throws -> [String] {
        guard let rawCGImage = image.cgImage else {
            throw NutritionLabelScanError.imageConversionFailed
        }
        let cgImage = preprocessImage(image) ?? rawCGImage

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines)
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
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func preprocessImage(_ image: UIImage) -> CGImage? {
        guard var ciImage = CIImage(image: image) else { return nil }

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

    private static func perspectiveCorrectedImage(from image: CIImage) -> CIImage? {
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

    private static func detectedDocumentRectangle(in image: CIImage) -> VNRectangleObservation? {
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

    private static func imagePoint(from normalizedPoint: CGPoint, width: CGFloat, height: CGFloat) -> CGPoint {
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

    // matchIndex: 0 = first (left) column, 1 = second (right) column.
    // Defaults to 0 so all existing callers are unaffected.
    static func parse(lines: [String], matchIndex: Int = 0) -> NutritionLabelResult {
        var result = NutritionLabelResult()
        let normalized = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        for line in normalized {
            let lower = line.lowercased()

            if lower.hasPrefix("serving size") {
                result.servingSize = extractTrailingText(from: line, after: "serving size")
                continue
            }

            if lower.contains("servings per container") || lower.contains("servings per package") {
                result.servingsPerContainer = extractInt(from: lower, matchIndex: matchIndex)
                continue
            }

            if lower.hasPrefix("calories") && lower.contains("from fat") == false {
                result.calories = extractInt(from: lower, matchIndex: matchIndex)
                continue
            }

            if matchesLabel(lower, "total fat") {
                result.fat = extractGrams(from: lower, matchIndex: matchIndex)
                    ?? extractFromDailyValue(from: lower, dvReference: 78, matchIndex: matchIndex).map { Int($0.rounded()) }
            } else if matchesLabel(lower, "saturated fat") {
                result.saturatedFat = extractGramsDouble(from: lower, matchIndex: matchIndex)
                    ?? extractFromDailyValue(from: lower, dvReference: 20, matchIndex: matchIndex)
            } else if matchesLabel(lower, "trans fat") {
                result.transFat = extractGramsDouble(from: lower, matchIndex: matchIndex)
            } else if matchesLabel(lower, "total carbohydrate") || matchesLabel(lower, "total carb") {
                result.carbs = extractGrams(from: lower, matchIndex: matchIndex)
                    ?? extractFromDailyValue(from: lower, dvReference: 275, matchIndex: matchIndex).map { Int($0.rounded()) }
            } else if matchesLabel(lower, "dietary fiber") {
                result.fiber = extractGramsDouble(from: lower, matchIndex: matchIndex)
                    ?? extractFromDailyValue(from: lower, dvReference: 28, matchIndex: matchIndex)
            } else if matchesLabel(lower, "added sugars") || matchesLabel(lower, "added sugar") {
                result.addedSugar = extractGramsDouble(from: lower, matchIndex: matchIndex)
                    ?? extractFromDailyValue(from: lower, dvReference: 50, matchIndex: matchIndex)
            } else if matchesLabel(lower, "total sugars") || matchesLabel(lower, "sugars") {
                result.sugar = extractGramsDouble(from: lower, matchIndex: matchIndex)
            } else if matchesLabel(lower, "protein") {
                result.protein = extractGrams(from: lower, matchIndex: matchIndex)
                    ?? extractFromDailyValue(from: lower, dvReference: 50, matchIndex: matchIndex).map { Int($0.rounded()) }
            } else if matchesLabel(lower, "cholesterol") {
                result.cholesterol = extractMilligrams(from: lower, matchIndex: matchIndex)
                    ?? extractFromDailyValue(from: lower, dvReference: 300, matchIndex: matchIndex)
            } else if matchesLabel(lower, "sodium") {
                result.sodium = extractMilligrams(from: lower, matchIndex: matchIndex)
                    ?? extractFromDailyValue(from: lower, dvReference: 2300, matchIndex: matchIndex)
            } else if matchesLabel(lower, "vitamin d") {
                result.vitaminD = extractMicrogramsOrMg(from: lower, matchIndex: matchIndex)
                    ?? extractFromDailyValue(from: lower, dvReference: 20, matchIndex: matchIndex)
            } else if matchesLabel(lower, "vitamin a") {
                result.vitaminA = extractMicrogramsOrMg(from: lower, matchIndex: matchIndex)
                    ?? extractFromDailyValue(from: lower, dvReference: 900, matchIndex: matchIndex)
            } else if matchesLabel(lower, "vitamin c") {
                result.vitaminC = extractMilligrams(from: lower, matchIndex: matchIndex)
                    ?? extractFromDailyValue(from: lower, dvReference: 90, matchIndex: matchIndex)
            } else if matchesLabel(lower, "vitamin e") {
                result.vitaminE = extractMilligrams(from: lower, matchIndex: matchIndex)
                    ?? extractFromDailyValue(from: lower, dvReference: 15, matchIndex: matchIndex)
            } else if matchesLabel(lower, "vitamin b12") || matchesLabel(lower, "vitamin b-12") {
                result.vitaminB12 = extractMicrogramsOrMg(from: lower, matchIndex: matchIndex)
                    ?? extractFromDailyValue(from: lower, dvReference: 2.4, matchIndex: matchIndex)
            } else if matchesLabel(lower, "thiamin") || matchesLabel(lower, "thiamine") {
                result.thiamin = extractMilligrams(from: lower, matchIndex: matchIndex)
                    ?? extractFromDailyValue(from: lower, dvReference: 1.2, matchIndex: matchIndex)
            } else if matchesLabel(lower, "riboflavin") {
                result.riboflavin = extractMilligrams(from: lower, matchIndex: matchIndex)
                    ?? extractFromDailyValue(from: lower, dvReference: 1.3, matchIndex: matchIndex)
            } else if matchesLabel(lower, "niacin") {
                result.niacin = extractMilligrams(from: lower, matchIndex: matchIndex)
                    ?? extractFromDailyValue(from: lower, dvReference: 16, matchIndex: matchIndex)
            } else if matchesLabel(lower, "folate") || matchesLabel(lower, "folic acid") {
                result.folate = extractMicrogramsOrMg(from: lower, matchIndex: matchIndex)
                    ?? extractFromDailyValue(from: lower, dvReference: 400, matchIndex: matchIndex)
            } else if matchesLabel(lower, "calcium") {
                result.calcium = extractMilligrams(from: lower, matchIndex: matchIndex)
                    ?? extractFromDailyValue(from: lower, dvReference: 1300, matchIndex: matchIndex)
            } else if matchesLabel(lower, "iron") {
                result.iron = extractMilligrams(from: lower, matchIndex: matchIndex)
                    ?? extractFromDailyValue(from: lower, dvReference: 18, matchIndex: matchIndex)
            } else if matchesLabel(lower, "potassium") {
                result.potassium = extractMilligrams(from: lower, matchIndex: matchIndex)
                    ?? extractFromDailyValue(from: lower, dvReference: 4700, matchIndex: matchIndex)
            } else if matchesLabel(lower, "magnesium") {
                result.magnesium = extractMilligrams(from: lower, matchIndex: matchIndex)
                    ?? extractFromDailyValue(from: lower, dvReference: 420, matchIndex: matchIndex)
            } else if matchesLabel(lower, "phosphorus") {
                result.phosphorus = extractMilligrams(from: lower, matchIndex: matchIndex)
                    ?? extractFromDailyValue(from: lower, dvReference: 1250, matchIndex: matchIndex)
            } else if matchesLabel(lower, "zinc") {
                result.zinc = extractMilligrams(from: lower, matchIndex: matchIndex)
                    ?? extractFromDailyValue(from: lower, dvReference: 11, matchIndex: matchIndex)
            } else if matchesLabel(lower, "omega-3") || matchesLabel(lower, "omega 3") || matchesLabel(lower, "dha") || matchesLabel(lower, "epa") {
                result.omega3 = extractGramsOrMilligramsAsGrams(from: lower, matchIndex: matchIndex)
            }
        }

        recoverSplitLineValues(from: normalized, into: &result)
        applySanityLimits(to: &result)

        return result
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
                    ?? extractFromDailyValue(from: valueLine, dvReference: 20)
            } else if result.transFat == nil, matchesLabel(labelLine, "trans fat") {
                result.transFat = extractGramsDouble(from: valueLine)
            } else if result.fiber == nil, matchesLabel(labelLine, "dietary fiber") {
                result.fiber = extractGramsDouble(from: valueLine)
                    ?? extractFromDailyValue(from: valueLine, dvReference: 28)
            } else if result.addedSugar == nil, matchesLabel(labelLine, "added sugars") || matchesLabel(labelLine, "added sugar") {
                result.addedSugar = extractGramsDouble(from: valueLine)
                    ?? extractFromDailyValue(from: valueLine, dvReference: 50)
            } else if result.cholesterol == nil, matchesLabel(labelLine, "cholesterol") {
                result.cholesterol = extractMilligrams(from: valueLine)
                    ?? extractFromDailyValue(from: valueLine, dvReference: 300)
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

    private static func extractInt(from text: String, matchIndex: Int = 0) -> Int? {
        guard let value = extractFirstBareNumber(from: text, matchIndex: matchIndex) else { return nil }
        return Int(value.rounded())
    }

    private static func extractGrams(from text: String, matchIndex: Int = 0) -> Int? {
        guard let value = extractGramsDouble(from: text, matchIndex: matchIndex) else { return nil }
        return Int(value.rounded())
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
            return mg
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

    private static func extractFromDailyValue(from text: String, dvReference: Double, matchIndex: Int = 0) -> Double? {
        let pattern = #"(\d+\.?\d*)\s*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)
        guard matches.count > matchIndex,
              let range = Range(matches[matchIndex].range(at: 1), in: text),
              let percent = Double(text[range]) else { return nil }
        return dvReference * percent / 100
    }

    private static func extractFirstNumericWithUnit(from text: String, unit: String, matchIndex: Int = 0) -> Double? {
        let escaped = NSRegularExpression.escapedPattern(for: unit)
        let pattern = #"(\d+\.?\d*)\s*"# + escaped
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)
        guard matches.count > matchIndex,
              let range = Range(matches[matchIndex].range(at: 1), in: text) else { return nil }
        return Double(text[range])
    }

    // Only counts matches that don't satisfy excludePattern toward matchIndex.
    private static func extractNumericBeforeUnit(from text: String, unitPattern: String, excludePattern: String, matchIndex: Int = 0) -> Double? {
        let pattern = #"(\d+\.?\d*)\s*"# + unitPattern
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
                return Double(text[numberRange])
            }
            validCount += 1
        }
        return nil
    }

    // Forward iteration; matchIndex selects which non-percentage numeric token to return.
    private static func extractFirstBareNumber(from text: String, matchIndex: Int = 0) -> Double? {
        let pattern = #"(\d+\.?\d*)"#
        let components = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var count = 0
        for component in components {
            guard component.contains("%") == false,
                  let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: component, range: NSRange(component.startIndex..., in: component)),
                  let range = Range(match.range(at: 1), in: component) else { continue }
            if count == matchIndex { return Double(component[range]) }
            count += 1
        }
        return nil
    }
}
#endif
