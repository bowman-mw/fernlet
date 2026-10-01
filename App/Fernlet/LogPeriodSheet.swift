import SwiftUI
import FernletCrypto
import FernletDomainModel
import FernletFoundation
import FernletLock
import HealthKit
import PrivateHealthStore
import PrivateStoreCore
import HealthKitGateway
import FernletUI

/// App-target region derivation for ``PeriodTemperatureUnit`` — the ONE rule both the entry picker
/// on this sheet and the read-back row on ``CycleDayDetailView`` obey.
///
/// The two sides had each written their own, and the rules disagreed. The picker asked
/// `measurementSystem == .metric`; the detail row asked ``BodyMeasurementEntry/usesImperial``,
/// which is `== .us`. `Locale.MeasurementSystem` has THREE values, so `.uk` fell in the gap: a
/// British user was offered a Fahrenheit picker and read the same reading back in Celsius, on
/// numbers whose entire value is small day-to-day movement. Deriving it here once removes the gap
/// by construction — a reverter has to reintroduce two expressions to reintroduce the bug.
///
/// `.us` (not "not metric") is the test, because this unit is a TEMPERATURE unit: the UK is metric
/// for temperature and imperial only for road distances and pints, so `.uk` belongs on the Celsius
/// side. That also lines this up with `BodyMeasurementEntry.usesImperial`, so a user's weight,
/// height, and basal temperature now agree about which system they are in.
extension PeriodTemperatureUnit {
    /// The unit this device's region reads body temperature in.
    ///
    /// Resolved at each use rather than cached, so changing Region in iOS Settings takes effect
    /// without a relaunch.
    static var regionDefault: PeriodTemperatureUnit {
        Locale.current.measurementSystem == .us ? .fahrenheit : .celsius
    }
}

/// The log/edit sheet for a cycle day: flow level, cycle-start and intermenstrual-bleeding flags,
/// symptoms with intensity steppers, cervical mucus and ovulation-test observations, basal body
/// temperature, and a private note.
///
/// Serves both flows — a fresh log (optionally pre-dated via `targetDate`) and an edit of one sealed
/// `CycleRecord`, seeded losslessly from its blocks — and saves through `PeriodTrackerStore`:
/// `logEvent`, `editRecord` (in place, under the same id), or, for an emptied edit, `deleteRecord`.
/// A fresh log must carry something to write; an edit only has to have changed, so unsetting a
/// mis-logged flow chip stays saveable and removes that entry (see ``canSave`` and ``save()``).
///
/// **Every field saves in Fernlet, whatever the Health switches say** (period-data design 2026-09-30,
/// Option B; owner report 2026-09-29: "When you click save for period tracking, but you're not
/// sharing to HealthKit, it doesn't work"). The entry is sealed into Fernlet's own store while the
/// Private tab is open, or held until it next opens (either passcode mode — nothing is dropped), and
/// only then copied to Apple Health, while cycle sharing is on. So the sheet never refuses for
/// sharing: ``healthNotice`` says up front, while sharing is off, that the entry saves privately and
/// is not copied; and ``present(_:isEdit:)`` maps the store's `PeriodLogOutcome` to an honest
/// sentence — none for a clean save (the sheet dismisses), "it will be on your calendar the next time
/// you open Private" for a held one, and what happened to the Apple Health copy when that half failed
/// or an edit removed Fernlet's older copy. A write that fails throws before anything is saved, and
/// gets its own sentence (``errorSentence(for:)``) with the draft kept. Chrome is the 2026-08-21
/// template: the draft-guard header carries Cancel and the Log/Edit title; Save commits bottom-right.
struct LogPeriodSheet: View {
    var periodStore: PeriodTrackerStore
    /// The sealed record an edit opens, or `nil` for a fresh log.
    private let editingRecord: CycleRecord?
    @Environment(FernletLockService.self) private var lockService
    /// The app's single preferences store: the notice reads the cycle-sharing rule over it, so the
    /// sentence follows the switches live.
    @Environment(StoragePreferencesStore.self) private var storagePreferencesStore
    @Environment(\.dismiss) private var dismiss

    @State private var eventDate: Date
    @State private var flowLevel: PeriodFlowLevel?
    @State private var temperatureText: String
    @State private var temperatureUnit: PeriodTemperatureUnit
    @State private var mucusQuality: CervicalMucusQuality?
    @State private var ovulationResult: OvulationTestResult?
    @State private var hasIntermenstrualBleeding: Bool
    @State private var isCycleStart: Bool
    @State private var note: String
    @State private var symptoms: Set<PeriodSymptom>
    @State private var customScales: [PeriodSymptom: Int]
    @State private var statusMessage: String?
    /// Whether ``statusMessage`` reports something that did NOT happen, so ``statusLine`` draws it
    /// in the error ink rather than the success one. The line used to be moss for every outcome,
    /// which dressed "nothing was saved" in the colour of "saved".
    @State private var statusIsError = false
    @State private var isSaving = false
    /// Set when a write LANDED but not cleanly — the entry is held until Private next opens, its
    /// Apple Health copy failed, or an edit removed Fernlet's older copy from Apple Health.
    ///
    /// The sheet used to show that sentence for 1.2–1.8 s and dismiss itself. It is the one message
    /// telling the user their note was not kept, VoiceOver's focus is somewhere else for the whole
    /// window, and a blind user was structurally guaranteed never to hear it. Stretching the timer
    /// only makes the race less unfair; the sheet now simply stays.
    ///
    /// Staying open raises two hazards, and this flag closes both by FREEZING the sheet: the fields
    /// go `disabled`, so there are no post-write edits for a swipe-down to discard (which is why
    /// `isDirty` may honestly report false and retire the draft guard), and the commit bar becomes a
    /// plain Done, so a second tap cannot write the day again. Re-arming Save instead would be
    /// worse than the bug it fixes: `PeriodTrackerStore.logEvent` mints a fresh record id and seals a
    /// new record every time, so a second commit duplicates the day rather than amending it. Changing
    /// a logged day is what the calendar's Edit is for, and it routes through `editRecord`.
    @State private var savedWithCaveat = false
    /// The field values the sheet opened with, so the dirty check compares against exactly what was
    /// seeded (a fresh log and an edit of an existing day seed very different things).
    private let initialValues: SheetValues

