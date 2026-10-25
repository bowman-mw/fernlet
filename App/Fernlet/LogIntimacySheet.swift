import SwiftUI
import FernletFoundation
import FernletCrypto
import FernletDomainModel
import FernletLock
import PrivateHealthStore
import HealthKitGateway
import FernletUI

/// The intimacy log sheet: an event date, an encrypted private note, and — when Apple Health sync
/// is enabled for intimate logging — an optional protection-used status.
///
/// The note is sealed on-device through `IntimacyLogStore` and never leaves the app; only the
/// event date and protection status go to HealthKit, and only when both the master toggle and the
/// intimate-logging capability are on in `StoragePreferencesStore`. Saving while the derived
/// intimacy-tracking gate has flipped to hidden throws `IntimacyTrackingHiddenError`, which the
/// sheet surfaces as a gentle explanation instead of a raw error string — as does a seal that
/// refuses for want of an install binding
/// (``ColumnCrypto/SealedColumnStrictSealError/bindingUnavailable``). A HealthKit write failure
/// after a successful seal is reported but never blocks the local save. Chrome is the 2026-08-21
/// template: the draft-guard header carries Cancel and the title; Save commits bottom-right.
struct LogIntimacySheet: View {
    /// The gated funnel for the sealed-note write. Reaches the same fail-closed decrypt/seam gate the
    /// calendar reads through, so a save while intimacy is hidden throws instead of sealing a new row.
    let intimacyStore: IntimacyLogStore
    @Environment(FernletLockService.self) private var lockService
    @Environment(StoragePreferencesStore.self) private var storagePreferencesStore
    @Environment(\.dismiss) private var dismiss

    @State private var eventDate = Date()
    /// Whether the user moved the date off "now". The seed is a live `Date()`, so this flag — not a
    /// value comparison — is what tells an adjusted date from an untouched one.
    @State private var dateAdjusted = false
    @State private var note = ""
    @State private var protectionUsed: Bool?
    @State private var isSaving = false
    @State private var statusMessage: String?
    /// Set when the sealed note WAS written but Apple Health refused the companion sample.
    ///
    /// That sentence used to show for 1.8 s and then dismiss itself, which is a window a VoiceOver
    /// user cannot win: focus is elsewhere, nothing is spoken, and the sheet is gone. The sheet now
    /// stays open and says it out loud.
    ///
    /// Staying open FREEZES the sheet: the fields go `disabled`, so there are no post-write edits
    /// for a swipe-down to discard (which is why `isDirty` may honestly report false), and the
    /// commit bar becomes a plain Done. Re-arming Save would be worse than the bug it fixes —
    /// `IntimacyLogStore.insert` appends, so a second commit seals a duplicate event rather than
    /// amending the one already written.
    @State private var savedWithCaveat = false

