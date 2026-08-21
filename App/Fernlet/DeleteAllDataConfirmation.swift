import SwiftUI
import FernletFoundation
import FernletUI

/// The one confirm dialog for "delete everything", shared by both Settings entry points.
///
/// It lives in its own file rather than in either view because the bug this change exists to fix was
/// exactly two entry points disagreeing about what deletion meant — one that cleared part of the data
/// while promising all of it, and one behind a lock the user might not have. A single funnel
/// (`FernletStore.deleteAllData`) with two hand-written dialogs would drift back into the same shape the
/// first time someone edited one of them.
///
/// The copy follows the house rule for destructive confirmations: name the exact data, say whether it
/// can be recovered, and never use a category word ("all other protected data") where an enumeration is
/// what makes the sentence true.
enum DeleteAllDataConfirmation {

    /// What the dialog offers — and says — about the samples Fernlet wrote into Apple Health.
    ///
    /// Three states rather than a `Bool` because the offer and the explanation stopped agreeing.
    /// Gating the second destructive button on `healthKitMasterEnabled` gave the most
    /// privacy-conscious user the LEAST deletion: turning Health off does not retract the
    /// sexual-activity, menstrual-flow, workout, mindful-session and body-measurement samples Fernlet
    /// already wrote, and that user was never offered their removal. The offer therefore keys off
    /// "has Fernlet ever been prompted for a capability that writes samples"
    /// (`HealthCapabilityRequestLedger`), which survives the toggle, while the wording still has to
    /// tell the toggle-off user why Health is being mentioned at all.
    ///
    /// Offering too widely is the deliberate direction: `HealthKitService.deleteAllAuthoredSamples()`
    /// is gated on neither the toggle nor device availability, an unauthorized type is an expected
    /// skip, and a delete Fernlet cannot reach comes back `.accessRevoked` and is named in the failure
    /// alert — so an offer that finds nothing costs one no-op pass and never lies.
    enum HealthSampleOffer {
        /// Fernlet has no record of ever being prompted for a capability that writes samples, so it
        /// has nothing of its own to delete: one "Delete" button and no keep-vs-delete question.
        case nothingAuthored
        /// The Health integration is on — the pre-existing case, described in the present tense.
        case integrationOn
        /// The integration is OFF, but Fernlet was prompted for at least one write-capable capability,
        /// so entries it wrote earlier may still sit in Apple Health. Same two outcomes as
        /// ``integrationOn``; only the wording changes, because "turn Health back on to let Fernlet
        /// remove it" is no longer what this user has to do.
        case integrationOff

        /// Whether the dialog offers the second destructive button (delete from Health too).
        ///
        /// Switched rather than `!= .nothingAuthored` so a fourth state cannot inherit "offers" — the
        /// defect being fixed here was exactly a Health state nobody re-decided the offer for.
        var offersHealthDelete: Bool {
            switch self {
            case .nothingAuthored: return false
            case .integrationOn, .integrationOff: return true
            }
        }
    }

    /// Builds the dialog. `healthSamples` decides whether the user is offered the SECOND destructive
    /// button and how the closing Apple Health paragraph reads — see ``HealthSampleOffer``. It is
    /// deliberately NOT the live `healthKitMasterEnabled` preference on its own.
    ///
    /// `onFinished` receives the outcome so the caller can surface a partial failure. Every layer of the
    /// delete is best-effort; the caller must not assume success just because the dialog was confirmed.
    /// `hasICloudDayCopy` (a live sync copy OR one kept behind after sync was turned off) and
    /// `hasSealedBackup` are claimed as SEPARATE sentences: a user may have one without the other, and
    /// the old single sentence claiming both — "as this device syncs" — was false for the keep-cloud-copy
    /// user (sync off) and overclaimed for anyone with only one of the two.
    static func make(
        healthSamples: HealthSampleOffer,
        hasICloudDayCopy: Bool,
        hasSealedBackup: Bool,
        delete: @escaping (Bool) async -> FernletStore.DeleteAllOutcome,
        onFinished: @escaping (FernletStore.DeleteAllOutcome) -> Void
    ) -> DestructiveConfirmation {
        DestructiveConfirmation(
            title: "Delete everything?",
            message: message(
                healthSamples: healthSamples,
                hasICloudDayCopy: hasICloudDayCopy,
                hasSealedBackup: hasSealedBackup
            ),
            confirmLabel: healthSamples.offersHealthDelete ? "Delete, keep Health" : "Delete",
            auditEvent: "settings.deleteAll.confirmed",
            secondaryConfirm: healthSamples.offersHealthDelete
                ? DestructiveConfirmation.SecondaryConfirm(
                    label: "Delete, and from Health",
                    auditEvent: "settings.deleteAll.withHealthSamplesConfirmed",
                    perform: { onFinished(await delete(true)) }
                )
                : nil,
            perform: { onFinished(await delete(false)) }
        )
    }

