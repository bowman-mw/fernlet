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
                VStack(alignment: .leading, spacing: 18) {
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
                            title: "5-4-3-2-1 grounding",
                            caption: "Arrive back in the room, one gentle sense at a time."
                        )
                        toolCard(
                            .worryBox,
                            icon: "archivebox",
                            tint: .goldenrod,
                            title: "Worry Box",
                            caption: "Write a worry down and let the box hold it for a while."
                        )
                    }

                    supportRow
                }
                .padding(20)
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
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("First aid")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.bark)
                Text("Small tools for a heavy moment. Pick whatever feels kind — or nothing at all.")
                    .font(.subheadline)
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            Spacer()
            Button("Done") { dismiss() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.moss)
        }
    }

    private func toolCard(_ tool: FirstAidTool, icon: String, tint: Color, title: String, caption: String) -> some View {
        Button {
            path.append(tool)
        } label: {
            FernletCard {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 38, height: 38)
                        .background(tint.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(Color.bark)
                        Text(caption)
                            .font(.callout)
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.slate.opacity(0.6))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("firstAid.tool.\(tool.rawValue)")
    }

    /// Static gentle-support row — always visible, never conditional, never tracking anything.
    private var supportRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("If things feel heavy")
            VStack(alignment: .leading, spacing: 10) {
                Text("Some moments are bigger than any app. You deserve real support — the 988 line is free, kind, and there around the clock.")
                    .font(.subheadline)
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                HStack(spacing: 10) {
                    supportLink("Call 988", icon: "phone", url: "tel:988")
                    supportLink("Text 988", icon: "message", url: "sms:988")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder
    private func supportLink(_ title: String, icon: String, url: String) -> some View {
        if let destination = URL(string: url) {
            Link(destination: destination) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.subheadline.weight(.semibold))
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(Color.moss)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.moss.opacity(0.13), in: Capsule())
            }
        }
    }

    /// A finished breathing session: quietly offer it to Apple Health as a mindful session.
    /// Every gate (master toggle, mindfulness capability, share authorization) is enforced
    /// inside `saveMindfulSession`; a closed gate or failed write stays silent — the exercise
    /// itself already happened and nothing should dampen that.
    private func handleBreathingComplete(start: Date, end: Date) {
        // TODO(Batch C): record a breathing-session achievement event in the milestone ledger
        // here (append-only, deterministic id `event:breathing:<uuid>`), once the ledger exists.
        let preferencesStore = storagePreferencesStore
        Task {
            try? await HealthKitService(preferencesStore: preferencesStore).saveMindfulSession(start: start, end: end)
        }
    }
}
