import SwiftUI
// For `AXCustomContent.Importance` — the `importance:` argument of `.accessibilityCustomContent`.
// SwiftUI declares the modifier but not the enum, and this target builds with
// SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY, under which `.high` needs the defining module in
// scope.
import Accessibility
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
///
/// **Consent may not shrink with the text (#3).** Those two degradations are layout decisions and
/// they stay, but a view that is never *drawn* is never an accessibility element — so at AX5 five
/// delete claims and three kept claims became one line each and the rest were unreachable by any
/// means, on the one screen in the app where what the user was told is the whole point. Every
/// claim is now single-sourced through ``WipeClaim`` and re-attached to VoiceOver:
/// ``CollapsedClaimContent`` speaks the full list on the AX5 summary row, and ``bulletRow`` puts
/// each claim's full wording on the More Content rotor wherever a short form is drawn in its place.
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

    // MARK: - Claims

    /// One reconciled claim on either list: the glyph its drawn row leads with, the full-size
    /// wording, the accessibility-size short form, and the short label that names it on VoiceOver's
    /// More Content rotor.
    ///
    /// All four live in ONE value on purpose (#3). The layout tiers these claims by text size and
    /// at AX5 collapses each list to a single drawn line, so the accessibility re-exposure has to
    /// promise exactly what the drawn list promises at default size. Two hand-kept copies of
    /// consent text drift the first time one of them is edited — and on this sheet the enumeration
    /// IS the disclosure.
    private struct WipeClaim {
        /// Short rotor label, e.g. "Friends". Display text — localized, never a token.
        let rotorLabel: LocalizedStringKey
        /// SF Symbol for the drawn row. Decorative: ``bulletRow(glyph:text:dropped:)`` hides it
        /// from VoiceOver (T1-8) and drops it entirely at accessibility sizes.
        let glyph: String
        /// The reconciled full-size wording — the truth the sheet asks the user to consent to.
        let full: LocalizedStringKey
        /// The accessibility-size short form, or `nil` when the claim is already short enough to
        /// draw unchanged at every size (both iCloud claims are single phrases).
        let short: LocalizedStringKey?
    }

    /// Whether the lists have collapsed to one drawn line each (5e·AX5) — the size at which the
    /// claims exist only on the accessibility side, via ``CollapsedClaimContent``.
    private var isCollapsed: Bool { dynamicTypeSize >= .accessibility5 }

    /// Every "this deletes" claim, in drawn order, including the two conditional iCloud claims.
    ///
    /// Claimed only when true, as before: a promise to delete a backup the code will skip is the
    /// old overpromise. The AX5 branch drops both from the drawn line; the rotor keeps them, so a
    /// user who HAS an iCloud copy is never told less than a user who does not.
    private var deleteClaims: [WipeClaim] {
        var claims: [WipeClaim] = [
            WipeClaim(rotorLabel: "Meals and activity", glyph: "fork.knife",
                      full: "Meals, workouts, water and sleep", short: "Meals, workouts, water, sleep"),
            WipeClaim(rotorLabel: "Journal", glyph: "book.closed",
                      full: "Journal entries, cycle days, the worry box", short: "Journal, cycle, worry box"),
            WipeClaim(rotorLabel: "Recipes and photos", glyph: "photo",
                      full: "Recipes, plans, your photos and polaroids", short: "Recipes, plans, your photos"),
            WipeClaim(rotorLabel: "Companion", glyph: "pawprint",
                      full: "Your companion, wardrobe and coins", short: "Companion, wardrobe, coins"),
            WipeClaim(rotorLabel: "Friends", glyph: "person.2",
                      full: "Your friends list — this phone gets a brand-new Fernlet identity, so friends' phones won't recognize it: you'll add each other again in person, and anyone you blocked is no longer blocked",
                      short: "Your friends list"),
        ]
        if hasICloudDayCopy {
            claims.append(WipeClaim(rotorLabel: "iCloud copy", glyph: "icloud",
                                    full: "Your iCloud copy", short: nil))
        }
        if hasSealedBackup {
            claims.append(WipeClaim(rotorLabel: "Encrypted backups", glyph: "icloud",
                                    full: "Your encrypted iCloud backups", short: nil))
        }
        return claims
    }

    /// One drawn claim row: the glyph, the wording at the current text size, and the full wording
    /// that was shortened away to produce it (`nil` when the row is drawn in full).
    private typealias ClaimRow = (glyph: String, text: LocalizedStringKey, dropped: LocalizedStringKey?)

    /// The rows to draw for one claim list at the current text size, each carrying the wording it
    /// was shortened FROM so ``bulletRow(glyph:text:dropped:)`` can put that on the rotor.
    ///
    /// `dropped` is `nil` at default sizes because the drawn row already IS the full claim —
    /// re-stating it would only pad the rotor.
    private func drawnRows(_ claims: [WipeClaim]) -> [ClaimRow] {
        guard !claims.isEmpty else { return [] }
        guard dynamicTypeSize.isAccessibilitySize else {
            return claims.map { (claim: WipeClaim) -> ClaimRow in (claim.glyph, claim.full, nil) }
        }
        return claims.map { (claim: WipeClaim) -> ClaimRow in
            guard let short = claim.short else { return (claim.glyph, claim.full, nil) }
            return (claim.glyph, short, claim.full)
        }
    }

    // MARK: - Lists

    /// The "this deletes" bullets, shortened at accessibility sizes (5e·AX3) and collapsed to one
    /// line at AX5 (5e·AX5). The full-size wording is the reconciled truth; the short forms only
    /// ever drop words, never add claims — and what they drop stays reachable on the rotor.
    private var deleteBullets: [ClaimRow] {
        guard !isCollapsed else { return [("trash", "Meals, workouts, journal, friends", nil)] }
        return drawnRows(deleteClaims)
    }

    private var deletesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("This deletes")
                .accessibilityIdentifier("deleteAll.deletesList")
            ForEach(Array(deleteBullets.enumerated()), id: \.offset) { _, bullet in
                bulletRow(glyph: bullet.glyph, text: bullet.text, dropped: bullet.dropped)
                    .modifier(CollapsedClaimContent(claims: deleteClaims, active: isCollapsed))
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

    /// Every "kept on purpose" claim, in drawn order — the survivors, ported from the dialog's
    /// reconciled kept list.
    ///
    /// The photo-wall claim is the one that most needs to survive the AX5 collapse: it says data
    /// this wipe does NOT reach, in both directions, and that there is no bulk delete. A user who
    /// only hears "shared photo wall" can reasonably read it the other way round.
    private var keptClaims: [WipeClaim] {
        [
            WipeClaim(rotorLabel: "Photo wall", glyph: "photo.on.rectangle.angled",
                      full: "The shared photo wall — the pictures friends gave you and the ones you shared with them stay, on both sides. You remove photos one at a time from the photo itself; there's no bulk delete.",
                      short: "The shared photo wall, on both sides"),
            WipeClaim(rotorLabel: "Design sharing", glyph: "hand.raised",
                      full: "Any restriction on sharing your own designs.",
                      short: "Any restriction on sharing your designs"),
            WipeClaim(rotorLabel: "App lock", glyph: "lock",
                      full: "Your app lock stays set up.", short: "Your app lock"),
        ]
    }

    /// The "kept on purpose" bullets, shortened at accessibility sizes (5e·AX3) and collapsed to
    /// one line at AX5 (5e·AX5) — the same tiering as ``deleteBullets``. The short forms only ever
    /// drop words, never claims: the wall stays on both sides, the design-sharing restriction
    /// stays, the app lock stays.
    private var keptBullets: [ClaimRow] {
        guard !isCollapsed else {
            return [("photo.on.rectangle.angled", "Shared photo wall, sharing restriction, app lock", nil)]
        }
        return drawnRows(keptClaims)
    }

    /// The survivors, ported from the dialog's reconciled kept list: the shared photo wall (BOTH
    /// directions — no bulk delete exists by product decision), the moderation self-ban (phrased as
    /// the dialog phrases it), and the app lock. Blocks are NOT kept — that consequence lives in
    /// the friends bullet above.
    private var keptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Kept on purpose")
                .accessibilityIdentifier("deleteAll.keptList")
            ForEach(Array(keptBullets.enumerated()), id: \.offset) { _, bullet in
                bulletRow(glyph: bullet.glyph, text: bullet.text, dropped: bullet.dropped)
                    .modifier(CollapsedClaimContent(claims: keptClaims, active: isCollapsed))
            }
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
    ///
    /// `dropped` is the wording this row was shortened FROM, or `nil` when it is drawn in full
    /// (#3). The short forms are not all cosmetic: the friends claim loses its entire second half —
    /// the new-identity reset and the fact that blocks are lifted with it — so the full wording
    /// rides the More Content rotor at DEFAULT importance, where it elaborates the drawn line for
    /// anyone who asks rather than repeating it at everyone who does not. It is attached uniformly
    /// rather than only on the claims that lose something material: a per-claim judgement call is
    /// exactly the kind of thing that goes stale when the copy is next edited.
    private func bulletRow(
        glyph: String,
        text: LocalizedStringKey,
        dropped: LocalizedStringKey?
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if !dynamicTypeSize.isAccessibilitySize {
                // T1-8: not `.combine`d with the text beside it, so without this the SF Symbol's
                // own name would be announced ahead of the claim it merely illustrates.
                Image(systemName: glyph)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.slate)
                    .frame(width: 22)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
            Spacer(minLength: 0)
        }
        .accessibilityCustomContent(AccessibilityCustomContentKey("Details"), dropped.map { Text($0) })
    }

    // MARK: - Accessibility re-exposure (#3)

    /// Re-attaches a collapsed claim list to VoiceOver, for the AX5 row that stands in for it.
    ///
    /// At AX5 each list is ONE summarising line — "Meals, workouts, journal, friends" for five
    /// claims, "Shared photo wall, sharing restriction, app lock" for three — and an undrawn view
    /// is an absent accessibility element, so the photo, companion, cycle, friends-identity and
    /// iCloud consequences could not be reached by any means at that size. Each claim gets its own
    /// entry here, carrying the FULL-size wording rather than the AX3 short form.
    ///
    /// **Importance is `.high`, deliberately** — the one place in this codebase that departs from
    /// the T2-2 default-importance convention (``MoveView``'s Recent chips, ``SharedSheets``'
    /// water hero). Default importance reaches only a user who already knows the More Content rotor
    /// exists; on an irreversible-wipe consent screen an undiscoverable claim is a dropped claim,
    /// and the whole finding is that AX5 consents to less than default size does. `.high` speaks
    /// each claim with the row, so the two sizes hear the same disclosure. It cannot double up with
    /// the drawn text — every value is `nil` unless `active`, i.e. unless the layout has already
    /// collapsed the words away.
    ///
    /// The slot count is FIXED at seven (Power of 10 rule 2 — a modifier chain cannot be a loop):
    /// five delete claims plus the two conditional iCloud ones, which is the longest list either
    /// section can produce. Unused slots resolve to a `nil` value, and the `Text?` overload takes
    /// that without leaving an empty rotor row.
    private struct CollapsedClaimContent: ViewModifier {
        /// The full claim list this one drawn row stands in for, in drawn order.
        let claims: [WipeClaim]
        /// Whether the layout has collapsed the list (AX5). `false` attaches nothing at all.
        let active: Bool

        func body(content: Content) -> some View {
            content
                .accessibilityCustomContent(key(0), value(0), importance: .high)
                .accessibilityCustomContent(key(1), value(1), importance: .high)
                .accessibilityCustomContent(key(2), value(2), importance: .high)
                .accessibilityCustomContent(key(3), value(3), importance: .high)
                .accessibilityCustomContent(key(4), value(4), importance: .high)
                .accessibilityCustomContent(key(5), value(5), importance: .high)
                .accessibilityCustomContent(key(6), value(6), importance: .high)
        }

        /// The rotor label for slot `index`; a placeholder past the end of a shorter list, where
        /// the matching ``value(_:)`` is `nil` and no entry is created at all.
        private func key(_ index: Int) -> AccessibilityCustomContentKey {
            guard index >= 0 else { return AccessibilityCustomContentKey("Details") }
            guard index < claims.count else { return AccessibilityCustomContentKey("Details") }
            return AccessibilityCustomContentKey(claims[index].rotorLabel)
        }

        /// The full-size wording for slot `index`, or `nil` when the drawn list still carries the
        /// claims itself or the slot is past the end of this list.
        private func value(_ index: Int) -> Text? {
            guard active, index >= 0 else { return nil }
            guard index < claims.count else { return nil }
            return Text(claims[index].full)
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
