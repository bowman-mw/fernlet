import SwiftUI
import PhotosUI

struct MeshLobbyView: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?

    @State private var renamingMesh = false
    @State private var newMeshName = ""
    @State private var leaveMeshConfirm = false
    @State private var selectedMember: MeshMember?
    @State private var pickerItems: [PhotosPickerItem] = []

    private var manager: MeshNetworkManager { store.meshNetworkManager }

    var body: some View {
        Group {
            if let mesh = manager.currentMesh {
                meshDetailView(mesh)
            } else if !manager.isSearching {
                lobbyIdleView
            } else if manager.lobbyMeshes.isEmpty && manager.lobbyIndividuals.isEmpty {
                lobbySearchingEmptyView
            } else {
                lobbySearchingResultsView
            }
        }
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
        .alert("Mesh", isPresented: Binding(
            get: { manager.meshError != nil },
            set: { if !$0 { manager.meshError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(manager.meshError ?? "")
        }
        .onChange(of: pickerItems) { _, newValue in
            loadPickerItems(newValue)
        }
    }

    // MARK: - Idle

    private var lobbyIdleView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScreenHeader(title: "Meshes", subtitle: "Share with nearby friends.")

                HStack(spacing: 10) {
                    Button("Start new mesh") {
                        manager.startNewMesh()
                    }
                    .buttonStyle(ChipButtonStyle(selected: true))

                    Button("Find friends") {
                        manager.startLobby()
                    }
                    .buttonStyle(ChipButtonStyle(selected: false))
                }
            }
            .padding(20)
        }
        .background(Color.parchment)
    }

    // MARK: - Searching, no results

    private var lobbySearchingEmptyView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScreenHeader(title: "Meshes", subtitle: "Looking for friends nearby.")

                VStack(spacing: 14) {
                    ProgressView()
                        .tint(Color.moss)
                        .frame(maxWidth: .infinity)

                    Text("Scanning for nearby meshes and devices…")
                        .font(.callout)
                        .foregroundStyle(Color.slate)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.vertical, 10)

                Button("Stop") { manager.stopLobby() }
                    .buttonStyle(ChipButtonStyle(selected: false))
            }
            .padding(20)
        }
        .background(Color.parchment)
    }

    // MARK: - Searching, with results

    private var lobbySearchingResultsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScreenHeader(title: "Meshes", subtitle: "Nearby.")

                if !manager.lobbyMeshes.isEmpty {
                    FernletScrollSection("Open meshes nearby") {
                        ForEach(manager.lobbyMeshes) { summary in
                            Button {
                                manager.joinMesh(summary)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(summary.name)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(Color.bark)
                                        Text("\(summary.knownMemberCount) member(s)")
                                            .font(.caption)
                                            .foregroundStyle(Color.slate)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.slate)
                                }
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)

                            if summary.id != manager.lobbyMeshes.last?.id {
                                FernletRowDivider()
                            }
                        }
                    }
                }

                let friends = manager.lobbyIndividuals.filter { $0.isFriend }
                if !friends.isEmpty {
                    FernletScrollSection("Friends nearby") {
                        ForEach(friends) { individual in
                            Button { manager.startNewMesh() } label: {
                                HStack {
                                    Text(individual.peer.displayName)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(Color.bark)
                                    Spacer()
                                    Text("Friend")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .foregroundStyle(Color.parchment)
                                        .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
                                }
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)

                            if individual.id != friends.last?.id { FernletRowDivider() }
                        }
                    }
                }

                let others = manager.lobbyIndividuals.filter { !$0.isFriend }
                if !others.isEmpty {
                    FernletScrollSection("Others nearby") {
                        ForEach(others) { individual in
                            Button { manager.startNewMesh() } label: {
                                HStack {
                                    Text(individual.peer.displayName)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(Color.bark)
                                    Spacer()
                                    Text("Stranger")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .foregroundStyle(Color.slate)
                                        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(Color.bark.opacity(0.12), lineWidth: 1)
                                        )
                                }
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)

                            if individual.id != others.last?.id { FernletRowDivider() }
                        }
                    }
                }

                Button("Stop") { manager.stopLobby() }
                    .buttonStyle(ChipButtonStyle(selected: false))
            }
            .padding(20)
        }
        .background(Color.parchment)
    }

    // MARK: - In a mesh

    @ViewBuilder
    private func meshDetailView(_ mesh: MeshDescriptor) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Header with rename affordance when open
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        if mesh.mode == .open {
                            Button {
                                newMeshName = mesh.name
                                renamingMesh = true
                            } label: {
                                HStack(spacing: 6) {
                                    Text(mesh.name)
                                        .font(.system(size: 36, weight: .bold, design: .serif))
                                        .foregroundStyle(Color.bark)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.72)
                                    Image(systemName: "pencil")
                                        .font(.title3)
                                        .foregroundStyle(Color.slate)
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(mesh.name)
                                .font(.system(size: 36, weight: .bold, design: .serif))
                                .foregroundStyle(Color.bark)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }

                        Text("\(mesh.members.count) member(s)")
                            .font(.system(size: 17, weight: .medium, design: .serif).italic())
                            .foregroundStyle(Color.slate)
                    }
                    Spacer()
                }

                FernletScrollSection("Mode") {
                    Picker("Mode", selection: Binding(
                        get: { mesh.mode },
                        set: { manager.setMeshMode($0) }
                    )) {
                        Text("Open").tag(MeshMode.open)
                        Text("Closed").tag(MeshMode.closed)
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 4)
                }

                FernletScrollSection("Members") {
                    if mesh.members.isEmpty {
                        EmptyState(text: "No other members yet.")
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(mesh.members) { member in
                                    Button { selectedMember = member } label: {
                                        VStack(spacing: 6) {
                                            ZStack {
                                                Circle()
                                                    .fill(Color.moss.opacity(0.18))
                                                    .frame(width: 52, height: 52)
                                                Text(initials(for: member.displayName))
                                                    .font(.system(size: 18, weight: .semibold, design: .serif))
                                                    .foregroundStyle(Color.moss)
                                            }
                                            Text(member.displayName)
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(Color.bark)
                                                .lineLimit(1)
                                                .frame(maxWidth: 60)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                FernletScrollSection("Shared pictures") {
                    if manager.meshPhotos.isEmpty {
                        EmptyState(text: "No pictures shared yet.")
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 96), spacing: 10)],
                            spacing: 10
                        ) {
                            ForEach(manager.meshPhotos) { photo in
                                FriendPhotoTile(photo: photo, selected: false)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                HStack(spacing: 10) {
                    PhotosPicker(
                        selection: $pickerItems,
                        maxSelectionCount: 10,
                        matching: .images
                    ) {
                        Label("Add pictures", systemImage: "photo.badge.plus")
                    }
                    .buttonStyle(ChipButtonStyle(selected: true))

                    Button("Leave mesh") { leaveMeshConfirm = true }
                        .buttonStyle(ChipButtonStyle(selected: false))
                }
            }
            .padding(20)
        }
        .background(Color.parchment)
        .sheet(isPresented: $renamingMesh) {
            renameMeshSheet
        }
        .alert("Leave mesh?", isPresented: $leaveMeshConfirm) {
            Button("Leave", role: .destructive) { manager.leaveMesh() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will stop receiving shared content from this mesh.")
        }
        .confirmationDialog(
            selectedMember.map { "Options for \($0.displayName)" } ?? "",
            isPresented: Binding(
                get: { selectedMember != nil },
                set: { if !$0 { selectedMember = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let member = selectedMember {
                Button("Block \(member.displayName)", role: .destructive) {
                    store.blockProximityPeer(fingerprint: member.fingerprint)
                    selectedMember = nil
                }
                Button("Cancel", role: .cancel) { selectedMember = nil }
            }
        }
    }

    private var renameMeshSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text("Rename mesh")
                            .font(.system(size: 28, weight: .bold, design: .serif))
                            .foregroundStyle(Color.bark)

                        SheetField("New name") {
                            TextField("Mesh name", text: $newMeshName)
                                .sheetTextInput()
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

    // MARK: - Helpers

    private func initials(for name: String) -> String {
        name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
    }

    private func loadPickerItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    manager.addPhoto(data)
                }
            }
            pickerItems = []
        }
    }
}
