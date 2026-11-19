import FernletUI
import SwiftUI

/// Settings → Home map → **Live planes nearby** (owner 2026-11-19): off by default, its line the approved disclosure
/// verbatim. Turned on for the first time (not asked in onboarding), it confirms with the same words first, in the
/// pattern of the web nutrition lookup's disclosure. Once today's 400 lookups are used, a quiet line says the planes
/// rest until tomorrow.
struct LivePlanesSwitch: View {
    @AppStorage(WorldMapPreferences.Key.livePlanes) private var isOn = false
    @State private var confirming = false
    @State private var isSpent = false

    var body: some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 4) {
                FernletRowLabel(title: Text(LiveAircraftCopy.title), detail: Text(LiveAircraftCopy.disclosure))
                if isOn && isSpent {
                    Text(LiveAircraftCopy.resting)
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(WorldPalette.dim)
                }
            }
            .padding(.vertical, 7)
        }
        .accessibilityIdentifier("settings.homeMap.livePlanes")
        .task(id: isOn) { isSpent = WorldMapPreferences.livePlanesBudget().isSpent(at: Date()) }
        .alert(Text(LiveAircraftCopy.confirmTitle), isPresented: $confirming) {
            Button { WorldMapPreferences.setShowsLivePlanes(true) } label: { Text(LiveAircraftCopy.turnOn) }
            Button(role: .cancel) { WorldMapPreferences.setLivePlanesDisclosed() } label: { Text(LiveAircraftCopy.notNow) }
        } message: {
            Text(LiveAircraftCopy.disclosure)
        }
    }

    /// The switch: off turns it off; on turns it on, or asks first if the disclosure hasn't been seen.
    private var binding: Binding<Bool> {
        Binding(get: { isOn }, set: { on in
            guard on else {
                WorldMapPreferences.setShowsLivePlanes(false)
                return
            }
            if WorldMapPreferences.livePlanesDisclosed() {
                WorldMapPreferences.setShowsLivePlanes(true)
            } else {
                confirming = true
            }
        })
    }
}
