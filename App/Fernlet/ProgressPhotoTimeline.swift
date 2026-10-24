#if canImport(UIKit)
import SwiftUI
import PrivateMediaStore
import FernletLock
import FernletUI
import FernletLockUI

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
    // the timeline reveals behind the Fernlet lock (fail-closed at the reveal seam: no thumbnail
    // decodes until unlocked). It is the SAME passcode as the Private Hub but its OWN unlock session
    // (`.progressPhotos`): unlocking here reveals only this strip and its photo detail, and the hub
    // stays locked. With no lock configured the strip stays open and capture stays one tap away —
    // and a user who deferred the onboarding lock step also gets `DeferredLockSetupNudge`'s card
    // above it, once, offering to set the lock up (granting THIS surface) or not. The card sits
    // beside capture and never in front of it (`ProgressPhotoSectionContent`).
    @Environment(FernletLockService.self) private var lockService
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingUnlock = false
    /// The first-use lock-setup prompt the onboarding "Skip for now" promised.
    @State private var lockNudge = DeferredLockSetupNudge()
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
        lockService.isUnlocked(for: .progressPhotos)
    }

    /// What the section shows: the unlock placeholder, or the strip with its capture control (plus
    /// the lock-setup nudge above it when offered). Gated behind THIS surface's own unlock when a lock
    /// is configured — an unlock held by the Private Hub or App-lock settings reveals nothing here.
    private var content: ProgressPhotoSectionContent {
        ProgressPhotoSectionContent.resolve(
            gateActive: gateActive,
            isUnlocked: isUnlocked,
            offersLockNudge: lockNudge.isOffered(isLockConfigured: lockService.isLockConfigured)
        )
    }

    /// Hide the app-switcher snapshot of body photos while the app isn't frontmost.
    private var redactForSnapshot: Bool { scenePhase != .active }

    /// The World build's framed look (`b2-progress-photos`); nil draws today's section.
    @Environment(\.fernletFramedLook) private var look

    /// Today's section: one cream card holding the nudge and the strip.
    private var plainSection: some View {
        FernletScrollSection("Progress photos") {
            switch content {
            case .locked:
                lockedPlaceholder
            case .revealed(let offersLockNudge):
                VStack(alignment: .leading, spacing: 14) {
                    if offersLockNudge {
                        ProgressPhotoLockNudgeCard(onSetUpLock: lockNudge.setUpLock, onNotNow: lockNudge.notNow)
                    }
                    revealedContent
                }
            }
        }
    }

    /// World build (`b2-progress-photos`): the section label, the lock nudge as its own sage card, the
    /// strip in a framed card, and how to open a photo under it.
    private var framedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Progress photos").padding(.horizontal, 4)
            switch content {
            case .locked:
                FernletCard { lockedPlaceholder }
            case .revealed(let offersLockNudge):
                if offersLockNudge {
                    ProgressPhotoLockNudgeCard(onSetUpLock: lockNudge.setUpLock, onNotNow: lockNudge.notNow)
                }
                FernletCard { revealedContent }
                if !records.isEmpty {
                    Text("Tap a photo to see it full size, with its date and note.",
                         comment: "Move panel, under the progress-photo strip: how to open a photo.")
                        .font(FernletFramedFont.body)
                        .foregroundStyle(look?.dim ?? Color.slate)
                        .fernletWrappingText()
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    var body: some View {
        Group {
            if look != nil { framedSection } else { plainSection }
        }
        .onAppear {
            sectionIsVisible = true
            pendingRelock = false
            isOpeningDetail = false
            // Arriving here revokes an unlock held by the Private Hub / App-lock settings rather than
            // inheriting it — the appear-side half of the one-surface guarantee, which holds even when
            // the surface we replaced never got to run its own disappear re-lock.
            if gateActive { lockService.revokeUnlockOutside(.progressPhotos) }
        }
        .onDisappear {
            sectionIsVisible = false
            reLockOnDisappear()
        }
        .onChange(of: scenePhase) { _, newPhase in handleScenePhaseChange(newPhase) }
        .sheet(isPresented: $showingUnlock) {
            ProgressPhotoUnlockSheet(lockService: lockService)
        }
        // The nudge's "Set up lock". Hung on the section, not on the card: the card disappears the
        // instant the lock exists, and a sheet whose presenter vanished would be torn down mid-way
        // through the setup's own success state. Granting `.progressPhotos` means the user lands
        // back on their photos, unlocked for this surface only; the lock service is passed in
        // because sheets do not reliably inherit it.
        .sheet(isPresented: $lockNudge.isPresentingLockSetup, onDismiss: {
            lockNudge.lockSetupDismissed(isLockConfigured: lockService.isLockConfigured)
        }) {
            FernletLockSetupView(grantingScope: DeferredLockSetupNudge.grantingScope)
                .environment(lockService)
        }
    }

    /// Scene-phase half of the re-lock machinery: suppresses the disappear re-lock while the scene is
    /// inactive (Face ID's system dialog bounces it), and for 1.5 s after it returns to active, then
    /// runs any genuine-departure lock that was deferred inside that window.
    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
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
                do {
                    try await Task.sleep(for: .milliseconds(1500))
                } catch {
                    // Cancelled: a newer scene transition superseded this task and now owns
                    // `suppressRelock`/`pendingRelock` — touch neither, or we would clear the
                    // newer task's suppression early and run its deferred lock.
                    return
                }
                suppressRelock = false
                // Execute a deferred genuine-departure lock if the section hasn't re-appeared.
                if pendingRelock && !sectionIsVisible && !isCapturing {
                    pendingRelock = false
                    // Only our own unlock — if another surface has since claimed one, locking
                    // here would yank it out from under whoever is on screen now.
                    if lockService.isUnlocked(for: .progressPhotos) {
                        lockService.lock(reason: .viewDisappeared)
                    }
                }
            }
        default:
            break
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
                // Top-aligned, so every picture starts on one line and a card with no caption ends
                // short instead of drifting down to the middle. The stack's HEIGHT comes from its
                // first child, which is why `addTile` reserves the tallest label block.
                LazyHStack(alignment: .top, spacing: 14) {
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
            if look != nil {
                FernletIconTile(size: 44) { WorldSpriteView(sprite: WorldSprites.lock, scale: 3) }
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.moss)
            }
            Text("Your progress photos are private")
                .font(look == nil ? .fernlet(.body) : FernletFramedFont.cardTitle)
                .foregroundStyle(look?.text ?? Color.bark)
            Text("These body photos sit behind your Fernlet lock. Unlock to see your timeline.")
                .font(look == nil ? .fernlet(.bodySmall) : FernletFramedFont.body)
                .foregroundStyle(look?.dim ?? Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
            if look != nil {
                Button("Unlock to view") { showingUnlock = true }
                    .buttonStyle(ActionPillButtonStyle(.primary))
                    .accessibilityIdentifier("move.progressPhotos.unlock")
            } else {
                Button {
                    showingUnlock = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Unlock to view")
                            .font(.fernlet(.label))
                    }
                    .foregroundStyle(Color.onMoss)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color.moss, in: Capsule())
                    .fernletSmallShadow()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("move.progressPhotos.unlock")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// The word on both app-switcher covers, under its own key: "Hidden" is also a safety code's state
    /// elsewhere, and Spanish agrees it with what is hidden (here, the progress photos).
    static var hiddenCaption: String {
        String(localized: "progressPhoto.snapshotCover.hidden", defaultValue: "Hidden",
               comment: "Caption on the cover over the progress photos in the app switcher: the photos are hidden")
    }

    /// Opaque privacy cover used to redact the timeline in the app-switcher snapshot.
    private var snapshotCover: some View {
        ZStack {
            Rectangle().fill(Color.parchment)
            VStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.slate)
                Text(ProgressPhotoSection.hiddenCaption)
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
        guard lockService.isUnlocked(for: .progressPhotos) else { return }
        if suppressRelock {
            pendingRelock = true
        } else {
            lockService.lock(reason: .viewDisappeared)
        }
    }

    @ViewBuilder private func addLabel(prominent: Bool) -> some View {
        if let look {
            // World build: the framed primary (the capture control is the button, so this only draws it).
            let shape = RoundedRectangle(cornerRadius: 10)
            HStack(spacing: 8) {
                WorldSpriteView(sprite: WorldSprites.photo, scale: 2, tint: look.onAccent)
                Text("Add progress photo")
                    .font(FernletFramedFont.button)
            }
            .foregroundStyle(look.onAccent)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .background(look.accent, in: shape)
            .overlay(shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
            .background { shape.fill(look.ink.opacity(0.3)).offset(y: 3) }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("Add progress photo")
                    .font(.fernlet(.label))
            }
            .foregroundStyle(Color.onMoss)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.moss, in: Capsule())
            .fernletSmallShadow()
        }
    }

    /// The leading "＋" tile in the populated strip: a card-sized box over the TALLEST label block any
    /// card in the strip carries, reserved and hidden.
    ///
    /// The reservation sets the strip's height. A `LazyHStack` in a horizontal `ScrollView` takes
    /// its height from its FIRST child, and this tile is always first, so the strip is exactly as
    /// tall as this tile, and the strip's edge cuts off any part of a taller card. Measured
    /// 2026-09-24 on iPhone 17 while the tile reserved one caption line: at content size `large` the
    /// strip was 203.67pt and a captioned card 211pt, so the centred stack pushed that card past both
    /// edges. "Feeling stronger" was cut through its baseline and the top of the picture was cut too.
    /// At the largest accessibility size the strip was 237.67pt around a 280pt card.
    ///
    /// So the tile reserves ``ProgressPhotoCardLabels`` itself, the same view every card renders, not
    /// a hand-kept copy of its fonts (a copy is what drifted). It reserves one for each distinct date
    /// in the strip, each over a caption line when any photo has a caption, and one for each
    /// distinct caption under the longest date, since captions wrap at accessibility sizes. In a
    /// `ZStack` the tallest wins, so a date that wraps onto two lines at the largest text sizes
    /// reserves both. Bounded: the chip has no year, so there are at most 366 distinct dates, and
    /// there are no more captions than captioned photos.
    private var addTile: some View {
        VStack(alignment: .leading, spacing: ProgressPhotoCard.labelSpacing) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                // World build: a dashed ink frame around a pixel photo and the word (`b2-progress-photos`).
                .strokeBorder(look?.text ?? Color.moss.opacity(0.5),
                              style: StrokeStyle(lineWidth: look == nil ? 1.5 : 2, dash: look == nil ? [6, 5] : [7, 5]))
                .frame(width: ProgressPhotoCard.cardWidth, height: ProgressPhotoCard.cardHeight)
                .overlay {
                    VStack(spacing: 8) {
                        if look != nil {
                            WorldSpriteView(sprite: WorldSprites.photo, scale: 3)
                        } else {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 22, weight: .semibold))
                        }
                        Text("Add")
                            .font(look == nil ? .fernlet(.label) : FernletFramedFont.sheetControl)
                    }
                    .foregroundStyle(look?.link ?? Color.moss)
                }
            ZStack(alignment: .topLeading) {
                ForEach(reservedDateLabels, id: \.self) { date in
                    ProgressPhotoCardLabels(date: date, caption: reservesCaptionLine ? " " : nil)
                }
                // At accessibility sizes a caption wraps, so one caption line is not the tallest
                // card any more: each distinct caption is reserved too, under the longest date.
                ForEach(reservedCaptions, id: \.self) { caption in
                    ProgressPhotoCardLabels(date: longestDateLabel, caption: caption)
                }
            }
            .hidden()
            .accessibilityHidden(true)
        }
    }

    /// Every distinct date chip the strip renders, in a stable order: what `addTile` reserves.
    private var reservedDateLabels: [String] {
        Set(records.map { ProgressPhotoCard.dateLabel(for: $0.capturedAt) }).sorted()
    }

    /// Whether any photo has a caption, and so whether the tallest card has a caption line.
    private var reservesCaptionLine: Bool {
        records.contains { $0.caption != nil }
    }

    /// Every distinct caption in the strip. Bounded by the photos the user has captioned.
    private var reservedCaptions: [String] {
        Set(records.compactMap(\.caption)).sorted()
    }

    /// The date chip with the most characters: the one most likely to wrap at the largest sizes.
    private var longestDateLabel: String {
        reservedDateLabels.max { $0.count < $1.count } ?? ""
    }
}

