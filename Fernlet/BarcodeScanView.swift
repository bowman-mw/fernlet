import SwiftUI

#if canImport(UIKit)
import UIKit
import Vision
import VisionKit
import PhotosUI
import FernletDomainModel
import FoodCatalog
import AppServices

// MARK: - Scan → resolve → remember flow

/// Scan a product barcode and resolve it to a food item as one pushable flow:
/// user items (a previously paired product) → bundled catalog (when a future database carries UPC
/// data) → gentle not-found path that creates a user food item WITH the barcode remembered, so the
/// next scan of the same product hits instantly. Calls `onResolved` exactly once.
struct BarcodeResolveFlowView: View {
    var store: FernletStore
    var onResolved: (FoodItem) -> Void
    @State private var notFound: ScannedBarcode?

    var body: some View {
        BarcodeScanView { code in
            if let item = store.foodCatalog.item(forBarcode: code) {
                onResolved(item)
            } else {
                notFound = ScannedBarcode(code: code)
            }
        }
        .navigationDestination(item: $notFound) { scanned in
            BarcodeNotFoundView(store: store, barcode: scanned.code, onCreated: onResolved)
        }
    }
}

struct ScannedBarcode: Identifiable, Hashable {
    let code: String
    var id: String { code }
}

// MARK: - Scanner screen

/// Live barcode viewfinder (VisionKit `DataScannerViewController`) with a graceful still-photo
/// fallback (`VNDetectBarcodesRequest` over the existing `ImagePickerView`/`PhotosPicker`) for
/// devices and simulators where the live scanner is unsupported. Delivers the raw payload string;
/// callers normalize via `FoodCatalog.item(forBarcode:)` / `FoodBarcode`.
struct BarcodeScanView: View {
    var detector: any BarcodePayloadDetecting = VisionBarcodeDetector()
    var onCode: (String) -> Void

    @State private var showingCamera = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var stillImage: UIImage?
    @State private var isDetecting = false
    @State private var detectionNotice: String?
    /// Set when the live scanner reports it became unavailable at runtime (camera permission denied
    /// after the viewfinder presented) — flips us to the still-photo fallback so the user never
    /// stares at a frozen black viewfinder. Reset on foreground so enabling access in Settings retries.
    @State private var liveScannerUnavailable = false

    @Environment(\.scenePhase) private var scenePhase

    private var liveScannerAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable && !liveScannerUnavailable
    }

    var body: some View {
        VStack(spacing: 0) {
            if liveScannerAvailable {
                BarcodeDataScannerView(
                    onPayload: { payload in onCode(payload) },
                    onUnavailable: {
                        // Camera access was denied (or the scanner otherwise went unavailable) — drop
                        // to the still-photo fallback with a gentle hint instead of a dead viewfinder.
                        liveScannerUnavailable = true
                        detectionNotice = "Camera access looks off — you can turn it on in Settings, or snap or choose a photo of the barcode below."
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(20)

                Text("Point the camera at the product's barcode.")
                    .font(.callout)
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            } else {
                stillPhotoFallback
            }
        }
        .background(Color.parchment)
        .navigationTitle("Scan barcode")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, newPhase in
            // Returning from Settings (where the user may have just enabled camera access) retries
            // the live scanner; if it's still denied, becameUnavailable flips us back.
            if newPhase == .active, liveScannerUnavailable { liveScannerUnavailable = false }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            ImagePickerView(sourceType: .camera) { image in
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

    private var stillPhotoFallback: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Take a photo of the product's barcode and Fernlet will read it.")
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
                }

                if let stillImage {
                    Image(uiImage: stillImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
                        .frame(maxWidth: .infinity)
                }

                if isDetecting {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Looking for a barcode...")
                            .font(.callout.italic())
                            .foregroundStyle(Color.slate)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }

                if let detectionNotice {
                    Text(detectionNotice)
                        .font(.caption.italic())
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
            }
            .padding(20)
            .padding(.bottom, 10)
        }
    }

    private func handlePickedImage(_ image: UIImage) {
        stillImage = image
        detectionNotice = nil
        isDetecting = true
        Task {
            let payload = try? await detector.payload(in: image)
            isDetecting = false
            if let payload {
                onCode(payload)
            } else {
                detectionNotice = "Fernlet couldn't spot a barcode in that photo — try moving closer so the code fills the frame."
            }
        }
    }
}

// MARK: - Live viewfinder (VisionKit)

private struct BarcodeDataScannerView: UIViewControllerRepresentable {
    var onPayload: (String) -> Void
    var onUnavailable: () -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: BarcodeScanner.symbologies)],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !scanner.isScanning else { return }
        // Re-arm after a pop back into the scanner (delivery stops scanning below). If arming throws
        // (e.g. permission just denied), surface it so the parent drops to the still-photo fallback
        // rather than leaving a frozen viewfinder.
        context.coordinator.delivered = false
        do {
            try scanner.startScanning()
        } catch {
            context.coordinator.reportUnavailable()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPayload: onPayload, onUnavailable: onUnavailable) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onPayload: (String) -> Void
        let onUnavailable: () -> Void
        var delivered = false
        private var reportedUnavailable = false

        init(onPayload: @escaping (String) -> Void, onUnavailable: @escaping () -> Void) {
            self.onPayload = onPayload
            self.onUnavailable = onUnavailable
        }

        func reportUnavailable() {
            guard !reportedUnavailable else { return }
            reportedUnavailable = true
            onUnavailable()
        }

        // VisionKit gives this a no-op default, so it MUST be implemented explicitly or a runtime
        // denial (camera access off) is silently swallowed and the viewfinder freezes.
        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            reportUnavailable()
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    delivered = true
                    dataScanner.stopScanning()
                    onPayload(payload)
                    return
                }
            }
        }
    }
}

