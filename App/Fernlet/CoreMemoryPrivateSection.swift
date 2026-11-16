import SwiftUI
import FernletDomainModel
import FernletUI

// G9-3 private memories on Settings → Core memory (owner call M6 = A): the memories a person moved into
// Private with "Keep private". While Private is closed the page only says how many wait behind the lock;
// once it is open they are listed, each with a confirmed delete. A decoy (duress) session shows nothing
// here, the same way the other sealed screens hide. Accessibility identifiers here are frozen tokens.

/// The Core memory page's "Private memories" section.
struct CoreMemoryPrivateSection: View {
    @Bindable var store: FernletStore
    @Binding var pendingDestructiveAction: DestructiveConfirmation?

    var body: some View {
        if store.duressSessionActive {
            EmptyView()
        } else if store.isPrivateMemoryOpen {
            openSection(store.privateMemories)
        } else {
            closedSection(count: store.privateMemoryCount)
        }
    }

    /// Private is closed: how many there are, and how to see them. Nothing when there are none.
    @ViewBuilder private func closedSection(count: Int) -> some View {
        if count > 0 {
            FernletFramedSection("Private memories", footer: "Open Private to unlock them. They stay sealed on this iPhone and in your journal's Sealed backup.") {
                FernletRowLabel(title: Text("^[\(count) private memory](inflect: true) — unlock to see"))
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("settings.memory.private.locked")
            }
        }
    }

    /// Private is open: every private memory, oldest first, each with a delete.
    @ViewBuilder private func openSection(_ memories: [MemoryNote]) -> some View {
        if !memories.isEmpty {
            FernletFramedSection("Private memories", footer: "Only here, while Private is open. Never on Home, never synced, and never given to the AI.") {
                ForEach(memories) { memory in
                    row(memory)
                }
            }
            .accessibilityIdentifier("settings.memory.private.list")
        }
    }

    /// One private memory: its sentence and date, then a confirmed delete.
    private func row(_ memory: MemoryNote) -> some View {
        HStack(alignment: .center, spacing: 8) {
            FernletRowLabel(title: Text(verbatim: memory.displayText),
                            detail: Text(memory.sourceDate.formatted(.dateTime.month(.abbreviated).day().year())))
                .padding(.vertical, 10)
            Button { confirmDelete(memory) } label: {
                FernletIconTile(size: 32, isControl: true) { FernletIcon(.close, scale: 2) }
            }
            .buttonStyle(.plain)
            .fernletIconButton("Delete private memory")
            .accessibilityIdentifier("settings.memory.private.delete")
        }
    }

    private func confirmDelete(_ memory: MemoryNote) {
        pendingDestructiveAction = DestructiveConfirmation(
            title: "Delete this private memory?",
            message: "\"\(memory.displayText)\"\n\nFernlet forgets it for good, here and in your journal's Sealed backup.",
            confirmLabel: "Delete",
            auditEvent: "settings.memory.private.deleteConfirmed"
        ) {
            store.forgetPrivateMemories(ids: [memory.id])
        }
    }
}

/// "Keep private" in the memory editor: moves the memory into Private's sealed store (the sealed copy is
/// written first; the Core copy goes only once it has landed). Offered only while Private is open;
/// otherwise it says what to do. Hidden in a decoy.
struct MemoryKeepPrivateSection: View {
    @Bindable var store: FernletStore
    /// Runs the move; answers whether it landed.
    let keep: () -> Bool

    @State private var failed = false

    var body: some View {
        if !store.duressSessionActive {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    failed = !keep()
                } label: {
                    Label("Keep private", systemImage: "lock")
                }
                .font(.fernlet(.label))
                .foregroundStyle(store.isPrivateMemoryOpen ? Color.bark : Color.slate)
                .frame(minHeight: 44)
                .disabled(!store.isPrivateMemoryOpen)
                .accessibilityIdentifier("settings.memory.keepPrivate")
                Text(store.isPrivateMemoryOpen
                     ? "Moves it into Private, sealed on this iPhone. It leaves Home and your other devices, and only shows here while Private is open."
                     : "Open Private first to keep a memory private.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                if failed {
                    Text("Fernlet couldn't keep this private just now. It's still in your memories.")
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.terracottaInk)
                        .fernletWrappingText()
                        .accessibilityIdentifier("settings.memory.keepPrivate.failed")
                }
            }
        }
    }
}
