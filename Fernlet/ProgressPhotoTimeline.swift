#if canImport(UIKit)
import SwiftUI
import PrivateMediaStore
import FernletLock

/// The gym progress-photo timeline that lives under the Move tab (#11 piece 3). A private, at-rest-sealed
/// strip of the user's own body photos, newest first, with an add affordance and a tap-through to a
/// detail view for each. Body photos, so nothing here decodes a picture until it scrolls into view, and
/// the whole store (bytes + dates + captions) is sealed — see `ProgressPhotoStore`.
struct ProgressPhotoSection: View {
    var records: [ProgressPhotoRecord]
    /// Loads a photo's sealed bytes on demand (off `FernletStore.progressPhotoData`).
    var loadData: (UUID) -> Data?
    /// A freshly *captured* photo (live camera). The parent seals it and refreshes `records`.
    var onCapture: (UIImage) -> Void
    /// A *library* pick delivered as raw JPEG `Data` plus a best-effort creation date, so the parent seals
    /// it through the bounded Data path (no full-res bitmap) and stamps the recovered date rather than "now".
    var onCaptureData: (Data, Date?) -> Void
    /// A library pick whose bytes failed to load (iCloud eviction, transfer error) — surfaced so the
    /// parent can show its "couldn't save this photo" feedback instead of the pick vanishing silently.
    var onCaptureFailed: () -> Void = {}
    var onOpen: (ProgressPhotoRecord) -> Void

    // Body photos are as personal as journal/cycle/intimacy, so — when a Fernlet lock is configured —
    // the timeline reveals behind the SAME global lock as the Private Hub (fail-closed at the reveal
    // seam: no thumbnail decodes until unlocked). With no lock configured the section behaves exactly as
    // before, keeping the capture affordance discoverable.
    @Environment(FernletLockService.self) private var lockService
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingUnlock = false
    // Set just before pushing the detail so the re-lock-on-disappear doesn't fire during the push (which
    // would make the also-gated detail re-prompt). Reset on re-appear.
    @State private var isOpeningDetail = false
    // Set while the section's OWN capture UI is up (the full-screen camera cover / library picker).
    // The camera cover fires onDisappear on the hierarchy it covers, so without this the re-lock fired
    // MID-CAPTURE and the fresh photo landed behind the unlock prompt (the library sheet path never
    // did — sheets don't fire onDisappear — which is how we know the re-lock was unintended).
    @State private var isCapturing = false
    // Scene-transition suppression, mirroring FernletLockGateModifier (see its header comment): Face ID
    // bounces the scene inactive→active, and on this page-style TabView that can fire a spurious
    // onDisappear right after a successful unlock — re-locking the strip the user just revealed. A
    // genuine departure during the settle window is only DEFERRED (pendingRelock), never dropped.
    @State private var suppressRelock = false
    @State private var suppressRelockTask: Task<Void, Never>?
    @State private var pendingRelock = false
    @State private var sectionIsVisible = false

    private var gateActive: Bool {
        lockService.isLockConfigured && !UITestSupport.bypassPrivateLockGate
    }

    private var isUnlocked: Bool {
        if case .unlocked = lockService.state { return true }
        return false
    }

    /// Whether the real photos may be shown. Gated behind the global lock when configured.
    private var isRevealed: Bool { !gateActive || isUnlocked }

    /// Hide the app-switcher snapshot of body photos while the app isn't frontmost.
    private var redactForSnapshot: Bool { scenePhase != .active }

