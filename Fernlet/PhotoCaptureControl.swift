#if canImport(UIKit)
import SwiftUI
import PhotosUI
import ImageIO

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
        .fullScreenCover(isPresented: $showingCamera) {
            ImagePickerView(sourceType: .camera) { image in
                onCameraCapture(image)
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $isLibraryPickerActive, selection: $selectedItem, matching: .images)
        .onChange(of: showingCamera) { _, _ in reportCaptureUIPresentation() }
        .onChange(of: isLibraryPickerActive) { _, _ in reportCaptureUIPresentation() }
        .onChange(of: selectedItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    if let onLibraryPickData {
                        // Hand the bytes straight through — the store does the only (bounded) decode.
                        onLibraryPickData(data, PhotoMetadata.creationDate(from: data))
                    } else {
                        // Legacy UIImage sink for callers that need a decoded image (meal preview).
                        let handler = onLibraryPick ?? onCameraCapture
                        if let image = UIImage(data: data) { handler(image) }
                    }
                } else {
                    // A pick the user made but whose bytes couldn't load must not vanish silently —
                    // the store-failure paths already show feedback, so this joins them.
                    onLibraryPickFailed?()
                }
                selectedItem = nil
            }
        }
    }

    private func reportCaptureUIPresentation() {
        onCaptureUIPresentationChange?(showingCamera || isLibraryPickerActive)
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