    /// Paragraphs in the order the user needs them: what goes, what stays, and what Fernlet cannot reach
    /// on their behalf. The iCloud and Health sentences are CONDITIONAL — a claim about deleting an
    /// iCloud backup that the code will skip (because there isn't one) is exactly the kind of
    /// nearly-harmless overpromise that made the old "Reset everything" label untrue.
    private static func message(healthSamples: HealthSampleOffer, hasICloudDayCopy: Bool, hasSealedBackup: Bool) -> String {
        // "meals and their photos" + "gym progress photos" + "saved recipes and their photos" — never a
        // bare "photos". The photos this funnel deletes are the user's OWN logged pictures: the ones
        // attached to meals (`mealPhotoStore`), the gym progress-photo timeline (`progressPhotoStore`,
        // step 4b), and each recipe's own photo (`recipePhotoStore`, step 4c). The shared-photo wall is KEPT
        // (see below), so an unqualified "photos" here would contradict the kept list and re-open the exact
        // says-more-than-it-does gap this dialog exists to close. This enumeration is the invariant backstop
        // (there's no test coupling this text to the funnel) — keep it in step with what step 4/4b delete.
        var scope = """
            This deletes your logged days, meals and their photos, gym progress photos, journal entries, \
            cycle notes, intimate logs, Worry Box notes, saved recipes and their photos, custom items and coins.
            """
        // Two INDEPENDENT claims, not one. The day-blob copy in iCloud (a live sync copy or one kept after
        // sync was turned off) and any sealed encrypted backups are removed by different legs of the
        // funnel, and a user can have either without the other — so each is only promised when it exists.
        if hasICloudDayCopy {
            scope += " Your iCloud copy goes too."
        }
        if hasSealedBackup {
            scope += " Any encrypted iCloud backups go too."
        }
        // NOT "none of it can be recovered": local data is included in iOS device backups by default
        // (StoragePreferences.localBackupExcludedFromiOSBackup defaults to false, deliberately), so an
        // encrypted backup taken before today can still restore it. Fernlet cannot reach into that, and
        // an absolute permanence claim would be false for every user on the default setting.
        scope += " Fernlet can't undo this."

        var paragraphs = [scope]

        // A multi-device caveat, only when there is a day-blob copy in iCloud. Day records and custom
        // items keep no tombstones, so a device you are actively using can re-upload its most recent
        // days — and re-add the clothing designs it still holds — after the wipe reaches the cloud.
        // Say so rather than imply the cloud is instantly and permanently empty (owner decision
        // 2026-08-21: disclose these two, don't tombstone them).
        //
        // Two per-row stores are deliberately NOT in this sentence, because they genuinely resist it:
        // the coin ledger and — since 2026-08-21 — the milestone ledger both write a reset-boundary
        // marker at the wipe, and their aggregation voids every row from before it (milestones by day
        // AND instant, which is what also voids rows re-derived from a day that came back). Rows that
        // sync back from an offline device raise no balance and no lifetime count. Naming them here
        // would be the says-more-than-it-does gap in reverse: a survival that no longer happens.
        //
        // Two residuals keep that claim honest, both shared with the coin ledger and both written up
        // in Docs/PrivacyWipeCoverage.md: (1) the wipe DAY itself stays countable/earnable, so
        // same-day pre-wipe content re-synced from another device can re-derive on that one day —
        // voiding it instead would lock out genuine post-wipe care on the day the user wiped;
        // (2) if the marker's own write fails it lives only in an in-memory retry queue, so a process
        // death before it flushes loses the boundary silently. Neither is big enough to name in the
        // dialog — the user's data is deleted in both — but neither may be quietly forgotten either.
        if hasICloudDayCopy {
            paragraphs.append("""
                If you use Fernlet on another device, this reaches it the next time that device syncs — \
                and a device you're using right then may re-add its most recent days and any custom \
                clothing designs it still has.
                """)
        }

        // Blocks are NOT listed as kept. A block is a row in the trust vault (`blockedAt != nil`) and
        // the wipe clears the vault wholesale, so it is a CONSEQUENCE spelled out below, not a survivor.
        // What genuinely survives is the self-ban — Fernlet's own shop being barred for reported content —
        // which must outlive a wipe or "delete my data" becomes a way to launder it.
        //
        // The shared-photo wall is named in FULL — "the ones friends sent you and the ones you shared
        // with them" — not the narrower "photos friends sent you" it used to say. The cache holds BOTH
        // (a photo the user shared is cached under their own fingerprint), so the old copy disclosed
        // half of what survives. By product decision the wall has no bulk clear — pictures come off it
        // one at a time (`MeshNetworkManager.deletePhoto`) — so this funnel leaves the whole wall
        // intact and the copy says how to remove them, rather than implying they are gone.
        //
        // The Fernlet identity is NOT in the kept list any more. It used to be, and it was true then;
        // the wipe now destroys the proximity keypairs (`wipeIdentityForDeleteAll`, bitchat adoptions
        // Increment 1) precisely so a post-wipe "fresh start" isn't still recognizable to every
        // friend's trust vault. Saying it survives would be the same says-more-than-it-does gap this
        // dialog exists to close, in reverse — so the consequence is stated where the user needs it,
        // next to the re-add sentence that the vault clear already required.
        //
        // Milestone counts left the kept list on 2026-08-20 for the same reason, in the other
        // direction: the wipe now deletes the milestone ledger (delete-everything coverage round),
        // so naming it as a survivor would disclose a survival that no longer happens.
        paragraphs.append("""
            Kept on purpose: your shared photos — both the ones friends sent you and the ones you \
            shared with them — and any restriction on sharing your own designs. You remove photos \
            one at a time from the photo itself; there's no bulk delete. Your app lock stays set up. \
            This phone gets a brand-new Fernlet identity, so friends' phones won't recognize it: \
            you'll need to add each other again in person, and anyone you blocked will no longer be \
            blocked — block them again if you meet.
            """)
        paragraphs.append(healthParagraph(for: healthSamples))
        return paragraphs.joined(separator: "\n\n")
    }