    var body: some View {
        FernletScrollSection("Progress photos") {
            if isRevealed {
                revealedContent
            } else {
                lockedPlaceholder
            }
        }
        .onAppear {
            sectionIsVisible = true
            pendingRelock = false
            isOpeningDetail = false
        }
        .onDisappear {
            sectionIsVisible = false
            reLockOnDisappear()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .inactive:
                suppressRelockTask?.cancel()
                suppressRelock = true
            case .active:
                // Keep suppression briefly after returning to foreground so any spurious
                // onDisappear/onAppear lifecycle events from the transition settle (same window as
                // FernletLockGateModifier).
                suppressRelockTask?.cancel()
                suppressRelockTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1500))
                    suppressRelock = false
                    // Execute a deferred genuine-departure lock if the section hasn't re-appeared.
                    if pendingRelock && !sectionIsVisible && !isCapturing {
                        pendingRelock = false
                        if case .unlocked = lockService.state {
                            lockService.lock(reason: .viewDisappeared)
                        }
                    }
                }
            default:
                break
            }
        }
        .sheet(isPresented: $showingUnlock) {
            ProgressPhotoUnlockSheet(lockService: lockService)
        }
    }

    @ViewBuilder private var revealedContent: some View {
        if records.isEmpty {
            VStack(spacing: 16) {
                EmptyState(text: "See how you're changing. Add a progress photo and it'll build a private timeline here — sealed on your device.")
                PhotoCaptureControl(
                    onCameraCapture: onCapture,
                    onLibraryPickData: onCaptureData,
                    onLibraryPickFailed: onCaptureFailed,
                    onCaptureUIPresentationChange: { isCapturing = $0 },
                    allowsLibraryChoice: true
                ) {
                    addLabel(prominent: true)
                }
                .accessibilityIdentifier("move.progressPhotos.addFirst")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    PhotoCaptureControl(
                        onCameraCapture: onCapture,
                        onLibraryPickData: onCaptureData,
                        onLibraryPickFailed: onCaptureFailed,
                        onCaptureUIPresentationChange: { isCapturing = $0 },
                        allowsLibraryChoice: true
                    ) {
                        addTile
                    }
                    .accessibilityIdentifier("move.progressPhotos.add")
                    ForEach(records) { record in
                        Button {
                            isOpeningDetail = true
                            onOpen(record)
                        } label: {
                            ProgressPhotoCard(record: record, loadData: { loadData(record.id) })
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
            }
            .accessibilityIdentifier("move.progressPhotos")
            // Opaque cover over the thumbnails while backgrounded so the app-switcher snapshot can't
            // leak body photos (belt-and-suspenders with the reveal gate, which only guards decoding).
            .overlay {
                if redactForSnapshot { snapshotCover }
            }
        }
    }

    /// Shown when a Fernlet lock is configured and the app is locked: a calm placeholder with a
    /// tap-to-unlock, so nobody handed the unlocked phone can scroll the body-photo timeline.
    private var lockedPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color.moss)
            Text("Your progress photos are private")
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
            Text("These body photos sit behind your Fernlet lock. Unlock to see your timeline.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
            Button {
                showingUnlock = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "lock.open.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Unlock to view")
                        .font(.fernlet(.label))
                }
                .foregroundStyle(Color.cream)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color.moss, in: Capsule())
                .fernletSmallShadow()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("move.progressPhotos.unlock")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// Opaque privacy cover used to redact the timeline in the app-switcher snapshot.
    private var snapshotCover: some View {
        ZStack {
            Rectangle().fill(Color.parchment)
            VStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.slate)
                Text("Hidden")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
            }
        }
    }

    /// Re-lock the global lock when the timeline goes away (tab switch / leaving), matching the Private
    /// Hub's "re-lock on disappear". Suppressed while pushing the detail (which is separately gated) so
    /// the push doesn't force a second unlock prompt, while the section's own capture UI covers it
    /// (the camera cover fires onDisappear on what it covers), and during scene-transition settle
    /// (deferred, not dropped — see the `suppressRelock` machinery above). Presenting the unlock sheet
    /// does NOT fire onDisappear, so it never re-locks mid-unlock; backgrounding is centrally covered by
    /// the app-level `.background` lock in `FernletApp`.
    private func reLockOnDisappear() {
        guard gateActive, !isOpeningDetail, !isCapturing else { return }
        guard !lockService.isPerformingBiometricUnlock else { return }
        guard case .unlocked = lockService.state else { return }
        if suppressRelock {
            pendingRelock = true
        } else {
            lockService.lock(reason: .viewDisappeared)
        }
    }

    private func addLabel(prominent: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.fill")
                .font(.system(size: 16, weight: .semibold))
            Text("Add progress photo")
                .font(.fernlet(.label))
        }
        .foregroundStyle(Color.cream)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.moss, in: Capsule())
        .fernletSmallShadow()
    }

    /// The leading "＋" tile in the populated strip — same footprint as a photo card.
    private var addTile: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.moss.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .frame(width: 132, height: 168)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 22, weight: .semibold))
                        Text("Add")
                            .font(.fernlet(.label))
                    }
                    .foregroundStyle(Color.moss)
                }
            Text(" ")
                .font(.fernlet(.labelSmall))
                .hidden()
        }
    }
}