    /// Whether the sheet holds anything a swipe-down would throw away. Nothing, once the note has
    /// been sealed — see ``savedWithCaveat``.
    private var isDirty: Bool {
        guard !savedWithCaveat else { return false }
        return !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || protectionUsed != nil
            || dateAdjusted
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // Frozen once the note is sealed — see ``savedWithCaveat``. `statusText` stays
                    // outside the disabled group: the caveat sentence is why the sheet stayed open.
                    Group {
                        dateField
                        noteField

                        // World (b3-log-intimacy): the encryption note as a framed notice with a pixel lock.
                        FernletNotice(text: Text("Add who was involved and any details you want to remember. This note stays encrypted on this device.")) {
                            FernletIcon(.lock, scale: 2)
                        }

                        appleHealthField
                    }
                    .disabled(savedWithCaveat)

                    statusText
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: saveLabel, disabled: isSaving) {
                // The note is already sealed on the caveat path, so the bar closes the sheet rather
                // than offering a second write of the same event.
                if savedWithCaveat { dismiss() } else { Task { await save() } }
            }
        }
        .fernletSheetStyle()
        // A swipe-down used to throw away a typed private note with no warning. The guard also
        // renders the pinned template header (Cancel + title).
        .fernletDraftGuard(isDirty: isDirty, title: "Log intimacy") { dismiss() }
        // Capture FRICTION (never a security control), attached at the sheet TYPE — presented
        // from the root router, so protection engages regardless of the tab beneath it.
        .captureProtected(surface: "logIntimacy")
    }

    /// The event's date and time, never in the future: the framed two-half button (`ref-int-date`,
    /// `ref-int-time`) under its section label, the date opening iOS's calendar and the time its wheels.
    /// Apple Health gets the picked date and time (``save()`` writes `eventDate`).
    private var dateField: some View {
        SheetField("Date and time") {
            PrivateDateTimeButton(date: $eventDate, latest: Date())
                .onChange(of: eventDate) { _, _ in dateAdjusted = true }
        }
    }

    /// The sealed note, capped at 2000 characters where the text enters.
    private var noteField: some View {
        SheetField("Private note") {
            SheetTextEditor(
                text: Binding(
                    get: { note },
                    set: { note = String($0.prefix(2000)) }
                ),
                placeholder: "Who was involved? Anything important to remember?",
                minHeight: 180
            )
        }
    }

    /// The Apple Health card: sync status, the protection chips (only when syncing), and what the
    /// sync does and does not send.
    private var appleHealthField: some View {
        SheetField("Apple Health") {
            VStack(alignment: .leading, spacing: 10) {
                // World (b3-log-intimacy): the pixel heart beside the sync state.
                Label {
                    Text(writesToHealthKit ? "Apple Health sync is on" : "Apple Health sync is off")
                } icon: {
                    WorldSpriteView(sprite: WorldSprites.heartSm, scale: 2,
                                    tint: writesToHealthKit ? nil : WorldPalette.dim)
                }
                .font(FernletFramedFont.rowTitleBold)
                .foregroundStyle(writesToHealthKit ? WorldPalette.mossInk : WorldPalette.dim)

                if writesToHealthKit {
                    FlowLayout(spacing: 8) {
                        // B6: a real change ticks (haptics only, as everywhere on this surface).
                        Button("Not specified") { FernletFeedback.system.select(nil, in: &protectionUsed) }
                            .buttonStyle(ChipButtonStyle(selected: protectionUsed == nil))
                        Button("Protection used") { FernletFeedback.system.select(true, in: &protectionUsed) }
                            .buttonStyle(ChipButtonStyle(selected: protectionUsed == true))
                        Button("No protection") { FernletFeedback.system.select(false, in: &protectionUsed) }
                            .buttonStyle(ChipButtonStyle(selected: protectionUsed == false))
                    }
                }

                Text(healthKitSummary)
                    .font(FernletFramedFont.field)
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
            }
            // Full width like the date and note fields above it — the card used to hug its text and
            // stop short of the right edge.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            // World: the framed card of the design language.
            .fernletFramed(WorldTheme.framedLook, fill: WorldPalette.paper, cornerRadius: FernletFramedLook.cardRadius)
        }
    }

    /// What the commit bar says: Done once the note is sealed and only the Health half fell short.
    private var saveLabel: LocalizedStringKey {
        if savedWithCaveat { return "Done" }
        return isSaving ? "Saving" : "Save"
    }

    /// The save outcome, when there is something to say.
    @ViewBuilder
    private var statusText: some View {
        if let statusMessage {
            Text(statusMessage)
                .font(.fernlet(.body))
                .foregroundStyle(Color.terracotta)
                .fernletWrappingText()
        }
    }

    /// Whether this save will also go to Apple Health — the gateway's own write-sharing rule
    /// (``HealthKitService/isWriteSharingEnabled(for:in:)``) over the observable preferences, so the
    /// "sync is on/off" card can never disagree with what the write gate does. It used to restate
    /// the rule by hand here, without the gate's device check.
    private var writesToHealthKit: Bool {
        HealthKitService.isWriteSharingEnabled(for: .intimateLogging, in: storagePreferencesStore.preferences)
    }

    private var healthKitSummary: String {
        if writesToHealthKit {
            return "The event date and optional protection status will be saved to Apple Health. Your private note is never sent."
        }
        return "This entry stays in Fernlet only. Apple Health sync can be changed in Privacy & Data settings."
    }

    private func save() async {
        // Single-flight: the save bar is disabled while saving, but the entry point states it too so
        // a double invocation can never seal two rows for one sheet.
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let log = IntimacyLog(
                eventDate: eventDate,
                note: String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
            )
            try intimacyStore.insert(log, contentKey: lockService.contentKey(for: .privateHub))
            guard writesToHealthKit else {
                dismiss()
                return
            }

            let externalUUID = UUID()
            let healthOutcome = await IntimacyHealthWrite.run(
                save: {
                    try await HealthKitService(preferencesStore: storagePreferencesStore).saveIntimacyEvent(
                        date: eventDate,
                        protectionUsed: protectionUsed,
                        externalUUID: externalUUID
                    )
                },
                link: { try intimacyStore.markSavedToHealthKit(id: log.id, externalUUID: externalUUID) }
            )
            guard let caveat = healthOutcome.caveat else {
                dismiss()
                return
            }
            // The note IS sealed; only part of the Health half went wrong. Say exactly which part and
            // STAY — the sentence is the whole point of the branch, and a 1.8 s window with the cursor
            // elsewhere is not a way of telling anyone anything. `.success`: the sealed note is on disk.
            // B9: felt as a caveat beside the sentence — haptics only, and no content.
            savedWithCaveat = true
            FernletFeedback.system.play(.caveat)
            report(caveat, kind: .success)
        } catch is IntimacyTrackingHiddenError {
            // The derived gate flipped to hidden while this sheet was open (a Settings toggle or a
            // profile edit mid-session) and the funnel refused the seal. A raw Foundation error string
            // would be alarming here — say what happened gently instead.
            //
            // NOTHING was written on this path, so the sheet deliberately does NOT dismiss and
            // `savedWithCaveat` stays false: the typed note is still only in this sheet, Save is
            // still the honest verb for the bar, and the draft guard still stands between the note
            // and a swipe-down. What was missing is that none of it was ever spoken.
            report(String(localized: "Intimacy tracking was just hidden in Settings, so this entry wasn't saved. You can turn it back on any time to keep logging."),
                   kind: .error)
        } catch ColumnCrypto.SealedColumnStrictSealError.bindingUnavailable {
            // The one seal entry refused: this install's device binding was unreadable at the moment
            // of the write, so the device-bound blob could not be minted. Owner decision D4 made this
            // reachable — the writer used to fall open to an un-domained legacy blob here and the save
            // simply succeeded — and `ColumnCrypto.SealedColumnStrictSealError` is `Error, Equatable`
            // only, with no `LocalizedError` anywhere, so the generic catch below both RENDERED and
            // SPOKE Foundation's default: "The operation couldn't be completed", followed by the
            // type's own name and a case number.
            //
            // Nothing was written on this path — the seal precedes the HealthKit half — so the sheet
            // stays open exactly as the hidden-gate branch above does. The sentence leads with the
            // question anyone actually has after a failed save (is what I typed gone?) and only then
            // says what to do, because the note is still in this sheet's state and a retry is the
            // whole recovery.
            report(String(localized: "This device couldn't encrypt your note just now, so nothing was saved. Your note is still here, so you can try saving again in a moment."),
                   kind: .error)
        } catch {
            report(error.localizedDescription, kind: .error)
        }
    }

    /// Publishes a save outcome: renders the sentence and speaks it once.
    ///
    /// **Privacy:** the outcome only. The note itself is sealed, device-only, and behind the app
    /// lock; an announcement is spoken aloud to whoever is within earshot.
    ///
    /// - Parameters:
    ///   - message: The already-localized outcome sentence — never the note itself.
    ///   - kind: `.error` when nothing was written at all; `.status` (the default) for a save that
    ///     landed with a caveat the user still has to read.
    private func report(_ message: String, kind: FernletAnnouncementKind = .status) {
        statusMessage = message
        // A6, as on the period sheet: the error haptic beside an error. Haptics only, no content.
        if kind == .error { FernletFeedback.system.play(.failed) }
        FernletAnnouncer.system.announce(kind, resolved: message)
    }
}

