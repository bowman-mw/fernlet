#if canImport(UIKit)
import SwiftUI
import PhotosUI
import UIKit
import PrivateMediaStore
import FernletLock
import FernletUI
import FernletLockUI

// The Private hub's photo wall.
//
// This file replaces the placeholder that shipped inside `PersonalScreenView`'s `.photos` page —
// three decorative `PolaroidTile`s under the sentence "Photo imports can live here when the photo
// picker is added." The polaroid language survives (it is the whole point of the surface); the
// promise is now real.
//
// Three deliberate non-decisions, so nobody has to re-derive them:
//
//  • No new persistence. The bytes and the dated index both go through the module's existing sealed
//    media stack — `ProgressPhotoStore` over `MealPhotoStore` over `PrivateMediaKeyProviding` — just
//    rooted at its own directory. That stack already owns the AES-256-GCM seal, the bounded ImageIO
//    downscale, the absurd-dimensions refusal, the fail-closed "no key means write nothing" rule and
//    the never-clobber-an-unreadable-index rule. Re-deriving any of that here would have been a
//    second, weaker copy of a hardened path.
//  • No second unlock flow. The wall renders inside `PrivateHubView`, which is wrapped in
//    `fernletLockGate` — one authentication for the whole hub. `PhotoWallSection` keeps a
//    *fail-closed reveal check* of its own (so hosting this page outside the hub can never expose
//    the wall) but deliberately offers no unlock button and runs no re-lock-on-disappear machinery:
//    the gate above it owns both, and a second re-locker fighting the first is exactly the bug
//    `ProgressPhotoSection` had to grow suppression flags to survive.
//  • No thumbnail cache. Stored photos are already capped at 1600px/0.8 JPEG by `MealPhotoStore`'s
//    normalization, and the wall is a small grid whose tiles load lazily, so the sealed bytes are
//    handed straight to `PolaroidTile` the way `HomeView`'s photowall strip already does.

/// Owner of the photo wall's sealed store and its in-memory record list.
///
/// Composition over invention: the persistence is an ordinary ``ProgressPhotoStore`` — the same
/// sealed-bytes-plus-sealed-dated-index pair the gym progress timeline uses — pointed at its own
/// `PhotoWall/` directory so the two feature's photos never mix. The type is named for its original
/// caller, but its contract is exactly what a photo wall needs: dates and captions sealed alongside
/// the pictures, with every mutation refusing rather than clobbering an index it cannot read.
///
/// Held as `@State` by `PersonalScreenView` so the header "+" and the wall's own add tile drive one
/// instance. The sealed store is `lazy` because that `@State` initializer re-runs on every view
/// init, and `ProgressPhotoStore.init` touches the filesystem.
///
/// - Important: **Not yet reached by "Delete everything."** `FernletStore.deleteAllData` enumerates
///   its media stores by hand (`mealPhotoStore` / `progressPhotoStore` / `recipePhotoStore`) and has
///   no seam an app-owned store can register through, so this directory currently survives a full
///   wipe — as would its entry in the shared media key's key-cache invalidation. `deleteAll()` and
///   ``invalidateEncryptionKeyCache()`` below exist precisely so that wiring is a two-line change in
///   `FernletStore`; until it lands, this store must not be treated as wipe-covered, and
///   Docs/PrivacyWipeCoverage.md must not claim it is.
///
/// `@MainActor` `@Observable`: SwiftUI observes ``photos`` directly, and every store call is
/// synchronous filesystem + CryptoKit work on the main actor, matching how `FernletStore` owns its
/// own media stores.
@MainActor
@Observable
final class PhotoWallLibrary {
    /// The wall, newest first (the store sorts by `capturedAt`). Empty until ``reload()`` runs, and
    /// empty again whenever the sealed index cannot be opened — an unreadable index reads as empty
    /// rather than as an error, so a lost key degrades to a blank wall instead of a broken screen.
    private(set) var photos: [ProgressPhotoRecord] = []

