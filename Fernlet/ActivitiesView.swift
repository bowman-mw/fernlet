import SwiftUI
import FernletDomainModel
import ProximityKit
import FernletUI

/// The Group Activities screen (Phase 6 / B5). A NavigationLink sub-screen off the Friends tab — NOT a
/// top-level tab (the app's tab bar is a hand-rolled 6-item pager; a 7th would compress it, and nested
/// paged TabViews conflict). Reaches the activity brain via `store.meshNetworkManager.activities`.
///
/// States (all driven by the manager's observable state, no scattered booleans):
///  * host form — always available (until the host cap) to start an activity nearby;
///  * nearby invites — activities a committed friend offered this session, with "Ask to join";
///  * hosting — activities I run: live roster + expiry + per-member remove + end + the join-prompt sheet;
///  * joined — activities I'm a member of: host + roster + token/staleness + leave;
///  * empty hint — when nothing is live.
struct ActivitiesView: View {
    var store: FernletStore
    private var manager: ProximityActivityManager { store.meshNetworkManager.activities }

    @State private var draftTitle = ""
    @State private var draftLocation = ""
    @State private var draftType: ActivityTypeOption = .walk
    @State private var draftDuration: ActivityDurationOption = .oneDay
    @State private var titleWarning: String?
    @State private var pendingRemoval: RemovalTarget?
    @State private var pendingEnd: UUID?