/// What the progress-photo section shows, decided in ONE place so the lock-setup nudge can never take
/// the place of capture.
///
/// `.locked` is the tap-to-unlock placeholder: a lock is configured and this surface does not hold
/// the unlock. `.revealed` is the strip (or its empty state) WITH its capture control, and its
/// `offersLockNudge` puts ``DeferredLockSetupNudge``'s card ABOVE that control — never instead of
/// it. The nudge needs "no lock configured" and the placeholder needs a configured one, so the two
/// never meet; `ProgressPhotoLockNudgeTests` pins that over every input.
enum ProgressPhotoSectionContent: Equatable {
    /// Behind a configured lock this surface has not unlocked.
    case locked
    /// The photos and the capture control, with the lock-setup nudge above them when offered.
    case revealed(offersLockNudge: Bool)

    /// - Parameters:
    ///   - gateActive: A lock is configured (and the UI-test bypass is off).
    ///   - isUnlocked: `.progressPhotos` holds the unlock in force.
    ///   - offersLockNudge: ``DeferredLockSetupNudge/isOffered(isLockConfigured:)``.
    static func resolve(gateActive: Bool, isUnlocked: Bool, offersLockNudge: Bool) -> Self {
        guard !gateActive || isUnlocked else { return .locked }
        return .revealed(offersLockNudge: offersLockNudge)
    }
}

