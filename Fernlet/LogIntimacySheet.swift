import SwiftUI
import FernletFoundation

struct LogIntimacySheet: View {
    @Environment(FernletLockService.self) private var lockService
    @Environment(StoragePreferencesStore.self) private var storagePreferencesStore
    @Environment(\.dismiss) private var dismiss

    @State private var eventDate = Date()
    @State private var note = ""
    @State private var protectionUsed: Bool?
    @State private var isSaving = false
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Log intimacy")
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(Color.bark)

                    SheetField("Date and time") {
                    DatePicker("Date and time", selection: $eventDate, in: ...Date())
                            .labelsHidden()
                            .tint(Color.moss)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
                }

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

                    Text("Add who was involved and any details you want to remember. This note stays encrypted on this device.")
                        .font(.caption)
                        .foregroundStyle(Color.slate)

                    SheetField("Apple Health") {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(
                                writesToHealthKit ? "Apple Health sync is on" : "Apple Health sync is off",
                                systemImage: writesToHealthKit ? "heart.text.square.fill" : "heart.slash"
                            )
                            .font(.callout.weight(.medium))
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
                                .font(.caption)
                                .foregroundStyle(Color.slate)
                                .fernletWrappingText()
                        }
                        .padding(14)
                        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.callout)
                            .foregroundStyle(Color.terracotta)
                            .fernletWrappingText()
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: isSaving ? "Saving" : "Save", disabled: isSaving) {
                Task { await save() }
            }
        }
        .background(Color.parchment)
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
        isSaving = true
        defer { isSaving = false }
        do {
            let repository = IntimacyLogRepository()
            let log = IntimacyLog(
                eventDate: eventDate,
                note: String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
            )
            try repository.insert(log, contentKey: lockService.contentKey())
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
                try repository.markSavedToHealthKit(id: log.id, externalUUID: externalUUID)
            } catch {
                statusMessage = "Private note saved, but Apple Health was not updated: \(error.localizedDescription)"
                try? await Task.sleep(for: .seconds(1.8))
            }
            dismiss()
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
