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
/// device's region (``CrisisResources``).
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

    // Menu geometry — mockup §1a runs off the shared 8pt/radius grid, so these live here as
    // named surface-local constants rather than FernletMetrics tokens.
    private let tileSize: CGFloat = 46
    private let tileRadius: CGFloat = 15
    private let rowRadius: CGFloat = 20
    private let supportCardRadius: CGFloat = 22
    private let pillRadius: CGFloat = 13

    // Surface-local warm hues that override the app's cool secondary ink for this menu.
    // Captions warm to taupe; the support card keeps every element in one amber-brown family.
    private static let captionInk = Color(light: Color(red: 0.478, green: 0.416, blue: 0.333),
                                          dark:  Color(red: 0.663, green: 0.612, blue: 0.522))
    private static let groundingInk = Color(light: Color(red: 0.369, green: 0.486, blue: 0.549),
                                            dark:  Color(red: 0.682, green: 0.776, blue: 0.831))
    private static let supportHeadingInk = Color(light: Color(red: 0.353, green: 0.263, blue: 0.133),
                                                 dark:  Color(red: 0.941, green: 0.875, blue: 0.706))
    private static let supportProseInk = Color(light: Color(red: 0.416, green: 0.325, blue: 0.200),
                                               dark:  Color(red: 0.796, green: 0.725, blue: 0.561))
    private static let supportOutlineInk = Color(light: Color(red: 0.353, green: 0.263, blue: 0.133),
                                                 dark:  Color(red: 0.878, green: 0.722, blue: 0.376))
    /// Secondary support-button outline stroke — brown @0.35 in light, goldenrod @0.4 in dark
    /// (mockup §1a).
    private static let supportOutlineStroke = Color(light: Color(red: 0.353, green: 0.263, blue: 0.133).opacity(0.35),
                                                    dark:  Color(red: 0.878, green: 0.722, blue: 0.376).opacity(0.40))
    /// On-accent ink for the filled Call button — parchment in light, near-black in dark.
    private static let supportFilledInk = Color(light: Color(red: 0.961, green: 0.937, blue: 0.878),
                                                dark:  Color(red: 0.102, green: 0.082, blue: 0.055))

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
                        supportRow
                    }
                    .padding(.horizontal, FernletMetrics.spaceLg)
                    .padding(.top, FernletMetrics.spaceSm)
                    .padding(.bottom, FernletMetrics.spaceXl)
                }
            }
            .background(Color.parchment)
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
        Text("Small tools for a heavy moment. Pick whatever feels kind — or nothing at all.")
            .font(.custom(FernletFontName.instrumentSerif, size: 22, relativeTo: .title2))
            .foregroundStyle(Color.bark)
            .lineSpacing(9)  // ~1.42 leading at 22pt
            .fernletWrappingText()
    }

    /// The three tool cards, in the menu's fixed order: breathing, grounding, worry box.
    private var toolList: some View {
        VStack(spacing: 12) {
            toolCard(
                .breathing,
                icon: "wind",
                tileFill: Color.fern.opacity(0.20),
                iconColor: .moss,
                title: "Slow breathing",
                caption: "A quiet minute or three with a slowly swelling circle."
            )
            toolCard(
                .grounding,
                icon: "target",
                tileFill: Color.journalQuiet.opacity(0.24),
                iconColor: Self.groundingInk,
                title: "5·4·3·2·1 grounding",
                caption: "Arrive back in the room, one gentle sense at a time."
            )
            toolCard(
                .worryBox,
                icon: "archivebox",
                tileFill: Color.goldenrod.opacity(0.20),
                iconColor: .goldenrod,
                title: "Worry box",
                caption: "Write a worry down and let the box hold it for a while."
            )
        }
    }

    private func toolCard(_ tool: FirstAidTool, icon: String, tileFill: Color, iconColor: Color, title: String, caption: String) -> some View {
        Button {
            path.append(tool)
        } label: {
            HStack(spacing: 15) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(iconColor)
                    .frame(width: tileSize, height: tileSize)
                    .background(tileFill, in: RoundedRectangle(cornerRadius: tileRadius, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.fernlet(.headerMedium))
                        .foregroundStyle(Color.bark)
                    Text(caption)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Self.captionInk)
                        .fernletWrappingText()
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.softTaupe)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: rowRadius, style: .continuous))
            .fernletSmallShadow()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("firstAid.tool.\(tool.rawValue)")
    }

    /// Static gentle-support row — always visible, never conditional, never tracking anything.
    /// Set apart from the tools with a warmer, goldenrod-tinted card.
    ///
    /// The line shown is chosen by ``CrisisResources`` from the device's *region*, read at render
    /// time rather than cached so travelling changes the number. A region Fernlet has no verified
    /// line for renders the copy with no buttons at all — never a number that does not connect
    /// there.
    private var supportRow: some View {
        let resource = CrisisResources.resource(for: Locale.current.region)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: "heart")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.goldenrod)
                Text("If things feel heavy")
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Self.supportHeadingInk)
            }
            Text(resource.blurb)
                .font(.fernlet(.body))
                .foregroundStyle(Self.supportProseInk)
                .lineSpacing(2)
                .fernletWrappingText()
                .padding(.bottom, FernletMetrics.spaceXs)
            if resource.actions.isEmpty == false {
                HStack(spacing: 10) {
                    ForEach(Array(resource.actions.enumerated()), id: \.element.id) { index, action in
                        supportLink(action, filled: index == 0)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.goldenrod.opacity(0.18), Color.goldenrod.opacity(0.11)],
                startPoint: .top,
                endPoint: .bottom
            ),
            in: RoundedRectangle(cornerRadius: supportCardRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: supportCardRadius, style: .continuous)
                .stroke(Color.goldenrod.opacity(0.32), lineWidth: 1)
        )
    }

    /// One call/text button. The URL is already resolved by ``CrisisResources``, so — unlike the
    /// hardcoded version this replaced — there is no optional-URL branch that could silently
    /// render nothing.
    private func supportLink(_ action: CrisisResourceAction, filled: Bool) -> some View {
        Link(destination: action.url) {
            HStack(spacing: 8) {
                Image(systemName: action.systemImage)
                    .font(.subheadline.weight(.semibold))
                Text(action.title)
                    .font(.fernlet(.label))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(filled ? Self.supportFilledInk : Self.supportOutlineInk)
            .background {
                if filled {
                    RoundedRectangle(cornerRadius: pillRadius, style: .continuous)
                        .fill(Color.moss)
                } else {
                    RoundedRectangle(cornerRadius: pillRadius, style: .continuous)
                        .stroke(Self.supportOutlineStroke, lineWidth: 1.5)
                }
            }
        }
        .accessibilityIdentifier("firstAid.support.\(action.id)")
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
            } catch {
                // Stays silent toward the USER by design — the exercise happened and nothing should
                // dampen that — but the write failure still has to be named somewhere. A closed
                // consent gate returns without throwing inside the service, so this logs real
                // failures only.
                FernletAuditLog.log("firstAid.mindfulSessionWriteFailed", context: ["error": String(describing: error)])
            }
        }
    }
}