/// The Health half of an intimacy save, judged in two steps so the sheet says which one failed.
///
/// The sample write and the local link mark (`IntimacyLogStore.markSavedToHealthKit`) used to share
/// one `catch`. A sample that landed in Apple Health, followed by a link mark that threw, read as
/// "Apple Health was not updated", which was false: the sample was there, and what Fernlet lost was
/// only its own record of it (the "Saved to Apple Health" line on the day's detail page). The two
/// failures are told apart here, and only a sample that actually failed says Health was not updated.
///
/// Pure over its two closures, so the decision is testable without HealthKit or a sealed store.
enum IntimacyHealthWrite {

    /// What the Health half did, with the sentence the sheet shows for each partial outcome.
    enum Outcome: Equatable {
        /// The sample landed and the sealed row now carries its Health link.
        case saved
        /// The sample did not land, so Apple Health was not updated. Carries the error's description.
        case healthNotUpdated(reason: String)
        /// The sample landed, but the local link mark threw: Apple Health has the event, and the
        /// sealed row will not show "Saved to Apple Health".
        case savedButUnlinked

        /// The caveat sentence for a partial outcome; nil when everything landed.
        var caveat: String? {
            switch self {
            case .saved:
                return nil
            case .healthNotUpdated(let reason):
                return String(localized: "Private note saved, but Apple Health was not updated: \(reason)")
            case .savedButUnlinked:
                return String(
                    localized: "intimacy.save.healthSavedLinkFailed",
                    defaultValue: "Private note saved and sent to Apple Health. Fernlet couldn't record that link, so this entry won't show “Saved to Apple Health”.",
                    comment: "Shown after an intimacy log was sealed and its Apple Health sample was written, but Fernlet failed to mark its own row as saved to Health. Both saves happened; only the label on the day's detail page will be missing."
                )
            }
        }
    }

    /// Writes the sample, then marks the link — the mark runs only after the sample landed.
    ///
    /// - Parameters:
    ///   - save: The Apple Health sample write.
    ///   - link: Records the sample's external UUID on the sealed row.
    /// - Returns: Which of the three outcomes happened.
    static func run(save: () async throws -> Void, link: () throws -> Void) async -> Outcome {
        do {
            try await save()
        } catch {
            return .healthNotUpdated(reason: error.localizedDescription)
        }
        do {
            try link()
        } catch {
            FernletAuditLog.log("intimacy.healthLink.failed", context: ["error": "\(type(of: error))"])
            return .savedButUnlinked
        }
        return .saved
    }
}
