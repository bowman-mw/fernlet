import SwiftUI
import AVFoundation
import UIKit
import FernletDomainModel
import FernletFoundation
import ProximityKit
import FernletConnections
import FernletSocial
import AppServices
import FernletUI
import FernletProximityUI
import FernletConnections
import os

// MARK: - Camera preview (UIViewRepresentable)

/// `UIViewRepresentable` wrapper showing the live `AVCaptureSession` preview layer.
///
/// Owns horizon-level rotation via `AVCaptureDevice.RotationCoordinator` and detaches the
/// session reference in `dismantleUIView`. ``DisposableCameraView`` keeps exactly one instance
/// structurally stable across rotation so the running capture session is never torn down and
/// reattached (the old freeze / black flash).
///
/// The preview view opts out of Smart Invert (`accessibilityIgnoresInvertColors`, T2-10): an
/// inverted viewfinder frames a shot the camera will not take.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        // T2-10: Smart Invert inverts the live preview, so the user frames a shot against a colour
        // negative and the photo that comes out is nothing like what they aimed at. Set here rather
        // than at the call site because exactly one instance exists and it is repositioned, never
        // rebuilt, across rotation — a call-site modifier would be easy to lose in that dance.
        v.accessibilityIgnoresInvertColors = true
        guard let previewLayer = v.previewLayer else {
            // Unreachable: `layerClass` guarantees the layer's type. Degrade to a blank preview
            // rather than trapping if UIKit ever hands back a different layer.
            assertionFailure("PreviewView.layerClass guarantees an AVCaptureVideoPreviewLayer")
            return v
        }
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        v.configureRotation()
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.updateRotation()
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: ()) {
        uiView.tearDown()
    }

    /// The backing `UIView` whose layer is an `AVCaptureVideoPreviewLayer`.
    ///
    /// Holds the rotation coordinator + KVO observation that keep the preview's rotation angle
    /// in sync with the device; `tearDown()` drops both and detaches the session.
    final class PreviewView: UIView {
        private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var rotationObservation: NSKeyValueObservation?

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        /// The backing preview layer. Optional by construction (R5: no silent trap) — the
        /// `layerClass` override makes nil unreachable, and every caller degrades to "no preview"
        /// instead of crashing if it ever happened.
        var previewLayer: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }

        func configureRotation() {
            guard let previewLayer else { return }
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            rotationCoordinator = coordinator
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] _, _ in
                self?.updateRotation()
            }
        }

        func tearDown() {
            rotationObservation = nil
            rotationCoordinator = nil
            previewLayer?.session = nil
        }

        func updateRotation() {
            guard let previewLayer else { return }
            guard let connection = previewLayer.connection,
                  let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelPreview,
                  connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }
    }
}

// MARK: - Camera capture controller

/// Manages the disposable camera's `AVCaptureSession` lifecycle and the arm/wind gate state machine.
///
/// Owned as `@State` by ``DisposableCameraView``. The AVFoundation side (authorization, session
/// configuration, rotation, capture) runs on a private serial `sessionQueue` and publishes its
/// observable state back to the main thread; the arm/wind/disarm state machine (`isArmed`,
/// `windProgress`) is independent of AVFoundation and fully testable. Capture is single-flight:
/// the pending continuation lives in an `OSAllocatedUnfairLock` slot that is reserved before
/// capture and consumed exactly once on the AVFoundation delegate queue, so the two isolation
/// domains never race (the previous `nonisolated(unsafe) var` was a real data race). Failures
/// surface as ``CaptureError`` or the delegate's decode errors.
@Observable
final class CameraCaptureController: NSObject {
    /// Failures ``capturePhoto()`` can throw before AVFoundation is even asked.
    ///
    /// `captureInProgress` wins over `cameraUnavailable` when both apply: the single-flight slot
    /// is reserved first, preserving the original error precedence.
    enum CaptureError: LocalizedError, Equatable {
        case cameraUnavailable
        case captureInProgress

        var errorDescription: String? {
            switch self {
            case .cameraUnavailable:
                return String(localized: "camera.error.cameraUnavailable",
                              defaultValue: "Camera access is unavailable.",
                              comment: "Shown by the disposable camera when the capture session is not configured or camera access was denied.")
            case .captureInProgress:
                return String(localized: "camera.error.captureInProgress",
                              defaultValue: "A photo is already being captured.",
                              comment: "Shown when the shutter is pressed while the previous shot is still being taken. Capture is single-flight.")
            }
        }
    }

    private(set) var isArmed: Bool = true
    private(set) var windProgress: Double = 0  // 0.0 (unwound) → 1.0 (ready to arm)
    private(set) var isSessionConfigured = false
    private(set) var cameraAuthorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    var canCapturePhoto: Bool {
        isSessionConfigured && cameraAuthorizationStatus == .authorized
    }

    var needsCameraPermissionPrompt: Bool {
        cameraAuthorizationStatus == .denied || cameraAuthorizationStatus == .restricted
    }

    /// The live capture session ``CameraPreviewView`` attaches to; configured lazily on `sessionQueue`.
    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private var captureRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var captureRotationObservation: NSKeyValueObservation?
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "com.fernlet.disposable-camera.session")
    @ObservationIgnored private var shouldRunSession = false
    @ObservationIgnored private var sessionConfiguredOnQueue = false
    // Reserved on the main actor before capture; consumed once on the AVFoundation delegate
    // queue. The lock owns the slot so both isolation domains touch it safely (the previous
    // `nonisolated(unsafe) var` was a real data race). Single-flight is enforced by the reserve.
    @ObservationIgnored private let captureCompletion = OSAllocatedUnfairLock<CheckedContinuation<Data, Error>?>(initialState: nil)

    override init() {
        super.init()
    }

    // MARK: Session lifecycle

    private func configureSessionIfNeeded() -> Bool {
        guard !sessionConfiguredOnQueue else { return true }
        session.beginConfiguration()
        session.sessionPreset = .photo
        defer { session.commitConfiguration() }

        // Each failure step is named: "Camera off" with no record of WHY is unfixable in the field.
        let log = Logger(subsystem: "com.fernlet", category: "camera")
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            log.error("session configure failed: no back wide-angle camera")
            publishSessionConfigured(false)
            return false
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            log.error("session configure failed: device input: \(error.localizedDescription, privacy: .public)")
            publishSessionConfigured(false)
            return false
        }
        guard session.canAddInput(input) else {
            log.error("session configure failed: cannot add camera input")
            publishSessionConfigured(false)
            return false
        }
        guard session.canAddOutput(photoOutput) else {
            log.error("session configure failed: cannot add photo output")
            publishSessionConfigured(false)
            return false
        }

        session.addInput(input)
        session.addOutput(photoOutput)
        sessionConfiguredOnQueue = true
        publishSessionConfigured(true)

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        captureRotationCoordinator = coordinator
        captureRotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] _, _ in
            self?.updateCaptureRotation()
        }
        return true
    }

    private func publishSessionConfigured(_ configured: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isSessionConfigured = configured
        }
    }

    private func publishAuthorizationStatus(_ status: AVAuthorizationStatus) {
        DispatchQueue.main.async { [weak self] in
            self?.cameraAuthorizationStatus = status
        }
    }

    private func updateCaptureRotation() {
        guard let connection = photoOutput.connection(with: .video),
              let angle = captureRotationCoordinator?.videoRotationAngleForHorizonLevelCapture,
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    /// Starts (or resumes) the capture session, requesting camera authorization first if it has
    /// never been asked. All AVFoundation work hops to the private `sessionQueue`; the resulting
    /// authorization/configured flags are published back to the main thread.
    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            shouldRunSession = true

            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                publishAuthorizationStatus(.authorized)
                startConfiguredSessionIfNeeded()
            case .notDetermined:
                Task { [weak self] in
                    guard let self else { return }
                    let granted = await AVCaptureDevice.requestAccess(for: .video)
                    sessionQueue.async { [weak self] in
                        guard let self else { return }
                        let status = AVCaptureDevice.authorizationStatus(for: .video)
                        publishAuthorizationStatus(status)
                        guard granted, status == .authorized else {
                            publishSessionConfigured(false)
                            return
                        }
                        startConfiguredSessionIfNeeded()
                    }
                }
            case .denied, .restricted:
                publishAuthorizationStatus(AVCaptureDevice.authorizationStatus(for: .video))
                publishSessionConfigured(false)
            @unknown default:
                publishAuthorizationStatus(AVCaptureDevice.authorizationStatus(for: .video))
                publishSessionConfigured(false)
            }
        }
    }

    private func startConfiguredSessionIfNeeded() {
        guard shouldRunSession, !session.isRunning, configureSessionIfNeeded() else { return }
        session.startRunning()
    }

    /// Stops the running capture session on the session queue and clears the run intent, so a
    /// stale async start can't restart it after the view has gone away.
    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            shouldRunSession = false
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    // MARK: Wind / arm state machine

    /// Advance wind from a drag gesture. `progress` is in [0, 1].
    /// Clicks one detent (`windDetent`) per twelfth of the wheel; arms with a full rigid snap
    /// (`wound`) at 1.0.
    func advanceWind(progress: Double) {
        guard !isArmed else { return }
        let clamped = max(0, min(progress, 1.0))
        let oldTick = Int(windProgress * 12)
        let newTick = Int(clamped * 12)
        windProgress = clamped
        if newTick > oldTick {
            FernletFeedback.system.play(.windDetent)
        }
        if clamped >= 1.0 {
            isArmed = true
            windProgress = 0
            FernletFeedback.system.play(.wound)
        }
    }

    func advanceWind(by progressDelta: Double) {
        guard progressDelta > 0 else { return }
        advanceWind(progress: windProgress + progressDelta)
    }

    /// Snaps an unfinished wind back to zero when the drag ends; a no-op once armed.
    func resetWind() {
        if !isArmed { windProgress = 0 }
    }

    /// Returns to the unarmed state after a shot so the viewfinder retracts and the next photo
    /// requires a fresh wind.
    func disarm() {
        isArmed = false
        windProgress = 0
    }

    // MARK: Capture

    /// Captures one photo and returns its encoded file data.
    ///
    /// Single-flight: the continuation is reserved in the locked slot before AVFoundation is
    /// asked, so a second call while one is pending throws ``CaptureError/captureInProgress``
    /// (which deliberately outranks ``CaptureError/cameraUnavailable``). The reservation is
    /// consumed exactly once by the capture delegate.
    /// - Returns: The photo's `fileDataRepresentation()` bytes.
    func capturePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { [weak self] cont in
            guard let self else {
                cont.resume(throwing: CocoaError(.fileNoSuchFile))
                return
            }
            // Reserve the single-flight slot first (preserves the original error precedence:
            // in-progress beats unavailable).
            let reserved = captureCompletion.withLock { stored -> Bool in
                guard stored == nil else { return false }
                stored = cont
                return true
            }
            guard reserved else {
                cont.resume(throwing: CaptureError.captureInProgress)
                return
            }
            guard canCapturePhoto, photoOutput.connection(with: .video) != nil else {
                captureCompletion.withLock { $0 = nil }
                cont.resume(throwing: CaptureError.cameraUnavailable)
                return
            }

            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

extension CameraCaptureController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let cont = captureCompletion.withLock { stored -> CheckedContinuation<Data, Error>? in
            let pending = stored
            stored = nil
            return pending
        }
        if let error {
            cont?.resume(throwing: error)
        } else if let data = photo.fileDataRepresentation() {
            cont?.resume(returning: data)
        } else {
            cont?.resume(throwing: CocoaError(.fileReadCorruptFile))
        }
    }
}

