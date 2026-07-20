//
//  FirstAidView.swift
//  Fernlet
//
//  A calm, low-stimulation "first aid" sheet: slow breathing, 5-4-3-2-1 grounding, the
//  Worry Box, and a static gentle-support row (988). Always reachable — from the Home
//  affordance near the companion, the body-signals explainer, and the gentle offer card.
//  The support row is deliberately static and always visible; it is NOT the deferred
//  extended-low-mood auto-nudge.
//

import SwiftUI
import FernletDomainModel
import FernletFoundation
import HealthKitGateway
import FernletUI

/// The tools the First Aid sheet can open directly (e.g. from a gentle offer card).
enum FirstAidTool: String, Hashable {
    case breathing
    case grounding
    case worryBox
}

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
    // Captions warm to taupe; the 988 card keeps every element in one amber-brown family.
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
    /// Text-988 outline stroke — brown @0.35 in light, goldenrod @0.4 in dark (mockup §1a).
    private static let supportOutlineStroke = Color(light: Color(red: 0.353, green: 0.263, blue: 0.133).opacity(0.35),
                                                    dark:  Color(red: 0.878, green: 0.722, blue: 0.376).opacity(0.40))
    /// On-accent ink for the filled Call button — parchment in light, near-black in dark.
    private static let supportFilledInk = Color(light: Color(red: 0.961, green: 0.937, blue: 0.878),
                                                dark:  Color(red: 0.102, green: 0.082, blue: 0.055))

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: FernletMetrics.spaceLg) {
                    header

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

                    supportRow
                }
                .padding(.horizontal, FernletMetrics.spaceLg)
                .padding(.top, FernletMetrics.spaceSm)
                .padding(.bottom, FernletMetrics.spaceXl)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("First aid")
                Spacer()
                Button("Done") { dismiss() }
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.moss)
            }
            Text("Small tools for a heavy moment. Pick whatever feels kind — or nothing at all.")
                .font(.custom(FernletFontName.instrumentSerif, size: 22, relativeTo: .title2))
                .foregroundStyle(Color.bark)
                .lineSpacing(9)  // ~1.42 leading at 22pt
                .fernletWrappingText()
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
    private var supportRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: "heart")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.goldenrod)
                Text("If things feel heavy")
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Self.supportHeadingInk)
            }
            Text("Some moments are bigger than any app. You deserve real support — the 988 line is free, kind, and there around the clock.")
                .font(.fernlet(.body))
                .foregroundStyle(Self.supportProseInk)
                .lineSpacing(2)
                .fernletWrappingText()
                .padding(.bottom, FernletMetrics.spaceXs)
            HStack(spacing: 10) {
                supportLink("Call 988", icon: "phone", url: "tel:988", filled: true)
                supportLink("Text 988", icon: "message", url: "sms:988", filled: false)
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

    @ViewBuilder
    private func supportLink(_ title: String, icon: String, url: String, filled: Bool) -> some View {
        if let destination = URL(string: url) {
            Link(destination: destination) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.subheadline.weight(.semibold))
                    Text(title)
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
        }
    }

    /// A finished breathing session: quietly offer it to Apple Health as a mindful session.
    /// Every gate (master toggle, mindfulness capability, share authorization) is enforced
    /// inside `saveMindfulSession`; a closed gate or failed write stays silent — the exercise
    /// itself already happened and nothing should dampen that.
    private func handleBreathingComplete(start: Date, end: Date) {
        // Count the session in the milestone ledger (append-only, `event:breathing:<uuid>`).
        // Breathing isn't in the diary, so this live hook is the only place it's counted — a
        // session finished before the ledger existed simply isn't (undercount accepted).
        store.recordMilestoneEvent(.breathing, ref: UUID().uuidString)
        let preferencesStore = storagePreferencesStore
        Task {
            try? await HealthKitService(preferencesStore: preferencesStore).saveMindfulSession(start: start, end: end)
        }
    }
}