    /// The sealed store, built on first use. `@ObservationIgnored` because it is not view state;
    /// `lazy` because `PersonalScreenView`'s `@State` initializer re-runs on every view init and
    /// `ProgressPhotoStore.init` creates directories.
    @ObservationIgnored private lazy var sealedStore = ProgressPhotoStore(directory: Self.directoryURL)

    /// `Documents/PhotoWall/` — a sibling of `MealPhotos/`, `ProgressPhotos/` and `RecipePhotos/`,
    /// never a subdirectory of one. Nesting it inside another store's root would make this wall's
    /// lifetime an accident of that store's `deleteAll()` (which removes its directory wholesale),
    /// which is not a coupling anyone should have to discover from a stack trace.
    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("PhotoWall", isDirectory: true)
    }

    init() {}

    /// Re-reads the sealed index into ``photos``. Cheap and idempotent; called on appear and after
    /// every mutation so the grid never renders a record the store no longer has.
    func reload() {
        photos = sealedStore.records()
    }

    /// Normalizes, seals and indexes one picked photo, then refreshes ``photos``.
    ///
    /// The bytes go in as `Data` and are decoded exactly once, inside the store's bounded ImageIO
    /// downscale — a 48 MP library pick must never be materialised as a full bitmap here (that is
    /// ~190 MB and a jetsam on the iPhone-11 floor), which is also why the picker path below hands
    /// `Data` straight through rather than a `UIImage`.
    ///
    /// - Returns: `false` when nothing was written — non-image bytes, dimensions past the store's
    ///   refusal bound, no encryption key, or a present-but-unreadable index (the store refuses to
    ///   overwrite one, since that would silently drop the existing wall). Every one of those is a
    ///   "we saved nothing" outcome the caller surfaces rather than swallows.
    @discardableResult
    func add(_ data: Data, capturedAt: Date) -> Bool {
        guard sealedStore.add(data, capturedAt: capturedAt) != nil else { return false }
        reload()
        return true
    }

    /// Decrypted bytes for one record, or nil when the file is missing or won't open. Never
    /// ciphertext: the store's read path is fail-closed and refuses unsealed bytes outright (the
    /// wall was born sealed, so a plaintext file at a valid id path is tampering, not a migration).
    func imageData(for id: UUID) -> Data? {
        sealedStore.imageData(for: id)
    }

    /// Rewrites a photo's caption in the sealed index (blank collapses to nil).
    func updateCaption(id: UUID, caption: String?) {
        sealedStore.updateCaption(id: id, caption: caption)
        reload()
    }

    /// Rewrites a photo's date in the sealed index. The wall stamps imports with "now" (the picked
    /// bytes' own EXIF date is read by `PhotoCaptureControl`'s private helper, which this path can't
    /// reach), so this editor is how an older photo gets its real date back.
    func updateCapturedAt(id: UUID, date: Date) {
        sealedStore.updateCapturedAt(id: id, date: date)
        reload()
    }

    /// Deletes one photo's sealed bytes and its index entry.
    func delete(id: UUID) {
        sealedStore.delete(id: id)
        reload()
    }

    /// Removes every photo and the sealed index. Unused today — it exists so the "Delete everything"
    /// wiring described in this type's `Important` note is a one-line call, not a redesign.
    @discardableResult
    func deleteAll() -> Bool {
        let cleared = sealedStore.deleteAll()
        reload()
        return cleared
    }

    /// Drops the provider-cached media key, for the same delete-all seam every other sealed media
    /// store exposes (Docs/PrivacyWipeCoverage.md). Also currently unwired — see the type's note.
    func invalidateEncryptionKeyCache() {
        sealedStore.invalidateEncryptionKeyCache()
    }
}

