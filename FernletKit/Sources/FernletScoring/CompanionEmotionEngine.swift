import Foundation
import FernletDomainModel

/// The person's night: when the companion gets sleepy and when it wakes, as minutes after local
/// midnight.
///
/// Device-local and set in Settings (`CompanionEmotionPreferences` in the app); ``standard`` is the
/// window used until the person picks their own. A bedtime after midnight (01:00) works the same as
/// one before it — every question is asked relative to the wake minute, so the window may wrap.
/// A window whose bedtime equals its wake time is EMPTY: the companion is never sleepy and the whole
/// day counts as waking hours.
public nonisolated struct CompanionSleepWindow: Equatable, Sendable {
    /// Minutes in one wall-clock day.
    public static let minutesPerDay = 1_440

    /// 22:30 to 07:00 — the window until the person sets their own.
    public static let standard = CompanionSleepWindow(bedtimeMinute: 22 * 60 + 30, wakeMinute: 7 * 60)

    /// When the companion gets sleepy, in minutes after local midnight (0..<1440).
    public let bedtimeMinute: Int
    /// When the companion wakes, in minutes after local midnight (0..<1440).
    public let wakeMinute: Int

    /// Both minutes are folded into 0..<1440, so a caller can never build an out-of-range window.
    public init(bedtimeMinute: Int, wakeMinute: Int) {
        self.bedtimeMinute = Self.folded(bedtimeMinute)
        self.wakeMinute = Self.folded(wakeMinute)
    }

    /// No sleep window at all (bedtime == wake).
    public var isEmpty: Bool { bedtimeMinute == wakeMinute }

    /// The waking span in minutes, wake to bedtime — the whole day for an empty window.
    public var awakeMinutes: Int {
        isEmpty ? Self.minutesPerDay : Self.folded(bedtimeMinute - wakeMinute)
    }

    /// Minutes since the most recent wake time for a local minute of the day (0..<1440).
    public func minutesSinceWake(_ minuteOfDay: Int) -> Int {
        Self.folded(minuteOfDay - wakeMinute)
    }

    /// Whether a local minute of the day falls inside the sleep window.
    public func isAsleep(atMinute minuteOfDay: Int) -> Bool {
        guard !isEmpty else { return false }
        return minutesSinceWake(minuteOfDay) >= awakeMinutes
    }

    private static func folded(_ minute: Int) -> Int {
        ((minute % minutesPerDay) + minutesPerDay) % minutesPerDay
    }
}

/// The opt-in body-signal reading, reduced to the two readings the companion can show.
///
/// `tense` covers both "tense" and "needs care". Nil whenever body signals are off or unread.
public nonisolated enum CompanionBodySignal: Equatable, Sendable {
    case calm
    case tense
}

