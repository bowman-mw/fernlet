import SwiftUI
import FernletCrypto
import FernletDomainModel
import FernletFoundation
import FernletLock
import HealthKit
import PrivateHealthStore
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
/// Serves both flows — a fresh log (optionally pre-dated via `targetDate`) and an edit of an
/// existing `CycleDayEntry` — and saves through `PeriodTrackerStore.logEvent`/`editEvent` as a
/// `UserLoggedCycleEvent`. A fresh log must carry something to write; an edit only has to have
/// changed, so unsetting a mis-logged flow chip stays saveable and removes that entry rather than
/// forcing the user onto the day detail's Delete (see ``canSave`` and ``save()``).
///
/// The clinical fields become HealthKit samples; the note and symptoms
/// become a sealed narrative, so the sheet warns up front when no app lock is configured and maps
/// the store's `PeriodLogResult` (saved / narrative buffered until unlock / narrative dropped) to
/// an honest status message before dismissing. A seal that REFUSES —
/// ``ColumnCrypto/SealedColumnStrictSealError/bindingUnavailable``, the only way the narrative half
/// can fail after the clinical half has already landed — gets its own sentence for the same reason,
/// rather than the Foundation default string. Chrome is the 2026-08-21 template: the draft-guard
/// header carries Cancel and the Log/Edit title; Save commits bottom-right.
///
/// **Apple Health is the only home for the clinical fields** (flow, first day of cycle,
/// intermenstrual bleeding, temperature, cervical mucus, ovulation test), and the gateway writes
/// none of them while Fernlet's master Health switch or its Cycle tracking switch is off — both
/// default to off. Owner report 2026-09-29: "When you click save for period tracking, but you're
/// not sharing to HealthKit, it doesn't work." It didn't: the whole log was refused (atomically,
/// note included), and the only sign was a sentence drawn in success green at the very bottom of
/// the scroll, far below the fold, while the sheet stayed open looking untouched. So the sheet now
/// says up front, whenever cycle sharing is off, which fields live in Health and that notes and
/// symptoms still save (``healthNotice``, keyed off the gate's own rule); a refused save says what
/// happened in a sentence of its own (``refusalSentence(for:isEdit:)``); and every outcome is
/// pinned directly above the Save bar (``statusLine``) rather than at the end of the scroll. The
/// refusal itself stays: the sheet never writes to Health, or turns a switch on, on its own.
struct LogPeriodSheet: View {
    var periodStore: PeriodTrackerStore
    private let editingEntry: CycleDayEntry?
    @Environment(FernletLockService.self) private var lockService
    /// The app's single preferences store: the contextual cycle ask turns this kind's Fernlet switch
    /// on through it, or the gateway's write gate would refuse every log the prompt just allowed.
    @Environment(StoragePreferencesStore.self) private var storagePreferencesStore
    @Environment(\.dismiss) private var dismiss
    @State private var authorization = HealthKitAuthorizationViewModel()

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
    /// Set when a write LANDED but not cleanly — the sealed note was buffered until unlock, or
    /// dropped for want of an app lock.
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
    /// worse than the bug it fixes: `PeriodTrackerStore.logEvent` mints a fresh `externalUUID` and
    /// inserts a new sealed narrative every time, so a second commit duplicates the day rather than
    /// amending it. Changing a logged day is what the calendar's Edit is for, and it routes through
    /// `editEvent(replacingEntry:)`.
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
    /// disabled, and the sole exit was the day detail's Delete, which also destroys the sealed note
    /// and every Fernlet-owned HealthKit sample for that day. An emptied edit removes exactly the
    /// entry it is editing (see ``save()``), which is what unsetting the chip asked for.
    private var canSave: Bool { hasLoggableContent || (editingEntry != nil && isDirty) }

    /// Whether the user has emptied an edit out — the tap then removes the entry instead of writing
    /// one, so the bar says so rather than calling a deletion "Save". Requires `isDirty` so the label
    /// only ever changes on a button the user can actually press.
    private var isEmptiedEdit: Bool { editingEntry != nil && !hasLoggableContent && isDirty }

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

