import SwiftUI
import FernletDomainModel
import FernletUI

// G9-3 memory controls on Settings → Core memory (Docs/G9-Data-Integrity-Recovery-Plan-2026-11-15.md,
// Part 3): the "Let Fernlet remember" switch, forget by filters with a checklist preview, "Forget
// patterns" and "Delete all memories". Every delete goes through a tap the person makes on purpose:
// the switch and the two wipes through `DestructiveConfirmation`, the filters through "Forget these".
// Accessibility identifiers here are frozen tokens.

/// The "Let Fernlet remember" switch (owner call M2 = A).
///
/// Turning it on is immediate. Turning it off asks first, with two outcomes: "Turn off and delete"
/// (every Core memory goes too) and "Turn off, keep them". Either way journal capture and pattern-making
/// stop, and the patterns already worked out are deleted. The switch reads the synced setting, so it
/// snaps back on if the question is cancelled.
struct CoreMemoryRememberSection: View {
    @Bindable var store: FernletStore
    @Binding var pendingDestructiveAction: DestructiveConfirmation?

    var body: some View {
        FernletFramedSection("Remembering") {
            Toggle(isOn: rememberBinding) {
                FernletRowLabel(title: Text("Let Fernlet remember"),
                                detail: Text("Keeps the feeling of each journal entry and works out patterns from your days."))
                    .padding(.vertical, 7)
            }
            .accessibilityIdentifier("settings.memory.remember")
        }
    }

    private var rememberBinding: Binding<Bool> {
        Binding(
            get: { store.settings.memoryExtractionEnabled },
            set: { isOn in
                if isOn {
                    store.setMemoryExtraction(enabled: true, deleteExisting: false)
                } else {
                    confirmTurnOff()
                }
            }
        )
    }

    private func confirmTurnOff() {
        let count = store.memories.count
        pendingDestructiveAction = DestructiveConfirmation(
            title: "Stop remembering?",
            message: "Fernlet stops keeping memories from your journal and stops working out patterns, and deletes the patterns it has. You can delete the ^[\(count) memory](inflect: true) it kept as well, or keep them.",
            confirmLabel: "Turn off and delete",
            auditEvent: "settings.memory.extractionOff.deleteConfirmed",
            secondaryConfirm: .init(label: "Turn off, keep them",
                                    auditEvent: "settings.memory.extractionOff.keepConfirmed") {
                store.setMemoryExtraction(enabled: false, deleteExisting: false)
            }
        ) {
            store.setMemoryExtraction(enabled: false, deleteExisting: true)
        }
    }
}

/// Forget by filters (owner call M4 = B): the page's "forget …" words, an optional date range and the
/// feeling chips fill a checklist of matching memories, all ticked; unticking keeps one. Only the
/// "Forget these" tap deletes, and only the ticked ones, followed by a one-line confirmation.
struct MemoryForgetPanel: View {
    @Bindable var store: FernletStore
    /// The words typed after "forget" in the page's search field ("" for none).
    let words: String
    /// Whether the panel stays open with no words typed (opened by its button, or after a forget).
    @Binding var isOpen: Bool
    /// Closes the panel and clears the search field.
    let onClose: () -> Void

    @Environment(\.fernletTermOfAddress) private var termOfAddress
    @State private var limitsDates = false
    @State private var from = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var feelings: Set<FeelingTag> = []
    /// Ids the person unticked: kept. Anything else that matches is ticked.
    @State private var unticked: Set<UUID> = []
    /// How many memories the last "Forget these" let go of, for the confirmation line.
    @State private var lastForgotten: Int?

    private var filter: MemoryForgetFilter {
        MemoryForgetFilter(words: words, from: limitsDates ? from : nil, to: limitsDates ? to : nil, feelings: feelings)
    }

    var body: some View {
        let matches = filter.matches(in: store.memories)
        let ticked = matches.filter { !unticked.contains($0.id) }
        VStack(alignment: .leading, spacing: 12) {
            FernletFramedSection("Forget by filters") {
                if !filter.trimmedWords.isEmpty {
                    FernletRowLabel(title: Text("Words"), value: Text(verbatim: filter.trimmedWords))
                }
                Toggle(isOn: $limitsDates) { FernletRowLabel(title: Text("Only between two dates")) }
                    .accessibilityIdentifier("settings.memory.forget.dates")
                if limitsDates { dateRows }
                feelingChips
            }
            if let lastForgotten {
                Text("Done. Fernlet has let go of ^[\(lastForgotten) memory](inflect: true).")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
                    .accessibilityIdentifier("settings.memory.forget.done")
            }
            preview(matches: matches, ticked: ticked)
            Button("Done") { onClose() }
                .font(.fernlet(.label))
                .foregroundStyle(Color.slate)
                .frame(minHeight: 44)
                .accessibilityIdentifier("settings.memory.forget.close")
        }
    }

    @ViewBuilder private var dateRows: some View {
        DatePicker("From", selection: $from, in: ...to, displayedComponents: .date)
            .font(.fernlet(.body))
            .accessibilityIdentifier("settings.memory.forget.from")
        DatePicker("To", selection: $to, in: from..., displayedComponents: .date)
            .font(.fernlet(.body))
            .accessibilityIdentifier("settings.memory.forget.to")
    }

