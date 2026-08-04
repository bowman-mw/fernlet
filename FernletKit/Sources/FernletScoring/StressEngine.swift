import Foundation

// MARK: - Stress ("body signals") engine
//
// A pure, deterministic, personal-baseline stress estimator. It compares each day's
// autonomic signals (HRV SDNN, resting heart rate) against the user's OWN recent normal
// (never a population norm), smooths the daily deviation with an EWMA, and maps the result
// to a small vocabulary of gentle wellness states. No I/O, no clocks, no HealthKit — the
// caller assembles `StressDaySample`s and persists whatever it wants.
//
// PRIVACY (S3 wall): this engine deliberately takes NO cycle/period inputs — no cycle
// phase, no period dates, nothing derived from PrivateHealthStore. Cycle data lives behind
// the sealed-store boundary and its only sanctioned scoring egress is the coarse
// `PeriodScoringAdjustment`. A stress engine that consumed cycle phase would create a
// second egress path for menstrual data and let a walled consumer of the abstract stress
// state infer cycle information. We instead accept the known luteal-phase HRV noise as
// estimation error (report §2.5 option (a)): a personally-harder phase may read as
// "a little tense", which the gentle copy tolerates by design.

/// One day of stress-relevant signals, assembled by the caller (most-recent day LAST).
///
/// All physiology fields are optional — a day with no wearable data simply contributes
/// nothing to baselines or deviations. In the app, the HealthKit gateway supplies the raw
/// metrics and the app-side stress service assembles the window it feeds to
/// ``StressEngine/assess(samples:)``.
public struct StressDaySample: Codable, Equatable, Sendable {
    /// `yyyy-MM-dd` day key.
    public var dateKey: String
    /// Daily mean HRV (SDNN, milliseconds). The anchor metric: without ≥7 valid HRV days
    /// the engine emits nothing at all.
    public var hrvSDNN: Double?
    /// Daily resting heart rate (bpm). Inverted for deviation (higher than usual = load).
    public var restingHR: Double?
    /// The user logged (or HealthKit recorded) a workout this day — training confounder.
    public var isWorkoutDay: Bool
    /// The user marked this day as sick — manual illness confounder.
    public var isSickDay: Bool
    /// Sleeping-wrist-temperature delta vs the user's own window mean, °C. Computed by the
    /// caller; > +0.5 °C suggests the body may be fighting something rather than "stress".
    public var wristTempDeltaC: Double?
    /// Daily mean respiratory rate (breaths/min); elevated vs baseline is an illness hint.
    public var respiratoryRate: Double?

    public init(
        dateKey: String,
        hrvSDNN: Double? = nil,
        restingHR: Double? = nil,
        isWorkoutDay: Bool = false,
        isSickDay: Bool = false,
        wristTempDeltaC: Double? = nil,
        respiratoryRate: Double? = nil
    ) {
        self.dateKey = dateKey
        self.hrvSDNN = hrvSDNN
        self.restingHR = restingHR
        self.isWorkoutDay = isWorkoutDay
        self.isSickDay = isSickDay
        self.wristTempDeltaC = wristTempDeltaC
        self.respiratoryRate = respiratoryRate
    }
}

/// The engine's gentle wellness vocabulary — never clinical.
///
/// Raw values are stable identifiers for the device-local sidecar; they are NEVER persisted into
/// any synced store or into `CompanionState` (companion "frazzled" is a presentation-only flag).
/// ``StressEngine/scoringModifier(for:)`` maps each state to its small capped score nudge.
public enum StressState: String, Codable, Equatable, Sendable {
    case calm
    case okay
    case tense
    case needsCare
}

/// Why a tense reading might not be "stress" — surfaced so the copy can soften itself.
///
/// Attached by ``StressEngine/assess(samples:)`` only when the state is `.tense` or worse; a
/// confounded reading is capped at `.tense`, and illness wins over training when both apply.
public enum StressAnnotation: String, Codable, Equatable, Sendable {
    /// Trained today or yesterday: probably "that good kind of tired", not strain.
    case workedOut
    /// Marked sick, warm wrist, or elevated respiration: possibly fighting something.
    case possiblyUnwell
}

/// How settled the personal baseline is. Driven purely by the count of valid HRV days.
///
/// Used by the explainer copy to set expectations while the baseline is forming; classification
/// thresholds stay widened (``StressEngine/wideningFactor``) until the baseline is `.established`.
public enum StressConfidence: String, Codable, Equatable, Sendable {
    case building      // 7..<14 valid days
    case settling      // 14..<30 valid days
    case established   // >= 30 valid days
}

/// The engine's output for "today" (the last sample).
///
/// A pure `Sendable` value bundling the classified ``StressState``, the smoothed deviation that
/// produced it, how settled the baseline is, and an optional softening ``StressAnnotation``. The
/// app-side stress service holds the current assessment (persisting it to the device-local
/// sidecar), and `FernletStore` feeds ``state`` through ``StressEngine/scoringModifier(for:)``
/// into the daily score.
public struct StressAssessment: Codable, Equatable, Sendable {
    /// The classified gentle wellness state (after the sustained rule and confounder capping).
    public var state: StressState
    /// EWMA-smoothed combined deviation (z) as of the last day. Negative = more load.
    public var smoothedZ: Double
    /// How settled the personal baseline behind this reading is.
    public var confidence: StressConfidence
    /// Optional confounder context (training or possible illness) softening the reading.
    public var annotation: StressAnnotation?

    public init(state: StressState, smoothedZ: Double, confidence: StressConfidence, annotation: StressAnnotation? = nil) {
        self.state = state
        self.smoothedZ = smoothedZ
        self.confidence = confidence
        self.annotation = annotation
    }
}

/// Abstract seam for anything that can produce a stress assessment — the plug-in point for
/// future (Phase-4) cross-vendor providers.
///
/// Requirements are async so actor-isolated services can conform; `providerID` should be a
/// nonisolated constant. As of the current tree nothing conforms yet: the app-side stress service
/// drives ``StressEngine`` directly, and this protocol is the seam it will be inverted onto when
/// a second provider arrives.
public protocol StressProvider {
    /// Stable identifier for the provider (should be a nonisolated constant).
    var providerID: String { get }
    /// The provider's assessment for today, or nil when it cannot produce one.
    func currentAssessment() async -> StressAssessment?
    /// How settled the provider's personal baseline is, or nil before one exists.
    func baselineConfidence() async -> StressConfidence?
}

/// Pure, deterministic personal-baseline stress estimator over daily HRV / resting-HR samples.
///
/// Compares each day's autonomic signals against the user's OWN recent normal (never a population
/// norm), smooths the daily deviation with a heavy EWMA, and classifies the result into the
/// gentle ``StressState`` vocabulary. `assess(samples:)` is the entry point; the other statics
/// are its exposed building blocks so the tests and the explainer copy share one source of truth
/// (the tunables). The app-side stress service assembles the ``StressDaySample`` window from
/// HealthKit metrics and runs the engine; `FernletStore` folds the result into scoring via
/// `scoringModifier(for:)`.
///
/// Invariants: no I/O, no clocks, no HealthKit — stateless nonisolated statics over
/// caller-supplied values. A cold start below `minimumValidDays` valid HRV days yields nil (never
/// a guess); daily deviations are clamped to ±`dailyZClamp`; `.needsCare` requires a sustained
/// deviation and is capped back to `.tense` by any confounder; and the scoring modifier is
/// re-clamped inside `computeBreakdown`, so no caller can exceed `scoringModifierRange`. By
/// design it takes NO cycle/period inputs (see the header note): the sealed store's only scoring
/// egress stays ``PeriodScoringAdjustment``.
public enum StressEngine {
    // MARK: Tunables (single source of truth for the tests + explainer copy)

    /// EWMA smoothing factor over the daily combined z — heavy smoothing so one rough
    /// night can never flip the state on its own.
    public static let ewmaAlpha = 0.3
    /// Cold-start floor: below this many valid HRV days the engine emits nothing
    /// ("still getting to know you").
    public static let minimumValidDays = 7
    /// Valid-HRV-day count at which the baseline counts as established (ideal window).
    public static let establishedValidDays = 30
    /// While the baseline is still settling (< `establishedValidDays`), classification
    /// thresholds are widened by this factor so early noise reads as "okay".
    public static let wideningFactor = 1.5
    /// Smoothed z at/above which the day reads `.calm`.
    public static let calmThreshold = 0.5
    /// Smoothed z at/below which the day leaves `.okay` toward `.tense`.
    public static let tenseThreshold = -0.5
    /// Smoothed z at/below which — when sustained — the day reads `.needsCare`.
    public static let needsCareThreshold = -1.5
    /// Daily combined z is clamped to ±this before smoothing so a single wild sample
    /// (or a near-zero SD early window) cannot dominate the EWMA.
    public static let dailyZClamp = 3.0
    /// Wrist-temperature delta (°C) above which the reading is annotated `.possiblyUnwell`.
    public static let illnessWristTempDeltaC = 0.5
    /// Respiratory-rate z above which the reading is annotated `.possiblyUnwell`.
    public static let illnessRespiratoryZ = 1.0
    /// Scoring-modifier clamp — capped and never dominant (mirrors `micronutrientModifier`).
    public static let scoringModifierRange: ClosedRange<Double> = -0.04...0.02

