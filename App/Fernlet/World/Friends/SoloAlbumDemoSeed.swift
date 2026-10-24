#if DEBUG
import UIKit
import FernletFoundation
import PrivateMediaStore

/// DEBUG only: plants three demo photos in a store's solo camera corpus for the screenshots of the
/// solo album (`FERNLET_UI_TEST_SOLO_ALBUM`; the simulator has no camera to take them). Absent from
/// Release builds entirely.
enum SoloAlbumDemoSeed {
    /// Which approved screen the photos stage.
    enum Scene: String {
        /// `b4-mem-solo-waiting`: three photos from today, held until tonight.
        case waiting
        /// `b4-mem-solo-revealed`: three photos from yesterday, shown.
        case revealed
        /// `b4-mem-solo-open`: the revealed set, opened.
        case open
    }

    /// Empties the corpus, then seals three rendered photos for `scene` through the store's own add.
    ///
    /// - Returns: whether all three were kept.
    static func plant(_ scene: Scene, in store: FernletStore, now: Date = .now) -> Bool {
        let corpus = SoloCameraPhotoStore(directory: store.soloCameraDirectory)
        guard corpus.purgeAll() else { return false }
        let hour: TimeInterval = 60 * 60
        let base = scene == .waiting ? now : now.addingTimeInterval(-24 * hour)
        let reveals = scene == .waiting ? now.addingTimeInterval(8 * hour) : base.addingTimeInterval(2 * hour)
        var kept = 0
        // R2: three photos.
        for variant in 0..<3 {
            let taken = base.addingTimeInterval(-Double(3 - variant) * hour)
            guard let data = image(variant) else { continue }
            let photo = SoloCameraPhoto(takenAt: taken, revealsAt: reveals)
            if case .added = corpus.add(photo, imageData: data, filmDay: FernletDate.dayKey(for: taken), dailyLimit: 10) {
                kept += 1
            }
        }
        return kept == 3
    }

    /// A simple park scene (sky, a sun, grass), a different light per variant.
    private static func image(_ variant: Int) -> Data? {
        let skies: [UInt32] = [0xF3D9A4, 0xA9C6DA, 0xE7D3A8]
        let grass: [UInt32] = [0x9CC08A, 0x8DB879, 0xC9A46A]
        let size = CGSize(width: 600, height: 750)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let picture = UIGraphicsImageRenderer(size: size, format: format).image { context in
            color(skies[variant % 3]).setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.45))
            color(grass[variant % 3]).setFill()
            context.fill(CGRect(x: 0, y: size.height * 0.45, width: size.width, height: size.height * 0.55))
            color(0xFFF1CF).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 380 - Double(variant) * 90, y: 90, width: 110, height: 110))
        }
        return picture.jpegData(compressionQuality: 0.85)
    }

    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif
