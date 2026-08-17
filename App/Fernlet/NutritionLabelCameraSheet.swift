import SwiftUI

#if canImport(UIKit)
import PhotosUI
import UIKit
import FernletDomainModel
import AppServices
import FernletUI

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
                VStack(alignment: .leading, spacing: 22) {
                    Text("Take a photo of a nutrition facts label and Fernlet will fill in the values it can read.")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.slate)
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
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: "Use values", disabled: scanResult == nil || isScanning) {
                if let scanResult {
                    onResult(scanResult)
                    dismiss()
                }
            }
        }
        .background(Color.parchment)
        .navigationTitle("Scan label")
        .navigationBarTitleDisplayMode(.inline)
        .photoCapturePlumbing(
            showingCamera: $showingCamera,
            selection: $selectedPhotoItem,
            flashMode: isFlashOn ? .on : .off,
            onCameraImage: handlePickedImage
        )
        .onDisappear { scanTask?.cancel() }
    }

    /// Camera / library / flash — the three ways a label image gets here.
    private var sourceButtons: some View {
        HStack(spacing: 12) {
            Button {
                showingCamera = true
            } label: {
                Label("Camera", systemImage: "camera.fill")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.cream)
                    .frame(maxWidth: .infinity)
                    .padding(14)
                    .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                Label("Library", systemImage: "photo.on.rectangle")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
                    .frame(maxWidth: .infinity)
                    .padding(14)
                    .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button {
                isFlashOn.toggle()
            } label: {
                Image(systemName: isFlashOn ? "bolt.fill" : "bolt.slash.fill")
                    .font(.headline)
                    .foregroundStyle(isFlashOn ? Color.cream : Color.bark)
                    .frame(width: 48, height: 48)
                    .background(isFlashOn ? Color.moss : Color.cream, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(hasCameraFlash == false)
        }
    }

    /// The picked image with its scanning spinner and (on a weak read) the framing/glare tips.
    @ViewBuilder
    private var imagePreview: some View {
        if let selectedImage {
            VStack(alignment: .leading, spacing: 10) {
                Image(uiImage: selectedImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
                    .frame(maxWidth: .infinity)

                if isScanning {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Reading label...")
                            .font(.fernlet(.bubble))
                            .foregroundStyle(Color.slate)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }

                if shouldShowScanTips {
                    scanTips
                }
            }
        }
    }

    /// The per-serving / per-container column picker shown for a two-column label.
    private func dualColumnPicker(_ dual: DualColumnScanResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TWO-COLUMN LABEL DETECTED")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .tracking(0.8)

            HStack(spacing: 0) {
                ForEach([0, 1], id: \.self) { index in
                    let label = index == 0 ? dual.col1Header : dual.col2Header
                    let isSelected = selectedDualColumn == index
                    Button {
                        selectedDualColumn = index
                        scanResult = index == 0 ? dual.col1 : dual.col2
                    } label: {
                        Text(label)
                            .font(.fernlet(.label))
                            .foregroundStyle(isSelected ? Color.bark : Color.slate)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(isSelected ? Color.cream : Color.clear)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color.bark.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.bark.opacity(0.10), lineWidth: 1))
        }
    }

    /// The "DETECTED VALUES" card wrapping the three value groups.
    private func detectedValuesCard(_ result: NutritionLabelResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DETECTED VALUES")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .tracking(0.8)

            VStack(alignment: .leading, spacing: 6) {
                detectedValues(for: result)
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
        }
    }

    /// The calm inline scan-failure line.
    @ViewBuilder
    private var errorLine: some View {
        if let scanError {
            Text(scanError)
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.terracotta)
                .fernletWrappingText()
        }
    }

    private var hasCameraFlash: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera) &&
        UIImagePickerController.isFlashAvailable(for: .rear)
    }

    private var shouldShowScanTips: Bool {
        scanError != nil || scanResult.map { $0.recognizedFieldCount < 3 } == true
    }

    private var scanTips: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Try tilting the product slightly to reduce glare.")
            Text("Move closer so the label fills the frame.")
            Text("Use the flashlight in dim lighting.")
        }
        .font(.fernlet(.bubble))
        .foregroundStyle(Color.slate)
        .fernletWrappingText()
    }

    /// One row of the detected-values tables: its label, where to read the value, and its unit.
    ///
    /// Data, not code — the label's Double-valued fields are near-identical rows, so they live in the
    /// two static tables below and render through one `ForEach`.
    private struct DetectedValueRow {
        let label: String
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
        ForEach(table, id: \.label) { row in
            if let value = result[keyPath: row.keyPath] {
                detectedRow(row.label, formatted(value, unit: row.unit))
            }
        }
    }

    private func detectedGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
            content()
        }
        .padding(.vertical, 4)
    }

    private func detectedRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
            Spacer()
            Text(value)
                .font(.fernlet(.stat))
                .foregroundStyle(Color.moss)
        }
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
            } catch {
                guard !Task.isCancelled else { return }
                scanError = (error as? LocalizedError)?.errorDescription ?? "Could not read that label."
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