// MARK: - Island viewfinder geometry

/// Pure, testable geometry for the wind-driven viewfinder that grows out of the Dynamic Island.
///
/// iOS exposes no public API for the island's rectangle (only ActivityKit can render into it), so we
/// *approximate* its band from the top safe-area inset and classify the device into island / notch /
/// flat buckets. The heuristic supplies only the closed "island" shape; every vertical position is
/// derived from `topInset` at runtime, so an unknown future device degrades gracefully to the notch/
/// flat case rather than mispositioning. Coordinates are measured from the true top of the screen.
struct IslandViewfinderMetrics: Equatable {
    /// The hardware bucket the top-inset heuristic sorted this screen into.
    ///
    /// Selected once in `init` via ``IslandViewfinderMetrics/classify(topInset:)``; every closed-anchor
    /// size, radius, and center below switches on it so island phones merge the housing with the
    /// island pill while notch/flat devices get the detached floating card.
    enum DeviceClass: Equatable { case island, notch, flat }

    let topInset: CGFloat
    let screenWidth: CGFloat
    let deviceClass: DeviceClass

    init(topInset: CGFloat, screenWidth: CGFloat) {
        self.topInset = topInset
        self.screenWidth = screenWidth
        self.deviceClass = Self.classify(topInset: topInset)
    }

    /// Dynamic Island devices report ~59pt of top inset; notched devices ~44–50pt; home-button
    /// phones and iPad ~20pt.
    static func classify(topInset: CGFloat) -> DeviceClass {
        if topInset >= 55 { return .island }
        if topInset >= 30 { return .notch }
        return .flat
    }

    /// Closed anchor — reads as (or tucks under) the island itself.
    var closedSize: CGSize {
        switch deviceClass {
        case .island: return CGSize(width: 126, height: 37)
        case .notch:  return CGSize(width: 96, height: 28)
        case .flat:   return CGSize(width: 72, height: 10)
        }
    }
    var closedCornerRadius: CGFloat {
        switch deviceClass {
        case .island: return 18.5
        case .notch:  return 13
        case .flat:   return 5
        }
    }
    var closedCenterY: CGFloat {
        switch deviceClass {
        case .island: return topInset * 0.5          // ~30pt: the island's own center
        case .notch:  return max(topInset - 12, 6)   // tucked just under the notch
        case .flat:   return topInset + 3            // just below the top edge
        }
    }

    /// Open, resting viewfinder — a chunky rounded square in the upper third.
    var openSize: CGSize {
        let side = min(max(screenWidth * 0.64, 180), 300)
        return CGSize(width: side, height: side)
    }
    var openCornerRadius: CGFloat { 30 }
    private var topGap: CGFloat { deviceClass == .flat ? 12 : 18 }
    /// Margin from the true screen top to the open housing's top edge on island devices — the
    /// housing wraps the island band rather than floating below it.
    private var openTopMargin: CGFloat { 3 }
    /// Where the open housing rests.
    /// - Dynamic Island: the housing top sits at the screen's top edge so the island pill rides
    ///   inside its top band — one continuous camera-hardware shape (no detached "second island").
    /// - Notch / flat: the detached floating card below the top inset — the intended look for
    ///   devices that have no island to merge with.
    var openCenterY: CGFloat {
        switch deviceClass {
        case .island: return openTopMargin + openSize.height / 2
        case .notch, .flat: return topInset + topGap + openSize.height / 2
        }
    }

    var centerX: CGFloat { screenWidth / 2 }

    /// One interpolated housing (or glass) rectangle: its size, corner radius, and vertical center.
    ///
    /// Produced by ``IslandViewfinderMetrics/frame(openness:)`` and
    /// ``IslandViewfinderMetrics/glassFrame(openness:)``; the view converts it into an absolute
    /// `CGRect` in the full-screen overlay's coordinate space.
    struct Frame: Equatable {
        var size: CGSize
        var cornerRadius: CGFloat
        var centerY: CGFloat
    }

    /// Interpolate the housing between the closed island anchor (`openness` 0) and the open
    /// viewfinder (`openness` 1). `openness` is clamped to [0, 1].
    func frame(openness: Double) -> Frame {
        let t = CGFloat(min(max(openness, 0), 1))
        return Frame(
            size: CGSize(
                width: lerp(closedSize.width, openSize.width, t),
                height: lerp(closedSize.height, openSize.height, t)
            ),
            cornerRadius: lerp(closedCornerRadius, openCornerRadius, t),
            centerY: lerp(closedCenterY, openCenterY, t)
        )
    }

    // MARK: - Preview glass (inset inside the housing shell)

    /// Fraction of the near-black shell that walls the live-preview glass. Grows with openness so
    /// the inset never swallows the housing while it's still island-sized.
    private func shellInset(openness: Double) -> CGFloat { 13 * clamp(openness) + 2 }

    /// Vertical gap from the housing's top edge down to the preview glass. On island devices the
    /// open gap clears the whole island band with a margin beneath it (the housing top is at the
    /// screen top); elsewhere it is the shell's decorative top gap, which the status LED rides in.
    private func ledGap(openness: Double) -> CGFloat {
        let openMax: CGFloat = deviceClass == .island ? topInset + 22 : 34
        return lerp(4, openMax, clamp(openness))
    }

