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

// MARK: - Local palette (barcode handoff mockup 11a–11c)

/// Warm off-white used for the viewfinder corner brackets — reads clearly over live camera video in
/// both light and dark. Local to this file per the styling rules (no shared color-file edits).
private extension Color {
    static let scannerBracket = Color(white: 0.91)
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
    /// Drives the library branch of the camera-off "Add a photo instead" menu. Presenting a
    /// `PhotosPicker` on demand (rather than from a bare label button) lets the moss primary offer
    /// camera + library while preserving the existing `selectedPhotoItem` → `handlePickedImage` path.
    @State private var isPhotoLibraryPickerActive = false
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
                liveScanner
            } else {
                cameraOffFallback
            }
        }
        .background(Color.parchment)
        .navigationTitle("Scan a food")
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

    // MARK: Live viewfinder (11a)

    /// The DataScanner representable with a calm frame overlaid on top: dimmed surround, warm corner
    /// brackets, a soft moss scan line, and the one caption. The scanner + delivery behavior is
    /// untouched — this is presentation chrome layered over the live video.
    private var liveScanner: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            BarcodeDataScannerView(
                onPayload: { payload in onCode(payload) },
                onUnavailable: {
                    // Camera access was denied (or the scanner otherwise went unavailable) — drop
                    // to the still-photo fallback with a gentle hint instead of a dead viewfinder.
                    liveScannerUnavailable = true
                    detectionNotice = "Camera access looks off — you can turn it on in Settings, or snap or choose a photo of the barcode below."
                }
            )
            .ignoresSafeArea()

            ScanFrameOverlay(caption: "Point the camera at the product's barcode.")

            // A kind way out, right on the frame (mockup 11a): a translucent "Add by hand" pill
            // pinned to the bottom, wired to the same hand-entry path as the camera-off fallback so
            // the user is never trapped waiting for a scan.
            VStack {
                Spacer()
                Button {
                    onCode("")
                } label: {
                    Label("Add by hand", systemImage: "plus")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.cream)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.cream.opacity(0.2), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 44)
                .accessibilityIdentifier("barcodeAddByHand")
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: Camera-off fallback (11a, right)

    /// Calm, non-blocking landing when the camera is unavailable: never a red error, just "no worries"
    /// with a photo path (existing `showingCamera` / `PhotosPicker`) and a hand-entry escape hatch.
    private var cameraOffFallback: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Soft camera-off icon tile.
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.goldenrod.opacity(0.14))
                    Image(systemName: "camera.metering.none")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Color.goldenrod)
                }
                .frame(width: 80, height: 80)
                .padding(.top, 40)

                VStack(spacing: 12) {
                    Text("Camera access is off")
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)
                        .multilineTextAlignment(.center)

                    Text("No worries — you can add a photo of the barcode, or just enter it by hand.")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.slate)
                        .multilineTextAlignment(.center)
                        .fernletWrappingText()
                        .frame(maxWidth: 300)
                }

                VStack(spacing: 11) {
                    // Primary — moss, wired to the existing photo path (camera → library fallback).
                    Menu {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button {
                                showingCamera = true
                            } label: {
                                Label("Take a photo", systemImage: "camera.fill")
                            }
                        }
                        Button {
                            isPhotoLibraryPickerActive = true
                        } label: {
                            Label("Choose from library", systemImage: "photo.on.rectangle")
                        }
                    } label: {
                        Label("Add a photo instead", systemImage: "camera.fill")
                            .font(.fernlet(.label))
                            .foregroundStyle(Color.cream)
                            .frame(maxWidth: .infinity)
                            .padding(15)
                            .background(Color.moss, in: RoundedRectangle(cornerRadius: 15))
                    }
                    .buttonStyle(.plain)
                    // The library branch is a PhotosPicker so we keep the exact existing selection path.
                    .photosPicker(isPresented: $isPhotoLibraryPickerActive, selection: $selectedPhotoItem, matching: .images)

                    // Secondary — enter the barcode's macros by hand (skips detection, opens the
                    // remember-a-food naming screen for this scan with no payload found).
                    Button {
                        onCode("")
                    } label: {
                        Text("Enter details by hand")
                            .font(.fernlet(.label))
                            .foregroundStyle(Color.goldenrod)
                            .frame(maxWidth: .infinity)
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 15)
                                    .stroke(Color.goldenrod.opacity(0.4), lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 300)

                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Turn on camera in Settings")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.slate)
                        .underline()
                }
                .buttonStyle(.plain)
                .padding(.top, 2)

                // Preview + detection status for a picked photo, so the fallback stays a working flow.
                if let stillImage {
                    Image(uiImage: stillImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.bark.opacity(0.10), lineWidth: 1))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 6)
                }

                if isDetecting {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Looking for a barcode...")
                            .font(.fernlet(.bubble))
                            .foregroundStyle(Color.slate)
                    }
                }

                if let detectionNotice {
                    Text(detectionNotice)
                        .font(.fernlet(.bubble))
                        .foregroundStyle(Color.slate)
                        .multilineTextAlignment(.center)
                        .fernletWrappingText()
                        .frame(maxWidth: 320)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(24)
            .padding(.bottom, 20)
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

// MARK: - Viewfinder chrome (11a)

/// Clean scan-frame chrome drawn over the live DataScanner: a dimmed surround with a clear window,
/// warm off-white rounded corner brackets, a soft glowing moss scan line, and one gentle caption.
/// Purely decorative — it never intercepts the camera or its delivery.
private struct ScanFrameOverlay: View {
    var caption: String

    /// A slow, gentle vertical sweep for the scan line (matches the companion's calm — never clinical).
    @State private var sweep = false

    private let windowWidth: CGFloat = 250
    private let windowHeight: CGFloat = 160
    private let cornerRadius: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let window = CGRect(
                x: (geo.size.width - windowWidth) / 2,
                y: geo.size.height * 0.42 - windowHeight / 2,
                width: windowWidth,
                height: windowHeight
            )

            ZStack {
                // Dimmed surround with a clear cut-out window.
                Color.black.opacity(0.5)
                    .reverseMask {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .frame(width: window.width, height: window.height)
                            .position(x: window.midX, y: window.midY)
                    }

                // Corner brackets + scan line, positioned on the window.
                ZStack {
                    ScanBrackets(cornerRadius: cornerRadius)
                        .stroke(Color.scannerBracket, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: window.width, height: window.height)

                    // Soft glowing moss scan line, sweeping between the top and bottom of the window.
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.moss.opacity(0), Color.moss, Color.moss.opacity(0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: window.width - 16, height: 2)
                        .shadow(color: Color.moss.opacity(0.8), radius: 6)
                        .offset(y: sweep ? window.height / 2 - 8 : -window.height / 2 + 8)
                        .animation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true), value: sweep)
                }
                .position(x: window.midX, y: window.midY)

                // Caption below the window.
                Text(caption)
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.cream)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.4), radius: 6)
                    .frame(maxWidth: geo.size.width - 80)
                    .position(x: geo.size.width / 2, y: window.maxY + 64)
            }
        }
        .allowsHitTesting(false)
        .onAppear { sweep = true }
        .accessibilityElement()
        .accessibilityLabel(caption)
    }
}

