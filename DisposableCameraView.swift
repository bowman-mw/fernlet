import SwiftUI
import AVFoundation
import UIKit

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
    private(set) var isArmed: Bool = true
    private(set) var windProgress: Double = 0  // 0.0 (unwound) → 1.0 (ready to arm)

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private var captureRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var captureRotationObservation: NSKeyValueObservation?
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "com.fernlet.disposable-camera.session")
    @ObservationIgnored private var shouldRunSession = false
    // Set on main actor before capture; consumed once on AVFoundation queue.
    // Single-flight guarantee (shutter disarms before capturePhoto returns) prevents races.
    @ObservationIgnored nonisolated(unsafe) private var captureCompletion: CheckedContinuation<Data, Error>?

    override init() {
        super.init()
        configureSession()
    }

    // MARK: Session lifecycle

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device)
        else {
            session.commitConfiguration()
            return
        }
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        session.commitConfiguration()

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        captureRotationCoordinator = coordinator
        captureRotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] _, _ in
            self?.updateCaptureRotation()
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
            guard !session.isRunning else { return }

            Task { [weak self] in
                guard let self else { return }
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                sessionQueue.async { [weak self] in
                    guard let self, granted, shouldRunSession, !session.isRunning else { return }
                    session.startRunning()
                }
            }
        }
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

// MARK: - Disposable camera view

struct DisposableCameraView: View {
    var store: FernletStore

    @State private var camera = CameraCaptureController()
    @State private var showInfo = false
    @State private var reviewPresented = false
    @State private var selectedForSave: Set<UUID> = []
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
                Color(red: 0.13, green: 0.10, blue: 0.08).ignoresSafeArea()

                viewfinderArea
                    .padding(.horizontal, 22)
                    .padding(.vertical, isLandscape ? 18 : 28)

                infoButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(20)

                if isLandscape {
                    landscapeControls
                } else {
                    portraitControls
                }
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
            set: { _ in }
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
        .foregroundStyle(manager.filmRemaining > 0 ? Color.yellow : Color.red)
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

    private var viewfinderArea: some View {
        ZStack {
            CameraPreviewView(session: camera.session)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            viewfinderBrackets
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
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
        let canShoot = camera.isArmed && manager.filmRemaining > 0
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
                        .foregroundStyle(Color.red.opacity(0.7))
                }
            }
        }
        .disabled(!canShoot)
        .scaleEffect(canShoot ? 1.0 : 0.9)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: canShoot)
        .accessibilityLabel(canShoot ? "Take photo" :
            manager.filmRemaining == 0 ? "No film remaining" : "Wind camera first")
        .accessibilityIdentifier("camera.shutter")
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
        guard camera.isArmed, manager.filmRemaining > 0 else { return }
        camera.disarm()
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        guard let data = try? await camera.capturePhoto() else { return }
        manager.addPhoto(data)
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
                try? await FriendPhotoLibrarySaver.save(toSave)
                manager.finishSessionPhotos(keeping: selectedForSave)
                await manager.leaveSessionAfterNotifyingPeers()
                reviewPresented = false
            },
            discardAll: {
                manager.deleteAllSessionPhotos()
                Task {
                    await manager.leaveSessionAfterNotifyingPeers()
                    reviewPresented = false
                }
            }
        )
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