    /// The live-preview window, inset inside the housing shell and pushed below the island band
    /// (island devices) or the status LED (notch / flat).
    /// A single, structurally-stable `CameraPreviewView` is positioned at this frame so the live
    /// `AVCaptureSession` attachment survives rotation instead of being torn down and rebuilt.
    func glassFrame(openness: Double) -> Frame {
        let housing = frame(openness: openness)
        let inset = shellInset(openness: openness)
        let gap = ledGap(openness: openness)
        let housingTop = housing.centerY - housing.size.height / 2
        let w = max(0, housing.size.width - inset * 2)
        let h = max(0, housing.size.height - gap - inset)
        return Frame(
            size: CGSize(width: w, height: h),
            cornerRadius: max(3, housing.cornerRadius - inset),
            centerY: housingTop + gap + h / 2
        )
    }

    /// Opacity of the live preview — hidden while the housing is still island-sized, fading in as
    /// the housing opens so the squished preview never shows.
    func previewOpacity(openness: Double) -> Double {
        max(0, min((openness - 0.3) / 0.6, 1))
    }

    /// Whether the decorative green "camera on" LED is drawn at all.
    ///
    /// Not on a Dynamic Island phone (2026-09-22): iOS already lights its own green camera-in-use
    /// dot inside the island the moment the capture session runs, and the housing's LED sat
    /// directly beneath it — two green dots stacked one under the other, the second one fake.
    /// A notch or flat phone keeps it: there the LED is the in-scene "camera on" cue the housing
    /// was designed around, and nothing else occupies that spot.
    var showsStatusLED: Bool { deviceClass != .island }

    /// Center Y of the status LED, or nil where ``showsStatusLED`` is false — so the position and
    /// the decision to draw it are one answer and cannot drift apart. Starts in the closed anchor
    /// and settles near the shell's top gap as the housing opens.
    func ledCenterY(openness: Double) -> CGFloat? {
        guard showsStatusLED else { return nil }
        let housingTopOpen = openCenterY - openSize.height / 2
        let openY = housingTopOpen + ledGap(openness: 1) * 0.4 + 6
        return lerp(closedCenterY, openY, clamp(openness))
    }

    private func clamp(_ v: Double) -> CGFloat { CGFloat(min(max(v, 0), 1)) }
    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
}

// MARK: - Orientation resolution

/// Pure, testable hysteresis for the camera's layout orientation.
///
/// A rotation animation drives the view's frame through a near-square shape; a raw
/// `width > height` test would flip the layout twice per rotation, thrashing it. The [0.95, 1.05]
/// aspect-ratio dead-band holds the current orientation until the frame is clearly one way or the
/// other. Kept as a free value type (not on the `View`, which the Swift 6 SDK isolates to the main
/// actor) so it stays nonisolated and unit-testable.
enum DisposableCameraOrientation {
    static func resolveLandscape(current: Bool, size: CGSize) -> Bool {
        let ratio = size.width / max(size.height, 1)
        return current ? ratio > 0.95 : ratio > 1.05
    }
}

// MARK: - Disposable camera view

/// The "disposable camera" (`b3-camera-session` draft 2): a full-screen focused flow over a dark
/// scene — the session's name top left and the framed ✕ top right, the framed viewfinder window with
/// cream corner marks and a green light, then Develop & finish, the shutter, and the gold film badge
/// with the wind control.
///
/// **Where it opens (World build, owner 2026-10-24).** The Friends album never swaps for it any more:
/// the Friends panel's session row has a Camera button, and Home's blue button offers it in a session
/// (lane HOME presents it with this same initialiser). It closes with its ✕ (`onClose`, or the
/// environment's dismiss for a full-screen cover), and closes itself when the session it shoots for
/// ends. Session info, Messages and Leave moved to Home's session button, so the camera has no info
/// or messages buttons; the session's prompts still ride it (``SessionPromptsModifier``) while it is
/// the surface on screen.
///
/// **On your own** (no session; `b3-camera-solo` draft 2, owner 2026-10-24) it is the same camera
/// without Develop & finish, titled "Just you" (or "Just you · <place>" when the presenter names one):
/// ten photos a local day ("7 of 10 / left today"), each sealed the moment it is taken into the
/// Friends area's device-only solo corpus (``SoloCameraRoll`` over `SoloCameraPhotoStore`) and held
/// until the companion goes to sleep, which the line at the bottom says. No review, no Develop. At 0
/// the shutter reads "No film left"; a decoy session's shots live in memory only.
///
/// Owns a ``CameraCaptureController`` as `@State` and renders the wind-to-arm control, the shutter
/// with a shared per-session film counter (`MeshSessionPhotos.filmRemaining`), and the develop flow:
/// "Develop" stops the capture session and either leaves immediately (no photos — the keep-as-friend
/// prompt is then FriendsView's job via the pending review batch) or presents
/// `FriendPhotoReviewSheet` with friend candidates computed at presentation time against the live
/// trust vault — over the photo ids snapshotted at Develop, rendered and answered wherever the session
/// photos hold them, so an ending that moves the roll under the open review (door 3's give-up) cannot
/// empty it. It reports whether any sheet or alert of its own is up (`presentsOwnSheet`), so
/// FriendsView never requests its keep-as-friends prompt over one, and — session photos U3 — whether
/// its Develop review is up (``SessionPhotoReviewCoordinator/cameraDevelopReviewUp``, cleared three
/// ways so it cannot latch), so the app-wide session-end review never draws over it; its answer raises
/// the coordinator's answer-in-flight leg around the finish-and-leave, and its capture session stops
/// while that overlay is up (a hidden live camera is a privacy defect). Orientation flips through
/// ``DisposableCameraOrientation``'s hysteresis so mid-rotation near-square frames never thrash the
/// layout.
struct DisposableCameraView: View {
    var store: FernletStore
    /// Reported up to ``FriendsView``: whether this view has a sheet or alert of its own up right
    /// now (see ``ownPresentationIsUp``). The Friends surface must not request its session-end
    /// review over one — the request would queue behind this view's sheet with a snapshot taken
    /// before the person answered the Develop review here — and re-checks the moment this goes
    /// false (2026-09-30 fix round, findings C-F1/C-F2). Defaults to a constant for a caller that
    /// does not need to know.
    var presentsOwnSheet: Binding<Bool> = .constant(false)
    /// Closes the camera; nil uses the environment's dismiss (a full-screen cover's presenter).
    var onClose: (() -> Void)? = nil
    /// On your own, the place the camera opened at ("Just you · Oak Park"): Home's blue button knows
    /// the hike, the run, the workout space or the restaurant. Nil shows "Just you". Shown only; never
    /// stored with a photo.
    var placeName: String? = nil

    @State private var camera = CameraCaptureController()
    @State private var flashOpacity: Double = 0
    @State private var reviewPresented = false
    /// The photo ids the open Develop review offers, snapshotted at ``beginDevelop()``. The review
    /// renders and answers these ids wherever the manager holds them now (2026-09-30 fix round,
    /// findings C-F1/L-F1): door 3's give-up ends the session under an open review with the mesh
    /// still held, so this view stays up while the ending moves the live list into the pending batch.
    @State private var developReviewIDs: Set<UUID> = []
    @State private var selectedForSave: Set<UUID> = []
    // Phase 2 friend minting: candidates snapshotted when the review presents + the user's keeps.
    @State private var friendCandidates: [MeshSessionRosterEntry] = []
    @State private var keptFriendFingerprints: Set<String> = []
    @State private var photoSaveError: PhotoSaveFailure? = nil
    /// The Develop review's opt-in camera-roll toggle, off each time the review presents.
    @State private var alsoSaveToPhotos = false
    /// Why the Develop review's last answer did not apply in full; the sheet stays up and says so.
    @State private var reviewAnswerFailure: SessionPhotoAnswerFailure?
    /// Kept photos the last answer removed because their held bytes could not be opened.
    @State private var reviewUnreadableCount = 0
    /// What the Develop review is busy with after the answer (the Photos export).
    @State private var reviewWorking: FriendPhotoReviewWorkingMessage?
    @State private var activeRemovalProposal: MeshRemovalProposalPayload?
    @State private var previousWindTranslation: CGFloat = 0
    // Orientation is @State (not a raw per-frame `size.width > size.height`) so a transient
    // near-square frame mid-rotation can't flip the layout twice — see `Self.resolveLandscape`.
    @State private var isLandscape = false
    @State private var leaveSessionConfirm = false
    /// The sender of a Develop review photo the people-report flow is open for (App Review guideline
    /// 1.2, 2026-10-15).
    @State private var photoReportSubject: PeerReportSubject?
    /// Whether this camera opened over a session: it closes itself when that session ends.
    @State private var opensInSession = false
    /// The roll a shot alone goes into (``SoloCameraRoll``), taken from the store when the camera
    /// opens with no session; nil in a session.
    @State private var soloRoll: SoloCameraRoll?
    /// A shot alone that could not be kept: its alert is up.
    @State private var soloShotFailed = false
    /// F10: this file is the repo's own cited exemplar for the `TimelineView(.animation(paused:))`
    /// idiom — it should exemplify Reduce Motion too, not just the isArmed gating it already had.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    // The camera surface is a standalone "hardware" scene rather than a parchment page, so its
    // colours are its own and the same in light and dark: the near-black housing (#050403), the
    // scene behind it (#201C17), the frame's brown (#4A2E1C), the cream of the marks and words
    // (#FFF1CF, 15:1 on the scene), the hardware-LED green (#5EE06A) and the film badge's gold.
    private static let housingBlack = Color(red: 0.020, green: 0.016, blue: 0.012)
    private static let sceneDark = WorldPalette.rgb(0x201C17)
    private static let frameBrown = WorldPalette.rgb(0x4A2E1C)
    private static let cream = WorldPalette.gameCream
    private static let ledGreen = Color(red: 0.369, green: 0.878, blue: 0.416)
    private static let filmGold = WorldPalette.rgb(0xF2D58A)
    // Warm shutter-button cream (#FBF7EE), the film-camera release color from the mockup.
    private static let shutterCream = Color(red: 0.984, green: 0.969, blue: 0.933)

