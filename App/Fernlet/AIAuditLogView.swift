// AIAuditLogView.swift
// The "what left my device" screen (AI Ladder §7.2): every AI call this device has made, read out
// of the device-local `AIAuditLog` ring buffer and rendered newest first.
//
// A pure READER. It never records, never updates an outcome, and never clears — "Delete everything"
// is the only eraser, and the log itself is written by the live AI call sites in `AIProviders` and
// the app target.
//
// THE PARKED-TOKEN CONTRACT (see `AIAuditLog.swift`, `AIAuditEntry.destinationParkedToken`): a
// destination or outcome written by a NEWER build freezes on decode to `.onDeviceFoundationModels` /
// `.succeeded` — the PRIVACY-WORST direction — with the true raw token parked beside it. So every
// display value on this screen is built by ``AIAuditRow``, which prefers the parked token whenever
// it is non-nil and renders it verbatim (a frozen token is never localized) under an honest
// "recorded by a newer version" note. Rendering the frozen enum instead would tell the user that a
// call which left the device stayed home — precisely the lie this log exists to prevent.

import SwiftUI
import AIContext
import FernletDomainModel
import FernletUI

// MARK: - Row model

/// One display value on an ``AIAuditRow``: plain language this build can name, or a raw token only a
/// newer build knows the meaning of.
///
/// The two cases are deliberately not collapsed into a single `String`: `.known` carries a
/// `LocalizedStringKey` (display text, which translates) while `.recorded` carries a frozen
/// persisted token (which never does, in any language). See the parked-token contract at the top of
/// this file.
enum AIAuditDisplayValue: Equatable {
    /// Plain language for a case this build knows.
    case known(LocalizedStringKey)
    /// The raw recorded token, shown exactly as it was written.
    case recorded(String)

    /// Whether this value is a raw token rather than copy Fernlet chose.
    var isRecordedToken: Bool {
        if case .recorded = self { return true }
        return false
    }
}

/// Whether a call's payload crossed the device boundary.
///
/// Three cases, not a `Bool`, because "this build cannot say" is a real and honest answer — see
/// ``unknown``.
enum AIAuditBoundary: Equatable {
    /// This build knows the destination, and that destination never leaves the device.
    case stayedOnDevice
    /// This build knows the destination, and data egressed to it.
    case leftDevice
    /// A newer build recorded the destination. Deliberately NOT folded into ``stayedOnDevice``: the
    /// tolerant decode already froze the unknown token to the on-device floor, so treating "unknown"
    /// as "stayed" would repeat the freeze default's privacy-worst understatement.
    case unknown
}

/// One row of the AI audit log, built from an ``AIAuditEntry`` by ``rows(from:)``.
///
/// A value type on purpose: the whole rendering decision — parked token vs frozen enum, plain
/// language vs verbatim token, on-device vs egress — is made here where `AIAuditLogScreenTests` can
/// pin it, and ``AIAuditLogView`` only lays the finished values out.
///
/// Metadata only, like the entry behind it: a field NAME list, never a field value.
struct AIAuditRow: Identifiable, Equatable {
    /// The entry's id, carried through so `ForEach` identifies rows without a per-render UUID.
    let id: UUID
    /// When the call was recorded.
    let timestamp: Date
    /// Which feature asked — plain language for a `payloadKind` this build knows.
    let kind: AIAuditDisplayValue
    /// Where the call went.
    let destination: AIAuditDisplayValue
    /// How the call turned out, failure states included.
    let outcome: AIAuditDisplayValue
    /// Whether the payload left the device; `.unknown` whenever a parked destination token is in play.
    let boundary: AIAuditBoundary
    /// The NAMES of the payload fields that were included. The log never holds their values.
    let includedFields: [String]
    /// Which model handled the call, when there is a single model to name.
    let modelIdentifier: String?
    /// Characters of filtered memory context injected into the call (0 when none).
    let memorySummaryCharCount: Int

    /// True when any value on this row is a raw recorded token rather than plain language — a
    /// destination/outcome parked by the tolerant decode, or a payload kind this build has no name
    /// for. Drives the row's "recorded by a newer version" note, so a verbatim token is never
    /// mistaken for wording Fernlet chose.
    var showsRecordedToken: Bool {
        kind.isRecordedToken || destination.isRecordedToken || outcome.isRecordedToken
    }

    /// Builds the screen's rows from the log's working set, newest first.
    ///
    /// Ties break on the entry's position in the log, so two calls recorded in the same instant keep
    /// their recorded order instead of shuffling under an unstable sort. The input is the capped
    /// ring buffer (≤ `AIAuditLog.entryLimit`), so the sort is bounded by construction (R2).
    static func rows(from entries: [AIAuditEntry]) -> [AIAuditRow] {
        guard entries.isEmpty == false else { return [] }
        let ordered = entries.enumerated().sorted { lhs, rhs in
            lhs.element.timestamp == rhs.element.timestamp
                ? lhs.offset > rhs.offset
                : lhs.element.timestamp > rhs.element.timestamp
        }
        return ordered.map { row(for: $0.element) }
    }

