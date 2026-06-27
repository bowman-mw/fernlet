import Foundation
import CoreGraphics
import SwiftUI
import Testing
import FernletDomainModel
@testable import Fernlet

@MainActor
struct EquipmentIconTests {
    @Test func everyEquipmentIconParsesToNonDegeneratePath() {
        for item in GymEquipment.allCases {
            guard let markup = EquipmentIconLibrary.equipment[item] else { continue }
            let path = SVGMarkupParser.path(from: markup)
            #expect(path.isEmpty == false, "\(item) icon produced an empty path")
            let bounds = path.boundingRect
            #expect(bounds.width > 2 && bounds.height > 2, "\(item) icon is degenerate: \(bounds)")
            // Stays roughly within the 44×44 design canvas.
            #expect(bounds.minX > -2 && bounds.minY > -2 && bounds.maxX < 46 && bounds.maxY < 46)
        }
    }

    @Test func everyLocationIconParses() {
        for (id, markup) in EquipmentIconLibrary.location {
            let path = SVGMarkupParser.path(from: markup)
            #expect(path.isEmpty == false, "location icon \(id) produced an empty path")
        }
    }

    @Test func arcCommandRendersReasonableBounds() {
        // An arc spanning a 19-tall chord on an r=11 circle bulges ~5.5 to one side (11 - √(11²−9.5²)).
        let path = SVGMarkupParser.path(from: #"<path d="M30 12.5a11 11 0 0 1 0 19"/>"#)
        let bounds = path.boundingRect
        #expect(abs(bounds.height - 19) < 2)
        #expect(bounds.width > 4 && bounds.width < 7)
        // Endpoints are at x=30; the arc bulges right (sweep=1).
        #expect(bounds.maxX > 34 && bounds.maxX < 37)
    }

    @Test func primitivesParse() {
        let rect = SVGMarkupParser.path(from: #"<rect x="5" y="5" width="10" height="20" rx="2"/>"#).boundingRect
        #expect(abs(rect.minX - 5) < 0.5 && abs(rect.width - 10) < 0.5 && abs(rect.height - 20) < 0.5)
        let circle = SVGMarkupParser.path(from: #"<circle cx="20" cy="20" r="8"/>"#).boundingRect
        #expect(abs(circle.midX - 20) < 0.5 && abs(circle.width - 16) < 0.5)
    }
}
