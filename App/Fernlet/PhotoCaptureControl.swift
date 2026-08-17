#if canImport(UIKit)
import SwiftUI
import PhotosUI
import ImageIO
import os

/// A tappable control that yields a photo, using the camera when one is available and falling back
/// to the photo library otherwise — the pattern that was inlined in the food-log sheet, extracted so
/// meal capture and the new gym progress-photo capture (#11) share one implementation instead of two.
///
/// The camera is presented as a full-screen `ImagePickerView`; on the Simulator (no camera) and on
/// camera-less or access-denied devices it presents a `PhotosPicker` instead of a dead black modal.
///
/// Sources: by default a single tap goes straight to the camera when one exists (the meal "Capture"
/// button's deliberate camera-first feel). Callers that also want to attach an *existing* photo set
/// `allowsLibraryChoice` — a tap then offers "Take photo" / "Choose from library" (recipe detail and
/// the progress-photo timeline, where you often already have the shot). The chooser only appears when a
/// camera is present; camera-less devices go straight to the library either way.
///
/// Library results can be delivered two ways. `onLibraryPickData` hands back the picked JPEG **`Data`**
/// (plus a best-effort creation date read from EXIF) so a caller can seal it through the store's bounded
/// ImageIO downscale WITHOUT ever materialising the full-resolution bitmap — a 48 MP pick would
/// otherwise decode to ~190 MB and risk jetsam on the iPhone-11 floor. When it's nil, library picks fall
/// back to the `UIImage` path (`onLibraryPick`, defaulting to `onCameraCapture`) for callers that need a
/// decoded image on hand (the meal sheet's preview/identify flow).
struct PhotoCaptureControl<Label: View>: View {
    var onCameraCapture: (UIImage) -> Void
    var onLibraryPick: ((UIImage) -> Void)?
    /// Preferred library sink: the raw picked `Data` and the photo's creation date (nil if unknown).
    /// When set, it takes priority over `onLibraryPick` and the bitmap is never decoded here.
    var onLibraryPickData: ((Data, Date?) -> Void)?
    /// Called when a library pick's bytes fail to load (iCloud eviction, transfer error), so the caller
    /// can surface its "couldn't save this photo" feedback instead of the pick vanishing silently.
    var onLibraryPickFailed: (() -> Void)? = nil
    /// Reports when the control's OWN capture UI (the full-screen camera cover / library picker) is
    /// presented or dismissed. The camera cover fires `onDisappear` on the hierarchy it covers, so a
    /// host that re-locks on disappear (the progress-photo timeline) uses this to suppress that
    /// re-lock mid-capture.
    var onCaptureUIPresentationChange: ((Bool) -> Void)? = nil
    /// Offer a source chooser (camera vs library) instead of jumping straight to the camera.
    var allowsLibraryChoice: Bool = false
    @ViewBuilder var label: () -> Label

    @State private var showingCamera = false
    @State private var isLibraryPickerActive = false
    @State private var showingSourceChooser = false
    @State private var selectedItem: PhotosPickerItem?

