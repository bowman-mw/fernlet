import FernletUI
import SwiftUI
import WorldMapStore

/// Privacy & data's "Airports and flights" card (World-Airports-Spec §9.1, §9.5, §10.1, §11; screens 13, 19, 25):
///
/// 1. **"Airports and flights"** (on by default): off keeps no new airport stamps, flights or layovers, stops the
///    calendar's look, and asks whether to delete what's kept (only when something is).
/// 2. **"Flights from Calendar"** (off by default): on asks iOS, then looks back once and opens the summary; its
///    note says where to take access away in iOS Settings, or, after Don't Allow, where to allow it.
/// 3. **"Add past flights"** (from a Flighty export file, read on this iPhone).
/// 4. **"Remove imported flights"**, once some are kept: every Flighty and calendar source goes after a
///    confirmation (a flight Fernlet saw itself stays).
///
/// Right after an import the card says what was added, with Undo, in place of the toast. Rows 2 and 3 are dimmed
/// while the first switch is off. Not shown in a decoy (§11: a decoy shows no flights, offers no import and never
/// reads the calendar).
struct PrivacyAirportsFlightsCard: View {
    let store: FernletStore
    @State private var flow: FlightyImportFlow
    @State private var calendar: CalendarFlightsFlow
    @State private var keepsFlights: Bool
    @State private var confirmsRemove = false
    @State private var confirmsForget = false

    init(store: FernletStore) {
        self.store = store
        _flow = State(initialValue: FlightyImportFlow(store: store))
        _calendar = State(initialValue: CalendarFlightsFlow(store: store))
        _keepsFlights = State(initialValue: store.keepsWorldAirportsAndFlights())
    }