/// The gentle, one-time card above the progress-photo strip for a user who skipped the onboarding
/// lock step: progress photos can sit behind the app lock — "Set up lock" or "Not now".
///
/// Purely presentational; ``DeferredLockSetupNudge`` decides when it shows and records the answer.
/// Inline rather than modal, so it never blocks or delays capture — the copy says photos can keep
/// being added either way. Buttons stack at accessibility text sizes (``AdaptiveStack``), and each
/// carries a hint for what happens next, since "Not now" retires the card for good.
struct ProgressPhotoLockNudgeCard: View {
    /// Opens lock setup granting `.progressPhotos`.
    let onSetUpLock: () -> Void
    /// Answers the nudge without a lock; the card does not come back.
    let onNotNow: () -> Void
    /// World build (`b2-progress-photos`): a sage card in an ink frame, the pixel lock in a tile.
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: look == nil ? 10 : 12) {
                icon
                VStack(alignment: .leading, spacing: 4) {
                    Text("Protect your progress photos")
                        .font(look == nil ? .fernlet(.label) : .custom(FernletFontName.frauncesSemiBold, size: 18, relativeTo: .headline))
                        .foregroundStyle(look?.text ?? Color.bark)
                        .fernletWrappingText()
                        .accessibilityAddTraits(.isHeader)
                    Text("Progress photos can sit behind Fernlet's app lock, so nobody holding your unlocked phone can scroll through them. You can keep adding photos either way, and set the lock up any time in Settings.")
                        .font(look == nil ? .fernlet(.bodySmall) : FernletFramedFont.body)
                        .foregroundStyle(look?.dim ?? Color.slate)
                        .fernletWrappingText()
                }
            }
            AdaptiveStack(horizontalAlignment: .leading) {
                Button(action: onSetUpLock) { Text("Set up lock").frame(maxWidth: look == nil ? nil : .infinity) }
                    .buttonStyle(ActionPillButtonStyle(.primary))
                    .accessibilityHint("Creates a passcode for Fernlet's app lock.")
                    .accessibilityIdentifier("move.progressPhotos.lockNudge.setUp")
                Button(action: onNotNow) { Text("Not now").frame(maxWidth: look == nil ? nil : .infinity) }
                    .buttonStyle(ActionPillButtonStyle(.secondary))
                    .accessibilityHint("Hides this suggestion. You can set up the lock later in Settings.")
                    .accessibilityIdentifier("move.progressPhotos.lockNudge.notNow")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(NudgeCardFrame())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("move.progressPhotos.lockNudge")
    }

    /// The card's icon. Decorative: the heading says what the card is about.
    @ViewBuilder private var icon: some View {
        if look != nil {
            FernletIconTile(size: 44) { WorldSpriteView(sprite: WorldSprites.lock, scale: 3) }
                .accessibilityHidden(true)
        } else {
            Image(systemName: "lock.shield")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.moss)
                .accessibilityHidden(true)
        }
    }
}