    private static func row(for entry: AIAuditEntry) -> AIAuditRow {
        AIAuditRow(
            id: entry.id,
            timestamp: entry.timestamp,
            kind: kindDisplay(entry.payloadKind),
            destination: destinationDisplay(entry),
            outcome: outcomeDisplay(entry),
            boundary: boundary(for: entry),
            includedFields: entry.includedFields,
            modelIdentifier: entry.modelIdentifier,
            memorySummaryCharCount: entry.memorySummaryCharCount
        )
    }

    /// THE CONTRACT, one line of it: a parked token always wins over the frozen enum. Without this
    /// branch an unknown future destination would render as "On-device model", because that is what
    /// the tolerant decode froze it to.
    private static func destinationDisplay(_ entry: AIAuditEntry) -> AIAuditDisplayValue {
        if let parkedToken = entry.destinationParkedToken { return .recorded(parkedToken) }
        switch entry.destination {
        case .onDeviceFoundationModels: return .known("On-device model")
        case .webNutritionLookup: return .known("Web nutrition search")
        case .privateCloudCompute: return .known("Apple Private Cloud Compute")
        case .externalAnthropic: return .known("Anthropic, with your own key")
        case .externalOpenAICompatible: return .known("Your own provider endpoint")
        }
    }

    /// The same contract for the outcome: an unknown future outcome froze to `.succeeded`, so the
    /// parked token is the only honest thing to show.
    private static func outcomeDisplay(_ entry: AIAuditEntry) -> AIAuditDisplayValue {
        if let parkedToken = entry.outcomeParkedToken { return .recorded(parkedToken) }
        switch entry.outcome {
        case .succeeded: return .known("Completed")
        case .fellBack: return .known("No usable answer — Fernlet used its own logic")
        case .refused: return .known("Declined by the model")
        case .schemaFailed: return .known("Unusable answer — discarded")
        }
    }

    /// A parked destination token means this build genuinely does not know whether the call
    /// egressed, and says so rather than inheriting the frozen on-device floor.
    private static func boundary(for entry: AIAuditEntry) -> AIAuditBoundary {
        guard entry.destinationParkedToken == nil else { return .unknown }
        return entry.destination.leavesDevice ? .leftDevice : .stayedOnDevice
    }

    /// Plain language per `AIContextPayload.payloadKind`. The kinds are frozen English tokens
    /// (never localize one), so this is the same token → display fork the rest of the app uses; a
    /// kind this build has no name for renders verbatim.
    private static func kindDisplay(_ payloadKind: String) -> AIAuditDisplayValue {
        guard payloadKind.isEmpty == false else { return .known("Not recorded") }
        switch payloadKind {
        case "food-selection": return .known("Food match")
        case "meal-decomposition": return .known("Meal breakdown")
        case "web-nutrition": return .known("Nutrition web search")
        case "web-nutrition-extraction": return .known("Reading a nutrition page")
        case "day-summary": return .known("Day summary")
        case "companion-thought": return .known("Companion thought")
        case "workout-adjustment": return .known("Workout adjustment")
        case "ingredient-substitution": return .known("Ingredient substitution")
        case "recipe-extraction": return .known("Reading a recipe page")
        default: return .recorded(payloadKind)
        }
    }
}

// MARK: - Screen