    var body: some View {
        FernletFramedSection(header: Text(FlightyImportCopy.cardTitle)) {
            airportsSwitch
            PrivacyCalendarFlightsRow(flow: calendar, isEnabled: keepsFlights)
            addPastFlightsRow
            if let added = flow.added { PrivacyFlightsAddedRow(line: FlightyImportCopy.addedToast(added.count)) { flow.undo() } }
            if let added = calendar.added { PrivacyFlightsAddedRow(line: CalendarFlightsCopy.added(added.count)) { calendar.undo() } }
            if store.worldFog.atlas.importedFlightCount > 0 { removeImportedRow }
        }
        .flightyImport(flow, showsToast: false)
        .calendarFlightsImport(calendar)
        .confirmationDialog(Text(FlightyImportCopy.removeTitle), isPresented: $confirmsRemove, titleVisibility: .visible) {
            Button(role: .destructive) { remove() } label: { Text(FlightyImportCopy.removeConfirm) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(FlightyImportCopy.removeBody)
        }
        .confirmationDialog(Text(CalendarFlightsCopy.forgetTitle), isPresented: $confirmsForget, titleVisibility: .visible) {
            Button(role: .destructive) { forget() } label: { Text(CalendarFlightsCopy.forgetConfirm) }
            Button(role: .cancel) {} label: { Text(CalendarFlightsCopy.forgetKeep) }
        } message: {
            Text(CalendarFlightsCopy.forgetBody)
        }
        .onAppear {
            calendar.refresh()
            showDemoIfAsked()
        }
    }

    /// "Airports and flights": on by default; off asks whether to delete what's kept.
    private var airportsSwitch: some View {
        Toggle(isOn: Binding(get: { keepsFlights }, set: { setKeepsFlights($0) })) {
            FernletRowLabel(title: Text(CalendarFlightsCopy.airportsSwitch), detail: Text(CalendarFlightsCopy.airportsSwitchSub))
                .padding(.vertical, 7)
        }
        .accessibilityInputLabels([Text(CalendarFlightsCopy.airportsSwitch)])
        .accessibilityIdentifier("privacy.flights.keep")
    }

    /// "Add past flights": from a Flighty export file.
    private var addPastFlightsRow: some View {
        Button { flow.pick() } label: {
            FernletRowLabel(title: Text(FlightyImportCopy.addPastFlights), detail: Text(FlightyImportCopy.addPastFlightsRowSub))
        }
        .buttonStyle(FernletRowButtonStyle())
        .disabled(!keepsFlights)
        .accessibilityInputLabels([Text(FlightyImportCopy.addPastFlights)])
        .accessibilityIdentifier("privacy.flights.addPast")
    }

    /// "Remove imported flights", once some are kept.
    private var removeImportedRow: some View {
        Button { confirmsRemove = true } label: {
            FernletRowLabel(title: Text(FlightyImportCopy.removeImported), destructive: true)
        }
        .buttonStyle(FernletRowButtonStyle(showsChevron: false))
        .accessibilityIdentifier("privacy.flights.removeImported")
    }

    private func setKeepsFlights(_ on: Bool) {
        keepsFlights = on
        store.setWorldAirportsAndFlights(on)
        guard !on else { return }
        calendar.turnOff()
        if store.worldFog.atlas.book.holdsAirportsOrFlights { confirmsForget = true }
    }

    private func remove() {
        guard let removed = store.worldFog.atlas.removeImportedFlights() else {
            flow.problem = .passportClosed
            return
        }
        FernletAnnouncer.system.announce(.status, resolved: String(localized: FlightyImportCopy.removed(removed)))
    }

    private func forget() {
        guard let removed = store.forgetWorldAirportsAndFlights() else {
            flow.problem = .passportClosed
            return
        }
        FernletAnnouncer.system.announce(.status, resolved: String(localized: CalendarFlightsCopy.forgotten(removed)))
    }

    /// The screenshots' made-up first look (`FERNLET_UI_TEST_CALENDAR_FLIGHTS=summary`); nothing in Release.
    private func showDemoIfAsked() {
        #if DEBUG
        if let found = UITestSupport.calendarFlightsDemo { calendar.showDemo(found) }
        #endif
    }
}

/// "Flights from Calendar" (screen 25): the switch and its sub, then a note. While it's on the note says where in
/// iOS Settings to take access away; after Don't Allow (or access taken away) it says where to allow it; while
/// the first look runs it says so. Dimmed while "Airports and flights" is off.
struct PrivacyCalendarFlightsRow: View {
    @Bindable var flow: CalendarFlightsFlow
    let isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { flow.isOn || flow.isLooking }, set: { flow.setOn($0) })) {
                FernletRowLabel(title: Text(CalendarFlightsCopy.calendarSwitch), detail: Text(CalendarFlightsCopy.calendarSwitchSub))
                    .padding(.vertical, 7)
            }
            .disabled(!isEnabled)
            .accessibilityInputLabels([Text(CalendarFlightsCopy.calendarSwitch)])
            .accessibilityIdentifier("privacy.flights.calendar")
            if let note {
                Text(note)
                    .font(FernletFramedFont.rowDetail)
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
                    .padding(.bottom, 7)
                    .accessibilityIdentifier("privacy.flights.calendarNote")
            }
        }
    }

    /// The note under the switch, if any.
    private var note: LocalizedStringResource? {
        if flow.isLooking { return CalendarFlightsCopy.looking }
        if flow.isOn { return CalendarFlightsCopy.calendarOnNote }
        return flow.isRefused ? CalendarFlightsCopy.calendarRefusedNote : nil
    }
}

/// "Added 48 flights from Flighty" (or "from your calendar") with Undo, while the import's toast would show.
struct PrivacyFlightsAddedRow: View {
    let line: LocalizedStringResource
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(line)
                .font(FernletFramedFont.rowDetail)
                .foregroundStyle(WorldPalette.dim)
                .fernletWrappingText()
            Spacer(minLength: 8)
            Button(action: onUndo) { Text("Undo").font(FernletFramedFont.buttonSmall).frame(minWidth: 44, minHeight: 44) }
                .buttonStyle(.plain)
                .foregroundStyle(WorldPalette.mossInk)
                .accessibilityIdentifier("privacy.flights.undo")
        }
        .accessibilityElement(children: .contain)
    }
}