/// Everything ``CompanionEmotionEngine`` reads. Assembled by the app from state it already holds;
/// every field is presentation input only, and nothing here is persisted by the engine.
///
/// Absolute instants (`lastMealAt`, `heartGlowUntil`, `playfulUntil`) rather than "is it true right
/// now" flags, so the same inputs answer for any instant of the day — which is what lets
/// ``CompanionEmotionEngine/timeline(for:dayContaining:calendar:)`` build the widget's whole day at
/// once.
public nonisolated struct CompanionEmotionInputs: Equatable, Sendable {
    /// Today's band. `.sick` is the unwell flag: it outranks every emotion.
    public var state: CompanionState
    /// The tag on today's latest journal entry or mood check-in; nil when there is none today.
    public var latestJournalTag: FeelingTag?
    /// The derived `moodTrend` signal reads "needs gentleness". Used only on a day with no entry yet.
    public var moodNeedsGentleness: Bool
    /// When today's most recent meal was logged; nil when no meal is logged today.
    public var lastMealAt: Date?
    /// Water logged today, in bottles.
    public var bottleCount: Int
    /// The day's water target, in bottles.
    public var hydrationTarget: Int
    /// The Settings switch for the appetite and thirst cues. Off means never hungry, never thirsty.
    public var appetiteCuesEnabled: Bool
    /// When the newest friend's heart stops glowing; nil when no heart is glowing. App-only.
    public var heartGlowUntil: Date?
    /// The opt-in body-signal reading; nil when body signals are off or unread. App-only.
    public var bodySignal: CompanionBodySignal?
    /// When the playful beat after a pet ends; nil when there has been no pet. App-only.
    public var playfulUntil: Date?
    /// The person's night.
    public var sleepWindow: CompanionSleepWindow

    public init(
        state: CompanionState,
        latestJournalTag: FeelingTag? = nil,
        moodNeedsGentleness: Bool = false,
        lastMealAt: Date? = nil,
        bottleCount: Int = 0,
        hydrationTarget: Int = 4,
        appetiteCuesEnabled: Bool = true,
        heartGlowUntil: Date? = nil,
        bodySignal: CompanionBodySignal? = nil,
        playfulUntil: Date? = nil,
        sleepWindow: CompanionSleepWindow = .standard
    ) {
        self.state = state
        self.latestJournalTag = latestJournalTag
        self.moodNeedsGentleness = moodNeedsGentleness
        self.lastMealAt = lastMealAt
        self.bottleCount = bottleCount
        self.hydrationTarget = hydrationTarget
        self.appetiteCuesEnabled = appetiteCuesEnabled
        self.heartGlowUntil = heartGlowUntil
        self.bodySignal = bodySignal
        self.playfulUntil = playfulUntil
        self.sleepWindow = sleepWindow
    }

    /// The same inputs with the app-only signals removed: the body-signal reading, the pet and the
    /// friend's heart.
    ///
    /// What the widget timeline is built from, so ``CompanionEmotion/calm``,
    /// ``CompanionEmotion/frazzled``, ``CompanionEmotion/playful``, ``CompanionEmotion/loved`` and
    /// ``CompanionEmotion/comforted`` cannot reach the widget snapshot by any route (see
    /// ``CompanionEmotion/isWidgetPublishable``).
    public var widgetSafe: CompanionEmotionInputs {
        var copy = self
        copy.bodySignal = nil
        copy.playfulUntil = nil
        copy.heartGlowUntil = nil
        return copy
    }

    /// A gentle day: today tagged hard or tired, or — with no entry yet today — a mood trend that
    /// needs gentleness. No happy-looking emotion is ever derived on one.
    ///
    /// Today's own entry outranks the trend on purpose: the trend looks back over the whole signal
    /// window and skips days with no entry, so on its own it could keep a companion sad for a week
    /// after one hard day. A trend-only day therefore never shows *sad*; it only holds back the
    /// cheerful faces.
    public var isGentleDay: Bool {
        switch latestJournalTag {
        case .hard, .tired: true
        case nil: moodNeedsGentleness
        case .bright, .good, .neutral, .quiet: false
        }
    }
}

/// One rule of the emotion precedence table: when it fires and what it shows.
///
/// The cases are listed in precedence order, and ``CompanionEmotionEngine/precedence`` is the same
/// order spelled out as the explicit table the engine walks.
public nonisolated enum CompanionEmotionRule: String, CaseIterable, Sendable {
    /// Today is marked unwell. No emotion: the sick face is the whole story.
    case unwell
    /// Inside the person's sleep window.
    case bedtime
    /// A gentle day, and a friend's heart is glowing or the companion was just petted.
    case held
    /// Today's latest entry is tagged hard.
    case hardDay
    /// Today's latest entry is tagged tired.
    case tiredDay
    /// Body signals read tense, on a thriving or okay day.
    case tense
    /// Petted in the last few minutes, on a day that is not gentle.
    case petted
    /// Cues on, waking hours, not resting, and no meal for a while.
    case hunger
    /// Cues on, waking hours, not resting, and water behind the day's pace.
    case thirst
    /// A friend's heart is glowing, on a day that is not gentle.
    case heart
    /// Today's latest entry is tagged bright or good.
    case brightDay
    /// The day's band is tired or resting.
    case lowBand
    /// Body signals read calm, on a thriving or okay day that is not gentle.
    case calmBody
    /// The day's band is thriving, on a day that is not gentle.
    case thriving

    /// What the rule shows when it fires — nil for ``unwell``, whose face is the state's own.
    public var emotion: CompanionEmotion? {
        switch self {
        case .unwell: nil
        case .bedtime: .sleepy
        case .held: .comforted
        case .hardDay: .sad
        case .tiredDay, .lowBand: .tired
        case .tense: .frazzled
        case .petted: .playful
        case .hunger: .hungry
        case .thirst: .thirsty
        case .heart: .loved
        case .brightDay, .thriving: .happy
        case .calmBody: .calm
        }
    }
}

