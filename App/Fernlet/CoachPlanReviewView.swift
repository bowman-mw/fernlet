//
//  CoachPlanReviewView.swift
//  Fernlet
//
//  The review gate for an imported coach plan (spec §F3 step 2-4): paste, then see exactly what
//  would be written before anything is.
//
//  This screen is the whole security story of the manual exchange. The plan arrives unsigned, so
//  nothing here may apply silently: blocking problems disable accept outright, safety conflicts are
//  struck or kept one by one, new exercises are named before they join the user's list, and a
//  collision with existing planned days is an explicit choice rather than a default. When this
//  becomes the signed coach-mesh transport, the verification chain changes and THIS SCREEN DOES NOT
//  — which is the point of putting the gate here rather than in the transport.
//

import SwiftUI
import FernletDomainModel
import FernletFoundation
import FernletUI

/// Reviews a decoded coach plan and, on explicit acceptance, materializes it into planned workouts.
///
/// Owns the mutable review decisions (start date, struck exercises, collision policy) and re-derives
/// the ``CoachPlanImportReview`` whenever the start date changes, because the collision set depends
/// on it.
struct CoachPlanReviewView: View {
    var store: FernletStore
    let plan: CoachPlan
    /// Called with the applied result so the presenting screen can show a confirmation.
    var onImported: (CoachPlanImportResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var startDate: Date = .now
    @State private var struckKeys: Set<String> = []
    @State private var collisionPolicy: CoachPlanCollisionPolicy = .keepBoth
    @State private var expandedDays: Set<Int> = []
    @State private var applyFailed = false

    /// The reviewed plan, held in state rather than recomputed in `body`.
    ///
    /// It is a function of the START DATE (the collision set depends on where the plan lands), so it
    /// is refreshed on appear and whenever the date moves — but NOT on every render, because
    /// reviewing walks every logged day and the whole catalog, and striking a single exercise
    /// would otherwise re-scan all of it.
    @State private var review: CoachPlanImportReview?

    private var startDayKey: String { FernletDate.dayKey(for: startDate) }

    private func refreshReview() {
        review = store.reviewCoachPlan(plan, startingOn: startDayKey)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let review {
                    content(review)
                } else {
                    // Alone on the screen with no text beside it, so this one gets a real label
                    // rather than being hidden — hiding it would leave the sheet empty to
                    // VoiceOver, which reads as "the plan failed to load".
                    ProgressView().padding(40)
                        .accessibilityLabel("Preparing the plan review")
                }
            }
            .background((look?.paper ?? Color.parchment).ignoresSafeArea())
            // World build (`b3-coach-review`): Cancel top left and the title in the sheet.
            .fernletSheetToolbar(title: "Review plan", onCancel: { dismiss() })
            .onAppear { refreshReview() }
            .onChange(of: startDayKey) { _, _ in refreshReview() }
            .alert("Couldn't add this plan", isPresented: $applyFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Nothing was changed. Please try pasting the plan again.")
            }
        }
    }

    private func content(_ review: CoachPlanImportReview) -> some View {
        VStack(alignment: .leading, spacing: FernletMetrics.spaceLg) {
            header(review)
            if !review.blockers.isEmpty { blockersCard(review) }
            // Both the start picker and the day list describe NEW days. An edits-only plan has none,
            // and showing "Day 1 lands here" over an empty plan list invites the user to set a start
            // date that governs nothing — edits land on the days their targets already occupy.
            if !plan.days.isEmpty { startCard }
            if !review.resolvedEdits.isEmpty { changesCard(review) }
            if !review.collidingDayKeys.isEmpty { collisionCard(review) }
            if !review.safetyFlags.isEmpty { safetyCard(review) }
            if !review.newExercises.isEmpty { newExercisesCard(review) }
            if !review.advisories.isEmpty { advisoriesCard(review) }
            if !plan.days.isEmpty { daysCard(review) }
            acceptSection(review)
        }
        .padding(20)
    }

    // MARK: - Sections

    private func header(_ review: CoachPlanImportReview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if plan.title.isEmpty { Text("Workout plan") } else { Text(verbatim: plan.title) }
            }
                .font(.fernlet(.header))
                .foregroundStyle(textInk)
            Text(Self.subtitle(for: plan, review: review))
                .font(.fernlet(.labelSmall))
                .foregroundStyle(dimInk)
            if let notes = plan.notes, !notes.isEmpty {
                Text(notes)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(dimInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // No trust badge and no verified-sender line: this plan was pasted, so Fernlet knows
            // nothing about who wrote it. Saying so is more honest than showing a name as if it
            // had been checked. World build: a framed terracotta notice (`b3-coach-review`).
            if look != nil {
                FernletNotice("Pasted in by you — Fernlet can't check who wrote this, so read it before you accept.",
                              tone: .warn) {
                    WorldSpriteView(sprite: WorldSprites.flag, scale: 2)
                }
                .padding(.top, 4)
            } else {
                Text("Pasted in by you — Fernlet can't check who wrote this, so read it before you accept.")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(dimInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    /// World build (`b3-coach-review`): the sheet's paper, framed cards and the warning notice.
    @Environment(\.fernletFramedLook) private var look
    /// The quiet ink: the look's dim under the World look (`b3-coach-review`), today's slate without it.
    private var dimInk: Color { look?.dim ?? Color.slate }
    /// The text ink: the look's text under the World look, today's bark without it.
    private var textInk: Color { look?.text ?? Color.bark }

    /// The one-line description under the title.
    ///
    /// Built from what the plan actually does rather than from `days` alone: an edits-only plan has
    /// no days and no sessions, and "0 days · 0 sessions" reads like a broken import when in fact it
    /// is a perfectly good set of changes.
    ///
    /// Each item is its own key, joined with " · " like every other caption row: the counts are
    /// plural-ruled count phrases (the English "s" used to be spliced into the key), so "1 days"
    /// cannot happen in any language.
    private static func subtitle(for plan: CoachPlan, review: CoachPlanImportReview) -> String {
        var parts: [String] = []
        if !plan.days.isEmpty {
            parts.append(String(localized: "coachPlan.count.days", defaultValue: "\(plan.days.count) days",
                                comment: "Coach plan review subtitle item: how many days the plan covers, e.g. '7 days'. Needs a plural variation."))
            if plan.sessionCount > 0 {
                parts.append(String(localized: "coachPlan.count.sessions", defaultValue: "\(plan.sessionCount) sessions",
                                    comment: "Coach plan review subtitle item: how many workout sessions the plan holds. Needs a plural variation."))
            }
        }
        let changes = review.resolvedEdits.count
        if changes > 0 {
            parts.append(String(localized: "coachPlan.count.changes", defaultValue: "\(changes) changes",
                                comment: "Coach plan review subtitle item: how many already-planned workouts the plan changes. Needs a plural variation."))
        }
        if parts.isEmpty {
            parts.append(String(localized: "coachPlan.review.nothingToAdd", defaultValue: "Nothing to add",
                                comment: "Coach plan review subtitle when the plan adds no days and changes nothing"))
        }
        if !plan.coachDisplayName.isEmpty {
            parts.append(String(localized: "coachPlan.review.fromAuthor", defaultValue: "from \(plan.coachDisplayName)",
                                comment: "Coach plan review subtitle item: who wrote the plan, e.g. 'from Claude'. Argument: the name the plan gives its author."))
        }
        return parts.joined(separator: " · ")
    }

    private func blockersCard(_ review: CoachPlanImportReview) -> some View {
        card {
            cardTitle("Can't add this plan yet")
            ForEach(review.blockers) { issue in
                bullet(issue.detail, tint: Color.terracotta)
            }
            Text("Ask for a corrected plan and paste it again.")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(dimInk)
        }
    }

    private var startCard: some View {
        card {
            cardTitle("Start on")
            DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                .datePickerStyle(.compact)
                .labelsHidden()
                .tint(Color.moss)
            Text("Day 1 lands here; the rest follow day by day.")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(dimInk)
        }
        .accessibilityIdentifier("coachPlan.start")
    }

    /// Changes to workouts already on the calendar, as a before/after list.
    ///
    /// No per-item opt-out (owner decision): this is one accept-all summary, and the Add button
    /// below it is the single gate. The safety toggles further down are NOT part of that — those
    /// are about the user's own avoid-list, which is a different question from "do I want the
    /// coach's changes".
    private func changesCard(_ review: CoachPlanImportReview) -> some View {
        card {
            cardTitle("Changes to workouts you'd planned")
            Text(Self.changesSummary(review.resolvedEdits))
                .font(.fernlet(.bodySmall))
                .foregroundStyle(dimInk)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(review.resolvedEdits) { resolved in
                editRow(resolved)
            }
        }
        .accessibilityIdentifier("coachPlan.changes")
    }

    /// One proposed change, showing ONLY the parts that actually differ.
    ///
    /// A notes-only adjust used to render the same exercise list twice with an arrow between them,
    /// which reads as "something changed here, work out what" — the opposite of a diff's job. The
    /// exercise before/after appears only when the prescription really moved; a rename and a new note
    /// get their own lines.
    @ViewBuilder
    private func editRow(_ resolved: ResolvedCoachPlanEdit) -> some View {
        let after = resolved.after
        let exercisesChanged = after.map { $0.exerciseLines != resolved.before.exerciseLines } ?? false
        let renamed = after.map { $0.name != resolved.before.name } ?? false
        let noteChanged = after.map { $0.notes != resolved.before.notes } ?? false

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(Self.dateLabel(resolved.dayKey))
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(dimInk)
                Text(Self.actionLabel(resolved.action))
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(resolved.action == .delete ? Color.terracotta : Color.moss)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background((resolved.action == .delete ? Color.terracotta : Color.moss).opacity(0.12),
                                in: Capsule())
                Spacer(minLength: 0)
            }

            if resolved.action == .delete {
                beforeAfterBlock(title: resolved.before.displayedName, lines: resolved.before.displayedExerciseLines,
                                 struck: true, tint: Color.slate)
            } else if exercisesChanged {
                beforeAfterBlock(title: resolved.before.displayedName, lines: resolved.before.displayedExerciseLines,
                                 struck: false, tint: Color.slate)
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(dimInk)
                beforeAfterBlock(title: after?.displayedName ?? resolved.before.displayedName,
                                 lines: after?.displayedExerciseLines ?? [], struck: false, tint: Color.bark)
            } else {
                // Nothing moved in the prescription — name the workout once and list what did change.
                Text(resolved.before.displayedName)
                    .font(.fernlet(.label))
                    .foregroundStyle(textInk)
                if renamed, let after {
                    changeLine("Renamed to \"\(after.displayedName)\"")
                }
                if !exercisesChanged && !renamed && !noteChanged {
                    changeLine("Same exercises, updated details")
                }
            }

            if noteChanged, resolved.action != .delete, let after {
                if after.notes.isEmpty {
                    changeLine("Note cleared")
                } else {
                    changeLine("Note: \(Self.lastNoteLine(after.notes))")
                }
            }
            FernletRowDivider()
        }
    }

    /// A single "what changed" line under a workout name. `LocalizedStringKey`, not `String`: every
    /// caller passes a literal, and a `String` parameter would keep all four out of the catalog.
    private func changeLine(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.fernlet(.bodySmall))
            .foregroundStyle(textInk)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The coach's own note, without the provenance stamp the importer appends.
    ///
    /// The stamp is added on apply, so showing the whole note here would preview a line the user
    /// didn't write and the coach didn't send. A stamp is matched by its exact shape
    /// (``CoachPlanNoteStamp/isStamp(_:)``): the bare "Day " prefix this used to strip also hid a
    /// note of the user's own such as "Day off, knees sore".
    static func lastNoteLine(_ notes: String) -> String {
        notes
            .components(separatedBy: .newlines)
            .filter { !CoachPlanNoteStamp.isStamp($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: " ")
    }

    private func beforeAfterBlock(title: String, lines: [String], struck: Bool, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.fernlet(.label))
                .foregroundStyle(tint)
                .strikethrough(struck)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(tint.opacity(struck ? 0.7 : 1))
                    .strikethrough(struck)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "2 replaced, 1 adjusted, 1 removed" — counted by action so the sentence matches the list.
    ///
    /// Each count is a plural-ruled count phrase (a translator agrees the participle with the
    /// count), joined with ", " (the house list separator), inside one sentence key.
    private static func changesSummary(_ edits: [ResolvedCoachPlanEdit]) -> String {
        let replaced = edits.filter { $0.action == .replace }.count
        let adjusted = edits.filter { $0.action == .adjust }.count
        let removed = edits.filter { $0.action == .delete }.count
        var parts: [String] = []
        if replaced > 0 {
            parts.append(String(localized: "coachPlan.count.replaced", defaultValue: "\(replaced) replaced",
                                comment: "Coach plan review: how many planned workouts the plan replaces, e.g. '2 replaced'. Needs a plural variation."))
        }
        if adjusted > 0 {
            parts.append(String(localized: "coachPlan.count.adjusted", defaultValue: "\(adjusted) adjusted",
                                comment: "Coach plan review: how many planned workouts the plan adjusts, e.g. '1 adjusted'. Needs a plural variation."))
        }
        if removed > 0 {
            parts.append(String(localized: "coachPlan.count.removed", defaultValue: "\(removed) removed",
                                comment: "Coach plan review: how many planned workouts the plan removes, e.g. '1 removed'. Needs a plural variation."))
        }
        let list = parts.joined(separator: ", ")
        return String(localized: "coachPlan.review.changesSummary",
                      defaultValue: "\(list). Workouts you've already logged are never touched.",
                      comment: "Coach plan review, the changes card. Argument: the counts by kind, e.g. '2 replaced, 1 adjusted'.")
    }

    private static func actionLabel(_ action: CoachPlanEditAction) -> String {
        switch action {
        case .adjust: String(localized: "coachPlan.review.action.adjusted", defaultValue: "Adjusted",
                             comment: "Coach plan review: tag on a planned workout the plan adjusts")
        case .replace: String(localized: "coachPlan.review.action.replaced", defaultValue: "Replaced",
                              comment: "Coach plan review: tag on a planned workout the plan replaces")
        case .delete: String(localized: "coachPlan.review.action.removed", defaultValue: "Removed",
                             comment: "Coach plan review: tag on a planned workout the plan removes")
        }
    }

    private static func dateLabel(_ dayKey: String) -> String {
        FernletDate.date(fromDayKey: dayKey)?
            .formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) ?? dayKey
    }

    private func collisionCard(_ review: CoachPlanImportReview) -> some View {
        card {
            cardTitle("You already have workouts planned")
            Text(Self.collisionBody(dayCount: review.collidingDayKeys.count))
                .font(.fernlet(.bodySmall))
                .foregroundStyle(dimInk)
                .fixedSize(horizontal: false, vertical: true)
            Picker("What to do", selection: $collisionPolicy) {
                Text("Keep both").tag(CoachPlanCollisionPolicy.keepBoth)
                Text("Replace planned").tag(CoachPlanCollisionPolicy.replace)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("coachPlan.collision")
        }
    }

    private func safetyCard(_ review: CoachPlanImportReview) -> some View {
        card {
            cardTitle("Check these against your limits")
            Text("These don't match what you told Fernlet you avoid or have. Turn one off to leave it out.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(dimInk)
                .fixedSize(horizontal: false, vertical: true)
            // Grouped by exercise: the same lift flagged on days 1, 8, and 15 is one decision, not
            // three, and striking it strikes it everywhere.
            ForEach(groupedFlags(review), id: \.key) { group in
                Toggle(isOn: Binding(
                    get: { !struckKeys.contains(group.key) },
                    set: { keep in
                        if keep { struckKeys.remove(group.key) } else { struckKeys.insert(group.key) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name)
                            .font(.fernlet(.body))
                            .foregroundStyle(textInk)
                        Text(group.reason)
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.terracotta)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(group.dayLabel)
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(dimInk)
                    }
                }
                .tint(Color.moss)
                .toggleStyle(FernletFramedToggleStyle())
            }
        }
    }

    private func newExercisesCard(_ review: CoachPlanImportReview) -> some View {
        card {
            cardTitle("New exercises")
            Text(Self.newExercisesBody(count: review.newExercises.count))
                .font(.fernlet(.bodySmall))
                .foregroundStyle(dimInk)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(review.newExercises, id: \.name) { target in
                bullet("\(target.name) — \(target.muscles.prefix(3).joined(separator: ", ")) · \(target.equipment.displayName)")
            }
        }
    }

    private func advisoriesCard(_ review: CoachPlanImportReview) -> some View {
        card {
            cardTitle("Fernlet adjusted a few things")
            ForEach(review.advisories) { issue in
                bullet(issue.detail, tint: Color.slate)
            }
        }
    }

    private func daysCard(_ review: CoachPlanImportReview) -> some View {
        card {
            cardTitle("The plan")
            ForEach(plan.days.sorted(by: { $0.dayIndex < $1.dayIndex }), id: \.dayIndex) { day in
                dayRow(day)
            }
        }
    }

    @ViewBuilder
    private func dayRow(_ day: CoachPlanDay) -> some View {
        let key = FernletStore.dayKey(startingOn: startDayKey, offsetBy: day.dayIndex - 1)
        let dateLabel = key.flatMap(FernletDate.date(fromDayKey:))?
            .formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) ?? ""

        VStack(alignment: .leading, spacing: 6) {
            // World build (`b3-coach-review`): a dotted rule above each day; today's hairline below it.
            if look != nil { FernletDottedRule() }
            Button {
                if expandedDays.contains(day.dayIndex) {
                    expandedDays.remove(day.dayIndex)
                } else {
                    expandedDays.insert(day.dayIndex)
                }
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Self.dayTitle(day)
                            .font(look == nil ? .fernlet(.label) : MoveFont.rowTitle)
                            .foregroundStyle(textInk)
                        Text(dateLabel)
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(dimInk)
                    }
                    Spacer(minLength: 0)
                    if !day.isRestDay && !day.sessions.isEmpty {
                        if look != nil {
                            FernletIcon(expandedDays.contains(day.dayIndex) ? .chevronDown : .chevron)
                        } else {
                            Image(systemName: expandedDays.contains(day.dayIndex) ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(dimInk)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(day.isRestDay || day.sessions.isEmpty)

            if expandedDays.contains(day.dayIndex) { daySessions(day) }
            if look == nil { FernletRowDivider() }
        }
    }

    /// A day's sessions when its row is open: each session's title, its exercise lines (struck ones
    /// crossed out) and its conditioning note.
    private func daySessions(_ day: CoachPlanDay) -> some View {
        ForEach(Array(day.sessions.enumerated()), id: \.offset) { _, session in
            VStack(alignment: .leading, spacing: 3) {
                if !session.title.isEmpty {
                    Text(session.title)
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(dimInk)
                }
                ForEach(Array(session.exercises.enumerated()), id: \.offset) { _, exercise in
                    let struck = struckKeys.contains(CoachPlan.normalizedName(exercise.name))
                    Text(exercise.line)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(struck ? dimInk : textInk)
                        .strikethrough(struck)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let conditioning = session.conditioning, !conditioning.isEmpty {
                    Text(conditioning)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(textInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 10)
        }
    }

    private func acceptSection(_ review: CoachPlanImportReview) -> some View {
        VStack(spacing: 8) {
            Button {
                if let result = store.applyCoachPlan(review, startingOn: startDayKey,
                                                     struckExerciseKeys: struckKeys,
                                                     collisionPolicy: collisionPolicy) {
                    onImported(result)
                    dismiss()
                } else {
                    applyFailed = true
                }
            } label: {
                Text("Add to my plan").frame(maxWidth: .infinity)
            }
            // The framed primary under the World look (faded while the plan can't be added).
            .buttonStyle(ActionPillButtonStyle(.primary))
            .disabled(!review.isImportable)
            .accessibilityIdentifier("coachPlan.accept")

            Text("Nothing is added until you tap this. You can edit or delete any day afterwards.")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(dimInk)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Helpers

    /// One row per flagged exercise, listing every day it appears on.
    private func groupedFlags(_ review: CoachPlanImportReview)
    -> [(key: String, name: String, reason: String, dayLabel: String)] {
        var order: [String] = []
        var byKey: [String: [CoachPlanSafetyFlag]] = [:]
        for flag in review.safetyFlags {
            if byKey[flag.exerciseKey] == nil { order.append(flag.exerciseKey) }
            byKey[flag.exerciseKey, default: []].append(flag)
        }
        return order.compactMap { key in
            guard let flags = byKey[key], let first = flags.first else { return nil }
            let days = flags.map(\.dayIndex).sorted()
            return (key: key, name: first.exerciseName, reason: first.reason, dayLabel: Self.flagDayLabel(days))
        }
    }

    /// "Day 3", or "Days 1, 8, 15" for an exercise flagged on several days: two keys rather than
    /// "Days " spliced in front of the numbers. Day 0 is an edit's flag, which has no plan day.
    static func flagDayLabel(_ days: [Int]) -> String {
        guard days.count > 1 else {
            return String(localized: "coachPlan.review.flagDay", defaultValue: "Day \(days.first ?? 0)",
                          comment: "Coach plan review: the plan day a flagged exercise is on, e.g. 'Day 3'")
        }
        let list = days.map { $0.formatted() }.joined(separator: ", ")
        return String(localized: "coachPlan.review.flagDays", defaultValue: "Days \(list)",
                      comment: "Coach plan review: the plan days a flagged exercise is on. Argument: the day numbers, e.g. '1, 8, 15'.")
    }

    /// A plan day's heading: "Day 2 · Upper", or "Day 2 · Rest" / "Day 2 · Workout" for an untitled
    /// day. Three whole keys rather than an English word spliced into the line.
    static func dayTitle(_ day: CoachPlanDay) -> Text {
        guard day.title.isEmpty else { return Text("Day \(day.dayIndex) · \(day.title)") }
        return day.isRestDay ? Text("Day \(day.dayIndex) · Rest") : Text("Day \(day.dayIndex) · Workout")
    }

    /// The collision card's sentence, plural-ruled so one day reads "1 day … already has".
    static func collisionBody(dayCount: Int) -> String {
        String(localized: "coachPlan.review.collisionBody",
               defaultValue: "\(dayCount) days in this range already have planned workouts. Workouts you've already logged are never touched.",
               comment: "Coach plan review: some of the plan's days already have planned workouts. Argument: how many days. Needs a plural variation (English: '1 day … already has').")
    }

    /// The new-exercises card's sentence, plural-ruled so the pronoun agrees ("check it" / "check them").
    static func newExercisesBody(count: Int) -> String {
        String(localized: "coachPlan.review.newExercisesBody",
               defaultValue: "\(count) exercises will be added to your exercise list, so Fernlet can suggest and check them later.",
               comment: "Coach plan review: the plan defines exercises Fernlet doesn't have. Argument: how many. Needs a plural variation (English: '1 exercise … check it later').")
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .modifier(MoveInsetCardFrame(cornerRadius: look == nil ? FernletMetrics.radiusMd : FernletFramedLook.cardRadius))
    }

    /// A card's caption. `LocalizedStringKey`: every caller passes a literal, which a `String`
    /// parameter would have kept out of the catalog. World build: the section label's look.
    @ViewBuilder
    private func cardTitle(_ text: LocalizedStringKey) -> some View {
        if look != nil {
            SectionLabel(text)
        } else {
            Text(text).font(.fernlet(.label)).foregroundStyle(dimInk)
        }
    }

    /// One bulleted line of runtime text (an issue's already-localized detail, a new exercise's
    /// coach-supplied name and muscles), drawn verbatim.
    private func bullet(_ text: String, tint: Color = Color.moss) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(tint).padding(.top, 7)
            Text(text).font(.fernlet(.bodySmall)).foregroundStyle(textInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
