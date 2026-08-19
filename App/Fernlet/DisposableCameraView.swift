import SwiftUI
import AVFoundation
import UIKit
import FernletDomainModel
import ProximityKit
import AppServices
import FernletUI
import os

// MARK: - Camera preview (UIViewRepresentable)

/// `UIViewRepresentable` wrapper showing the live `AVCaptureSession` preview layer.
///
/// Owns horizon-level rotation via `AVCaptureDevice.RotationCoordinator` and detaches the
/// session reference in `dismantleUIView`. ``DisposableCameraView`` keeps exactly one instance
/// structurally stable across rotation so the running capture session is never torn down and
/// reattached (the old freeze / black flash).
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
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
                return "Camera access is unavailable."
            case .captureInProgress:
                return "A photo is already being captured."
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
    /// Emits haptic detents at each third; arms with a medium thud at 1.0.
    func advanceWind(progress: Double) {
        guard !isArmed else { return }
        let clamped = max(0, min(progress, 1.0))
        let oldTick = Int(windProgress * 12)
        let newTick = Int(clamped * 12)
        windProgress = clamped
        if newTick > oldTick {
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.55)
        }
        if clamped >= 1.0 {
            isArmed = true
            windProgress = 0
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 1)
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
    /// open gap clears the whole island band + status LED (the housing top is at the screen top);
    /// elsewhere it is the shell's decorative top gap.
    private func ledGap(openness: Double) -> CGFloat {
        let openMax: CGFloat = deviceClass == .island ? topInset + 22 : 34
        return lerp(4, openMax, clamp(openness))
    }

    /// The live-preview window, inset inside the housing shell and pushed below the status LED.
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

    /// Center Y of the status LED — rides in the closed island pill, then settles just below the
    /// island band (island devices) or near the shell's top gap (notch / flat) as it opens.
    func ledCenterY(openness: Double) -> CGFloat {
        let openY: CGFloat
        switch deviceClass {
        case .island:
            // Just below the island band, inside the merged housing.
            openY = topInset * 0.5 + closedSize.height / 2 + 9
        case .notch, .flat:
            let housingTopOpen = openCenterY - openSize.height / 2
            openY = housingTopOpen + ledGap(openness: 1) * 0.4 + 6
        }
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

/// The in-session "disposable camera": the full-screen hardware-styled capture surface shown by
/// ``FriendsView`` while a friends mesh session is live.
///
/// Owns a ``CameraCaptureController`` as `@State` and renders the wind-to-arm thumbwheel, the
/// island-morphing viewfinder (geometry from ``IslandViewfinderMetrics``), the shutter with a
/// shared per-session film counter (`MeshNetworkManager.filmRemaining`), and the session-info
/// sheet (rename, open/closed access, roster with removal seconding / blocking, in-session
/// hearts). It also hosts the session-scoped chat entry (13+ gated via `manager.isChatAllowed`),
/// the admission-prompt sheet for join requests, and the develop flow: "Develop" stops the
/// capture session and either leaves immediately (no photos — the keep-as-friend prompt is then
/// FriendsView's job via the pending review batch) or presents `FriendPhotoReviewSheet` with
/// friend candidates computed at presentation time against the live trust vault. Orientation
/// flips through ``DisposableCameraOrientation``'s hysteresis so mid-rotation near-square frames
/// never thrash the layout.
struct DisposableCameraView: View {
    var store: FernletStore

    @State private var camera = CameraCaptureController()
    @State private var flashOpacity: Double = 0
    @State private var showInfo = false
    @State private var showChat = false
    @State private var reviewPresented = false
    @State private var selectedForSave: Set<UUID> = []
    // Phase 2 friend minting: candidates snapshotted when the review presents + the user's keeps.
    @State private var friendCandidates: [MeshSessionRosterEntry] = []
    @State private var keptFriendFingerprints: Set<String> = []
    @State private var photoSaveError: PhotoSaveFailure? = nil
    @State private var activeRemovalProposal: MeshRemovalProposalPayload?
    @State private var previousWindTranslation: CGFloat = 0
    // Orientation is @State (not a raw per-frame `size.width > size.height`) so a transient
    // near-square frame mid-rotation can't flip the layout twice — see `Self.resolveLandscape`.
    @State private var isLandscape = false
    @State private var renamingMesh = false
    @State private var newMeshName = ""
    @State private var leaveSessionConfirm = false
    /// The session member a "Block …?" confirmation is about — the in-session menu used to block
    /// instantly while the roster's Block asked first.
    @State private var participantToBlock: MeshSessionParticipant?
    /// At most one in-flight session-message notification post (R3: the trigger is peer-driven).
    @State private var messageNotificationTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    /// The cap on a session name typed here — it rides the mesh descriptor to every peer.
    private static let maxMeshNameLength = 40

    // Housing / LED palette. The camera surface is a standalone "hardware housing" scene rather
    // than a parchment card, so a couple of colors are literal rather than design-system tokens:
    // the near-black shell (#050403) and the vivid hardware-LED green (#5EE06A) have no token.
    private static let housingBlack = Color(red: 0.020, green: 0.016, blue: 0.012)
    private static let ledGreen = Color(red: 0.369, green: 0.878, blue: 0.416)
    // Warm shutter-button cream (#FBF7EE), the film-camera release color from the mockup.
    private static let shutterCream = Color(red: 0.984, green: 0.969, blue: 0.933)

    private var manager: MeshNetworkManager { store.meshNetworkManager }
    private let portraitWindThreshold: Double = 120
    private let landscapeWindThreshold: Double = 720

    var body: some View {
        GeometryReader { geometry in
            cameraSurface(geometry: geometry)
        }
        .onAppear { camera.startSession() }
        .onDisappear {
            camera.stopSession()
        }
        .onChange(of: manager.pendingRemovalProposals) { _, _ in
            presentNextRemovalProposalIfNeeded()
        }
        // TF b19 item 6: a rising unread count means an inbound message arrived while the chat sheet
        // was closed (the store only increments unread when it isn't being viewed). Signal it — a light
        // haptic while the app is active, a best-effort local notification while it isn't.
        .onChange(of: manager.sessionMessages.unreadCount) { oldValue, newValue in
            guard newValue > oldValue else { return }
            handleUnreadMessageArrival()
        }
        .sheet(isPresented: $reviewPresented, onDismiss: resumeCameraAfterCancelledReview) { reviewSheet }
        .sheet(isPresented: $showInfo) { infoSheet }
        .sheet(isPresented: $showChat) {
            SessionChatPanel(manager: manager, onDone: { showChat = false })
        }
        .modifier(SessionPromptsModifier(
            manager: manager,
            activeRemovalProposal: $activeRemovalProposal,
            leaveSessionConfirm: $leaveSessionConfirm,
            showInfo: $showInfo,
            beginDevelop: beginDevelop
        ))
    }

    /// The full-screen camera "hardware" scene for the current geometry.
    ///
    /// The scene lives in a full-screen (safe-area-ignoring) layer so one preview node can span both
    /// orientations and, on island devices, the housing can reach up to the true screen top to wrap
    /// the island. A single `CameraPreviewView` inside `cameraStage` keeps stable structural
    /// identity across rotation, so the live `AVCaptureSession` is never detached/reattached (the
    /// old freeze/black flash).
    private func cameraSurface(geometry: GeometryProxy) -> some View {
        ZStack {
            Color(red: 0.13, green: 0.10, blue: 0.08)
                .ignoresSafeArea()
                .overlay { cameraStage(geometry: geometry) }

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

    /// The two top-corner controls (info + in-session chat), extracted into a single overlay so the
    /// main body ZStack stays inside the Swift type-checker's budget.
    private var topControls: some View {
        ZStack {
            infoButton
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The 13+ age gate. Reads the same value the transport enforces (`chatAllowedProvider`), so
            // the affordance can't survive a gate the send/receive seams are already refusing. Settings
            // carries the explanation and the way to unlock it — a camera overlay is the wrong place to
            // tell someone they're too young.
            if manager.isChatAllowed {
                chatButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .padding(20)
    }

    private var infoButton: some View {
        Button { showInfo = true } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 18))
                .foregroundStyle(Color.white.opacity(0.5))
        }
        .accessibilityIdentifier("camera.info")
        .fernletIconButton("Session info")
    }

    /// In-session chat entry point (Phase 5). Messages are live-session only and vanish at session end.
    /// TF b19 item 6: a dot badge appears while there are unread inbound messages (cleared when the
    /// panel opens).
    private var chatButton: some View {
        let hasUnread = manager.sessionMessages.hasUnread
        return Button { showChat = true } label: {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 18))
                .foregroundStyle(Color.white.opacity(hasUnread ? 0.85 : 0.5))
                .overlay(alignment: .topTrailing) {
                    if hasUnread {
                        Circle()
                            .fill(Color.terracotta)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Self.housingBlack, lineWidth: 1.5))
                            .offset(x: 5, y: -4)
                            .accessibilityHidden(true)
                    }
                }
        }
        .fernletTapTarget()
        .accessibilityLabel(hasUnread ? "Session messages, new message" : "Session messages")
        .accessibilityIdentifier("camera.chat")
    }

    private var portraitControls: some View {
        HStack(alignment: .bottom) {
            developButton
                .frame(width: 72)
            Spacer()
            shutterButton
            Spacer()
            HStack(spacing: 8) {
                filmCounterBadge
                windIndicator(isLandscape: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
    }

    private var landscapeControls: some View {
        // The film + wind cluster used to sit at `.topTrailing`, painting over the chat button in the
        // same corner (topControls is drawn first, so the cluster stole its taps). It now rides a
        // leading rail, vertically centered — the top corners belong to info (leading) and chat
        // (trailing) alone, and the cluster clears the centered preview and the trailing shutter.
        ZStack {
            VStack(spacing: 14) {
                filmCounterBadge
                windIndicator(isLandscape: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 20)

            shutterButton
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 22)

            developButton
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(22)
        }
    }

    private var filmCounterBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "film")
                .font(.system(size: 11, weight: .semibold))
            Text("\(manager.filmRemaining)")
                .font(.fernlet(.stat))
        }
        .foregroundStyle(manager.filmRemaining > 0 ? Color.goldenrod : Color.terracotta)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .accessibilityLabel("Film remaining: \(manager.filmRemaining)")
        .accessibilityIdentifier("camera.filmCounter")
    }

    // MARK: - Viewfinder

    /// The glass rect (in the full-screen overlay's coordinate space) for the live-preview window,
    /// plus its corner radius and fade. Computed as a plain value for the current orientation +
    /// openness so a single, structurally-stable `CameraPreviewView` can be repositioned across
    /// rotation rather than recreated.
    private struct GlassRect {
        var rect: CGRect
        var cornerRadius: CGFloat
        var previewOpacity: Double
    }

    /// The whole "camera hardware" scene: the black housing (portrait only, wrapping the island),
    /// ONE preview node, and the framing chrome. `openness` (armed → 1, else windProgress) drives
    /// the open↔closed morph in BOTH orientations, so `disarm()` after a shot retracts the
    /// viewfinder in landscape exactly as it does in the portrait island path.
    private func cameraStage(geometry: GeometryProxy) -> some View {
        let openness = camera.isArmed ? 1.0 : camera.windProgress
        let metrics = IslandViewfinderMetrics(
            topInset: geometry.safeAreaInsets.top,
            screenWidth: geometry.size.width
        )
        let glass = glassRect(geometry: geometry, metrics: metrics, openness: openness)
        let showsPermissionPrompt = camera.needsCameraPermissionPrompt
            && (isLandscape || openness > 0.85)

        return ZStack {
            // Decorative hardware — flattened for VoiceOver, kept out of hit testing (the wind
            // gesture lives on the thumbwheel). The child order here is fixed regardless of
            // orientation: the housing shell is one optional slot, the preview always index 1, and
            // the framing chrome one Group slot — so the `CameraPreviewView` UIView (and its live
            // capture-session attachment) survives every rotation.
            ZStack {
                if !isLandscape {
                    islandHousingShell(metrics: metrics, openness: openness)
                }

                CameraPreviewView(session: camera.session)
                    .frame(width: glass.rect.width, height: glass.rect.height)
                    .clipShape(RoundedRectangle(cornerRadius: glass.cornerRadius, style: .continuous))
                    .opacity(glass.previewOpacity)
                    .position(x: glass.rect.midX, y: glass.rect.midY)

                Group {
                    if isLandscape {
                        landscapeFraming(glass: glass)
                    } else {
                        islandFraming(metrics: metrics, glass: glass, openness: openness)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(camera.isArmed ? "Viewfinder ready" : "Wind to open the viewfinder")
            .accessibilityHidden(showsPermissionPrompt)

            // The permission prompt is real UI, so it layers after the decorative flattening — its
            // Open Settings button stays tappable and VoiceOver-reachable.
            if showsPermissionPrompt {
                cameraPermissionPrompt
                    .frame(width: glass.rect.width, height: glass.rect.height)
                    .clipShape(RoundedRectangle(cornerRadius: glass.cornerRadius, style: .continuous))
                    .position(x: glass.rect.midX, y: glass.rect.midY)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: openness)
    }

    /// Preview-glass geometry for the current orientation, in the full-screen overlay coordinate
    /// space (origin = true top-left).
    private func glassRect(
        geometry: GeometryProxy,
        metrics: IslandViewfinderMetrics,
        openness: Double
    ) -> GlassRect {
        if isLandscape {
            // Fit a 4:3 window inside the safe area (minus chrome padding), then shrink + fade it
            // toward a compact element as the camera unwinds so it retracts after a shot and the
            // user re-arms with the same wind affordance as portrait.
            let sa = geometry.safeAreaInsets
            let padH: CGFloat = 26, padV: CGFloat = 18
            let availW = max(0, geometry.size.width - padH * 2)
            let availH = max(0, geometry.size.height - padV * 2)
            var w = availW
            var h = availW * 3 / 4
            if h > availH { h = availH; w = availH * 4 / 3 }
            let scale = 0.4 + 0.6 * CGFloat(min(max(openness, 0), 1))
            w *= scale
            h *= scale
            let centerX = sa.leading + geometry.size.width / 2
            let centerY = sa.top + geometry.size.height / 2
            return GlassRect(
                rect: CGRect(x: centerX - w / 2, y: centerY - h / 2, width: w, height: h),
                cornerRadius: 12,
                previewOpacity: metrics.previewOpacity(openness: openness)
            )
        } else {
            let g = metrics.glassFrame(openness: openness)
            return GlassRect(
                rect: CGRect(
                    x: metrics.centerX - g.size.width / 2,
                    y: g.centerY - g.size.height / 2,
                    width: g.size.width,
                    height: g.size.height
                ),
                cornerRadius: g.cornerRadius,
                previewOpacity: metrics.previewOpacity(openness: openness)
            )
        }
    }

    /// The near-black housing shell behind the portrait preview. On island devices its top reaches
    /// the screen edge so the island pill rides inside its top band (item 8); on notch / flat it is
    /// the detached floating card.
    private func islandHousingShell(metrics: IslandViewfinderMetrics, openness: Double) -> some View {
        let housing = metrics.frame(openness: openness)
        return RoundedRectangle(cornerRadius: housing.cornerRadius, style: .continuous)
            .fill(Self.housingBlack)
            .shadow(color: Color.black.opacity(0.55), radius: 16, y: 12)
            .frame(width: housing.size.width, height: housing.size.height)
            .position(x: metrics.centerX, y: housing.centerY)
    }

    /// Portrait framing chrome: reticle brackets over the glass + the status LED just below the
    /// island band.
    private func islandFraming(
        metrics: IslandViewfinderMetrics,
        glass: GlassRect,
        openness: Double
    ) -> some View {
        ZStack {
            islandViewfinderReticle
                .frame(width: glass.rect.width, height: glass.rect.height)
                .opacity(glass.previewOpacity)
                .position(x: glass.rect.midX, y: glass.rect.midY)

            islandCameraLED(openness: openness)
                .position(x: metrics.centerX, y: metrics.ledCenterY(openness: openness))
        }
    }

    /// Landscape framing chrome: corner brackets + a subtle rounded border that stays visible while
    /// the viewfinder is retracted, so the shrunken glass reads as the wind/re-arm target.
    private func landscapeFraming(glass: GlassRect) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: glass.cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.12 + 0.13 * glass.previewOpacity), lineWidth: 1)
                .frame(width: glass.rect.width, height: glass.rect.height)
                .position(x: glass.rect.midX, y: glass.rect.midY)

            viewfinderBrackets
                .frame(width: glass.rect.width, height: glass.rect.height)
                .opacity(glass.previewOpacity)
                .position(x: glass.rect.midX, y: glass.rect.midY)
        }
    }

    /// The classic "camera on" green LED (#5EE06A) that rides at the top of the housing, breathing
    /// with a slow pulse once the viewfinder is open.
    private func islandCameraLED(openness: Double) -> some View {
        // Base visibility fades the LED in with the housing; once armed it breathes 0.8↔1.0. The
        // breathe is clock-driven (TimelineView) rather than a repeatForever animation: disarming
        // after a shot retargets the LED's opacity, which would kill a repeating animation for
        // good, and the pulse must survive every disarm/re-arm cycle.
        let visible = camera.isArmed ? 1.0 : Double(openness)
        return TimelineView(.animation(paused: !camera.isArmed)) { context in
            // 0.8 ↔ 1.0 cosine breathe with a 3.8s round trip (the old autoreversing 1.9s ease).
            let phase = context.date.timeIntervalSinceReferenceDate / 3.8 * 2 * .pi
            let breathe = camera.isArmed ? 0.9 - 0.1 * cos(phase) : 0.82
            Circle()
                .fill(Self.ledGreen)
                .frame(width: 7, height: 7)
                .shadow(color: Self.ledGreen.opacity(0.75), radius: 5)
                .opacity(visible * breathe)
        }
    }

    /// White reticle corner brackets framing the live preview, matching the mockup's armed frame.
    private var islandViewfinderReticle: some View {
        cornerBrackets(color: Color.white.opacity(0.7), length: 16, thickness: 2, margin: 8)
            .allowsHitTesting(false)
    }

    private var cameraPermissionPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Color.dustyRose)
                .frame(width: 60, height: 60)
                .background(Color.dustyRose.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.bottom, 4)
            Text("Camera access is off")
                .font(.fernlet(.header))
                .foregroundStyle(.white)
            Text("Fernlet needs the camera to take photos with friends. You can turn it on any time.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") {
                openAppSettings()
            }
            .font(.fernlet(.label))
            .foregroundStyle(Color.midnight)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.stateThriving.opacity(0.9), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .padding(.top, 6)
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.housingBlack.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("camera.permissionPrompt")
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var viewfinderBrackets: some View {
        cornerBrackets(color: Color.white.opacity(0.45), length: 18, thickness: 2, margin: 0)
    }

    /// Four corner brackets inset `margin` from each edge — the island reticle and the landscape
    /// viewfinder frame differ only in size, inset, and brightness.
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

    private var developButton: some View {
        Button {
            // With photos there is a review sheet to back out of. With none, "Develop" used to end
            // the live session on the spot — chat transcript gone, camera gone — off a photo verb.
            // Ask with the same "End session?" alert the info sheet raises.
            if manager.sessionPhotos.isEmpty {
                leaveSessionConfirm = true
            } else {
                beginDevelop()
            }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.white.opacity(0.65))
                // Named for what it actually does: developing the film also ends the outing.
                Text("Develop & finish")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("camera.develop")
    }

    private var shutterButton: some View {
        let canShoot = camera.isArmed && manager.filmRemaining > 0 && camera.canCapturePhoto
        return Button {
            guard canShoot else { return }
            Task { await takePhoto() }
        } label: {
            VStack(spacing: 7) {
                ZStack {
                    // Bright, glowing ring when ready; muted ring when locked.
                    Circle()
                        .stroke(Color.white.opacity(canShoot ? 0.85 : 0.16), lineWidth: 3)
                        .frame(width: 82, height: 82)
                        .shadow(color: Color.white.opacity(canShoot ? 0.25 : 0), radius: 10)
                    Circle()
                        .fill(canShoot ? Self.shutterCream : Color.white.opacity(0.14))
                        .frame(width: 70, height: 70)
                    if !camera.isArmed && manager.filmRemaining > 0 {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.5))
                    } else if manager.filmRemaining == 0 {
                        Image(systemName: "film.slash")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.terracotta.opacity(0.9))
                    } else if !camera.canCapturePhoto {
                        Image(systemName: "camera.slash")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                }
                // Captions replace the mockup's cryptic glyphs: name each shutter state in words.
                Text(shutterCaption(canShoot: canShoot))
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(canShoot ? Color.stateThriving : Color.white.opacity(0.4))
            }
        }
        .disabled(!canShoot)
        .scaleEffect(canShoot ? 1.0 : 0.9)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: canShoot)
        .accessibilityLabel(shutterAccessibilityLabel(canShoot: canShoot))
        .accessibilityIdentifier("camera.shutter")
    }

    /// A short caption under the shutter, so its ring state reads without decoding a glyph.
    private func shutterCaption(canShoot: Bool) -> String {
        if canShoot { return "Tap to shoot" }
        if manager.filmRemaining == 0 { return "No film left" }
        if !camera.canCapturePhoto { return "Camera off" }
        return "Wind to arm"
    }

    private func shutterAccessibilityLabel(canShoot: Bool) -> String {
        if canShoot { return "Take photo" }
        if manager.filmRemaining == 0 { return "No film remaining" }
        if !camera.canCapturePhoto { return "Camera unavailable" }
        return "Wind camera first"
    }

    private func windIndicator(isLandscape: Bool) -> some View {
        // A larger, legible ridged thumbwheel (mockup 5d "after") with its ridges scrolling as the
        // wheel turns and a slim progress track underneath. Green ridges/accents once winding starts.
        let winding = !camera.isArmed && camera.windProgress > 0
        return VStack(spacing: 6) {
            windThumbwheel(active: winding)
            Text(camera.isArmed ? "Ready" : isLandscape ? "Swipe →" : "Slide ↓")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(camera.isArmed ? Color.stateThriving : Color.white.opacity(0.42))
            windProgressTrack(active: winding)
        }
        .frame(width: 64)
        .contentShape(Rectangle())
        .gesture(windGesture(isLandscape: isLandscape))
        // Winding is the gate on the shutter, and it was drag-only: VoiceOver and Switch Control
        // users could never arm the camera, so the shutter read "Wind camera first" forever. The
        // wheel is now one element with a value, a default activation (double tap), and a named
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
        // over-fills the 44pt window by one two-ridge loop and slides down through it across a
        // full wind: the wheel reads as continuously turning — no blank band opens up, and the
        // arm-time windProgress reset to 0 lands on an identical frame.
        let ridgeCount = 9
        let rowHeight: CGFloat = 44
        let loopPeriod: CGFloat = (2.5 + 5) * 2  // (ridge height + spacing) × 2 ridges
        let scroll = camera.windProgress * loopPeriod - loopPeriod
        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.20, green: 0.17, blue: 0.14), Color(red: 0.09, green: 0.075, blue: 0.06)],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .overlay {
                VStack(spacing: 5) {
                    ForEach(0..<ridgeCount, id: \.self) { i in
                        Capsule()
                            .fill(
                                active && i.isMultiple(of: 2)
                                    ? Color.stateThriving.opacity(0.55)
                                    : Color.white.opacity(0.16)
                            )
                            .frame(height: 2.5)
                    }
                }
                .padding(.horizontal, 12)
                .offset(y: CGFloat(scroll))
                .frame(height: rowHeight, alignment: .top)
                .clipped()
            }
            .frame(width: 40, height: rowHeight)
    }

    @ViewBuilder
    private func windProgressTrack(active: Bool) -> some View {
        Capsule()
            .fill(Color.white.opacity(0.12))
            .frame(height: 5)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.stateThriving)
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
        guard camera.isArmed, manager.filmRemaining > 0, camera.canCapturePhoto else { return }
        camera.disarm()  // openness → 0: the viewfinder retracts into the island.
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        flashShutter()
        do {
            let data = try await camera.capturePhoto()
            manager.addPhoto(data)
        } catch {
            manager.meshError = error.localizedDescription
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
        if manager.sessionPhotos.isEmpty {
            // No photos to review here. The keep-as-friend prompt for a photo-less session is
            // presented by FriendsView off the manager's pendingFriendReview batch — teardown
            // promotes the roster into it, so nothing is lost by deferring past leaveSession.
            Task { await manager.leaveSessionAfterNotifyingPeers() }
        } else {
            // Phase 2: friend eligibility is computed at presentation time, against the live
            // trust vault, so peers trusted or blocked mid-session never reach the sheet.
            friendCandidates = FriendMintingReview.eligibleCandidates(
                roster: manager.sessionRoster,
                trustedPeers: store.trustedProximityPeers
            )
            keptFriendFingerprints = []
            selectedForSave = Set(manager.sessionPhotos.map(\.id))
            reviewPresented = true
        }
    }

    /// Completes the keep-as-friend flow: mints the kept candidates (one-sided, local-only) and
    /// consumes ONLY the roster entries this review presented (`consumeRosterEntries`, scoped) —
    /// never clearSessionRoster(): a peer who commits mid-review stays in the live roster and is
    /// offered at true session end via the manager's pendingFriendReview batch. The embedded
    /// friend section keeps its presentation-time snapshot for display. Only called on the paths
    /// that actually end the session — a cancelled review resumes the camera and keeps the
    /// roster for the real session end.
    private func finalizeFriendKeeps() {
        store.keepProximityFriends(from: friendCandidates, keptFingerprints: keptFriendFingerprints)
        manager.consumeRosterEntries(fingerprints: Set(friendCandidates.map(\.fingerprint)))
        friendCandidates = []
        keptFriendFingerprints = []
    }

    private func resumeCameraAfterCancelledReview() {
        guard manager.isInSession else { return }
        camera.startSession()
    }

    // MARK: - Review sheet

    @ViewBuilder
    private var reviewSheet: some View {
        FriendPhotoReviewSheet(
            photos: manager.sessionPhotos,
            selectedIDs: $selectedForSave,
            friendCandidates: friendCandidates,
            keptFriendFingerprints: $keptFriendFingerprints,
            saveSelected: {
                let toSave = manager.sessionPhotos.filter { selectedForSave.contains($0.id) }
                do {
                    try await FriendPhotoLibrarySaver.save(toSave)
                    manager.finishSessionPhotos(keeping: selectedForSave)
                    finalizeFriendKeeps()
                    await manager.leaveSessionAfterNotifyingPeers()
                    reviewPresented = false
                } catch {
                    photoSaveError = FriendPhotoLibrarySaver.userFacingFailure(for: error, photoCount: toSave.count)
                }
            },
            discardAll: {
                manager.deleteAllSessionPhotos()
                finalizeFriendKeeps()
                Task { @MainActor in
                    await manager.leaveSessionAfterNotifyingPeers()
                    reviewPresented = false
                }
            }
        )
        .photoSaveFailureAlert("Couldn't Save Photos", failure: $photoSaveError)
    }

    // MARK: - Info sheet

    @ViewBuilder
    private var infoSheet: some View {
        ZStack {
            Color.parchment
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    sessionHeader
                    sessionStats
                    accessPicker

                    Text("People")
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)

                    participantList
                    heartStatusRow
                    presenceNudge
                    debugInspectorButton
                    removalRequestsSection
                    endSessionButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
        .sheet(isPresented: $renamingMesh) {
            renameMeshSheet
        }
        .alert(
            participantToBlock.map { "Block \($0.displayName)?" } ?? "Block this person?",
            isPresented: $participantToBlock.isPresent(),
            presenting: participantToBlock
        ) { participant in
            Button("Block", role: .destructive) {
                manager.block(participant)
                participantToBlock = nil
            }
            Button("Cancel", role: .cancel) { participantToBlock = nil }
        } message: { participant in
            Text("Blocking \(participant.displayName) will hide their content from you and yours from them, and drop them from this session.")
        }
    }

    /// The sheet's title row: the (renameable) mesh name and the Done button.
    private var sessionHeader: some View {
        HStack {
            if let mesh = manager.currentMesh {
                Button {
                    newMeshName = mesh.name
                    renamingMesh = true
                } label: {
                    HStack(spacing: 7) {
                        Text(mesh.name)
                            .font(.fernlet(.display))
                        Image(systemName: "pencil")
                            .font(.body)
                    }
                    .foregroundStyle(Color.bark)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sessionInfo.rename")
            } else {
                Text("Session")
                    .font(.fernlet(.display))
                    .foregroundStyle(Color.bark)
            }
            Spacer()
            Button("Done") { showInfo = false }
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
                .buttonStyle(.plain)
        }
    }

    /// Participant count and remaining film.
    private var sessionStats: some View {
        // Real plurals — "2 person(s) connected" is a placeholder that shipped.
        let people = manager.sessionParticipants.count
        let shots = manager.filmRemaining
        return VStack(alignment: .leading, spacing: 22) {
            Text(people == 1 ? "1 person connected" : "\(people) people connected")
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.slate)

            HStack(spacing: 6) {
                Image(systemName: "film")
                    .foregroundStyle(Color.slate)
                Text(shots == 1 ? "1 shot left" : "\(shots) shots left")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate)
            }
        }
    }

    /// Open vs closed session access.
    private var accessPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Session access")
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)

            Picker("Session access", selection: Binding(
                get: { manager.isSessionOpen ? MeshMode.open : MeshMode.closed },
                set: { manager.setSessionOpen($0 == .open) }
            )) {
                Text("Open").tag(MeshMode.open)
                Text("Closed").tag(MeshMode.closed)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("sessionInfo.mode")
        }
    }

    /// The session roster, one row per participant.
    private var participantList: some View {
        VStack(spacing: 0) {
            ForEach(manager.sessionParticipants) { participant in
                participantRow(participant)
                if participant.id != manager.sessionParticipants.last?.id {
                    FernletRowDivider()
                }
            }
        }
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    /// One roster row: name, vouch label, the heart button for trusted friends, and the row menu.
    private func participantRow(_ participant: MeshSessionParticipant) -> some View {
        HStack(spacing: 12) {
            Image(systemName: participant.isLocal ? "person.crop.circle.fill" : "person.crop.circle")
                .foregroundStyle(Color.moss)
            Text(participant.displayName)
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
            if !participant.isLocal, let vouchLabel = manager.vouchLabel(for: participant.fingerprint) {
                Text(vouchLabel)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
            }
            if participant.isLocal {
                Text("You")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
            }
            Spacer()
            if !participant.isLocal {
                if let friend = trustedFriend(for: participant) {
                    sessionHeartButton(for: friend)
                }
                participantMenu(participant)
            }
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 14)
    }

    /// The per-participant overflow menu: propose a removal, or block outright.
    private func participantMenu(_ participant: MeshSessionParticipant) -> some View {
        Menu {
            Button {
                manager.proposeRemoval(of: participant)
            } label: {
                Label("Ask to remove", systemImage: "person.badge.minus")
            }
            Button(role: .destructive) {
                // Same action, same person, same safety net as Friends & Blocks: blocking here also
                // drops them from the shared photo and chat flow, so it asks first.
                participantToBlock = participant
            } label: {
                Label("Block", systemImage: "hand.raised")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(Color.slate)
        }
        .fernletTapTarget()
        .accessibilityLabel("Options for \(participant.displayName)")
    }

    /// TF b19 item 5 tier 1: surface heart send state inline (no longer silent).
    @ViewBuilder
    private var heartStatusRow: some View {
        if let status = sessionHeartStatusText {
            Text(status)
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.moss)
                .frame(maxWidth: .infinity, alignment: .center)
                .fernletWrappingText()
                .accessibilityIdentifier("sessionInfo.heartStatus")
        }
    }

    /// TF b19 item 5 tier 1: actionable prompt for the older-build fallback that still needs the
    /// presence radio (hearts on, Nearby Friends off). Hidden in the common mesh path — replaces the
    /// old dead "Hearts travel in person for now" label.
    @ViewBuilder
    private var presenceNudge: some View {
        if sessionHeartsNeedPresence {
            Button {
                store.setAllowNearbyPresence(true)
            } label: {
                Text("Turn on Nearby Friends to send hearts")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.parchment)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sessionInfo.enablePresence")
        }
    }

    /// The Connection Inspector entry point, behind the proximity debug-tools setting.
    @ViewBuilder
    private var debugInspectorButton: some View {
        if store.settings.showProximityDebugTools {
            Button {
                store.showConnectionInspector = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(Color.moss)
                    Text("Connection Inspector")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.bark)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.slate)
                }
                .padding(14)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sessionInfo.inspectorButton")
        }
    }

    /// Pending removal proposals awaiting a second.
    @ViewBuilder
    private var removalRequestsSection: some View {
        if !manager.pendingRemovalProposals.isEmpty {
            Text("Removal Requests")
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)

            ForEach(manager.pendingRemovalProposals) { proposal in
                removalRequestCard(proposal)
            }
        }
    }

    /// One pending removal proposal: what was asked, and this device's part in it.
    private func removalRequestCard(_ proposal: MeshRemovalProposalPayload) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(proposal.proposerDisplayName) asked to remove \(proposal.targetDisplayName).")
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
            if manager.canSecondRemoval(proposal) {
                Button("Second Removal", role: .destructive) {
                    manager.secondRemoval(proposal)
                }
                .font(.fernlet(.label))
            } else {
                Text("Waiting for another participant to second this decision.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    /// Ends the session (confirmed by the end-session alert).
    private var endSessionButton: some View {
        Button("End session") {
            leaveSessionConfirm = true
        }
        .buttonStyle(ActionPillButtonStyle(.destructive))
        .accessibilityIdentifier("sessionInfo.endSession")
    }

    // MARK: - Send good vibes (in-session)

    /// The trusted-friend record behind a session participant, when hearts can go to them:
    /// consent on, known in the vault by fingerprint, not blocked or removed.
    private func trustedFriend(for participant: MeshSessionParticipant) -> ProximityTrustedPeerRecord? {
        guard store.settings.allowNearbyHearts else { return nil }
        return store.trustedProximityPeers.first {
            IdentityService.fingerprintsMatch($0.fingerprint, participant.fingerprint)
                && $0.blockedAt == nil
                && $0.revokedAt == nil
        }
    }

    /// A quiet one-tap heart beside a connected friend. TF b19 item 5: in-session hearts now ride the
    /// live mesh session (reliable — the peer is right here, already connected over a verified channel)
    /// instead of the fragile on-demand presence connect. A session peer on an older build (no `hearts`
    /// mesh capability) falls back to the presence path so nothing regresses. Enabled only while the
    /// 5-minute cooldown to them is clear, they're reachable, and no send is in flight; no counts shown
    /// anywhere. A filled check marks the cooldown — a state, never a number.
    private func sessionHeartButton(for friend: ProximityTrustedPeerRecord) -> some View {
        let onCooldown = !store.heartLedger.canSendHeart(to: friend.fingerprint)
        // `canSendHeart` is fail-closed (Track A): an UNLOADED ledger also answers false, and the
        // cooldown copy would be a lie there — nothing was sent. Say what is actually wrong, exactly
        // as the friend row does (FriendListView's `onCooldown` branch).
        let ledgerUnavailable = onCooldown && !store.heartLedger.isLoaded
        // Prefer the mesh: a live session member with the `hearts` capability is always reachable over
        // the already-connected channel — no dependence on the separate presence radio. Only the older-
        // build fallback consults presence reachability.
        let meshCapable = manager.canSendSessionHeart(toFingerprint: friend.fingerprint)
        let reachable = meshCapable || store.presenceManager.isReachable(fingerprint: friend.fingerprint)
        let sending = sessionHeartSendInProgress
        let firstName = PresenceManager.firstName(of: friend.displayName)
        let state = SendGoodVibesLabel.state(onCooldown: onCooldown, reachable: reachable, sending: sending)
        return Button {
            // Haptic acknowledgement so the tap is never silent (TF b19 item 5 tier 1).
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            if meshCapable {
                manager.sendSessionHeart(to: friend)
            } else {
                store.presenceManager.sendHeart(to: friend)
            }
        } label: {
            // Compact in-row form of the "Send good vibes" affordance (good-vibes 10c): a
            // dusty-rose/terracotta heart when ready, a soft-filled check within the cooldown,
            // muted apart.
            Image(systemName: state == .cooldown ? "checkmark" : "heart.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(sessionHeartForeground(for: state))
                .frame(width: 30, height: 30)
                .background(sessionHeartBackground(for: state), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(onCooldown || !reachable || sending)
        .accessibilityLabel(
            ledgerUnavailable
                ? "Fernlet couldn't reach its own notes just now — unlock and reopen to send hearts."
                : onCooldown
                    ? "You just sent \(firstName) some warmth — hearts settle for a few minutes."
                    : reachable
                        ? "Send good vibes to \(friend.displayName)"
                        : "\(firstName) isn't reachable for a heart right now."
        )
    }

    /// A send is in flight on EITHER transport (the mesh path — TF b19 item 5 — or the presence
    /// fallback for older peers).
    private var sessionHeartSendInProgress: Bool {
        if case .sending = manager.sessionHeartState { return true }
        switch store.presenceManager.heartSendState {
        case .connecting, .verifying: return true
        default: return false
        }
    }

    /// Shared, single-line status for the in-session heart send (TF b19 item 5 tier 1 — surface the
    /// send state instead of failing silently). Reflects the mesh path first, then the presence
    /// fallback. Only one send runs at a time, so one line suffices for the whole participant list.
    private var sessionHeartStatusText: String? {
        switch manager.sessionHeartState {
        case .sending(let name): return "Sending \(name) some warmth…"
        case .sent(let name): return "Sent \(name) some good vibes."
        case .failed(let message): return message
        case .idle:
            switch store.presenceManager.heartSendState {
            case .idle: return nil
            case .connecting(let name): return "Connecting to \(name)…"
            case .verifying(let name): return "Saying hello to \(name)…"
            case .sent(let name): return "Sent \(name) some good vibes."
            case .failed(let message): return message
            }
        }
    }

    /// TF b19 item 5 tier 1: adopt the actionable `needsPresence` affordance (mirroring FriendListView)
    /// only where the presence path still applies — i.e. a session friend on an OLDER build who can't
    /// receive a mesh heart, while hearts are on but the Nearby Friends (presence) radio is off. In the
    /// common case (both peers updated) hearts ride the mesh and need no presence, so this stays hidden.
    private var sessionHeartsNeedPresence: Bool {
        guard store.settings.allowNearbyHearts, !store.settings.allowNearbyPresence else { return false }
        return manager.sessionParticipants.contains { participant in
            guard !participant.isLocal, let friend = trustedFriend(for: participant) else { return false }
            return !manager.canSendSessionHeart(toFingerprint: friend.fingerprint)
        }
    }

    private func sessionHeartForeground(for state: SendGoodVibesLabel.SendState) -> Color {
        switch state {
        case .ready, .sending: Color.terracotta
        case .cooldown: Color.terracotta.opacity(0.7)
        case .notNearby: Color.bark.opacity(0.35)
        }
    }

    private func sessionHeartBackground(for state: SendGoodVibesLabel.SendState) -> Color {
        switch state {
        case .ready, .sending: Color.terracotta.opacity(0.14)
        case .cooldown: Color.dustyRose.opacity(0.16)
        case .notNearby: Color.bark.opacity(0.06)
        }
    }

    // MARK: - Incoming message signal (TF b19 item 6)

    /// An inbound message arrived while the chat sheet was closed. While the app is active, a light
    /// notification haptic is the reliable in-app nudge (the dot badge on the chat button is already
    /// showing). While it isn't active, fire a best-effort local notification instead — Multipeer
    /// Connectivity usually suspends in the background, so this rarely reaches us there, but we fire it
    /// if it does. Never fires while the chat sheet is open (the store doesn't count those as unread).
    private func handleUnreadMessageArrival() {
        switch scenePhase {
        case .active:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        default:
            postSessionMessageNotification()
        }
    }

    private func postSessionMessageNotification() {
        // The most recent inbound message drives the notification's sender name. It was already
        // sanitized by SessionMessageStore.receiveIncoming; NotificationService re-sanitizes defensively.
        guard let latest = manager.sessionMessages.messages.last(where: { !$0.isOutgoing }) else { return }
        // R3: one in-flight post at a time. Peers drive this event, so an unbounded Task per inbound
        // message would be peer-controlled fan-out; the notification is a nudge, not a log, so
        // coalescing to the newest sender while one is posting is the right bound.
        guard messageNotificationTask == nil else { return }
        let name = latest.senderDisplayName
        messageNotificationTask = Task {
            await NotificationService.postSessionMessage(from: name)
            messageNotificationTask = nil
        }
    }

    private var renameMeshSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text("Rename session")
                            .font(.fernlet(.displayMedium))
                            .foregroundStyle(Color.bark)

                        SheetField("New name") {
                            TextField("Session name", text: Binding(
                                get: { newMeshName },
                                set: { newMeshName = String($0.prefix(Self.maxMeshNameLength)) }
                            ))
                            .sheetTextInput()
                            .accessibilityIdentifier("sessionInfo.renameField")
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 10)
                }

                SheetSaveBar(
                    label: "Rename",
                    disabled: newMeshName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    // R3/R5: the name is broadcast to every peer in the mesh descriptor, so it is
                    // bounded here as well as at the field (the advertised copy caps separately).
                    let trimmed = String(newMeshName.trimmingCharacters(in: .whitespacesAndNewlines)
                        .prefix(Self.maxMeshNameLength))
                    guard !trimmed.isEmpty else { return }
                    manager.renameMesh(trimmed)
                    renamingMesh = false
                }
            }
            .background(Color.parchment)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { renamingMesh = false }
                        .foregroundStyle(Color.slate)
                }
            }
        }
    }

    private func presentNextRemovalProposalIfNeeded() {
        guard activeRemovalProposal == nil else { return }
        activeRemovalProposal = manager.pendingRemovalProposals.last {
            $0.proposerFingerprint != manager.localFingerprint
        }
    }
}