/// One step of an emotion timeline: from `at` on, the companion shows `emotion` (nil = the state's
/// own face) until the next moment.
public nonisolated struct CompanionEmotionMoment: Equatable, Sendable {
    /// The instant the emotion begins, always on a whole second.
    public let at: Date
    /// The emotion from that instant; nil means no emotion (the plain state face).
    public let emotion: CompanionEmotion?

    public init(at: Date, emotion: CompanionEmotion?) {
        self.at = at
        self.emotion = emotion
    }
}

/// The companion's emotion as a pure function of its inputs and the clock.
///
/// ## Precedence (highest first)
///
/// | # | Rule | Shows | Fires when |
/// |---|---|---|---|
/// | 1 | `unwell` | — (the sick face) | today is marked unwell |
/// | 2 | `bedtime` | sleepy | inside the sleep window |
/// | 3 | `held` | comforted | gentle day, and a heart is glowing or the companion was just petted |
/// | 4 | `hardDay` | sad | today's latest entry is tagged hard |
/// | 5 | `tiredDay` | tired | today's latest entry is tagged tired |
/// | 6 | `tense` | frazzled | body signals read tense, band thriving or okay |
/// | 7 | `petted` | playful | petted in the last few minutes, day not gentle |
/// | 8 | `hunger` | hungry | cues on, waking hours, band not resting, no meal for a while |
/// | 9 | `thirst` | thirsty | cues on, waking hours, band not resting, water behind pace |
/// | 10 | `heart` | loved | a friend's heart is glowing, day not gentle |
/// | 11 | `brightDay` | happy | today's latest entry is tagged bright or good |
/// | 12 | `lowBand` | tired | band tired or resting |
/// | 13 | `calmBody` | calm | body signals read calm, band thriving or okay, day not gentle |
/// | 14 | `thriving` | happy | band thriving, day not gentle |
/// | — | — | — | otherwise: the plain state face |
///
/// Why this order: the unwell flag outranks everything; bedtime outranks the day (nobody is nudged
/// about food at night); what the person SAID about the day (hard, tired) outranks every signal the
/// app infers; the body's reading outranks a pet; a pet is answered at once; needs outrank a
/// friend's warmth; and the plain band comes last, so a morning with nothing logged yet shows
/// whatever is actually going on rather than a verdict on the empty log.
///
/// **Tone.** Signals never alarm. Sad is sad WITH the person and only ever mirrors a day they
/// tagged hard — never a low score or a missing log. Hunger and thirst come from logging gaps, so
/// they are bounded to waking hours minus a quiet evening, suppressed when unwell or resting, and
/// switched off entirely by the person's cue setting.
///
/// Everything is a nonisolated static over value types: no clock reads (callers pass `now`), no
/// I/O, no persistence.
public enum CompanionEmotionEngine {
    /// Hunger starts this long after the last logged meal.
    public static let hungerGap: TimeInterval = 4.5 * 60 * 60
    /// With no meal logged yet today, hunger starts this long after the wake time.
    public static let firstMealGrace: TimeInterval = 3 * 60 * 60
    /// The appetite and thirst cues fall silent this many minutes before bedtime.
    public static let eveningQuietMinutes = 90
    /// Thirst starts once water is this fraction of the day's target (at least one bottle) behind
    /// an even pace across the waking day.
    public static let thirstLagFraction = 1.0 / 3.0
    /// Upper bound on the moments one timeline may hold (R2: bounded growth).
    public static let maxTimelineMoments = 16