    var body: some View {
        Button {
            let hasCamera = UIImagePickerController.isSourceTypeAvailable(.camera)
            if allowsLibraryChoice && hasCamera {
                showingSourceChooser = true
            } else if hasCamera {
                showingCamera = true
            } else {
                isLibraryPickerActive = true
            }
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .confirmationDialog("Add a photo", isPresented: $showingSourceChooser, titleVisibility: .visible) {
            Button("Take photo") { showingCamera = true }
            Button("Choose from library") { isLibraryPickerActive = true }
            Button("Cancel", role: .cancel) {}
        }
        .photoCapturePlumbing(
            showingCamera: $showingCamera,
            selection: $selectedItem,
            onCameraImage: onCameraCapture,
            // Hand the bytes straight through — the store does the only (bounded) decode.
            onLibraryData: onLibraryPickData.map { sink in
                { data in sink(data, PhotoMetadata.creationDate(from: data)) }
            },
            onLibraryImage: onLibraryPick,
            onLibraryLoadFailed: onLibraryPickFailed
        )
        .photosPicker(isPresented: $isLibraryPickerActive, selection: $selectedItem, matching: .images)
        .onChange(of: showingCamera) { _, _ in reportCaptureUIPresentation() }
        .onChange(of: isLibraryPickerActive) { _, _ in reportCaptureUIPresentation() }
    }

    private func reportCaptureUIPresentation() {
        onCaptureUIPresentationChange?(showingCamera || isLibraryPickerActive)
    }
}

/// Shared camera-cover + library-selection plumbing for the app's photo-capture surfaces.
extension View {
    /// Attaches the two halves of photo capture that every capture surface repeats: a full-screen
    /// `ImagePickerView` camera cover driven by `showingCamera`, and consumption of a
    /// `PhotosPickerItem` selection (load bytes, deliver, reset the selection to nil).
    ///
    /// Shared by ``PhotoCaptureControl``, `BarcodeScanView`'s still-photo fallback, and
    /// `NutritionLabelCameraSheet`. The library picker's *presentation* is deliberately not part of
    /// this modifier — the three call sites present theirs differently (an in-chain `photosPicker`,
    /// a menu-anchored picker, and a `PhotosPicker` label button).
    ///
    /// Library delivery mirrors the sinks ``PhotoCaptureControl`` exposes:
    /// - `onLibraryData`, when set, receives the raw picked bytes with no `UIImage` decode here —
    ///   the jetsam-avoidance path (the store does the only, bounded decode).
    /// - Otherwise the bytes are decoded and handed to `onLibraryImage`, falling back to
    ///   `onCameraImage`.
    /// - `onLibraryLoadFailed` fires when `loadTransferable` throws or yields nothing (iCloud
    ///   eviction, transfer error) AND when the bytes decode to no image; every one of those paths
    ///   also logs its reason, so a dropped pick is never invisible.
    ///
    /// - Parameters:
    ///   - showingCamera: Presents the full-screen rear-camera cover while true.
    ///   - selection: The `PhotosPicker` selection to consume; reset to nil after handling.
    ///   - flashMode: Camera flash mode for `ImagePickerView` (the label scanner's torch toggle).
    ///   - onCameraImage: Receives the captured camera image — and decoded library picks when no
    ///     library-specific sink is provided.
    ///   - onLibraryData: Priority library sink for the raw picked bytes; skips the decode.
    ///   - onLibraryImage: Library sink for a decoded image; defaults to `onCameraImage`.
    ///   - onLibraryLoadFailed: Called when the selection's bytes fail to load.
    func photoCapturePlumbing(
        showingCamera: Binding<Bool>,
        selection: Binding<PhotosPickerItem?>,
        flashMode: UIImagePickerController.CameraFlashMode = .auto,
        onCameraImage: @escaping (UIImage) -> Void,
        onLibraryData: ((Data) -> Void)? = nil,
        onLibraryImage: ((UIImage) -> Void)? = nil,
        onLibraryLoadFailed: (() -> Void)? = nil
    ) -> some View {
        self
            .fullScreenCover(isPresented: showingCamera) {
                ImagePickerView(sourceType: .camera, flashMode: flashMode) { image in
                    onCameraImage(image)
                }
                .ignoresSafeArea()
            }
            .onChange(of: selection.wrappedValue) { _, newItem in
                guard let newItem else { return }
                Task {
                    let loaded: Data?
                    do {
                        loaded = try await newItem.loadTransferable(type: Data.self)
                    } catch {
                        // iCloud eviction / transfer error: name it, then take the failure path.
                        Logger(subsystem: "com.fernlet", category: "photoPicker")
                            .error("library pick failed: \(error.localizedDescription, privacy: .public)")
                        loaded = nil
                    }
                    // A pick the user made but whose bytes couldn't load — or that decoded to
                    // nothing — must not vanish silently when the caller opted into feedback.
                    guard let data = loaded else {
                        onLibraryLoadFailed?()
                        selection.wrappedValue = nil
                        return
                    }
                    if let onLibraryData {
                        onLibraryData(data)
                    } else if let image = UIImage(data: data) {
                        (onLibraryImage ?? onCameraImage)(image)
                    } else {
                        Logger(subsystem: "com.fernlet", category: "photoPicker")
                            .error("library pick decoded to no image")
                        onLibraryLoadFailed?()
                    }
                    selection.wrappedValue = nil
                }
            }
    }
}

/// Reads a photo's capture date from its own bytes.
///
/// A non-generic namespace so it can hold the shared `DateFormatter` as a static stored property
/// (generic types can't). Kept out of ``PhotoCaptureControl`` for that reason alone; the control's
/// library path is its only caller.
private enum PhotoMetadata {
    /// Best-effort capture date recovered from the picked bytes' own EXIF/TIFF metadata — no photo-library
    /// permission needed, because the metadata travels with the exported `Data` (unlike `PHAsset.creationDate`,
    /// which would require broad library access). Returns nil for screenshots, edited exports, or any image
    /// without a date tag; the caller then defaults to "now" and the manual date editor remains the floor.
    static func creationDate(from data: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let raw = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String) else { return nil }
        guard let date = exifDateFormatter.date(from: raw) else { return nil }
        // Clamp to now: a wrong camera clock can stamp a FUTURE date, and the manual date editor caps
        // at today — an imported photo must not be able to sit past the cap the editor enforces.
        return min(date, Date())
    }

    /// EXIF/TIFF dates are "yyyy:MM:dd HH:mm:ss" in the camera's local time (no zone), so parse in the
    /// current zone with a fixed POSIX locale.
    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()
}
#endif
