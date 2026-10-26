//
//  FirstAidView.swift
//  Fernlet
//
//  A calm, low-stimulation "first aid" sheet: slow breathing, 5-4-3-2-1 grounding, the
//  Worry Box, and a static gentle-support row (a region-appropriate crisis line). Always
//  reachable — from the Home affordance near the companion, the body-signals explainer,
//  and the gentle offer card.
//  The support row is deliberately static and always visible; it is NOT the deferred
//  extended-low-mood auto-nudge.
//

import SwiftUI
import FernletDomainModel
import FernletFoundation
import HealthKitGateway
import FernletUI

/// The tools the First Aid sheet can open directly (e.g. from a gentle offer card).
///
/// Doubles as ``FirstAidView``'s navigation-path element: the menu pushes one of these, and
/// `initialTool` deep-links straight onto a tool when a caller opened the sheet for it.
enum FirstAidTool: String, Hashable {
    case breathing
    case grounding
    case worryBox
}

/// The calm, low-stimulation "first aid" menu sheet: slow breathing, 5-4-3-2-1 grounding, the
/// Worry Box entry flow, and a static gentle-support row carrying the crisis line for the
/// device's region (``CrisisSupportCard``, shared with Settings → Safety & reporting).
///
/// Presented by ContentView from the Home affordance near the companion, the body-signals
/// explainer (``StressExplainerSheet``), and the gentle offer card; `initialTool` lets those
/// callers land directly on one tool. Tools push via a ``FirstAidTool`` navigation path into
/// ``BreathingExerciseView``, ``GroundingView``, and ``WorryEntryView``. A read-only menu under
/// the 2026-08-21 template: Done sits top-right in the pinned header — rendered on the menu root
/// only, never on pushed tools — and is the whole exit. The support row is
/// deliberately static and always visible — it is NOT the deferred extended-low-mood auto-nudge —
/// and a completed breathing session is counted in the milestone ledger and quietly offered to
/// Apple Health (every consent gate is enforced inside `saveMindfulSession`; a closed gate or
/// failed write stays silent).
struct FirstAidView: View {
    var store: FernletStore
    var worryBox: WorryBoxService
    /// When set, the sheet opens straight onto this tool (offer cards deep-link here).
    var initialTool: FirstAidTool? = nil
    @Environment(StoragePreferencesStore.self) private var storagePreferencesStore
    @Environment(\.dismiss) private var dismiss
    @State private var path: [FirstAidTool] = []

    var body: some View {
        NavigationStack(path: $path) {
            // The pinned header lives on the menu ROOT only — pushed tool screens replace this
            // whole VStack, so they never carry the sheet's Done.
            VStack(spacing: 0) {
                SheetHeader(title: "First aid", onDone: { dismiss() })
                ScrollView {
                    VStack(alignment: .leading, spacing: FernletMetrics.spaceLg) {
                        strapline
                        toolList
                        CrisisSupportCard(identifierPrefix: "firstAid.support")
                    }
                    .padding(.horizontal, FernletMetrics.spaceLg)
                    .padding(.top, FernletMetrics.spaceSm)
                    .padding(.bottom, FernletMetrics.spaceXl)
                }
            }
            // World (b3-first-aid): the sheet's paper; the tools push pages with their own header
            // (``FirstAidToolHeader``) in place of the navigation bar.
            .fernletSheetStyle()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: FirstAidTool.self) { tool in
                switch tool {
                case .breathing:
                    BreathingExerciseView(onSessionComplete: handleBreathingComplete)
                case .grounding:
                    GroundingView()
                case .worryBox:
                    WorryEntryView(worryBox: worryBox)
                }
            }
        }
        .onAppear {
            if let initialTool, path.isEmpty {
                path.append(initialTool)
            }
        }
    }

    /// The Instrument Serif strapline — the first content line under the pinned header.
    private var strapline: some View {
        // World (b3-first-aid): the strapline in Fraunces, the design language's one serif.
        Text("Small tools for a heavy moment. Pick whatever feels kind — or nothing at all.")
            .font(.custom(FernletFontName.frauncesSemiBold, size: 22, relativeTo: .title2))
            .foregroundStyle(WorldPalette.bark)
            .lineSpacing(3)
            .fernletWrappingText()
    }

    /// The three tool cards, in the menu's fixed order: breathing, grounding, worry box.
    private var toolList: some View {
        VStack(spacing: 12) {
            // World (b3-first-aid): framed rows with the pixel breathe, target and box.
            toolCard(
                .breathing,
                sprite: WorldSprites.breathe,
                title: "Slow breathing",
                caption: "A quiet minute or three with a slowly swelling circle."
            )
            toolCard(
                .grounding,
                sprite: WorldSprites.target,
                title: "5·4·3·2·1 grounding",
                caption: "Arrive back in the room, one gentle sense at a time."
            )
            toolCard(
                .worryBox,
                sprite: WorldSprites.box,
                title: "Worry box",
                caption: "Write a worry down and let the box hold it for a while."
            )
        }
    }

    /// One tool card. `title` and `caption` are `LocalizedStringKey` so the three cards' literals reach
    /// the catalog; as `String` they bound `Text`'s verbatim initializer and were never harvested.
    private func toolCard(_ tool: FirstAidTool, sprite: WorldSprite, title: LocalizedStringKey, caption: LocalizedStringKey) -> some View {
        Button {
            path.append(tool)
        } label: {
            FirstAidToolCardLabel(sprite: sprite, title: title, caption: caption)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("firstAid.tool.\(tool.rawValue)")
        // Voice Control: the card is named by its title and caption together; the title is what a
        // user says. "5·4·3·2·1 grounding" also answers to the plain word, since a run of spoken
        // digits is not something dictation reliably turns back into that title.
        .accessibilityInputLabels(tool == .grounding ? [Text(title), Text("Grounding")] : [Text(title)])
    }

    /// A finished breathing session: quietly offer it to Apple Health as a mindful session.
    /// Every gate (master toggle, mindfulness capability, share authorization) is enforced
    /// inside `saveMindfulSession`; a closed gate or failed write stays silent — the exercise
    /// itself already happened and nothing should dampen that.
    private func handleBreathingComplete(start: Date, end: Date) {
        // R5: an inverted or zero interval is not a session — never count it, and never offer it to
        // Health (an ill-formed `.mindfulSession` interval is a write we could not defend).
        guard end > start else {
            FernletAuditLog.log("firstAid.invalidBreathingInterval")
            return
        }
        // Count the session in the milestone ledger (append-only, `event:breathing:<uuid>`).
        // Breathing isn't in the diary, so this live hook is the only place it's counted — a
        // session finished before the ledger existed simply isn't (undercount accepted).
        store.recordMilestoneEvent(.breathing, ref: UUID().uuidString)
        let preferencesStore = storagePreferencesStore
        Task {
            do {
                try await HealthKitService(preferencesStore: preferencesStore).saveMindfulSession(start: start, end: end)
            } catch HealthKitServiceError.sharingTurnedOff {
                // The user's own switch said no, and the service's write gate already audited the
                // refusal (`healthkit.write.refused`) — not a failure to name twice.
                return
            } catch {
                // Stays silent toward the USER by design — the exercise happened and nothing should
                // dampen that — but the write failure still has to be named somewhere.
                FernletAuditLog.log("firstAid.mindfulSessionWriteFailed", context: ["error": String(describing: error)])
            }
        }
    }
}
