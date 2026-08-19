import SwiftUI
#if canImport(UIKit)
import UIKit
import FernletDomainModel
import FernletFoundation
import FernletUI
#endif

/// The Settings debug screen listing every recorded proximity session, newest first.
///
/// Each row (peer, start time, end state, duration, envelope count, error badge) pushes the same
/// ``ConnectionInspectorLogDetailView`` the live inspector uses; swipe-to-delete removes single
/// sessions and the toolbar action exports the whole history as a JSON file through the system
/// share sheet. Backed entirely by ``ConnectionInspector``'s `historicalLogs`.
struct ConnectionInspectorHistoryView: View {
    var inspector: ConnectionInspector
    @State private var exportPayload: ExportPayload?
    /// The reason the last export failed, shown as an alert. This screen is normally viewed with no
    /// live session, so `ConnectionInspector.recordError` alone would be a no-op recovery.
    @State private var exportError: String?

    var body: some View {
        List {
            if inspector.historicalLogs.isEmpty {
                Text("No connection sessions recorded.")
                    .foregroundStyle(Color.slate)
                    .listRowBackground(Color.cream)
            } else {
                ForEach(inspector.historicalLogs) { log in
                    NavigationLink {
                        ConnectionInspectorLogDetailView(log: log)
                            .navigationTitle("Session")
                    } label: {
                        historyRow(log)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            inspector.deleteLog(id: log.id)
                        }
                    }
                    .listRowBackground(Color.cream)
                }
                .onDelete { inspector.deleteLogs(at: $0) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.parchment)
        .navigationTitle("Connection History")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    exportLogs()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(inspector.historicalLogs.isEmpty)
                // Names the action, not the glyph ("square.and.arrow.up").
                .accessibilityLabel("Export connection history")
            }
        }
        // Delete the peer-identity dossier as soon as the chosen activity has finished reading it —
        // on both the shared and cancelled paths — rather than letting it linger until the next
        // sweep. Only THIS file: a data export or trainer summary may be in flight elsewhere.
        .sheet(item: $exportPayload) { payload in
            ActivityShareView(items: [payload.url]) {
                if inspector.store?.discardExportedFile(at: payload.url) == false {
                    FernletAuditLog.log("connectionInspector.discardFailed")
                }
                exportPayload = nil
            }
        }
        .alert("Couldn't export", isPresented: $exportError.isPresent()) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    /// One history row: peer name with an error badge, the start time, and the end state /
    /// duration / envelope-count line.
    private func historyRow(_ log: ConnectionSessionLog) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(log.peer?.displayName ?? "Unknown peer")
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)
                Spacer()
                if !log.errors.isEmpty {
                    Label("\(log.errors.count)", systemImage: "exclamationmark.triangle.fill")
                        .font(.fernlet(.stat))
                        .foregroundStyle(Color.terracotta)
                }
            }
            Text(log.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
            HStack(spacing: 10) {
                Text(log.endState)
                Text(duration(log))
                Text("\(log.envelopes.count) envelopes")
            }
            .font(.fernlet(.stat))
            .foregroundStyle(Color.slate)
        }
        .padding(.vertical, 4)
    }

    private func duration(_ log: ConnectionSessionLog) -> String {
        guard let seconds = log.summary.durationSeconds else { return "active" }
        return String(format: "%.0fs", seconds)
    }

    /// Writes the history as JSON and presents the share sheet for it.
    ///
    /// The file is a proximity peer-identity dossier (display names, advertised/confirmed
    /// fingerprints, signing keys, first/last-seen times), so it goes through
    /// ``FernletStore/writeProtectedExport(_:kind:)`` into `tmp/DataExports` — the one directory the
    /// launch sweep, the share-completion purge and "Delete everything" reach by construction. It is
    /// deliberately NOT preceded by a `purgeDataExports()`: that removes the whole directory and
    /// would delete a trainer summary another screen has in flight.
    private func exportLogs() {
        // R5: the store is late-bound via `attachStore`, so a nil here would otherwise be a button
        // that silently does nothing.
        guard let store = inspector.store else {
            FernletAuditLog.log("connectionInspector.exportFailed", context: ["reason": "noStore"])
            exportError = "Fernlet isn't ready yet. Please try again."
            return
        }
        do {
            let data = try inspector.exportAsJSON()
            let url = try store.writeProtectedExport(data, kind: "connection-logs")
            exportPayload = ExportPayload(url: url)
        } catch {
            // `recordError` writes to the LIVE log, which this Settings browser normally does not
            // have — so it stays only as the extra it is, and the audit line plus the alert are the
            // recovery the user actually sees (R7: a named recovery that really runs).
            FernletAuditLog.log("connectionInspector.exportFailed", context: [
                "reason": error.localizedDescription
            ])
            inspector.recordError(domain: "export", message: error.localizedDescription, recoverable: true)
            exportError = error.localizedDescription
        }
    }

    /// The written export file's URL, wrapped `Identifiable` so `.sheet(item:)` can present the
    /// share sheet for it.
    ///
    /// A fresh `id` per export means re-exporting always re-presents, even for the same file name.
    private struct ExportPayload: Identifiable {
        let id = UUID()
        let url: URL
    }
}
