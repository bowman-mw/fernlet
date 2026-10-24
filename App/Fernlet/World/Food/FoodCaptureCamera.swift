import SwiftUI

/// The words that mark a nutrition label in the live camera's text (`b3-meal` draft 2, the owner's
/// "if it detects a bar code or nutrition label, saves the data automatically"). Pure, so it is
/// unit-tested apart from the camera: a headline ("Nutrition Facts", "Información nutricional") is
/// enough on its own, otherwise three of the label's row words must show.
nonisolated enum FoodLabelCue {
    /// A label's own headline, lowercased.
    static let headlines = ["nutrition facts", "nutrition information", "información nutricional",
                            "informacion nutricional", "valeurs nutritionnelles", "nährwerte"]
    /// The row words a label prints, lowercased (English and Spanish).
    static let rowWords = ["protein", "carbohydrate", "total fat", "sodium", "calories", "serving size",
                           "saturated", "sugars", "proteína", "hidratos", "grasas", "fibra"]
    /// How many distinct row words make a label when no headline shows.
    static let rowWordFloor = 3
    /// The most recognised lines read per frame (a page of text is not a label).
    static let maxLines = 80

    /// Whether the recognised lines look like a nutrition label.
    static func looksLikeNutritionLabel(_ lines: [String]) -> Bool {
        let text = lines.prefix(maxLines).joined(separator: "\n").lowercased()
        guard !text.isEmpty else { return false }
        if headlines.contains(where: { text.contains($0) }) { return true }
        return rowWords.filter { text.contains($0) }.count >= rowWordFloor
    }
}

#if canImport(UIKit)
import AppServices
import FernletDomainModel
import FernletUI
import PhotosUI
import UIKit
import VisionKit

/// The one camera behind Log meal's camera button (`b3-meal` and `b3-meal-macros` draft 2, `b3-barcode-scan`
/// draft 2; owner, 2026-10-24: "capture auto-detects barcodes and nutrition labels"). Full screen and
/// dark, with the scan window in the middle, the framed Back top left, and the shutter, the photo
/// library and "Add by hand" at the bottom.
///
/// - A barcode in view is read at once (VisionKit's live scanner) and handed back.
/// - A nutrition label in view (``FoodLabelCue`` over the live text) is photographed and read by the
///   app's label reader (`NutritionLabelScanner`); a confident reading (three or more fields, the
///   capture router's floor) is handed back, a weak one keeps the camera open.
/// - Otherwise the shutter takes the photo, which the meal sheet routes as today (barcode, label, a
///   meal photo, or the "Nothing to read here" fallback). A library pick attaches as the meal photo.
///
/// Every reading stays on this iPhone. One hand-off per opening: once something is handed back the
/// scanner pauses, so a second barcode can't fire behind it.
struct FoodCaptureCameraView: View {
    var onBarcode: (String) -> Void
    var onLabel: (NutritionLabelResult) -> Void
    var onPhoto: (UIImage) -> Void
    var onLibraryPick: (Data) -> Void
    var onAddByHand: () -> Void
    /// The camera went unavailable (access turned off): the meal sheet shows "Scan a food" instead.
    var onUnavailable: () -> Void
    var onClose: () -> Void
    /// False draws the chrome over a dark stand-in (the DEBUG gallery; the simulator has no camera).
    var showsLiveCamera = true

    @State private var handle = FoodCaptureCameraHandle()
    @State private var handedOff = false
    @State private var isReadingLabel = false
    @State private var isCapturing = false
    @State private var captureFailed = false
    @State private var showingLibrary = false
    @State private var libraryItem: PhotosPickerItem?

