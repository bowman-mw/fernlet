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
                .font(.system(size: 15, weight: .bold, design: .monospaced))
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
        let previewInset: CGFloat = 5

        return RoundedRectangle(cornerRadius: frame.cornerRadius, style: .continuous)
            .fill(Color.black)
            .overlay {
                ZStack {
                    CameraPreviewView(session: camera.session)
                        .opacity(previewOpacity)
                    if camera.needsCameraPermissionPrompt && openness > 0.85 {
                        cameraPermissionPrompt
                    }
                }
                .padding(previewInset)
                .clipShape(
                    RoundedRectangle(cornerRadius: max(2, frame.cornerRadius - previewInset), style: .continuous)
                )
            }
            .overlay(alignment: .top) {
                // The classic "camera on" green LED, riding at the top of the housing.
                Circle()
                    .fill(Color(red: 0.36, green: 0.85, blue: 0.42))
                    .frame(width: 7, height: 7)
                    .shadow(color: Color.green.opacity(0.7), radius: 3)
                    .opacity(camera.isArmed ? 1 : previewOpacity)
                    .padding(.top, 7)
            }
            .frame(width: frame.size.width, height: frame.size.height)
            .position(x: metrics.centerX, y: frame.centerY)
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: openness)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(camera.isArmed ? "Viewfinder ready" : "Wind to open the viewfinder")
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
        VStack(spacing: 10) {
            Image(systemName: "camera.fill")
                .font(.system(size: 26, weight: .semibold))
            Text("Camera access needed")
                .font(.system(size: 16, weight: .semibold))
            Button("Open Settings") {
                openAppSettings()
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("camera.permissionPrompt")
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var viewfinderBrackets: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let len: CGFloat = 18, t: CGFloat = 2
            let c = Color.white.opacity(0.45)
            ZStack {
                // top-left
                rect(c, w: len, h: t).position(x: len / 2, y: t / 2)
                rect(c, w: t, h: len).position(x: t / 2, y: len / 2)
                // top-right
                rect(c, w: len, h: t).position(x: w - len / 2, y: t / 2)
                rect(c, w: t, h: len).position(x: w - t / 2, y: len / 2)
                // bottom-left
                rect(c, w: len, h: t).position(x: len / 2, y: h - t / 2)
                rect(c, w: t, h: len).position(x: t / 2, y: h - len / 2)
                // bottom-right
                rect(c, w: len, h: t).position(x: w - len / 2, y: h - t / 2)
                rect(c, w: t, h: len).position(x: w - t / 2, y: h - len / 2)
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
                    .font(.system(size: 11))
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
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.45), lineWidth: 3)
                    .frame(width: 82, height: 82)
                Circle()
                    .fill(canShoot ? Color.white : Color.white.opacity(0.2))
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
        }
        .disabled(!canShoot)
        .scaleEffect(canShoot ? 1.0 : 0.9)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: canShoot)
        .accessibilityLabel(shutterAccessibilityLabel(canShoot: canShoot))
        .accessibilityIdentifier("camera.shutter")
    }

    private func shutterAccessibilityLabel(canShoot: Bool) -> String {
        if canShoot { return "Take photo" }
        if manager.filmRemaining == 0 { return "No film remaining" }
        if !camera.canCapturePhoto { return "Camera unavailable" }
        return "Wind camera first"
    }

    private func windIndicator(isLandscape: Bool) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(
                        Color.white.opacity(0.24),
                        style: StrokeStyle(lineWidth: 5, dash: [5, 4])
                    )
                    .frame(width: 52, height: 52)
                    .rotationEffect(.degrees(camera.windProgress * 360))
                    .offset(y: -8)
                Circle()
                    .stroke(Color.white.opacity(0.5), lineWidth: 2)
                    .frame(width: 36, height: 36)
                    .rotationEffect(.degrees(camera.windProgress * 360))
                    .offset(y: -8)
            }
            .frame(width: 58, height: 20, alignment: .bottom)
            .clipped()
            Text(camera.isArmed ? "Ready" : isLandscape ? "Swipe →" : "Slide ↓")
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .frame(width: 66, height: 48)
        .contentShape(Rectangle())
        .gesture(windGesture(isLandscape: isLandscape))
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
                                        .font(.system(size: 32, weight: .bold, design: .serif))
                                    Image(systemName: "pencil")
                                        .font(.body)
                                }
                                .foregroundStyle(Color.bark)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("sessionInfo.rename")
                        } else {
                            Text("Session")
                                .font(.system(size: 32, weight: .bold, design: .serif))
                                .foregroundStyle(Color.bark)
                        }
                        Spacer()
                        Button("Done") { showInfo = false }
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.bark)
                            .buttonStyle(.plain)
                    }

                    Text("\(manager.sessionParticipants.count) person(s) connected")
                        .font(.callout.italic())
                        .foregroundStyle(Color.slate)

                    HStack(spacing: 6) {
                        Image(systemName: "film")
                            .foregroundStyle(Color.slate)
                        Text("\(manager.filmRemaining) shot(s) remaining")
                            .font(.callout)
                            .foregroundStyle(Color.slate)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Session access")
                            .font(.headline)
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
                        .font(.headline)
                        .foregroundStyle(Color.bark)

                    VStack(spacing: 0) {
                        ForEach(manager.sessionParticipants) { participant in
                            HStack(spacing: 12) {
                                Image(systemName: participant.isLocal ? "person.crop.circle.fill" : "person.crop.circle")
                                    .foregroundStyle(Color.moss)
                                Text(participant.displayName)
                                    .font(.body)
                                    .foregroundStyle(Color.bark)
                                if !participant.isLocal, let vouchLabel = manager.vouchLabel(for: participant.fingerprint) {
                                    Text(vouchLabel)
                                        .font(.caption)
                                        .foregroundStyle(Color.slate)
                                }
                                if participant.isLocal {
                                    Text("You")
                                        .font(.caption.weight(.semibold))
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
                                    .font(.body.weight(.medium))
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
                            .font(.headline)
                            .foregroundStyle(Color.bark)

                        ForEach(manager.pendingRemovalProposals) { proposal in
                            VStack(alignment: .leading, spacing: 10) {
                                Text("\(proposal.proposerDisplayName) asked to remove \(proposal.targetDisplayName).")
                                    .font(.callout)
                                    .foregroundStyle(Color.bark)
                                if manager.canSecondRemoval(proposal) {
                                    Button("Second Removal", role: .destructive) {
                                        manager.secondRemoval(proposal)
                                    }
                                    .font(.callout.weight(.semibold))
                                } else {
                                    Text("Waiting for another participant to second this decision.")
                                        .font(.caption)
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
                            .font(.system(size: 28, weight: .bold, design: .serif))
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
