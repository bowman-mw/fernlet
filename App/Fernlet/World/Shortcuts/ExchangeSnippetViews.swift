import FernletDomainModel
import FernletExchange
import FernletUI
import SwiftUI

/// The lines of the two Shortcuts confirmations (`b4-sc-recipe`, `b4-sc-plan`, World Review Batch 4),
/// apart from their views so tests can read them.
///
/// Every count is plural-ruled ("1 serving", not "1 servings"): a recipe's counts are the Messages
/// card's own (`FernletMessagesCardCopy`, read from the iMessage app's catalog, whose `one`/`other`
/// blocks already exist), so a shared recipe counts the same way in Messages and in Shortcuts; the
/// plan's two counts with a noun have keys of their own.
enum ExchangeSnippetCopy {
    /// "1 serving · 9 ingredients".
    static func servingsAndIngredients(servings: Int, ingredients: Int) -> String {
        [FernletMessagesCardCopy.servingCount(servings), FernletMessagesCardCopy.ingredientCount(ingredients)]
            .joined(separator: " · ")
    }

    /// "6 steps · Notes included", or "6 steps · No notes".
    static func stepsAndNotes(steps: Int, includesNotes: Bool) -> String {
        let notes = includesNotes ? String(localized: "Notes included") : String(localized: "No notes")
        return [FernletMessagesCardCopy.stepCount(steps), notes].joined(separator: " · ")
    }

    /// The plan's sender, or "Sender not specified" when the plan names none.
    static func sender(_ displayName: String) -> String {
        guard displayName.isEmpty else { return displayName }
        return String(localized: "shortcuts.plan.senderNotSpecified", defaultValue: "Sender not specified",
                      comment: "Shortcuts' Add this workout plan? confirmation, under the plan's title, when the plan file names no sender.")
    }

    /// "1 collision · Keep existing workouts": the days that already hold planned workouts, then what
    /// the import does about them.
    static func collisions(_ count: Int, policy: WorkoutPlanCollisionPolicy) -> String {
        let days = String(localized: "shortcuts.plan.collisions", defaultValue: "\(count) collisions",
                          comment: "Shortcuts' Add this workout plan? confirmation: how many days in the plan's range already have planned workouts, e.g. '1 collision', '3 collisions'. Needs a plural variation per language. Followed by ' · ' and what the import does about them.")
        return [days, policy.displayName].joined(separator: " · ")
    }

    /// "3 added · 0 changed · 0 removed".
    static func changes(added: Int, changed: Int, removed: Int) -> String {
        String(localized: "shortcuts.plan.changes", defaultValue: "\(added) added · \(changed) changed · \(removed) removed",
               comment: "Shortcuts' Add this workout plan? confirmation: planned workouts the import adds, changes and removes. The three numbers are counts of workouts; a label-and-number form ('Added: 3') avoids needing plural forms.")
    }

    /// "1 avoided or unavailable exercise warning".
    static func safetyWarnings(_ count: Int) -> String {
        String(localized: "shortcuts.plan.safetyWarnings", defaultValue: "\(count) avoided or unavailable exercise warnings",
               comment: "Shortcuts' Add this workout plan? confirmation, in the warning colour: how many of the plan's exercises you avoid or Fernlet can't offer, e.g. '1 avoided or unavailable exercise warning'. Needs a plural variation per language.")
    }
}

extension WorkoutPlanCollisionPolicy {
    /// The policy's name as Shortcuts lists it (its `caseDisplayRepresentations` keys), localized.
    var displayName: String {
        switch self {
        case .keepExistingWorkouts: String(localized: "Keep existing workouts")
        case .addAlongside: String(localized: "Add alongside")
        case .replaceFutureConflicts: String(localized: "Replace future conflicts")
        }
    }
}

