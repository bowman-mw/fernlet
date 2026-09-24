import Foundation
import Testing
import FernletDomainModel
import FernletScoring

/// The companion's emotions (owner decision 2026-09-24): the precedence table, every rule alone and
/// in conflict, the tone invariants over a full input grid, the sleep window, and the widget timeline.
///
/// Every instant is built on a fixed Gregorian calendar in `America/New_York`, so nothing here reads
/// the machine's clock or time zone.
struct CompanionEmotionEngineTests {

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        return calendar
    }()

    /// 2026-09-24 at `hour`:`minute` local (or another September day).
    static func at(_ hour: Int, _ minute: Int = 0, day: Int = 24, month: Int = 9) -> Date {
        let parts = DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)
        return calendar.date(from: parts) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    /// An okay day at 13:00 where nothing fires: lunch at noon, water met, no tag, no heart.
    static func base() -> CompanionEmotionInputs {
        CompanionEmotionInputs(state: .okay, lastMealAt: at(12), bottleCount: 4, hydrationTarget: 4)
    }

    static func emotion(_ inputs: CompanionEmotionInputs, _ time: Date = at(13)) -> CompanionEmotion? {
        CompanionEmotionEngine.emotion(for: inputs, at: time, calendar: calendar)
    }

    static func rule(_ inputs: CompanionEmotionInputs, _ time: Date = at(13)) -> CompanionEmotionRule? {
        CompanionEmotionEngine.firingRule(for: inputs, at: time, calendar: calendar)
    }

    // MARK: - The table

    /// The precedence table, row by row. Reordering a rule is a behaviour change: this list is the
    /// place it has to be argued for, together with the DocC table in `FernletScoring.md`.
    @Test func precedenceTableIsPinnedRowByRow() {
        let expected: [(CompanionEmotionRule, CompanionEmotion?)] = [
            (.unwell, nil), (.bedtime, .sleepy), (.held, .comforted), (.hardDay, .sad),
            (.tiredDay, .tired), (.tense, .frazzled), (.petted, .playful), (.hunger, .hungry),
            (.thirst, .thirsty), (.heart, .loved), (.brightDay, .happy), (.lowBand, .tired),
            (.calmBody, .calm), (.thriving, .happy)
        ]
        #expect(CompanionEmotionEngine.precedence == expected.map(\.0))
        #expect(CompanionEmotionEngine.precedence == CompanionEmotionRule.allCases,
                "the enum's declaration order and the explicit table drifted apart")
        for (rule, emotion) in expected {
            #expect(rule.emotion == emotion, "\(rule) now shows \(String(describing: rule.emotion))")
        }
        let shown = Set(CompanionEmotionEngine.precedence.compactMap(\.emotion))
        #expect(shown == Set(CompanionEmotion.allCases), "every emotion must be reachable from some rule")
    }

    @Test func theBaseDayShowsThePlainStateFace() {
        #expect(Self.rule(Self.base()) == nil)
        #expect(Self.emotion(Self.base()) == nil)
    }

    /// Each rule, alone, in the smallest scenario that fires it.
    @Test func everyRuleFiresAloneInItsOwnScenario() {
        let heart = Self.at(20)
        let pet = Self.at(13, 3)
        let scenarios: [(CompanionEmotionRule, CompanionEmotionInputs, Date)] = [
            (.unwell, Self.with { $0.state = .sick }, Self.at(13)),
            (.bedtime, Self.base(), Self.at(23)),
            (.held, Self.with { $0.latestJournalTag = .hard; $0.heartGlowUntil = heart }, Self.at(13)),
            (.hardDay, Self.with { $0.latestJournalTag = .hard }, Self.at(13)),
            (.tiredDay, Self.with { $0.latestJournalTag = .tired }, Self.at(13)),
            (.tense, Self.with { $0.bodySignal = .tense }, Self.at(13)),
            (.petted, Self.with { $0.playfulUntil = pet }, Self.at(13)),
            (.hunger, Self.with { $0.lastMealAt = Self.at(8) }, Self.at(13)),
            (.thirst, Self.with { $0.bottleCount = 0 }, Self.at(13)),
            (.heart, Self.with { $0.heartGlowUntil = heart }, Self.at(13)),
            (.brightDay, Self.with { $0.latestJournalTag = .bright }, Self.at(13)),
            (.lowBand, Self.with { $0.state = .tired }, Self.at(13)),
            (.calmBody, Self.with { $0.bodySignal = .calm }, Self.at(13)),
            (.thriving, Self.with { $0.state = .thriving }, Self.at(13))
        ]
        #expect(scenarios.map(\.0) == CompanionEmotionEngine.precedence, "one scenario per rule, in table order")
        for (rule, inputs, time) in scenarios {
            #expect(Self.rule(inputs, time) == rule, "\(rule)'s own scenario fired \(String(describing: Self.rule(inputs, time)))")
        }
    }

    /// The base day, edited.
    static func with(_ edit: (inout CompanionEmotionInputs) -> Void) -> CompanionEmotionInputs {
        var inputs = base()
        edit(&inputs)
        return inputs
    }

    /// Two (or more) rules true at once: the higher one wins, including the composite `held` row.
    @Test func higherRulesWinEveryConflict() {
        let heart = Self.at(20)
        let pet = Self.at(13, 3)
        let cases: [(String, CompanionEmotionInputs, Date, CompanionEmotion?)] = [
            ("sick over bedtime", Self.with { $0.state = .sick }, Self.at(23), nil),
            ("sick over hunger", Self.with { $0.state = .sick; $0.lastMealAt = Self.at(6) }, Self.at(13), nil),
            ("bedtime over a hard day", Self.with { $0.latestJournalTag = .hard }, Self.at(23, 30), .sleepy),
            ("hard + heart is held", Self.with { $0.latestJournalTag = .hard; $0.heartGlowUntil = heart }, Self.at(13), .comforted),
            ("hard + pet is held", Self.with { $0.latestJournalTag = .hard; $0.playfulUntil = pet }, Self.at(13), .comforted),
            ("tired tag + heart is held", Self.with { $0.latestJournalTag = .tired; $0.heartGlowUntil = heart }, Self.at(13), .comforted),
            ("trend + heart is held", Self.with { $0.moodNeedsGentleness = true; $0.heartGlowUntil = heart }, Self.at(13), .comforted),
            ("sad over hunger", Self.with { $0.latestJournalTag = .hard; $0.lastMealAt = Self.at(6) }, Self.at(13), .sad),
            ("sad over tense", Self.with { $0.latestJournalTag = .hard; $0.bodySignal = .tense }, Self.at(13), .sad),
            ("sad over thriving", Self.with { $0.latestJournalTag = .hard; $0.state = .thriving }, Self.at(13), .sad),
            ("tired tag over tense", Self.with { $0.latestJournalTag = .tired; $0.bodySignal = .tense }, Self.at(13), .tired),
            ("tired tag + pet is held", Self.with { $0.latestJournalTag = .tired; $0.playfulUntil = pet }, Self.at(13), .comforted),
            ("tired tag over thriving", Self.with { $0.latestJournalTag = .tired; $0.state = .thriving }, Self.at(13), .tired),
            ("tense over a pet", Self.with { $0.bodySignal = .tense; $0.playfulUntil = pet }, Self.at(13), .frazzled),
            ("tense over hunger", Self.with { $0.bodySignal = .tense; $0.lastMealAt = Self.at(6) }, Self.at(13), .frazzled),
            ("pet over hunger", Self.with { $0.playfulUntil = pet; $0.lastMealAt = Self.at(6) }, Self.at(13), .playful),
            ("hunger over thirst", Self.with { $0.lastMealAt = Self.at(6); $0.bottleCount = 0 }, Self.at(13), .hungry),
            ("thirst over heart", Self.with { $0.bottleCount = 0; $0.heartGlowUntil = heart }, Self.at(13), .thirsty),
            ("heart over bright", Self.with { $0.heartGlowUntil = heart; $0.latestJournalTag = .bright }, Self.at(13), .loved),
            ("heart over the low band", Self.with { $0.heartGlowUntil = heart; $0.state = .tired }, Self.at(13), .loved),
            ("bright over the low band", Self.with { $0.latestJournalTag = .good; $0.state = .tired }, Self.at(13), .happy),
            ("low band over calm", Self.with { $0.state = .tired; $0.bodySignal = .calm }, Self.at(13), .tired),
            ("calm over thriving", Self.with { $0.state = .thriving; $0.bodySignal = .calm }, Self.at(13), .calm),
            ("trend-only holds back thriving", Self.with { $0.moodNeedsGentleness = true; $0.state = .thriving }, Self.at(13), nil),
            ("trend-only never shows sad", Self.with { $0.moodNeedsGentleness = true }, Self.at(13), nil),
            ("today's entry outranks the trend", Self.with { $0.moodNeedsGentleness = true; $0.latestJournalTag = .bright }, Self.at(13), .happy),
            ("resting never hungry", Self.with { $0.state = .resting; $0.lastMealAt = Self.at(6) }, Self.at(13), .tired),
            ("cues off never hungry", Self.with { $0.appetiteCuesEnabled = false; $0.lastMealAt = Self.at(6) }, Self.at(13), nil),
            ("cues off never thirsty", Self.with { $0.appetiteCuesEnabled = false; $0.bottleCount = 0 }, Self.at(13), nil),
            ("the quiet evening mutes hunger", Self.with { $0.lastMealAt = Self.at(14) }, Self.at(21, 15), nil),
            ("hunger holds until the quiet evening", Self.with { $0.lastMealAt = Self.at(14) }, Self.at(20, 45), .hungry)
        ]
        for (name, inputs, time, expected) in cases {
            #expect(Self.emotion(inputs, time) == expected,
                    "\(name): expected \(String(describing: expected)), got \(String(describing: Self.emotion(inputs, time)))")
        }
    }

    // MARK: - Tone invariants over the whole grid

    /// Every combination of the discrete inputs at seven times of day, against the tone rules:
    /// sick shows nothing, bedtime shows sleepy, a gentle or unwell day never looks happy, sad only
    /// mirrors a hard tag, and appetite cues respect the switch, the band and the clock.
    @Test func toneInvariantsHoldAcrossTheWholeInputGrid() {
        var checked = 0
        for inputs in Self.grid() {
            for time in Self.gridTimes {
                Self.checkInvariants(inputs, at: time)
                checked += 1
            }
        }
        #expect(checked > 100_000, "the grid shrank to \(checked) cells — the invariants are checking less")
    }

    static let gridTimes: [Date] = [at(3), at(7, 30), at(10, 30), at(13), at(17, 30), at(21, 30), at(23, 30)]

    /// Every discrete input combination, built without nested-loop depth: one flat index decoded.
    static func grid() -> [CompanionEmotionInputs] {
        let states: [CompanionState] = [.thriving, .okay, .tired, .resting, .sick]
        let tags: [FeelingTag?] = [nil] + FeelingTag.allCases.map { $0 }
        let meals: [Date?] = [nil, at(6, 30), at(12)]
        let bodies: [CompanionBodySignal?] = [nil, .calm, .tense]
        let dims = [states.count, tags.count, 2, meals.count, 3, 2, bodies.count, 2, 2]
        let total = dims.reduce(1, *)
        return (0..<total).map { index in
            var rest = index
            var digit: [Int] = []
            for size in dims {
                digit.append(rest % size)
                rest /= size
            }
            return CompanionEmotionInputs(
                state: states[digit[0]], latestJournalTag: tags[digit[1]], moodNeedsGentleness: digit[2] == 1,
                lastMealAt: meals[digit[3]], bottleCount: [0, 2, 4][digit[4]], hydrationTarget: 4,
                appetiteCuesEnabled: digit[8] == 0, heartGlowUntil: digit[5] == 1 ? at(22) : nil,
                bodySignal: bodies[digit[6]], playfulUntil: digit[7] == 1 ? at(23, 59) : nil)
        }
    }

    static func checkInvariants(_ inputs: CompanionEmotionInputs, at time: Date) {
        let emotion = Self.emotion(inputs, time)
        let minute = calendar.component(.hour, from: time) * 60 + calendar.component(.minute, from: time)
        let asleep = inputs.sleepWindow.isAsleep(atMinute: minute)
        if inputs.state == .sick { #expect(emotion == nil, "sick must outrank every emotion: \(inputs)") }
        if inputs.state != .sick && asleep { #expect(emotion == .sleepy, "bedtime must show sleepy: \(inputs)") }
        if inputs.isGentleDay || inputs.state == .sick {
            #expect(emotion?.isHappyLooking != true, "happy-looking \(String(describing: emotion)) on a gentle/unwell day: \(inputs)")
        }
        if emotion == .sad { #expect(inputs.latestJournalTag == .hard, "sad without a hard tag: \(inputs)") }
        if emotion == .hungry || emotion == .thirsty {
            #expect(inputs.appetiteCuesEnabled && inputs.state != .resting && !asleep, "an appetite cue broke its bounds: \(inputs)")
            let sinceWake = inputs.sleepWindow.minutesSinceWake(minute)
            #expect(sinceWake < inputs.sleepWindow.awakeMinutes - CompanionEmotionEngine.eveningQuietMinutes,
                    "an appetite cue inside the quiet evening: \(inputs)")
        }
        if emotion == .calm || emotion == .frazzled {
            #expect(inputs.state == .thriving || inputs.state == .okay, "a body-signal face on a low band: \(inputs)")
        }
        let widgetEmotion = Self.emotion(inputs.widgetSafe, time)
        #expect(widgetEmotion?.isWidgetPublishable != false, "the widget-safe inputs derived \(String(describing: widgetEmotion))")
    }

    // MARK: - Sleep window

    @Test func theStandardWindowWrapsMidnight() {
        let window = CompanionSleepWindow.standard
        #expect(window.bedtimeMinute == 22 * 60 + 30 && window.wakeMinute == 7 * 60)
        #expect(window.awakeMinutes == 930)
        #expect(window.isAsleep(atMinute: 23 * 60))
        #expect(window.isAsleep(atMinute: 2 * 60))
        #expect(window.isAsleep(atMinute: 6 * 60 + 59))
        #expect(!window.isAsleep(atMinute: 7 * 60))
        #expect(!window.isAsleep(atMinute: 22 * 60 + 29))
        #expect(window.isAsleep(atMinute: 22 * 60 + 30))
    }

    @Test func aBedtimeAfterMidnightWorksTheSame() {
        let window = CompanionSleepWindow(bedtimeMinute: 60, wakeMinute: 9 * 60)
        #expect(!window.isAsleep(atMinute: 30))
        #expect(window.isAsleep(atMinute: 60))
        #expect(window.isAsleep(atMinute: 8 * 60 + 59))
        #expect(!window.isAsleep(atMinute: 9 * 60))
        #expect(window.awakeMinutes == 16 * 60)
    }

    @Test func anEmptyWindowIsNeverSleepyAndFoldingKeepsMinutesInRange() {
        let empty = CompanionSleepWindow(bedtimeMinute: 8 * 60, wakeMinute: 8 * 60)
        #expect(empty.isEmpty && empty.awakeMinutes == 1_440)
        #expect((0..<1_440).allSatisfy { !empty.isAsleep(atMinute: $0) })
        let folded = CompanionSleepWindow(bedtimeMinute: -30, wakeMinute: 1_500)
        #expect(folded.bedtimeMinute == 1_410 && folded.wakeMinute == 60)
    }

    // MARK: - Timeline

    /// A lunch-at-12:30 okay day: hungry from 17:00, quiet from 21:00, sleepy from 22:30, sleepy again
    /// AT midnight (a new day's own moment), and nothing from the next wake.
    @Test func timelineMarksEachTransition() {
        let inputs = Self.with { $0.lastMealAt = Self.at(12, 30) }
        let timeline = CompanionEmotionEngine.timeline(for: inputs, dayContaining: Self.at(13), calendar: Self.calendar)
        let expected: [(Date, CompanionEmotion?)] = [
            (Self.at(0), .sleepy), (Self.at(7), nil), (Self.at(17), .hungry), (Self.at(21), nil),
            (Self.at(22, 30), .sleepy), (Self.at(0, day: 25), .sleepy), (Self.at(7, day: 25), nil)
        ]
        #expect(timeline.map(\.at) == expected.map(\.0))
        #expect(timeline.map(\.emotion) == expected.map(\.1))
    }

    /// Two snapshots of an unchanged day, built at different times, carry the same timeline — what
    /// the background refresh's reload-only-on-change diff depends on.
    @Test func timelineIsTimeStable() {
        let inputs = Self.with { $0.lastMealAt = Self.at(9, 15); $0.bottleCount = 1; $0.heartGlowUntil = Self.at(19, 40) }
        let morning = CompanionEmotionEngine.timeline(for: inputs, dayContaining: Self.at(0), calendar: Self.calendar)
        let noon = CompanionEmotionEngine.timeline(for: inputs, dayContaining: Self.at(12), calendar: Self.calendar)
        let night = CompanionEmotionEngine.timeline(for: inputs, dayContaining: Self.at(23, 59), calendar: Self.calendar)
        #expect(morning == noon && noon == night)
    }

    /// Fractional input instants never leak into the timeline: every moment survives the widget
    /// file's whole-second ISO-8601 round trip unchanged.
    @Test func timelineMomentsSitOnWholeSeconds() {
        let inputs = Self.with {
            $0.lastMealAt = Self.at(9).addingTimeInterval(0.4321)
            $0.heartGlowUntil = Self.at(15).addingTimeInterval(12.75)
            $0.playfulUntil = Self.at(10).addingTimeInterval(0.5)
            $0.bottleCount = 0
        }
        let timeline = CompanionEmotionEngine.timeline(for: inputs, dayContaining: Self.at(12), calendar: Self.calendar)
        #expect(!timeline.isEmpty)
        for moment in timeline {
            let seconds = moment.at.timeIntervalSinceReferenceDate
            #expect(seconds == seconds.rounded(), "moment \(moment.at) is not on a whole second")
        }
    }

    /// The candidate instants are complete: the timeline and the live engine agree at every five
    /// minutes of the day, for several days that exercise every time-driven rule.
    @Test func timelineAgreesWithTheLiveEngineAllDay() {
        let days: [CompanionEmotionInputs] = [
            Self.with { $0.lastMealAt = Self.at(12, 30) },
            Self.with { $0.lastMealAt = nil; $0.bottleCount = 0 },
            Self.with { $0.lastMealAt = Self.at(8, 7); $0.bottleCount = 1; $0.heartGlowUntil = Self.at(16, 20) },
            Self.with { $0.latestJournalTag = .hard; $0.heartGlowUntil = Self.at(11, 11) },
            Self.with { $0.playfulUntil = Self.at(10, 2); $0.bodySignal = .calm; $0.state = .thriving },
            Self.with { $0.sleepWindow = CompanionSleepWindow(bedtimeMinute: 60, wakeMinute: 9 * 60); $0.lastMealAt = Self.at(15) }
        ]
        for inputs in days {
            let timeline = CompanionEmotionEngine.timeline(for: inputs, dayContaining: Self.at(12), calendar: Self.calendar)
            for step in 0..<288 {
                let time = Self.at(0).addingTimeInterval(TimeInterval(step * 300))
                let fromTimeline = CompanionEmotionEngine.emotion(in: timeline, at: time, calendar: Self.calendar)
                let live = Self.emotion(inputs, time)
                #expect(fromTimeline == live, "at \(time) the timeline says \(String(describing: fromTimeline)), the engine \(String(describing: live)): \(inputs)")
            }
        }
    }

    /// After midnight only the clock is known: sleepy until the next wake, then nothing — and a
    /// moment is never read on a later day than its own.
    @Test func timelineCarriesOnlyTheClockAcrossMidnight() {
        let inputs = Self.with { $0.latestJournalTag = .hard; $0.heartGlowUntil = Self.at(12, day: 25) }
        let timeline = CompanionEmotionEngine.timeline(for: inputs, dayContaining: Self.at(12), calendar: Self.calendar)
        let lookup = { (time: Date) in CompanionEmotionEngine.emotion(in: timeline, at: time, calendar: Self.calendar) }
        #expect(lookup(Self.at(22)) == .comforted)
        #expect(lookup(Self.at(2, day: 25)) == .sleepy)
        #expect(lookup(Self.at(8, day: 25)) == nil, "yesterday's comfort leaked into a new day")
        #expect(lookup(Self.at(12, day: 26)) == nil)
        let late = CompanionSleepWindow(bedtimeMinute: 60, wakeMinute: 9 * 60)
        let lateDay = CompanionEmotionEngine.timeline(for: Self.with { $0.sleepWindow = late; $0.latestJournalTag = .hard },
                                                      dayContaining: Self.at(12), calendar: Self.calendar)
        #expect(CompanionEmotionEngine.emotion(in: lateDay, at: Self.at(23, 50), calendar: Self.calendar) == .sad)
        #expect(CompanionEmotionEngine.emotion(in: lateDay, at: Self.at(0, 30, day: 25), calendar: Self.calendar) == nil)
        #expect(CompanionEmotionEngine.emotion(in: lateDay, at: Self.at(1, 30, day: 25), calendar: Self.calendar) == .sleepy)
    }

    /// The widget is built from `widgetSafe` inputs, so the body-signal and petting emotions can
    /// never reach it, and a timeline is bounded.
    @Test func widgetSafeTimelinesCarryOnlyPublishableEmotionsAndStayBounded() {
        for inputs in Self.grid().prefix(4_000) {
            let timeline = CompanionEmotionEngine.timeline(for: inputs.widgetSafe, dayContaining: Self.at(12),
                                                           calendar: Self.calendar)
            #expect(timeline.count <= CompanionEmotionEngine.maxTimelineMoments)
            #expect(timeline.allSatisfy { $0.emotion?.isWidgetPublishable != false }, "\(inputs)")
            #expect(zip(timeline, timeline.dropFirst()).allSatisfy { $0.at < $1.at }, "moments out of order")
        }
    }

    /// A spring-forward day still places bedtime and wake on the wall clock.
    @Test func daylightSavingDaysKeepWallClockTimes() {
        let springForward = Self.at(12, day: 8, month: 3)
        let timeline = CompanionEmotionEngine.timeline(for: Self.base(), dayContaining: springForward, calendar: Self.calendar)
        let hours = timeline.map { Self.calendar.component(.hour, from: $0.at) * 60 + Self.calendar.component(.minute, from: $0.at) }
        #expect(hours.contains(7 * 60), "wake moment missing on the DST day: \(timeline)")
        #expect(hours.contains(22 * 60 + 30), "bedtime moment missing on the DST day: \(timeline)")
        #expect(zip(timeline, timeline.dropFirst()).allSatisfy { $0.at < $1.at })
    }
}
