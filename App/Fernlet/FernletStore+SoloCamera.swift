import Foundation
import PrivateMediaStore

/// The disposable camera on your own (World build; owner 2026-10-24: "I think the photos can be
/// saved in the friend area" — ten a day, no Develop step, shown after the companion sleeps): where
/// this store's sealed solo corpus lives, the roll the camera shoots into, the read API the Friends
/// page will use once its design is approved, and the Delete everything leg.
extension FernletStore {
    /// THIS store's solo camera corpus: `SoloCameraPhotos/` under the store's own proximity root
    /// (production `Application Support/Fernlet`), per instance for the reason the pending
    /// session-photo corpus is — a test store that wipes must never reach another store's photos.
    nonisolated var soloCameraDirectory: URL {
        SoloCameraPhotoStore.directory(in: proximitySupportRoot)
    }

    /// The roll the camera shoots into on your own, following the duress decoy as it is now.
    func soloCameraRoll() -> SoloCameraRoll {
        soloCamera
    }

    /// The solo photos that show at `now`, newest first — none while the companion has not slept
    /// since they were taken, and none of the real ones in a decoy. For the Friends page once its
    /// design is approved; nothing draws them yet. Ask the same ``SoloCameraRoll`` for their bytes.
    func soloPhotos(visibleAt now: Date = .now) -> [SoloCameraPhoto] {
        soloCameraRoll().photos(visibleAt: now)
    }

    /// Delete everything's solo camera leg: the whole sealed corpus and its film count, keyless.
    /// Wipe leg 4e, inside `deletePhotoCorpora`. The duress silent wipe
    /// crypto-erases the corpus's key row with the rest of `com.fernlet.private-media` before this
    /// runs; the recovery lock keeps it, as it keeps every sibling photo corpus.
    ///
    /// - Returns: whether the corpus is gone.
    func purgeSoloCameraForDeleteAll() -> Bool {
        soloCamera.purgeForDeleteAll()
    }
}