    /// The closing Apple Health paragraph, one per ``HealthSampleOffer`` state.
    ///
    /// The toggle-off wording is the point of the split. The master switch being off does NOT retract
    /// what Fernlet already wrote, and the old copy — "turn Health back on to let Fernlet remove it" —
    /// sent that user to a switch they had deliberately turned off, for a deletion the app can perform
    /// without it. It now says that anything written before is still there and that Fernlet can still
    /// delete it, while naming the one case where it can't: share access revoked in the Health app,
    /// which the wipe reports as an incomplete store rather than swallowing.
    ///
    /// "Anything Fernlet wrote", never "the entries Fernlet wrote": the ledger behind this state records
    /// that a PROMPT was shown, not that a sample was written, so a user who was prompted and denied
    /// gets the offer with nothing behind it. The hedge is what keeps that dialog true.
    ///
    /// The no-record wording stays a hedge ("no record of writing"), never "Fernlet has never written
    /// anything": the ledger errs toward forgetting — an unreadable row reads as never-requested — so a
    /// flat denial would be the one sentence here that the code cannot back up.
    private static func healthParagraph(for offer: HealthSampleOffer) -> String {
        switch offer {
        case .integrationOn:
            return """
                Fernlet can also delete the entries it wrote to Apple Health. It can only ever delete its \
                own — everything else in Apple Health is yours to delete in the Health app.
                """
        case .integrationOff:
            return """
                Health is turned off in Fernlet, but anything Fernlet wrote to Apple Health before that is \
                still in Apple Health, and Fernlet can still delete it — you don't have to turn Health \
                back on. It can only ever delete its own; everything else in Apple Health is yours to \
                delete in the Health app. If you've taken Fernlet's Health access away since, it will say \
                so instead of claiming it's gone.
                """
        case .nothingAuthored:
            return """
                Fernlet has no record of writing anything to Apple Health, so it isn't offering to delete \
                from there. If it wrote entries on an earlier install, turn Health back on to let Fernlet \
                remove them, or delete them yourself in the Health app.
                """
        }
    }

    /// Shown when a wipe came back incomplete. Naming the store that failed is the point: "something went
    /// wrong" would leave the user unable to tell whether their journal is gone.
    ///
    /// The closing line deliberately does NOT promise that retrying fixes everything, and does not say
    /// the leftovers are "on your device". Both were true when every store was local; "hearts parked in
    /// iCloud" is neither — those records sit on a CloudKit public database, and once the wipe cleared
    /// the outbox the record names needed to delete them are gone, so a retry cannot reach them.
    ///
    /// They do NOT age out on their own. `HeartDropOutbox.entryLifetime` (14 days) is the SENDER's
    /// local outbox prune interval, not a server-side expiry, and on this path the wipe has already
    /// emptied that outbox — so the cleanup that would have deleted them can never run. The records
    /// remain sealed, unreadable ciphertext not linked to the user by name, which is what makes the
    /// residual acceptable rather than harmless. Privacy-Policy.md §12 states it the same way; do not
    /// re-introduce an auto-expiry claim here without changing the mechanism first.
    static func failureMessage(for outcome: FernletStore.DeleteAllOutcome) -> String {
        """
        Fernlet deleted everything it could, but couldn't finish: \
        \(ListFormatter.localizedString(byJoining: outcome.incompleteStores)). \
        Anything named there may still exist. Trying again can help for anything still on this phone.
        """
    }
}

/// A full-screen busy overlay shown while the "delete everything" wipe runs.
///
/// The wipe is multi-second (CloudKit + HealthKit deletes) and the destructive alert dismisses the
/// moment the user confirms, so without this the screen stays fully interactive: a second tap could
/// interleave a second wipe, or the user could log new data into a store mid-deletion. The dimmed
/// layer swallows taps; the caller (``SettingsSheet`` or ``PrivacyDataSettingsView``) also disables
/// the delete button and blocks dismissal while it is up.
struct DeletingEverythingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.20).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .tint(Color.moss)
                Text("Deleting everything…")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
            }
            .padding(20)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityIdentifier("deleteAll.spinner")
    }
}
