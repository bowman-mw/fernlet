import FernletUI
import SwiftUI
import WorldMapStore

/// Privacy & data's "Airports and flights" card (World-Airports-Spec §9.1, §9.5, screen 19): "Add past flights"
/// (from a Flighty export file, read on this iPhone) and, once some are kept, "Remove imported flights", which
/// takes every Flighty and calendar source away after a confirmation (a flight Fernlet saw itself stays). Right
/// after an import the card says what was added, with Undo, in place of the toast.
///
/// Not shown in a decoy (§11: a decoy shows no flights and offers no import).
struct PrivacyAirportsFlightsCard: View {
    let store: FernletStore
    @State private var flow: FlightyImportFlow
    @State private var confirmsRemove = false

    init(store: FernletStore) {
        self.store = store
        _flow = State(initialValue: FlightyImportFlow(store: store))
    }

    var body: some View {
        FernletFramedSection(header: Text(FlightyImportCopy.cardTitle)) {
            Button { flow.pick() } label: {
                FernletRowLabel(title: Text(FlightyImportCopy.addPastFlights), detail: Text(FlightyImportCopy.addPastFlightsRowSub))
            }
            .buttonStyle(FernletRowButtonStyle())
            .accessibilityInputLabels([Text(FlightyImportCopy.addPastFlights)])
            .accessibilityIdentifier("privacy.flights.addPast")
            if let added = flow.added { addedRow(added) }
            if store.worldFog.atlas.importedFlightCount > 0 {
                Button { confirmsRemove = true } label: {
                    FernletRowLabel(title: Text(FlightyImportCopy.removeImported), destructive: true)
                }
                .buttonStyle(FernletRowButtonStyle(showsChevron: false))
                .accessibilityIdentifier("privacy.flights.removeImported")
            }
        }
        .flightyImport(flow, showsToast: false)
        .confirmationDialog(Text(FlightyImportCopy.removeTitle), isPresented: $confirmsRemove, titleVisibility: .visible) {
            Button(role: .destructive) { remove() } label: { Text(FlightyImportCopy.removeConfirm) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(FlightyImportCopy.removeBody)
        }
    }

    /// "Added 48 flights from Flighty" with Undo, while the import's toast would show.
    private func addedRow(_ added: FlightyImportAdded) -> some View {
        HStack(spacing: 10) {
            Text(FlightyImportCopy.addedToast(added.count))
                .font(FernletFramedFont.rowDetail)
                .foregroundStyle(WorldPalette.dim)
                .fernletWrappingText()
            Spacer(minLength: 8)
            Button { flow.undo() } label: { Text("Undo").font(FernletFramedFont.buttonSmall).frame(minWidth: 44, minHeight: 44) }
                .buttonStyle(.plain)
                .foregroundStyle(WorldPalette.mossInk)
                .accessibilityIdentifier("privacy.flights.undo")
        }
        .accessibilityElement(children: .contain)
    }

    private func remove() {
        guard let removed = store.worldFog.atlas.removeImportedFlights() else {
            flow.problem = .passportClosed
            return
        }
        FernletAnnouncer.system.announce(.status, resolved: String(localized: FlightyImportCopy.removed(removed)))
    }
}
