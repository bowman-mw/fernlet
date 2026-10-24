import SwiftUI

#if canImport(UIKit)
import PhotosUI
import UIKit
import FernletDomainModel
import AppServices
import FernletUI

/// A label already read, for ``NutritionLabelCameraSheet`` to open with: the photo, the reading, and
/// the two columns when the label had two.
struct NutritionLabelSheetSeed {
    var image: UIImage
    var result: NutritionLabelResult
    var dualColumn: DualColumnScanResult? = nil
}

/// The nutrition-label OCR screen: photograph (or pick) a nutrition-facts label, run
/// `NutritionLabelScanner` over it, review the detected values, and hand the chosen
/// `NutritionLabelResult` back through `onResult`.
///
/// Reached from the recipe editor's label scan, the barcode not-found handoff, and the capture
/// chooser. It handles two-column labels (per-serving vs. per-container) with a column picker, shows
/// glare/framing tips when a scan reads fewer than 3 fields, and offers a torch toggle for dim
/// lighting. Macros-first: the Calories row renders only behind the explicit `showCalories` opt-in —
/// the parsed value still passes through `onResult` untouched.
struct NutritionLabelCameraSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Macros-first: the detected Calories row renders only behind the explicit opt-in (the value
    /// is still parsed and passed through `onResult` untouched — only the display is gated).
    var showCalories: Bool = false
    /// The page Back returns to ("Remember"), already resolved; nil says "Back".
    var backTitle: String? = nil
    /// A label already read, to open with (the DEBUG screenshot gallery; nothing in shipping code
    /// passes one).
    var seed: NutritionLabelSheetSeed? = nil
    @Environment(\.fernletFramedLook) private var look
    var onResult: (NutritionLabelResult) -> Void

    @State private var showingCamera = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var isScanning = false
    @State private var scanError: String?
    @State private var scanResult: NutritionLabelResult?
    @State private var dualColumnResult: DualColumnScanResult?
    @State private var selectedDualColumn = 0
    @State private var isFlashOn = false
    /// The single in-flight label scan (see `handlePickedImage`); cancelled when a new image is picked
    /// and when the sheet goes away.
    @State private var scanTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Take a photo of a nutrition facts label and Fernlet will fill in the values it can read.")
                        .font(look == nil ? .fernlet(.body) : FernletFramedFont.body)
                        .foregroundStyle(look?.dim ?? Color.slate)
                        .fernletWrappingText()

                    sourceButtons

                    imagePreview

                    if let dual = dualColumnResult {
                        dualColumnPicker(dual)
                    }

                    if let scanResult {
                        detectedValuesCard(scanResult)
                    }

                    errorLine
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: "Use values", disabled: scanResult == nil || isScanning) {
                if let scanResult {
                    onResult(scanResult)
                    dismiss()
                }
            }
        }
        .foodSheetBackground()
        // b3-label-scan: a page pushed inside the sheet, its Back naming where it came from.
        .foodSheetPushedPage("Scan label", back: backTitle)
        .photoCapturePlumbing(
            showingCamera: $showingCamera,
            selection: $selectedPhotoItem,
            flashMode: isFlashOn ? .on : .off,
            onCameraImage: handlePickedImage
        )
        .onAppear(perform: applySeed)
        .onDisappear { scanTask?.cancel() }
    }

    /// Opens with the seed's photo and reading, once (a later appear keeps what was scanned since).
    private func applySeed() {
        guard let seed, selectedImage == nil else { return }
        selectedImage = seed.image
        dualColumnResult = seed.dualColumn
        scanResult = seed.dualColumn?.col1 ?? seed.result
    }

    /// Camera / library / flash — the three ways a label image gets here: the moss Camera, the framed
    /// Library, and the framed flash tile.
    private var sourceButtons: some View {
        HStack(spacing: 10) {
            Button { showingCamera = true } label: {
                HStack(spacing: 8) {
                    WorldSpriteView(sprite: FoodSprites.camera, scale: 2)
                    Text("Camera")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.primary))
            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                HStack(spacing: 8) {
                    WorldSpriteView(sprite: FoodSprites.library, scale: 2)
                    Text("Library")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.secondary))

            flashButton
        }
    }

    /// The flash: a framed tile with the pixel bolt, filled with the accent while on.
    private var flashButton: some View {
        Button { isFlashOn.toggle() } label: {
            FernletIconTile(size: 48, fill: isFlashOn ? (look?.accent ?? Color.moss) : nil, isControl: true) {
                WorldSpriteView(sprite: FoodSprites.bolt, scale: 3, tint: isFlashOn ? (look?.onAccent ?? Color.onMoss) : nil)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(hasCameraFlash == false)
        .opacity(hasCameraFlash ? 1 : 0.5)
        .accessibilityLabel(isFlashOn ? "Turn the flash off" : "Turn the flash on")
    }

    /// The picked photo in an ink frame, the "Reading label..." line while it reads, and the tips
    /// when the reading was thin.
    @ViewBuilder
    private var imagePreview: some View {
        if let selectedImage {
            VStack(alignment: .leading, spacing: 10) {
                Image(uiImage: selectedImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(look?.ink ?? Color.bark.opacity(0.10), lineWidth: 2))
                    .frame(maxWidth: .infinity)
                    .accessibilityIgnoresInvertColors()

                if isScanning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .accessibilityHidden(true)
                        Text("Reading label...")
                            .font(look == nil ? .fernlet(.bubble) : FernletFramedFont.note)
                            .foregroundStyle(look?.dim ?? Color.slate)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }

                if shouldShowScanTips {
                    scanTips
                }
            }
        }
    }

    /// The two columns of a two-column label (per serving, as prepared, …) as one framed segmented
    /// control under its label.
    private func dualColumnPicker(_ dual: DualColumnScanResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("TWO-COLUMN LABEL DETECTED")
            FernletSegmentedPicker("TWO-COLUMN LABEL DETECTED", selection: dualColumnSelection(dual), options: [0, 1]) { index in
                Text(verbatim: index == 0 ? dual.col1Header : dual.col2Header)
            }
        }
    }

    /// The chosen column, switching the values the sheet will use with it.
    private func dualColumnSelection(_ dual: DualColumnScanResult) -> Binding<Int> {
        Binding(get: { selectedDualColumn }, set: { index in
            selectedDualColumn = index
            scanResult = index == 0 ? dual.col1 : dual.col2
        })
    }

    /// The values read, in today's groups, on one framed card.
    private func detectedValuesCard(_ result: NutritionLabelResult) -> some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("DETECTED VALUES")
                detectedValues(for: result)
            }
        }
    }

    @ViewBuilder
    private var errorLine: some View {
        if let scanError {
            FernletNotice(text: Text(scanError), tone: .warn) { EmptyView() }
        }
    }
    private var hasCameraFlash: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera) &&
        UIImagePickerController.isFlashAvailable(for: .rear)
    }

    private var shouldShowScanTips: Bool {
        scanError != nil || scanResult.map { $0.recognizedFieldCount < Self.confidentFieldCount } == true
    }

    /// Fewer recognized fields than this and the scan tips show beside the values: a reading, but a
    /// thin one.
    static let confidentFieldCount = 3

    /// What a finished label scan feels like (§7): the person waited on it, so a confident reading is
    /// `done`, a thin one — values shown, with the retake tips beside them — is `caveat`, and a scan
    /// that read nothing (`nil`, it threw) is `failed` beside its error line.
    static func scanEvent(recognizedFieldCount: Int?) -> FernletFeedbackEvent {
        guard let recognizedFieldCount else { return .failed }
        return recognizedFieldCount < confidentFieldCount ? .caveat : .done
    }

    private var scanTips: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Try tilting the product slightly to reduce glare.")
            Text("Move closer so the label fills the frame.")
            Text("Use the flashlight in dim lighting.")
        }
        .font(look == nil ? .fernlet(.bubble) : FernletFramedFont.note)
        .foregroundStyle(look?.dim ?? Color.slate)
        .fernletWrappingText()
    }

    /// One row of the detected-values tables: its label, where to read the value, and its unit.
    ///
    /// Data, not code — the label's Double-valued fields are near-identical rows, so they live in the
    /// two static tables below and render through one `ForEach`. `label` is a `LocalizedStringKey`, so
    /// the table's literals reach the catalog (as `String` they were drawn verbatim); the key path,
    /// unique per row, is the row's identity.
    private struct DetectedValueRow {
        let label: LocalizedStringKey
        let keyPath: KeyPath<NutritionLabelResult, Double?>
        let unit: String
    }

    /// The Double-valued "Label details" rows, in display order.
    private static let labelDetailRows: [DetectedValueRow] = [
        DetectedValueRow(label: "Saturated fat", keyPath: \.saturatedFat, unit: "g"),
        DetectedValueRow(label: "Trans fat", keyPath: \.transFat, unit: "g"),
        DetectedValueRow(label: "Cholesterol", keyPath: \.cholesterol, unit: "mg"),
        DetectedValueRow(label: "Sodium", keyPath: \.sodium, unit: "mg"),
        DetectedValueRow(label: "Fiber", keyPath: \.fiber, unit: "g"),
        DetectedValueRow(label: "Sugar", keyPath: \.sugar, unit: "g"),
        DetectedValueRow(label: "Added sugar", keyPath: \.addedSugar, unit: "g")
    ]

    /// The "Vitamins & minerals" rows, in display order.
    private static let vitaminRows: [DetectedValueRow] = [
        DetectedValueRow(label: "Vitamin A", keyPath: \.vitaminA, unit: "mcg"),
        DetectedValueRow(label: "Vitamin C", keyPath: \.vitaminC, unit: "mg"),
        DetectedValueRow(label: "Vitamin D", keyPath: \.vitaminD, unit: "mcg"),
        DetectedValueRow(label: "Vitamin E", keyPath: \.vitaminE, unit: "mg"),
        DetectedValueRow(label: "Vitamin B12", keyPath: \.vitaminB12, unit: "mcg"),
        DetectedValueRow(label: "Thiamin", keyPath: \.thiamin, unit: "mg"),
        DetectedValueRow(label: "Riboflavin", keyPath: \.riboflavin, unit: "mg"),
        DetectedValueRow(label: "Niacin", keyPath: \.niacin, unit: "mg"),
        DetectedValueRow(label: "Folate", keyPath: \.folate, unit: "mcg"),
        DetectedValueRow(label: "Calcium", keyPath: \.calcium, unit: "mg"),
        DetectedValueRow(label: "Iron", keyPath: \.iron, unit: "mg"),
        DetectedValueRow(label: "Magnesium", keyPath: \.magnesium, unit: "mg"),
        DetectedValueRow(label: "Phosphorus", keyPath: \.phosphorus, unit: "mg"),
        DetectedValueRow(label: "Potassium", keyPath: \.potassium, unit: "mg"),
        DetectedValueRow(label: "Zinc", keyPath: \.zinc, unit: "mg"),
        DetectedValueRow(label: "Omega-3", keyPath: \.omega3, unit: "g")
    ]

    @ViewBuilder
    private func detectedValues(for scanResult: NutritionLabelResult) -> some View {
        if hasMacroValues(in: scanResult) {
            macroGroup(scanResult)
        }

        if hasLabelDetailValues(in: scanResult) {
            labelDetailGroup(scanResult)
        }

        if hasVitaminAndMineralValues(in: scanResult) {
            detectedGroup("Vitamins & minerals") {
                rows(Self.vitaminRows, of: scanResult)
            }
        }
    }

    /// Calories (only behind the opt-in) plus the three macros — all Int-typed on the label.
    private func macroGroup(_ result: NutritionLabelResult) -> some View {
        detectedGroup("Macros") {
            if showCalories, let calories = result.calories {
                detectedRow("Calories", "\(calories)")
            }
            if let protein = result.protein {
                detectedRow("Protein", "\(protein)g")
            }
            if let carbs = result.carbs {
                detectedRow("Carbs", "\(carbs)g")
            }
            if let fat = result.fat {
                detectedRow("Fat", "\(fat)g")
            }
        }
    }

    /// Serving size / servings (their own types) plus the Double-valued detail table.
    private func labelDetailGroup(_ result: NutritionLabelResult) -> some View {
        detectedGroup("Label details") {
            if let servingSize = result.servingSize {
                detectedRow("Serving size", servingSize)
            }
            if let servings = result.servingsPerContainer {
                detectedRow("Servings", "\(servings)")
            }
            rows(Self.labelDetailRows, of: result)
        }
    }

    /// Renders the rows of a table whose value is present on `result`.
    @ViewBuilder
    private func rows(_ table: [DetectedValueRow], of result: NutritionLabelResult) -> some View {
        ForEach(table, id: \.keyPath) { row in
            if let value = result[keyPath: row.keyPath] {
                detectedRow(row.label, formatted(value, unit: row.unit))
            }
        }
    }

    private func detectedGroup<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(FoodFont.noteStrong)
                .foregroundStyle(look?.dim ?? Color.slate)
                .padding(.bottom, 4)
            content()
        }
        .padding(.vertical, 4)
    }

    /// One detected value: its localized name, and the value as read (numbers and unit symbols).
    /// A key-value row with a dotted rule above it (`.kv`), the value in bold.
    private func detectedRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        FernletKeyValueRow(label, value: Text(verbatim: value))
    }

    private func hasMacroValues(in result: NutritionLabelResult) -> Bool {
        // Calories only count as a displayable value when their row is opted in — otherwise a
        // calories-only scan would render an empty "Macros" group.
        (showCalories && result.calories != nil) || result.protein != nil || result.carbs != nil || result.fat != nil
    }

    private func hasLabelDetailValues(in result: NutritionLabelResult) -> Bool {
        result.servingSize != nil || result.servingsPerContainer != nil || result.saturatedFat != nil ||
        result.transFat != nil || result.cholesterol != nil || result.sodium != nil ||
        result.fiber != nil || result.sugar != nil || result.addedSugar != nil
    }

    private func hasVitaminAndMineralValues(in result: NutritionLabelResult) -> Bool {
        result.vitaminA != nil || result.vitaminC != nil || result.vitaminD != nil ||
        result.vitaminE != nil || result.vitaminB12 != nil || result.folate != nil ||
        result.thiamin != nil || result.riboflavin != nil || result.niacin != nil ||
        result.calcium != nil || result.iron != nil || result.magnesium != nil ||
        result.phosphorus != nil || result.potassium != nil || result.zinc != nil ||
        result.omega3 != nil
    }

    private func formatted(_ value: Double, unit: String) -> String {
        let text = value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return "\(text)\(unit)"
    }

    private func handlePickedImage(_ image: UIImage) {
        selectedImage = image
        scanError = nil
        scanResult = nil
        dualColumnResult = nil
        selectedDualColumn = 0
        isScanning = true

        // R3: exactly one scan in flight — picking a second label cancels the first, so its result
        // can never land after the reset and be shown for the wrong image.
        scanTask?.cancel()
        scanTask = Task {
            do {
                let (primary, dual) = try await NutritionLabelScanner.scanAll(image: image)
                guard !Task.isCancelled else { return }
                dualColumnResult = dual
                scanResult = primary
                FernletFeedback.system.play(Self.scanEvent(recognizedFieldCount: primary.recognizedFieldCount))
            } catch {
                guard !Task.isCancelled else { return }
                scanError = (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "labelScan.error.fallback",
                              defaultValue: "Could not read that label.",
                              comment: "Shown in the nutrition-label camera sheet when the scan fails and the thrown error carries no description of its own.")
                FernletFeedback.system.play(Self.scanEvent(recognizedFieldCount: nil))
            }
            isScanning = false
        }
    }

}

