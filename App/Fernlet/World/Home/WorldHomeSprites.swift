import Foundation

/// The World Home's own sprites, copied key for key from the approved design pages' `SPR` table (World
/// Review Batch 3 draws the camera on the blue button). Kept beside the Home that draws them, so the
/// shared sprite table stays one writer's.
extension WorldSprites {
    /// The disposable camera (`SPR.camera`, the kit's ink palette): ink body, paper face, a blue lens.
    nonisolated static let disposableCamera = WorldSprite(
        rows: ["..kkk.....", "kkkkkkkkkk", "kwwwwwwwwk", "kwwkkkwwwk", "kwkbbbkwwk", "kwwkkkwwwk", "kwwwwwwwwk", "kkkkkkkkkk"],
        palette: ["k": 0x4A2E1C, "w": 0xFFF6E2, "b": 0x6F98B6])
}
