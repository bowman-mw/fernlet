import SwiftUI

#if canImport(UIKit)
import UIKit
import Vision
import VisionKit
import PhotosUI
import FernletDomainModel
import FernletFoundation
import FoodCatalog
import AppServices
import FernletUI

// MARK: - Scan → resolve → remember flow

/// Scan a product barcode and resolve it to a food item as one pushable flow:
/// user items (a previously paired product) → bundled catalog (when a future database carries UPC
/// data) → gentle not-found path that creates a user food item WITH the barcode remembered, so the
/// next scan of the same product hits instantly. Calls `onResolved` exactly once.
struct BarcodeResolveFlowView: View {
    var store: FernletStore
    /// The page Back returns to ("Log meal"), already resolved; nil says "Back".
    var backTitle: String? = nil
    /// When set, a photo added on the camera-off page goes here (the meal sheet's capture front door)
    /// instead of being searched for a barcode only.
    var onPhoto: ((UIImage) -> Void)? = nil
    var onResolved: (FoodItem) -> Void
    @State private var notFound: ScannedBarcode?

    var body: some View {
        BarcodeScanView(backTitle: backTitle, onPhoto: onPhoto) { code in
            if let item = store.foodCatalog.item(forBarcode: code) {
                onResolved(item)
            } else {
                notFound = ScannedBarcode(code: code)
            }
        }
        .navigationDestination(item: $notFound) { scanned in
            BarcodeNotFoundView(store: store, barcode: scanned.code, backTitle: String(localized: "Scan a food"),
                                onCreated: onResolved)
        }
    }
}

/// A scanned barcode payload wrapped for navigation-destination identity.
///
/// ``BarcodeResolveFlowView`` sets one when a code has no catalog match, driving the push to
/// ``BarcodeNotFoundView``; the code itself is the identity, so re-scanning the same code reuses the
/// same destination.
struct ScannedBarcode: Identifiable, Hashable {
    let code: String
    var id: String { code }
}

// MARK: - Scanner screen

