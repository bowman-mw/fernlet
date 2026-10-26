import SwiftUI

/// The world shell: a non-shipping, fixture-only prototype of Fernlet's live-map Home, to live
/// with on a phone for a few days. Not part of the Fernlet app; nothing here ships. Its own bundle
/// id (`MBO.Fernlet.WorldShell`), so it never shares the real app's data.
@main
struct WorldShellApp: App {
    var body: some Scene {
        WindowGroup {
            WorldHomeView()
        }
    }
}
