import Foundation
import WorldMapStore

//  Sprout's lines and the weekly corner: DEBUG screenshot hooks (round 7, World-Exploration-Spec §4 and §5), beside
//  `UITestSupport`'s own: wrapped in `#if DEBUG`, with a release no-op, so nothing of it ships.

extension UITestSupport {
    #if DEBUG
    /// `FERNLET_UI_TEST_LINES=<category>:<1…3>[:<name>]` puts that line in Sprout's bubble on Home as if a discovery
    /// had found it (`desert:1`, `city:1:Portland`); `board:<land|open|towns|marks|world>` opens that lines board
    /// over Home (`ex-lines-*`). Display only. Consumed by `WorldDiscoveryLinesDriver`.
    static var linesScene: String? {
        ProcessInfo.processInfo.environment["FERNLET_UI_TEST_LINES"]
    }

    /// `FERNLET_UI_TEST_CORNER=1` stands a corner in where the person stands, as if it were this week's pick near
    /// home, and Sprout mentions it (`ex-nudge`). Display only: nothing is picked or written. Consumed by
    /// `WorldMapHome`.
    static var stagesCorner: Bool {
        ProcessInfo.processInfo.environment["FERNLET_UI_TEST_CORNER"] == "1"
    }
    #else
    static var linesScene: String? { nil }
    static var stagesCorner: Bool { false }
    #endif
}