/// The lock nudge's card: World build, the look's sage in a 2-pt ink frame with its solid shadow (the
/// kit's `.ac.sage`); today, a faint moss wash.
private struct NudgeCardFrame: ViewModifier {
    @Environment(\.fernletFramedLook) private var look

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: look == nil ? 14 : FernletFramedLook.cardRadius, style: .continuous)
        if let look {
            content
                .background(look.sage, in: shape)
                .overlay(shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
                .background { shape.fill(look.shadow).offset(y: 3) }
        } else {
            content
                .background(Color.moss.opacity(0.07), in: shape)
                .overlay(shape.stroke(Color.moss.opacity(0.3), lineWidth: 1))
        }
    }
}

/// A calm sheet that runs the app's real unlock flow (`FernletLockView`) so revealing the progress-photo
/// timeline uses the SAME passcode as the Private Hub — but its own `.progressPhotos` unlock session, so
/// authenticating here opens the strip and nothing else. The lock service is passed in explicitly (rather
/// than read from the sheet's environment) since sheets don't reliably inherit it, then re-injected for
/// `FernletLockView`. Dismisses the moment THIS scope unlocks.
private struct ProgressPhotoUnlockSheet: View {
    let lockService: FernletLockService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // `onResetRequested: nil` is deliberate, and it is only safe because of the scope rule in
        // `FernletLockService.unlock`: `.progressPhotos` never receives the lock's content key
        // (these photos seal under `PrivateMediaKeyStore`'s own key), so a dead Secure-Enclave key
        // cannot strand this sheet — the unlock succeeds on the verifier match alone and the
        // unrecoverable card never renders here. Offering a destructive app-lock reset from the
        // photo strip would be the wrong place for it; the Private Hub gate and Settings → App
        // lock both carry it.
        FernletLockView(
            scope: .progressPhotos,
            onUnlocked: { dismiss() },
            onResetRequested: nil,
            automaticallyPromptsBiometrics: true
        )
            .environment(lockService)
            .onChange(of: lockService.state) { _, newState in
                if newState.isUnlocked(for: .progressPhotos) { dismiss() }
            }
    }
}

