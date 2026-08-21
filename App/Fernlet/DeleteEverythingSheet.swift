import SwiftUI
import FernletFoundation
import FernletUI

/// The typed-gate confirmation sheet for "Delete everything" (2026-08-21 redesign, artboard 5e —
/// SETT-08, XCUT-21, XCUT-02).
///
/// Replaces the system alert at both Settings entry points: the most destructive action in the app
/// now carries the same sheet shape and typed gate the lesser "Delete iCloud data" action already
/// used. The ~180-word alert message became two scannable lists — **what goes** and **what is kept
/// on purpose** — whose claims are ported from ``DeleteAllDataConfirmation``'s hand-reconciled
/// copy and must stay in step with `FernletStore.deleteAllData`'s funnel (there is no test coupling
/// the text to the funnel; the enumeration is the invariant backstop).
///
/// Contract with the entry screens (``SettingsSheet`` / ``PrivacyDataSettingsView``):
/// - Nothing mutates until a delete button is tapped; Cancel and swipe-down run nothing.
/// - The confirm word is the localized ``DeleteConfirmationWord`` — a matching input under the
///   localization wall. The terracotta actions stay disabled by **opacity** until it matches, then
///   fill solid (this confirm surface is the one place solid terracotta is allowed).
/// - Cancel is a real, always-rendered button (iOS 26 `confirmationDialog` suppresses the
///   `.cancel` role, which is why this sheet renders its own buttons).
/// - The Apple Health choice keeps its TWO outcomes ("Delete, keep Health" vs "Delete, and from
///   Health"), driven by the same ``DeleteAllDataConfirmation/HealthSampleOffer`` the alert used.
/// - On confirm the sheet logs the same audit tokens the alert path logged, dismisses, and hands
///   the wipe to `DeleteEverythingFlow.runWipe` via `onConfirm` — busy overlay, outcome alerts and
///   dismissal blocking stay per-screen exactly as before.
///
/// Dynamic Type (5e·AX3/AX5): the bullet lists lose their glyphs and shorten to phrases at
/// accessibility sizes, collapsing to one line at AX5; the buttons unstack with Cancel underneath;
/// the typed gate may scroll below the fold, but the sheet still cannot be confirmed without
/// reaching it — the buttons stay inert until the word is typed.
struct DeleteEverythingSheet: View {
    /// Which Apple Health outcome(s) to offer — see ``DeleteAllDataConfirmation/HealthSampleOffer``.
    let offer: DeleteAllDataConfirmation.HealthSampleOffer
    /// Whether iCloud holds a day-blob copy (live sync copy or one kept after sync-off). Claimed
    /// only when true — a promise to delete a backup the code will skip is the old overpromise.
    let hasICloudDayCopy: Bool
    /// Whether any sealed encrypted backups exist in iCloud. Independent of `hasICloudDayCopy`.
    let hasSealedBackup: Bool
    /// Runs the wipe. The Bool is "also delete Fernlet-authored Apple Health samples".
    let onConfirm: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var typedConfirmation = ""