    /// Every user-editable value on this sheet, as one comparable snapshot.
    ///
    /// `nonisolated` because the target's default isolation is `MainActor`, and a MainActor-isolated
    /// `==` cannot satisfy `Equatable`'s nonisolated requirement.
    private nonisolated struct SheetValues: Equatable {
        var eventDate: Date
        var flowLevel: PeriodFlowLevel?
        var temperatureText: String
        var mucusQuality: CervicalMucusQuality?
        var ovulationResult: OvulationTestResult?
        var hasIntermenstrualBleeding: Bool
        var isCycleStart: Bool
        var note: String
        var symptoms: Set<PeriodSymptom>
        var customScales: [PeriodSymptom: Int]
    }

    private var currentValues: SheetValues {
        SheetValues(
            eventDate: eventDate,
            flowLevel: flowLevel,
            temperatureText: temperatureText,
            mucusQuality: mucusQuality,
            ovulationResult: ovulationResult,
            hasIntermenstrualBleeding: hasIntermenstrualBleeding,
            isCycleStart: isCycleStart,
            note: note,
            symptoms: symptoms,
            customScales: customScales
        )
    }

    /// Whether the sheet holds anything a swipe-down would throw away. Nothing once the entry has
    /// been written, because the fields are frozen at the same moment — see ``savedWithCaveat``.
    private var isDirty: Bool { !savedWithCaveat && currentValues != initialValues }

    /// Whether Save is available.
    ///
    /// A fresh log needs something to write. An EDIT needs only a change: a day whose only content
    /// was a flow level had no way back once that chip was unset — gating on content alone left Save
    /// disabled, and the sole exit was the day detail's Delete, which removes every entry on that day.
    /// An emptied edit removes exactly the record it is editing (see ``save()``), which is what
    /// unsetting the chip asked for.
    private var canSave: Bool { hasLoggableContent || (editingRecord != nil && isDirty) }

    /// Whether the user has emptied an edit out — the tap then removes the entry instead of writing
    /// one, so the bar says so rather than calling a deletion "Save". Requires `isDirty` so the label
    /// only ever changes on a button the user can actually press.
    private var isEmptiedEdit: Bool { editingRecord != nil && !hasLoggableContent && isDirty }