    // MARK: Baseline statistics

    /// Personal baseline for one metric over the supplied window.
    ///
    /// Built by `baseline(from:)`; deviations are always measured against `longMean` /
    /// `standardDeviation`, with `shortMean` kept as an informational "current normal".
    public struct MetricBaseline: Equatable, Sendable {
        /// Mean of the valid values among the last 7 days — the short "current normal"
        /// (informational; deviations are measured against the long window).
        public var shortMean: Double?
        /// Mean of every valid value in the window (30 days minimum, 60 ideal).
        public var longMean: Double
        /// Between-day sample standard deviation over the window.
        public var standardDeviation: Double
        /// Coefficient of variation (SD / long mean); 0 when the mean is 0.
        public var coefficientOfVariation: Double
        /// Number of non-nil days that fed the baseline.
        public var validDayCount: Int
    }

    /// Builds a baseline from the per-day values (ordered oldest→newest, nil = no data).
    /// Returns nil with fewer than 2 valid days (no meaningful SD).
    public static func baseline(from values: [Double?]) -> MetricBaseline? {
        let valid = values.compactMap { $0 }
        guard valid.count >= 2 else { return nil }
        let mean = valid.reduce(0, +) / Double(valid.count)
        let variance = valid.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(valid.count - 1)
        let sd = variance.squareRoot()
        let recentValid = values.suffix(7).compactMap { $0 }
        let shortMean = recentValid.isEmpty ? nil : recentValid.reduce(0, +) / Double(recentValid.count)
        return MetricBaseline(
            shortMean: shortMean,
            longMean: mean,
            standardDeviation: sd,
            coefficientOfVariation: mean == 0 ? 0 : sd / mean,
            validDayCount: valid.count
        )
    }

    /// Standard z-score of a value against a baseline. Nil when the SD is degenerate
    /// (near-zero spread would turn any wobble into a huge deviation).
    public static func zScore(_ value: Double, baseline: MetricBaseline) -> Double? {
        guard baseline.standardDeviation > 0.0001 else { return nil }
        return (value - baseline.longMean) / baseline.standardDeviation
    }

    /// One day's combined deviation: mean of the available per-metric z's — HRV as-is
    /// (lower than usual = load = negative), resting HR inverted (higher than usual =
    /// load = negative) — clamped to ±`dailyZClamp`. Nil when the day has no usable metric.
    public static func combinedZ(
        sample: StressDaySample,
        hrvBaseline: MetricBaseline?,
        restingHRBaseline: MetricBaseline?
    ) -> Double? {
        var deviations: [Double] = []
        if let hrv = sample.hrvSDNN, let baseline = hrvBaseline, let z = zScore(hrv, baseline: baseline) {
            deviations.append(z)
        }
        if let rhr = sample.restingHR, let baseline = restingHRBaseline, let z = zScore(rhr, baseline: baseline) {
            deviations.append(-z)
        }
        guard !deviations.isEmpty else { return nil }
        let mean = deviations.reduce(0, +) / Double(deviations.count)
        return min(max(mean, -dailyZClamp), dailyZClamp)
    }

    // MARK: Smoothing

    /// EWMA over an optional-valued daily series. Days without a value carry the previous
    /// smoothed value forward unchanged (nil until the first valued day seeds the series).
    public static func ewmaSeries(_ values: [Double?], alpha: Double = StressEngine.ewmaAlpha) -> [Double?] {
        var smoothed: [Double?] = []
        var current: Double?
        for value in values {
            if let value {
                current = current.map { alpha * value + (1 - alpha) * $0 } ?? value
            }
            smoothed.append(current)
        }
        return smoothed
    }

    // MARK: Classification

    /// Threshold scale for a given valid-day count: widened (×1.5) until the baseline is
    /// established at 30 valid days, then 1.0.
    public static func thresholdScale(validDays: Int) -> Double {
        validDays >= establishedValidDays ? 1.0 : wideningFactor
    }

