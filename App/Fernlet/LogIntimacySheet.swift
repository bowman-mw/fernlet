import SwiftUI
import FernletFoundation
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
/// sheet surfaces as a gentle explanation instead of a raw error string. A HealthKit write failure
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

    /// Whether the sheet holds anything a swipe-down would throw away.
    private var isDirty: Bool {
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || protectionUsed != nil
            || dateAdjusted
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    dateField
                    noteField

                    Text("Add who was involved and any details you want to remember. This note stays encrypted on this device.")
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)

                    appleHealthField
                    statusText
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: isSaving ? "Saving" : "Save", disabled: isSaving) {
                Task { await save() }
            }
        }
        .background(Color.parchment)
        // A swipe-down used to throw away a typed private note with no warning. The guard also
        // renders the pinned template header (Cancel + title).
        .fernletDraftGuard(isDirty: isDirty, title: "Log intimacy") { dismiss() }
        // Capture FRICTION (never a security control), attached at the sheet TYPE — presented
        // from the root router, so protection engages regardless of the tab beneath it.
        .captureProtected(surface: "logIntimacy")
    }

    /// The event's date and time, never in the future.
    private var dateField: some View {
        SheetField("Date and time") {
            DatePicker("Date and time", selection: $eventDate, in: ...Date())
                .labelsHidden()
                .onChange(of: eventDate) { _, _ in dateAdjusted = true }
                .tint(Color.moss)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
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
                Label(
                    writesToHealthKit ? "Apple Health sync is on" : "Apple Health sync is off",
                    systemImage: writesToHealthKit ? "heart.text.square.fill" : "heart.slash"
                )
                .font(.fernlet(.label))
                .foregroundStyle(writesToHealthKit ? Color.moss : Color.slate)

                if writesToHealthKit {
                    FlowLayout(spacing: 8) {
                        Button("Not specified") { protectionUsed = nil }
                            .buttonStyle(ChipButtonStyle(selected: protectionUsed == nil))
                        Button("Protection used") { protectionUsed = true }
                            .buttonStyle(ChipButtonStyle(selected: protectionUsed == true))
                        Button("No protection") { protectionUsed = false }
                            .buttonStyle(ChipButtonStyle(selected: protectionUsed == false))
                    }
                }

                Text(healthKitSummary)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            // Full width like the date and note fields above it — the card used to hug its text and
            // stop short of the right edge.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
        }
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

    private var writesToHealthKit: Bool {
        storagePreferencesStore.preferences.healthKitMasterEnabled
            && (storagePreferencesStore.preferences.healthKitCapabilityEnabled[HealthCapability.intimateLogging.rawValue] ?? false)
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
            do {
                try await HealthKitService(preferencesStore: storagePreferencesStore).saveIntimacyEvent(
                    date: eventDate,
                    protectionUsed: protectionUsed,
                    externalUUID: externalUUID
                )
                try intimacyStore.markSavedToHealthKit(id: log.id, externalUUID: externalUUID)
            } catch {
                statusMessage = "Private note saved, but Apple Health was not updated: \(error.localizedDescription)"
                // Cancelled: the sheet is already gone; the note is saved either way.
                do { try await Task.sleep(for: .seconds(1.8)) } catch { return }
            }
            dismiss()
        } catch is IntimacyTrackingHiddenError {
            // The derived gate flipped to hidden while this sheet was open (a Settings toggle or a
            // profile edit mid-session) and the funnel refused the seal. A raw Foundation error string
            // would be alarming here — say what happened gently instead.
            statusMessage = "Intimacy tracking was just hidden in Settings, so this entry wasn't saved. You can turn it back on any time to keep logging."
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
