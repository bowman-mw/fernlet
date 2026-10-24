import Foundation

/// DEBUG-only launch hooks for the Friends lane's screenshots and UI checks; every flag is off in
/// Release (`TestHookBoundaryTests`: each read sits inside `#if DEBUG`, and the release half answers
/// nil for all of them).
///
/// - `FERNLET_UI_TEST_FRIENDS_ROUTE=activities|friendList|friendShop|yourShop` — the Friends panel
///   opens with that page pushed (one page deep, so the plate's Back names Friends).
/// - `FERNLET_UI_TEST_SESSION_SURFACE=menu|info|chat|rename|leave|camera` — Home's session button opens
///   that piece at launch, over a canned session (`PROXIMITYKIT_UI_TEST_MESH_OPEN=1`).
/// - `FERNLET_UI_TEST_SOLO_CAMERA=1` — the Friends panel opens the disposable camera on your own at
///   launch, with no session (`b3-camera-solo`; the blue button is lane HOME's).
/// - `FERNLET_UI_TEST_SOLO_ALBUM=waiting|revealed|open` — the Friends panel plants three demo solo
///   photos (`SoloAlbumDemoSeed`): held until tonight, shown, or shown with the set opened.
nonisolated enum FriendsUITestHooks {
    #if DEBUG
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// Whether the Friends panel opens the solo camera at launch.
    static var opensSoloCamera: Bool { env["FERNLET_UI_TEST_SOLO_CAMERA"] == "1" }

    /// The solo album scene the Friends panel stages at launch (the raw token), if any.
    static var soloAlbumScene: String? { env["FERNLET_UI_TEST_SOLO_ALBUM"] }

    /// The page the Friends panel pushes at launch, if any.
    static var initialRoute: FriendsRoute? {
        switch env["FERNLET_UI_TEST_FRIENDS_ROUTE"] {
        case "activities": .activities
        case "friendList": .friendList
        case "friendShop": .friendShop
        case "yourShop": .yourShop
        default: nil
        }
    }

    /// The session-button surface to open at launch, if any (the raw token; the button maps it).
    static var initialSessionSurface: String? { env["FERNLET_UI_TEST_SESSION_SURFACE"] }
    #else
    static var opensSoloCamera: Bool { false }
    static var soloAlbumScene: String? { nil }
    static var initialRoute: FriendsRoute? { nil }
    static var initialSessionSurface: String? { nil }
    #endif
}
