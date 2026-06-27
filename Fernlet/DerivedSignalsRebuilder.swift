import FernletDomainModel
struct DerivedSignalsRebuilder {
    static func rebuild(
        allDays: [String: FernletDay],
        todayKey: String,
        windowDays: Int = FernletLimits.signalWindowDays
    ) -> [DerivedSignalRecord] {
        let orderedDays = allDays.sorted { first, second in first.key < second.key }
        let recent = Array(orderedDays.suffix(windowDays))
        return DerivedSignalFactory.makeSignals(from: recent, todayKey: todayKey)
    }
}