    private var isArmed: Bool { DeleteConfirmationWord.matches(typedConfirmation) }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "Delete everything?",
                subtitle: "This cannot be undone.",
                onCancel: { dismiss() }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    deletesSection
                    keptSection
                    healthSection
                    typedGate
                }
                .padding(20)
                .padding(.bottom, 8)
            }
            actionBar
        }
        .background(Color.parchment)
        .presentationDragIndicator(.visible)
    }

    // MARK: - Lists

    /// The "this deletes" bullets, shortened at accessibility sizes (5e·AX3) and collapsed to one
    /// line at AX5 (5e·AX5). The full-size wording is the reconciled truth; the short forms only
    /// ever drop words, never add claims.
    private var deleteBullets: [(glyph: String, text: LocalizedStringKey)] {
        if dynamicTypeSize >= .accessibility5 {
            return [("trash", "Meals, workouts, journal, friends")]
        }
        var bullets: [(String, LocalizedStringKey)]
        if dynamicTypeSize.isAccessibilitySize {
            bullets = [
                ("fork.knife", "Meals, workouts, water, sleep"),
                ("book.closed", "Journal, cycle, worry box"),
                ("photo", "Recipes, plans, your photos"),
                ("pawprint", "Companion, wardrobe, coins"),
                ("person.2", "Your friends list"),
            ]
        } else {
            bullets = [
                ("fork.knife", "Meals, workouts, water and sleep"),
                ("book.closed", "Journal entries, cycle days, the worry box"),
                ("photo", "Recipes, plans, your photos and polaroids"),
                ("pawprint", "Your companion, wardrobe and coins"),
                ("person.2", "Your friends list — this phone gets a brand-new Fernlet identity, so friends' phones won't recognize it: you'll add each other again in person, and anyone you blocked is no longer blocked"),
            ]
        }
        if hasICloudDayCopy { bullets.append(("icloud", "Your iCloud copy")) }
        if hasSealedBackup { bullets.append(("icloud", "Your encrypted iCloud backups")) }
        return bullets
    }

    private var deletesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("This deletes")
                .accessibilityIdentifier("deleteAll.deletesList")
            ForEach(Array(deleteBullets.enumerated()), id: \.offset) { _, bullet in
                bulletRow(glyph: bullet.glyph, text: bullet.text)
            }
            // NOT "none of it can be recovered": local data rides iOS device backups by default,
            // so an older encrypted backup can still restore it — Fernlet can't reach into that.
            Text("Fernlet can't undo this.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            if hasICloudDayCopy {
                // Day records and custom items keep no tombstones (owner decision 2026-08-21:
                // disclose, don't tombstone). The coin and milestone ledgers are deliberately NOT
                // named — their reset-boundary markers void re-synced rows.
                Text("If you use Fernlet on another device, this reaches it the next time that device syncs — and a device you're using right then may re-add its most recent days and any custom clothing designs it still has.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
    }

    /// The survivors, ported from the dialog's reconciled kept list: the shared photo wall (BOTH
    /// directions — no bulk delete exists by product decision), the moderation self-ban (phrased as
    /// the dialog phrases it), and the app lock. Blocks are NOT kept — that consequence lives in
    /// the friends bullet above.
    private var keptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Kept on purpose")
                .accessibilityIdentifier("deleteAll.keptList")
            bulletRow(glyph: "photo.on.rectangle.angled", text: "The shared photo wall — the pictures friends gave you and the ones you shared with them stay, on both sides. You remove photos one at a time from the photo itself; there's no bulk delete.")
            bulletRow(glyph: "hand.raised", text: "Any restriction on sharing your own designs.")
            bulletRow(glyph: "lock", text: "Your app lock stays set up.")
        }
    }

    /// One Apple Health paragraph per offer state — the same three tellings
    /// ``DeleteAllDataConfirmation`` carries (its doc comments explain every hedge; keep the two
    /// in step).
    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Apple Health")
            Text(healthParagraph)
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
    }

    private var healthParagraph: LocalizedStringKey {
        switch offer {
        case .integrationOn:
            "Fernlet can also delete the entries it wrote to Apple Health — that's the second button below. It can only ever delete its own; everything else in Apple Health is yours to delete in the Health app."
        case .integrationOff:
            "Health is turned off in Fernlet, but anything Fernlet wrote to Apple Health before that is still there, and Fernlet can still delete it — you don't have to turn Health back on. It can only ever delete its own; everything else in Apple Health is yours to delete in the Health app. If you've taken Fernlet's Health access away since, it will say so instead of claiming it's gone."
        case .nothingAuthored:
            "Fernlet has no record of writing anything to Apple Health, so it isn't offering to delete from there. If it wrote entries on an earlier install, turn Health back on to let Fernlet remove them, or delete them yourself in the Health app."
        }
    }

    /// One glyph-led claim line; the glyph bullet drops at accessibility sizes (5e·AX3) so the
    /// words keep the room.
    private func bulletRow(glyph: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if !dynamicTypeSize.isAccessibilitySize {
                Image(systemName: glyph)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.slate)
                    .frame(width: 22)
                    .padding(.top, 2)
            }
            Text(text)
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
            Spacer(minLength: 0)
        }
    }

    // MARK: - Typed gate

    /// The gate sits BELOW the kept list on purpose: at accessibility sizes it scrolls under the
    /// fold, which is acceptable only because it cannot be passed without scrolling past what it
    /// protects (5e·AX3).
    private var typedGate: some View {
        SheetField("Type \(DeleteConfirmationWord.localizedWord) to confirm") {
            TextField(DeleteConfirmationWord.localizedWord, text: $typedConfirmation)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .sheetTextInput()
                .accessibilityIdentifier("deleteAll.confirmText")
        }
    }

    // MARK: - Actions

    /// Delete button(s) with Cancel — side by side at regular sizes, unstacked with Cancel
    /// underneath at accessibility sizes and whenever the Health choice needs two buttons, so the
    /// destructive action is never the closest to the thumb (5e·AX3).
    @ViewBuilder
    private var actionBar: some View {
        VStack(spacing: 10) {
            if offer.offersHealthDelete {
                deleteButton("Delete, keep Health", includeHealth: false, id: "deleteAll.confirm")
                deleteButton("Delete, and from Health", includeHealth: true, id: "deleteAll.confirmWithHealth")
                cancelButton
            } else if dynamicTypeSize.isAccessibilitySize {
                deleteButton("Delete everything", includeHealth: false, id: "deleteAll.confirm")
                cancelButton
            } else {
                HStack(spacing: 12) {
                    cancelButton
                    deleteButton("Delete everything", includeHealth: false, id: "deleteAll.confirm")
                }
            }
        }
        .padding(20)
        .background(Color.parchment)
    }

    /// Solid terracotta ONLY once armed — this confirm surface is the one place the destructive
    /// token allows a solid fill; disabled is an opacity drop, never a color change.
    private func deleteButton(_ title: LocalizedStringKey, includeHealth: Bool, id: String) -> some View {
        Button {
            confirm(includeHealth: includeHealth)
        } label: {
            Text(title)
                .font(.fernlet(.label))
                .foregroundStyle(isArmed ? Color.onTerracotta : Color.bark)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    Color.terracotta.opacity(isArmed ? 1 : 0.55),
                    in: RoundedRectangle(cornerRadius: 14)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isArmed)
        .accessibilityIdentifier(id)
    }

    private var cancelButton: some View {
        Button("Cancel") { dismiss() }
            .buttonStyle(.plain)
            .font(.fernlet(.label))
            .foregroundStyle(Color.slate)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier("deleteAll.cancel")
    }

    /// Logs the same audit tokens the alert path's `commitDestructive` logged, dismisses, and
    /// starts the wipe. The guard makes the typed gate load-bearing even if a disabled button were
    /// ever tapped programmatically.
    private func confirm(includeHealth: Bool) {
        guard isArmed else { return }
        FernletAuditLog.log(
            includeHealth ? "settings.deleteAll.withHealthSamplesConfirmed" : "settings.deleteAll.confirmed",
            context: ["confirmed": "true"]
        )
        dismiss()
        onConfirm(includeHealth)
    }
}