/// A calm sheet that runs the app's real unlock flow (`FernletLockView`) so revealing the progress-photo
/// timeline uses the SAME lock as the Private Hub — one authentication, one content key. The lock service
/// is passed in explicitly (rather than read from the sheet's environment) since sheets don't reliably
/// inherit it, then re-injected for `FernletLockView`. Dismisses the moment the global lock unlocks.
private struct ProgressPhotoUnlockSheet: View {
    let lockService: FernletLockService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        FernletLockView(onUnlocked: { dismiss() }, onResetRequested: nil)
            .environment(lockService)
            .onChange(of: lockService.state) { _, newState in
                if case .unlocked = newState { dismiss() }
            }
    }
}

/// One dated photo in the timeline. Loads its sealed bytes lazily (like the meal polaroid) so a long
/// history doesn't decode every image up front. Deliberately plainer than the playful meal polaroid —
/// no tilt, a calm frame — because these are body photos.
struct ProgressPhotoCard: View {
    let record: ProgressPhotoRecord
    let loadData: () -> Data?
    var body_width: CGFloat = 132

    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.parchment)
                .frame(width: body_width, height: 168)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .font(.title2)
                            .foregroundStyle(Color.slate.opacity(0.4))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.bark.opacity(0.10), lineWidth: 1)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(record.capturedAt.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
                if let caption = record.caption {
                    Text(caption)
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                        .lineLimit(1)
                }
            }
            .frame(width: body_width, alignment: .leading)
        }
        .task {
            // Decode off the main thread (`byPreparingForDisplay`) so scrolling a long strip doesn't
            // jank; only the finished image is assigned back on the MainActor.
            guard image == nil, let data = loadData() else { return }
            image = await UIImage(data: data)?.byPreparingForDisplay()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress photo from \(record.capturedAt.formatted(.dateTime.month(.wide).day().year()))")
    }
}

/// Full-screen view of a single progress photo: the picture, its date, an editable note, and delete.
/// No share affordance by design — these are private body photos and the app never offers to send them.
struct ProgressPhotoDetailView: View {
    var store: FernletStore
    let record: ProgressPhotoRecord
    /// Called right after any persisted change (caption save / delete) so the parent timeline refreshes
    /// from the store deterministically — NOT via a second racing `onDisappear`.
    var onChanged: () -> Void
    /// Whether the gate should re-lock when this detail disappears. MoveView passes "still in the
    /// navigation path": a pop back to the (still-gated, still-visible) timeline keeps the unlock
    /// session — one Face ID covers strip → detail → pop-back — while a genuine departure (switching
    /// tabs with the detail pushed) still re-locks. Defaults to always-lock for any other presenter.
    var shouldLockOnDisappear: () -> Bool

    @Environment(\.dismiss) private var dismiss
    // Full-screen body photo → gated behind the same global lock as the Private Hub, and redacted from
    // the app-switcher snapshot while backgrounded.
    @Environment(FernletLockService.self) private var lockService
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: UIImage?
    @State private var caption: String
    @State private var capturedAt: Date
    @State private var pendingDestructiveAction: DestructiveConfirmation?
    @FocusState private var captionFocused: Bool

    private var gateActive: Bool {
        lockService.isLockConfigured && !UITestSupport.bypassPrivateLockGate
    }

    /// Fail-closed at the reveal seam: don't even decode the sealed bytes until unlocked.
    private var canReveal: Bool {
        guard gateActive else { return true }
        if case .unlocked = lockService.state { return true }
        return false
    }

    private var redactForSnapshot: Bool { scenePhase != .active }

