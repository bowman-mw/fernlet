import FernletDomainModel
import SwiftUI

/// The pixel icon each quick-log shortcut wears on Settings › Quick-log shortcuts
/// (`b2-settings-quicklog`, approved 2026-10-23): the rice ball for a meal, the drop for water, the
/// shoe for moving, the moon for sleep, the diary for the journal and the tick for care, as the
/// design draws the six default tiles; the optional shortcuts take the nearest World sprite.
enum SettingsShortcutSprite {
    /// The crescent moon in the design's ink: World's own moon is the night sky's pale cream, which
    /// vanishes on paper. One-colour ink, so it takes the ink token in dark mode.
    static let inkMoon = WorldSprite(rows: ["..kkk.", ".kk...", "kk....", "kk....", "kk....", ".kk...", "..kkk."],
                                     palette: ["k": WorldSprite.ink])

    /// The sprite for one shortcut.
    static func sprite(for shortcut: FernletShortcut) -> WorldSprite {
        switch shortcut {
        case .meal: WorldSprites.onigiri
        case .water: WorldSprites.drop
        case .move: WorldSprites.shoe
        case .sleep: inkMoon
        case .journal: WorldSprites.diary
        case .care: WorldSprites.check
        case .logPeriod, .periodTracking: WorldSprites.flag
        case .intimacyTracking: WorldSprites.heartSm
        case .friends: WorldSprites.face
        case .breathing: WorldSprites.breathe
        case .grounding: WorldSprites.leaf
        case .worryBox: WorldSprites.box
        case .bathroom: BathroomRollSprite.roll
        }
    }
}
