import SwiftUI
import FernletFoundation

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

    /// Builds the dialog. `canDeleteHealthSamples` decides whether the user is offered the SECOND
    /// destructive button — pass the live `healthKitMasterEnabled` preference. When Health was never
    /// turned on there is nothing Fernlet could have written, so the question would be noise.
    ///
    /// `onFinished` receives the outcome so the caller can surface a partial failure. Every layer of the
    /// delete is best-effort; the caller must not assume success just because the dialog was confirmed.
    static func make(
        canDeleteHealthSamples: Bool,
        hasCloudCopy: Bool,
        delete: @escaping (Bool) async -> FernletStore.DeleteAllOutcome,
        onFinished: @escaping (FernletStore.DeleteAllOutcome) -> Void
    ) -> DestructiveConfirmation {
        DestructiveConfirmation(
            title: "Delete everything?",
            message: message(canDeleteHealthSamples: canDeleteHealthSamples, hasCloudCopy: hasCloudCopy),
            confirmLabel: canDeleteHealthSamples ? "Delete, keep Health" : "Delete",
            auditEvent: "settings.deleteAll.confirmed",
            secondaryConfirm: canDeleteHealthSamples
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
    private static func message(canDeleteHealthSamples: Bool, hasCloudCopy: Bool) -> String {
        var scope = """
            This deletes your logged days, meals and photos, journal entries, cycle notes, intimate logs, \
            Worry Box notes, saved recipes, custom items and coins.
            """
        if hasCloudCopy {
            scope += " Your iCloud copy and any encrypted iCloud backups go too, as this device syncs."
        }
        // NOT "none of it can be recovered": local data is included in iOS device backups by default
        // (StoragePreferences.localBackupExcludedFromiOSBackup defaults to false, deliberately), so an
        // encrypted backup taken before today can still restore it. Fernlet cannot reach into that, and
        // an absolute permanence claim would be false for every user on the default setting.
        scope += " Fernlet can't undo this."

        var paragraphs = [
            scope,
            // Blocks are NOT listed here. A block is a row in the trust vault (`blockedAt != nil`) and
            // the wipe clears the vault wholesale, so claiming blocks are kept would be false. What
            // genuinely survives is the self-ban — Fernlet's own shop being barred for reported content —
            // which must outlive a wipe or "delete my data" becomes a way to launder it.
            """
            Kept on purpose: your milestone counts, your lifetime care history, your Fernlet identity, \
            photos friends sent you, and any restriction on sharing your own designs. Your app lock stays \
            set up. You'll need to add your friends again.
            """
        ]
        if canDeleteHealthSamples {
            paragraphs.append(
                """
                Fernlet can also delete the entries it wrote to Apple Health. It can only ever delete its \
                own — everything else in Apple Health is yours to delete in the Health app.
                """
            )
        } else {
            // The master switch being off does NOT retract what Fernlet already wrote. Saying nothing
            // would leave those samples in Apple Health with the user believing everything was deleted.
            paragraphs.append(
                """
                Anything Fernlet previously wrote to Apple Health stays there. Turn Health back on to let \
                Fernlet remove it, or delete it yourself in the Health app.
                """
            )
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// Shown when a wipe came back incomplete. Naming the store that failed is the point: "something went
    /// wrong" would leave the user unable to tell whether their journal is gone.
    static func failureMessage(for outcome: FernletStore.DeleteAllOutcome) -> String {
        """
        Fernlet deleted everything it could, but couldn't finish: \
        \(ListFormatter.localizedString(byJoining: outcome.incompleteStores)). \
        Try again — if it keeps failing, this data may still be on your device.
        """
    }
}
