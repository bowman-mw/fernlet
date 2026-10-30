import Foundation
import WorldMapStore

extension FernletStore {
    /// The lifted cells the crossed roads and the city card read: the map's own (a decoy's alone in a decoy), and in
    /// a DEBUG roads screenshot the demo walk's too.
    var worldRoadCells: Set<HexCell> {
        let lifted = worldFog.visibleCells
        guard WorldRoadTestScenes.isOn(decoy: worldFog.isDecoy || duressSessionActive) else { return lifted }
        return lifted.union(WorldRoadTestScenes.cells)
    }
}