    /// The precedence table, highest first. The engine walks it top to bottom and the first rule
    /// that fires decides; `CompanionEmotionEngineTests` pins it row by row.
    public static let precedence: [CompanionEmotionRule] = [
        .unwell, .bedtime, .held, .hardDay, .tiredDay, .tense, .petted,
        .hunger, .thirst, .heart, .brightDay, .lowBand, .calmBody, .thriving
    ]

    /// The emotion at `now`, or nil for the plain state face.
    public static func emotion(for inputs: CompanionEmotionInputs, at now: Date,
                               calendar: Calendar = .current) -> CompanionEmotion? {
        firingRule(for: inputs, at: now, calendar: calendar)?.emotion
    }

    /// The first rule in ``precedence`` that fires at `now`, or nil when none does.
    public static func firingRule(for inputs: CompanionEmotionInputs, at now: Date,
                                  calendar: Calendar = .current) -> CompanionEmotionRule? {
        let clock = EmotionClock(now: now, dayStart: calendar.startOfDay(for: now), calendar: calendar)
        return precedence.first { fires($0, inputs: inputs, clock: clock) }
    }

    /// Whether one rule fires for these inputs at this instant — the table's right-hand column.
    static func fires(_ rule: CompanionEmotionRule, inputs: CompanionEmotionInputs, clock: EmotionClock) -> Bool {
        let gentle = inputs.isGentleDay
        let lowEnergy = inputs.state == .tired || inputs.state == .resting || inputs.state == .sick
        let cuesOpen = inputs.appetiteCuesEnabled && inputs.state != .resting
            && isInCueWindow(inputs.sleepWindow, clock: clock)
        switch rule {
        case .unwell: return inputs.state == .sick
        case .bedtime: return inputs.sleepWindow.isAsleep(atMinute: clock.minuteOfDay)
        case .held: return gentle && (isHeartGlowing(inputs, clock) || isPetted(inputs, clock))
        case .hardDay: return inputs.latestJournalTag == .hard
        case .tiredDay: return inputs.latestJournalTag == .tired
        case .tense: return inputs.bodySignal == .tense && !lowEnergy
        case .petted: return isPetted(inputs, clock) && !gentle
        case .hunger: return cuesOpen && clock.now >= hungerOnset(inputs, clock: clock)
        case .thirst: return cuesOpen && isThirsty(inputs, clock: clock)
        case .heart: return isHeartGlowing(inputs, clock) && !gentle
        case .brightDay: return inputs.latestJournalTag == .bright || inputs.latestJournalTag == .good
        case .lowBand: return inputs.state == .tired || inputs.state == .resting
        case .calmBody: return inputs.bodySignal == .calm && !lowEnergy && !gentle
        case .thriving: return inputs.state == .thriving && !gentle
        }
    }

    // MARK: - Timeline

