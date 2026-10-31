import FernletUI
import SwiftUI
import UniformTypeIdentifiers
import WorldMapStore

extension View {
    /// Hosts a Flighty import on this screen (World-Airports-Spec §9): iOS's own file picker (CSV only, kept as
    /// Apple draws it), the summary sheet, a problem's alert, and the "Added 48 flights from Flighty · Undo" toast
    /// over the bottom edge (`showsToast` false where the screen says it in place, as Privacy & data does). Its
    /// "Add past flights" entry point calls ``FlightyImportFlow/pick()``.
    func flightyImport(_ flow: FlightyImportFlow, showsToast: Bool = true) -> some View {
        modifier(FlightyImportHost(flow: flow, showsToast: showsToast))
    }
}

/// Implements ``SwiftUI/View/flightyImport(_:)``.
private struct FlightyImportHost: ViewModifier {
    @Bindable var flow: FlightyImportFlow
    let showsToast: Bool

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $flow.isPicking, allowedContentTypes: [.commaSeparatedText]) { flow.picked($0) }
            .sheet(item: $flow.found) { found in
                FlightyImportSheet(found: found, onAdd: { flow.confirm() }, onCancel: { flow.found = nil })
            }
            .alert(Text(FlightyImportCopy.problemTitle), isPresented: problemShown) {
                Button("OK", role: .cancel) { flow.problem = nil }
            } message: {
                if let problem = flow.problem { Text(FlightyImportCopy.message(problem)) }
            }
            .overlay(alignment: .bottom) { toast }
    }

    /// The toast after an import, with Undo.
    @ViewBuilder
    private var toast: some View {
        if showsToast, let added = flow.added {
            WorldLoggedNote(line: Text(FlightyImportCopy.addedToast(added.count)), identifier: .flights) { flow.undo() }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .transition(.opacity)
                .onAppear {
                    FernletAnnouncer.system.announce(.status, resolved: String(localized: FlightyImportCopy.addedToast(added.count)))
                }
        }
    }

    private var problemShown: Binding<Bool> {
        Binding(get: { flow.problem != nil }, set: { if !$0 { flow.problem = nil } })
    }
}
