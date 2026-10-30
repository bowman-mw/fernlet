import Foundation

/// The World Home's own sprites, copied key for key from the approved design pages' `SPR` table (World
/// Review Batch 3 draws the camera on the blue button). Kept beside the Home that draws them, so the
/// shared sprite table stays one writer's.
extension WorldSprites {
    /// The disposable camera (`SPR.camera`, the kit's ink palette): ink body, paper face, a blue lens.
    nonisolated static let disposableCamera = WorldSprite(
        rows: ["..kkk.....", "kkkkkkkkkk", "kwwwwwwwwk", "kwwkkkwwwk", "kwkbbbkwwk", "kwwkkkwwwk", "kwwwwwwwwk", "kkkkkkkkkk"],
        palette: ["k": 0x4A2E1C, "w": 0xFFF6E2, "b": 0x6F98B6])

    /// The small red car the companion rides along in (`b1-home-car`, round 7), drawn key for key from the
    /// approved mockup: a 14 × 10 car at twice the riding companion's pixel, the windshield's left side and
    /// the open seat behind it, where the companion sits (``WorldRideCar``). Light and dark Home draw it the
    /// same, as the mockup does.
    nonisolated static let rideCar = WorldSprite(
        rows: ["....kk........", "...kbb........", "..kbbbkbbbbk..", ".kRRRRRRRRRRk.", "kRRRRRRRRRRRRk",
               "kRYRRRRRRRRYRk", "kRRRRRRRRRRRRk", ".kkGkkkkkkGkk.", "..kGk....kGk..", "...k......k..."],
        palette: ["k": 0x4A2E1C, "b": 0xCFE7F0, "R": 0xC8553D, "Y": 0xF2C14E, "G": 0x9C9A92])

    /// The car under Increase Contrast: a deeper outline and red on the light map; on the dark map a cream
    /// outline, so the car's edge never sinks into the night streets.
    nonisolated static func rideCar(dark: Bool, increasedContrast: Bool) -> WorldSprite {
        guard increasedContrast else { return rideCar }
        var palette = rideCar.palette
        palette["k"] = dark ? 0xF5EFE0 : 0x24140B
        palette["R"] = dark ? 0xD8634A : 0xB0412B
        return WorldSprite(rows: rideCar.rows, palette: palette)
    }
}
