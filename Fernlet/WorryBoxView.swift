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

/// Write a worry, then "let it go": the note drifts down into the box and is sealed away.
struct WorryEntryView: View {
    var worryBox: WorryBoxService
    @State private var text = ""
    @State private var isLettingGo = false
    @State private var didLetGo = false
    @State private var gentleError: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isEditorFocused: Bool

    private static let characterLimit = 300

    var body: some View {
        VStack(spacing: 20) {
            if didLetGo {
                letGoConfirmation
            } else {
                composer
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.parchment)
        .navigationTitle("Worry Box")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What's circling around? Write it down — the box can hold it for a while so you don't have to.")
                .font(.subheadline)
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            TextEditor(text: $text)
                .focused($isEditorFocused)
                .frame(minHeight: 110, maxHeight: 160)
                .padding(10)
                .scrollContentBackground(.hidden)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
                .font(.body)
                .onChange(of: text) { _, newValue in
                    if newValue.count > Self.characterLimit {
                        text = String(newValue.prefix(Self.characterLimit))
                    }
                }
                .accessibilityLabel("Worry text")

            Text("Stays sealed on this device only — worries never sync anywhere.")
                .font(.caption.italic())
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            if let gentleError {
                Text(gentleError)
                    .font(.caption)
                    .foregroundStyle(Color.terracotta)
                    .fernletWrappingText()
            }

            Button {
                letGo()
            } label: {
                Label("Let it go", systemImage: "archivebox")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.moss, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLettingGo)
            .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            .accessibilityIdentifier("firstAid.worry.letGo")
        }
        // Placeholder "let it go" animation (composer gently sinks + fades before the
        // confirmation appears) — flagged for design-mockup refinement.
        .offset(y: isLettingGo ? 60 : 0)
        .opacity(isLettingGo ? 0 : 1)
        .scaleEffect(isLettingGo ? 0.9 : 1)
    }

    private var letGoConfirmation: some View {
        VStack(spacing: 16) {
            Image(systemName: "archivebox.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Color.goldenrod)
                .frame(width: 72, height: 72)
                .background(Color.goldenrod.opacity(0.14), in: Circle())
            Text("Tucked away.")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.bark)
            Text("You can set it down for now. It's kept safe in the Worry Box on your Personal tab, whenever — if ever — you want to look again.")
                .font(.subheadline)
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
            HStack(spacing: 14) {
                Button("Another") {
                    text = ""
                    didLetGo = false
                    isLettingGo = false
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.moss)
                Button("Done") { dismiss() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.moss)
            }
        }
        .padding(.top, 40)
        .transition(.opacity)
    }

    private func letGo() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isLettingGo else { return }
        do {
            try worryBox.addWorry(trimmed)
            gentleError = nil
            isEditorFocused = false
            withAnimation(.easeIn(duration: 0.6)) { isLettingGo = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(620))
                withAnimation(.easeOut(duration: 0.4)) { didLetGo = true }
            }
        } catch {
            gentleError = "The box couldn't quite close just now. Your words are still here — try once more in a moment."
        }
    }
}

// MARK: - Hub section (Personal tab)

/// The kept worries, re-readable and releasable. Sits inside PrivateHubView, so the
/// standard lock gate covers it exactly like the other private sections.
struct WorryBoxView: View {
    var worryBox: WorryBoxService
    @State private var composeText = ""
    @FocusState private var isComposeFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(title: "Worry Box", subtitle: "SET DOWN, NOT CARRIED", subtitleFirst: true, identifier: "screen.worryBox")

                Text("Worries you've set down. They stay sealed on this device only — releasing one lets it go for good.")
                    .font(.subheadline)
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
                    .font(.body)
                Button {
                    guard (try? worryBox.addWorry(composeText)) != nil else { return }
                    composeText = ""
                    isComposeFocused = false
                } label: {
                    Label("Let it go", systemImage: "archivebox")
                        .font(.subheadline.weight(.semibold))
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
        VStack(spacing: 10) {
            Image(systemName: "archivebox")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.goldenrod)
            Text("The box is empty right now.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.bark)
            Text("That's a good thing. When something feels heavy, First aid on the Home screen can tuck it in here.")
                .font(.caption)
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func worryCard(_ worry: WorryNarrative) -> some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(worry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.slate)
                Text(worry.text)
                    .font(.callout)
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
                Button {
                    // Placeholder release animation (card fades from the list) — flagged
                    // for design-mockup refinement alongside the entry animation.
                    withAnimation(.easeOut(duration: 0.45)) {
                        worryBox.release(worry.id)
                    }
                } label: {
                    Label("Release", systemImage: "wind")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.moss)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.moss.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Release this worry")
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }
}
