import SwiftUI

/// The crisp companion for the Today panel's companion card: a port of the shipping `CompanionView`
/// (`App/Fernlet/CompanionVectorAssets.swift`) for the standard appearance only (circle body, fern
/// sprout), with the same proportions, breath maths and state face. The map uses the pixel version;
/// panels you read stay crisp (design page, "Pixel where it helps, crisp where you read").
struct CompanionVectorView: View {
    let state: ShellCompanionState
    var size: CGFloat = 56
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let breath = (sin(elapsed * .pi / state.breathTempo) + 1) / 2
            figure(breath: breath)
        }
        .frame(width: size * 1.1, height: size * 1.25)
        .accessibilityHidden(true)
    }

    /// One frame of the figure, back to front: body, highlight, sprout, eyes, mouth.
    private func figure(breath: Double) -> some View {
        let sink = state == .resting ? size * 0.04 : 0
        return ZStack {
            Ellipse()
                .fill(state.color)
                .frame(width: size, height: size)
                .scaleEffect(x: 1 + breath * horizontalBreath, y: 1 + breath * verticalBreath)
                .offset(y: sink)
                .shadow(color: state.color.opacity(0.20), radius: size * 0.08, x: 0, y: size * 0.04)
            Ellipse()
                .fill(.white.opacity(0.16))
                .frame(width: size * 0.34, height: size * 0.22)
                .offset(x: -size * 0.12, y: -size * 0.20)
            sprout
            HStack(spacing: size * 0.18) { eye; eye }
                .offset(y: -size * 0.08)
            RoundedRectangle(cornerRadius: 5)
                .fill(.white.opacity(0.72))
                .frame(width: size * 0.18, height: mouthHeight)
                .offset(y: size * 0.14)
        }
        .offset(y: size * 0.1)
    }

    /// The standard sprout: a stem with two leaves, in fern.
    private var sprout: some View {
        VStack(spacing: -size * 0.03) {
            Capsule().fill(FernColors.fern).frame(width: size * 0.035, height: size * 0.18)
            HStack(spacing: -size * 0.015) {
                Ellipse().fill(FernColors.fern).frame(width: size * 0.18, height: size * 0.09).rotationEffect(.degrees(-26))
                Ellipse().fill(FernColors.fern).frame(width: size * 0.18, height: size * 0.09).rotationEffect(.degrees(26))
            }
        }
        .offset(y: -size * 0.55)
    }

    /// The open eye: round, or half-lidded on a low-energy day (`CompanionEyeView`).
    private var eye: some View {
        ZStack {
            Ellipse()
                .fill(.white.opacity(0.92))
                .frame(width: size * 0.13, height: state.isLowEnergy ? size * 0.07 : size * 0.13)
            Circle()
                .fill(FernColors.bark)
                .frame(width: size * 0.06, height: size * 0.06)
        }
    }

    /// `CompanionState.mouthHeight(for:)`.
    private var mouthHeight: CGFloat {
        switch state {
        case .thriving: size * 0.07
        case .okay: size * 0.05
        case .tired, .sick: size * 0.025
        case .resting: size * 0.018
        }
    }

    /// `CompanionState.horizontalBreath`.
    private var horizontalBreath: CGFloat {
        switch state {
        case .thriving: 0.018
        case .okay: 0.012
        case .tired, .sick: 0.006
        case .resting: 0.003
        }
    }

    /// `CompanionState.verticalBreath`.
    private var verticalBreath: CGFloat {
        switch state {
        case .thriving: 0.026
        case .okay: 0.018
        case .tired, .sick: 0.010
        case .resting: 0.004
        }
    }
}