    /// Whether the live camera can run here (a camera, VisionKit's scanner, access not refused).
    static var isLiveAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        ZStack {
            WorldPalette.rgb(0x221C17).ignoresSafeArea()
            if showsLiveCamera {
                FoodCaptureScannerView(handle: handle, paused: handedOff, onBarcode: deliverBarcode,
                                       onLabelCue: readLabel, onUnavailable: onUnavailable)
                    .ignoresSafeArea()
            }
            FoodScanWindow(caption: "Point at a barcode or a nutrition label, or take a photo of your meal.")
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomControls
            }
            if isReadingLabel {
                CaptureAnalyzingOverlay().transition(.opacity)
            }
        }
        .animation(FernletMotion.ui, value: isReadingLabel)
        .photosPicker(isPresented: $showingLibrary, selection: $libraryItem, matching: .images)
        .onChange(of: libraryItem) { _, item in loadLibraryPick(item) }
        .accessibilityAction(.escape, onClose)
    }

    /// The framed Back, top left (the button rule: Back and Cancel top left).
    private var topBar: some View {
        HStack {
            FernletBackButton(verbatim: String(localized: "Log meal")) { onClose() }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// The library, the shutter and "Add by hand", over the camera's foot.
    private var bottomControls: some View {
        VStack(spacing: 16) {
            if captureFailed {
                Text("Fernlet couldn't take that photo. Try again.")
                    .font(FernletFramedFont.notice)
                    .foregroundStyle(WorldPalette.gameCream)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(alignment: .center) {
                libraryButton
                Spacer(minLength: 0)
                FoodShutterButton(isBusy: isCapturing, action: takePhoto)
                Spacer(minLength: 0)
                Color.clear.frame(width: 52, height: 52)
            }
            Button(action: addByHand) {
                HStack(spacing: 8) {
                    FernletIcon(.plus, scale: 2)
                    Text("Add by hand")
                }
            }
            .buttonStyle(ActionPillButtonStyle(.secondary))
            .accessibilityIdentifier("barcodeAddByHand")
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 20)
    }

    private var libraryButton: some View {
        Button { showingLibrary = true } label: {
            FernletIconTile(size: 52) { WorldSpriteView(sprite: FoodSprites.library, scale: 3) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose from library")
        .accessibilityInputLabels([Text("Library"), Text("Choose from library")])
    }

    // MARK: Hand-offs

    private func deliverBarcode(_ payload: String) {
        guard !handedOff, !payload.isEmpty else { return }
        handedOff = true
        // A10: "got it — the camera's done, move your hand".
        FernletFeedback.system.play(.captured)
        onBarcode(payload)
    }

    private func addByHand() {
        guard !handedOff else { return }
        handedOff = true
        onAddByHand()
    }

    /// The live text looked like a label: photograph it and read it with the app's label reader. A
    /// weak or failed reading keeps the camera open; the cue comes back when the label is steadier.
    private func readLabel() {
        guard !handedOff, !isReadingLabel, !isCapturing else { return }
        isReadingLabel = true
        Task {
            defer { isReadingLabel = false }
            do {
                let photo = try await handle.capturePhoto()
                let reading = try await NutritionLabelScanner.scanAll(image: FoodCaptureRouter.downscaledForOCR(photo)).primary
                guard !handedOff, reading.recognizedFieldCount >= FoodCaptureRouter.labelConfidenceFieldFloor else { return }
                handedOff = true
                FernletFeedback.system.play(.captured)
                onLabel(reading)
            } catch {
                // Nothing readable this time: the camera stays live, the shutter still works, and the
                // cue comes back when the label is steadier. Nothing to say to the person yet.
                return
            }
        }
    }

    /// The shutter: the photo goes back to the meal sheet, which reads it for a barcode or a label and
    /// otherwise keeps it as the meal photo.
    private func takePhoto() {
        guard !handedOff, !isCapturing else { return }
        isCapturing = true
        captureFailed = false
        Task {
            defer { isCapturing = false }
            do {
                let photo = try await handle.capturePhoto()
                guard !handedOff else { return }
                handedOff = true
                FernletFeedback.system.play(.captured)
                onPhoto(photo)
            } catch {
                captureFailed = true
                FernletFeedback.system.play(.caveat)
            }
        }
    }

    /// A library pick attaches as the meal photo (the byte path: the full-resolution bitmap is never
    /// decoded here).
    private func loadLibraryPick(_ item: PhotosPickerItem?) {
        guard let item, !handedOff else { return }
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { return }
                handedOff = true
                onLibraryPick(data)
            } catch {
                captureFailed = true
            }
            libraryItem = nil
        }
    }
}

/// The camera's shutter: a 72-pt paper disc in a 3-pt ink ring, a smaller ring inside. Dims while a
/// photo is being taken.
struct FoodShutterButton: View {
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(WorldPalette.gameCream)
                Circle().strokeBorder(WorldPalette.ink, lineWidth: 3)
                Circle().strokeBorder(WorldPalette.ink.opacity(0.5), lineWidth: 2).padding(9)
            }
            .frame(width: 72, height: 72)
            .opacity(isBusy ? 0.5 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel("Take photo")
        .accessibilityInputLabels([Text("Take photo"), Text("Shutter")])
        .accessibilityIdentifier("captureCamera.shutter")
    }
}

/// Holds the live scanner so the shutter and the label cue can photograph through it.
@MainActor
final class FoodCaptureCameraHandle {
    weak var scanner: DataScannerViewController?

    /// A photo from the running scanner, or an error when there is none.
    func capturePhoto() async throws -> UIImage {
        guard let scanner else { throw FoodCaptureCameraError.noCamera }
        return try await scanner.capturePhoto()
    }
}

/// Why the capture camera could not take a photo.
nonisolated enum FoodCaptureCameraError: Error {
    case noCamera
}

/// VisionKit's live scanner reading barcodes and text at once: the first barcode is handed back, and
/// text that looks like a nutrition label raises the label cue (at most every three seconds).
struct FoodCaptureScannerView: UIViewControllerRepresentable {
    let handle: FoodCaptureCameraHandle
    var paused: Bool
    var onBarcode: (String) -> Void
    var onLabelCue: () -> Void
    var onUnavailable: () -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: BarcodeScanner.symbologies), .text()],
            qualityLevel: .balanced,
            recognizesMultipleItems: true,
            isHighlightingEnabled: false
        )
        scanner.delegate = context.coordinator
        // T2-10: an inverted live preview does not decode.
        scanner.view.accessibilityIgnoresInvertColors = true
        handle.scanner = scanner
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if paused {
            if scanner.isScanning { scanner.stopScanning() }
            return
        }
        guard !scanner.isScanning else { return }
        do {
            try scanner.startScanning()
        } catch {
            context.coordinator.reportUnavailable()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onBarcode: onBarcode, onLabelCue: onLabelCue, onUnavailable: onUnavailable)
    }

    /// The scanner's delegate: one barcode per opening, the label cue throttled, unavailability once.
    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onBarcode: (String) -> Void
        let onLabelCue: () -> Void
        let onUnavailable: () -> Void
        private var deliveredBarcode = false
        private var reportedUnavailable = false
        private var lastCue = Date.distantPast

        init(onBarcode: @escaping (String) -> Void, onLabelCue: @escaping () -> Void,
             onUnavailable: @escaping () -> Void) {
            self.onBarcode = onBarcode
            self.onLabelCue = onLabelCue
            self.onUnavailable = onUnavailable
        }

        func reportUnavailable() {
            guard !reportedUnavailable else { return }
            reportedUnavailable = true
            onUnavailable()
        }

        // VisionKit gives this a no-op default, so it MUST be implemented or a runtime denial freezes.
        func dataScanner(_ dataScanner: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            reportUnavailable()
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            consider(allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            consider(allItems)
        }

        /// A barcode wins; otherwise the text is checked for a label.
        private func consider(_ items: [RecognizedItem]) {
            guard !deliveredBarcode else { return }
            var lines: [String] = []
            for item in items.prefix(FoodLabelCue.maxLines) {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue, !payload.isEmpty {
                    deliveredBarcode = true
                    onBarcode(payload)
                    return
                }
                if case .text(let text) = item {
                    lines.append(text.transcript)
                }
            }
            guard Date().timeIntervalSince(lastCue) > 3, FoodLabelCue.looksLikeNutritionLabel(lines) else { return }
            lastCue = Date()
            onLabelCue()
        }
    }
}

