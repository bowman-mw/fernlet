import SwiftUI
import FernletDomainModel
import FernletUI

// The exercise lists inside the workout sheets (World Review Batch 3, draft 2): `b3-workout-log`,
// `b3-workout-edit` and `b3-workout-plan` show each exercise as one framed row whose sets read in one
// line; tapping a row opens that exercise's own page (`b3-workout-exercise`).

/// Where a workout sheet's stack goes: the one exercise being added or changed.
enum WorkoutLiftRoute: Hashable {
    /// The exercise page (``MoveLiftPage``) for a new exercise, or, in the Log sheet, the listed one it
    /// was opened from.
    case lift
    /// The plan sheet's page for the listed exercise with this id, edited in place.
    case row(UUID)
}

/// A lift's sets read as one line for its list row (`b3-workout-edit`: "3 sets · 10, 9, 8 reps · 35 lb"):
/// how many sets, the reps (one number when every set matched), and the weight (each distinct one, in
/// order; a blank set repeats the one above, as the editor says).
enum WorkoutSetSummary {
    /// The line for `draft`; empty when it has no sets.
    static func line(for draft: ExerciseSetsDraft) -> String {
        guard !draft.rows.isEmpty else { return "" }
        return line(reps: draft.rows.map(\.reps), weights: draft.rows.map(\.weightValue), unit: unit(of: draft))
    }

    /// The line for an exercise already added set by set (its logged result); nil when it has no sets,
    /// so the row keeps its plain prescription line.
    static func line(for result: ExerciseResult) -> String? {
        let sets = Array(result.loggedSets.prefix(ExerciseResult.maxSets))
        guard !sets.isEmpty else { return nil }
        let unit: UnitMass = result.unitToken == LoadUnit.kg.rawValue ? .kilograms : .pounds
        return line(reps: sets.map(\.reps), weights: sets.map(\.weight), unit: unit)
    }

    private static func line(reps: [Int], weights: [Double?], unit: UnitMass) -> String {
        let count = reps.count
        let sets = String(localized: "move.lift.summary.sets", defaultValue: "\(count) sets",
                          comment: "Workout sheets, an exercise row's set count, e.g. '3 sets'. Needs a plural variation; English also needs the one-set form.")
        var parts = [sets, repsText(reps)]
        if let weight = weightText(weights, unit: unit) { parts.append(weight) }
        return parts.joined(separator: " · ")
    }

    private static func unit(of draft: ExerciseSetsDraft) -> UnitMass { draft.unit == .kg ? .kilograms : .pounds }

    /// "8 reps" when every set matched, "10, 9, 8 reps" otherwise.
    static func repsText(_ reps: [Int]) -> String {
        if let first = reps.first, reps.allSatisfy({ $0 == first }) {
            return String(localized: "move.lift.summary.reps", defaultValue: "\(first) reps",
                          comment: "Workout sheets, an exercise row's reps when every set had the same, e.g. '8 reps'. Needs a plural variation.")
        }
        let list = reps.map { $0.formatted() }.joined(separator: ", ")
        return String(localized: "move.lift.summary.repsList", defaultValue: "\(list) reps",
                      comment: "Workout sheets, an exercise row's reps set by set, e.g. '10, 9, 8 reps'.")
    }

    /// The distinct weights in order, each with its abbreviated unit in the person's locale ("35 lb",
    /// "35 lb, 25 lb" for a drop set), or nil when none was typed.
    static func weightText(_ draft: ExerciseSetsDraft) -> String? {
        weightText(draft.rows.map(\.weightValue), unit: unit(of: draft))
    }

    /// The distinct weights of `weights` in order (a blank repeats the set above), or nil when none.
    private static func weightText(_ weights: [Double?], unit: UnitMass) -> String? {
        var distinct: [Double] = []
        var carried: Double?
        for weight in weights.prefix(ExerciseResult.maxSets) {
            carried = weight ?? carried
            if let carried, carried > 0, !distinct.contains(carried) { distinct.append(carried) }
        }
        guard !distinct.isEmpty else { return nil }
        return distinct
            .map { WorkoutActivityLoadText.weight($0, unit: unit, width: .abbreviated, locale: .current) }
            .joined(separator: ", ")
    }
}

/// One exercise in a workout sheet's list: its category's colour as a framed square, the name, its sets
/// in one line ("3 sets · 10, 9, 8 reps · 35 lb"), and the pixel chevron. The whole row opens its page;
/// VoiceOver also offers Remove when the sheet allows it.
struct MoveLiftListRow: View {
    let name: String
    let detail: String
    let color: Color
    let identifier: String
    var onRemove: (() -> Void)? = nil
    let action: () -> Void
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                MoveSwatch(color: color, size: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name)
                        .font(MoveFont.rowTitle)
                        .foregroundStyle(look?.text ?? Color.bark)
                        .fernletWrappingText()
                    if !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(FernletFramedFont.rowDetail)
                            .foregroundStyle(look?.dim ?? Color.slate)
                            .fernletWrappingText()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(FernletRowButtonStyle(showsChevron: true))
        .accessibilityIdentifier(identifier)
        .modifier(MoveLiftRemoveAction(onRemove: onRemove, name: name))
    }
}

/// Offers "Remove" as a VoiceOver action and a long-press menu item on a lift row, when the sheet allows it.
private struct MoveLiftRemoveAction: ViewModifier {
    let onRemove: (() -> Void)?
    let name: String

