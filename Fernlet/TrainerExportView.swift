import SwiftUI
import FernletDomainModel
import FernletUI

/// The Trainer / Nutritionist export review + consent screen (Phase 7). The user picks exactly what to
/// include and sees precisely what is and is NEVER shared, then prepares a curated summary to hand to a
/// trainer or nutritionist. Nothing leaves the device until the user shares the prepared file.
///
/// A coach is NOT a friend, so this deliberately does NOT ride the friend mesh. In-person sharing over the
/// dedicated `fernlet-coach` trainer channel (to a coach running the separate coaching app) ships with
/// that later feature; until then the reviewed summary is shared as a protected file (AirDrop, email, …).
struct TrainerExportView: View {
    var store: FernletStore
    @Environment(\.dismiss) private var dismiss

    @State private var options = TrainerExportOptions.coreOnly
    @State private var preparedFile: URL?
    @State private var prepareError = false

    private var preview: TrainerExportBundle { store.buildTrainerExport(options: options) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FernletMetrics.spaceLg) {
                    intro
                    alwaysIncludedCard
                    optionalCard
                    neverSharedCard
                    prepareSection
                    comingSoonNote
                }
                .padding(20)
            }
            .background(Color.parchment)
            .navigationTitle("Share with a trainer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .onChange(of: options) { _, _ in preparedFile = nil }   // options changed → re-prepare
            .alert("Couldn't prepare the summary", isPresented: $prepareError) {
                Button("OK", role: .cancel) {}
            } message: { Text("Please try again.") }
        }
    }

    // MARK: - Sections

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Share your training")
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
            Text("Prepare a summary of your workouts and nutrition to give to a trainer or nutritionist. "
                 + "You control exactly what goes in it, and nothing is shared until you choose to.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var alwaysIncludedCard: some View {
        card {
            cardTitle("Always included")
            bullet("Your workouts (names, sets/reps/weights as logged, duration, effort)")
            bullet("Per-day nutrition summaries (calories, macros, micronutrient totals, meal names)")
            bullet("Training-safety notes (injuries, muscles and movements to avoid)")
        }
    }

    private var optionalCard: some View {
        card {
            cardTitle("Also include (optional)")
            Toggle("Your goal", isOn: $options.includeGoal).tint(Color.moss)
            Toggle("Hydration", isOn: $options.includeHydration).tint(Color.moss)
            Toggle("Sleep summaries", isOn: $options.includeSleep).tint(Color.moss)
            Toggle("Days you were unwell", isOn: $options.includeSickness).tint(Color.moss)
            Toggle("Wellbeing score", isOn: $options.includeWellbeing).tint(Color.moss)
        }
        .font(.fernlet(.body))
        .foregroundStyle(Color.bark)
    }

    private var neverSharedCard: some View {
        card {
            cardTitle("Never shared")
            bullet("Journal entries and private notes", tint: Color.terracotta)
            bullet("Period, cycle, and intimate-activity data", tint: Color.terracotta)
            bullet("Photos, friends, and location", tint: Color.terracotta)
            bullet("Recipe ingredients and your private keys", tint: Color.terracotta)
        }
    }

    private var prepareSection: some View {
        VStack(spacing: 10) {
            Text("\(preview.days.count) day\(preview.days.count == 1 ? "" : "s") of training will be included.")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .frame(maxWidth: .infinity, alignment: .center)

            if let url = preparedFile {
                ShareLink(item: url) {
                    Label("Share summary…", systemImage: "square.and.arrow.up")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.parchment)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.moss, in: RoundedRectangle(cornerRadius: FernletMetrics.radiusSm))
                }
                .accessibilityIdentifier("trainer.share")
            } else {
                Button {
                    if let url = store.writeTrainerExportFile(options: options) {
                        preparedFile = url
                    } else {
                        prepareError = true
                    }
                } label: {
                    Text("Prepare summary")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.parchment)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.moss, in: RoundedRectangle(cornerRadius: FernletMetrics.radiusSm))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("trainer.prepare")
            }
        }
    }

    private var comingSoonNote: some View {
        Text("Sharing in person with a coach who uses Fernlet Coach is coming soon.")
            .font(.fernlet(.labelSmall))
            .foregroundStyle(Color.slate)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
    }

    // MARK: - Building blocks

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: FernletMetrics.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: FernletMetrics.radiusMd).stroke(Color.bark.opacity(0.08), lineWidth: 1))
    }

    private func cardTitle(_ text: String) -> some View {
        Text(text).font(.fernlet(.label)).foregroundStyle(Color.slate)
    }

    private func bullet(_ text: String, tint: Color = Color.moss) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(tint).padding(.top, 7)
            Text(text).font(.fernlet(.bodySmall)).foregroundStyle(Color.bark)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
