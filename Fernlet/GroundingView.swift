//
//  GroundingView.swift
//  Fernlet
//
//  5-4-3-2-1 grounding: a stepped, tap-to-advance flow (no timers, no pressure) that
//  walks one gentle sense at a time and ends on a soft affirmation.
//

import SwiftUI

struct GroundingView: View {
    private struct GroundingStep {
        let count: Int
        let icon: String
        let prompt: String
        let hint: String
    }

    private static let steps: [GroundingStep] = [
        GroundingStep(count: 5, icon: "eye", prompt: "Notice five things you can see", hint: "Anything at all — a corner of the ceiling, the light on your hand."),
        GroundingStep(count: 4, icon: "hand.raised", prompt: "Notice four things you can touch", hint: "The chair under you, the fabric of your sleeve, the air on your skin."),
        GroundingStep(count: 3, icon: "ear", prompt: "Notice three things you can hear", hint: "Near or far. A hum, a bird, your own breath."),
        GroundingStep(count: 2, icon: "nose", prompt: "Notice two things you can smell", hint: "Or two smells you like remembering."),
        GroundingStep(count: 1, icon: "mouth", prompt: "Notice one thing you can taste", hint: "Even just the inside of your mouth counts.")
    ]

    @State private var stepIndex = 0
    @State private var isComplete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 12)

            if isComplete {
                completion
            } else {
                stepContent(Self.steps[stepIndex])
            }

            Spacer(minLength: 12)

            footer
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { advance() }
        .background(Color.parchment)
        .navigationTitle("Grounding")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stepContent(_ step: GroundingStep) -> some View {
        VStack(spacing: 18) {
            Text("\(step.count)")
                .font(.system(size: 64, weight: .bold, design: .serif))
                .foregroundStyle(Color.moss)
            Image(systemName: step.icon)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.fern)
                .frame(width: 64, height: 64)
                .background(Color.fern.opacity(0.12), in: Circle())
            Text(step.prompt)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.bark)
                .multilineTextAlignment(.center)
            Text(step.hint)
                .font(.subheadline)
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
        }
        .transition(.opacity)
        .id(stepIndex)
    }

    private var completion: some View {
        VStack(spacing: 18) {
            Image(systemName: "leaf")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Color.moss)
                .frame(width: 72, height: 72)
                .background(Color.moss.opacity(0.12), in: Circle())
            Text("You're here.")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.bark)
            Text("That's enough. Take the calm with you — there's nothing else to do.")
                .font(.subheadline)
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
        }
        .transition(.opacity)
    }

    private var footer: some View {
        Group {
            if isComplete {
                Button("Done") { dismiss() }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.moss, in: RoundedRectangle(cornerRadius: 14))
                    .buttonStyle(.plain)
            } else {
                Text("Tap anywhere when you're ready for the next one — take all the time you like.")
                    .font(.caption)
                    .foregroundStyle(Color.slate)
                    .multilineTextAlignment(.center)
                    .fernletWrappingText()
            }
        }
    }

    private func advance() {
        guard !isComplete else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            if stepIndex < Self.steps.count - 1 {
                stepIndex += 1
            } else {
                isComplete = true
            }
        }
    }
}