/// One dated photo in the timeline. Loads its sealed bytes lazily (like the meal polaroid) so a long
/// history doesn't decode every image up front. Deliberately plainer than the playful meal polaroid —
/// no tilt, a calm frame — because these are body photos.
struct ProgressPhotoCard: View {
    let record: ProgressPhotoRecord
    let loadData: () -> Data?
    /// The card's fixed width, shared with the strip's add tile and ``ProgressPhotoCardLabels``.
    /// Immutable: no caller ever customised it (R6).
    static let cardWidth: CGFloat = 132
    /// The card's fixed picture height — the thumbnail is decoded to exactly this footprint.
    static let cardHeight: CGFloat = 168
    /// The gap between the picture and its labels. The add tile uses it too, so the two footprints
    /// match.
    static let labelSpacing: CGFloat = 8

    @Environment(\.displayScale) private var displayScale
    @Environment(\.fernletFramedLook) private var look
    @State private var image: UIImage?

    /// The date chip's text: abbreviated month and day, e.g. "Sep 9".
    static func dateLabel(for date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.labelSpacing) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.parchment)
                .frame(width: Self.cardWidth, height: Self.cardHeight)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            // T2-10: a photograph of a person under Smart Invert is a colour
                            // negative. The placeholder glyph below is a tinted symbol and is
                            // deliberately left to invert with the rest of the chrome.
                            .accessibilityIgnoresInvertColors()
                    } else {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .font(.title2.weight(.light))
                            .foregroundStyle(Color.slate)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    // World build: each photo in an ink frame with a solid shadow (`.photo3`).
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(look?.ink ?? Color.bark.opacity(0.10), lineWidth: look == nil ? 1 : 2)
                )
                .background {
                    if let look { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(look.shadow).offset(y: 3) }
                }
            ProgressPhotoCardLabels(date: Self.dateLabel(for: record.capturedAt), caption: record.caption)
        }
        .task {
            // Decode off the main thread straight to the card's own pixel size (mirrors the meal
            // polaroid): the sealed bytes are ~1600px, and `byPreparingForDisplay` retained that full
            // ~8 MB bitmap behind a 132pt thumbnail — one per card scrolled past, for as long as the
            // strip lived. These are decrypted body photos, so the footprint matters twice.
            guard image == nil, let data = loadData() else { return }
            let pixelSize = CGSize(width: Self.cardWidth * displayScale, height: Self.cardHeight * displayScale)
            image = await UIImage(data: data)?.byPreparingThumbnail(ofSize: pixelSize)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress photo from \(record.capturedAt.formatted(.dateTime.month(.wide).day().year()))")
    }
}

