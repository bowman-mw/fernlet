import FernletUI
import SwiftUI
import WorldMapStore

/// What opens the ticket (§7, §10.7): where the person is (nil away from an airport), and what a calendar flight
/// fills in (To and the departure time). A new id each time it opens.
nonisolated struct WorldTripTicketRequest: Equatable, Identifiable, Sendable {
    let id = UUID()
    /// The airport the person is at; nil: "Fills in at the airport you leave from".
    let from: WorldBoardingPass.Stop?
    /// The To field's text to start with.
    var text = ""
    /// The destination a calendar flight filled in.
    var destination: WorldTripDestination?
    /// The calendar flight's departure, shown with the date.
    var departure: Date?
    /// Today.
    let date: Date
}

/// Fernlet's ticket (§7, screen 17): the approved boarding pass, top-anchored 62 pt down over a dim, with To as a
/// field, the bundled list's suggestions under it and the keyboard below. ✕ top right cancels; Start trip starts
/// the trip with the chosen suggestion (the first, unless another was tapped), or with To blank when nothing was
/// typed or nothing matches ("it fills in when you land"). The search runs on the phone, never sent.
struct WorldTripTicketOverlay: View {
    let request: WorldTripTicketRequest
    let companion: String
    /// The suggestions for a text, at most so many.
    let search: (String, Int) -> [WorldTripSuggestion]
    let onStart: (WorldTripDestination?) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @State private var chosen: WorldTripDestination?
    /// The field's text when ``chosen`` was chosen: typing anything else lets the first suggestion lead again.
    @State private var chosenText: String?
    @FocusState private var isFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ZStack(alignment: .top) {
            WorldPassPalette.veil
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .accessibilityHidden(true)
            ScrollView {
                VStack(spacing: 8) {
                    card
                    if !suggestions.isEmpty {
                        WorldTripSuggestionList(suggestions: suggestions, selected: selected, onChoose: choose)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 62)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .ignoresSafeArea(edges: .top)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .onAppear(perform: start)
        .onChange(of: text) { _, next in if next != chosenText { chosen = nil } }
    }

    /// The pass with To as a field, and Start trip on its stub.
    private var card: some View {
        WorldPassFrame {
            WorldPassHeader(onClose: onCancel)
            HStack(alignment: .center, spacing: 6) {
                WorldPassStopColumn(label: WorldTripCopy.from, code: request.from?.code,
                                    place: request.from?.place ?? String(localized: WorldTripCopy.fromFillsIn), trailing: false)
                WorldPassJet()
                WorldTripToField(text: $text, isFocused: $isFocused)
            }
            .padding(EdgeInsets(top: 14, leading: 14, bottom: 10, trailing: 14))
            WorldPassFacts(companion: companion, date: WorldTripDates.day(request.date, departure: request.departure), isTicket: true)
            WorldPassStub {
                Button(action: startTrip) {
                    Text(WorldTripCopy.startTrip).frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .accessibilityInputLabels([Text(WorldTripCopy.startTrip)])
                .accessibilityIdentifier("world.trip.start")
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(WorldTripCopy.leaveBlank)
                        .worldPassFont(WorldPassType.place(false)).foregroundStyle(WorldPassPalette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: WorldTripCopy.spokenTicket(companion: companion)))
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("world.trip.ticket")
    }

    /// Three suggestions, or two at the largest text.
    private var suggestions: [WorldTripSuggestion] {
        search(text, WorldTripSuggestions.limit(accessibilitySize: dynamicTypeSize.isAccessibilitySize))
    }

    /// The suggestion Start trip takes: the tapped or filled-in one, else the first.
    private var selected: WorldTripDestination? {
        chosen ?? suggestions.first?.destination
    }

    /// The text and the calendar flight's destination to start with; the keyboard comes up.
    private func start() {
        chosen = request.destination
        chosenText = request.destination == nil ? nil : request.text
        text = request.text
        isFocused = true
    }

    /// A suggestion tapped: it is chosen, and the field shows its city or code.
    private func choose(_ suggestion: WorldTripSuggestion) {
        let shown = suggestion.destination.kind == .city ? suggestion.city : suggestion.destination.code
        chosen = suggestion.destination
        chosenText = shown
        text = shown
    }

    /// Start trip: the chosen destination, or To blank.
    private func startTrip() {
        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        onStart(blank ? nil : selected)
    }
}

/// The ticket's To side: its label, the field ("To, text field. A city, airport or code."), and the prompt under it
/// once something is typed.
struct WorldTripToField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let large = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .trailing, spacing: 2) {
            Text(WorldTripCopy.to)
                .worldPassFont(WorldPassType.label(large)).tracking(1.1).textCase(.uppercase)
                .foregroundStyle(WorldPassPalette.dim)
                .accessibilityHidden(true)
            TextField(text: $text, prompt: .fieldPrompt(verbatim: String(localized: WorldTripCopy.toPrompt))) { Text(WorldTripCopy.to) }
                .worldPassFont(.custom(FernletFontName.dmSansBold, size: large ? 32 : 26, relativeTo: .title))
                .foregroundStyle(WorldPassPalette.text)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused(isFocused)
                .onSubmit { isFocused.wrappedValue = false }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .frame(minHeight: large ? 52 : 44)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PassportBookPalette.moss, lineWidth: 2))
                .accessibilityLabel(Text(WorldTripCopy.to))
                .accessibilityHint(Text(WorldTripCopy.toPrompt))
                .accessibilityIdentifier("world.trip.to")
            // The prompt stays under the field once something is typed (the field shows it while empty).
            Text(WorldTripCopy.toPrompt)
                .worldPassFont(WorldPassType.place(large))
                .foregroundStyle(WorldPassPalette.dim)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(text.isEmpty ? 0 : 1)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// The suggestions under the ticket (`.apsug`): a paper list in a 2-pt ink frame, each a button, the selected one
/// tinted moss.
struct WorldTripSuggestionList: View {
    let suggestions: [WorldTripSuggestion]
    let selected: WorldTripDestination?
    let onChoose: (WorldTripSuggestion) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                if index > 0 { WorldPalette.rule.frame(height: 1) }
                row(suggestion)
            }
        }
        .background(WorldPalette.paper, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: 2))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(WorldTripCopy.suggestions))
    }

    private func row(_ suggestion: WorldTripSuggestion) -> some View {
        let large = dynamicTypeSize.isAccessibilitySize
        let isSelected = suggestion.destination == selected
        return Button { onChoose(suggestion) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: WorldTripCopy.title(suggestion))
                    .worldPassFont(.custom(FernletFontName.dmSansBold, size: large ? 19 : 15.5, relativeTo: .subheadline))
                    .foregroundStyle(WorldPalette.bark)
                Text(verbatim: WorldTripCopy.detail(suggestion))
                    .worldPassFont(.custom(FernletFontName.dmSansMedium, size: large ? 16 : 13, relativeTo: .footnote))
                    .foregroundStyle(WorldPalette.dim)
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .background(isSelected ? PassportBookPalette.moss.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityInputLabels([Text(verbatim: suggestion.destination.kind == .city ? suggestion.city : suggestion.destination.code)])
        .accessibilityIdentifier("world.trip.suggestion.\(suggestion.id)")
    }
}