    /// The emotion across the whole day containing `date`, through the next wake time: one moment per
    /// change, the first at local midnight.
    ///
    /// This is what the widget renders from, one WidgetKit timeline entry per moment, so a *sleepy*
    /// companion appears at bedtime and a *hungry* one at the hunger onset with the app closed.
    ///
    /// **Time-stable on purpose.** It covers the whole day from midnight rather than "from now", and
    /// every instant sits on a whole second, so two snapshots built at different times from an
    /// unchanged day carry byte-identical timelines — the property the background refresh's
    /// "reload only on change" diff depends on. Moments before the moment of computing are
    /// evaluated with today's CURRENT inputs, so they describe the day as it now stands rather than
    /// as it was then; nothing renders them.
    ///
    /// After local midnight the next day has not happened yet, so only the clock is known: the
    /// timeline shows *sleepy* inside the sleep window and nothing otherwise, and ends at the next
    /// wake time. A moment is always emitted AT that midnight, because a reader scopes each moment to
    /// the day it falls on (the widget never lets one day's emotion leak into the next). Pass
    /// ``CompanionEmotionInputs/widgetSafe`` inputs for anything that leaves the app.
    public static func timeline(for inputs: CompanionEmotionInputs, dayContaining date: Date,
                                calendar: Calendar = .current) -> [CompanionEmotionMoment] {
        let dayStart = calendar.startOfDay(for: date)
        let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        guard nextDayStart > dayStart else { return [] }
        let instants = candidateInstants(inputs, dayStart: dayStart, nextDayStart: nextDayStart, calendar: calendar)
        var moments: [CompanionEmotionMoment] = []
        for instant in instants.prefix(maxTimelineMoments * 2) {
            let emotion: CompanionEmotion? = if instant < nextDayStart {
                firingRule(for: inputs, at: instant, calendar: calendar)?.emotion
            } else {
                clockOnlyEmotion(inputs.sleepWindow, at: instant, calendar: calendar)
            }
            // The moment at the next midnight is kept even when nothing changes: a reader scopes each
            // moment to its own day, so without it the sleepy night would end at midnight.
            if let last = moments.last, last.emotion == emotion, instant != nextDayStart { continue }
            moments.append(CompanionEmotionMoment(at: instant, emotion: emotion))
        }
        return Array(moments.prefix(maxTimelineMoments))
    }

    /// What a timeline shows at `date`: the latest moment at or before it ON THE SAME LOCAL DAY.
    ///
    /// Day-scoped deliberately: a moment never carries into the next day, so a stale timeline can
    /// never show yesterday's feeling. The widget's `WidgetEmotionTimeline` in the extension is the
    /// hand-copied twin of this lookup — the rule is the contract, so keep the two identical.
    public static func emotion(in timeline: [CompanionEmotionMoment], at date: Date,
                               calendar: Calendar = .current) -> CompanionEmotion? {
        guard !timeline.isEmpty else { return nil }
        let day = calendar.startOfDay(for: date)
        return timeline.last { $0.at <= date && calendar.startOfDay(for: $0.at) == day }?.emotion
    }

    /// Every instant at which some rule's answer can change, sorted, de-duplicated, on whole
    /// seconds, from `dayStart` through the next wake time. Between two of them the emotion is
    /// constant, which is what makes one evaluation per instant exact.
    static func candidateInstants(_ inputs: CompanionEmotionInputs, dayStart: Date, nextDayStart: Date,
                                  calendar: Calendar) -> [Date] {
        assert(nextDayStart > dayStart, "a day must end after it starts")
        let window = inputs.sleepWindow
        let wake = instant(minute: window.wakeMinute, of: dayStart, calendar: calendar)
        let nextWake = instant(minute: window.wakeMinute, of: nextDayStart, calendar: calendar)
        let horizon = window.isEmpty ? nextDayStart : max(nextWake, nextDayStart)
        let cueMinutes = max(window.awakeMinutes - eveningQuietMinutes, 0)
        var raw: [Date?] = [
            dayStart, wake, nextDayStart, nextWake,
            instant(minute: window.bedtimeMinute, of: dayStart, calendar: calendar),
            instant(minute: window.bedtimeMinute, of: nextDayStart, calendar: calendar),
            wake.addingTimeInterval(TimeInterval(cueMinutes * 60)),
            inputs.heartGlowUntil, inputs.playfulUntil
        ]
        let clock = EmotionClock(now: dayStart, dayStart: dayStart, calendar: calendar)
        raw.append(hungerOnset(inputs, clock: clock))
        raw.append(thirstOnset(inputs, wake: wake))
        let valid = raw.compactMap { $0 }.map(wholeSecondCeiling).filter { $0 >= dayStart && $0 <= horizon }
        return Array(Set(valid)).sorted()
    }

    // MARK: - Rule helpers

