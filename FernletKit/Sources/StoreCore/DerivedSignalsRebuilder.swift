import FernletDomainModel
import LocalPersistence
/// Stateless recompute of the derived-signal set from the trailing window of raw day history.
///
/// A pure, nonisolated struct and the sole caller of `DerivedSignalFactory.makeSignals`: it orders
/// the day map by key (day keys are zero-padded `yyyy-MM-dd`, so lexicographic order is
/// chronological), trims to the trailing `FernletLimits.signalWindowDays` window, and hands the
/// slice to the factory. Derived signals are Tier-2 data — always reproducible from raw days with
/// no AI involvement — so this type persists nothing: ``DerivedSignalsService`` decides when a
/// rebuild runs, and `LocalFernletDatabase` owns where the records land.
public struct DerivedSignalsRebuilder {
    /// Recomputes the full signal set from the trailing window of `allDays`.
    ///
    /// - Parameters:
    ///   - allDays: The complete day history, keyed by `yyyy-MM-dd` day key.
    ///   - todayKey: The day key the factory treats as "today" for its recency math.
    ///   - windowDays: How many trailing days feed the factory.
    /// - Returns: The factory's freshly built `DerivedSignalRecord` set.
    public static func rebuild(
        allDays: [String: FernletDay],
        todayKey: String,
        windowDays: Int = FernletLimits.signalWindowDays
    ) -> [DerivedSignalRecord] {
        let orderedDays = allDays.sorted { first, second in first.key < second.key }
        let recent = Array(orderedDays.suffix(windowDays))
        return DerivedSignalFactory.makeSignals(from: recent, todayKey: todayKey)
    }
}