/// "Scan a food" (`b3-barcode-off`, `b3-barcode-scan` draft 2): the live barcode viewfinder (VisionKit
/// `DataScannerViewController`) under the World scan window, with a graceful still-photo fallback
/// (`VNDetectBarcodesRequest` over the photo picker) where the live scanner is unsupported or the camera
/// is off. Delivers the raw payload string; callers normalize via `FoodCatalog.item(forBarcode:)` /
/// `FoodBarcode`.
///
/// Log meal reaches it only when its live camera can't run; there `onPhoto` hands an added photo to the
/// meal sheet's capture front door, which reads a barcode, a label, or keeps it as the meal photo. The
/// recipe editor's scan reaches it directly and keeps the barcode-only reading.
struct BarcodeScanView: View {
    var detector: any BarcodePayloadDetecting = VisionBarcodeDetector()
    /// The page Back returns to, already resolved; nil says "Back".
    var backTitle: String? = nil
    /// Takes an added photo instead of the barcode-only reading (Log meal's camera-off path).
    var onPhoto: ((UIImage) -> Void)? = nil
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
    /// Latches the moment we hand a payload (or an empty hand-entry) to `onCode`, so a barcode the
    /// live scanner recognizes during/after the push can never fire a second `onCode` that would log an
    /// unchosen meal or swap the pushed screen out from under the user. The live scanner's own
    /// `delivered` guard resets when the viewfinder re-arms (`updateUIViewController`), so the guard has
    /// to live here at the View that owns the single delivery.
    @State private var handedOff = false
    /// The single in-flight still-photo detection (see `handlePickedImage`); cancelled when a new photo
    /// is picked and when the scanner goes away.
    @State private var detectionTask: Task<Void, Never>?
    @Environment(\.fernletFramedLook) private var look

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
        .foodSheetBackground()
        .foodSheetPushedPage("Scan a food", back: backTitle)
        .onChange(of: scenePhase) { _, newPhase in
            // Returning from Settings (where the user may have just enabled camera access) retries
            // the live scanner; if it's still denied, becameUnavailable flips us back.
            if newPhase == .active, liveScannerUnavailable { liveScannerUnavailable = false }
        }
        .photoCapturePlumbing(
            showingCamera: $showingCamera,
            selection: $selectedPhotoItem,
            onCameraImage: handlePickedImage
        )
        .onDisappear { detectionTask?.cancel() }
    }

    // MARK: Live viewfinder (b3-barcode-scan)

    /// The DataScanner representable under the World scan window (dimmed surround, pixel corner
    /// brackets, the moss scan line, the caption on a dark plate) and the framed "Add by hand". The
    /// scanner + delivery behavior is untouched — this is presentation chrome over the live video.
    private var liveScanner: some View {
        ZStack {
            WorldPalette.rgb(0x221C17).ignoresSafeArea()

            BarcodeDataScannerView(
                // Once we've handed a code off (a real payload OR an empty hand-entry), pause the live
                // scanner so it can't recognize a second barcode behind the pushed screen.
                paused: handedOff,
                onPayload: { payload in deliver(payload) },
                onUnavailable: {
                    // Camera access was denied (or the scanner otherwise went unavailable) — drop
                    // to the still-photo fallback with a gentle hint instead of a dead viewfinder.
                    liveScannerUnavailable = true
                    detectionNotice = String(localized: "barcode.notice.cameraOff",
                                             defaultValue: "Camera access looks off — you can turn it on in Settings, or snap or choose a photo of the barcode below.",
                                             comment: "Barcode scanner: camera permission is off. Offers the photo fallback below the line.")
                }
            )
            .ignoresSafeArea()
            // Popping back into the scanner from the pushed name/lookup screen clears the hand-off
            // latch (and re-arms the paused scanner), so the user can scan a different product.
            .onAppear { handedOff = false }

            FoodScanWindow(caption: "Point the camera at the product's barcode.")

            // A kind way out, right on the frame: "Add by hand" pinned to the bottom, wired to the
            // same hand-entry path as the camera-off fallback so the user is never trapped waiting.
            VStack {
                Spacer()
                Button { deliver("") } label: {
                    HStack(spacing: 8) {
                        FernletIcon(.plus, scale: 2)
                        Text("Add by hand")
                    }
                }
                .buttonStyle(ActionPillButtonStyle(.secondary))
                .padding(.bottom, 32)
                .accessibilityIdentifier("barcodeAddByHand")
            }
        }
    }

    // MARK: Camera-off fallback (b3-barcode-off)

    /// Calm, non-blocking landing when the camera is unavailable: never a red error, just "no worries"
    /// with a photo path (existing `showingCamera` / `PhotosPicker`) and a hand-entry escape hatch.
    private var cameraOffFallback: some View {
        ScrollView {
            VStack(spacing: 18) {
                cameraOffHeader
                cameraOffActions

                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Turn on camera in Settings")
                        .font(look == nil ? .fernlet(.label) : FernletFramedFont.button)
                        .foregroundStyle(look?.link ?? Color.slate)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)

                pickedPhotoStatus
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
    }

    /// The camera-off sign (a pixel camera on a gold tile) plus its two lines of copy.
    private var cameraOffHeader: some View {
        VStack(spacing: 14) {
            FernletIconTile(size: 84, fill: WorldPalette.rgb(0xF2D58A)) {
                WorldSpriteView(sprite: FoodSprites.cameraOff, scale: 5, tint: WorldPalette.rgb(0x3A2414))
            }
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Camera access is off")
                    .font(look == nil ? .fernlet(.header) : FernletFramedFont.cardTitle)
                    .foregroundStyle(look?.text ?? Color.bark)
                    .multilineTextAlignment(.center)

                Text("No worries — you can add a photo of the barcode, or just enter it by hand.")
                    .font(look == nil ? .fernlet(.body) : FernletFramedFont.body)
                    .foregroundStyle(look?.dim ?? Color.slate)
                    .multilineTextAlignment(.center)
                    .fernletWrappingText()
            }
        }
    }

    /// The two ways out of a camera-off scanner: add a photo (camera or library) or enter by hand.
    private var cameraOffActions: some View {
        VStack(spacing: 12) {
            // Primary — wired to the existing photo path (camera → library fallback).
            Menu {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { showingCamera = true } label: { Label("Take a photo", systemImage: "camera.fill") }
                }
                Button { isPhotoLibraryPickerActive = true } label: {
                    Label("Choose from library", systemImage: "photo.on.rectangle")
                }
            } label: {
                HStack(spacing: 10) {
                    WorldSpriteView(sprite: FoodSprites.camera, scale: 2)
                    Text("Add a photo instead")
                }
                .frame(maxWidth: .infinity)
            }
            .menuStyle(.button)
            .buttonStyle(ActionPillButtonStyle(.primary))
            // The library branch is a PhotosPicker so we keep the exact existing selection path.
            .photosPicker(isPresented: $isPhotoLibraryPickerActive, selection: $selectedPhotoItem, matching: .images)

            // Secondary — enter the barcode's macros by hand (skips detection, opens the
            // remember-a-food naming screen for this scan with no payload found).
            Button { deliver("") } label: {
                Text("Enter details by hand").frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.secondary))
        }
    }

    /// Preview + detection status for a picked photo, so the camera-off fallback stays a working flow.
    @ViewBuilder
    private var pickedPhotoStatus: some View {
        if let stillImage {
            Image(uiImage: stillImage)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(look?.ink ?? Color.bark.opacity(0.10), lineWidth: 2))
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                // T2-10: this is the camera-off fallback's only feedback on whether the barcode
                // was actually in frame. An inverted barcode is a barcode nobody can check.
                .accessibilityIgnoresInvertColors()
        }

        if isDetecting {
            HStack(spacing: 8) {
                ProgressView()
                    .accessibilityHidden(true)
                Text("Looking for a barcode...")
                    .font(look == nil ? .fernlet(.bubble) : FernletFramedFont.note)
                    .foregroundStyle(look?.dim ?? Color.slate)
            }
        }

        if let detectionNotice {
            Text(detectionNotice)
                .font(look == nil ? .fernlet(.bubble) : FernletFramedFont.note)
                .foregroundStyle(look?.dim ?? Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
        }
    }

    /// The single guarded delivery point for every path that hands a code (or an empty hand-entry) to
    /// `onCode`. The latch makes a second delivery impossible once the flow has left the live scanner —
    /// a barcode recognized during/after the push can't log an unchosen meal or swap the pushed screen.
    private func deliver(_ code: String) {
        guard !handedOff else { return }
        handedOff = true
        // A10: "got it — the camera's done, move your hand". Only for a real code: "Add by hand"
        // delivers an empty one, and a tap that opens a form is not a capture.
        if !code.isEmpty { FernletFeedback.system.play(.captured) }
        onCode(code)
    }

    private func handlePickedImage(_ image: UIImage) {
        // Log meal's camera-off path: the meal sheet reads the photo (barcode, label, or meal photo).
        if let onPhoto {
            onPhoto(image)
            return
        }
        stillImage = image
        detectionNotice = nil
        isDetecting = true
        // R3: exactly one detection in flight — a second pick cancels the first rather than racing it,
        // so a stale completion can't clear `isDetecting` or post a notice for the previous photo.
        detectionTask?.cancel()
        detectionTask = Task {
            let payload = try? await detector.payload(in: image)
            guard !Task.isCancelled else { return }
            isDetecting = false
            // A found code is felt by `deliver` (`captured`), so only the miss plays here: B9, a
            // caveat beside the line that says how to try again — never an error.
            if let payload {
                deliver(payload)
            } else {
                detectionNotice = String(localized: "barcode.notice.noBarcodeInPhoto",
                                          defaultValue: "Fernlet couldn't spot a barcode in that photo — try moving closer so the code fills the frame.",
                                          comment: "Barcode scanner: a snapped or chosen photo showed no readable barcode")
                FernletFeedback.system.play(.caveat)
            }
        }
    }
}