    /// What the clock alone says once the day has rolled over: sleepy inside the window, else nothing.
    static func clockOnlyEmotion(_ window: CompanionSleepWindow, at instant: Date, calendar: Calendar) -> CompanionEmotion? {
        window.isAsleep(atMinute: EmotionClock.minuteOfDay(instant, calendar: calendar)) ? .sleepy : nil
    }

    /// Waking hours, minus the quiet evening before bedtime.
    static func isInCueWindow(_ window: CompanionSleepWindow, clock: EmotionClock) -> Bool {
        guard !window.isAsleep(atMinute: clock.minuteOfDay) else { return false }
        return window.minutesSinceWake(clock.minuteOfDay) < window.awakeMinutes - eveningQuietMinutes
    }

    /// When hunger begins today: ``hungerGap`` after the last logged meal, or ``firstMealGrace`` after
    /// the wake time when there is none yet.
    static func hungerOnset(_ inputs: CompanionEmotionInputs, clock: EmotionClock) -> Date {
        assert(hungerGap > 0 && firstMealGrace > 0, "hunger must start after the meal or the wake, never before")
        if let lastMealAt = inputs.lastMealAt {
            return lastMealAt.addingTimeInterval(hungerGap)
        }
        let wake = instant(minute: inputs.sleepWindow.wakeMinute, of: clock.dayStart, calendar: clock.calendar)
        return wake.addingTimeInterval(firstMealGrace)
    }

    /// Whether water is behind the day's pace at this instant.
    static func isThirsty(_ inputs: CompanionEmotionInputs, clock: EmotionClock) -> Bool {
        let wake = instant(minute: inputs.sleepWindow.wakeMinute, of: clock.dayStart, calendar: clock.calendar)
        guard let onset = thirstOnset(inputs, wake: wake) else { return false }
        return clock.now >= onset
    }

    /// When thirst begins today, or nil when the water logged so far can never fall far enough
    /// behind (target met, or too close to it for the lag to open before bedtime).
    static func thirstOnset(_ inputs: CompanionEmotionInputs, wake: Date) -> Date? {
        let target = Double(inputs.hydrationTarget)
        guard inputs.hydrationTarget > 0, inputs.bottleCount < inputs.hydrationTarget else { return nil }
        let lag = max(1, target * thirstLagFraction)
        let fraction = (Double(max(inputs.bottleCount, 0)) + lag) / target
        guard fraction < 1 else { return nil }
        let minutes = (Double(inputs.sleepWindow.awakeMinutes) * fraction).rounded(.up)
        return wake.addingTimeInterval(minutes * 60)
    }

    static func isHeartGlowing(_ inputs: CompanionEmotionInputs, _ clock: EmotionClock) -> Bool {
        inputs.heartGlowUntil.map { clock.now < $0 } ?? false
    }

    static func isPetted(_ inputs: CompanionEmotionInputs, _ clock: EmotionClock) -> Bool {
        inputs.playfulUntil.map { clock.now < $0 } ?? false
    }

    /// The wall-clock instant `minute` minutes after midnight on `day`, DST-safe; falls back to
    /// elapsed minutes when the calendar cannot place the time.
    static func instant(minute: Int, of day: Date, calendar: Calendar) -> Date {
        let placed = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day,
                                   matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
        return placed ?? day.addingTimeInterval(TimeInterval(minute * 60))
    }

    /// Rounds an instant UP to a whole second: an onset lands on or after the exact time it names,
    /// and a whole second survives the ISO-8601 round trip through the widget file unchanged.
    static func wholeSecondCeiling(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.up))
    }
}

/// One instant, placed on the local clock: the instant, its local midnight, and its minute of day.
struct EmotionClock {
    let now: Date
    let dayStart: Date
    let calendar: Calendar
    let minuteOfDay: Int

    init(now: Date, dayStart: Date, calendar: Calendar) {
        assert(dayStart <= now, "an instant is never before its own midnight")
        self.now = now
        self.dayStart = dayStart
        self.calendar = calendar
        self.minuteOfDay = Self.minuteOfDay(now, calendar: calendar)
    }

    /// The local minute of the day (0..<1440) an instant falls on.
    static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