/// The date chip and optional caption under a progress photo's picture.
///
/// This is its own view because the strip's add tile also renders it, hidden, to reserve room for
/// the tallest card (see `ProgressPhotoSection.addTile`). That reservation is exact only when it
/// uses this view; a copy of its fonts and spacing is what drifted before. The parameters are
/// `String` on purpose: a formatted date and the user's own note are data, and a
/// `LocalizedStringKey` would look a caption up in the string catalog.
struct ProgressPhotoCardLabels: View {
    /// The date chip's text, as ``ProgressPhotoCard/dateLabel(for:)`` formats it.
    let date: String
    /// The user's note, or nil for none. One line below accessibility sizes, where a longer note
    /// truncates; at them it wraps.
    let caption: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.fernletFramedLook) private var look

    /// The label column: the card's width, widened at accessibility sizes, where one word of a
    /// caption ("Feeling") or a two-digit date chip was already wider than the 132pt card.
    private var columnWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 220 : ProgressPhotoCard.cardWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(date)
                .font(.fernlet(.label))
                .fontWeight(look == nil ? nil : .bold)
                .foregroundStyle(look?.text ?? Color.bark)
            if let caption {
                Text(caption)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(look?.dim ?? Color.slate)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: columnWidth, alignment: .leading)
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
    /// World build: the page's ink and the framed field and button take the look.
    @Environment(\.fernletFramedLook) private var look

    private var gateActive: Bool {
        lockService.isLockConfigured && !UITestSupport.bypassPrivateLockGate
    }

    /// Fail-closed at the reveal seam: don't even decode the sealed bytes until unlocked — and only
    /// for THIS surface's unlock (shared with the strip that pushed us, so one authentication covers
    /// strip → detail → pop-back; never inherited from the Private Hub or App-lock settings).
    private var canReveal: Bool {
        guard gateActive else { return true }
        return lockService.isUnlocked(for: .progressPhotos)
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
                photoHero

                Text(capturedAt.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                    .font(.fernlet(.displayMedium))
                    .foregroundStyle(look?.text ?? Color.bark)

                dateTakenField
                noteField
                deleteButton
            }
            .padding(20)
        }
        .fernletPageBackground()
        // Opaque cover over the WHOLE detail while backgrounded so the app-switcher snapshot can't leak
        // any of it — the previous cover redacted only the picture, leaving the capture date and the
        // caption (free text about the user's body) readable in the snapshot.
        .overlay {
            if redactForSnapshot {
                snapshotRedactionOverlay
            }
        }
        // World build (`b2-progress-photos`): opened "in the same frame", its title and Back on the plate.
        .fernletPushedPage("Progress photo")
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
        // Same full-screen lock treatment as the Private Hub, on the strip's OWN `.progressPhotos`
        // scope: when configured + not unlocked for that scope, an unlock overlay covers the photo,
        // and it re-locks on disappear. Inactive (no lock configured) → passes through unchanged.
        // Sharing the strip's scope is what lets `shouldLockOnDisappear` keep one unlock across
        // strip → detail → pop-back instead of costing a fresh Face ID per photo (see the property
        // doc above).
        .fernletLockGate(
            scope: .progressPhotos,
            active: gateActive,
            automaticallyPromptsBiometrics: false,
            shouldLockOnDisappear: shouldLockOnDisappear
        )
    }

    /// The photo itself, or the calm placeholder while it is still sealed/decoding.
    @ViewBuilder
    private var photoHero: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    // T2-10: the full-size progress photo, for the same reason as the strip
                    // thumbnail — inverted, it is a negative of the user's own body.
                    .accessibilityIgnoresInvertColors()
                    // Without this the hero is an undescribed image: the nav title says "Progress
                    // photo" but never which one, and the date is the only thing distinguishing
                    // one from the next. Same wording as the strip card's label so the announcement
                    // does not change on the way in.
                    .accessibilityLabel("Progress photo from \(record.capturedAt.formatted(.dateTime.month(.wide).day().year()))")
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.parchment)
                    .frame(height: 360)
                    .overlay {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .font(.largeTitle.weight(.light))
                            .foregroundStyle(Color.slate)
                            // Decorative placeholder while the photo decodes; unhidden, VoiceOver
                            // would speak the symbol's name where the photo's date label will be.
                            .accessibilityHidden(true)
                    }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The capture-date picker (capped at today), persisted on every change.
    private var dateTakenField: some View {
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
    }

    /// The optional note, capped where the text enters so the sealed index never sees more.
    private var noteField: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Note")
            TextField("A word about this one — optional", text: limitedCaption,
                      prompt: .fieldPrompt("A word about this one — optional"), axis: .vertical)
                .lineLimit(1...4)
                .focused($captionFocused)
                // The sheet field: framed under the World look, today's cream field without it.
                .sheetTextInput()
                // No `.onSubmit` here: a multiline (axis: .vertical) TextField treats Return as a
                // newline and never fires onSubmit, so the save affordance is the keyboard-toolbar
                // "Done" below (plus the onDisappear backstop).
                .accessibilityIdentifier("progressPhoto.caption")
        }
    }

    /// The delete affordance, routed through the shared destructive confirmation.
    private var deleteButton: some View {
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
            Text("Delete this photo").frame(maxWidth: .infinity)
        }
        // The destructive pill: framed under the World look.
        .buttonStyle(ActionPillButtonStyle(.destructive))
        .accessibilityIdentifier("progressPhoto.delete")
    }

    /// The opaque cover shown in the app-switcher snapshot.
    private var snapshotRedactionOverlay: some View {
        ZStack {
            Color.parchment.ignoresSafeArea()
            VStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.slate)
                Text(ProgressPhotoSection.hiddenCaption)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
            }
        }
    }

    /// R3/R5: the note is free text about the user's body written into the sealed index on every
    /// disappear — bounded where it enters, and again in ``saveCaption()``.
    private static let maxCaptionLength = 200

    private var limitedCaption: Binding<String> {
        Binding(
            get: { caption },
            set: { caption = String($0.prefix(Self.maxCaptionLength)) }
        )
    }

    /// Persists the caption, then refreshes the parent timeline in the SAME step (save → refresh), so the
    /// card never shows a stale caption regardless of view-teardown ordering.
    private func saveCaption() {
        // Fail closed: a detail that never revealed cannot have an edited caption, so it must not
        // rewrite the sealed index on its way out.
        guard canReveal else { return }
        store.updateProgressPhotoCaption(id: record.id, caption: String(caption.prefix(Self.maxCaptionLength)))
        onChanged()
    }
}
#endif
