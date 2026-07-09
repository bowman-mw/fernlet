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

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: FernletMetrics.spaceLg) {
                    header

                    VStack(spacing: 12) {
                        toolCard(
                            .breathing,
                            icon: "wind",
                            tint: .moss,
                            title: "Slow breathing",
                            caption: "A quiet minute or three with a slowly swelling circle."
                        )
                        toolCard(
                            .grounding,
                            icon: "leaf",
                            tint: .fern,
                            title: "5·4·3·2·1 grounding",
                            caption: "Arrive back in the room, one gentle sense at a time."
                        )
                        toolCard(
                            .worryBox,
                            icon: "archivebox",
                            tint: .goldenrod,
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
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
                .lineSpacing(3)
                .fernletWrappingText()
        }
    }

    private func toolCard(_ tool: FirstAidTool, icon: String, tint: Color, title: String, caption: String) -> some View {
        Button {
            path.append(tool)
        } label: {
            HStack(spacing: 15) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(tint)
                    .frame(width: 46, height: 46)
                    .background(tint.opacity(0.20), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.fernlet(.headerMedium))
                        .foregroundStyle(Color.bark)
                    Text(caption)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.softTaupe)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
                    .foregroundStyle(Color.bark)
            }
            Text("Some moments are bigger than any app. You deserve real support — the 988 line is free, kind, and there around the clock.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .lineSpacing(2)
                .fernletWrappingText()
                .padding(.bottom, FernletMetrics.spaceXs)
            HStack(spacing: 10) {
                supportLink("Call 988", icon: "phone.fill", url: "tel:988", filled: true)
                supportLink("Text 988", icon: "message.fill", url: "sms:988", filled: false)
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
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
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
                .foregroundStyle(filled ? Color.white : Color.moss)
                .background {
                    if filled {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(Color.moss)
                    } else {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(Color.moss.opacity(0.45), lineWidth: 1.5)
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
