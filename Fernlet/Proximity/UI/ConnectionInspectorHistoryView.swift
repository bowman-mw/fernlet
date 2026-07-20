import SwiftUI
#if canImport(UIKit)
import UIKit
import FernletDomainModel
import FernletUI
#endif

struct ConnectionInspectorHistoryView: View {
    var inspector: ConnectionInspector
    @State private var exportPayload: ExportPayload?

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
            }
        }
        .sheet(item: $exportPayload) { payload in
            ActivityShareView(items: [payload.url])
        }
    }

    private func duration(_ log: ConnectionSessionLog) -> String {
        guard let seconds = log.summary.durationSeconds else { return "active" }
        return String(format: "%.0fs", seconds)
    }

    private func exportLogs() {
        do {
            let data = try inspector.exportAsJSON()
            let fileName = "fernlet-connection-logs-\(Date().formatted(.iso8601.year().month().day())).json"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try data.write(to: url, options: .atomic)
            exportPayload = ExportPayload(url: url)
        } catch {
            inspector.recordError(domain: "export", message: error.localizedDescription, recoverable: true)
        }
    }

    private struct ExportPayload: Identifiable {
        let id = UUID()
        let url: URL
    }
}

#if canImport(UIKit)
private struct ActivityShareView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