/// The scan window over a camera (`b3-barcode-scan` draft 2): the surround dimmed, a clear window with
/// cream pixel corner brackets, a moss scan line that sweeps (and holds still under Reduce Motion),
/// and the caption on a dark plate below, never a text shadow. Decorative to touches; VoiceOver
/// reads the caption.
struct FoodScanWindow: View {
    let caption: LocalizedStringKey
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let size = CGSize(width: 260, height: 170)
    private let sweepPeriod: Double = 5.2

    var body: some View {
        GeometryReader { geo in
            let window = CGRect(x: (geo.size.width - size.width) / 2, y: geo.size.height * 0.42 - size.height / 2,
                                width: size.width, height: size.height)
            ZStack {
                surround(window)
                TimelineView(.animation(paused: reduceMotion)) { timeline in
                    scanLine(window, elapsed: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate)
                }
                FoodScanBrackets()
                    .fill(WorldPalette.gameCream)
                    .frame(width: window.width, height: window.height)
                    .position(x: window.midX, y: window.midY)
                Text(caption)
                    .font(FernletFramedFont.button)
                    .foregroundStyle(WorldPalette.gameCream)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: geo.size.width - 48)
                    .position(x: geo.size.width / 2, y: window.maxY + 56)
            }
        }
        // One coordinate space for the window, its cut-out and its brackets: the whole screen.
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(caption)
    }

    /// The dimmed surround with the window cut out of it.
    private func surround(_ window: CGRect) -> some View {
        Color.black.opacity(0.45)
            .mask {
                Rectangle()
                    .overlay {
                        Rectangle()
                            .frame(width: window.width, height: window.height)
                            .position(x: window.midX, y: window.midY)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
    }

    /// The moss line sweeping between the window's top and bottom (a raised-cosine round trip).
    private func scanLine(_ window: CGRect, elapsed: TimeInterval) -> some View {
        let travel = (1 - cos(elapsed * 2 * .pi / sweepPeriod)) / 2
        let y = window.minY + 14 + (window.height - 28) * travel
        return Rectangle()
            .fill(WorldPalette.rgb(0x8DBB78))
            .frame(width: window.width - 20, height: 3)
            .position(x: window.midX, y: y)
    }
}

/// The scan window's four square pixel corner brackets: 4-pt arms, 22 pt long.
nonisolated struct FoodScanBrackets: Shape {
    var thickness: CGFloat = 4
    var arm: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX - arm, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY - thickness), CGPoint(x: rect.maxX - arm, y: rect.maxY - thickness)]
        for corner in corners {
            path.addRect(CGRect(x: corner.x, y: corner.y, width: arm, height: thickness))
        }
        let uprights = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX - thickness, y: rect.minY),
                        CGPoint(x: rect.minX, y: rect.maxY - arm), CGPoint(x: rect.maxX - thickness, y: rect.maxY - arm)]
        for corner in uprights {
            path.addRect(CGRect(x: corner.x, y: corner.y, width: thickness, height: arm))
        }
        return path
    }
}
#endif