    private var manager: MeshNetworkManager { store.meshNetworkManager }
    /// Fernlet's mesh features over ``manager``: the session photos (the film, the live roll, the
    /// capture and the Develop review's answers) live there.
    private var features: FernletMeshFeatures { store.meshFeatures }
    /// The app-level session-end review (session photos U3): told when the Develop review is up, and
    /// around this view's answer.
    private var reviewCoordinator: SessionPhotoReviewCoordinator { store.sessionPhotoReviewCoordinator }
    /// Where the Develop answer waits for a failed Photos export's alert to be closed before it ends
    /// the session and closes the review (fix round 1, U2-C-U2-R2 / U2-L-U2-R2) — held by the
    /// store-owned coordinator and open only while ``reviewPresented`` feeds its Develop flag, NOT in
    /// this view's `@State` (fix round 1 of U3, U3-C-U3-R1): a termination tears this view down
    /// under a running answer, and a failure after that (or after a swipe-down) must not be waited
    /// on forever — that wait never lowered the answer leg, which kept discovery blocked and every
    /// later session-end review undismissable.
    private var saveFailureAcknowledgement: PhotoSaveFailureAcknowledgement {
        reviewCoordinator.developSaveFailureAcknowledgement
    }
    private let portraitWindThreshold: Double = 120
    private let landscapeWindThreshold: Double = 720

    var body: some View {
        GeometryReader { geometry in
            cameraSurface(geometry: geometry)
        }
        .onAppear(perform: handleAppear)
        .onDisappear {
            camera.stopSession()
            // Leaving the hierarchy takes every sheet of this view with it — the Develop review
            // included, so its flag is cleared here too (I20: it cannot outlive the camera).
            presentsOwnSheet.wrappedValue = false
            reviewCoordinator.cameraDevelopReviewUp = false
        }
        .onChange(of: ownPresentationIsUp, initial: true) { _, isUp in
            presentsOwnSheet.wrappedValue = isUp
        }
        .onChange(of: reviewPresented, initial: true) { _, up in reviewCoordinator.cameraDevelopReviewUp = up }
        // The session-end overlay over this surface (door 3's held mesh, before its leave lands):
        // no live capture under it, and no restart after it unless the session is live again.
        .onChange(of: reviewCoordinator.isShowing) { _, showing in handleOverlayChange(showing: showing) }
        // The session this camera shot for is over (End session anywhere, or the last peer gone for
        // good): there is nothing left to shoot for, as when the old album swap took it away.
        .onChange(of: manager.isInSession) { _, inSession in if opensInSession && !inSession { close() } }
        .onChange(of: manager.pendingRemovalProposals) { _, _ in
            presentNextRemovalProposalIfNeeded()
        }
        .onChange(of: store.duressSessionActive) { _, decoy in soloRoll?.setDecoy(decoy) }
        .sheet(isPresented: $reviewPresented, onDismiss: resumeCameraAfterCancelledReview) { reviewSheet }
        .alert("Couldn't keep that photo. Try again.", isPresented: $soloShotFailed) {
            Button("OK", role: .cancel) {}
        }
        // The session's prompts only in a session: alone, a stale mesh notice is not this camera's.
        .modifier(SessionPromptsModifier(
            manager: manager,
            isActive: manager.isInSession,
            activeRemovalProposal: $activeRemovalProposal,
            leaveSessionConfirm: $leaveSessionConfirm,
            onConfirmEnd: beginDevelop
        ))
        .accessibilityAction(.escape) { close() }
    }

    /// Leaves the camera: the presenter's close, or the cover's dismiss.
    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    /// Opening: notes whether this camera shoots for a session, takes the solo roll when it does
    /// not, and starts the capture session unless the session-end review is up.
    private func handleAppear() {
        opensInSession = manager.isInSession
        if !opensInSession {
            let roll = store.soloCameraRoll()
            roll.refresh()
            soloRoll = roll
        }
        if !reviewCoordinator.isShowing { camera.startSession() }
    }

    /// Whether any sheet or alert this view hangs is up: its Develop review, the end-session and
    /// removal-seconding alerts, and the manager-driven admission sheet and session alert — the
    /// same conditions their presenters read. What ``presentsOwnSheet`` reports.
    private var ownPresentationIsUp: Bool {
        reviewPresented || leaveSessionConfirm || activeRemovalProposal != nil || soloShotFailed
            || (!manager.pendingAdmissionRequests.isEmpty && manager.currentMesh != nil)
            || manager.meshError != nil || manager.routedShareRefusal != nil
    }

    /// Whether a shot can be kept here: in a session the session's photos hold it; on your own the
    /// solo roll does, once its sealed corpus can be read (until then the camera alone says "Camera
    /// off").
    private var canShootHere: Bool {
        manager.isInSession || soloRoll?.shotsLeft(at: Date()) != nil
    }

    /// Whether this camera is shooting on your own (no session): the solo film, no Develop.
    private var isSolo: Bool { !manager.isInSession }

    /// Film left for the shutter: the session's shared film, or today's solo film (none while the
    /// solo corpus cannot be read).
    private var filmRemaining: Int {
        guard isSolo else { return features.photos.filmRemaining }
        return soloRoll?.shotsLeft(at: Date()) ?? 0
    }

    /// The Develop review's photos: the snapshotted ids still awaiting an answer, wherever the
    /// session photos hold them (`MeshSessionPhotos.photosAwaitingAnswer(among:)`).
    private var developReviewPhotos: [FriendPhotoPayload] {
        features.photos.photosAwaitingAnswer(among: developReviewIDs)
    }