/// Fernlet's card inside Shortcuts' confirmation (`b4-sc-*`): paper in an ink frame, a pixel icon in a
/// framed tile beside the title in Fraunces (and a line under it), then the facts in DM Sans. iOS
/// draws the frame around it — the app icon, the question, Cancel and Add.
struct ExchangeSnippetCard<Lines: View>: View {
    let sprite: WorldSprite
    /// One colour for a one-colour sprite (the dumbbell); nil keeps the sprite's own.
    var tint: Color?
    let title: String
    var subtitle: String?
    @ViewBuilder let lines: Lines

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    FernletIconTile(size: 40) { WorldSpriteView(sprite: sprite, scale: 2, tint: tint) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: title)
                            .font(ExchangeSnippetType.title)
                            .foregroundStyle(WorldPalette.bark)
                        if let subtitle {
                            Text(verbatim: subtitle)
                                .font(FernletFramedFont.note)
                                .foregroundStyle(WorldPalette.dim)
                        }
                    }
                }
                .padding(.bottom, 2)
                lines
                    .font(FernletFramedFont.body)
                    .foregroundStyle(WorldPalette.bark)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .worldDesignLanguage()
    }
}

/// The confirmation's type: the title in Fraunces (19 pt, as drawn) and the warning in DM Sans bold.
nonisolated enum ExchangeSnippetType {
    static let title = Font.custom(FernletFontName.frauncesSemiBold, size: 19, relativeTo: .title3)
    static let warning = Font.custom(FernletFontName.dmSansBold, size: 15, relativeTo: .body)
    /// The warning's orange, darkened for contrast on paper (6.3:1 light, 7.1:1 dark).
    static let warningInk = WorldPalette.adaptive(light: 0x8A4B12, dark: 0xF0B26A)
}

/// Import recipe's confirmation (`b4-sc-recipe`): only fields the import will persist — the name, the
/// servings and ingredients, the steps and whether notes come along, and the parts of a recipe made
/// in parts.
struct RecipeExchangeConfirmation: View {
    let packet: RecipeExchangePacket

    var body: some View {
        ExchangeSnippetCard(sprite: WorldSprites.bowlInk, title: packet.recipe.name) {
            Text(verbatim: ExchangeSnippetCopy.servingsAndIngredients(servings: packet.recipe.servings,
                                                                     ingredients: packet.recipe.ingredients.count))
            Text(verbatim: ExchangeSnippetCopy.stepsAndNotes(steps: packet.recipe.steps?.count ?? 0,
                                                            includesNotes: packet.includesNotes))
            if let parts = packet.recipe.components, !parts.isEmpty {
                Text("Parts: \(parts.map(\.name).joined(separator: " · "))")
            }
        }
    }
}

/// Add this workout plan's confirmation (`b4-sc-plan`): exactly the safety and collision facts the
/// foreground review uses — the sender, days and workouts, the dates, collisions and the policy,
/// what changes, and the warning line when there is one.
struct WorkoutPlanExchangeConfirmation: View {
    let preview: WorkoutPlanImportPreview

    private var lastDayKey: String {
        let highestDay = preview.review.plan.days.map(\.dayIndex).max() ?? 1
        return FernletStore.dayKey(startingOn: preview.startDayKey, offsetBy: highestDay - 1) ?? preview.startDayKey
    }

    private var changeCounts: String {
        let edits = preview.review.resolvedEdits.filter(\.isMeaningful)
        let changed = edits.filter { $0.action != .delete }.count
        let removed = edits.filter { $0.action == .delete }.count
        return ExchangeSnippetCopy.changes(added: preview.review.plan.sessionCount, changed: changed, removed: removed)
    }

    var body: some View {
        let plan = preview.review.plan
        ExchangeSnippetCard(sprite: WorldSprites.dumbbell, tint: WorldPalette.iconInk, title: plan.title,
                            subtitle: ExchangeSnippetCopy.sender(plan.coachDisplayName)) {
            Text("\(plan.days.count) days · \(plan.sessionCount) workouts")
            Text("\(preview.startDayKey) – \(lastDayKey)")
            Text(verbatim: ExchangeSnippetCopy.collisions(preview.review.collidingDayKeys.count, policy: preview.policy))
            Text(verbatim: changeCounts)
            if !preview.review.safetyFlags.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    WorldSpriteView(sprite: MoveSprites.info, scale: 2, tint: ExchangeSnippetType.warningInk)
                    Text(verbatim: ExchangeSnippetCopy.safetyWarnings(preview.review.safetyFlags.count))
                        .font(ExchangeSnippetType.warning)
                        .foregroundStyle(ExchangeSnippetType.warningInk)
                }
            }
        }
    }
}