// MARK: - Live viewfinder (VisionKit)

/// The `UIViewControllerRepresentable` wrapper around VisionKit's `DataScannerViewController` that
/// powers the live barcode viewfinder.
///
/// Delivers at most one payload per arming via the coordinator's `delivered` guard, pauses/re-arms
/// under the parent's `paused` latch (see ``BarcodeScanView``), and surfaces runtime unavailability
/// (camera permission revoked mid-session) through `onUnavailable` so the parent can drop to the
/// still-photo fallback. The symbology list is injectable — the QR verify ceremony reuses this exact
/// viewfinder with `[.qr]`.
///
/// The hosted view opts out of Smart Invert (`accessibilityIgnoresInvertColors`, T2-10) — an
/// inverted live preview does not decode — so every call site inherits that without repeating it.
struct BarcodeDataScannerView: UIViewControllerRepresentable {
    /// The parent latches this true the moment it hands any code off, pausing the live scanner so a
    /// second barcode can't be recognized behind the pushed screen. The parent clears it (re-arming
    /// the scanner) when the viewfinder reappears on pop-back.
    var paused: Bool = false
    /// Defaults to the food-barcode set; the QR verify ceremony (bitchat adoptions Increment 4)
    /// reuses this exact viewfinder with `[.qr]` instead of duplicating VisionKit plumbing.
    var symbologies: [VNBarcodeSymbology] = BarcodeScanner.symbologies
    var onPayload: (String) -> Void
    var onUnavailable: () -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: symbologies)],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        // T2-10: Smart Invert inverts the LIVE VIDEO too, and a barcode or QR read off an inverted
        // preview does not decode. Set on the UIKit view rather than as a SwiftUI modifier at each
        // call site so every user of this representable — the food scanner and both QR ceremonies —
        // inherits it and none can forget.
        scanner.view.accessibilityIgnoresInvertColors = true
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if paused {
            // A code has been handed off — stop recognizing so nothing fires behind the pushed screen.
            if scanner.isScanning { scanner.stopScanning() }
            return
        }
        guard !scanner.isScanning else { return }
        // Re-arm after a pop back into the scanner (delivery/pause stops scanning above). If arming
        // throws (e.g. permission just denied), surface it so the parent drops to the still-photo
        // fallback rather than leaving a frozen viewfinder.
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

    /// The `DataScannerViewControllerDelegate` for the live viewfinder: delivers the first recognized
    /// barcode payload exactly once per arming and reports scanner unavailability exactly once.
    ///
    /// `delivered` is reset by `updateUIViewController` on re-arm (pop back into the scanner), which
    /// is why the cross-push single-delivery latch lives up in ``BarcodeScanView`` instead.
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
/// **Optional online lookup (tracker §3.3).** For a valid barcode the screen also offers
/// ``OpenFoodFactsLookupCard``: one explicit tap per lookup, only behind the web-nutrition-lookup
/// consent, sending only the barcode digits to Open Food Facts. Scanning itself stays offline. A
/// found product PREFILLS this screen (`applyOnlineImport(_:)`) rather than saving anything, so the
/// screen's own review gate — the fix-1.14 plausibility and completeness nudges on "Remember this
/// food" — runs over Open Food Facts' values exactly as over a scanned label. Remembering then saves
/// a `.openFoodFacts` user food (`rememberOnlineImport(_:)`); rescanning the label first hands the
/// numbers back to the user, and the save is an ordinary `.manual` food.
struct BarcodeNotFoundView: View {
    var store: FernletStore
    let barcode: String
    /// When the auto-router already parsed a nutrition label from the captured photo, the macros
    /// arrive pre-filled here so the naming screen opens with the rings populated (no rescan needed).
    /// nil for the ordinary barcode not-found handoff.
    var prefilledScan: NutritionLabelResult? = nil
    /// The page Back returns to ("Log meal", "Scan a food"), already resolved; nil says "Back".
    var backTitle: String? = nil
    var onCreated: (FoodItem) -> Void

