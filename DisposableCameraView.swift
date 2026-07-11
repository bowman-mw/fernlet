import SwiftUI
import AVFoundation
import UIKit
import FernletDomainModel
import ProximityKit

// MARK: - Camera preview (UIViewRepresentable)

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.configureRotation()
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.updateRotation()
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: ()) {
        uiView.tearDown()
    }

    final class PreviewView: UIView {
        private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var rotationObservation: NSKeyValueObservation?

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        func configureRotation() {
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
            previewLayer.session = nil
        }

        func updateRotation() {
            guard let connection = previewLayer.connection,
                  let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelPreview,
                  connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }
    }
}

// MARK: - Camera capture controller

/// Manages AVCaptureSession lifecycle and the arm/wind gate state machine.
/// The arm/wind/disarm logic is independent of AVFoundation and fully testable.
@Observable
final class CameraCaptureController: NSObject {
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

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private var captureRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var captureRotationObservation: NSKeyValueObservation?
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "com.fernlet.disposable-camera.session")
    @ObservationIgnored private var shouldRunSession = false
    @ObservationIgnored private var sessionConfiguredOnQueue = false
    // Set on main actor before capture; consumed once on AVFoundation queue.
    // Single-flight guarantee (shutter disarms before capturePhoto returns) prevents races.
    @ObservationIgnored nonisolated(unsafe) private var captureCompletion: CheckedContinuation<Data, Error>?

    override init() {
        super.init()
    }

    // MARK: Session lifecycle

    private func configureSessionIfNeeded() -> Bool {
        guard !sessionConfiguredOnQueue else { return true }
        session.beginConfiguration()
        session.sessionPreset = .photo
        defer { session.commitConfiguration() }

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input),
            session.canAddOutput(photoOutput)
        else {
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

    func resetWind() {
        if !isArmed { windProgress = 0 }
    }

    func disarm() {
        isArmed = false
        windProgress = 0
    }

    // MARK: Capture

    func capturePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { [weak self] cont in
            guard let self else {
                cont.resume(throwing: CocoaError(.fileNoSuchFile))
                return
            }
            guard captureCompletion == nil else {
                cont.resume(throwing: CaptureError.captureInProgress)
                return
            }
            guard canCapturePhoto, photoOutput.connection(with: .video) != nil else {
                cont.resume(throwing: CaptureError.cameraUnavailable)
                return
            }

            captureCompletion = cont
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
        let cont = captureCompletion
        captureCompletion = nil
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
    var openCenterY: CGFloat { topInset + topGap + openSize.height / 2 }

    var centerX: CGFloat { screenWidth / 2 }

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

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
}

// MARK: - Disposable camera view

struct DisposableCameraView: View {
    var store: FernletStore

    @State private var camera = CameraCaptureController()
    @State private var flashOpacity: Double = 0
    @State private var showInfo = false
    @State private var reviewPresented = false
    @State private var selectedForSave: Set<UUID> = []
    @State private var photoSaveError: String? = nil
    @State private var activeRemovalProposal: MeshRemovalProposalPayload?
    @State private var previousWindTranslation: CGFloat = 0
    @State private var renamingMesh = false
    @State private var newMeshName = ""
    @State private var leaveSessionConfirm = false

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
            let isLandscape = geometry.size.width > geometry.size.height
            ZStack {
                Color(red: 0.13, green: 0.10, blue: 0.08)
                    .ignoresSafeArea()
                    .overlay {
                        // Portrait: the viewfinder grows out of the Dynamic Island as the camera is
                        // wound (openness = armed ? 1 : windProgress) and retracts into it after a shot.
                        // Landscape keeps the centered framed preview — the island is on the long edge
                        // there, so a top-anchored animation doesn't apply.
                        if !isLandscape {
                            islandViewfinder(
                                metrics: IslandViewfinderMetrics(
                                    topInset: geometry.safeAreaInsets.top,
                                    screenWidth: geometry.size.width
                                )
                            )
                        }
                    }

                if isLandscape {
                    viewfinderArea
                        .padding(.horizontal, 22)
                        .padding(.vertical, 18)
                }

                infoButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(20)

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
            .onAppear { updateLandscapeState(isLandscape) }
            .onChange(of: isLandscape) { _, newValue in
                updateLandscapeState(newValue)
            }
        }
        .onAppear { camera.startSession() }
        .onDisappear {
            camera.stopSession()
            store.isDisposableCameraLandscape = false
        }
        .onChange(of: manager.pendingRemovalProposals) { _, _ in
            presentNextRemovalProposalIfNeeded()
        }
        .sheet(isPresented: $reviewPresented, onDismiss: resumeCameraAfterCancelledReview) { reviewSheet }
        .sheet(isPresented: $showInfo) { infoSheet }
        .sheet(isPresented: Binding(
            get: { !manager.pendingAdmissionRequests.isEmpty && manager.currentMesh != nil },
            set: { isPresented in
                if !isPresented {
                    manager.pendingAdmissionRequests.forEach { manager.declineAdmission($0) }
                }
            }
        )) {
            if let mesh = manager.currentMesh {
                MeshAdmissionPromptSheet(
                    requests: manager.pendingAdmissionRequests,
                    meshName: mesh.name,
                    allow: { manager.allowAdmission($0) },
                    decline: { manager.declineAdmission($0) }
                )
            }
        }
        .alert("Session", isPresented: Binding(
            get: { manager.meshError != nil },
            set: { if !$0 { manager.meshError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(manager.meshError ?? "")
        }
        .alert(
            activeRemovalProposal.map { "Remove \($0.targetDisplayName)?" } ?? "Remove participant?",
            isPresented: Binding(
                get: { activeRemovalProposal != nil },
                set: { if !$0 { activeRemovalProposal = nil } }
            ),
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

    private var infoButton: some View {
        Button { showInfo = true } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 18))
                .foregroundStyle(Color.white.opacity(0.5))
        }
        .accessibilityIdentifier("camera.info")
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
        ZStack {
            HStack(spacing: 12) {
                filmCounterBadge
                windIndicator(isLandscape: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(18)

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

    /// Portrait viewfinder that grows out of the Dynamic Island as the camera is wound. `openness`
    /// tracks the wind: 0 while unwound (a black pill sitting where the island is), 1 once armed
    /// (fully-open square). Winding animates it open; `disarm()` after a shot animates it back into
    /// the island. Purely presentational — the wind gesture lives on the thumbwheel control.
    private func islandViewfinder(metrics: IslandViewfinderMetrics) -> some View {
        let openness = camera.isArmed ? 1.0 : camera.windProgress
        let frame = metrics.frame(openness: openness)
        // Hide the squished preview while the housing is still island-sized; fade it in as it opens.
        let previewOpacity = max(0, min((openness - 0.3) / 0.6, 1))
        // The live-preview square is inset from the near-black housing shell; the LED rides in the
        // gap above it. Track the mockup's ~14pt shell / 30pt top gap, scaled down with openness so
        // the inset never swallows the housing while it's still island-sized.
        let shellInset: CGFloat = 13 * openness + 2
        let ledGap: CGFloat = 30 * openness + 4
        let showsPermissionPrompt = camera.needsCameraPermissionPrompt && openness > 0.85

        return RoundedRectangle(cornerRadius: frame.cornerRadius, style: .continuous)
            .fill(Self.housingBlack)
            .shadow(color: Color.black.opacity(0.55), radius: 16, y: 12)
            .overlay {
                // Live-preview window, inset inside the housing shell and pushed below the LED.
                ZStack {
                    CameraPreviewView(session: camera.session)
                        .opacity(previewOpacity)
                    islandViewfinderReticle
                        .opacity(previewOpacity)
                }
                .clipShape(
                    RoundedRectangle(cornerRadius: max(3, frame.cornerRadius - shellInset), style: .continuous)
                )
                .padding(.top, ledGap)
                .padding([.horizontal, .bottom], shellInset)
            }
            .overlay(alignment: .top) {
                islandCameraLED(openness: openness)
                    .padding(.top, ledGap * 0.4 + 3)
            }
            // The housing, preview, and LED are decorative: flattened for VoiceOver and kept out
            // of hit testing (the wind gesture lives on the thumbwheel control).
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(camera.isArmed ? "Viewfinder ready" : "Wind to open the viewfinder")
            .accessibilityHidden(showsPermissionPrompt)
            // The permission prompt is real UI, so it layers after the decorative flattening —
            // its Open Settings button stays tappable and VoiceOver-reachable.
            .overlay {
                if showsPermissionPrompt {
                    cameraPermissionPrompt
                        .clipShape(
                            RoundedRectangle(cornerRadius: max(3, frame.cornerRadius - shellInset), style: .continuous)
                        )
                        .padding(.top, ledGap)
                        .padding([.horizontal, .bottom], shellInset)
                }
            }
            .frame(width: frame.size.width, height: frame.size.height)
            .position(x: metrics.centerX, y: frame.centerY)
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: openness)
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

    private var viewfinderArea: some View {
        ZStack {
            CameraPreviewView(session: camera.session)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            viewfinderBrackets
            if camera.needsCameraPermissionPrompt {
                cameraPermissionPrompt
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
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
        Button { beginDevelop() } label: {
            VStack(spacing: 5) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.white.opacity(0.65))
                Text("Develop")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.white.opacity(0.5))
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

    private func updateLandscapeState(_ isLandscape: Bool) {
        store.isDisposableCameraLandscape = isLandscape
        previousWindTranslation = 0
        if !isLandscape {
            camera.resetWind()
        }
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
            Task { await manager.leaveSessionAfterNotifyingPeers() }
        } else {
            selectedForSave = Set(manager.sessionPhotos.map(\.id))
            reviewPresented = true
        }
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
            saveSelected: {
                let toSave = manager.sessionPhotos.filter { selectedForSave.contains($0.id) }
                do {
                    try await FriendPhotoLibrarySaver.save(toSave)
                    manager.finishSessionPhotos(keeping: selectedForSave)
                    await manager.leaveSessionAfterNotifyingPeers()
                    reviewPresented = false
                } catch CocoaError.userCancelled {
                    photoSaveError = "Fernlet needs access to your Photo Library to save photos. Open Settings to grant access."
                } catch {
                    photoSaveError = "Could not save to your photo library. Please try again."
                }
            },
            discardAll: {
                manager.deleteAllSessionPhotos()
                Task {
                    await manager.leaveSessionAfterNotifyingPeers()
                    reviewPresented = false
                }
            }
        )
        .alert("Couldn't Save Photos", isPresented: Binding(
            get: { photoSaveError != nil },
            set: { if !$0 { photoSaveError = nil } }
        )) {
            if photoSaveError?.contains("Settings") == true {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                    photoSaveError = nil
                }
            }
            Button("OK", role: .cancel) { photoSaveError = nil }
        } message: {
            Text(photoSaveError ?? "")
        }
    }

    // MARK: - Info sheet

    @ViewBuilder
    private var infoSheet: some View {
        ZStack {
            Color.parchment
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
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

                    Text("\(manager.sessionParticipants.count) person(s) connected")
                        .font(.fernlet(.bubble))
                        .foregroundStyle(Color.slate)

                    HStack(spacing: 6) {
                        Image(systemName: "film")
                            .foregroundStyle(Color.slate)
                        Text("\(manager.filmRemaining) shot(s) remaining")
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.slate)
                    }

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

                    Text("People")
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)

                    VStack(spacing: 0) {
                        ForEach(manager.sessionParticipants) { participant in
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
                                    Menu {
                                        Button {
                                            manager.proposeRemoval(of: participant)
                                        } label: {
                                            Label("Ask to remove", systemImage: "person.badge.minus")
                                        }
                                        Button(role: .destructive) {
                                            manager.block(participant)
                                        } label: {
                                            Label("Block", systemImage: "hand.raised")
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                            .foregroundStyle(Color.slate)
                                    }
                                    .accessibilityLabel("Options for \(participant.displayName)")
                                }
                            }
                            .padding(.vertical, 13)
                            .padding(.horizontal, 14)
                            if participant.id != manager.sessionParticipants.last?.id {
                                FernletRowDivider()
                            }
                        }
                    }
                    .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))

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

                    if !manager.pendingRemovalProposals.isEmpty {
                        Text("Removal Requests")
                            .font(.fernlet(.header))
                            .foregroundStyle(Color.bark)

                        ForEach(manager.pendingRemovalProposals) { proposal in
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
                    }

                    Button("End session") {
                        leaveSessionConfirm = true
                    }
                    .buttonStyle(ChipButtonStyle(selected: false))
                    .accessibilityIdentifier("sessionInfo.endSession")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
        .sheet(isPresented: $renamingMesh) {
            renameMeshSheet
        }
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

    /// A quiet one-tap heart beside a connected friend. Enabled only while today's heart to them
    /// is unsent AND they are reachable on a live heart connection; no counts shown anywhere.
    /// A filled heart marks "already sent today" — a state, never a number.
    private func sessionHeartButton(for friend: ProximityTrustedPeerRecord) -> some View {
        let alreadySentToday = !store.heartLedger.canSendHeart(to: friend.fingerprint)
        let reachable = store.heartShareManager.isReachable(fingerprint: friend.fingerprint)
        let firstName = ProximityHeartManager.firstName(of: friend.displayName)
        let state = SendGoodVibesLabel.state(alreadySentToday: alreadySentToday, reachable: reachable)
        return Button {
            store.heartShareManager.sendHeart(to: friend)
        } label: {
            // Compact in-row form of the "Send good vibes" affordance (good-vibes 10c): a
            // dusty-rose/terracotta heart when ready, a soft-filled check once sent, muted apart.
            Image(systemName: state == .sent ? "checkmark" : "heart.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(sessionHeartForeground(for: state))
                .frame(width: 30, height: 30)
                .background(sessionHeartBackground(for: state), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(alreadySentToday || !reachable)
        .accessibilityLabel(
            alreadySentToday
                ? "You've already sent \(firstName) some warmth today."
                : reachable
                    ? "Send good vibes to \(friend.displayName)"
                    : "Hearts travel in person for now."
        )
    }

    private func sessionHeartForeground(for state: SendGoodVibesLabel.SendState) -> Color {
        switch state {
        case .ready: Color.terracotta
        case .sent: Color.terracotta.opacity(0.7)
        case .notNearby: Color.bark.opacity(0.35)
        }
    }

    private func sessionHeartBackground(for state: SendGoodVibesLabel.SendState) -> Color {
        switch state {
        case .ready: Color.terracotta.opacity(0.14)
        case .sent: Color.dustyRose.opacity(0.16)
        case .notNearby: Color.bark.opacity(0.06)
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
                            TextField("Session name", text: $newMeshName)
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
                    let trimmed = newMeshName.trimmingCharacters(in: .whitespacesAndNewlines)
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