    /// Whether there is anything to log at all. Save used to be enabled on an untouched sheet and
    /// dismissed without writing a thing, which reads as "saved" and isn't.
    private var hasLoggableContent: Bool {
        flowLevel != nil
            || isCycleStart
            || hasIntermenstrualBleeding
            || mucusQuality != nil
            || ovulationResult != nil
            || !symptoms.isEmpty
            || !temperatureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(periodStore: PeriodTrackerStore, targetDate: Date? = nil, editingRecord: CycleRecord? = nil) {
        self.periodStore = periodStore
        self.editingRecord = editingRecord
        // ONE derivation for the entry unit and the read-back unit — see the extension at the top
        // of this file. It seeds an EDIT too, not just a fresh log: a reading kept in one unit is
        // shown converted into the picker's, so the field never contradicts the unit beside it.
        let entryUnit = PeriodTemperatureUnit.regionDefault
        // Seeded ONCE and reused for both the @State values and the dirty-check baseline — two
        // separate `Date()` calls would make a freshly opened sheet claim to be dirty. An edit seeds
        // from the record's own blocks (an unknown block seeds empty, and stays unknown if the edit
        // leaves it empty — `PeriodTrackerStore.editRecord`).
        let seeded = Self.seededValues(record: editingRecord, targetDate: targetDate, entryUnit: entryUnit)
        _eventDate = State(initialValue: seeded.eventDate)
        _flowLevel = State(initialValue: seeded.flowLevel)
        _isCycleStart = State(initialValue: seeded.isCycleStart)
        _hasIntermenstrualBleeding = State(initialValue: seeded.hasIntermenstrualBleeding)
        _mucusQuality = State(initialValue: seeded.mucusQuality)
        _ovulationResult = State(initialValue: seeded.ovulationResult)
        _temperatureText = State(initialValue: seeded.temperatureText)
        _temperatureUnit = State(initialValue: entryUnit)
        _note = State(initialValue: seeded.note)
        _symptoms = State(initialValue: seeded.symptoms)
        _customScales = State(initialValue: seeded.customScales)
        self.initialValues = seeded
    }

    /// The values a sheet opens with: the record's blocks for an edit, a blank draft on `targetDate`
    /// (or now) for a fresh log.
    private static func seededValues(record: CycleRecord?, targetDate: Date?, entryUnit: PeriodTemperatureUnit) -> SheetValues {
        let clinical = record?.clinical
        let narrative = record?.narrative
        return SheetValues(
            eventDate: record?.loggedAt ?? targetDate ?? Date(),
            flowLevel: clinical?.flowLevel,
            temperatureText: clinical.flatMap { block in
                block.basalBodyTemperature.map { temperatureText(value: $0, enteredIn: block.temperatureUnit, shownIn: entryUnit) }
            } ?? "",
            mucusQuality: clinical?.cervicalMucusQuality,
            ovulationResult: clinical?.ovulationTestResult,
            hasIntermenstrualBleeding: clinical?.hasIntermenstrualBleeding ?? false,
            isCycleStart: clinical?.isCycleStart ?? false,
            note: narrative?.note ?? "",
            symptoms: Set(narrative?.symptomFlags ?? []),
            customScales: Dictionary(uniqueKeysWithValues: (narrative?.customSymptomScales ?? [:]).compactMap { rawValue, scale in
                PeriodSymptom(rawValue: rawValue).map { ($0, scale) }
            })
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // Frozen once the entry is written — see ``savedWithCaveat``.
                    Group {
                        healthNotice
                        dateField
                        flowLevelField
                        cycleDetailsField
                        symptomsField
                        observationsField
                        temperatureField
                        noteField
                        noteCounter
                    }
                    .disabled(savedWithCaveat)
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            // OUTSIDE the scroll AND the disabled group: the outcome sits beside the button that
            // produced it, and the caveat sentence is the reason the sheet stayed open, so nothing
            // may dim, mute or scroll it away.
            statusLine

            SheetSaveBar(label: saveLabel, disabled: isSaving || !(canSave || savedWithCaveat)) {
                // Once the entry is written the bar is a Done, not a second Save: leaving the sheet
                // open is what lets the caveat be read (and heard), and re-arming the write would
                // let the same tap log the day twice.
                if savedWithCaveat { dismiss() } else { Task { await save() } }
            }
        }
        .background(Color.parchment)
        // No Apple Health prompt here any more (owner question Q4, default "remove it"): cycle sharing
        // is turned on only in Settings › Health. Reinstating the contextual ask is one call to
        // `HealthAccessGrant.requestInContext(.cycleTracking, …)` in this task.
        .task {
            periodStore.attachLockService(lockService)
        }
        // A swipe-down used to throw away a period log with symptoms and a note, with no warning.
        // The guard also renders the pinned template header (Cancel + title); both title branches
        // are authored `LocalizedStringKey` literals.
        .fernletDraftGuard(
            isDirty: isDirty,
            title: editingRecord != nil ? "Edit period" : "Log period"
        ) { dismiss() }
        // Capture FRICTION (never a security control), attached at the sheet TYPE so both
        // presenters (the Cycle page and Home's quick-log tile) are covered by one edit.
        .captureProtected(surface: "logPeriod")
    }

    /// Which day is being logged. Without it the sheet silently logged "today" — a user catching up
    /// on yesterday had to back out, find the day on the calendar, open it, and tap Edit.
    private var dateField: some View {
        SheetField("Date") {
            DatePicker("Date", selection: $eventDate, in: ...Date(), displayedComponents: .date)
                .labelsHidden()
                .tint(Color.moss)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
        }
    }

    /// Whether Fernlet may write this sheet's clinical fields to Apple Health right now — the
    /// gateway's own rule (``HealthKitService/isWriteSharingEnabled(for:in:)``), evaluated over the
    /// app's observable preferences so the notice below follows the switches live and can never
    /// promise a save the write gate will refuse.
    private var sharesCycleDataWithHealth: Bool {
        HealthKitService.isWriteSharingEnabled(for: .cycleTracking, in: storagePreferencesStore.preferences)
    }

    /// Shown whenever cycle sharing with Apple Health is off (the default: both the master switch
    /// and the Cycle tracking switch start off), BEFORE the user types anything: the entry saves
    /// privately in Fernlet, it is not copied to Apple Health, and where to turn that on.
    ///
    /// Since the cutover (period-data design 2026-09-30, §10.4) every field saves in Fernlet with
    /// sharing off — the sheet no longer refuses a flow level — so the notice is a fact, not a warning
    /// of a refusal. `.fernletWrappingText()` so no word of it is clipped at larger sizes. The
    /// identifier is kept, so the UI test still finds it.
    @ViewBuilder
    private var healthNotice: some View {
        if !sharesCycleDataWithHealth {
            Text("Saved privately in Fernlet. Fernlet isn't copying cycle entries to Apple Health. You can turn that on in Settings › Health.",
                 comment: "Notice at the top of the period log sheet while Fernlet's cycle sharing with Apple Health is off. Every field of the entry still saves in Fernlet, encrypted on this iPhone; it is just not copied to Apple Health. Settings › Health is Fernlet's own Settings page.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.mossInk)
                .fernletWrappingText()
                .accessibilityIdentifier("logPeriod.healthNotice")
        }
    }

    private var flowLevelField: some View {
        SheetField("Flow level") {
            FlowLayout(spacing: 8) {
                ForEach(PeriodFlowLevel.allCases) { level in
                    // `displayName` (the app-target fork in CycleTrackerView.swift), not `title`,
                    // which is `rawValue.capitalized` — a storage token wearing paint. The calendar
                    // that READS this value was forked in the same round; leaving the SETTER on
                    // tokens would have shown a French user "Heavy" here and the translation there.
                    //
                    // Tapping the selected chip again clears it (the chip already carries the
                    // `.isSelected` trait, so VoiceOver says which one is on). Without that a flow
                    // chip, once touched, could not be taken back, so a user refused for sharing
                    // had no way to keep just the note and symptoms short of starting over.
                    Button(level.displayName) { flowLevel = flowLevel == level ? nil : level }
                        .buttonStyle(ChipButtonStyle(selected: flowLevel == level))
                }
            }
        }
    }

    private var cycleDetailsField: some View {
        SheetField("Cycle details") {
            VStack(spacing: 0) {
                periodToggle("First day of cycle", isOn: $isCycleStart)
                Divider()
                periodToggle("Intermenstrual bleeding", isOn: $hasIntermenstrualBleeding)
            }
            .padding(.horizontal, 14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
        }
    }

    /// One toggle per symptom, each revealing a 1…10 intensity stepper while it is on.
    private var symptomsField: some View {
        SheetField("Symptoms") {
            VStack(spacing: 0) {
                ForEach(PeriodSymptom.allCases) { symptom in
                    VStack(alignment: .leading, spacing: 8) {
                        periodToggle(symptom.title, isOn: Binding(
                            get: { symptoms.contains(symptom) },
                            set: { isOn in
                                if isOn {
                                    symptoms.insert(symptom)
                                } else {
                                    symptoms.remove(symptom)
                                    customScales[symptom] = nil
                                }
                            }
                        ))

                        if symptoms.contains(symptom) {
                            Stepper(value: Binding(
                                get: { customScales[symptom] ?? 5 },
                                set: { customScales[symptom] = $0 }
                            ), in: 1...10) {
                                Text("Intensity \(customScales[symptom] ?? 5)")
                                    .font(.fernlet(.label))
                                    .foregroundStyle(Color.bark)
                            }
                            .padding(.bottom, 12)
                        }
                    }
                    if symptom != PeriodSymptom.allCases.last {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
        }
    }

    /// Cervical mucus and ovulation test as labeled rows.
    ///
    /// A bare `Picker` outside a `Form` drops its title and renders in the system accent, so this
    /// read as two stacked, unexplained blue "None" menus. Each row now names itself and carries a
    /// moss chip showing the current value.
    private var observationsField: some View {
        SheetField("Observations") {
            VStack(spacing: 0) {
                // `displayName` (the app-target forks in CycleTrackerView.swift), not `title`,
                // which is `rawValue.capitalized` — a storage token wearing paint. Same reason the
                // flow chips above were forked: the calendar day detail that READS these values
                // renders the localized fork, so leaving the SETTER on tokens showed a French user
                // "Egg White" here and the translation there.
                observationRow("Cervical mucus", value: mucusQuality?.displayName ?? noneObservationName) {
                    Button(noneObservationName) { mucusQuality = nil }
                    ForEach(CervicalMucusQuality.allCases) { quality in
                        Button(quality.displayName) { mucusQuality = quality }
                    }
                }
                Divider()
                observationRow("Ovulation test", value: ovulationResult?.displayName ?? noneObservationName) {
                    Button(noneObservationName) { ovulationResult = nil }
                    ForEach(OvulationTestResult.allCases) { result in
                        Button(result.displayName) { ovulationResult = result }
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
            .tint(Color.moss)
        }
    }

    /// The "nothing observed" word for both observation rows.
    ///
    /// Resolved here rather than left as the bare `"None"` literal the value chip used to carry: a
    /// `String` reaches `Text` through the non-localizing `StringProtocol` initializer, so the chip
    /// read English forever while the menu item beside it (a `LocalizedStringKey` literal) did not.
    /// One resolved string now feeds both, so they cannot diverge either.
    private var noneObservationName: String {
        String(localized: "cycle.observation.none", defaultValue: "None",
               comment: "Value shown for a cervical-mucus or ovulation-test row when nothing was observed that day.")
    }

    /// One "label on the left, value chip on the right" observation row.
    ///
    /// `title` is a `LocalizedStringKey`, not a `String`: a `String` parameter reaches `Text` through
    /// the verbatim overload, which silently opts both call sites out of localization with a clean
    /// build — the exact failure mode the localization wall exists to catch, and the reason this
    /// round's other display forks were made. `value` stays a `String` deliberately: it arrives
    /// already resolved from `CycleDayEntry`'s display forks (`mucusQuality?.displayName`) or from
    /// ``noneObservationName``, so it must be rendered verbatim rather than looked up a second time.
    private func observationRow<Options: View>(
        _ title: LocalizedStringKey,
        value: String,
        @ViewBuilder options: () -> Options
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Menu {
                options()
            } label: {
                HStack(spacing: 6) {
                    Text(value)
                        .font(.fernlet(.label))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(Color.moss)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(Color.moss.opacity(0.10), in: Capsule())
                .contentShape(Capsule())
            }
            // `Text(title)` rather than `title`: a `LocalizedStringKey` cannot be interpolated into
            // another `LocalizedStringKey` (the compiler rejects it outright — the interpolation
            // would fall back to a debug description), but a `Text` carries its own lookup. Same
            // idiom, and the same reason, as the widget slot rows in `HomeView`.
            .accessibilityLabel("\(Text(title)), \(value)")
        }
        .padding(.vertical, 8)
    }

    private var temperatureField: some View {
        SheetField("Basal body temperature") {
            HStack(spacing: 10) {
                TextField("Optional", text: $temperatureText)
                    .keyboardType(.decimalPad)
                    .sheetTextInput(font: .fernlet(.label))
                Picker("Unit", selection: $temperatureUnit) {
                    ForEach(PeriodTemperatureUnit.allCases) { unit in
                        Text(unit.symbol).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
            }
        }
    }

    private var noteField: some View {
        SheetField("Note") {
            SheetTextEditor(
                text: Binding(
                    get: { note },
                    set: { note = String($0.prefix(1000)) }
                ),
                placeholder: "Anything important to remember?",
                minHeight: 140
            )
        }
    }

    /// The save bar's word for what the tap will do — "Remove entry" once an edit has been emptied,
    /// because that tap deletes the day's Fernlet-owned samples and sealed note instead of writing.
    /// `LocalizedStringKey`, not `String`: all three words are authored copy, and only this type
    /// extracts them into the string catalog.
    private var saveLabel: LocalizedStringKey {
        if savedWithCaveat { return "Done" }
        if isSaving { return "Saving" }
        return isEmptiedEdit ? "Remove entry" : "Save"
    }

    private var noteCounter: some View {
        Text("\(note.count)/1000")
            .font(.fernlet(.stat))
            .foregroundStyle(Color.slate)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The save outcome (or a validation message) in the sheet's own voice, pinned directly above
    /// the Save bar.
    ///
    /// It used to be the last child of the scroll content, below nine symptom rows and a 140pt note:
    /// for anyone who tapped a flow chip at the top and then Save, hundreds of points off-screen, so
    /// a refused save looked like a button that did nothing. Pinned, it appears beside the button
    /// the user just pressed at every scroll position. Error ink for a refusal, success ink for a
    /// save that landed with a caveat — both the contrast-safe text tokens, not the accents.
    ///
    /// Capped at 200pt: at accessibility text sizes a long refusal would otherwise push the whole
    /// form off the screen, so a sentence taller than that scrolls inside its own strip instead.
    /// ``StatusHeightCap`` rather than `.frame(maxHeight:)`, which grows to the full 200pt and
    /// centres a two-line sentence in dead space.
    @ViewBuilder
    private var statusLine: some View {
        if let statusMessage {
            StatusHeightCap(maxHeight: 200) {
                ViewThatFits(in: .vertical) {
                    statusSentence(statusMessage)
                    ScrollView { statusSentence(statusMessage) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .background(Color.parchment)
        }
    }

    /// One rendering of the outcome sentence — `message` is already resolved, so it is drawn
    /// verbatim rather than looked up a second time.
    private func statusSentence(_ message: String) -> some View {
        Text(message)
            .font(.fernlet(.body))
            .foregroundStyle(statusIsError ? Color.terracottaInk : Color.mossInk)
            .fernletWrappingText()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("logPeriod.status")
    }

    private func periodToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            // Without these the label rendered in system SF, next to DM Sans everywhere else.
            .font(.fernlet(.label))
            .foregroundStyle(Color.bark)
            .tint(Color.moss)
            .padding(.vertical, 12)
    }

    /// Seeds the temperature field from a record's stored reading, converted from the unit it was
    /// entered in to the unit the picker shows, so the field can honestly sit next to the picker.
    static func temperatureText(value: Double, enteredIn stored: PeriodTemperatureUnit, shownIn shown: PeriodTemperatureUnit) -> String {
        guard stored != shown else { return String(format: "%.2f", value) }
        let converted = shown == .celsius ? (value - 32) * 5 / 9 : value * 9 / 5 + 32
        return String(format: "%.2f", converted)
    }

    /// Plausible basal-body-temperature ranges. A value outside them is a typo or a paste, never a
    /// reading, and this sheet's value becomes an `HKQuantitySample` verbatim.
    private static let celsiusRange = 30.0...45.0
    private static let fahrenheitRange = 86.0...113.0

    private var temperatureRange: ClosedRange<Double> {
        temperatureUnit == .celsius ? Self.celsiusRange : Self.fahrenheitRange
    }

    /// Validates the draft before anything is written: the first-day flag, then the typed basal body
    /// temperature.
    ///
    /// "First day of cycle" marks where a PERIOD starts, so it needs a flow level beside it: the
    /// predictions read flow alone, and Apple Health keeps the flag as metadata on the day's flow
    /// sample, so a copy of a flagged day with no flow would lose it. It is refused here with
    /// ``cycleStartProblem(isCycleStart:flowLevel:)``.
    ///
    /// R5: `Double("nan")`, `Double("1e400")` and `-5` all parse (paste or a hardware keyboard) and
    /// would reach HealthKit as a non-finite or absurd clinical sample, so the value is checked here
    /// — nil field is fine, unusable field refuses the save with a message.
    private func validatedDraft() -> DraftValidation {
        if let problem = Self.cycleStartProblem(isCycleStart: isCycleStart, flowLevel: flowLevel) {
            return .invalid(problem)
        }
        let trimmed = temperatureText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .valid(temperature: nil) }
        let range = temperatureRange
        guard let parsed = LocaleTolerantNumber.double(from: trimmed),
              parsed.isFinite, range.contains(parsed) else {
            return .invalid("Enter a temperature between \(Int(range.lowerBound)) and \(Int(range.upperBound)) \(temperatureUnit.symbol), or leave it blank.")
        }
        return .valid(temperature: parsed)
    }

    /// The outcome of validating the draft: the usable temperature (nil when the field is blank), or
    /// the message explaining why the save is refused.
    private enum DraftValidation {
        case valid(temperature: Double?)
        case invalid(String)
    }

    /// Why the first-day flag cannot be saved as drafted, or nil when it can: it marks where a period
    /// starts, so it needs a flow level beside it (see ``validatedDraft()``).
    static func cycleStartProblem(isCycleStart: Bool, flowLevel: PeriodFlowLevel?) -> String? {
        guard isCycleStart, flowLevel == nil else { return nil }
        return String(localized: "logPeriod.validation.cycleStartNeedsFlow",
                      defaultValue: "Choose a flow level to mark the first day of your cycle.",
                      comment: "Shown above Save on the period log sheet when 'First day of cycle' is on but no flow level is chosen. The first-day mark is stored with the flow level, so it cannot be saved alone.")
    }

    /// Writes the sheet.
    ///
    /// An emptied EDIT is a real outcome, not a no-op: it deletes the record being edited (and its
    /// Apple Health copy — none for a record whose clinical block is unknown, whose Health samples are
    /// data this sheet never showed) through `deleteRecord`, so the day's entry goes away and no other
    /// entry is touched. A fresh log can never take that path: `canSave` requires content when
    /// `editingRecord` is nil, so an empty sheet cannot write an empty entry.
    private func save() async {
        // Single-flight: the save bar is disabled while saving, but the entry point states it too so
        // a double invocation can never run two writes for one sheet.
        guard !isSaving else { return }
        // The bar is disabled otherwise; stated here too so the write path carries its own
        // precondition — an empty fresh sheet must never write, and an untouched edit must never
        // rewrite its record for nothing.
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }
        let event: UserLoggedCycleEvent
        switch validatedDraft() {
        case .valid(let temperature):
            event = draftEvent(basalBodyTemperature: temperature)
        case .invalid(let message):
            report(message, kind: .error)
            return
        }
        do {
            try await write(event)
        } catch {
            // Nothing was saved (every throw comes before the entry is kept): the sheet stays open
            // with everything the user typed, and says why.
            report(Self.errorSentence(for: error), kind: .error)
        }
    }

    /// The write itself: a fresh log, an emptied edit (a delete), or an edit in place. An edit needs
    /// the Private tab's key — it is reached only from the calendar, inside the open tab.
    private func write(_ event: UserLoggedCycleEvent) async throws {
        let contentKey = lockService.contentKey(for: .privateHub)
        guard let record = editingRecord else {
            present(try await periodStore.logEvent(event, unlockedContentKey: contentKey), isEdit: false)
            return
        }
        if isEmptiedEdit {
            presentDeletion(try await periodStore.deleteRecord(record))
            return
        }
        guard let contentKey else { throw FernletLockError.locked }
        present(try await periodStore.editRecord(record.id, with: event, unlockedContentKey: contentKey), isEdit: true)
    }

    /// The draft as the event the store writes, with the already-validated temperature.
    private func draftEvent(basalBodyTemperature: Double?) -> UserLoggedCycleEvent {
        UserLoggedCycleEvent(
            date: eventDate,
            flowLevel: flowLevel,
            basalBodyTemperature: basalBodyTemperature,
            temperatureUnit: temperatureUnit,
            cervicalMucusQuality: mucusQuality,
            ovulationTestResult: ovulationResult,
            hasIntermenstrualBleeding: hasIntermenstrualBleeding,
            isCycleStart: isCycleStart,
            note: note,
            symptoms: symptoms,
            customSymptomScales: Dictionary(uniqueKeysWithValues: customScales.map { symptom, value in
                (symptom.rawValue, value)
            })
        )
    }

    /// Maps a save that LANDED to what the sheet does next (§10.4): dismiss when there is nothing to
    /// say, otherwise freeze the sheet (see ``savedWithCaveat``) and say it.
    private func present(_ outcome: PeriodLogOutcome, isEdit: Bool) {
        guard let sentence = Self.outcomeSentence(outcome, isEdit: isEdit, hasPasscode: lockService.isLockConfigured) else {
            dismiss()
            return
        }
        savedWithCaveat = true
        report(sentence.text, kind: sentence.kind)
    }

    /// Maps an emptied edit's delete: gone from Fernlet and Apple Health (or never in Health) dismisses;
    /// Fernlet's copy gone but Apple Health's still there freezes the sheet and says so.
    private func presentDeletion(_ outcome: PeriodDeleteOutcome) {
        guard case .stillInHealth = outcome.healthCopy else {
            dismiss()
            return
        }
        savedWithCaveat = true
        report(Self.stillInHealthSentence, kind: .status)
    }

    /// The sentence a landed save shows, and how it is announced — or `nil` when there is nothing to
    /// say (sealed now, and Apple Health got its copy or was never meant to). The Health half's
    /// failure outranks the held-until-Private line: it is the part the user can act on.
    static func outcomeSentence(
        _ outcome: PeriodLogOutcome,
        isEdit: Bool,
        hasPasscode: Bool
    ) -> (text: String, kind: FernletAnnouncementKind)? {
        switch outcome.healthCopy {
        case .failed(let failure):
            return (healthCopyFailedSentence(failure, isEdit: isEdit), .success)
        case .removedStaleCopy:
            return (removedStaleCopySentence, .status)
        case .notShared, .written:
            break
        }
        guard outcome.storage == .pendingUntilPrivateOpens else { return nil }
        return (pendingSentence(hasPasscode: hasPasscode), .success)
    }

    /// The sentence a save that threw shows above the Save bar — nothing was saved and the draft is
    /// kept. Anything this does not name keeps its own description.
    static func errorSentence(for error: any Error) -> String {
        switch error {
        case is PeriodTrackingHiddenError:
            return String(localized: "logPeriod.error.hidden",
                          defaultValue: "Period tracking was just hidden in Settings, so this entry wasn't saved. Your entry is still here.",
                          comment: "Shown above Save on the period log sheet when cycle tracking was hidden in Settings while the sheet was open, so nothing was saved.")
        case PendingNarrativeBufferError.full:
            return bufferFullSentence
        case PendingNarrativeBufferError.bufferUnopenable:
            return bufferUnopenableSentence
        case PendingNarrativeBufferError.keyUnreadable, ColumnCrypto.SealedColumnStrictSealError.bindingUnavailable:
            return notEncryptedSentence
        case CycleRecordRepositoryError.storeFull:
            return String(localized: "logPeriod.error.storeFull",
                          defaultValue: "Fernlet's cycle history is full on this iPhone, so this entry wasn't saved.",
                          comment: "Shown above Save on the period log sheet when the cycle history already holds as many entries as Fernlet keeps (20,000), so nothing was saved.")
        case FernletLockError.locked:
            return String(localized: "logPeriod.error.privateClosed",
                          defaultValue: "Private closed before this could be saved, so nothing was changed. Open Private, then save again.",
                          comment: "Shown above Save when an edit of a cycle day could not be saved because the Private tab closed while the sheet was open. 'Private' is the tab's name.")
        default:
            return error.localizedDescription
        }
    }

    /// Held until the Private tab next opens (either passcode mode): the word is the tab's own button.
    static func pendingSentence(hasPasscode: Bool) -> String {
        hasPasscode
            ? String(localized: "logPeriod.saved.pending.passcode",
                     defaultValue: "Saved. It will be on your calendar the next time you unlock Private.",
                     comment: "Shown on the period log sheet after a save while the Private tab was closed and an app passcode is set: the entry is kept, encrypted, and appears on the cycle calendar the next time the user unlocks the tab.")
            : String(localized: "logPeriod.saved.pending.noPasscode",
                     defaultValue: "Saved. It will be on your calendar the next time you open Private.",
                     comment: "Shown on the period log sheet after a save while the Private tab was closed and no app passcode is set: the entry is kept, encrypted, and appears on the cycle calendar the next time the user opens the tab.")
    }

    /// The entry saved in Fernlet; its Apple Health copy did not — a lead sentence for a log or an
    /// edit, then the reason, each a whole sentence.
    static func healthCopyFailedSentence(_ failure: PeriodLogOutcome.HealthCopyFailure, isEdit: Bool) -> String {
        let lead = isEdit
            ? String(localized: "logPeriod.saved.healthCopyNotUpdated",
                     defaultValue: "Saved in Fernlet, but Apple Health's copy of this day couldn't be updated.",
                     comment: "Shown after an edit of a cycle day saved in Fernlet but its copy in Apple Health could not be changed. Followed by the reason.")
            : String(localized: "logPeriod.saved.healthCopyFailed",
                     defaultValue: "Saved in Fernlet, but Apple Health didn't get a copy.",
                     comment: "Shown after a cycle entry saved in Fernlet but its copy to Apple Health failed. Followed by the reason.")
        return lead + " " + healthCopyReason(failure)
    }

    /// Why an Apple Health copy failed, as a whole sentence.
    private static func healthCopyReason(_ failure: PeriodLogOutcome.HealthCopyFailure) -> String {
        switch failure {
        case .healthDenied:
            String(localized: "logPeriod.saved.healthReason.denied",
                   defaultValue: "The Health app isn't letting Fernlet save cycle data. You can allow it there.",
                   comment: "Reason after 'Apple Health didn't get a copy': the user turned Fernlet's cycle access off in the Health app.")
        case .healthUnavailable:
            String(localized: "logPeriod.saved.healthReason.unavailable",
                   defaultValue: "Apple Health isn't available on this iPhone.",
                   comment: "Reason after 'Apple Health didn't get a copy': this device has no Apple Health.")
        case .other:
            String(localized: "logPeriod.saved.healthReason.other",
                   defaultValue: "Something went wrong there. Editing this day later will try again.",
                   comment: "Reason after 'Apple Health didn't get a copy' for an unexpected error. Saving an edit of the day writes the copy again.")
        }
    }

    /// Owner question Q1: cycle sharing is off and an edit removed Fernlet's older copy of the day from
    /// Apple Health — said only when a sample was really deleted.
    static var removedStaleCopySentence: String {
        String(localized: "logPeriod.saved.removedStaleCopy",
               defaultValue: "Saved. Cycle sharing is off, so Fernlet removed its older copy of this day from Apple Health.",
               comment: "Shown after an edit of a cycle day while Fernlet's cycle sharing with Apple Health is off, when Fernlet deleted the copy it had made of that day earlier.")
    }

    /// Fernlet's copy is gone, Apple Health's is not (§10.4) — the delete outcome `.stillInHealth`.
    static var stillInHealthSentence: String {
        String(localized: "logPeriod.removed.stillInHealth",
               defaultValue: "Removed from Fernlet. Apple Health still has Fernlet's copy of this day because Fernlet can't change it right now. You can delete it in the Health app, or here later.",
               comment: "Shown after a cycle day was deleted in Fernlet but Fernlet's copy in Apple Health could not be removed (for example, Fernlet's access was turned off in the Health app). 'Here later' means from the day on Fernlet's calendar.")
    }

    /// The entry could not be encrypted this instant (the install binding or the pending buffer's key
    /// would not answer). Nothing was saved anywhere — the record is kept FIRST, before any Apple
    /// Health copy — and the draft is still in the sheet.
    static var notEncryptedSentence: String {
        String(localized: "logPeriod.error.notEncrypted",
               defaultValue: "This iPhone couldn't encrypt your entry just now, so nothing was saved. Your entry is still here. Try again in a moment.",
               comment: "Shown above Save on the period log sheet when the entry could not be encrypted this instant. Nothing was saved, and nothing went to Apple Health.")
    }

    /// The pending buffer holds entries whose key is gone, so nothing more can be added to it until
    /// the Private tab's "can't be opened" card has dealt with them (§6.5, §10.4).
    static var bufferUnopenableSentence: String {
        String(localized: "logPeriod.error.bufferUnopenable.v2",
               defaultValue: "Fernlet can't add to the entries it's holding for Private, so this entry wasn't saved. Your entry is still here. Open Private to sort this out.",
               comment: "Shown above Save on the period log sheet when the entries Fernlet holds until Private next opens were sealed under a key that no longer exists, so a new one cannot join them. Opening the Private tab shows what can't be opened and offers to remove it. 'Private' is the tab's name.")
    }

    /// The pending buffer is at its cap, so this entry was not added — nothing it holds was dropped to
    /// make room (§6.5, §10.4).
    static var bufferFullSentence: String {
        String(localized: "logPeriod.error.bufferFull.v2",
               defaultValue: "Fernlet is holding your recent entries until you next open Private, so this one wasn't saved. Your entry is still here. Open Private once, then save this again.",
               comment: "Shown above Save on the period log sheet when the entries Fernlet holds until Private next opens have reached their limit. Opening the Private tab files them and makes room. 'Private' is the tab's name.")
    }

    /// Publishes a save outcome: renders the sentence and speaks it once.
    ///
    /// Every one of these sentences reports something the user did not get cleanly — an entry held
    /// until Private opens, an Apple Health copy that failed, a temperature refused, a write that
    /// threw. Rendered as a plain `Text` it reached
    /// only people looking at the sheet, which contradicts the project's nothing-silent invariant
    /// for exactly the users least able to check.
    ///
    /// **Privacy:** the outcome sentence and nothing else. An announcement is audible across the
    /// room, and the note this sheet seals is the reason the whole surface is behind an app lock.
    ///
    /// - Parameters:
    ///   - message: The already-localized outcome sentence — never the note itself.
    ///   - kind: `.error` when nothing was written at all; `.status` (the default) for a save that
    ///     landed with a caveat the user still has to read.
    private func report(_ message: String, kind: FernletAnnouncementKind = .status) {
        statusMessage = message
        statusIsError = kind == .error
        FernletAnnouncer.system.announce(kind, resolved: message)
    }
}

/// Sizes its one child to the child's OWN height, never taller than `maxHeight` — the cap on
/// ``LogPeriodSheet``'s pinned outcome line.
///
/// `.frame(maxHeight:)` cannot do this: a flexible frame grows to the height it is offered (up to
/// the cap), so a two-line sentence sat centred in a 200pt box, taking that space from the form
/// above it. This proposes at most `maxHeight` to the child and reports what the child chose, so a
/// short sentence costs its own lines and only a taller one is held to the cap (where the sheet's
/// `ViewThatFits` swaps in a scrolling copy).
private struct StatusHeightCap: Layout {
    /// The tallest the child may be.
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let height = min(proposal.height ?? maxHeight, maxHeight)
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: height))
        return CGSize(width: size.width, height: min(size.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        child.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
