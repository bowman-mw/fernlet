import FernletDomainModel
import FernletUI
import SwiftUI

/// What a tapped plane's card shows, taken when it was tapped. In memory only, never saved.
struct LiveAircraftCardSnapshot: Identifiable, Equatable {
    let id: String
    /// "United 1704", the callsign as flown, or nil with neither.
    let flight: String?
    /// "Boeing 737-800", the type's code when it isn't listed, or nil.
    let type: String?
    let family: LiveAircraftFamily
    let livery: LiveAircraftLivery
    let altitudeFeet: Int
    let groundSpeedKnots: Double?
    let match: LiveAircraftFlownMatch

    /// The card for `plane`, matched against the person's flights as `match`.
    init(_ plane: LiveAircraft, match: LiveAircraftFlownMatch) {
        id = plane.id
        flight = LiveAircraftCopy.flightName(plane)
        type = LiveAircraftCopy.typeName(plane)
        family = LiveAircraftTypes.family(code: plane.typeCode, category: plane.category)
        livery = LiveAircraftAirlines.flight(plane.callsign)?.airline.livery ?? .plain(family)
        altitudeFeet = plane.altitudeFeet
        groundSpeedKnots = plane.groundSpeedKnots
        self.match = match
    }

    /// The plane as VoiceOver names it in the map's actions: "United 1704, Boeing 737-800".
    var spokenName: String {
        let title = flight ?? AddressedCopy.plain(LiveAircraftCopy.noCallsign)
        return [title, type].compactMap { $0 }.joined(separator: ", ")
    }
}

/// A tapped plane's card (owner 2026-11-19, calls 7 and 8): the airline and flight read from the callsign, the type in
/// words, altitude and speed in the person's units, and a line when the person has flown on it or its type. No route
/// guess: nothing more is asked of adsb.lol on a tap. Read by VoiceOver as a heading and its rows.
struct LiveAircraftCard: View {
    let snapshot: LiveAircraftCardSnapshot
    @Environment(\.dismiss) private var dismiss

    /// The sheet's height.
    static let height: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                WorldSpriteView(sprite: LiveAircraftSprites.sprite(snapshot.family, livery: snapshot.livery, eighths: 2), scale: 2)
                VStack(alignment: .leading, spacing: 2) {
                    title
                        .font(.fernlet(.headerMedium))
                        .foregroundStyle(WorldPalette.ink)
                        .accessibilityAddTraits(.isHeader)
                    if let line = flownLine {
                        Text(line)
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(WorldPalette.dim)
                    }
                }
                Spacer(minLength: 0)
                Button { dismiss() } label: {
                    WorldSpriteView(sprite: WorldSprites.xx, scale: 2)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text(LiveAircraftCopy.close))
                .accessibilityIdentifier("world.livePlanes.card.close")
            }
            row(LiveAircraftCopy.type, value: snapshot.type.map { Text(verbatim: $0) } ?? Text(LiveAircraftCopy.unknownType))
            row(LiveAircraftCopy.altitude, value: Text(verbatim: LiveAircraftCopy.altitude(feet: snapshot.altitudeFeet)))
            if let knots = snapshot.groundSpeedKnots {
                row(LiveAircraftCopy.speed, value: Text(verbatim: LiveAircraftCopy.speed(knots: knots)))
            }
            Text(LiveAircraftCopy.nothingSaved)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(WorldPalette.dim)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorldPalette.paper)
        .accessibilityIdentifier("world.livePlanes.card")
    }

    /// The flight's name, or "A plane" with no callsign.
    private var title: Text {
        snapshot.flight.map { Text(verbatim: $0) } ?? Text(LiveAircraftCopy.noCallsign)
    }

    /// "You flew on this plane", "You've flown this type", or nil.
    private var flownLine: LocalizedStringResource? {
        switch snapshot.match {
        case .samePlane: LiveAircraftCopy.flewOnThisPlane
        case .sameType: LiveAircraftCopy.flewThisType
        case .none: nil
        }
    }

    /// One row: its label, and its value on the right.
    private func row(_ label: LocalizedStringResource, value: Text) -> some View {
        HStack {
            Text(label).foregroundStyle(WorldPalette.dim)
            Spacer(minLength: 8)
            value.foregroundStyle(WorldPalette.ink).multilineTextAlignment(.trailing)
        }
        .font(.fernlet(.bodySmall))
        .accessibilityElement(children: .combine)
    }
}