/// The four rounded L-shaped corner brackets of the scan window, as one stroked Shape.
private struct ScanBrackets: Shape {
    var cornerRadius: CGFloat
    /// How far each bracket arm extends along an edge from its corner.
    var arm: CGFloat = 30

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = cornerRadius

        // Top-left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + arm + r))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + r + arm, y: rect.minY))

        // Top-right
        path.move(to: CGPoint(x: rect.maxX - r - arm, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                    startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + r + arm))

        // Bottom-right
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - r - arm))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX - r - arm, y: rect.maxY))

        // Bottom-left
        path.move(to: CGPoint(x: rect.minX + r + arm, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r - arm))

        return path
    }
}

private extension View {
    /// Masks out (punches a hole through) the receiver using the given shape — used to cut the clear
    /// scan window into the dimmed surround.
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: .center) {
                    mask()
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
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
    /// When the auto-router already parsed a nutrition label from the captured photo, the macros
    /// arrive pre-filled here so the naming screen opens with the rings populated (no rescan needed).
    /// nil for the ordinary barcode not-found handoff.
    var prefilledScan: NutritionLabelResult? = nil
    var onCreated: (FoodItem) -> Void

    @State private var name = ""
    @State private var scanResult: NutritionLabelResult?
    @State private var showingLabelScanner = false
    /// Once the food is saved we show the "Remembered" (11c) confirmation and hold the item; the
    /// user's "Done" tap fires `onCreated`, so the create logic itself is unchanged — we only give
    /// the confirmation its moment before the flow dismisses.
    @State private var rememberedItem: FoodItem?

    var body: some View {
        Group {
            if let rememberedItem {
                RememberedConfirmationView(item: rememberedItem) {
                    onCreated(rememberedItem)
                }
            } else {
                namingScreen
            }
        }
        .background(Color.parchment)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Seed the macros the auto-router already read (once — don't clobber a rescan).
            if scanResult == nil, let prefilledScan {
                scanResult = prefilledScan
                if trimmedName.isEmpty, let servingSize = prefilledScan.servingSize, servingSize.isEmpty == false {
                    name = "Scanned item (\(servingSize))"
                }
            }
        }
    }

    // MARK: Naming screen (11b)

    private var namingScreen: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 18) {
                        // Quiet "ADD A FOOD" eyebrow above the friendly header (mockup 11b).
                        Text("Add a food")
                            .font(.fernlet(.labelSmall))
                            .tracking(1.4)
                            .textCase(.uppercase)
                            .foregroundStyle(Color.softTaupe)

                        // Friendly "New to Fernlet" header with a little companion face.
                        HStack(spacing: 12) {
                            CompanionFace()
                                .frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("New to Fernlet")
                                    .font(.fernlet(.labelSmall))
                                    .tracking(1.2)
                                    .textCase(.uppercase)
                                    .foregroundStyle(Color.goldenrod)
                                Text("We haven't met this one")
                                    .font(.fernlet(.header))
                                    .foregroundStyle(Color.bark)
                                    .fernletWrappingText()
                            }
                        }
                    }

                    Text("Give it a name and it'll be here next time you scan.")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()

                    SheetField("What should we call it?") {
                        TextField("Hazelnut oat bar", text: $name)
                            .sheetTextInput()
                    }

                    // Optional dashed label-scan (wired to the existing NutritionLabelScanner flow).
                    Button {
                        showingLabelScanner = true
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(Color.moss.opacity(0.14))
                                Image(systemName: "doc.viewfinder")
                                    .font(.system(size: 20, weight: .regular))
                                    .foregroundStyle(Color.moss)
                            }
                            .frame(width: 44, height: 44)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(scanResult == nil ? "Scan the nutrition label" : "Rescan the nutrition label")
                                    .font(.fernlet(.body))
                                    .foregroundStyle(Color.bark)
                                Text("optional — we'll read the macros for you")
                                    .font(.fernlet(.bodySmall))
                                    .foregroundStyle(Color.slate)
                                    .fernletWrappingText()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.softTaupe)
                        }
                        .padding(16)
                        .background(Color.cream, in: RoundedRectangle(cornerRadius: 18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(Color.moss.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        )
                    }
                    .buttonStyle(.plain)

                    // Macros, per serving — grams only. NEVER a calorie value.
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Macros, per serving")
                                .font(.fernlet(.labelSmall))
                                .foregroundStyle(Color.slate)
                            Spacer()
                            Text("grams — no calories here")
                                .font(.fernlet(.bubble))
                                .foregroundStyle(Color.softTaupe)
                        }

                        HStack(spacing: 11) {
                            MacroRingTile(label: "Protein", grams: scanResult?.protein ?? 0, tint: .moss)
                            MacroRingTile(label: "Carbs", grams: scanResult?.carbs ?? 0, tint: .goldenrod)
                            MacroRingTile(label: "Fat", grams: scanResult?.fat ?? 0, tint: .terracotta)
                        }

                        if scanResult == nil {
                            Text("Scanning the label fills in the macros — you can also add them later.")
                                .font(.fernlet(.bubble))
                                .foregroundStyle(Color.slate)
                                .fernletWrappingText()
                        } else if let servingSize = scanResult?.servingSize, servingSize.isEmpty == false {
                            Text("Per serving: \(servingSize)")
                                .font(.fernlet(.labelSmall))
                                .foregroundStyle(Color.slate)
                        }
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
                rememberedItem = item
            }
        }
        .navigationTitle("Remember product")
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