/// A `UIViewControllerRepresentable` wrapper around `UIImagePickerController` for camera capture
/// (with an optional flash mode) or library picking.
///
/// Shared by the label scanner, the barcode still-photo fallback, and other food-capture flows;
/// delivers the original `UIImage` through `onImagePicked` and dismisses itself on pick or cancel.
struct ImagePickerView: UIViewControllerRepresentable {
    var sourceType: UIImagePickerController.SourceType = .camera
    var flashMode: UIImagePickerController.CameraFlashMode = .auto
    var onImagePicked: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        if sourceType == .camera {
            picker.cameraCaptureMode = .photo
            picker.cameraDevice = .rear
            if UIImagePickerController.isFlashAvailable(for: .rear) {
                picker.cameraFlashMode = flashMode
            }
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
        guard sourceType == .camera, UIImagePickerController.isFlashAvailable(for: .rear) else { return }
        uiViewController.cameraFlashMode = flashMode
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked)
    }

    /// The picker's delegate: forwards the picked original image to `onImagePicked` and dismisses
    /// the controller on both pick and cancel.
    ///
    /// `UINavigationControllerDelegate` conformance is required by `UIImagePickerController.delegate`
    /// even though no navigation callbacks are used.
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImagePicked: (UIImage) -> Void

        init(onImagePicked: @escaping (UIImage) -> Void) {
            self.onImagePicked = onImagePicked
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onImagePicked(image)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

#endif

/// The name a nutrition-label scan pre-fills into an empty name field — the recipe editor's and the
/// barcode "name it & remember" screen's (Spanish round step 2, 2026-10-20).
///
/// A pre-fill, not a stored default: the person sees it in an editable field and saves it as their own
/// words, and nothing reads it back as a token, so it is written in their language.
nonisolated enum ScannedItemName {
    /// "Scanned item (2 cookies (30g))" when the label printed a serving size, else "Scanned item".
    static func prefill(servingSize: String?) -> String {
        guard let servingSize, !servingSize.isEmpty else {
            return String(localized: "scan.itemName.default", defaultValue: "Scanned item",
                          comment: "Pre-filled name of a food or recipe read from a nutrition label. The person can edit it.")
        }
        return String(localized: "scan.itemName.withServing", defaultValue: "Scanned item (\(servingSize))",
                      comment: "Pre-filled name of a food or recipe read from a nutrition label. The argument is the serving size the label printed, as printed (e.g. '2 cookies (30g)'). The person can edit it.")
    }
}