    /// The full-screen camera scene for the current geometry.
    ///
    /// The scene lives in a full-screen (safe-area-ignoring) layer so one preview node can span both
    /// orientations. A single `CameraPreviewView` inside `cameraStage` keeps stable structural
    /// identity across rotation, so the live `AVCaptureSession` is never detached/reattached (the
    /// old freeze/black flash).
    ///
    /// Modifier order is load-bearing: `ignoresSafeArea()` must wrap the `overlay`, not the color
    /// alone. `ignoresSafeArea()` extends only the view it modifies, so an overlay attached *after*
    /// it is laid out in the un-extended safe-area frame and every `.position` inside the stage
    /// measures from the safe-area top. With the overlay inside, the stage's bounds are the whole
    /// screen and its positions mean what they say.
    private func cameraSurface(geometry: GeometryProxy) -> some View {
        ZStack {
            Self.sceneDark
                .overlay { cameraStage(geometry: geometry) }
                .ignoresSafeArea()

            // Corner + edge chrome lives in the safe-area coordinate space so buttons never tuck
            // under the island or the home indicator.
            topControls

            if isLandscape {
                landscapeControls
            } else {
                portraitControls
            }

            // Shutter flash — brief white wash over the whole surface on capture.
            Color.white
                .opacity(flashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .onAppear { updateOrientation(for: geometry.size) }
        .onChange(of: geometry.size) { _, newSize in
            updateOrientation(for: newSize)
        }
    }

    /// The top row: the session's name and who is in it, top left, and the framed ✕ top right (the
    /// button rule: ✕ always top right).
    private var topControls: some View {
        HStack(alignment: .center, spacing: 12) {
            titleText
                .font(FernletFramedFont.button)
                .foregroundStyle(Self.cream)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            FernletCloseButton(action: close)
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// "Picnic · with Sam and Rae" in a session; "Just you" (or "Just you · Oak Park") on your own.
    private var titleText: Text {
        guard manager.isInSession else {
            guard let placeName, !placeName.isEmpty else { return Text("Just you") }
            return Text("Just you · \(placeName)")
        }
        let names = manager.sessionParticipants.filter { !$0.isLocal }.map {
            PeerNameDisplay.firstName($0.displayName, fingerprint: $0.fingerprint, placeholder: .met, in: .fernlet)
        }
        let meshName = manager.currentMesh?.name ?? ""
        guard !names.isEmpty else { return meshName.isEmpty ? Text("Session") : Text(verbatim: meshName) }
        let together = FriendsSessionNames.sentence(names)
        guard !meshName.isEmpty else { return Text("With \(together)") }
        return Text("\(meshName) · with \(together)")
    }

    private var portraitControls: some View {
        VStack(spacing: 18) {
            HStack(alignment: .bottom) {
                Group {
                    if manager.isInSession { developButton } else { Color.clear.frame(height: 1) }
                }
                .frame(width: 112)
                Spacer(minLength: 0)
                shutterButton
                Spacer(minLength: 0)
                filmColumn(isLandscape: false)
                    .frame(width: 112)
            }
            if isSolo { soloFooter }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 12)
        .padding(.bottom, isSolo ? 12 : 24)
    }

    /// The room the solo line takes under the controls, kept clear of the viewfinder.
    private static let soloFooterReserve: CGFloat = 44

    /// On your own, when the photos show (`b3-camera-solo`): after the companion goes to sleep, tonight,
    /// or tomorrow night once it is already asleep (form answer 44). Read again each minute, so the line
    /// turns as bedtime passes with the camera open.
    private var soloFooter: some View {
        TimelineView(.everyMinute) { context in
            soloFooterLine(at: context.date)
        }
    }

    /// The solo line at `date`.
    private func soloFooterLine(at date: Date) -> some View {
        let tomorrow = SoloCameraRules.waitsForTomorrowNight(at: date, calendar: .current)
        let line = tomorrow
            ? Text("Your photos appear tomorrow night, after \(companionName) goes to sleep.")
            : Text("Your photos appear tonight, after \(companionName) goes to sleep.")
        return line
            .font(FernletFramedFont.note)
            .foregroundStyle(Self.cream.opacity(0.88))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 460)
            .padding(.horizontal, 12)
            .accessibilityIdentifier("camera.soloFooter")
    }

    /// The companion's name (``FernletStore/worldCompanionName``), as the Today card says it.
    private var companionName: String {
        store.worldCompanionName
    }

    private var landscapeControls: some View {
        // The film + wind cluster rides a leading rail, vertically centred; the shutter the trailing
        // rail; Develop the bottom-leading corner. The top corners belong to the title and the ✕.
        ZStack {
            filmColumn(isLandscape: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, 20)

            shutterButton
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 22)

            if manager.isInSession {
                developButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(22)
            } else {
                // Alone, the line sits under the viewfinder, in the room its frame leaves for it.
                soloFooter
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 6)
            }
        }
    }

    /// The gold film badge over the wind control and its caption ("Ready" once wound). Alone, "left
    /// today" sits under the badge (`b3-camera-solo`).
    private func filmColumn(isLandscape: Bool) -> some View {
        VStack(spacing: 8) {
            filmCounterBadge
            if isSolo {
                // The badge's label already says it for VoiceOver.
                Text("left today")
                    .font(FernletFramedFont.buttonSmall)
                    .foregroundStyle(Self.ledGreen)
                    .accessibilityHidden(true)
            }
            windIndicator(isLandscape: isLandscape)
        }
    }

    private var filmCounterBadge: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return HStack(spacing: 6) {
            WorldSpriteView(sprite: FriendsSprites.film, scale: 2, tint: Self.frameBrown)
            filmCountText
                .font(FernletFramedFont.button)
                .monospacedDigit()
                .foregroundStyle(Self.frameBrown)
            // The always-visible half of the kept-photo notice: a glyph, with the sentence itself
            // in the badge's accessibility label. A session's notice only.
            if !isSolo && features.photos.photosKeptOnThisPhone > 0 {
                Image(systemName: "iphone")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Self.frameBrown)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(filmRemaining > 0 ? Self.filmGold : Self.filmGold.opacity(0.55), in: shape)
        .overlay(shape.strokeBorder(Self.frameBrown, lineWidth: 2))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(filmCounterAccessibilityLabel)
        .accessibilityIdentifier("camera.filmCounter")
    }

    /// The badge's count: the session's shots left, or "7 of 10" of today's film alone.
    private var filmCountText: Text {
        guard isSolo else { return Text("\(features.photos.filmRemaining)") }
        return Text("\(filmRemaining) of \(SoloCameraRules.photosPerDay)")
    }

    /// The badge's label, with the kept-photo sentence appended when there is one — `Text`
    /// interpolating `Text`, so both halves are harvested (review T2-1). Alone, today's film.
    private var filmCounterAccessibilityLabel: Text {
        if isSolo { return Text("\(filmRemaining) of \(SoloCameraRules.photosPerDay) photos left today") }
        guard let kept = RoutedShareRefusalCopy.photoKeptNotice(count: features.photos.photosKeptOnThisPhone) else {
            return Text("Film remaining: \(features.photos.filmRemaining)")
        }
        return Text("Film remaining: \(features.photos.filmRemaining). \(Text(kept))")
    }

    // MARK: - Viewfinder

    /// Where the framed viewfinder window sits (`b3-camera-session` draft 2), in the full-screen
    /// layer's coordinates (origin = the true top-left): under the title row in portrait, 24 pt in from
    /// each side, about 4:5 and never into the controls; centred and 4:3 in landscape, clear of the
    /// side rails. A pure function of the size and insets, so one preview node is repositioned across
    /// rotation rather than recreated (the old freeze / black flash).
    ///
    /// - Parameters:
    ///   - size: The safe-area size the camera lays out in.
    ///   - safeArea: The safe-area insets.
    ///   - landscape: Whether the camera is in its landscape layout.
    ///   - bottomReserve: Room kept clear under the window for a line of text (the solo camera's
    ///     "Your photos appear tonight…"); 0 for the session camera.
    /// - Returns: The window's rectangle.
    static func viewfinderRect(in size: CGSize, safeArea: EdgeInsets, landscape: Bool,
                               bottomReserve: CGFloat = 0) -> CGRect {
        let reserve = max(0, bottomReserve)
        guard landscape else {
            let width = max(0, size.width - 48)
            let maxHeight = max(0, size.height - 64 - 200 - reserve)
            let height = min(width * 1.21, maxHeight)
            return CGRect(x: safeArea.leading + 24, y: safeArea.top + 64, width: width, height: height)
        }
        let height = max(0, size.height - 24 - reserve)
        let width = min(height * 4 / 3, max(0, size.width - 260))
        let fitted = min(height, width * 3 / 4)
        return CGRect(x: safeArea.leading + (size.width - width) / 2,
                      y: safeArea.top + (size.height - reserve - fitted) / 2,
                      width: width, height: fitted)
    }

    /// The camera scene: the framed window with the live preview fading in as the film winds, the
    /// cream corner marks and the green light, and the permission prompt inside it when needed.
    private func cameraStage(geometry: GeometryProxy) -> some View {
        let openness = camera.isArmed ? 1.0 : camera.windProgress
        let window = Self.viewfinderRect(in: geometry.size, safeArea: geometry.safeAreaInsets, landscape: isLandscape,
                                         bottomReserve: isSolo ? Self.soloFooterReserve : 0)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let showsPermissionPrompt = camera.needsCameraPermissionPrompt && (isLandscape || openness > 0.85)
        return ZStack {
            // Decorative hardware — flattened for VoiceOver, kept out of hit testing (the wind
            // gesture lives on the wind control). The child order is fixed regardless of
            // orientation, so the `CameraPreviewView` UIView (and its live capture-session
            // attachment) survives every rotation.
            ZStack {
                shape.fill(Self.housingBlack)
                    .frame(width: window.width, height: window.height)
                    .position(x: window.midX, y: window.midY)
                CameraPreviewView(session: camera.session)
                    .frame(width: window.width, height: window.height)
                    .clipShape(shape)
                    .opacity(openness)
                    .position(x: window.midX, y: window.midY)
                viewfinderChrome
                    .frame(width: window.width, height: window.height)
                    .position(x: window.midX, y: window.midY)
            }
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(camera.isArmed ? "Viewfinder ready" : "Wind to open the viewfinder")
            .accessibilityHidden(showsPermissionPrompt)

            // The permission prompt is real UI, so it layers after the decorative flattening — its
            // Open Settings button stays tappable and VoiceOver-reachable.
            if showsPermissionPrompt {
                cameraPermissionPrompt
                    .frame(width: window.width, height: window.height)
                    .clipShape(shape)
                    .position(x: window.midX, y: window.midY)
            }
        }
        .animation(.easeOut(duration: 0.25), value: openness)
    }

    /// The window's frame: a 4-pt brown frame, cream pixel corner marks, and the green light top
    /// right, which breathes once the film is wound (still under Reduce Motion).
    private var viewfinderChrome: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Self.frameBrown, lineWidth: 5)
            cornerBrackets(color: Self.cream, length: 22, thickness: 4, margin: 24)
                .opacity(camera.isArmed ? 1 : 0.55)
            cameraLED
                .padding(14)
        }
    }

    /// The classic "camera on" green light, a framed pixel square; once armed it breathes 0.8↔1.0.
    /// The breathe is clock-driven (TimelineView) rather than a repeatForever animation: disarming
    /// after a shot retargets the light's opacity, which would kill a repeating animation for good,
    /// and the pulse must survive every disarm/re-arm cycle.
    private var cameraLED: some View {
        TimelineView(.animation(paused: !camera.isArmed || reduceMotion)) { context in
            // 0.8 ↔ 1.0 cosine breathe with a 3.8s round trip.
            let phase = context.date.timeIntervalSinceReferenceDate / 3.8 * 2 * .pi
            let breathe = camera.isArmed ? 0.9 - 0.1 * cos(phase) : 0.45
            Rectangle()
                .fill(Self.ledGreen)
                .frame(width: 12, height: 12)
                .overlay(Rectangle().strokeBorder(Self.housingBlack, lineWidth: 2))
                .opacity(breathe)
        }
    }

    private var cameraPermissionPrompt: some View {
        VStack(spacing: 14) {
            Text("Camera access is off")
                .font(FernletFramedFont.cardTitle)
                .foregroundStyle(Self.cream)
            Text("Fernlet needs the camera to take photos with friends. You can turn it on any time.")
                .font(FernletFramedFont.body)
                .foregroundStyle(Self.cream.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                openAppSettings()
            } label: {
                Text("Open Settings").frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.primary))
            .padding(.top, 6)
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.housingBlack.opacity(0.92))
        .accessibilityIdentifier("camera.permissionPrompt")
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Four corner brackets inset `margin` from each edge: the viewfinder's cream corner marks.
    private func cornerBrackets(color c: Color, length len: CGFloat, thickness t: CGFloat, margin m: CGFloat) -> some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // top-left
                rect(c, w: len, h: t).position(x: m + len / 2, y: m + t / 2)
                rect(c, w: t, h: len).position(x: m + t / 2, y: m + len / 2)
                // top-right
                rect(c, w: len, h: t).position(x: w - m - len / 2, y: m + t / 2)
                rect(c, w: t, h: len).position(x: w - m - t / 2, y: m + len / 2)
                // bottom-left
                rect(c, w: len, h: t).position(x: m + len / 2, y: h - m - t / 2)
                rect(c, w: t, h: len).position(x: m + t / 2, y: h - m - len / 2)
                // bottom-right
                rect(c, w: len, h: t).position(x: w - m - len / 2, y: h - m - t / 2)
                rect(c, w: t, h: len).position(x: w - m - t / 2, y: h - m - len / 2)
            }
        }
    }

    private func rect(_ color: Color, w: CGFloat, h: CGFloat) -> some View {
        Rectangle().fill(color).frame(width: w, height: h)
    }

    /// Develop & finish: a framed paper tile with the two-prints mark, its words under it in cream.
    private var developButton: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return Button {
            // With photos there is a review sheet to back out of. With none, "Develop" used to end
            // the live session on the spot — chat transcript gone, camera gone — off a photo verb.
            // Ask with the same "End session?" the session button asks.
            if features.photos.sessionPhotos.isEmpty {
                leaveSessionConfirm = true
            } else {
                beginDevelop()
            }
        } label: {
            VStack(spacing: 6) {
                WorldSpriteView(sprite: FriendsSprites.prints, scale: 3, tint: Self.frameBrown)
                    .frame(width: 52, height: 52)
                    .background(Self.cream, in: shape)
                    .overlay(shape.strokeBorder(Self.frameBrown, lineWidth: 2))
                // Named for what it actually does: developing the film also ends the outing.
                Text("Develop & finish")
                    .font(FernletFramedFont.buttonSmall)
                    .foregroundStyle(Self.cream)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("camera.develop")
    }

    private var shutterButton: some View {
        let canShoot = camera.isArmed && filmRemaining > 0 && camera.canCapturePhoto && canShootHere
        return Button {
            guard canShoot else { return }
            Task { await takePhoto() }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    // A cream ring and release when ready; muted when locked.
                    Circle()
                        .stroke(Self.cream.opacity(canShoot ? 1 : 0.25), lineWidth: 5)
                        .frame(width: 84, height: 84)
                    Circle()
                        .fill(canShoot ? Self.shutterCream : Self.cream.opacity(0.14))
                        .overlay(Circle().strokeBorder(Self.frameBrown, lineWidth: 3))
                        .frame(width: 66, height: 66)
                    shutterGlyph
                }
                // Captions replace cryptic glyphs: name each shutter state in words.
                Text(shutterCaption(canShoot: canShoot))
                    .font(FernletFramedFont.buttonSmall)
                    .foregroundStyle(canShoot ? Self.cream : Self.cream.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
        .disabled(!canShoot)
        .scaleEffect(canShoot ? 1.0 : 0.94)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: canShoot)
        .accessibilityLabel(shutterAccessibilityLabel(canShoot: canShoot))
        .accessibilityIdentifier("camera.shutter")
    }

    /// The glyph inside a shutter that cannot fire: a camera that cannot keep a shot here, the film
    /// to wind, the film used up, or the camera off. SF Symbols has no `camera.slash` or `film.slash`
    /// (the lookup logged "No symbol named" and drew nothing), so the off states wear `video.slash`
    /// and the spent roll a terracotta `film`; the caption underneath names each state in words.
    @ViewBuilder
    private var shutterGlyph: some View {
        if !canShootHere {
            Image(systemName: "video.slash")
                .font(.system(size: 18))
                .foregroundStyle(Self.cream.opacity(0.6))
        } else if !camera.isArmed && filmRemaining > 0 {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Self.cream.opacity(0.6))
        } else if filmRemaining == 0 {
            Image(systemName: "film")
                .font(.system(size: 18))
                .foregroundStyle(Color.terracotta)
        } else if !camera.canCapturePhoto {
            Image(systemName: "video.slash")
                .font(.system(size: 18))
                .foregroundStyle(Self.cream.opacity(0.6))
        }
    }

    /// A short caption under the shutter, so its ring state reads without decoding a glyph. A key,
    /// not a `String`: `Text(String)` is the verbatim overload, which kept all four out of the catalog.
    /// A camera that cannot keep a shot here (the solo corpus unreadable right now) says so before
    /// the film does.
    private func shutterCaption(canShoot: Bool) -> LocalizedStringKey {
        if canShoot { return "Tap to shoot" }
        if !canShootHere { return "Camera off" }
        if filmRemaining == 0 { return "No film left" }
        if !camera.canCapturePhoto { return "Camera off" }
        return "Wind to arm"
    }

    /// `Text` rather than `String` (review T2-1): a `String` reaches `.accessibilityLabel(_:)`
    /// through the verbatim overload, so none of these four states was ever harvested.
    private func shutterAccessibilityLabel(canShoot: Bool) -> Text {
        if canShoot { return Text("Take photo") }
        if !canShootHere { return Text("Camera unavailable") }
        if filmRemaining == 0 { return Text("No film remaining") }
        if !camera.canCapturePhoto { return Text("Camera unavailable") }
        return Text("Wind camera first")
    }

    private func windIndicator(isLandscape: Bool) -> some View {
        // A ridged thumbwheel with its ridges scrolling as the wheel turns and a slim progress track
        // under it; "Ready" in green once wound (b3-camera-session's caption under the film badge).
        let winding = !camera.isArmed && camera.windProgress > 0
        return VStack(spacing: 6) {
            windThumbwheel(active: winding)
            windProgressTrack(active: winding)
            Text(camera.isArmed ? "Ready" : isLandscape ? "Swipe →" : "Slide ↓")
                .font(FernletFramedFont.buttonSmall)
                .foregroundStyle(camera.isArmed ? Self.ledGreen : Self.cream.opacity(0.7))
        }
        .frame(width: 72)
        .contentShape(Rectangle())
        .gesture(windGesture(isLandscape: isLandscape))
        // Winding is the gate on the shutter, and it was drag-only: VoiceOver and Switch Control
        // users could never arm the camera, so the shutter read "Wind camera first" forever. The
        // wheel is one element with a value, a default activation (double tap), and a named
        // action — no dragging required to take a photo.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Film wind")
        .accessibilityValue(camera.isArmed ? "Ready" : "\(Int((camera.windProgress * 100).rounded()))% wound")
        .accessibilityHint(camera.isArmed ? "The camera is ready to shoot" : "Winds the camera so you can take a photo")
        .accessibilityAction { camera.advanceWind(progress: 1) }
        .accessibilityAction(named: "Wind camera") { camera.advanceWind(progress: 1) }
    }

    private func windThumbwheel(active: Bool) -> some View {
        // The ridge texture repeats every two ridges (the active tint alternates), so the stack
        // over-fills the window by one two-ridge loop and slides down through it across a full
        // wind: the wheel reads as continuously turning — no blank band opens up, and the arm-time
        // windProgress reset to 0 lands on an identical frame.
        let ridgeCount = 9
        let rowHeight: CGFloat = 40
        let loopPeriod: CGFloat = (2.5 + 5) * 2  // (ridge height + spacing) × 2 ridges
        let scroll = camera.windProgress * loopPeriod - loopPeriod
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return shape
            .fill(Self.housingBlack)
            .overlay {
                VStack(spacing: 5) {
                    ForEach(0..<ridgeCount, id: \.self) { i in
                        Rectangle()
                            .fill(active && i.isMultiple(of: 2) ? Self.ledGreen.opacity(0.7) : Self.cream.opacity(0.35))
                            .frame(height: 2.5)
                    }
                }
                .padding(.horizontal, 10)
                .offset(y: CGFloat(scroll))
                .frame(height: rowHeight, alignment: .top)
                .clipped()
            }
            .overlay(shape.strokeBorder(Self.frameBrown, lineWidth: 2))
            .frame(width: 56, height: rowHeight)
    }

    @ViewBuilder
    private func windProgressTrack(active: Bool) -> some View {
        Rectangle()
            .fill(Self.cream.opacity(0.18))
            .frame(width: 56, height: 5)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Self.ledGreen)
                        .frame(width: geo.size.width * (camera.isArmed ? 1 : camera.windProgress))
                }
            }
            .opacity(active || camera.isArmed ? 1 : 0.5)
            .animation(FernletMotion.fast, value: camera.windProgress)
    }

    // MARK: - Thumbwheel gesture

    private func windGesture(isLandscape: Bool) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .local)
            .onChanged { value in
                let translation = isLandscape ? value.translation.width : value.translation.height
                if isLandscape {
                    let delta = max(0, translation - previousWindTranslation)
                    previousWindTranslation = translation
                    camera.advanceWind(by: delta / landscapeWindThreshold)
                } else {
                    camera.advanceWind(progress: max(0, translation) / portraitWindThreshold)
                }
            }
            .onEnded { _ in
                previousWindTranslation = 0
                if !isLandscape {
                    camera.resetWind()
                }
            }
    }

    private func updateOrientation(for size: CGSize) {
        let next = DisposableCameraOrientation.resolveLandscape(current: isLandscape, size: size)
        guard next != isLandscape else { return }
        isLandscape = next
        previousWindTranslation = 0
        // A half-wound portrait viewfinder shouldn't carry its wind across a rotation.
        if !next { camera.resetWind() }
    }

    // MARK: - Photo capture

    private func takePhoto() async {
        guard camera.isArmed, filmRemaining > 0, camera.canCapturePhoto, canShootHere else { return }
        // Where this shot goes is decided at the tap: the session's film, or today's solo film.
        let solo = isSolo
        camera.disarm()  // openness → 0: the viewfinder fades until the film is wound again.
        flashShutter()
        do {
            let data = try await camera.capturePhoto()
            // B18: the shutter is felt only once the capture has RETURNED — Apple warns a haptic
            // can disturb the camera while it is capturing, and the white flash above already
            // answered the tap. Owed a device check: that this never blurs a shot.
            FernletFeedback.system.play(.shutter)
            guard !solo else {
                keepSoloShot(data)
                return
            }
            features.photos.addPhoto(data)
        } catch {
            if solo {
                soloShotFailed = true
            } else {
                manager.meshError = error.localizedDescription
            }
            // The alert shows the error; this is its haptic. Only here, not on every `meshError`:
            // most of those are the mesh's own news, which plays nothing.
            FernletFeedback.system.play(.failed)
        }
    }

    /// A shot alone: sealed at once into the solo roll and held until the companion's sleep (in a
    /// decoy, memory only). A shot that could not be kept says so and uses no film.
    private func keepSoloShot(_ data: Data) {
        guard let soloRoll else {
            soloShotFailed = true
            return
        }
        switch soloRoll.takePhoto(data) {
        case .kept:
            // Where it was taken, only at an everyday place (World build step 5c and round 5; never a friend's photo).
            if let id = soloRoll.lastKeptID {
                let fix = store.worldLocation.latest
                Task { await store.keepSoloPhotoPlace(for: id, fix: fix) }
            }
        case .noFilmLeft:
            // A used-up film shows on the badge and the shutter; nothing else to say.
            return
        case .notKept:
            soloShotFailed = true
            FernletFeedback.system.play(.failed)
        }
    }

    /// Brief white flash confirming the shot fired.
    private func flashShutter() {
        flashOpacity = 0.85
        withAnimation(.easeOut(duration: 0.3)) { flashOpacity = 0 }
    }

    // MARK: - Develop / leave

    private func beginDevelop() {
        camera.stopSession()
        if features.photos.sessionPhotos.isEmpty {
            // No photos to review here. The keep-as-friend prompt for a photo-less session is
            // presented by FriendsView off the session photos' pendingFriendReview batch — teardown
            // promotes the roster into it, so nothing is lost by deferring past leaveSession.
            // Photos that land during the leave's handoff are promoted into the same batch, and
            // FriendsView offers them there (2026-09-30); none is kept unasked.
            Task { await manager.leaveSessionAfterNotifyingPeers() }
        } else {
            // The review offers exactly these ids and answers them wherever the session photos hold them
            // when the person answers. Door 3's give-up can end the session under it with the mesh
            // held, so this view stays up while the ending moves the photos into
            // pendingFriendReview; the snapshot keeps them offered and the answer still lands. A
            // termination instead tears this view down, and FriendsView asks again with every
            // photo still offered and ticked. A photo arriving after the snapshot is not shown, so
            // it is not answered here: it reaches the post-session review.
            // Phase 2: friend eligibility is computed at presentation time, against the live
            // trust vault, so peers trusted or blocked mid-session never reach the sheet.
            friendCandidates = FriendMintingReview.eligibleCandidates(
                roster: manager.sessionRoster,
                trustedPeers: store.trustedProximityPeers
            )
            keptFriendFingerprints = []
            developReviewIDs = Set(features.photos.sessionPhotos.map(\.id))
            selectedForSave = developReviewIDs
            alsoSaveToPhotos = false
            reviewAnswerFailure = nil
            reviewUnreadableCount = 0
            photoSaveError = nil   // a failure from an earlier review never opens this one
            reviewPresented = true
        }
    }

    /// Completes the keep-as-friend flow: mints the kept candidates (one-sided, local-only) and
    /// consumes ONLY the roster entries this review presented (`consumeRosterEntries`, scoped) —
    /// never clearSessionRoster(): a peer who commits mid-review stays in the live roster and is
    /// offered at true session end via the session photos' pendingFriendReview batch. The embedded
    /// friend section keeps its presentation-time snapshot for display. Only called on the paths
    /// that actually end the session — a cancelled review resumes the camera and keeps the
    /// roster for the real session end.
    private func finalizeFriendKeeps() {
        store.keepProximityFriends(from: friendCandidates, keptFingerprints: keptFriendFingerprints)
        manager.consumeRosterEntries(fingerprints: Set(friendCandidates.map(\.fingerprint)))
        friendCandidates = []
        keptFriendFingerprints = []
    }

    /// Stops the capture session while the app-wide session-end review is up, and restarts it when
    /// the review goes only if this session is live (or the camera shoots on its own) and the
    /// Develop review is not up.
    private func handleOverlayChange(showing: Bool) {
        guard !showing else {
            camera.stopSession()
            return
        }
        // Alone there is no session to be live: the camera restarts as soon as the review goes.
        if isSolo, !reviewPresented {
            camera.startSession()
            return
        }
        guard manager.isSessionLive, !reviewPresented else { return }
        camera.startSession()
    }

    /// Restarts the capture session after a review the user cancelled.
    ///
    /// `isInSession` is the right predicate here and stays (P6 item 2): the question is whether this
    /// view is still the Social tab's content, which is `ConnectView`'s swap condition — not whether
    /// a peer is committed this instant. A founded pair whose link blipped is still looking at the
    /// camera.
    private func resumeCameraAfterCancelledReview() {
        guard manager.isInSession, !reviewCoordinator.isShowing else { return }
        camera.startSession()
    }

    // MARK: - Review sheet

    /// The Develop review over the photos snapshotted at Develop, wherever the manager lists them
    /// now. They are HELD in the sealed pending corpus, never on the wall, until this answer; tiles
    /// load through the manager's gated review seam; swipe-down cancels back to the camera with
    /// nothing answered.
    @ViewBuilder
    private var reviewSheet: some View {
        FriendPhotoReviewSheet(
            photos: developReviewPhotos,
            selectedIDs: $selectedForSave,
            friendCandidates: friendCandidates,
            keptFriendFingerprints: $keptFriendFingerprints,
            alsoSaveToPhotos: $alsoSaveToPhotos,
            canKeep: features.photos.wallCanTakeKeeps,
            workingMessage: reviewWorking,
            answerFailure: reviewAnswerFailure,
            unreadableCount: reviewUnreadableCount,
            tileReloadToken: features.photos.heldPhotosCanBeShown ? 1 : 0,
            keepSelected: { await keepSelectedSessionPhotos() },
            discardAll: { await discardAllSessionPhotos() },
            loadImageData: { features.photos.reviewThumbnailData(for: $0) },
            canReport: { store.reportableSenderKey(of: $0) != nil },
            requestReport: { photoReportSubject = PeerReportSubject.photo($0, senderKey: store.reportableSenderKey(of: $0)) }
        )
        .peerReportFlow($photoReportSubject) { subject, reason in reportDevelopPhoto(subject, reason: reason) }
        .photoSaveFailureAlert("Couldn't Save Photos", failure: $photoSaveError)
        // The alert closing — either button, or the system taking it down — releases an answer
        // waiting on it; so does the sheet going away, so a torn-down sheet never strands one.
        .onChange(of: photoSaveError == nil) { _, cleared in if cleared { saveFailureAcknowledgement.acknowledge() } }
        .onDisappear {
            saveFailureAcknowledgement.acknowledge()
            reviewCoordinator.cameraDevelopReviewUp = false
        }
        .fernletSheet()
    }

    /// FRND-12's primary review action: keeps the ticked photos (the unticked shown ones are
    /// deleted), mints the kept friends, and — only if the toggle is on — exports what the answer
    /// reports kept, AFTER the keep landed, so a Photos denial can never cost it. Scoped to the ids
    /// the review showed (``developReviewIDs``), wherever they are listed now. A failed export's
    /// alert is shown inside the review and closed by the person BEFORE the session is left and the
    /// review closes (design §4.6; fix round 1, U2-C-U2-R2 / U2-L-U2-R2): the alert hangs off the
    /// sheet, so closing it first took the alert down with it. If the review already went (a
    /// termination, a swipe-down) the wait returns at once, so the answer leg always falls.
    private func keepSelectedSessionPhotos() async {
        // The discovery block's answer leg (I21), raised before the manager is touched and lowered
        // only after this answer's leave has returned.
        reviewCoordinator.beginAnswer()
        defer { reviewCoordinator.endAnswer() }
        let answer = features.photos.finishSessionPhotos(keeping: selectedForSave, of: developReviewIDs)
        finalizeFriendKeeps()
        await exportKeptPhotosIfAsked(answer)
        if photoSaveError != nil { await saveFailureAcknowledgement.wait() }
        await finishDevelopReview(after: answer)
    }

    /// The camera-roll half of the answer, and the ONLY place this view hands photos to
    /// `FriendPhotoLibrarySaver`: the photos the answer reports landed on the wall
    /// (`SessionPhotoAnswer.keptOnWall`), hydrated from the WALL — never a pending byte, never before
    /// the answer. Purely additive: a failure (a Photos denial included) sets `photoSaveError`, whose
    /// alert the sheet shows while the caller waits for it to be closed, and never touches the keep.
    private func exportKeptPhotosIfAsked(_ answer: SessionPhotoAnswer) async {
        guard alsoSaveToPhotos, !answer.keptOnWall.isEmpty else { return }
        let toSave = features.photos.hydratedPhotos(features.photos.meshPhotos.filter { answer.keptOnWall.contains($0.id) })
        // If no bytes could be loaded/decrypted, don't report a false success.
        guard !toSave.isEmpty else {
            photoSaveError = .generic
            return
        }
        reviewWorking = .savingToPhotos
        defer { reviewWorking = nil }
        do {
            try await FriendPhotoLibrarySaver.save(toSave)
            // A failure's cue is the shared failure alert's (`photoSaveFailureAlert`).
            FernletFeedback.system.play(.done)
        } catch {
            photoSaveError = FriendPhotoLibrarySaver.userFacingFailure(for: error, photoCount: toSave.count)
        }
    }

    /// "Delete all", confirmed: deletes every photo the review showed and mints the kept friends —
    /// the keep action's twin with nothing kept.
    private func discardAllSessionPhotos() async {
        reviewCoordinator.beginAnswer()
        defer { reviewCoordinator.endAnswer() }
        let answer = features.photos.finishSessionPhotos(keeping: [], of: developReviewIDs)
        finalizeFriendKeeps()
        await finishDevelopReview(after: answer)
    }

    /// Report… on a Develop review photo (App Review guideline 1.2, 2026-10-15): files the people
    /// report against its sender (recorded on this device, the sender blocked), removes the photo the
    /// way declining it would (`MeshSessionPhotos.removeReportedPhoto(_:)`), and takes it out of this
    /// review — its id, its tick — and its sender out of the keep-as-friend rows. A review left with
    /// no photo closes as a swipe-down does, answering nothing else: the camera resumes, and Develop
    /// again ends the session with the friend question asked by the Friends surface. Refused while an
    /// answer of this review runs (its export, or the answer itself).
    ///
    /// - Parameters:
    ///   - subject: The photo's sender, with the photo's id as its content.
    ///   - reason: The reason the person chose.
    private func reportDevelopPhoto(_ subject: PeerReportSubject, reason: ReportReason) {
        guard case .photo(let photoID) = subject.content, developReviewIDs.contains(photoID),
              reviewWorking == nil, !reviewCoordinator.answerInFlight else { return }
        store.reportSessionPeer(subject, reason: reason)
        if !features.photos.removeReportedPhoto(photoID) {
            FernletAuditLog.log("camera.developReview.reportedPhotoStillHeld")
        }
        developReviewIDs.remove(photoID)
        selectedForSave.remove(photoID)
        friendCandidates.removeAll { $0.signingPublicKey == subject.signingPublicKey }
        keptFriendFingerprints.formIntersection(Set(friendCandidates.map(\.fingerprint)))
        guard developReviewPhotos.isEmpty else { return }
        reviewPresented = false
    }

    /// After an answer: stay up when it left photos held (`notApplied`) — the grid already shows
    /// only those, the selection is trimmed to them, and the inline line says why — or show the
    /// "couldn't be opened" notice when there is one, end the session, and close.
    private func finishDevelopReview(after answer: SessionPhotoAnswer) async {
        guard answer.notApplied.isEmpty else {
            reviewAnswerFailure = answer.failure
            selectedForSave.formIntersection(answer.notApplied)
            return
        }
        reviewAnswerFailure = nil
        if !answer.unreadable.isEmpty {
            reviewUnreadableCount = answer.unreadable.count
            await pauseForUnreadableNotice()
        }
        await manager.leaveSessionAfterNotifyingPeers()
        reviewPresented = false
    }

    /// Holds the review on screen long enough to read the "couldn't be opened" line (it is also
    /// announced). Cancellation just ends the pause early — the close still runs.
    private func pauseForUnreadableNotice() async {
        do {
            try await Task.sleep(for: .milliseconds(1_800))
        } catch {
            return   // cancelled: close at once (R7: nothing owed)
        }
    }

    // MARK: - Session prompts

    /// Asks about the newest removal proposal somebody else made, when none is up
    /// (``SessionRemovalQueue``). Session info, Messages and Leave live on Home's session button now;
    /// the prompts ride every session surface, this one included (``SessionPromptsModifier``).
    private func presentNextRemovalProposalIfNeeded() {
        activeRemovalProposal = SessionRemovalQueue.next(current: activeRemovalProposal,
                                                         pending: manager.pendingRemovalProposals,
                                                         localFingerprint: manager.localFingerprint)
    }
}
