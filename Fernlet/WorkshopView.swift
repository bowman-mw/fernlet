import SwiftUI

struct WorkshopView: View {
    @ObservedObject var store: FernletStore
    @Binding var activeSheet: FernletSheet?
    var isInHub: Bool = false
    @State private var tab = WorkshopTab.texture

    var entries: [TextureEntry] {
        switch tab {
        case .texture: store.workshop.textureEntries
        case .handoff: store.workshop.handoffEntries
        case .notes: store.workshop.claudeNotesEntries
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        ScreenHeader(title: "Workshop", subtitle: "design observations")
                        Spacer()
                        HeaderActionButton(systemImage: "plus") { activeSheet = .texture }
                            .disabled(tab != .texture)
                            .opacity(tab == .texture ? 1 : 0.35)
                    }
                    .padding(.top, 4)

                    Picker("Workshop", selection: $tab) {
                        ForEach(WorkshopTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)

                    FernletScrollSection(tab.rawValue) {
                        if entries.isEmpty {
                            EmptyState(text: "No entries yet")
                        } else {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                TextureRow(entry: entry)
                                if index < entries.count - 1 {
                                    FernletRowDivider()
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.parchment)
            .navigationTitle("")
            .toolbar(isInHub ? .hidden : .visible, for: .navigationBar)
        }
    }
}

enum WorkshopTab: String, CaseIterable, Identifiable {
    case texture = "Texture"
    case handoff = "Handoff"
    case notes = "Claude Notes"
    var id: String { rawValue }
}

// MARK: - Sheets

struct TextureRow: View {
    var entry: TextureEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.title).font(.subheadline.weight(.semibold))
                ForEach(Array(entry.tags), id: \.self) { tag in
                    Text(tag.rawValue.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(tag.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(tag.color.opacity(0.12), in: Capsule())
                }
            }
            Text(entry.body)
                .font(.callout)
        }
        .padding(.vertical, 4)
    }
}