// MARK: - Remembered confirmation (11c)

/// The soft "Remembered" success state: a green check medallion, a warm line naming the food, and a
/// mini food chip showing the macros in grams (never calories). "Done" hands the just-created item
/// back to the flow.
private struct RememberedConfirmationView: View {
    let item: FoodItem
    var onDone: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 26) {
                // Green check medallion.
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.moss.opacity(0.2), Color.moss.opacity(0)],
                                center: .center, startRadius: 0, endRadius: 52
                            )
                        )
                        .frame(width: 104, height: 104)
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.fern, Color.moss],
                                center: UnitPoint(x: 0.42, y: 0.36), startRadius: 2, endRadius: 60
                            )
                        )
                        .frame(width: 80, height: 80)
                        .shadow(color: Color.moss.opacity(0.3), radius: 12, y: 8)
                    Image(systemName: "checkmark")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(Color.cream)
                }
                .scaleEffect(appeared ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)

                VStack(spacing: 12) {
                    Text("Remembered")
                        .font(.fernlet(.display))
                        .foregroundStyle(Color.bark)

                    Text("\(item.name) is in your foods now — scan it again and it'll log in a tap.")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.slate)
                        .multilineTextAlignment(.center)
                        .fernletWrappingText()
                        .frame(maxWidth: 300)
                }

                // Mini food chip — name + grams (P / C / F). No calories.
                HStack(spacing: 13) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.goldenrod.opacity(0.16))
                        Image(systemName: "bag.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.goldenrod)
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.bark)
                            .lineLimit(1)
                        HStack(spacing: 10) {
                            Text("P \(item.macros.protein)")
                                .foregroundStyle(Color.moss)
                            Text("C \(item.macros.carbs)")
                                .foregroundStyle(Color.goldenrod)
                            Text("F \(item.macros.fat)")
                                .foregroundStyle(Color.terracotta)
                        }
                        .font(.fernlet(.stat))
                    }
                    Spacer(minLength: 0)
                }
                .padding(15)
                .frame(maxWidth: 290)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 18))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.name), \(item.macros.protein) grams protein, \(item.macros.carbs) grams carbs, \(item.macros.fat) grams fat")
            }
            .padding(.horizontal, 34)

            Spacer(minLength: 0)

            Button(action: onDone) {
                Text("Done")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.cream)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .background(Color.moss, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { appeared = true }
        }
    }
}