    @State private var name = ""
    @State private var scanResult: NutritionLabelResult?
    @State private var showingLabelScanner = false
    /// A gentle nudge shown when "Remember this food" is tapped with no macros yet — a 0g food logs a
    /// meal that counts for nothing. We offer to scan the label first, but never hard-block: the user
    /// can still choose "Remember it anyway".
    @State private var showingEmptyMacroNudge = false
    /// A second gentle nudge (fix 1.14) shown when the scanned panel's numbers CONTRADICT each other —
    /// calories that don't match the macros, a fat breakdown bigger than the total fat, a decimal point
    /// the OCR lost — or, more softly, when a value trips the outer ceiling guard. Same contract as
    /// the empty-macro nudge: offer a rescan, never hard-block.
    @State private var showingPlausibilityReview = false
    /// Set by a dialog button that wants the label scanner, and consumed once the dialog has actually
    /// gone away. Assigning `showingLabelScanner` from INSIDE a dismissing confirmation dialog is this
    /// project's documented covered-destination trap: the push is swallowed and the button does
    /// nothing. Both nudges route through this flag rather than setting the destination directly.
    ///
    /// - Note: NOT covered by a UI test, and the reason is structural rather than an oversight.
    ///   `BarcodeNotFoundView` is a navigation destination reached only after a live camera scan
    ///   returns an unrecognised payload, which XCUITest cannot synthesise on a simulator. The one
    ///   place it is constructed with an injectable `prefilledScan` is `FoodView.swift`, and every
    ///   route to it on launch would need a new `FernletSheet` case presented from there or from
    ///   `ContentView` — both outside this change. The follow-up is small and specific: add a
    ///   `FERNLET_UI_TEST_OPEN_BARCODE_NOT_FOUND` hook to `UITestSupport` in the same shape as
    ///   `shouldOpenJournalEditor`, present `BarcodeNotFoundView(prefilledScan:)` from it with a
    ///   contradictory synthetic scan, and assert that "Rescan the nutrition label" reaches the
    ///   label camera. Until then the handoff above is order-independent by construction rather
    ///   than by test.
    @State private var pendingLabelScan = false
    /// Once the food is saved we show the "Remembered" (11c) confirmation and hold the item; the
    /// user's "Done" tap fires `onCreated`, so the create logic itself is unchanged — we only give
    /// the confirmation its moment before the flow dismisses.
    @State private var rememberedItem: FoodItem?
    /// Set when the save comes back empty, so a failed "Remember this food" tap says something instead
    /// of leaving the screen unchanged.
    @State private var saveNotice: String?
    /// The Open Food Facts product this screen was prefilled from, if the user looked the barcode up.
    /// Cleared when they rescan the label, because the numbers are then their own.
    @State private var onlineImport: OpenFoodFactsProduct?
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        Group {
            if let rememberedItem {
                // b3-remembered: Done top right is the way on (the serving step), no Back.
                RememberedConfirmationView(item: rememberedItem) {
                    onCreated(rememberedItem)
                }
                .toolbar(.hidden, for: .navigationBar)
            } else {
                namingScreen
                    .foodSheetPushedPage("Remember product", back: backTitle)
            }
        }
        .foodSheetBackground()
        // Always pushed (the meal sheet's or the recipe editor's stack), so the name field's
        // keyboard "Done" is declared on the page: a Done outside the stack never reaches it.
        .keyboardDoneToolbar()
        .onAppear {
            // Seed the macros the auto-router already read (once — don't clobber a rescan).
            if scanResult == nil, let prefilledScan {
                scanResult = prefilledScan
                if trimmedName.isEmpty, let servingSize = prefilledScan.servingSize, servingSize.isEmpty == false {
                    name = ScannedItemName.prefill(servingSize: servingSize)
                }
            }
        }
        // Pushed inside a tab's stack (the recipe editor's barcode flow): a re-tap of the tab asks
        // before it pops a named or scanned food that has not been remembered yet.
        .tabReselectDraft(isDirty: hasUnrememberedInput)
    }

    /// Whether the screen holds a name or scanned macros that "Remember this food" has not saved.
    private var hasUnrememberedInput: Bool {
        rememberedItem == nil && (!trimmedName.isEmpty || scanResult != nil)
    }

    // MARK: Naming screen (11b)

    /// The scrolling half of the naming screen (`b3-remember` draft 2, "quieter"): the one-line header
    /// beside a small companion, the name first, Open Food Facts as one button, the optional label
    /// scan, then the macro tiles. Split out of ``namingScreen`` so both stay inside the 60-line body
    /// budget (R4).
    private var namingFormBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                namingHeader

                FoodSheetField("What should we call it?") {
                    TextField("Hazelnut oat bar", text: $name, prompt: .fieldPrompt("Hazelnut oat bar"))
                        .sheetTextInput()
                }

                if let lookupBarcode = OpenFoodFactsBarcode(scanned: barcode) {
                    OpenFoodFactsLookupCard(store: store, barcode: lookupBarcode, onFound: applyOnlineImport)
                }

                labelScanButton

                macroSection
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
    }

    private var namingScreen: some View {
        VStack(spacing: 0) {
            namingFormBody

            if let saveNotice {
                FernletNotice(text: Text(saveNotice), tone: .warn) { EmptyView() }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            SheetSaveBar(label: "Remember this food", disabled: trimmedName.isEmpty) {
                // Saving here also logs the meal (via `onCreated`), so an all-zero food would quietly
                // log a meal that counts for nothing. Nudge to add macros first — softly, not a wall.
                if macrosAreEmpty {
                    showingEmptyMacroNudge = true
                } else if !reviewFindings.isEmpty {
                    // The numbers are present but disagree with each other (fix 1.14). Same softness:
                    // offer a rescan, and let "Remember it anyway" through untouched.
                    showingPlausibilityReview = true
                } else {
                    rememberFood()
                }
            }
        }
        .confirmationDialog(
            "No macros yet",
            isPresented: $showingEmptyMacroNudge,
            titleVisibility: .visible
        ) {
            Button("Scan the nutrition label") { pendingLabelScan = true }
            Button("Remember it anyway") { rememberFood() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(verbatim: emptyMacroMessage)
        }
        .confirmationDialog(
            reviewTitle,
            isPresented: $showingPlausibilityReview,
            titleVisibility: .visible
        ) {
            Button("Rescan the nutrition label") { pendingLabelScan = true }
            Button("Remember it anyway") { rememberFood() }
            Button("Cancel", role: .cancel) { }
        } message: {
            // Already-localized copy from the gate's findings, so it goes through verbatim rather
            // than being looked up a second time as a key.
            Text(verbatim: reviewMessage)
        }
        // Both nudges hand the label scanner over through `pendingLabelScan`, consumed once the
        // dialog is gone — see the flag's declaration. All three bindings are watched because
        // whichever of "the action ran" and "the dialog dismissed" happens second is what completes
        // the handoff.
        .onChange(of: pendingLabelScan) { _, _ in consumePendingLabelScan() }
        .onChange(of: showingEmptyMacroNudge) { _, _ in consumePendingLabelScan() }
        .onChange(of: showingPlausibilityReview) { _, _ in consumePendingLabelScan() }
        .navigationDestination(isPresented: $showingLabelScanner) {
            NutritionLabelCameraSheet(showCalories: store.settings.showCalories,
                                      backTitle: String(localized: "Remember")) { result in
                scanResult = result
                // The user's own scan replaces Open Food Facts' numbers, so the save is theirs.
                onlineImport = nil
                if trimmedName.isEmpty, let servingSize = result.servingSize, servingSize.isEmpty == false {
                    name = ScannedItemName.prefill(servingSize: servingSize)
                }
            }
        }
    }

    /// The one-line header beside a small companion (draft 2: "We haven't met this one").
    private var namingHeader: some View {
        HStack(spacing: 12) {
            FernletIconTile(size: 48) { headerCompanion }
                .accessibilityHidden(true)
            Text("We haven't met this one")
                .font(look == nil ? .fernlet(.header) : FernletFramedFont.cardTitle)
                .foregroundStyle(look?.text ?? Color.bark)
                .fernletWrappingText()
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// The companion beside the header: its pixel sprite, still, in the World look (`b3-remember`);
    /// today's face without it.
    @ViewBuilder private var headerCompanion: some View {
        if look != nil {
            let state = store.liveCompanionState
            let companion = WorldCompanionLook(appearance: store.settings.companionAppearance, state: state, asleep: false)
            WorldCompanionCanvas(grid: WorldCompanionPainter.paint(state: state, look: companion, pose: WorldCompanionPose()),
                                 scale: 2)
                .frame(width: WorldCompanionSprite.size(scale: 2).width, height: WorldCompanionSprite.size(scale: 2).height)
        } else {
            CompanionFace().frame(width: 36, height: 36)
        }
    }

    /// The optional "scan the nutrition label" row, a dashed framed card wired to the label scanner.
    private var labelScanButton: some View {
        Button {
            showingLabelScanner = true
        } label: {
            HStack(spacing: 14) {
                FernletIconTile(size: 44) { WorldSpriteView(sprite: FoodSprites.doc, scale: 3) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(scanResult == nil ? "Scan the nutrition label" : "Rescan the nutrition label")
                        .font(FoodFont.rowName)
                        .foregroundStyle(look?.text ?? Color.bark)
                    Text("optional — we'll read the macros for you")
                        .font(FernletFramedFont.rowDetail)
                        .foregroundStyle(look?.dim ?? Color.slate)
                        .fernletWrappingText()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                FernletIcon(.chevron, scale: 2)
            }
            .padding(14)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(look?.ink ?? Color.moss.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Macros, per serving — grams only, NEVER a calorie value: three framed tiles with the pixel
    /// drumstick, wheat and drop, each over its macro's colour bar.
    private var macroSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Macros, per serving")
                Spacer(minLength: 8)
                Text("grams — no calories here")
                    .font(FernletFramedFont.rowDetail)
                    .foregroundStyle(look?.dim ?? Color.softTaupe)
            }

            HStack(spacing: 10) {
                FoodMacroTile(kind: .protein, grams: scanResult?.protein ?? 0)
                FoodMacroTile(kind: .carbs, grams: scanResult?.carbs ?? 0)
                FoodMacroTile(kind: .fat, grams: scanResult?.fat ?? 0)
            }

            if let servingSize = scanResult?.servingSize, servingSize.isEmpty == false {
                Text("Per serving: \(servingSize)")
                    .font(FernletFramedFont.note)
                    .foregroundStyle(look?.dim ?? Color.slate)
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The fix-1.14 plausibility + completeness report for the current scan, computed over the OCR
    /// result with its optionals INTACT — a label line the scanner never read stays `nil` here
    /// instead of becoming a claim that the product contains none of that nutrient.
    private var plausibility: NutritionPlausibilityReport {
        Self.plausibility(ofScan: scanResult)
    }

    /// The same report for a scan that MAY NOT HAVE HAPPENED YET, which on this screen is the
    /// ordinary case rather than the edge one.
    ///
    /// The nil branch substitutes an EMPTY `NutritionLabelResult` rather than a `.clean` report, and
    /// the difference is the whole point. `.clean` names no missing fields, so the "Still missing: …"
    /// line vanished in the dominant trigger of the empty-macro nudge: this screen has no manual
    /// macro entry, so "nothing scanned yet" IS the four-silent-zeros case the nudge exists to warn
    /// about. An empty result reports every core field as missing, which is the truth. Nothing is
    /// reported, so no arithmetic finding can fire either way — which is exactly why the regression
    /// was invisible, and why it is pinned by a test rather than left to review.
    ///
    /// No food name is passed, deliberately. The name would resolve the 21 CFR 101.9(j)(4)
    /// insignificant-nutrient exemption, and that exemption is for a food bearing no nutrition
    /// information — a barcoded packaged product with a Nutrition Facts panel is outside it by
    /// definition. Its home is the hand-typed custom-food seam, not this screen.
    static func plausibility(ofScan scan: NutritionLabelResult?) -> NutritionPlausibilityReport {
        (scan ?? NutritionLabelResult()).plausibilityReport()
    }

    /// The findings the review dialog speaks about. Arithmetic contradictions outrank the outer
    /// ceiling guard, so they are shown alone when present; a ceiling on its own gets the softer
    /// wording instead. (`allReportedValuesZero` never reaches here — every reported value being
    /// zero implies empty macros, which `macrosAreEmpty` catches first with copy written for it.)
    private var reviewFindings: [NutritionPlausibilityFinding] {
        let contradictions = plausibility.contradictions.filter { $0 != .allReportedValuesZero }
        return contradictions.isEmpty ? plausibility.advisories : contradictions
    }

    /// The dialog's title, which must match the CLASS of finding being shown: a curve-fitted ceiling
    /// is a "have another look", never a claim that the user's arithmetic is broken.
    private var reviewTitle: LocalizedStringKey {
        reviewFindings.contains(where: { !$0.isAdvisory })
            ? "These numbers don't add up"
            : "Worth a second look"
    }

    /// Up to three findings (with an honest "and N more" tail), plus the completeness line naming
    /// what was never filled in.
    private var reviewMessage: String {
        [NutritionPlausibilityReport.message(for: reviewFindings, limit: 3), missingMacrosMessage]
            .compactMap { $0 }
            .joined(separator: "\n\n")
    }

    /// The empty-macro nudge's copy, plus the same completeness line — so the user is TOLD which
    /// values are about to be stored as zero before they choose "Remember it anyway".
    private var emptyMacroMessage: String {
        let lead = String(localized: "Without macros this logs as 0g, so it won't count toward your day. Scan the label to add them — or remember it now and fill them in later.")
        guard let missingMacrosMessage else { return lead }
        return lead + "\n\n" + missingMacrosMessage
    }

    /// "Still missing: …" for the fields this screen can meaningfully name.
    ///
    /// Calories are dropped: this screen states outright that it deals in grams and shows no calorie
    /// figure, and Fernlet derives energy from the macros anyway, so naming it would point at a box
    /// that does not exist here. Serving size and the three macros are exactly the values that would
    /// otherwise be stored as a silent zero, which is what §26 asks to be named.
    private var missingMacrosMessage: String? {
        Self.missingMacrosMessage(forScan: scanResult)
    }

    /// The same line for an arbitrary (possibly absent) scan, so the copy the user actually reads is
    /// reachable from a test — including the no-scan case, where it must name serving size and all
    /// three macros rather than saying nothing at all.
    static func missingMacrosMessage(forScan scan: NutritionLabelResult?) -> String? {
        NutritionPlausibilityReport.missingFieldsMessage(
            for: plausibility(ofScan: scan).missingFields.filter { $0 != .calories }
        )
    }

    /// True when nothing has filled in the macros yet (no label scanned, or a scan that read all
    /// zeros) — the case where remembering-and-logging would contribute nothing to the day.
    ///
    /// - Note: no insignificant-nutrient exemption here, and that is deliberate. Wiring 21 CFR
    ///   101.9(j)(4) into this screen was wrong twice over: the exemption is for a food that bears no
    ///   nutrition information, which a barcoded product is not, and keying it off the typed name
    ///   silently disabled this nudge for anyone who happened to call their unscanned product
    ///   "coffee" — saving 0 g with no warning at all.
    private var macrosAreEmpty: Bool {
        (scanResult?.protein ?? 0) == 0 && (scanResult?.carbs ?? 0) == 0 && (scanResult?.fat ?? 0) == 0
    }

    /// Pushes the label scanner once the flag is set AND no nudge dialog is still on screen.
    ///
    /// Deliberately order-independent: SwiftUI does not promise whether a confirmation dialog's
    /// button action runs before or after its `isPresented` binding flips, so this is watched from
    /// all three bindings and simply fires on whichever change makes both conditions true.
    private func consumePendingLabelScan() {
        guard pendingLabelScan, !showingEmptyMacroNudge, !showingPlausibilityReview else { return }
        pendingLabelScan = false
        showingLabelScanner = true
    }

    /// Persist the named product as a user `FoodItem` and hand off to the "Remembered" confirmation
    /// (whose "Done" fires `onCreated`, logging the meal). Shared by the save bar and the empty-macro
    /// "Remember it anyway" path so the create logic stays in one place.
    private func rememberFood() {
        // Open Food Facts' numbers, still unchanged since the lookup, are saved with their provenance
        // (and their licence notice) rather than as a hand-entered food.
        if let onlineImport, Self.savesAsOnlineImport(scan: scanResult, imported: onlineImport) {
            rememberOnlineImport(onlineImport)
            return
        }
        // The `?? 0`s below are the collapse the gate exists to warn about — and they stay, because
        // `ManualRecipeIngredientInput` and `Macros` store the macros as non-optional grams (the scan
        // itself reads whole grams) and this round does not change that schema. What the gate buys is that the collapse is no longer
        // SILENT: whichever nudge applies has already named the fields about to be stored as zero
        // (`missingMacrosMessage`) and the user chose "Remember it anyway". Naming-then-storing is
        // what §26 asks for; making absence representable all the way to disk is a schema question
        // for the ledger, not a change to make behind a save button.
        let micros = scanResult?.micronutrients()
        let input = ManualRecipeIngredientInput(
            name: trimmedName,
            quantity: 1,
            unit: RecipeUnit.serving.rawValue,
            protein: Double(scanResult?.protein ?? 0),
            carbs: Double(scanResult?.carbs ?? 0),
            fat: Double(scanResult?.fat ?? 0),
            scannedMicronutrients: micros?.hasAnyValue == true ? micros : nil,
            barcode: barcode
        )
        guard let item = store.saveCustomIngredient(input) else {
            // Recovery: tell the user rather than swallowing the failed save silently.
            reportSaveFailure(String(localized: "barcode.rememberFood.saveFailed",
                                     defaultValue: "Fernlet couldn't save that food — give it a name and try again.",
                                     comment: "Barcode name-it screen: remembering the scanned food failed"))
            FernletAuditLog.log(
                "barcode.rememberFood.failed",
                context: ["reason": "saveCustomIngredient returned nil"]
            )
            return
        }
        reportRemembered(item)
    }

    // MARK: Optional online lookup (tracker §3.3)

    /// Prefills the screen from a product Open Food Facts knows: its name when the user has not typed
    /// one, and its values as this screen's scan model so the review gate runs over them. Nothing is
    /// saved here — the user still has to tap "Remember this food".
    private func applyOnlineImport(_ product: OpenFoodFactsProduct) {
        onlineImport = product
        if trimmedName.isEmpty, let suggested = product.suggestedName {
            name = suggested
        }
        if let imported = product.labelResult() {
            scanResult = imported
        }
    }

    /// Saves the reviewed Open Food Facts product under the name on screen, as a `.openFoodFacts`
    /// user food, and hands off to the "Remembered" confirmation (whose "Done" leads to the serving
    /// step — the meal is logged only there).
    private func rememberOnlineImport(_ product: OpenFoodFactsProduct) {
        guard let item = store.saveOpenFoodFactsFood(product, named: trimmedName) else {
            reportSaveFailure(String(localized: "barcode.onlineImport.saveFailed",
                                     defaultValue: "Fernlet couldn't save that food — give it a name and try again.",
                                     comment: "Shown under the barcode naming screen when saving a product found on Open Food Facts failed."))
            FernletAuditLog.log(
                "barcode.rememberOnlineImport.failed",
                context: ["reason": "saveOpenFoodFactsFood returned nil"]
            )
            return
        }
        reportRemembered(item)
    }

    /// A remembered food hands off to the "Remembered" confirmation, felt as `done` (§7): a save the
    /// person asked for that nothing else confirms in place.
    private func reportRemembered(_ item: FoodItem) {
        saveNotice = nil
        rememberedItem = item
        FernletFeedback.system.play(.done)
    }

    /// A failed "Remember this food" says so three ways (A6): the line under the field, the error
    /// haptic, and VoiceOver — which used to hear nothing, because nothing moves focus to the line.
    private func reportSaveFailure(_ message: String) {
        saveNotice = message
        FernletFeedback.system.play(.failed)
        FernletAnnouncer.system.announce(.error, resolved: message)
    }

    /// Whether a save should keep Open Food Facts provenance: only while the values on screen are
    /// still exactly the ones the lookup produced. A label the user scanned since then makes the
    /// numbers theirs; a product that had no usable nutrition never carries OFF provenance.
    static func savesAsOnlineImport(scan: NutritionLabelResult?, imported: OpenFoodFactsProduct) -> Bool {
        guard let scan, let importedScan = imported.labelResult() else { return false }
        return scan == importedScan
    }
}

// MARK: - Remembered confirmation (b3-remembered)

/// The soft "Remembered" success state (`b3-remembered`, approved 2026-10-24): Done top right (the way
/// on to the serving step), a framed moss medal with a pixel tick, a warm line naming the food, and the
/// food on a framed card with its macros as coloured tags in grams (never calories). The Open Food Facts
/// credit shows when the numbers came from there.
struct RememberedConfirmationView: View {
    let item: FoodItem
    var onDone: () -> Void

    @State private var appeared = false
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.plain)
                    .font(FernletFramedFont.sheetControl)
                    .foregroundStyle(look?.link ?? Color.moss)
                    .fernletTapTarget()
                    .accessibilityIdentifier("sheet.done")
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            ScrollView {
                VStack(spacing: 18) {
                    checkMedallion
                    messageBlock
                    foodChip
                    attribution
                }
                .padding(.horizontal, 18)
                .padding(.top, 40)
                .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.7)) { appeared = true }
        }
    }

    /// The framed moss medal with the pixel tick, scaling in on appear (still under Reduce Motion).
    private var checkMedallion: some View {
        ZStack {
            Circle().fill(look?.mark ?? Color.moss)
            Circle().strokeBorder(look?.ink ?? Color.clear, lineWidth: 3)
            WorldSpriteView(sprite: WorldSprites.check, scale: 6, tint: WorldPalette.gameCream)
        }
        .frame(width: 96, height: 96)
        .background { Circle().fill(look?.shadow ?? Color.clear).offset(y: 4) }
        .scaleEffect(appeared || reduceMotion ? 1 : 0.6)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .accessibilityHidden(true)
    }

    /// "Remembered" plus the warm line naming the food.
    private var messageBlock: some View {
        VStack(spacing: 10) {
            Text("Remembered")
                .font(.custom(FernletFontName.frauncesSemiBold, size: 40, relativeTo: .largeTitle))
                .foregroundStyle(look?.text ?? Color.bark)
                .accessibilityAddTraits(.isHeader)

            Text("\(item.name) is in your foods now — scan it again and it'll log in a tap.")
                .font(look == nil ? .fernlet(.body) : FernletFramedFont.body)
                .foregroundStyle(look?.dim ?? Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
        }
    }

    /// The licence notice for a food whose numbers came from an attributed source (Open Food Facts,
    /// ODbL) — already localized by the domain model.
    @ViewBuilder private var attribution: some View {
        if let attribution = item.source.attributionLine {
            Text(verbatim: attribution)
                .font(FernletFramedFont.rowDetail)
                .foregroundStyle(look?.dim ?? Color.slate)
                .multilineTextAlignment(.center)
        }
    }

    /// The food on a framed card: the basket on a gold tile, its name, and P / C / F as tags.
    private var foodChip: some View {
        FernletCard {
            HStack(spacing: 13) {
                FernletIconTile(size: 44, fill: WorldPalette.rgb(0xF2D58A)) {
                    WorldSpriteView(sprite: WorldSprites.basket, scale: 2)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(FoodFont.rowName)
                        .foregroundStyle(look?.text ?? Color.bark)
                        .lineLimit(2)
                    FoodMacroTagRow(macros: item.macros)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(item.macros.protein) grams protein, \(item.macros.carbs) grams carbs, \(item.macros.fat) grams fat")
    }
}

// MARK: - Small pieces

/// One macro on Remember product (`b3-remember` draft 2): a framed tile with the macro's pixel icon
/// (drumstick, wheat, drop), the grams in bold, the name, and a bar in the macro's colour. Grams
/// only — this tile never renders or computes calories.
private struct FoodMacroTile: View {
    let kind: FoodMacroKind
    let grams: Int
    @Environment(\.fernletFramedLook) private var look

    private var name: LocalizedStringKey {
        switch kind {
        case .protein: "Protein"
        case .carbs: "Carbs"
        case .fat: "Fat"
        }
    }

    private var sprite: WorldSprite {
        switch kind {
        case .protein: FoodSprites.drumstick
        case .carbs: FoodSprites.wheat
        case .fat: FoodSprites.fatDrop
        }
    }

    var body: some View {
        FernletCard {
            VStack(spacing: 6) {
                WorldSpriteView(sprite: sprite, scale: 3)
                Text(verbatim: "\(grams)g")
                    .font(.custom(FernletFontName.dmSansBold, size: 22, relativeTo: .title3))
                    .foregroundStyle(look?.text ?? Color.bark)
                    .monospacedDigit()
                Text(name)
                    .font(FernletFramedFont.rowDetail)
                    .foregroundStyle(look?.dim ?? Color.slate)
                kind.colour
                    .frame(height: 8)
                    .overlay(Rectangle().strokeBorder(look?.ink ?? Color.clear, lineWidth: 1.5))
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(Text(name)): \(grams) grams"))
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
