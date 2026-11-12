import FernletUI
import SwiftUI

extension PassportBookScreen {
    // MARK: The Road trips page (World-RoadTrip-Spec PR 4)

    /// The Road trips page's model: the person's road trips no longer on, once their numbers are in; nil (no page) in a
    /// decoy, in the demo, and before any trip is over (`rt-end`: "next to flights", on the Flights page's pattern).
    var roadTripsModel: PassportRoadTripsModel? {
        guard presenter.demo == nil, !store.worldFog.isDecoy, !store.duressSessionActive else { return nil }
        let model = PassportRoadTripsModel(trips: store.worldFog.roadTrip.book.closed)
        return model.isEmpty ? nil : model
    }

    /// The log the Road trips page has open, or nil (also when its year has since lost its trips).
    func openRoadTripLog(_ roadTrips: PassportRoadTripsModel?) -> PassportRoadTripYearLog? {
        roadTripsYear.flatMap { roadTrips?.log(ofYear: $0) }
    }

    /// The year whose log `page` has open (a new log's page starts at its top), or nil.
    func logYear(on page: PassportBookPage) -> Int? {
        switch page {
        case .flights: flightsYear
        case .roadTrips: roadTripsYear
        default: nil
        }
    }

    /// The Road trips page's content: the open year's log, or the page itself.
    @ViewBuilder
    var roadTripsContent: some View {
        let roadTrips = roadTripsModel
        if let log = openRoadTripLog(roadTrips) {
            PassportRoadTripsYearPage(log: log, takesFocus: yearTakesFocus)
        } else if let roadTrips {
            PassportRoadTripsPage(roadTrips: roadTrips, refocusYear: yearToRefocus) { openRoadTripYear($0) }
        }
    }

    /// Opens `year`'s log on the Road trips page; VoiceOver goes to its header.
    func openRoadTripYear(_ year: Int) {
        yearTakesFocus = true
        yearToRefocus = nil
        showRoadTripYear(year)
    }

    /// Closes the open log, back to the Road trips page; VoiceOver goes back to the year's row.
    func closeRoadTripYear() {
        yearToRefocus = roadTripsYear
        showRoadTripYear(nil)
    }

    /// Steps to the year `by` places along the list (1 older, -1 newer) and reads it out, VoiceOver staying where it is.
    func stepRoadTripYear(_ by: Int) {
        guard let roadTripsYear, let roadTrips = roadTripsModel, let position = roadTrips.position(ofYear: roadTripsYear),
              roadTrips.years.indices.contains(position + by) else { return }
        let log = roadTrips.years[position + by]
        yearTakesFocus = false
        showRoadTripYear(log.year)
        FernletAnnouncer.system.announce(.status, resolved: PassportRoadTripsText.yearSpoken(log))
    }

    /// Shows `year`'s log, or the Road trips page itself for nil.
    private func showRoadTripYear(_ year: Int?) {
        FernletFeedback.system.play(.tick)
        pageOnTop = true
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.15)) { roadTripsYear = year }
        } else {
            roadTripsYear = year
        }
    }
}
