import SwiftUI

struct ConnectionInspectorView: View {
    @ObservedObject var inspector: ConnectionInspector
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let log = inspector.liveLog {
                    ConnectionInspectorLogDetailView(log: log)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.largeTitle)
                            .foregroundStyle(Color.slate)
                        Text("No active session")
                            .font(.headline)
                            .foregroundStyle(Color.bark)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.parchment)
                }
            }
            .navigationTitle("Connection Inspector")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .foregroundStyle(Color.slate)
                }
            }
        }
    }
}

struct ConnectionInspectorLogDetailView: View {
    let log: ConnectionSessionLog

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                identitySection
                distanceSection
                transportSection
                eventsSection
                envelopesSection
                if !log.errors.isEmpty { errorsSection }
            }
            .padding(20)
        }
        .background(Color.parchment)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(log.endState.capitalized)
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.bark)
            HStack(spacing: 10) {
                Label(durationText, systemImage: "timer")
                Label(log.localFingerprint, systemImage: "key.horizontal")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Color.slate)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Identity")
            inspectorRow("Local", log.localFingerprint)
            inspectorRow("Peer", log.peer?.displayName ?? "Unknown")
            inspectorRow("Peer fingerprint", log.peer?.confirmedFingerprint ?? log.peer?.advertisedFingerprint ?? "Unknown")
            inspectorRow("Ranging", log.ranging.mode.rawValue.uppercased())
        }
        .inspectorPanel()
    }

    private var distanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Distance")
            let latest = log.ranging.samples.last?.meters
            HStack(alignment: .firstTextBaseline) {
                Text(latest.map { "\(Int($0 * 100))" } ?? "--")
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(distanceColor(latest))
                Text("cm")
                    .font(.headline)
                    .foregroundStyle(Color.slate)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("min \(centimeters(log.ranging.minDistanceMeters))")
                    Text("max \(centimeters(log.ranging.maxDistanceMeters))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.slate)
            }
            if let rangingStatusText {
                Text(rangingStatusText)
                    .font(.caption)
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            DistanceSparkline(samples: Array(log.ranging.samples.suffix(90)))
                .frame(height: 54)
        }
        .inspectorPanel()
    }

    private var rangingStatusText: String? {
        guard log.ranging.samples.isEmpty else { return nil }
        switch log.ranging.mode {
        case .uwb:
            return "Waiting for Nearby Interaction distance samples."
        case .rssi:
            return "RSSI fallback active. MultipeerConnectivity does not expose RSSI, so meter estimates are unavailable on this transport."
        case .none:
            return "Ranging has not started for this session."
        }
    }

    private var transportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Transport")
            inspectorRow("MCSession", log.transport.mcSessionState)
            inspectorRow("Bytes sent", "\(log.transport.bytesSent)")
            inspectorRow("Bytes received", "\(log.transport.bytesReceived)")
            inspectorRow("Average RTT", log.transport.averageRttMs.map { String(format: "%.0f ms", $0) } ?? "--")
        }
        .inspectorPanel()
    }

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Events")
            ForEach(log.events.suffix(50).reversed()) { event in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(color(for: event.kind))
                        .frame(width: 8, height: 8)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.kind.rawValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.slate)
                        Text(event.message)
                            .font(.subheadline)
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                    }
                    Spacer()
                    Text(event.timestamp.formatted(date: .omitted, time: .standard))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.slate)
                }
            }
        }
        .inspectorPanel()
    }

    private var envelopesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Envelopes")
            if log.envelopes.isEmpty {
                EmptyState(text: "No envelopes recorded.")
            } else {
                ForEach(log.envelopes.suffix(30).reversed()) { envelope in
                    inspectorRow(envelope.direction.rawValue.capitalized, "\(envelope.payloadType) · \(envelope.payloadByteCount) B")
                }
            }
        }
        .inspectorPanel()
    }

    private var errorsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Errors")
            ForEach(log.errors) { error in
                inspectorRow(error.domain, error.message)
            }
        }
        .inspectorPanel()
    }

    private var durationText: String {
        let end = log.endedAt ?? Date()
        return String(format: "%.0fs", end.timeIntervalSince(log.startedAt))
    }

    private func inspectorRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.slate)
            Spacer(minLength: 16)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Color.bark)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
    }

    private func centimeters(_ meters: Double?) -> String {
        meters.map { "\(Int($0 * 100)) cm" } ?? "--"
    }

    private func distanceColor(_ meters: Double?) -> Color {
        guard let meters else { return Color.slate }
        if meters < 0.05 { return Color.moss }
        if meters < 0.30 { return Color.goldenrod }
        return Color.terracotta
    }

    private func color(for kind: ConnectionSessionLog.Event.Kind) -> Color {
        switch kind {
        case .error, .envelopeRejected, .identityRejected: return Color.terracotta
        case .tapConfirmed, .identityVerified, .userConfirmed, .envelopeVerified: return Color.moss
        case .rangingUpdated: return Color.goldenrod
        default: return Color.slate
        }
    }
}

private struct DistanceSparkline: View {
    let samples: [ConnectionSessionLog.DistanceSample]

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                guard samples.count > 1 else { return }
                let maxMeters = max(samples.map(\.meters).max() ?? 0.3, 0.3)
                for (index, sample) in samples.enumerated() {
                    let x = proxy.size.width * CGFloat(index) / CGFloat(samples.count - 1)
                    let normalized = min(sample.meters / maxMeters, 1)
                    let y = proxy.size.height * (1 - CGFloat(normalized))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.moss, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .background(Color.parchment.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension View {
    func inspectorPanel() -> some View {
        self
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 8))
    }
}
