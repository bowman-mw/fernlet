import SwiftUI

/// The pixel icon a personal-care task wears on Settings › Personal care tasks (`b2-settings-care`,
/// approved 2026-10-23): the World sprite for the SF Symbol the task already names, so built-in and
/// custom tasks keep one icon source (`PersonalCareTask.systemImage`) and nothing new is stored.
///
/// The tooth for brushing, the sun and moon for skincare, the drop for washing and sunscreen, the
/// star for deodorant; any other symbol (a custom task's) draws the tick.
enum CareTaskSprite {
    /// The sprite for a task's SF Symbol name.
    static func sprite(forSystemImage name: String) -> WorldSprite {
        switch name {
        case "mouth": WorldStampArt.tooth
        case "sun.max": WorldSprites.sun
        case "moon": SettingsShortcutSprite.inkMoon
        case "shower", "drop": WorldSprites.drop
        case "sparkle": WorldSprites.star
        default: WorldSprites.check
        }
    }
}