/// The Private hub's photo wall: a scatter of polaroids over the user's own sealed photos, plus the
/// `PhotosPicker` import that fills it.
///
/// Reveal is fail-closed. When a Fernlet lock is configured, nothing decodes until the lock reports
/// unlocked — the same reveal-seam discipline `ProgressPhotoSection` uses, and the reason the locked
/// branch renders a placeholder rather than dimmed tiles. Inside `PrivateHubView` that check is
/// already satisfied by the hub's own gate; it earns its keep only if this page is ever hosted
/// somewhere less careful. Unlike the progress-photo timeline there is intentionally no unlock
/// button and no re-lock-on-disappear here: the hub gate above owns both.
///
/// Note what the lock does and does not do for these bytes. The photos are sealed under the shared
/// **media** key (a keychain row available after first unlock), not under the lock's content key, so
/// the lock is a UI reveal gate over this wall, not the thing that makes the bytes unreadable. The
/// seal is what protects them at rest; the gate is what stops someone holding an unlocked phone from
/// scrolling them. Both are needed, and neither substitutes for the other.
struct PhotoWallSection: View {
    /// The sealed store + record cache, owned by `PersonalScreenView`.
    var library: PhotoWallLibrary
    /// Driven by the page header's "+" as well as the wall's own add tile, so one picker serves both.
    @Binding var isPresentingPicker: Bool

    @Environment(FernletLockService.self) private var lockService
    @Environment(\.scenePhase) private var scenePhase
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var isImporting = false
    /// How many photos in the last pick saved nothing (unloadable bytes, refused dimensions, no
    /// encryption key). Surfaced rather than swallowed: a pick the user made that quietly vanished
    /// is indistinguishable from a bug.
    @State private var failedImportCount = 0
    @State private var selectedPhoto: ProgressPhotoRecord?

    /// At most ten per pick. Each import is a synchronous ImageIO downscale, an AES-GCM seal and a
    /// sealed-index rewrite on the main actor (the sealed store is a nonisolated value type owned
    /// here, exactly as `FernletStore` owns its own media stores), so the cap keeps one pick a short
    /// stretch of blocking work rather than an unbounded one.
    private static let maximumSelectionCount = 10

    private var gateActive: Bool {
        lockService.isLockConfigured && !UITestSupport.bypassPrivateLockGate
    }

    /// Whether the real photos may be decoded and shown.
    private var isRevealed: Bool {
        guard gateActive else { return true }
        if case .unlocked = lockService.state { return true }
        return false
    }

    /// Hide the app-switcher snapshot of the wall while the app isn't frontmost.
    private var redactForSnapshot: Bool { scenePhase != .active }

