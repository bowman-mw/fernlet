#if canImport(UIKit)
import SwiftUI
import PhotosUI

/// A tappable control that yields a `UIImage`, using the camera when one is available and falling back
/// to the photo library otherwise — the pattern that was inlined in the food-log sheet, extracted so
/// meal capture and the new gym progress-photo capture (#11) share one implementation instead of two.
///
/// The camera is presented as a full-screen `ImagePickerView`; on the Simulator (no camera) and on
/// camera-less or access-denied devices it presents a `PhotosPicker` instead of a dead black modal.
///
/// Two callbacks so a caller can treat the two sources differently (the food sheet routes a *camera*
/// shot through its auto-detect front door but simply attaches a *library* pick): `onLibraryPick`
/// defaults to `onCameraCapture` when a caller wants both handled identically (the common case).
struct PhotoCaptureControl<Label: View>: View {
    var onCameraCapture: (UIImage) -> Void
    var onLibraryPick: ((UIImage) -> Void)?
    @ViewBuilder var label: () -> Label

    @State private var showingCamera = false
    @State private var isLibraryPickerActive = false
    @State private var selectedItem: PhotosPickerItem?

    var body: some View {
        Button {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                showingCamera = true
            } else {
                isLibraryPickerActive = true
            }
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .fullScreenCover(isPresented: $showingCamera) {
            ImagePickerView(sourceType: .camera) { image in
                onCameraCapture(image)
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $isLibraryPickerActive, selection: $selectedItem, matching: .images)
        .onChange(of: selectedItem) { _, newItem in
            guard let newItem else { return }
            let handler = onLibraryPick ?? onCameraCapture
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    handler(image)
                }
                selectedItem = nil
            }
        }
    }
}
#endif