    init(
        store: FernletStore,
        record: ProgressPhotoRecord,
        onChanged: @escaping () -> Void,
        shouldLockOnDisappear: @escaping () -> Bool = { true }
    ) {
        self.store = store
        self.record = record
        self.onChanged = onChanged
        self.shouldLockOnDisappear = shouldLockOnDisappear
        _caption = State(initialValue: record.caption ?? "")
        _capturedAt = State(initialValue: record.capturedAt)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.parchment)
                            .frame(height: 360)
                            .overlay {
                                Image(systemName: "figure.strengthtraining.traditional")
                                    .font(.largeTitle)
                                    .foregroundStyle(Color.slate.opacity(0.4))
                            }
                    }
                }
                .frame(maxWidth: .infinity)

                Text(capturedAt.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                    .font(.fernlet(.displayMedium))
                    .foregroundStyle(Color.bark)

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Date taken")
                    // Imported/older photos default to "today" (the app captures at the current moment and
                    // library picks only recover a date when the EXIF carries one), so let the user correct
                    // it — the timeline is about dates. Capped at today; edits persist through the same
                    // sealed-index rewrite as the caption.
                    DatePicker(
                        "Date taken",
                        selection: $capturedAt,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .tint(Color.moss)
                    .accessibilityIdentifier("progressPhoto.datePicker")
                    .onChange(of: capturedAt) { _, newValue in
                        store.updateProgressPhotoCapturedAt(id: record.id, date: newValue)
                        onChanged()
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Note")
                    TextField("A word about this one — optional", text: $caption, axis: .vertical)
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                        .lineLimit(1...4)
                        .focused($captionFocused)
                        .padding(12)
                        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.bark.opacity(0.10), lineWidth: 1)
                        )
                        // No `.onSubmit` here: a multiline (axis: .vertical) TextField treats Return as a
                        // newline and never fires onSubmit, so the save affordance is the keyboard-toolbar
                        // "Done" below (plus the onDisappear backstop).
                        .accessibilityIdentifier("progressPhoto.caption")
                }

                Button(role: .destructive) {
                    pendingDestructiveAction = DestructiveConfirmation(
                        title: "Delete this progress photo?",
                        message: "This removes it from your timeline and your device. Fernlet can't undo this.",
                        confirmLabel: "Delete",
                        auditEvent: "progressPhoto.deleteConfirmed",
                        perform: {
                            store.deleteProgressPhoto(id: record.id)
                            onChanged()
                            dismiss()
                        }
                    )
                } label: {
                    Label("Delete this photo", systemImage: "trash")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.dustyRose)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.dustyRose.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("progressPhoto.delete")
            }
            .padding(20)
        }
        .background(Color.parchment)
        // Opaque cover over the WHOLE detail while backgrounded so the app-switcher snapshot can't leak
        // any of it — the previous cover redacted only the picture, leaving the capture date and the
        // caption (free text about the user's body) readable in the snapshot.
        .overlay {
            if redactForSnapshot {
                ZStack {
                    Color.parchment.ignoresSafeArea()
                    VStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Color.slate)
                        Text("Hidden")
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.slate)
                    }
                }
            }
        }
        .navigationTitle("Progress photo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if captionFocused {
                ToolbarItem(placement: .keyboard) {
                    Button("Done") {
                        captionFocused = false
                        saveCaption()
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        // Keyed on the lock state so the decode runs (and re-runs) the moment the gate unlocks. The
        // reveal guard means the sealed bytes are never even decoded into memory while locked.
        .task(id: lockService.state) {
            // Decode off-main; only the finished image lands back on the MainActor.
            guard canReveal, image == nil, let data = store.progressPhotoData(for: record.id) else { return }
            image = await UIImage(data: data)?.byPreparingForDisplay()
        }
        // Backstop for the caption if the user leaves without tapping Done (e.g. taps back with the
        // keyboard still up). Idempotent with the Done save. `saveCaption` refreshes the parent itself,
        // so ordering vs the parent no longer matters.
        .onDisappear { saveCaption() }
        // Routes through the shared destructive-confirmation so the delete warns AND leaves an audit trail,
        // like every other irreversible action (the bespoke confirmationDialog it replaced had no audit).
        .destructiveConfirmation($pendingDestructiveAction)
        // Same full-screen lock as the Private Hub: when configured + locked, an unlock overlay covers
        // the photo and re-locks on disappear. Inactive (no lock configured) → passes through unchanged.
        // The disappear re-lock defers to `shouldLockOnDisappear` so popping back to the still-unlocked
        // strip doesn't cost a fresh Face ID per photo (see the property doc above).
        .fernletLockGate(active: gateActive, shouldLockOnDisappear: shouldLockOnDisappear)
    }

    /// Persists the caption, then refreshes the parent timeline in the SAME step (save → refresh), so the
    /// card never shows a stale caption regardless of view-teardown ordering.
    private func saveCaption() {
        store.updateProgressPhotoCaption(id: record.id, caption: caption)
        onChanged()
    }
}
#endif
