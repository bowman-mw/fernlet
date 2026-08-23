//
//  WorryBoxView.swift
//  Fernlet
//
//  The Worry Box surfaces: the write-and-let-go entry flow (hosted in First Aid) and the
//  Private-hub section that lists kept worries with a per-worry "release" (delete).
//  Storage is sealed + device-only (WorryBoxService / WorryNarrativeRepository) — worries
//  never sync, never feed memories, and are deliberately absent from SealedBackup.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import PrivateMemoryStore
import FernletUI

// MARK: - Entry (First Aid)

/// Write a worry, then "let it go": the words tuck down into the box, a lid closes over
/// them with a soft seal glow, and the worry is sealed away.
///
/// The First Aid entry point (pushed from ``FirstAidView``), capped at 300 characters. The seal is
/// real before the theater starts — ``WorryBoxService/addWorry(_:)`` writes the sealed row first,
/// then the ~2.2s `TuckIntoBoxView` animation plays and settles onto the confirmation. A failed
/// write keeps the text in the editor with a gentle retry message.
struct WorryEntryView: View {
    var worryBox: WorryBoxService

    /// The compose → release → confirmation flow.
    ///
    /// `releasing` exists only for the tuck animation; the worry is already sealed by the time it
    /// begins.
    private enum Phase { case writing, releasing, tucked }

    @State private var text = ""
    @State private var phase: Phase = .writing
    @State private var releasedText = ""
    @State private var gentleError: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isEditorFocused: Bool

    /// The composer's cap — the same constant the sealed-store entry point enforces.
    private static let characterLimit = WorryBoxService.maxCharacters

    /// How long the tuck theater runs before the confirmation settles. Reduce Motion collapses the
    /// sequence to a crossfade, so the wait collapses with it.
    private var tuckDuration: Duration { reduceMotion ? .milliseconds(600) : .milliseconds(2200) }