    /// The picker's presentation, ANDed with the reveal gate. Writes pass straight through so a
    /// dismissal (or a lock engaging mid-pick) still clears the caller's flag.
    private var revealedPickerPresentation: Binding<Bool> {
        Binding(
            get: { isRevealed && isPresentingPicker },
            set: { isPresentingPicker = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isRevealed {
                revealedContent
            } else {
                lockedPlaceholder
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The picker is attached unconditionally (so the sink can never go away mid-flight) but
        // presented through `revealedPickerPresentation`, which refuses while the wall is locked —
        // the page's header "+" lives in `PersonalScreenView` and knows nothing about the reveal
        // state, so the refusal has to happen here rather than at the button.
        //
        // No `photoLibrary:` argument, deliberately — matching `PhotoCaptureControl`. Passing
        // `.shared()` switches `PhotosPicker` to the in-process picker, which needs full photo-library
        // authorization and an `NSPhotoLibraryUsageDescription` prompt. The default out-of-process
        // picker asks for no permission at all and hands back only what the user picked, which is the
        // posture this app owes a private wall.
        .photosPicker(
            isPresented: revealedPickerPresentation,
            selection: $pickedItems,
            maxSelectionCount: Self.maximumSelectionCount,
            matching: .images
        )
        .onChange(of: pickedItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await importPickedItems(items) }
        }
        .task { library.reload() }
        // Re-read on unlock: a wall that first appeared behind the gate has an empty record list,
        // and nothing else would refresh it once the gate opens.
        .onChange(of: lockService.state) { _, _ in library.reload() }
        .sheet(item: $selectedPhoto) { record in
            NavigationStack {
                // The lock service is handed over explicitly AND re-injected: sheets do not reliably
                // inherit an `@Environment(FernletLockService.self)` from their presenter (the same
                // reason `ProgressPhotoUnlockSheet` passes it by hand), and a missing non-optional
                // Observable environment value is a trap, not a nil.
                PhotoWallDetailView(library: library, record: record, lockService: lockService)
            }
            .environment(lockService)
        }
    }

    // MARK: - Revealed states

    @ViewBuilder private var revealedContent: some View {
        if library.photos.isEmpty {
            emptyWall
        } else {
            populatedWall
        }
        if isImporting {
            HStack(spacing: 8) {
                ProgressView().tint(Color.moss)
                Text("Sealing your photos…")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
            }
        } else if failedImportCount > 0 {
            Text(importFailureMessage)
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.dustyRose)
                .fernletWrappingText()
        }
        Text(privacyFootnote)
            .font(.fernlet(.bodySmall))
            .foregroundStyle(Color.slate)
            .fernletWrappingText()
    }

    private var importFailureMessage: String {
        failedImportCount == 1
            ? "One photo couldn't be saved, so nothing was written for it."
            : "\(failedImportCount) photos couldn't be saved, so nothing was written for them."
    }

    /// Says only what is true for THIS device's configuration: the seal is unconditional, the lock
    /// clause is not — promising "behind your Fernlet lock" with no lock configured would be a claim
    /// the app can't keep.
    private var privacyFootnote: String {
        gateActive
            ? "Your wall stays on this device, encrypted at rest and behind your Fernlet lock. Fernlet never sends these anywhere."
            : "Your wall stays on this device and is encrypted at rest. Fernlet never sends these anywhere. Set a Fernlet lock in Settings to keep it behind a passcode too."
    }

    /// The empty wall keeps the three decorative polaroids the placeholder shipped — they are the
    /// surface's visual language, and they read as an invitation rather than a promise now that the
    /// copy beneath them describes an action the user can actually take.
    private var emptyWall: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: -8) {
                PolaroidTile(color: .fern.opacity(0.45), caption: "today", rotation: -2)
                PolaroidTile(color: .dustyRose.opacity(0.38), caption: "people", rotation: 2)
                PolaroidTile(color: .goldenrod.opacity(0.45), caption: "places", rotation: -1)
            }
            .accessibilityHidden(true)
            EmptyState(text: "Nothing pinned up yet. Add a few photos you want to keep close — the ordinary ones count.")
            addControl
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var populatedWall: some View {
        // 116pt is the polaroid's own footprint (a 98pt print inside 7pt side margins) plus a little
        // slack for the tilt, so an adaptive column can never be narrower than the tile it holds.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 12)], alignment: .leading, spacing: 18) {
            addTile
            ForEach(Array(library.photos.enumerated()), id: \.element.id) { index, record in
                Button {
                    selectedPhoto = record
                } label: {
                    PhotoWallTile(
                        record: record,
                        rotation: Self.tilt(forIndex: index),
                        loadData: { library.imageData(for: record.id) }
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("personal.photoWall")
        // Belt-and-suspenders with the reveal gate, which only governs decoding: an already-decoded
        // wall must not survive into the app-switcher snapshot either.
        .overlay {
            if redactForSnapshot { snapshotCover }
        }
    }

    /// The leading "＋" cell, drawn as an empty polaroid frame so the add affordance sits in the
    /// same visual vocabulary as the photos it adds.
    private var addTile: some View {
        Button {
            isPresentingPicker = true
        } label: {
            VStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.moss.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(width: 98, height: 86)
                    .overlay {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.moss)
                    }
                Text("add")
                    .font(.fernlet(.bubble))
                    .foregroundStyle(Color.slate.opacity(0.58))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.top, 7)
            .padding(.bottom, 14)
            .background(Color.cream.opacity(0.82), in: RoundedRectangle(cornerRadius: 4))
            .shadow(color: Color.bark.opacity(0.08), radius: 12, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add photos")
        .accessibilityIdentifier("personal.photoWall.add")
    }

    /// The prominent first-run add button. Once the wall has photos the add affordance becomes the
    /// polaroid-shaped ``addTile`` in the grid instead, so there is never more than one on screen.
    private var addControl: some View {
        Button {
            isPresentingPicker = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 16, weight: .semibold))
                Text("Add photos")
                    .font(.fernlet(.label))
            }
            .foregroundStyle(Color.cream)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.moss, in: Capsule())
            .fernletSmallShadow()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("personal.photoWall.addFirst")
    }

