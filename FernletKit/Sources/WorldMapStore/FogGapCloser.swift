import Foundation

/// What one gap-closing pass found: the enclosed cells, how many hidden cells it examined, and
/// whether a cap stopped it before it had looked at everything it was given.
public nonisolated struct FogGapScan: Equatable, Sendable {
    /// The hidden cells whose six neighbours are all revealed, sorted by ``HexCell/id``.
    public var gaps: [HexCell]
    /// How many distinct hidden cells the pass examined.
    public var examined: Int
    /// Whether a cap (cells given, or cells examined) cut the pass short.
    public var hitCap: Bool

    /// A scan result.
    public init(gaps: [HexCell], examined: Int, hitCap: Bool) {
        self.gaps = gaps
        self.examined = examined
        self.hitCap = hitCap
    }
}

/// Closes the fog's odd hidden tiles (round 7, idea 7): a single fogged cell whose six neighbours
/// (``MercatorHexGrid/neighbours(of:)``) are all revealed is a hole the eye reads as a glitch, so it
/// is lifted with its surround.
///
/// Only single cells close. Two or more hidden cells next to each other are never filled, and a cell
/// that is not fully enclosed is never returned. A filled cell is at most one cell (about 17.5 m at
/// 45°) inside ground the person already uncovered, so closing reveals nothing new about where they went.
///
/// **One round is enough.** Filling a gap `G` could only complete another enclosure `H` if `G` were
/// one of `H`'s neighbours. But every neighbour of `G` is already revealed (that is what made `G` a
/// gap), so no hidden cell touches `G`, and filling it encloses nothing further. For the same reason
/// two gaps found in one pass are never neighbours, so their order does not matter. The pass is
/// therefore never iterated.
///
/// Bounded (Power of 10): ``closingScan(around:in:)`` reads at most ``maxLiftedPerPass`` lifted
/// cells and so examines at most ``maxExaminedPerPass`` hidden cells (six each), each with six
/// lookups. The one-off ``sweep(revealed:limit:)`` reads at most ``maxSweepSources`` revealed cells
/// and examines at most ``maxSweepExamined``.
public nonisolated enum FogGapCloser {
    /// The most lifted cells one pass reads. One fix lifts a few dozen (50 m); a drained buffer more.
    public static let maxLiftedPerPass = 2_000
    /// The most hidden cells one pass examines: six neighbours for each lifted cell read.
    public static let maxExaminedPerPass = 6 * maxLiftedPerPass
    /// The most revealed cells a sweep reads: `FogCellStore.maxCells`, a full store.
    public static let maxSweepSources = 250_000
    /// The most hidden cells a sweep examines: six for each revealed cell of a full store.
    public static let maxSweepExamined = 6 * maxSweepSources

    /// Whether `cell` is hidden and all six of its neighbours are in `revealed`.
    public static func isEnclosed(_ cell: HexCell, in revealed: Set<HexCell>) -> Bool {
        guard !revealed.contains(cell) else { return false }
        return MercatorHexGrid.neighbours(of: cell).allSatisfy { revealed.contains($0) }
    }

    /// The gaps that `lifted` (the cells just lifted) closed: the hidden cells next to them that are
    /// now fully enclosed by `revealed`. `revealed` must already hold `lifted`; a lifted cell it does
    /// not hold (the store refused it at its cap) is skipped. Cells away from `lifted` are not examined.
    public static func closing(around lifted: [HexCell], in revealed: Set<HexCell>) -> [HexCell] {
        closingScan(around: lifted, in: revealed).gaps
    }

    /// ``closing(around:in:)`` with the counts: at most ``maxLiftedPerPass`` lifted cells are read
    /// (the rest set ``FogGapScan/hitCap``), so at most ``maxExaminedPerPass`` cells are examined.
    public static func closingScan(around lifted: [HexCell], in revealed: Set<HexCell>) -> FogGapScan {
        guard !lifted.isEmpty, !revealed.isEmpty else {
            return FogGapScan(gaps: [], examined: 0, hitCap: false)
        }
        let sources = lifted.prefix(maxLiftedPerPass).filter { revealed.contains($0) }
        var scan = examine(sources, in: revealed, cap: maxExaminedPerPass)
        if lifted.count > maxLiftedPerPass { scan.hitCap = true }
        return scan
    }

    /// A one-off pass over an existing history: every hidden neighbour of `revealed`, in ``HexCell/id``
    /// order, until `limit` hidden cells (clamped to 0...``maxSweepExamined``) have been examined or
    /// ``maxSweepSources`` revealed cells read. ``FogGapScan/hitCap`` says whether it stopped early;
    /// a later sweep with a higher limit finds the rest.
    public static func sweep(revealed: Set<HexCell>, limit: Int = maxSweepExamined) -> FogGapScan {
        let cap = min(max(limit, 0), maxSweepExamined)
        guard !revealed.isEmpty else { return FogGapScan(gaps: [], examined: 0, hitCap: false) }
        guard cap > 0 else { return FogGapScan(gaps: [], examined: 0, hitCap: true) }
        let sources = revealed.sorted().prefix(maxSweepSources)
        var scan = examine(sources, in: revealed, cap: cap)
        if revealed.count > maxSweepSources { scan.hitCap = true }
        return scan
    }

    /// Examines each hidden neighbour of `sources` once, stopping before the `cap`-plus-first.
    /// Bound: `sources.count` × 6 iterations, and at most `cap` examinations of six lookups each.
    private static func examine<Sources: Collection<HexCell>>(
        _ sources: Sources, in revealed: Set<HexCell>, cap: Int
    ) -> FogGapScan {
        guard cap > 0 else { return FogGapScan(gaps: [], examined: 0, hitCap: !sources.isEmpty) }
        var seen = Set<HexCell>()
        seen.reserveCapacity(min(cap, sources.count * 6))
        var gaps: [HexCell] = []
        for source in sources {
            for candidate in MercatorHexGrid.neighbours(of: source)
            where !revealed.contains(candidate) && !seen.contains(candidate) {
                guard seen.count < cap else {
                    return FogGapScan(gaps: gaps.sorted(), examined: seen.count, hitCap: true)
                }
                seen.insert(candidate)
                if isEnclosed(candidate, in: revealed) { gaps.append(candidate) }
            }
        }
        return FogGapScan(gaps: gaps.sorted(), examined: seen.count, hitCap: false)
    }
}