    var body: some View {
        VStack(spacing: 20) {
            switch phase {
            case .writing:
                composer
            case .releasing:
                TuckIntoBoxView(worryText: releasedText)
            case .tucked:
                letGoConfirmation
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Color.parchment)
        .navigationTitle("Worry box")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What's circling around?")
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()

            Text("Write it down — the box can hold it for a while, so you don't have to.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            worryEditor

            if text.count > 260 {
                Text("The box holds about 300 characters.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }

            HStack(spacing: 8) {
                Image(systemName: "lock")
                    .font(.caption)
                    .foregroundStyle(Color.slate)
                Text("Stays sealed on this device only — worries never sync anywhere.")
                    .font(.fernlet(.bubble))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }

            if let gentleError {
                Text(gentleError)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.terracotta)
                    .fernletWrappingText()
            }

            letGoButton
        }
        // Arriving here from First aid is a heavy moment — the keyboard should already be up
        // rather than costing one more tap.
        .onAppear { isEditorFocused = true }
    }

    /// The worry text editor: placeholder overlay, the 300-character cap, and its a11y label.
    private var worryEditor: some View {
        TextEditor(text: $text)
            .focused($isEditorFocused)
            .frame(minHeight: 180, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .font(.fernlet(.body))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("It's alright. Just start typing…")
                        .font(.custom(FernletFontName.instrumentSerifItalic, size: 17, relativeTo: .body))
                        .foregroundStyle(Color.slate.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .padding(12)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .onChange(of: text) { _, newValue in
                if newValue.count > Self.characterLimit {
                    text = String(newValue.prefix(Self.characterLimit))
                }
            }
            .accessibilityLabel("Worry text")
    }

    /// The "Let it go" button — disabled until there is something to seal.
    private var letGoButton: some View {
        Button {
            letGo()
        } label: {
            let disabled = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Text("Let it go")
                .font(.fernlet(.label))
                .foregroundStyle(disabled ? Color.moss.opacity(0.55) : Color.parchmentInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(disabled ? Color.moss.opacity(0.18) : Color.moss,
                            in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("firstAid.worry.letGo")
    }

    private var letGoConfirmation: some View {
        VStack(spacing: 0) {
            SealedBoxView()
                .padding(.bottom, 30)

            Text("Tucked away.")
                .font(.fernlet(.display))
                .foregroundStyle(Color.bark)
                .padding(.bottom, 12)

            Text("You can set it down for now. It's kept safe in the Worry box on your Private tab, sealed on this device.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
                .frame(maxWidth: 280)
                .padding(.bottom, 34)

            Button {
                text = ""
                withAnimation(.easeOut(duration: 0.3)) { phase = .writing }
            } label: {
                Text("Write another")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.parchmentInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.moss, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 300)
            .padding(.bottom, 10)

            Button("Done") { dismiss() }
                .font(.fernlet(.label))
                .foregroundStyle(Color.slate)
        }
        .transition(.opacity)
    }

    private func letGo() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, phase == .writing else { return }
        do {
            try worryBox.addWorry(trimmed)
            gentleError = nil
            isEditorFocused = false
            releasedText = trimmed
            withAnimation(.easeInOut(duration: 0.4)) { phase = .releasing }
            // The tuck (words sink) + lid close + seal glow run for ~2.2s; then settle onto
            // the confirmation. The worry is already sealed in the store above — the wait is
            // purely the animation, so Reduce Motion shortens it with the animation.
            Task { @MainActor in
                do {
                    try await Task.sleep(for: tuckDuration)
                } catch {
                    // Cancelled: the entry view is gone; the worry is already sealed, so there is
                    // nothing to undo and no state left to settle.
                    return
                }
                withAnimation(.easeOut(duration: 0.4)) { phase = .tucked }
            }
        } catch {
            // Spoken as well as shown: the line renders above a text field the user is still
            // looking at, but nothing moves focus to it, so a blind user's only evidence that the
            // seal failed would be that the entry view did not go away. The EVENT, never the
            // worry — the words in the field are the reason this screen is sealed at all.
            let failure = "The box couldn't quite close just now. Your words are still here — try once more in a moment."
            gentleError = failure
            FernletAnnouncer.system.announce(.error, resolved: failure)
        }
    }
}

// MARK: - Tuck-into-the-box release animation

/// The "let it go" motif: the words lift and shrink down into an open box, the lid swings
/// closed over them, and a soft amber seal-glow pulses.
///
/// Purely decorative — the worry is sealed in the store before this appears. Shown by
/// ``WorryEntryView`` during its `releasing` phase and hidden from accessibility.
private struct TuckIntoBoxView: View {
    var worryText: String

    @State private var tucked = false      // words sink + shrink into the box
    @State private var lidClosed = false   // lid rotates down over the opening
    @State private var sealGlow = false    // amber halo blooms once sealed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Warm wood tones for the box — outside the shared palette, so kept local.
    private let boxBody = Color(red: 0.745, green: 0.561, blue: 0.322)
    private let boxLid = Color(red: 0.796, green: 0.627, blue: 0.388)
    private let boxInside = Color(red: 0.306, green: 0.227, blue: 0.133)

    var body: some View {
        VStack(spacing: 0) {
            Text("Letting it go…")
                .font(.custom(FernletFontName.instrumentSerifItalic, size: 18, relativeTo: .body))
                .foregroundStyle(Color.slate)
                .padding(.bottom, 30)

            ZStack(alignment: .bottom) {
                // The worry note, drifting down into the box and fading as it goes.
                Text(worryText)
                    .font(.fernlet(.bubble))
                    .foregroundStyle(Color.bark)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 200)
                    .background(Color.cream, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: Color.barkShadow.opacity(0.16), radius: 12, x: 0, y: 8)
                    .scaleEffect(tucked ? 0.32 : 1)
                    .offset(y: tucked ? 92 : -110)
                    .opacity(tucked ? 0 : 1)

                box
            }
            .frame(width: 230, height: 250)
        }
        .onAppear(perform: runSequence)
    }

    private var box: some View {
        ZStack {
            // Inner shadow / opening
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(boxInside)
                .frame(width: 160, height: 102)
                .offset(y: -6)

            // Front face
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(colors: [boxLid, boxBody], startPoint: .top, endPoint: .bottom)
                )
                .frame(width: 174, height: 72)
                .offset(y: 22)

            // Clasp
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.goldenrod)
                .frame(width: 18, height: 15)
                .offset(y: 30)

            // The lid, hinged at its lower edge, swinging closed over the opening.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(colors: [boxLid, boxBody], startPoint: .top, endPoint: .bottom)
                )
                .frame(width: 182, height: 34)
                .rotationEffect(.degrees(lidClosed ? 0 : -104), anchor: .bottom)
                .offset(y: -34)

            // Seal glow bloom
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.goldenrod.opacity(0.6), Color.goldenrod.opacity(0)],
                        center: .center, startRadius: 0, endRadius: 45
                    )
                )
                .frame(width: 90, height: 90)
                .scaleEffect(sealGlow ? 1.5 : 0.6)
                .opacity(sealGlow ? 0 : 0.9)
                .offset(y: -6)
        }
        .frame(width: 182, height: 122)
        .accessibilityHidden(true)
    }