    // MARK: - Locked / redacted states

    /// Shown when a Fernlet lock is configured and the app is locked. No unlock button by design:
    /// the Private hub's own gate is what unlocks this page, and a second entry point would mean two
    /// things racing to re-lock it afterwards.
    private var lockedPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.moss)
            Text("Your photo wall is private")
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
            Text("These photos sit behind your Fernlet lock. Unlock Fernlet to see the wall.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    /// Opaque cover used to redact the wall in the app-switcher snapshot.
    private var snapshotCover: some View {
        ZStack {
            Rectangle().fill(Color.cream)
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

    // MARK: - Import

    /// Loads each pick's bytes and seals them, one at a time.
    ///
    /// Sequential on purpose: each `add` is a synchronous ImageIO downscale plus an AES-GCM seal plus
    /// a full sealed-index rewrite, and the index rewrite is read-modify-write — running these
    /// concurrently would have two passes racing on the same index and silently losing records.
    ///
    /// Only `Data` is loaded, never a `UIImage`: the store performs the single bounded decode, so a
    /// large pick never materialises a full-resolution bitmap here.
    private func importPickedItems(_ items: [PhotosPickerItem]) async {
        isImporting = true
        failedImportCount = 0
        var failures = 0
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                // The bytes never arrived (iCloud eviction, transfer error) — count it so the pick
                // can't disappear without explanation.
                failures += 1
                continue
            }
            if !library.add(data, capturedAt: Date()) { failures += 1 }
        }
        pickedItems = []
        failedImportCount = failures
        isImporting = false
    }

    /// Deterministic per-position tilt, so a tile keeps the same hand-placed angle across renders
    /// (a random one would visibly re-scatter the wall on every scroll).
    private static func tilt(forIndex index: Int) -> Double {
        let angles: [Double] = [-2, 1.5, -1, 2, -1.5, 1]
        return angles[index % angles.count]
    }
}

/// One polaroid on the wall: the sealed bytes for a record, its caption (or its date when it has
/// none), and a fixed tilt.
///
/// Bytes load in `.task` and are cached in `@State`, so the decrypt happens once per tile rather
/// than on every body pass; the JPEG decode itself is left to ``PolaroidTile``, matching how
/// `HomeView`'s photowall strip feeds it. Stored photos are already bounded to 1600px by the sealed
/// store's normalization, so there is no full-resolution decode to avoid here.
struct PhotoWallTile: View {
    let record: ProgressPhotoRecord
    let rotation: Double
    let loadData: () -> Data?

    @State private var imageData: Data?

    /// The user's own caption when there is one, else the photo's date — a polaroid always has
    /// something written under the print.
    private var caption: String {
        record.caption ?? record.capturedAt.formatted(.dateTime.month(.abbreviated).day())
    }

    private var accessibilityDescription: String {
        let date = record.capturedAt.formatted(.dateTime.month(.wide).day().year())
        guard let caption = record.caption else { return "Photo from \(date)" }
        return "Photo from \(date), \(caption)"
    }

    var body: some View {
        PolaroidTile(
            color: Color.softTaupe.opacity(0.35),
            caption: caption,
            rotation: rotation,
            imageData: imageData,
            imageWidth: 98,
            imageHeight: 86
        )
        .task {
            guard imageData == nil else { return }
            imageData = loadData()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }
}

/// Full view of one wall photo: the picture, an editable caption and date, and delete.
///
/// No share affordance, deliberately — these are private keepsakes and the app never offers to send
/// them anywhere (the same call ``ProgressPhotoDetailView`` makes for body photos). The whole sheet
/// is redacted from the app-switcher snapshot, caption and date included: a note about a photo is as
/// personal as the photo.
struct PhotoWallDetailView: View {
    var library: PhotoWallLibrary
    let record: ProgressPhotoRecord
    /// Passed in rather than read from `@Environment` — see the presenting sheet's note.
    let lockService: FernletLockService

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: UIImage?
    @State private var caption: String
    @State private var capturedAt: Date
    @State private var pendingDestructiveAction: DestructiveConfirmation?
    @FocusState private var captionFocused: Bool