// MARK: - Not-found: pair the barcode with a new user food

/// Gentle landing for a barcode Fernlet doesn't know: name the product, optionally scan its
/// nutrition label (the existing `NutritionLabelScanner` flow), and it becomes a user `FoodItem`
/// with the barcode remembered — the next scan resolves instantly via `FoodCatalog.item(forBarcode:)`.
///
/// TODO (future opt-in): resolve unknown barcodes via a web UPC lookup behind the existing
/// `webNutritionLookupEnabled` setting (`FoodProductWebImporter` pattern). Deliberately NOT wired
/// this pass — barcode scanning stays fully offline.
struct BarcodeNotFoundView: View {
    var store: FernletStore
    let barcode: String
    var onCreated: (FoodItem) -> Void

    @State private var name = ""
    @State private var scanResult: NutritionLabelResult?
    @State private var showingLabelScanner = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("New to Fernlet")
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(Color.bark)

                    Text("Fernlet doesn't know this barcode yet. Give it a name — and scan the nutrition label if you like — and Fernlet will remember it for next time.")
                        .font(.callout)
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()

                    SheetField("Name") {
                        TextField("oat granola bar", text: $name)
                            .sheetTextInput()
                    }

                    Button {
                        showingLabelScanner = true
                    } label: {
                        Label(scanResult == nil ? "Scan the nutrition label" : "Rescan the nutrition label", systemImage: "camera.viewfinder")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.moss)
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    if let scanResult {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("FROM THE LABEL")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.slate)
                                .tracking(0.8)
                            // Macros-first: the scanned calories are deliberately not rendered here.
                            Text("P \(scanResult.protein ?? 0)g · C \(scanResult.carbs ?? 0)g · F \(scanResult.fat ?? 0)g")
                                .font(.headline)
                                .foregroundStyle(Color.bark)
                            if let servingSize = scanResult.servingSize {
                                Text("Per serving: \(servingSize)")
                                    .font(.caption)
                                    .foregroundStyle(Color.slate)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        Text("Scanning the label fills in the macros — you can also add them later.")
                            .font(.caption.italic())
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: "Remember this food", disabled: trimmedName.isEmpty) {
                let micros = scanResult?.micronutrients()
                let input = ManualRecipeIngredientInput(
                    name: trimmedName,
                    quantity: 1,
                    unit: RecipeUnit.serving.rawValue,
                    protein: scanResult?.protein ?? 0,
                    carbs: scanResult?.carbs ?? 0,
                    fat: scanResult?.fat ?? 0,
                    scannedMicronutrients: micros?.hasAnyValue == true ? micros : nil,
                    barcode: barcode
                )
                guard let item = store.saveCustomIngredient(input) else { return }
                onCreated(item)
            }
        }
        .background(Color.parchment)
        .navigationTitle("Remember product")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingLabelScanner) {
            NutritionLabelCameraSheet(showCalories: store.settings.showCalories) { result in
                scanResult = result
                if trimmedName.isEmpty, let servingSize = result.servingSize, servingSize.isEmpty == false {
                    name = "Scanned item (\(servingSize))"
                }
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#endif