// MARK: - Small pieces

/// A macro ring tile: a tinted progress-style ring with the grams count inside and a colored label
/// beneath. Grams only — this tile never renders or computes calories.
private struct MacroRingTile: View {
    var label: String
    var grams: Int
    var tint: Color

    /// A gentle, purely decorative fill so an all-zero tile still reads as a ring, not an error. The
    /// value is cosmetic — the truth is the "\(grams)g" in the center.
    private var fill: CGFloat {
        let capped = min(max(grams, 0), 40)
        return 0.12 + CGFloat(capped) / 40 * 0.78
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.18), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: fill)
                    .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(grams)g")
                    .font(.fernlet(.stat))
                    .foregroundStyle(Color.bark)
            }
            .frame(width: 56, height: 56)

            Text(label)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(grams) grams")
    }
}

/// A small, friendly companion face for the "New to Fernlet" header (nice-to-have, decorative).
private struct CompanionFace: View {
    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color.fern, Color.moss],
                    center: UnitPoint(x: 0.36, y: 0.3), startRadius: 2, endRadius: 34
                )
            )
            .overlay {
                VStack(spacing: 5) {
                    HStack(spacing: 14) {
                        eye
                        eye
                    }
                    Capsule()
                        .fill(Color.bark.opacity(0.5))
                        .frame(width: 11, height: 5)
                }
            }
            .shadow(color: Color.moss.opacity(0.3), radius: 6, y: 4)
    }

    private var eye: some View {
        Capsule()
            .fill(Color.cream)
            .frame(width: 6, height: 8)
            .overlay(alignment: .bottom) {
                Circle()
                    .fill(Color.bark)
                    .frame(width: 3.5, height: 3.5)
                    .offset(y: -1)
            }
    }
}

#endif