/// The session's interruptive prompts, lifted out of ``DisposableCameraView``'s `body` (R4).
///
/// Applied as one modifier so the ordering of the admission sheet, the mesh-error alert, the
/// removal-proposal alert and the end-session confirmation is identical to the inline version it
/// replaced. State stays in the view; this only presents it.
private struct SessionPromptsModifier: ViewModifier {
    let manager: MeshNetworkManager
    @Binding var activeRemovalProposal: MeshRemovalProposalPayload?
    @Binding var leaveSessionConfirm: Bool
    @Binding var showInfo: Bool
    let beginDevelop: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { !manager.pendingAdmissionRequests.isEmpty && manager.currentMesh != nil },
                set: { isPresented in
                    if !isPresented {
                        manager.pendingAdmissionRequests.forEach { manager.declineAdmission($0) }
                    }
                }
            )) {
                admissionSheet
            }
            .alert("Session", isPresented: Binding(
                get: { manager.meshError != nil },
                set: { if !$0 { manager.meshError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(manager.meshError ?? "")
            }
            .modifier(SessionRemovalPromptsModifier(
                manager: manager,
                activeRemovalProposal: $activeRemovalProposal,
                leaveSessionConfirm: $leaveSessionConfirm,
                showInfo: $showInfo,
                beginDevelop: beginDevelop
            ))
    }

    /// The pending join requests for the current mesh.
    @ViewBuilder
    private var admissionSheet: some View {
        if let mesh = manager.currentMesh {
            JoinPromptSheet(
                requests: manager.pendingAdmissionRequests,
                targetName: mesh.name,
                displayName: { $0.requesterDisplayName },
                fingerprint: { $0.requesterFingerprint },
                accessibilityPrefix: "mesh.admission",
                allow: { manager.allowAdmission($0) },
                decline: { manager.declineAdmission($0) }
            )
        }
    }
}

/// The two destructive session prompts: seconding a removal proposal, and ending the session.
private struct SessionRemovalPromptsModifier: ViewModifier {
    let manager: MeshNetworkManager
    @Binding var activeRemovalProposal: MeshRemovalProposalPayload?
    @Binding var leaveSessionConfirm: Bool
    @Binding var showInfo: Bool
    let beginDevelop: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                activeRemovalProposal.map { "Remove \($0.targetDisplayName)?" } ?? "Remove participant?",
                isPresented: $activeRemovalProposal.isPresent(),
                presenting: activeRemovalProposal
            ) { proposal in
                if manager.canSecondRemoval(proposal) {
                    Button("Second Removal", role: .destructive) {
                        manager.secondRemoval(proposal)
                        activeRemovalProposal = nil
                    }
                }
                Button("Not Now", role: .cancel) {
                    activeRemovalProposal = nil
                }
            } message: { proposal in
                Text("\(proposal.proposerDisplayName) asked to remove \(proposal.targetDisplayName) from this session. A different participant must second the decision.")
            }
            .alert("End session?", isPresented: $leaveSessionConfirm) {
                Button("End Session", role: .destructive) {
                    showInfo = false
                    beginDevelop()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You will stop sharing with everyone in this session.")
            }
    }
}