    /// Raw band classification of a smoothed z (before the sustained-`needsCare` rule and
    /// confounder capping). `scale` widens the bands while the baseline is settling.
    public static func classify(smoothedZ: Double, scale: Double) -> StressState {
        if smoothedZ >= calmThreshold * scale { return .calm }
        if smoothedZ > tenseThreshold * scale { return .okay }
        if smoothedZ > needsCareThreshold * scale { return .tense }
        return .needsCare
    }

    /// Baseline confidence from the valid-HRV-day count (assumes >= `minimumValidDays`).
    public static func confidence(validDays: Int) -> StressConfidence {
        if validDays >= establishedValidDays { return .established }
        if validDays >= 14 { return .settling }
        return .building
    }

    // MARK: Assessment

    /// Assesses "today" (the LAST sample) against the personal baseline built from the
    /// whole window. Returns nil during cold start (< 7 valid HRV days) — the caller
    /// should show "still getting to know you" copy, never a guess.
    ///
    /// - Parameter samples: one sample per day, ordered oldest→newest, most-recent last.
    public static func assess(samples: [StressDaySample]) -> StressAssessment? {
        guard let today = samples.last else { return nil }

        let hrvBaseline = baseline(from: samples.map(\.hrvSDNN))
        guard let hrvBaseline, hrvBaseline.validDayCount >= minimumValidDays else { return nil }
        let restingHRBaseline = baseline(from: samples.map(\.restingHR))
        let respiratoryBaseline = baseline(from: samples.map(\.respiratoryRate))

        let dailyZ = samples.map { combinedZ(sample: $0, hrvBaseline: hrvBaseline, restingHRBaseline: restingHRBaseline) }
        let smoothedSeries = ewmaSeries(dailyZ)
        guard let smoothed = smoothedSeries.last ?? nil else { return nil }

        let scale = thresholdScale(validDays: hrvBaseline.validDayCount)
        var state = classify(smoothedZ: smoothed, scale: scale)

        // `.needsCare` requires the deep deviation to be SUSTAINED (>= 2 consecutive days
        // of smoothed z at/below the threshold); a single day reads `.tense` at most.
        if state == .needsCare {
            let previousSmoothed = smoothedSeries.count >= 2 ? smoothedSeries[smoothedSeries.count - 2] : nil
            let sustained = previousSmoothed.map { $0 <= needsCareThreshold * scale } ?? false
            if !sustained { state = .tense }
        }

        // Confounders — annotate and soften rather than alarm. Illness wins over training
        // when both apply (an unwell body should never be nudged toward "good tired" copy).
        // Annotations are only attached when they have something to explain (state >= tense).
        var annotation: StressAnnotation?
        if state == .tense || state == .needsCare {
            let previousDay = samples.count >= 2 ? samples[samples.count - 2] : nil
            var possiblyUnwell = today.isSickDay
            if let delta = today.wristTempDeltaC, delta > illnessWristTempDeltaC { possiblyUnwell = true }
            if let respiration = today.respiratoryRate,
               let respiratoryBaseline,
               let z = zScore(respiration, baseline: respiratoryBaseline),
               z > illnessRespiratoryZ {
                possiblyUnwell = true
            }
            if possiblyUnwell {
                annotation = .possiblyUnwell
            } else if today.isWorkoutDay || (previousDay?.isWorkoutDay ?? false) {
                annotation = .workedOut
            }
            // A confounded reading is capped at `.tense` — "worked out" or "possibly
            // unwell" should never escalate to the strongest state.
            if annotation != nil, state == .needsCare { state = .tense }
        }

        return StressAssessment(
            state: state,
            smoothedZ: smoothed,
            confidence: confidence(validDays: hrvBaseline.validDayCount),
            annotation: annotation
        )
    }

    // MARK: Scoring modifier

    /// Maps a gentle state to the small, capped, never-dominant scoring modifier
    /// (calm +0.02, okay 0, tense −0.02, needsCare −0.04). Nil state (cold start or
    /// feature off) is the identity 0 so scoring stays byte-identical.
    public static func scoringModifier(for state: StressState?) -> Double {
        let raw: Double
        switch state {
        case .calm: raw = 0.02
        case .okay, nil: raw = 0
        case .tense: raw = -0.02
        case .needsCare: raw = -0.04
        }
        return clampScoringModifier(raw)
    }

    /// Clamps any stress modifier into the allowed range — applied again inside
    /// `computeBreakdown` so no caller can exceed the cap.
    public static func clampScoringModifier(_ value: Double) -> Double {
        min(max(value, scoringModifierRange.lowerBound), scoringModifierRange.upperBound)
    }
}
