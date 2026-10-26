import FernletDomainModel
import FernletUI
import SwiftUI

/// Settings › Sharing (World `b3-sharing-settings`, approved 2026-10-24; supersedes `b2-settings-sharing`):
/// what a recipe the person shares carries, the manual clipboard/paste plan exchange gate, and what
/// trainer summaries include.
///
/// "Recipes you share" is new from the owner's note on the share sheet (2026-10-24): Include notes and
/// Include picture moved here from every share, on by default as the sheet's switches were. The rest is
/// the Sharing page as it was, in framed sections. Every switch writes the synced settings and schedules
/// a save; nothing here sends anything.
struct SharingSettingsView: View {
    var store: FernletStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                FernletFramedSection("Recipes you share") {
                    switchRow("Include notes", detail: "Your notes go along with the recipe.",
                              isOn: binding(\.recipeShareIncludesNotes), identifier: "settings.sharing.recipeNotes")
                    switchRow("Include picture", detail: "The recipe's photo goes along, if it has one.",
                              isOn: binding(\.recipeShareIncludesPicture), identifier: "settings.sharing.recipePicture")
                }
                FernletFramedSection("Manual plan exchange",
                                     footer: "Copied text leaves Fernlet when you paste it elsewhere. Pasted plans are not from a verified coach, so Fernlet shows every day for review before adding anything.") {
                    switchRow("Manual plan exchange",
                              detail: "Lets you copy a training summary and prompt for an AI assistant, then paste its workout plan back into Fernlet.",
                              isOn: binding(\.coachExchangeEnabled), identifier: "settings.sharing.planExchange")
                }
                trainerSummaries
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .fernletPageBackground()
        // In the World panel the title and Back go on the wooden plate (`b1-frame-push`).
        .fernletPushedPage("Sharing settings")
    }

    /// Trainer summaries: the five optional categories, under the line saying they are additions.
    private var trainerSummaries: some View {
        FernletFramedSection(header: Text("Trainer summaries"),
                             footer: Text("These choices apply to every summary prepared from Move or Shortcuts.")) {
            Text("Also include in trainer summaries")
                .font(FernletFramedFont.rowDetailBold)
                .foregroundStyle(WorldPalette.dim)
            switchRow("Your goal", isOn: binding(\.trainerExportIncludesGoal))
            switchRow("Hydration", isOn: binding(\.trainerExportIncludesHydration))
            switchRow("Sleep summaries", isOn: binding(\.trainerExportIncludesSleep))
            switchRow("Days you were unwell", isOn: binding(\.trainerExportIncludesSickness))
            switchRow("Wellbeing score", isOn: binding(\.trainerExportIncludesWellbeing))
        }
    }

    /// One switch row: the name, an optional line under it, and the framed switch the root's toggle
    /// style draws. `LocalizedStringKey`, so every call site's literals reach the catalog.
    private func switchRow(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil, isOn: Binding<Bool>,
                           identifier: String? = nil) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(FernletFramedFont.rowTitleBold)
                    .foregroundStyle(WorldPalette.bark)
                if let detail {
                    Text(detail)
                        .font(FernletFramedFont.rowDetail)
                        .foregroundStyle(WorldPalette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier(identifier ?? "settings.sharing.toggle")
    }

    /// A settings value as a binding that writes the synced settings and schedules their save.
    private func binding(_ keyPath: WritableKeyPath<FernletSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { newValue in
                store.settings[keyPath: keyPath] = newValue
                store.scheduleSnapshotSave()
            }
        )
    }
}