/// The AI activity log screen: every AI call this device has made, newest first.
///
/// Pushed from ``SettingsSheet`` via `SettingsRoute.aiAuditLog`. Calm disclosure, not a scoreboard:
/// it counts nothing, grades nothing, and congratulates no one — it lists what happened.
///
/// Reads ``AIAuditLog`` (an `actor`) exactly once per push, from `.task` into `@State`, so the
/// actor hop never happens on the main thread's critical path and a re-render never re-reads.
/// `rows == nil` is the in-flight state, kept distinct from `rows == []` so a log that is still
/// loading is never drawn as a log that is empty.
struct AIAuditLogView: View {
    /// The log to read. The process-wide `AIAuditLog.shared` in the app; injectable for previews.
    var log: AIAuditLog = .shared
    /// The loaded rows; `nil` while the first read is in flight.
    @State private var rows: [AIAuditRow]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                callsSection
            }
            .padding(20)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Color.parchment)
        .navigationTitle("AI activity log")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadRows() }
    }

    /// The standing disclosure: what this log is, what it cannot contain, and how it ends.
    private var headerCard: some View {
        FernletScrollSection("What this is") {
            VStack(alignment: .leading, spacing: 8) {
                disclosureLine("Every AI call this device has made, newest first.")
                disclosureLine("Fernlet records metadata only: which feature asked, where the call went, when, how it turned out, and the names of the fields that were sent — never your words, your entries, or the model's reply.")
                disclosureLine("This log stays on this device. It is never synced to iCloud, is kept out of your device backup, and is never part of a data export. “Delete everything” erases it.")
                disclosureLine("Fernlet keeps the most recent \(AIAuditLog.entryLimit) calls.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func disclosureLine(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.fernlet(.bodySmall))
            .foregroundStyle(Color.slate)
            .fernletWrappingText()
    }

    /// The list itself: loading, the quiet empty line, or one card per call.
    @ViewBuilder
    private var callsSection: some View {
        SectionLabel("Calls")
        if let rows {
            if rows.isEmpty {
                FernletCard { EmptyState(text: "No AI calls have been made from this device.") }
                    .accessibilityIdentifier("aiAuditLog.empty")
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { callCard($0) }
                }
            }
        } else {
            FernletCard { EmptyState(text: "Loading AI activity…") }
        }
    }

    /// One call: what kind, where it went, how it turned out, and the field names sent.
    private func callCard(_ row: AIAuditRow) -> some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 6) {
                callHeadline(row)
                boundaryBadge(row.boundary)
                detailRow("Sent to", row.destination)
                detailRow("Result", row.outcome)
                fieldsLine(row)
                provenanceLines(row)
                if row.showsRecordedToken { recordedTokenNote }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The kind, with the timestamp trailing it — the same abbreviated date + time the Connection
    /// History screen next door uses.
    private func callHeadline(_ row: AIAuditRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            valueText(row.kind)
                .font(.fernlet(.headerMedium))
                .foregroundStyle(Color.bark)
            Spacer(minLength: 8)
            Text(row.timestamp.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
        }
    }

    private func detailRow(_ label: LocalizedStringKey, _ value: AIAuditDisplayValue) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
            valueText(value)
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
            Spacer(minLength: 0)
        }
    }

    /// A display value as `Text`: a known case localizes, a recorded token renders verbatim.
    private func valueText(_ value: AIAuditDisplayValue) -> Text {
        switch value {
        case .known(let key): return Text(key)
        case .recorded(let token): return Text(verbatim: token)
        }
    }

    @ViewBuilder
    private func boundaryBadge(_ boundary: AIAuditBoundary) -> some View {
        switch boundary {
        case .stayedOnDevice: badge("Stayed on this device", Color.moss)
        case .leftDevice: badge("Left this device", Color.terracotta)
        case .unknown: badge("This version can't say where this went", Color.terracotta)
        }
    }

    private func badge(_ title: LocalizedStringKey, _ tint: Color) -> some View {
        Text(title)
            .font(.fernlet(.labelSmall))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }

    /// The field NAMES that went with the call. The line says "names only" because that is the whole
    /// promise: the log has never held a field's value.
    @ViewBuilder
    private func fieldsLine(_ row: AIAuditRow) -> some View {
        if row.includedFields.isEmpty {
            supportingLine("No fields were recorded for this call.")
        } else {
            supportingLine("Fields sent, names only: \(row.includedFields.joined(separator: ", "))")
        }
    }

    /// The two optional metadata lines: which model handled it, and how much memory context rode
    /// along (a character count, never the text).
    @ViewBuilder
    private func provenanceLines(_ row: AIAuditRow) -> some View {
        if let modelIdentifier = row.modelIdentifier {
            supportingLine("Model: \(modelIdentifier)")
        }
        if row.memorySummaryCharCount > 0 {
            supportingLine("Memory context: \(row.memorySummaryCharCount) characters")
        }
    }

    private func supportingLine(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.fernlet(.labelSmall))
            .foregroundStyle(Color.slate)
            .fernletWrappingText()
    }

    /// The honest note beside a verbatim token — see the parked-token contract at the top of this file.
    private var recordedTokenNote: some View {
        Text("Recorded by a newer version of Fernlet. Shown exactly as it was recorded, because this version has no name for it.")
            .font(.fernlet(.labelSmall))
            .foregroundStyle(Color.terracotta)
            .fernletWrappingText()
    }

    /// Reads the actor's working set once per push. The `guard` makes it once per push rather than
    /// once per `.task` re-run, and the read is an `await` off the main thread's critical path.
    private func loadRows() async {
        guard rows == nil else { return }
        let entries = await log.entries
        rows = AIAuditRow.rows(from: entries)
    }
}

#Preview {
    NavigationStack { AIAuditLogView(log: AIAuditLog()) }
}
