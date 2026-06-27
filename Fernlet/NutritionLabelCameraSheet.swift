import SwiftUI

#if canImport(UIKit)
import PhotosUI
import UIKit
import FernletDomainModel

struct NutritionLabelCameraSheet: View {
    @Environment(\.dismiss) private var dismiss
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

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Take a photo of a nutrition facts label and Fernlet will fill in the values it can read.")
                        .font(.callout)
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()

                    HStack(spacing: 12) {
                        Button {
                            showingCamera = true
                        } label: {
                            Label("Camera", systemImage: "camera.fill")
                                .font(.headline)
                                .foregroundStyle(Color.cream)
                                .frame(maxWidth: .infinity)
                                .padding(14)
                                .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            Label("Library", systemImage: "photo.on.rectangle")
                                .font(.headline)
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
                                        .font(.callout.italic())
                                        .foregroundStyle(Color.slate)
                                }
                                .frame(maxWidth: .infinity, alignment: .center)
                            }

                            if shouldShowScanTips {
                                scanTips
                            }
                        }
                    }

                    if let dual = dualColumnResult {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("TWO-COLUMN LABEL DETECTED")
                                .font(.caption.weight(.semibold))
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
                                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
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

                    if let scanResult {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("DETECTED VALUES")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.slate)
                                .tracking(0.8)

                            VStack(alignment: .leading, spacing: 6) {
                                detectedValues(for: scanResult)
                            }
                            .padding(14)
                            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
                        }
                    }

                    if let scanError {
                        Text(scanError)
                            .font(.caption.italic())
                            .foregroundStyle(Color.red.opacity(0.8))
                            .fernletWrappingText()
                    }
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
        .fullScreenCover(isPresented: $showingCamera) {
            ImagePickerView(sourceType: .camera, flashMode: isFlashOn ? .on : .off) { image in
                handlePickedImage(image)
            }
            .ignoresSafeArea()
        }
        .onChange(of: selectedPhotoItem) { _, newValue in
            guard let newValue else { return }
            Task {
                if let data = try? await newValue.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    handlePickedImage(image)
                }
                selectedPhotoItem = nil
            }
        }
    }

    private var hasCameraFlash: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera) &&
        UIImagePickerController.isFlashAvailable(for: .rear)
    }

    private var shouldShowScanTips: Bool {
        scanError != nil || scanResult.map { detectedFieldCount(in: $0) < 3 } == true
    }

    private var scanTips: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Try tilting the product slightly to reduce glare.")
            Text("Move closer so the label fills the frame.")
            Text("Use the flashlight in dim lighting.")
        }
        .font(.caption.italic())
        .foregroundStyle(Color.slate)
        .fernletWrappingText()
    }

    @ViewBuilder
    private func detectedValues(for scanResult: NutritionLabelResult) -> some View {
        if hasMacroValues(in: scanResult) {
            detectedGroup("Macros") {
                if let calories = scanResult.calories {
                    detectedRow("Calories", "\(calories)")
                }
                if let protein = scanResult.protein {
                    detectedRow("Protein", "\(protein)g")
                }
                if let carbs = scanResult.carbs {
                    detectedRow("Carbs", "\(carbs)g")
                }
                if let fat = scanResult.fat {
                    detectedRow("Fat", "\(fat)g")
                }
            }
        }

        if hasLabelDetailValues(in: scanResult) {
            detectedGroup("Label details") {
                if let servingSize = scanResult.servingSize {
                    detectedRow("Serving size", servingSize)
                }
                if let servings = scanResult.servingsPerContainer {
                    detectedRow("Servings", "\(servings)")
                }
                if let saturatedFat = scanResult.saturatedFat {
                    detectedRow("Saturated fat", formatted(saturatedFat, unit: "g"))
                }
                if let transFat = scanResult.transFat {
                    detectedRow("Trans fat", formatted(transFat, unit: "g"))
                }
                if let cholesterol = scanResult.cholesterol {
                    detectedRow("Cholesterol", formatted(cholesterol, unit: "mg"))
                }
                if let sodium = scanResult.sodium {
                    detectedRow("Sodium", formatted(sodium, unit: "mg"))
                }
                if let fiber = scanResult.fiber {
                    detectedRow("Fiber", formatted(fiber, unit: "g"))
                }
                if let sugar = scanResult.sugar {
                    detectedRow("Sugar", formatted(sugar, unit: "g"))
                }
                if let addedSugar = scanResult.addedSugar {
                    detectedRow("Added sugar", formatted(addedSugar, unit: "g"))
                }
            }
        }

        if hasVitaminAndMineralValues(in: scanResult) {
            detectedGroup("Vitamins & minerals") {
                if let vitaminA = scanResult.vitaminA {
                    detectedRow("Vitamin A", formatted(vitaminA, unit: "mcg"))
                }
                if let vitaminC = scanResult.vitaminC {
                    detectedRow("Vitamin C", formatted(vitaminC, unit: "mg"))
                }
                if let vitaminD = scanResult.vitaminD {
                    detectedRow("Vitamin D", formatted(vitaminD, unit: "mcg"))
                }
                if let vitaminE = scanResult.vitaminE {
                    detectedRow("Vitamin E", formatted(vitaminE, unit: "mg"))
                }
                if let vitaminB12 = scanResult.vitaminB12 {
                    detectedRow("Vitamin B12", formatted(vitaminB12, unit: "mcg"))
                }
                if let thiamin = scanResult.thiamin {
                    detectedRow("Thiamin", formatted(thiamin, unit: "mg"))
                }
                if let riboflavin = scanResult.riboflavin {
                    detectedRow("Riboflavin", formatted(riboflavin, unit: "mg"))
                }
                if let niacin = scanResult.niacin {
                    detectedRow("Niacin", formatted(niacin, unit: "mg"))
                }
                if let folate = scanResult.folate {
                    detectedRow("Folate", formatted(folate, unit: "mcg"))
                }
                if let calcium = scanResult.calcium {
                    detectedRow("Calcium", formatted(calcium, unit: "mg"))
                }
                if let iron = scanResult.iron {
                    detectedRow("Iron", formatted(iron, unit: "mg"))
                }
                if let magnesium = scanResult.magnesium {
                    detectedRow("Magnesium", formatted(magnesium, unit: "mg"))
                }
                if let phosphorus = scanResult.phosphorus {
                    detectedRow("Phosphorus", formatted(phosphorus, unit: "mg"))
                }
                if let potassium = scanResult.potassium {
                    detectedRow("Potassium", formatted(potassium, unit: "mg"))
                }
                if let zinc = scanResult.zinc {
                    detectedRow("Zinc", formatted(zinc, unit: "mg"))
                }
                if let omega3 = scanResult.omega3 {
                    detectedRow("Omega-3", formatted(omega3, unit: "g"))
                }
            }
        }
    }

    private func detectedGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.slate)
            content()
        }
        .padding(.vertical, 4)
    }

    private func detectedRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.bark)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.moss)
        }
    }

    private func hasMacroValues(in result: NutritionLabelResult) -> Bool {
        result.calories != nil || result.protein != nil || result.carbs != nil || result.fat != nil
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

    private func detectedFieldCount(in result: NutritionLabelResult) -> Int {
        [
            result.servingSize.map { _ in true },
            result.servingsPerContainer.map { _ in true },
            result.calories.map { _ in true },
            result.protein.map { _ in true },
            result.carbs.map { _ in true },
            result.fat.map { _ in true },
            result.fiber.map { _ in true },
            result.sugar.map { _ in true },
            result.addedSugar.map { _ in true },
            result.saturatedFat.map { _ in true },
            result.transFat.map { _ in true },
            result.cholesterol.map { _ in true },
            result.vitaminA.map { _ in true },
            result.vitaminC.map { _ in true },
            result.vitaminD.map { _ in true },
            result.vitaminE.map { _ in true },
            result.vitaminB12.map { _ in true },
            result.thiamin.map { _ in true },
            result.riboflavin.map { _ in true },
            result.niacin.map { _ in true },
            result.folate.map { _ in true },
            result.calcium.map { _ in true },
            result.iron.map { _ in true },
            result.magnesium.map { _ in true },
            result.phosphorus.map { _ in true },
            result.potassium.map { _ in true },
            result.sodium.map { _ in true },
            result.zinc.map { _ in true },
            result.omega3.map { _ in true }
        ]
        .compactMap { $0 }
        .count
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

        Task {
            do {
                let (primary, dual) = try await NutritionLabelScanner.scanAll(image: image)
                dualColumnResult = dual
                scanResult = primary
            } catch {
                scanError = (error as? LocalizedError)?.errorDescription ?? "Could not read that label."
            }
            isScanning = false
        }
    }

}

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