    private func runSequence() {
        guard !reduceMotion else {
            // Reduce Motion: one short crossfade to the sealed state instead of the sinking note,
            // the swinging lid, and the blooming glow.
            withAnimation(.easeInOut(duration: 0.35)) {
                tucked = true
                lidClosed = true
                sealGlow = true
            }
            return
        }
        withAnimation(.easeIn(duration: 0.9)) { tucked = true }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.62).delay(1.05)) { lidClosed = true }
        withAnimation(.easeOut(duration: 0.9).delay(1.7)) { sealGlow = true }
    }
}

/// The settled, latched box shown on the "Tucked away." confirmation — a soft amber halo
/// pulses gently around it.
///
/// Static decoration for ``WorryEntryView``'s `tucked` phase; hidden from accessibility.
private struct SealedBoxView: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let boxBody = Color(red: 0.745, green: 0.561, blue: 0.322)
    private let boxLid = Color(red: 0.796, green: 0.627, blue: 0.388)

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.goldenrod.opacity(0.22), Color.goldenrod.opacity(0)],
                        center: .center, startRadius: 0, endRadius: 95
                    )
                )
                .frame(width: 180, height: 180)
                .scaleEffect(pulse ? 1.06 : 0.94)
                .opacity(pulse ? 0.9 : 0.55)

            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [boxLid, boxBody], startPoint: .top, endPoint: .bottom))
                    .frame(width: 138, height: 30)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [boxLid, boxBody], startPoint: .top, endPoint: .bottom))
                    .frame(width: 134, height: 74)
                    .offset(y: -2)
            }
            .overlay(alignment: .center) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.goldenrod)
                    .frame(width: 18, height: 15)
                    .offset(y: 6)
            }
            .shadow(color: Color(red: 0.353, green: 0.267, blue: 0.133).opacity(0.28), radius: 14, x: 0, y: 10)
        }
        .frame(width: 180, height: 150)
        .accessibilityHidden(true)
        .onAppear {
            // A forever-repeating halo is exactly the continuous motion Reduce Motion exists to
            // stop — hold the glow still instead.
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

// MARK: - Hub section (Personal tab)

/// The kept worries, re-readable and releasable, plus an inline composer.
///
/// The Private-hub section for the Worry Box: sits inside ``PrivateHubView``, so the standard
/// lock gate covers it exactly like the other private sections. Reads
/// ``WorryBoxService/worries`` (empty while locked), reloads on appear, and per-worry "Release"
/// plays the ember-lift animation before ``WorryBoxService/release(_:)`` performs the real
/// deletion.
///
/// The delete waits out a short "Keep it" window behind an undo strip, on Mail's Undo Send terms:
/// undo is available while the user is on the page, and leaving (or backgrounding) COMMITS the
/// release rather than reverting it. Every ending — the timer, a second release, disappearing,
/// backgrounding — funnels through ``claimPendingRelease()``, which consumes the worry exactly
/// once, so no pair of them can delete twice.
struct WorryBoxView: View {
    var worryBox: WorryBoxService
    @State private var composeText = ""
    /// The worry whose ember is currently lifting — the row is still listed (dimmed, with the ember
    /// overlay) and its sealed row is untouched until the lift finishes.
    @State private var releasingWorry: WorryNarrative?
    @State private var emberLifted = false
    /// Gentle copy shown when a sealed write or a release did not land (never a silent failure).
    @State private var composeError: String?
    @State private var releaseError: String?
    /// The worry whose ember has lifted but whose sealed row is NOT deleted yet — the page hides it
    /// and offers "Keep it" for a few seconds first. Releasing is permanent, so the ceremony gets an
    /// honest way back instead of a dialog in front of it.
    @State private var pendingRelease: WorryNarrative?
    /// The timer that commits ``pendingRelease``. Cancelled by "Keep it".
    @State private var pendingReleaseTask: Task<Void, Never>?
    /// The ember-lift animation for a release that has been tapped but has not reached its "Keep it"
    /// window yet. Held so a commit path can end it: an unstructured `Task` outlives the view, and
    /// would otherwise land `pendingRelease` and a fresh timer on state that no longer exists.
    @State private var emberTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var isComposeFocused: Bool
    /// Puts VoiceOver on "Keep it" the moment the undo strip appears, so the undo is one activation
    /// away instead of an unknown number of swipes away inside a countdown.
    @AccessibilityFocusState private var isKeepItFocused: Bool

    /// How long a released worry can still be kept, for a user who can see the strip arrive and
    /// reach it with one tap.
    private static let keepItWindow: Duration = .seconds(6)

    /// The same window for someone driving the phone through an assistive technology.
    ///
    /// Six seconds is a *sighted-tap* budget. A VoiceOver user has to notice a new bottom overlay
    /// exists, swipe to it and double-tap; a Switch Control scan cannot finish a single pass of the
    /// page in six seconds at the default scan rate. This gates the PERMANENT deletion of a sealed
    /// row that is deliberately absent from `SealedBackup` — there is no second chance anywhere — so
    /// the window stretches toward Mail's Undo Send (10–30 s), which this screen's own doc comment
    /// names as its model.
    ///
    /// The number itself now lives on ``FernletDismissalWindow`` — this screen was where it was
    /// first reasoned out, and the rest of the app's transient surfaces adopted the same value in
    /// batch A3 rather than each inventing one.
    private static let assistiveKeepItWindow: Duration = FernletDismissalWindow.assistiveActionWindow

    /// The window in force right now.
    ///
    /// Read at the moment a release starts rather than cached, because VoiceOver and Switch Control
    /// can both be turned on mid-session (Siri, the accessibility shortcut, a Shortcuts automation).
    private var activeKeepItWindow: Duration {
        // The hand-rolled `UIAccessibility` read this screen shipped in batch A1 is now
        // ``FernletDismissalWindow`` — same decision, one place, and unit-testable through its
        // injected flag.
        FernletDismissalWindow.system.window(
            standard: Self.keepItWindow,
            assistive: Self.assistiveKeepItWindow)
    }

    /// The kept worries, minus one waiting out its "Keep it" window.
    private var visibleWorries: [WorryNarrative] {
        worryBox.worries.filter { $0.id != pendingRelease?.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(title: "Worry box", subtitle: "Set it down for a while.", identifier: "screen.worryBox")

                Text("Worries you've set down. The box keeps them — releasing one lets it go for good.")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()

                composer

                if let releaseError {
                    Text(releaseError)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.terracotta)
                        .fernletWrappingText()
                }

                if visibleWorries.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 10) {
                        ForEach(visibleWorries) { worry in
                            worryCard(worry)
                        }
                    }
                    .animation(.easeOut(duration: 0.45), value: visibleWorries.count)
                }
            }
            .padding(20)
        }
        .background(Color.parchment)
        .overlay(alignment: .bottom) { keepItToast }
        .onAppear { worryBox.reload() }
        // Leaving COMMITS the pending release — the same contract as Mail's Undo Send. The strip is
        // the undo affordance while the user is on the page; once the page is gone, the ceremony the
        // user just completed ("releasing one lets it go for good") must not quietly un-happen and
        // put the worry back with nothing said.
        .onDisappear { commitPendingRelease() }
        // Driven from the STRIP APPEARING, not from the release task that sets `pendingRelease`:
        // at that point the toast — and the "Keep it" button this focuses — has not been built yet,
        // so the focus request would land on nothing and the announcement would be the only channel.
        .onChange(of: pendingRelease?.id) { _, id in
            guard id != nil else { return }
            announceKeepItWindow()
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding takes the strip away just as thoroughly as leaving does, and the pending
            // timer can be suspended — or the app killed — long before its deadline. Commit here too,
            // synchronously, while there is still a runloop to do it on. `claimPendingRelease`
            // consumes the worry, so an `onDisappear` that follows finds nothing left to delete.
            if phase == .background { commitPendingRelease() }
        }
    }

    /// The "Released — Keep it" strip: the whole undo window, and the only thing standing between a
    /// tap and a permanent delete.
    @ViewBuilder
    private var keepItToast: some View {
        if pendingRelease != nil {
            HStack(spacing: 12) {
                Text("Released.")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                Spacer(minLength: 8)
                Button("Keep it") { keepPendingRelease() }
                    .font(.fernlet(.label))
                    // T1-3: text ink, not the `moss` accent (3.74:1, fails 4.5:1 small text) — this
                    // is the one control that undoes an otherwise-permanent deletion (T0-5).
                    .foregroundStyle(Color.mossInk)
                    .buttonStyle(.plain)
                    .fernletTapTarget(minWidth: 60)
                    .accessibilityFocused($isKeepItFocused)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color.cream, in: Capsule())
            .fernletSmallShadow()
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var composer: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Something circling around?", text: $composeText, axis: .vertical)
                    .focused($isComposeFocused)
                    .lineLimit(1...4)
                    .font(.fernlet(.body))
                    // R3: the same cap the sealed-store entry point enforces, applied where the
                    // text enters so the field cannot grow without bound.
                    .onChange(of: composeText) { _, newValue in
                        if newValue.count > WorryBoxService.maxCharacters {
                            composeText = String(newValue.prefix(WorryBoxService.maxCharacters))
                        }
                    }
                if let composeError {
                    Text(composeError)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.terracotta)
                        .fernletWrappingText()
                }
                // Disabled fades the FILL, never the label: at 0.45 opacity the whole button read as
                // an empty green bar with no readable word on it.
                let composeEmpty = composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button {
                    sealComposedWorry()
                } label: {
                    Label("Let it go", systemImage: "archivebox")
                        .font(.fernlet(.label))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(composeEmpty ? Color.moss.opacity(0.55) : Color.parchmentInk)
                        .background(composeEmpty ? Color.moss.opacity(0.18) : Color.moss,
                                    in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(composeEmpty)
            }
        }
    }

    /// Seals the hub composer's text, surfacing a gentle retry line when the sealed write fails.
    private func sealComposedWorry() {
        // The button is disabled when the field is blank; state it here too, so the entry point
        // carries its own precondition rather than relying on the caller's disabled state.
        guard !composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try worryBox.addWorry(composeText)
            composeText = ""
            isComposeFocused = false
            composeError = nil
        } catch {
            // The event, never the worry: the compose field keeps its text and the failure is
            // spoken so it is not discoverable only by noticing the list did not grow.
            let failure = "The box couldn't quite close just now — your words are still here."
            composeError = failure
            FernletAnnouncer.system.announce(.error, resolved: failure)
        }
    }

    private var emptyState: some View {
        HStack(spacing: 20) {
            Image(systemName: "archivebox")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Color.goldenrod.opacity(0.75))
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 5) {
                Text("The box is empty right now.")
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)
                Text("That's a good thing. Write one above whenever something feels heavy.")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func worryCard(_ worry: WorryNarrative) -> some View {
        let releasing = releasingWorry?.id == worry.id
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "archivebox")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color.goldenrod)
                .frame(width: 30, height: 30)
                .background(Color.goldenrod.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                Text(worry.text)
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
                HStack {
                    Text("Set down " + worry.createdAt.formatted(.relative(presentation: .named, unitsStyle: .wide)))
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                    Spacer(minLength: 12)
                    Button {
                        release(worry)
                    } label: {
                        Label("Release this worry", systemImage: "arrow.up")
                            .font(.fernlet(.labelSmall))
                            // Moss, not goldenrod: this is an action, and goldenrod on cream read as
                            // decoration rather than something tappable. T1-3: text ink, not the
                            // `moss` accent (3.74:1, fails 4.5:1 small text).
                            .foregroundStyle(Color.mossInk)
                    }
                    .buttonStyle(.plain)
                    // A labelSmall text link was a ~16pt-tall target for a permanent action.
                    .fernletTapTarget(minWidth: 0)
                    .accessibilityLabel("Release this worry")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .fernletSmallShadow()
        // The row lifts away like an ember on release: its words dim under a soft veil while a
        // warm ember rises and fades. When the ember has lifted, the store removes the row and
        // the list closes the gap.
        .opacity(releasing ? 0.25 : 1)
        .overlay {
            if releasing {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.goldenrod, Color.goldenrod.opacity(0)],
                                center: .center, startRadius: 0, endRadius: 14
                            )
                        )
                        .frame(width: 22, height: 22)
                        .offset(y: emberLifted ? -66 : 6)
                        .opacity(emberLifted ? 0 : 1)
                    Text("letting it go…")
                        .font(.fernlet(.bubble))
                        // T1-3: text ink, not the `goldenrod` accent (2.22:1).
                        .foregroundStyle(Color.goldenrodInk)
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Ember-lift release: dim the row, float a warm ember up out of it, then hold the sealed row
    /// back for a few seconds behind a "Keep it" strip before deleting it for real.
    ///
    /// The ceremony is unchanged — what changed is that it no longer destroys anything on its own.
    /// The page copy says releasing "lets it go for good", which is exactly why one small text link
    /// must not be able to do it on a mis-tap.
    private func release(_ worry: WorryNarrative) {
        guard releasingWorry == nil else { return }
        // A second release while one is still waiting: let the first one finish now rather than
        // silently extending — or dropping — its window.
        commitPendingRelease()
        emberLifted = false
        releaseError = nil
        withAnimation(.easeOut(duration: 0.3)) { releasingWorry = worry }
        withAnimation(.easeOut(duration: 1.1)) { emberLifted = true }
        emberTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(760))
            } catch {
                // Cancelled by a commit path (leaving the page, backgrounding, or a second release):
                // that path already claimed this worry and deleted it, so there is nothing left to
                // settle here.
                return
            }
            emberTask = nil
            withAnimation(.easeOut(duration: 0.45)) {
                releasingWorry = nil
                pendingRelease = worry
            }
            emberLifted = false
            startKeepItWindow(for: worry)
        }
    }

    /// Says the undo strip has arrived and hands VoiceOver the undo itself.
    ///
    /// The strip is a new bottom overlay that appears with no sound and no focus change: a blind
    /// user's first hint that the countdown to a permanent delete has started would otherwise be the
    /// worry's absence from the list afterwards.
    ///
    /// **Privacy:** the event only, never the worry. The text is sealed, and an announcement is
    /// spoken out loud to whoever is in the room.
    private func announceKeepItWindow() {
        isKeepItFocused = true
        FernletAnnouncer.system.announce(
            .status, LocalizedStringResource("Released. Keep it, if you'd rather it stayed.")
        )
    }

    /// Starts the undo window. When it elapses undisturbed, the sealed row is really deleted.
    private func startKeepItWindow(for worry: WorryNarrative) {
        pendingReleaseTask?.cancel()
        let window = activeKeepItWindow
        pendingReleaseTask = Task { @MainActor in
            do {
                try await Task.sleep(for: window)
            } catch {
                // Cancelled by "Keep it" (the worry stays) or by a commit path that has already
                // claimed it (the worry is already gone). Nothing to do either way.
                return
            }
            guard pendingRelease?.id == worry.id else { return }
            pendingReleaseTask = nil
            guard let claimed = withAnimation(.easeOut(duration: 0.3), { claimPendingRelease() }) else { return }
            performRelease(claimed)
        }
    }

    /// Claims the release in flight, clearing the pending state before handing back the worry.
    ///
    /// The single seam through which a worry becomes deletable: every path that can end the window
    /// (the timer, a second release, leaving the page, backgrounding) goes through here, and the
    /// state is consumed before the worry is returned — so two paths racing to end the same window
    /// can never hand the same worry to ``performRelease(_:)`` twice.
    ///
    /// Claims the ember-lift worry too, so a release tapped moments before the page went away is
    /// committed rather than stranded in a task the view no longer owns.
    private func claimPendingRelease() -> WorryNarrative? {
        pendingReleaseTask?.cancel()
        pendingReleaseTask = nil
        emberTask?.cancel()
        emberTask = nil
        guard let worry = pendingRelease ?? releasingWorry else { return nil }
        pendingRelease = nil
        releasingWorry = nil
        emberLifted = false
        return worry
    }

    /// Ends the window early and deletes now — used when a second release starts, when the page goes
    /// away, and when the app is backgrounded.
    private func commitPendingRelease() {
        guard let worry = claimPendingRelease() else { return }
        performRelease(worry)
    }

    /// Keeps the worry: cancels the pending delete and slides the row back into the list.
    private func keepPendingRelease() {
        pendingReleaseTask?.cancel()
        pendingReleaseTask = nil
        withAnimation(.easeOut(duration: 0.35)) { pendingRelease = nil }
    }

    /// The real deletion in the sealed store. The worry has already been consumed by
    /// ``claimPendingRelease()``, so this runs at most once per release.
    private func performRelease(_ worry: WorryNarrative) {
        let released = worryBox.release(worry.id)
        if !released {
            // The sealed row is still on disk (the service audited the failure); say so rather
            // than showing a letting-go that did not happen. On the leaving/backgrounding paths the
            // strip is already gone, but the worry stays in the box — so the list itself is the
            // honest answer when the user comes back.
            // Spoken too, because this is the one failure whose visible evidence is a NON-event:
            // the row simply stays in the list, which a VoiceOver user re-reading the list would
            // reasonably take for a release that has not animated out yet.
            let failure = "That one didn't quite lift just now — try again in a moment."
            releaseError = failure
            FernletAnnouncer.system.announce(.error, resolved: failure)
        }
    }
}