    /// One chip per feeling the memories carry; tapping toggles it.
    @ViewBuilder private var feelingChips: some View {
        let choices = MemoryForgetFilter.feelings(presentIn: store.memories)
        if !choices.isEmpty {
            FlowLayout(spacing: 8) {
                ForEach(choices) { feeling in
                    Button {
                        if feelings.contains(feeling) { feelings.remove(feeling) } else { feelings.insert(feeling) }
                    } label: {
                        Text(verbatim: feeling.label(addressing: termOfAddress))
                    }
                    .buttonStyle(ChipButtonStyle(selected: feelings.contains(feeling)))
                    .accessibilityIdentifier("settings.memory.forget.feeling.\(feeling.rawValue)")
                }
            }
            .padding(.vertical, 6)
        }
    }

    /// The checklist preview and its "Forget these" button, or why there is nothing to show.
    @ViewBuilder private func preview(matches: [MemoryNote], ticked: [MemoryNote]) -> some View {
        if filter.isEmpty {
            FernletCard { EmptyState(text: "Type \"forget\" and a word in the search, or pick dates or feelings, to find memories to forget.") }
        } else if matches.isEmpty {
            FernletCard { EmptyState(text: "No memories match.") }
        } else {
            FernletFramedSection("Ticked memories are forgotten") {
                ForEach(matches) { memory in
                    checklistRow(memory, isTicked: !unticked.contains(memory.id))
                }
            }
            Button(role: .destructive) {
                forget(ticked)
            } label: {
                Label("Forget these (\(ticked.count))", systemImage: "trash")
            }
            .buttonStyle(DestructiveCardButtonStyle())
            .disabled(ticked.isEmpty)
            .accessibilityIdentifier("settings.memory.forget.confirm")
        }
    }

    /// One memory in the checklist: a tick, its sentence and its date. VoiceOver reads the sentence and
    /// date, then whether it will be forgotten.
    private func checklistRow(_ memory: MemoryNote, isTicked: Bool) -> some View {
        Button {
            if isTicked { unticked.insert(memory.id) } else { unticked.remove(memory.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isTicked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isTicked ? Color.terracottaInk : Color.slate)
                    .accessibilityHidden(true)
                FernletRowLabel(title: Text(verbatim: memory.displayText),
                                detail: Text(memory.sourceDate.formatted(.dateTime.month(.abbreviated).day().year())))
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isTicked ? Text("Will be forgotten") : Text("Kept"))
        .accessibilityHint(Text("Double-tap to keep or forget this memory."))
        .accessibilityAddTraits(isTicked ? .isSelected : [])
        .accessibilityIdentifier("settings.memory.forget.row")
    }

    private func forget(_ ticked: [MemoryNote]) {
        guard !ticked.isEmpty else { return }
        lastForgotten = store.forgetMemories(ids: Set(ticked.map(\.id)))
        unticked = []
        isOpen = true
    }
}

/// "Forget patterns" (owner call M3 = A) with its one-line explanation, and "Delete all memories",
/// each behind a `DestructiveConfirmation`.
struct CoreMemoryResetSection: View {
    @Bindable var store: FernletStore
    @Binding var pendingDestructiveAction: DestructiveConfirmation?

    var body: some View {
        FernletFramedSection("Patterns",
                             footer: "Patterns are what Fernlet works out from your days: gaps between your goals and your days, your routines, and how workouts and mood go together.") {
            Button { confirmForgetPatterns() } label: {
                FernletRowLabel("Forget patterns", destructive: true)
            }
            .buttonStyle(FernletRowButtonStyle(showsChevron: false))
            .accessibilityIdentifier("settings.memory.forgetPatterns")
        }
        FernletFramedSection {
            Button { confirmDeleteAll() } label: {
                FernletRowLabel("Delete all memories", destructive: true)
            }
            .buttonStyle(FernletRowButtonStyle(showsChevron: false))
            .disabled(store.memories.isEmpty)
            .accessibilityIdentifier("settings.memory.deleteAll")
        }
    }

    private func confirmForgetPatterns() {
        pendingDestructiveAction = DestructiveConfirmation(
            title: "Forget patterns?",
            message: "Fernlet deletes the patterns it has worked out, on this phone and your other devices, and learns only from today on. Your memories and your days stay.",
            confirmLabel: "Forget patterns",
            auditEvent: "settings.memory.forgetPatternsConfirmed"
        ) {
            store.forgetPatterns()
        }
    }

    private func confirmDeleteAll() {
        let count = store.memories.count
        pendingDestructiveAction = DestructiveConfirmation(
            title: "Delete all memories?",
            message: "Deletes all ^[\(count) memory](inflect: true) on this phone and in iCloud. This can't be undone.",
            confirmLabel: "Delete all",
            auditEvent: "settings.memory.deleteAllConfirmed"
        ) {
            store.deleteAllMemories()
        }
    }
}
