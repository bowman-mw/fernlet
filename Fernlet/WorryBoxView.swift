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
import PrivateMemoryStore

// MARK: - Entry (First Aid)

/// Write a worry, then "let it go": the words tuck down into the box, a lid closes over
/// them with a soft seal glow, and the worry is sealed away.
struct WorryEntryView: View {
    var worryBox: WorryBoxService

    /// The compose → release → confirmation flow.
    private enum Phase { case writing, releasing, tucked }

    @State private var text = ""
    @State private var phase: Phase = .writing
    @State private var releasedText = ""
    @State private var gentleError: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isEditorFocused: Bool

    private static let characterLimit = 300

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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: phase == .writing ? .top : .center)
        .background(Color.parchment)
        .navigationTitle("Worry Box")
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

            TextEditor(text: $text)
                .focused($isEditorFocused)
                .frame(minHeight: 150, maxHeight: 220)
                .padding(12)
                .scrollContentBackground(.hidden)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .font(.fernlet(.body))
                .onChange(of: text) { _, newValue in
                    if newValue.count > Self.characterLimit {
                        text = String(newValue.prefix(Self.characterLimit))
                    }
                }
                .accessibilityLabel("Worry text")

            HStack(spacing: 8) {
                Image(systemName: "lock")
                    .font(.caption)
                    .foregroundStyle(Color.slate)
                Text("Stays sealed on this device only — worries never sync anywhere.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }

            if let gentleError {
                Text(gentleError)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.terracotta)
                    .fernletWrappingText()
            }

            Button {
                letGo()
            } label: {
                Text("Let it go")
                    .font(.fernlet(.label))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.moss, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            .accessibilityIdentifier("firstAid.worry.letGo")
        }
    }

    private var letGoConfirmation: some View {
        VStack(spacing: 0) {
            SealedBoxView()
                .padding(.bottom, 30)

            Text("Tucked away.")
                .font(.fernlet(.display))
                .foregroundStyle(Color.bark)
                .padding(.bottom, 12)

            Text("You can set it down for now. It's kept safe in the Worry Box on your Personal tab, sealed on this device.")
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
                    .foregroundStyle(.white)
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
            // purely the animation.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(2200))
                withAnimation(.easeOut(duration: 0.4)) { phase = .tucked }
            }
        } catch {
            gentleError = "The box couldn't quite close just now. Your words are still here — try once more in a moment."
        }
    }
}

// MARK: - Tuck-into-the-box release animation

/// The "let it go" motif: the words lift and shrink down into an open box, the lid swings
/// closed over them, and a soft amber seal-glow pulses. Purely decorative — the worry is
/// sealed in the store before this appears.
private struct TuckIntoBoxView: View {
    var worryText: String

    @State private var tucked = false      // words sink + shrink into the box
    @State private var lidClosed = false   // lid rotates down over the opening
    @State private var sealGlow = false    // amber halo blooms once sealed

    // Warm wood tones for the box — outside the shared palette, so kept local.
    private let boxBody = Color(red: 0.745, green: 0.561, blue: 0.322)
    private let boxLid = Color(red: 0.796, green: 0.627, blue: 0.388)
    private let boxInside = Color(red: 0.306, green: 0.227, blue: 0.133)

    var body: some View {
        VStack(spacing: 0) {
            Text("Letting it go…")
                .font(.fernlet(.bubble))
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
                    .shadow(color: .bark.opacity(0.16), radius: 12, x: 0, y: 8)
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
        withAnimation(.easeIn(duration: 0.9)) { tucked = true }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.62).delay(1.05)) { lidClosed = true }
        withAnimation(.easeOut(duration: 0.9).delay(1.7)) { sealGlow = true }
    }
}

/// The settled, latched box shown on the "Tucked away." confirmation — a soft amber halo
/// pulses gently around it.
private struct SealedBoxView: View {
    @State private var pulse = false

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
            withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

// MARK: - Hub section (Personal tab)

/// The kept worries, re-readable and releasable. Sits inside PrivateHubView, so the
/// standard lock gate covers it exactly like the other private sections.
struct WorryBoxView: View {
    var worryBox: WorryBoxService
    @State private var composeText = ""
    @State private var releasingID: WorryNarrative.ID?
    @State private var emberLifted = false
    @FocusState private var isComposeFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(title: "Worry Box", subtitle: "SET DOWN, NOT CARRIED", subtitleFirst: true, identifier: "screen.worryBox")

                Text("Worries you've set down. They stay sealed on this device only — releasing one lets it go for good.")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()

                composer

                if worryBox.worries.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 10) {
                        ForEach(worryBox.worries) { worry in
                            worryCard(worry)
                        }
                    }
                    .animation(.easeOut(duration: 0.45), value: worryBox.worries.count)
                }
            }
            .padding(20)
        }
        .background(Color.parchment)
        .onAppear { worryBox.reload() }
    }

    private var composer: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Something circling around?", text: $composeText, axis: .vertical)
                    .focused($isComposeFocused)
                    .lineLimit(1...4)
                    .font(.fernlet(.body))
                Button {
                    guard (try? worryBox.addWorry(composeText)) != nil else { return }
                    composeText = ""
                    isComposeFocused = false
                } label: {
                    Label("Let it go", systemImage: "archivebox")
                        .font(.fernlet(.label))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            }
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
                Text("That's a good thing. When something feels heavy, First aid on the Home screen can tuck it in here.")
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
        let releasing = releasingID == worry.id
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
                    Text(worry.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                    Spacer(minLength: 12)
                    Button {
                        release(worry)
                    } label: {
                        Label("Release this worry", systemImage: "arrow.up")
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.goldenrod)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Release this worry")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .bark.opacity(0.05), radius: 3, x: 0, y: 1)
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
                        .foregroundStyle(Color.goldenrod)
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Ember-lift release: dim the row, float a warm ember up out of it, then remove it from
    /// the sealed store. The store call is the real deletion; the wait is only the animation.
    private func release(_ worry: WorryNarrative) {
        guard releasingID == nil else { return }
        emberLifted = false
        withAnimation(.easeOut(duration: 0.3)) { releasingID = worry.id }
        withAnimation(.easeOut(duration: 1.1)) { emberLifted = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(760))
            withAnimation(.easeOut(duration: 0.45)) {
                worryBox.release(worry.id)
            }
            releasingID = nil
            emberLifted = false
        }
    }
}
