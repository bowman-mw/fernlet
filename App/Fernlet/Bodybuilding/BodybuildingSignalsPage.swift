//
//  BodybuildingSignalsPage.swift
//  Fernlet
//
//  Calendar signals (World round 7, `bb-signals`; spec §4): pushed from the Day calendar ("‹ Day
//  calendar"), eight switches each with where its signal comes from, then "Opens on: Month | Week". Saves
//  through the store's calendar preferences (a decoy session keeps nothing).
//

import FernletDomainModel
import FernletUI
import SwiftUI

/// The Calendar signals page.
struct BodybuildingSignalsPage: View {
    var store: FernletStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FernletFramedSection("Shown on the calendar") {
                    ForEach(BodybuildingSignal.allCases) { signal in
                        Toggle(isOn: binding(for: signal)) {
                            HStack(spacing: 12) {
                                FernletIconTile(size: 36) { BodybuildingSignalIcon(signal: signal) }
                                FernletRowLabel(title: Text(verbatim: signal.displayName),
                                                detail: Text(verbatim: signal.sourceLine))
                            }
                            .padding(.vertical, 7)
                        }
                        .accessibilityIdentifier("bodybuilding.signal.\(signal.rawValue)")
                    }
                }
                FernletFramedSection("Opens on",
                                     footer: "The month grid has room for four; the week list shows all you turn on.") {
                    FernletSegmentedPicker("Opens on", selection: opensOnBinding, options: BodybuildingCalendarMode.allCases) {
                        Text(verbatim: $0.displayName)
                    }
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("bodybuilding.signals.opensOn")
                }
            }
            .padding(16)
        }
        .fernletPageBackground()
        .fernletPushedPage(BodybuildingCalendarText.signalsTitle)
        .accessibilityIdentifier("screen.bodybuilding.signals")
    }

    /// One signal's switch, saved through the store.
    private func binding(for signal: BodybuildingSignal) -> Binding<Bool> {
        Binding(get: { store.bodybuildingCalendarSettings.isOn(signal) }, set: { isOn in
            var prefs = store.bodybuildingCalendarSettings
            prefs.setSignal(signal, on: isOn)
            store.bodybuildingCalendarSettings = prefs
        })
    }

    /// "Opens on", saved through the store.
    private var opensOnBinding: Binding<BodybuildingCalendarMode> {
        Binding(get: { store.bodybuildingCalendarSettings.opensOn }, set: { mode in
            var prefs = store.bodybuildingCalendarSettings
            prefs.opensOn = mode
            store.bodybuildingCalendarSettings = prefs
        })
    }
}