    private var allEmpty: Bool {
        manager.hostedActivities.isEmpty && manager.joinedActivities.isEmpty && manager.offeredActivities.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FernletMetrics.spaceLg) {
                hostForm
                if !manager.offeredActivities.isEmpty { offeredSection }
                if !manager.hostedActivities.isEmpty { hostedSection }
                if !manager.joinedActivities.isEmpty { joinedSection }
                if allEmpty { emptyHint }
            }
            .padding(20)
        }
        .background(Color.parchment)
        .navigationTitle("Activities")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { manager.gcExpired() }
        .sheet(isPresented: joinPromptBinding) {
            if let first = manager.pendingJoinRequests.first {
                ActivityJoinPromptSheet(
                    requests: manager.pendingJoinRequests,
                    activityTitle: titleForActivity(first.activityID),
                    errorMessage: manager.activityError,
                    dismissError: { manager.activityError = nil },
                    allow: { manager.admitJoin($0) },
                    decline: { manager.declineJoin($0) }
                )
            }
        }
        .alert("Activities", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: { Text(manager.activityError ?? "") }
        .alert("End activity?", isPresented: endBinding) {
            Button("End", role: .destructive) { if let id = pendingEnd { manager.endHosting(activityID: id) }; pendingEnd = nil }
            Button("Cancel", role: .cancel) { pendingEnd = nil }
        } message: { Text("You'll stop hosting it for everyone here.") }
        .alert("Remove member?", isPresented: removalBinding) {
            Button("Remove", role: .destructive) {
                if let t = pendingRemoval { manager.removeParticipant(activityID: t.activityID, fingerprint: t.fingerprint) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { Text(pendingRemoval.map { "Remove \($0.name) from this activity?" } ?? "") }
    }

    // MARK: - Host form

    private var canHostMore: Bool { manager.hostedActivities.count < ActivityLimits.maxHosted }

    @ViewBuilder private var hostForm: some View {
        VStack(alignment: .leading, spacing: FernletMetrics.spaceMd) {
            Text("Start an activity")
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
            Text("Anyone you're with right now can ask to join. It stays on your devices — nothing is uploaded.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fixedSize(horizontal: false, vertical: true)

            if canHostMore {
                TextField("Activity name", text: $draftTitle)
                    .font(.fernlet(.body))
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color.cream, in: RoundedRectangle(cornerRadius: FernletMetrics.radiusSm))
                    .onChange(of: draftTitle) { _, new in
                        draftTitle = ItemNameModeration.sanitizedName(new)
                        titleWarning = nil
                    }
                    .accessibilityIdentifier("activities.titleField")

                chipRow(ActivityTypeOption.allCases, selected: draftType) { draftType = $0 } label: { $0.rawValue }
                chipRow(ActivityDurationOption.allCases, selected: draftDuration) { draftDuration = $0 } label: { $0.rawValue }

                TextField("Where? (optional, e.g. \"the park\")", text: $draftLocation)
                    .font(.fernlet(.bodySmall))
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color.cream, in: RoundedRectangle(cornerRadius: FernletMetrics.radiusSm))
                    .onChange(of: draftLocation) { _, new in
                        draftLocation = ItemNameModeration.sanitizedName(new)
                    }

                if let titleWarning {
                    Text(titleWarning).font(.fernlet(.labelSmall)).foregroundStyle(Color.terracotta)
                }

                Button(action: startActivity) {
                    Text("Start activity")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.parchment)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(draftTitle.isEmpty ? Color.moss.opacity(0.4) : Color.moss,
                                    in: RoundedRectangle(cornerRadius: FernletMetrics.radiusSm))
                }
                .buttonStyle(.plain)
                .disabled(draftTitle.isEmpty)
                .accessibilityIdentifier("activities.start")
            } else {
                Text("You're hosting the maximum of \(ActivityLimits.maxHosted) activities. End one to start another.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
            }
        }
        .padding(16)
        .background(Color.cream.opacity(0.5), in: RoundedRectangle(cornerRadius: FernletMetrics.radiusMd))
        .overlay(RoundedRectangle(cornerRadius: FernletMetrics.radiusMd).stroke(Color.bark.opacity(0.08), lineWidth: 1))
    }

    private func startActivity() {
        guard ItemNameModeration.isAllowedForListing(draftTitle) else {
            titleWarning = "That name can't be shared — try another."
            return
        }
        titleWarning = nil
        let expiresAt = Date().addingTimeInterval(draftDuration.seconds)
        if manager.host(title: draftTitle, activityTypeToken: draftType.token,
                        coarseLocation: draftLocation.isEmpty ? nil : draftLocation, expiresAt: expiresAt) != nil {
            draftTitle = ""
            draftLocation = ""
        }
    }

    // MARK: - Nearby invites

    private var offeredSection: some View {
        section("Nearby invites") {
            ForEach(manager.offeredActivities) { offered in
                VStack(alignment: .leading, spacing: 10) {
                    activityHeader(title: offered.descriptor.sanitizedTitle,
                                   subtitle: subtitle(type: offered.descriptor.activityTypeToken, location: offered.descriptor.coarseLocation),
                                   icon: "figure.2.arms.open")
                    ExpiryLabel(expiresAt: offered.descriptor.expiresAt)
                    HStack(spacing: 10) {
                        Button("Ask to join") { manager.requestJoin(offered) }
                            .buttonStyle(ChipButtonStyle(selected: true))
                            .accessibilityIdentifier("activities.askToJoin")
                        Button("Dismiss") { manager.dismissOffer(activityID: offered.descriptor.activityID) }
                            .buttonStyle(ChipButtonStyle(selected: false))
                    }
                }
                .padding(14)
                .modifier(CardBackground())
            }
        }
    }

    // MARK: - Hosting

    private var hostedSection: some View {
        section("You're hosting") {
            ForEach(manager.hostedActivities) { hosted in
                VStack(alignment: .leading, spacing: 12) {
                    activityHeader(title: hosted.descriptor.sanitizedTitle,
                                   subtitle: subtitle(type: hosted.descriptor.activityTypeToken, location: hosted.descriptor.coarseLocation),
                                   icon: "person.3.sequence")
                    ExpiryLabel(expiresAt: hosted.descriptor.expiresAt)
                    rosterView(participants: hosted.participants,
                               hostFingerprint: hosted.descriptor.hostFingerprint,
                               issuedAt: hosted.currentSnapshot.issuedAt,
                               version: hosted.version,
                               removable: true,
                               activityID: hosted.descriptor.activityID)
                    Button("End activity") { pendingEnd = hosted.descriptor.activityID }
                        .buttonStyle(ChipButtonStyle(selected: false))
                        .accessibilityIdentifier("activities.end")
                }
                .padding(14)
                .modifier(CardBackground())
            }
        }
    }

    // MARK: - Joined

    private var joinedSection: some View {
        section("You've joined") {
            ForEach(manager.joinedActivities) { joined in
                VStack(alignment: .leading, spacing: 12) {
                    activityHeader(title: joined.descriptor.sanitizedTitle,
                                   subtitle: hostSubtitle(joined),
                                   icon: "figure.2")
                    ExpiryLabel(expiresAt: joined.descriptor.expiresAt)
                    rosterView(participants: joined.lastSnapshot.participants,
                               hostFingerprint: joined.descriptor.hostFingerprint,
                               issuedAt: joined.lastSnapshot.issuedAt,
                               version: joined.lastSnapshot.version,
                               removable: false,
                               activityID: joined.descriptor.activityID)
                    Button("Leave") { manager.leaveJoined(activityID: joined.descriptor.activityID) }
                        .buttonStyle(ChipButtonStyle(selected: false))
                        .accessibilityIdentifier("activities.leave")
                }
                .padding(14)
                .modifier(CardBackground())
            }
        }
    }

    // MARK: - Roster

    @ViewBuilder
    private func rosterView(participants: [ActivityParticipant], hostFingerprint: String,
                            issuedAt: Date, version: Int, removable: Bool, activityID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Roster as of \(issuedAt.formatted(date: .abbreviated, time: .shortened)) (v\(version))")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
            ForEach(participants) { member in
                HStack(spacing: 10) {
                    memberAvatar(member)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(ItemNameModeration.sanitizedName(member.displayName))
                                .font(.fernlet(.headerMedium))
                                .foregroundStyle(Color.bark)
                            if member.fingerprint == hostFingerprint {
                                Text("host")
                                    .font(.fernlet(.labelSmall))
                                    .foregroundStyle(Color.moss)
                            }
                        }
                        Text(member.fingerprint)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Color.slate)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if removable && member.fingerprint != hostFingerprint {
                        Button {
                            pendingRemoval = RemovalTarget(activityID: activityID, fingerprint: member.fingerprint,
                                                           name: ItemNameModeration.sanitizedName(member.displayName))
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(Color.terracotta)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func memberAvatar(_ member: ActivityParticipant) -> some View {
        if let cached = store.cachedFriendState(fingerprint: member.fingerprint) {
            CompanionView(state: cached.fuzzyState.representativeState, appearance: cached.appearance, size: 40)
        } else {
            ZStack {
                Circle().fill(Color.moss.opacity(0.18)).frame(width: 40, height: 40)
                Text(monogram(member.displayName))
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.moss)
            }
        }
    }

    // MARK: - Empty

    private var emptyHint: some View {
        VStack(spacing: FernletMetrics.spaceSm) {
            Image(systemName: "figure.2.arms.open")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.moss.opacity(0.7))
            Text("No activities yet")
                .font(.fernlet(.headerMedium))
                .foregroundStyle(Color.bark)
            Text("Start one above, or wait for a nearby friend to invite you.")
                .font(.fernlet(.bodySmall))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.slate)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.fernlet(.label))
                .foregroundStyle(Color.slate)
            content()
        }
    }

    private func activityHeader(title: String, subtitle: String?, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.moss)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? "Activity" : title)
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func chipRow<T: Identifiable & Equatable>(_ options: [T], selected: T,
                                                      onSelect: @escaping (T) -> Void,
                                                      label: @escaping (T) -> String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options) { option in
                    Button(label(option)) { onSelect(option) }
                        .buttonStyle(ChipButtonStyle(selected: option == selected))
                }
            }
        }
    }

    // MARK: - Helpers

    private var joinPromptBinding: Binding<Bool> {
        Binding(
            get: { !manager.pendingJoinRequests.isEmpty },
            set: { presented in
                if !presented { manager.pendingJoinRequests.forEach { manager.declineJoin($0) } }
            }
        )
    }

    private var errorBinding: Binding<Bool> {
        // Only present the root alert when the join-prompt sheet is NOT up: while it is, the error is an
        // admit-time failure the sheet shows inline (a root alert can't present over the sheet anyway).
        Binding(
            get: { manager.activityError != nil && manager.pendingJoinRequests.isEmpty },
            set: { if !$0 { manager.activityError = nil } })
    }

    private var endBinding: Binding<Bool> {
        Binding(get: { pendingEnd != nil }, set: { if !$0 { pendingEnd = nil } })
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private func titleForActivity(_ id: UUID) -> String {
        manager.hostedActivities.first(where: { $0.descriptor.activityID == id })?.descriptor.sanitizedTitle ?? "an activity"
    }

    private func subtitle(type: String, location: String?) -> String {
        let t = type.isEmpty ? nil : ItemNameModeration.sanitizedName(type).capitalized
        // The descriptor is pinned as-received (to keep the paramsHash stable), so sanitize the coarse
        // location for display here.
        let loc = location.map { ItemNameModeration.sanitizedName($0) }.flatMap { $0.isEmpty ? nil : $0 }
        return [t, loc].compactMap { $0 }.joined(separator: " · ")
    }

    private func hostSubtitle(_ joined: ProximityActivityManager.JoinedActivity) -> String {
        let hostName = joined.lastSnapshot.participants
            .first(where: { $0.fingerprint == joined.descriptor.hostFingerprint })
            .map { ItemNameModeration.sanitizedName($0.displayName) }
        let base = hostName.map { "Hosted by \($0)" } ?? "Joined"
        let extra = subtitle(type: joined.descriptor.activityTypeToken, location: joined.descriptor.coarseLocation)
        return extra.isEmpty ? base : "\(base) · \(extra)"
    }

    private func monogram(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "?" : String(trimmed.prefix(1)).uppercased()
    }

    // MARK: - Local model

    private struct RemovalTarget: Equatable { let activityID: UUID; let fingerprint: String; let name: String }

    private enum ActivityTypeOption: String, CaseIterable, Identifiable {
        case walk = "Walk", coffee = "Coffee", meal = "Meal", study = "Study", workout = "Workout", hangout = "Hangout", other = "Other"
        var id: String { rawValue }
        var token: String { rawValue.lowercased() }
    }

    private enum ActivityDurationOption: String, CaseIterable, Identifiable {
        case twoHours = "2 hours", oneDay = "1 day", threeDays = "3 days", sevenDays = "7 days"
        var id: String { rawValue }
        var seconds: TimeInterval {
            switch self {
            case .twoHours: return 2 * 3600
            case .oneDay: return 24 * 3600
            case .threeDays: return 3 * 24 * 3600
            case .sevenDays: return 7 * 24 * 3600
            }
        }
    }

    private struct CardBackground: ViewModifier {
        func body(content: Content) -> some View {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: FernletMetrics.radiusMd))
                .overlay(RoundedRectangle(cornerRadius: FernletMetrics.radiusMd).stroke(Color.bark.opacity(0.08), lineWidth: 1))
        }
    }
}

/// A live "Expires in …" / "Expired" label that ticks each minute.
private struct ExpiryLabel: View {
    let expiresAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let remaining = expiresAt.timeIntervalSince(context.date)
            HStack(spacing: 5) {
                Image(systemName: "clock").font(.caption2)
                Text(remaining <= 0 ? "Expired" : "Expires \(Self.relative(remaining))")
                    .font(.fernlet(.labelSmall))
            }
            .foregroundStyle(remaining <= 0 ? Color.terracotta : Color.slate)
        }
    }

    private static func relative(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "in \(max(1, minutes)) min" }
        let hours = minutes / 60
        if hours < 48 { return "in \(hours) h" }
        return "in \(hours / 24) days"
    }
}