    func body(content: Content) -> some View {
        if let onRemove {
            content
                .accessibilityAction(named: Text("Remove")) { onRemove() }
                .contextMenu {
                    Button("Remove \(name)", role: .destructive, action: onRemove)
                }
        } else {
            content
        }
    }
}

/// One recent lift on the Log workout sheet (`b3-workout-log` draft 2: "Recent lifts are full rows with a +,
/// so nothing is cut off"): the name in bold, last time's sets after it, and a framed + that adds it to the
/// workout with those sets.
struct MoveRecentLiftRow: View {
    let name: String
    let recall: String?
    let identifier: String
    let action: () -> Void
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                (Text(verbatim: name).fontWeight(.semibold)
                    .foregroundStyle(look?.text ?? Color.bark))
                    .font(FernletFramedFont.rowTitle)
                    .fernletWrappingText()
                if let recall {
                    Text(verbatim: recall)
                        .font(FernletFramedFont.rowDetail)
                        .foregroundStyle(look?.dim ?? Color.slate)
                        .fernletWrappingText()
                }
                Spacer(minLength: 8)
                FernletIconTile(size: 32) { FernletIcon(.plus, scale: 2) }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityHint(Text("Adds it with last time's sets."))
        // Voice Control: the exercise is what a user says.
        .accessibilityInputLabels([Text(verbatim: name)])
        .accessibilityIdentifier(identifier)
        .accessibilityCustomContent(AccessibilityCustomContentKey("Last time"), recall.map { Text(verbatim: $0) })
    }
}

/// The page for one exercise inside a workout sheet (`b3-workout-exercise`, new in Batch 3 draft 2): the
/// sheet's stack shows Back naming the sheet; the exercise's name is the page's big title with last time
/// under it; then its fields; the sheet's button ("Add to workout") at the bottom.
struct MoveLiftPage<Content: View>: View {
    let title: Text
    let subtitle: Text?
    let buttonLabel: LocalizedStringKey?
    var buttonDisabled = false
    var onButton: () -> Void = {}
    let content: Content
    /// The back control's word under the World look: the list page this one came from.
    let back: Text?
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.dismiss) private var dismiss

    init(title: Text, subtitle: Text?, buttonLabel: LocalizedStringKey?, buttonDisabled: Bool = false,
         back: Text? = nil, onButton: @escaping () -> Void = {}, @ViewBuilder content: () -> Content) {
        self.back = back
        self.title = title
        self.subtitle = subtitle
        self.buttonLabel = buttonLabel
        self.buttonDisabled = buttonDisabled
        self.onButton = onButton
        self.content = content()
    }

    var body: some View {
        if look != nil {
            // World build (`b3-workout-exercise`): no system bar; "‹ Log workout" top left in the
            // sheet's control ink, where the sheets' Cancel sits, and the page's own big title.
            page
                .navigationTitle(title)
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .top, spacing: 0) { backRow }
        } else {
            page
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // The page prints its own title, so the bar's middle stays empty.
                    ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                }
        }
    }

    private var page: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    content
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            if let buttonLabel {
                SheetSaveBar(label: buttonLabel, disabled: buttonDisabled, action: onButton)
            }
        }
        .background((look?.paper ?? Color.parchment).ignoresSafeArea())
    }

    /// The framed back control: a pixel chevron and the list page's name; pops this page.
    private var backRow: some View {
        Button { dismiss() } label: {
            HStack(spacing: 6) {
                WorldSpriteView(sprite: WorldSprites.chevL, scale: 2)
                back ?? Text("Back")
            }
            .font(FernletFramedFont.sheetControl)
            .foregroundStyle(look?.dim ?? Color.slate)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sheet.back")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .background(look?.paper ?? Color.parchment)
    }

    /// The page's big title and its line under it.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            title
                .font(FernletFramedFont.sheetTitle)
                .foregroundStyle(look?.text ?? Color.bark)
                .fernletWrappingText()
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                subtitle
                    .font(FernletFramedFont.body)
                    .foregroundStyle(look?.dim ?? Color.slate)
                    .fernletWrappingText()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The framed "+ Add exercise" button at the foot of a workout sheet's exercise card.
struct MoveAddExerciseButton: View {
    var label: LocalizedStringKey = "Add exercise"
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                FernletIcon(.plus, scale: 2)
                Text(label)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ActionPillButtonStyle(.secondary))
        .accessibilityIdentifier(identifier)
    }
}

/// A workout sheet's exercise card (`b3-workout-log` draft 2): the rows split by dotted rules, then the Add
/// button, on one framed card under its section label.
struct MoveLiftCard<Rows: View, Footer: View>: View {
    let header: Text
    let rows: Rows
    let footer: Footer

    init(header: Text, @ViewBuilder rows: () -> Rows, @ViewBuilder footer: () -> Footer) {
        self.header = header
        self.rows = rows()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(header).padding(.horizontal, 4)
            FernletCard {
                VStack(alignment: .leading, spacing: 0) {
                    Group(subviews: rows) { subviews in
                        ForEach(subviews) { row in
                            if row.id != subviews.first?.id { FernletDottedRule() }
                            row
                        }
                    }
                    footer.padding(.top, 10)
                }
            }
        }
    }
}