    init(periodStore: PeriodTrackerStore, targetDate: Date? = nil, editingEntry: CycleDayEntry? = nil) {
        self.periodStore = periodStore
        self.editingEntry = editingEntry
        // ONE derivation for the entry unit and the read-back unit — see the extension at the top
        // of this file. It seeds an EDIT too, not just a fresh log: the sealed store normalizes
        // every stored reading to Fahrenheit, so re-opening a metric user's day with "97.70" and
        // an F picker would contradict the "°C" the day detail draws for that very sample.
        let entryUnit = PeriodTemperatureUnit.regionDefault
        // Seeded ONCE and reused for both the @State values and the dirty-check baseline — two
        // separate `Date()` calls would make a freshly opened sheet claim to be dirty.
        let seeded = SheetValues(
            eventDate: editingEntry?.date ?? targetDate ?? Date(),
            flowLevel: editingEntry?.flowLevel,
            temperatureText: editingEntry?.basalBodyTemperatureFahrenheit
                .map { LogPeriodSheet.temperatureText(fahrenheit: $0, in: entryUnit) } ?? "",
            mucusQuality: editingEntry?.cervicalMucusQuality,
            ovulationResult: editingEntry?.ovulationTestResult,
            hasIntermenstrualBleeding: editingEntry?.hasIntermenstrualBleeding ?? false,
            isCycleStart: editingEntry?.isCycleStart ?? false,
            note: editingEntry?.narrative?.note ?? "",
            symptoms: Set(editingEntry?.narrative?.symptomFlags ?? []),
            customScales: Dictionary(uniqueKeysWithValues: (editingEntry?.narrative?.customSymptomScales ?? [:]).compactMap { rawValue, scale in
                PeriodSymptom(rawValue: rawValue).map { ($0, scale) }
            })
        )
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

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // Frozen once the entry is written — see ``savedWithCaveat``.
                    Group {
                        lockWarning
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
        .task {
            periodStore.attachLockService(lockService)
            if !authorization.hasRequested(.cycleTracking) {
                await HealthAccessGrant.requestInContext(
                    .cycleTracking,
                    source: "logPeriodSheet",
                    authorization: authorization,
                    preferences: storagePreferencesStore
                )
            }
        }
        // A swipe-down used to throw away a period log with symptoms and a note, with no warning.
        // The guard also renders the pinned template header (Cancel + title); both title branches
        // are authored `LocalizedStringKey` literals.
        .fernletDraftGuard(
            isDirty: isDirty,
            title: editingEntry != nil ? "Edit period" : "Log period"
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

    /// Shown only when notes would be dropped for want of an app lock.
    @ViewBuilder
    private var lockWarning: some View {
        if lockService.state == .notConfigured && hasNarrative {
            Text("Notes are only saved when app lock is on. Set up app lock in Settings to keep them with this cycle.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.terracotta)
                .fernletWrappingText()
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
    /// and the Cycle tracking switch start off), BEFORE the user types anything: which fields need
    /// Health, that notes and symptoms still save without it, and where sharing is turned on.
    ///
    /// Up front rather than only after a refused Save, because the refusal is atomic — the note
    /// typed beside a flow chip is refused with it — and learning that after composing a long note
    /// is the worst time. `.fernletWrappingText()` so no word of it is clipped at larger sizes.
    @ViewBuilder
    private var healthNotice: some View {
        if !sharesCycleDataWithHealth {
            Text("Flow, first day of cycle, intermenstrual bleeding, temperature, cervical mucus and ovulation tests are saved in Apple Health, and Fernlet isn't sharing cycle data with Health right now. Notes and symptoms still save privately in Fernlet. You can turn on sharing in Settings › Health.",
                 comment: "Notice at the top of the period log sheet while Fernlet's cycle sharing with Apple Health is off. The listed fields are the sheet's own field names; Settings › Health is Fernlet's own Settings page.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.terracottaInk)
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

    private var hasNarrative: Bool {
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !symptoms.isEmpty
    }

    /// Seeds the temperature field from an existing day's stored reading, in `unit`.
    ///
    /// `CycleDayEntry.basalBodyTemperatureFahrenheit` hands every stored reading back as Fahrenheit
    /// whatever the user originally typed, so an edit in a Celsius region has to convert before the
    /// field can honestly sit next to a °C picker.
    private static func temperatureText(fahrenheit: Double, in unit: PeriodTemperatureUnit) -> String {
        guard unit == .celsius else { return String(format: "%.2f", fahrenheit) }
        return String(format: "%.2f", (fahrenheit - 32) * 5 / 9)
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
    /// "First day of cycle" is not a sample of its own — HealthKit records it as metadata on the
    /// day's FLOW sample, and ``CycleDayEntry/isCycleStart`` reads it back from there alone — so the
    /// flag with no flow level wrote nothing and still reported `.saved`: the sheet dismissed as if
    /// the day were logged. It is refused here with ``cycleStartProblem(isCycleStart:flowLevel:)``.
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

    /// Why the first-day flag cannot be saved as drafted, or nil when it can: the flag rides on the
    /// flow sample, so it needs a flow level beside it (see ``validatedDraft()``).
    static func cycleStartProblem(isCycleStart: Bool, flowLevel: PeriodFlowLevel?) -> String? {
        guard isCycleStart, flowLevel == nil else { return nil }
        return String(localized: "logPeriod.validation.cycleStartNeedsFlow",
                      defaultValue: "Choose a flow level to mark the first day of your cycle.",
                      comment: "Shown above Save on the period log sheet when 'First day of cycle' is on but no flow level is chosen. The first-day mark is stored with the flow level, so it cannot be saved alone.")
    }

    /// The sentence a refused save shows above the Save bar, in the sheet's own voice.
    ///
    /// The gateway's own text for a closed switch ("…so nothing was saved to Health") implies the
    /// entry was kept somewhere else. It was not: `PeriodTrackerStore` writes the Health half first
    /// and refuses the whole log when it is refused, note and symptoms included, so these sentences
    /// say that nothing was saved, that the entry is still in the sheet, and what would let it save.
    /// A fresh log can also be saved without its Health details, so its sentence says so; an EDIT
    /// is delete-then-rewrite and was refused before anything was deleted, so nothing changed.
    ///
    /// - Parameters:
    ///   - error: What `logEvent` / `editEvent` threw.
    ///   - isEdit: Whether the sheet was editing an existing day.
    /// - Returns: A resolved sentence; any other error falls back to its `localizedDescription`.
    static func refusalSentence(for error: any Error, isEdit: Bool) -> String {
        switch error {
        case HealthKitServiceError.sharingTurnedOff:
            guard !isEdit else {
                return String(localized: "logPeriod.refusal.sharingOff.edit",
                              defaultValue: "Nothing was changed, because Fernlet isn't sharing cycle data with Apple Health, and this day's cycle details are kept there. Your changes are still here. You can turn on sharing in Settings › Health.",
                              comment: "Shown above Save when editing a logged period day is refused because Fernlet's cycle sharing with Apple Health is off. Nothing was deleted or saved.")
            }
            return String(localized: "logPeriod.refusal.sharingOff",
                          defaultValue: "Nothing was saved, because Fernlet isn't sharing cycle data with Apple Health. Your entry is still here. Turn on sharing in Settings › Health, or clear the flow and other Health details to save just your notes and symptoms.",
                          comment: "Shown above Save when a period log is refused because Fernlet's cycle sharing with Apple Health is off. Nothing was saved, including the note. 'Health details' are the fields the notice at the top of the sheet lists.")
        case let healthError as HKError where healthError.code == .errorAuthorizationDenied
            || healthError.code == .errorAuthorizationNotDetermined:
            return String(localized: "logPeriod.refusal.healthDenied",
                          defaultValue: "Nothing was saved, because Apple Health isn't allowing Fernlet to save cycle data. Your entry is still here. You can allow it for Fernlet in the Health app.",
                          comment: "Shown above Save when Apple Health itself refused Fernlet's cycle write (the user denied Fernlet cycle data in the Health app). Nothing was saved.")
        default:
            return error.localizedDescription
        }
    }

    /// Writes the sheet.
    ///
    /// An emptied EDIT is a real outcome, not a no-op: `editEvent` deletes that entry's Fernlet-owned
    /// samples and its sealed narrative and then re-logs an event that carries nothing, so no sample
    /// is written and no narrative is sealed — the day's entry goes away and no other day is touched.
    /// A fresh log can never take that path: `canSave` requires content when `editingEntry` is nil,
    /// so an empty sheet cannot write an empty entry.
    private func save() async {
        // Single-flight: the save bar is disabled while saving, but the entry point states it too so
        // a double invocation can never run two writes for one sheet.
        guard !isSaving else { return }
        // The bar is disabled otherwise; stated here too so the write path carries its own
        // precondition — an empty fresh sheet must never write, and an untouched edit must never
        // delete-and-recreate its day for nothing.
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }
        let basalBodyTemperature: Double?
        switch validatedDraft() {
        case .valid(let temperature):
            basalBodyTemperature = temperature
        case .invalid(let message):
            report(message, kind: .error)
            return
        }
        do {
            let event = UserLoggedCycleEvent(
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
            let result: PeriodLogResult
            if let entry = editingEntry {
                result = try await periodStore.editEvent(event, replacingEntry: entry, unlockedContentKey: lockService.contentKey(for: .privateHub))
            } else {
                result = try await periodStore.logEvent(event, unlockedContentKey: lockService.contentKey(for: .privateHub))
            }
            switch result {
            case .saved:
                // The only clean outcome: everything the user typed is where they expect it, so
                // there is nothing to read and the sheet gets out of the way.
                dismiss()
            // `.success`, not `.status`: on both arms the write LANDED — the caveat is about where
            // the note ended up, not about whether anything was saved. "Your data is safe now" is a
            // different thing to hear than "here is a fact", and these are the batch's only two
            // durable-write announcements on this sheet.
            case .savedWithBufferedNarrative:
                savedWithCaveat = true
                report(String(localized: "Note saved. Unlock to view it on your calendar."),
                       kind: .success)
            case .savedWithDroppedNarrative:
                savedWithCaveat = true
                report(String(localized: "Health event saved. Set up app lock to keep notes with future cycles."),
                       kind: .success)
            }
        } catch ColumnCrypto.SealedColumnStrictSealError.bindingUnavailable {
            // The one seal entry refused: this install's device binding was unreadable at the moment
            // of the write, so the sealed narrative could not be minted. Owner decision D4 made this
            // reachable — the writer used to fall open to an un-domained legacy blob and the save
            // simply succeeded — and `ColumnCrypto.SealedColumnStrictSealError` is `Error, Equatable`
            // only, with no `LocalizedError` anywhere, so the generic catch below both RENDERED and
            // SPOKE Foundation's default: "The operation couldn't be completed", followed by the
            // type's own name and a case number.
            //
            // The sentence has to carry two facts the generic string could not. First, and first for
            // a reason: the note is NOT gone. It is still in this sheet's state, which is the only
            // question worth answering to someone who has just been told a save failed. Second, this
            // refusal can only come from the narrative half, which `logEvent`/`editEvent` reach
            // AFTER the HealthKit write has landed — so a plain "try again" would quietly invite a
            // second copy of the clinical half. It says to look before re-saving instead of naming
            // Apple Health outright, because a note-or-symptoms-only entry writes no sample at all.
            report(String(localized: "This device couldn't encrypt your note just now, so the note wasn't saved. Nothing you typed is lost, but the rest of the entry already saved, so check the day on your calendar before saving again."),
                   kind: .error)
        } catch {
            // Most often Fernlet's cycle sharing being off, which refuses the whole log — see
            // `refusalSentence(for:isEdit:)`. The sheet stays open with everything the user typed.
            report(Self.refusalSentence(for: error, isEdit: editingEntry != nil), kind: .error)
        }
    }

    /// Publishes a save outcome: renders the sentence and speaks it once.
    ///
    /// Every one of these sentences reports something the user did NOT get — a note buffered, a note
    /// dropped, a temperature refused, a write that threw. Rendered as a plain `Text` it reached
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