    private var redactForSnapshot: Bool { scenePhase != .active }

    private var gateActive: Bool {
        lockService.isLockConfigured && !UITestSupport.bypassPrivateLockGate
    }

    /// Fail-closed at the reveal seam: don't decrypt the sealed bytes at all until unlocked.
    private var canReveal: Bool {
        guard gateActive else { return true }
        if case .unlocked = lockService.state { return true }
        return false
    }

    init(library: PhotoWallLibrary, record: ProgressPhotoRecord, lockService: FernletLockService) {
        self.library = library
        self.record = record
        self.lockService = lockService
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
                            .fill(Color.softTaupe.opacity(0.3))
                            .frame(height: 320)
                            .overlay {
                                Image(systemName: "photo")
                                    .font(.largeTitle)
                                    .foregroundStyle(Color.slate.opacity(0.4))
                            }
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Date")
                    // Imports are stamped "now" (the EXIF-date reader lives in `PhotoCaptureControl`'s
                    // private helper, out of reach of the picker path this wall uses), so an older
                    // photo needs a way back to its real date. Capped at today, and persisted through
                    // the same fail-closed sealed-index rewrite as the caption.
                    DatePicker("Date", selection: $capturedAt, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .tint(Color.moss)
                        .accessibilityIdentifier("photoWall.datePicker")
                        .onChange(of: capturedAt) { _, newValue in
                            library.updateCapturedAt(id: record.id, date: newValue)
                        }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Caption")
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
                        // A multiline (axis: .vertical) TextField treats Return as a newline and never
                        // fires `onSubmit`, so the save affordances are the keyboard "Done" below plus
                        // the onDisappear backstop — the same pair `ProgressPhotoDetailView` uses.
                        .accessibilityIdentifier("photoWall.caption")
                }

                Button(role: .destructive) {
                    pendingDestructiveAction = DestructiveConfirmation(
                        title: "Delete this photo?",
                        message: "This removes it from your wall and from this device. Fernlet can't undo this.",
                        confirmLabel: "Delete",
                        auditEvent: "photoWall.deleteConfirmed",
                        perform: {
                            library.delete(id: record.id)
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
                .accessibilityIdentifier("photoWall.delete")
            }
            .padding(20)
        }
        .background(Color.parchment)
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
        .navigationTitle("Photo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    saveCaption()
                    dismiss()
                }
                .font(.fernlet(.label))
                .tint(Color.moss)
            }
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
        // Keyed on the lock state so the decode runs (and re-runs) the moment the gate opens, and so a
        // lock engaged while this sheet is up leaves nothing new decrypted.
        .task(id: lockService.state) {
            // Decode off the main thread; only the finished image lands back on the MainActor.
            guard canReveal, image == nil, let data = library.imageData(for: record.id) else { return }
            image = await UIImage(data: data)?.byPreparingForDisplay()
        }
        // Backstop for a caption the user typed and then swiped away from with the keyboard still up.
        // Idempotent with both "Done" buttons.
        .onDisappear { saveCaption() }
        // Routes through the shared destructive-confirmation so the delete both warns and leaves an
        // audit trail, like every other irreversible action in the app.
        .destructiveConfirmation($pendingDestructiveAction)
        // A sheet outlives the hub gate underneath it: SwiftUI does not fire `onDisappear` on a view a
        // sheet covers, so if the app locks while this is open the hub's gate can't cover it. Gate the
        // sheet itself — but with `shouldLockOnDisappear: { false }`, because closing it returns to the
        // still-visible, still-gated wall, and a second re-locker here would cost a fresh Face ID per
        // photo (the exact bug the progress-photo detail's veto exists to avoid).
        .fernletLockGate(active: gateActive, shouldLockOnDisappear: { false })
    }

    private func saveCaption() {
        library.updateCaption(id: record.id, caption: caption)
    }
}
#endif
