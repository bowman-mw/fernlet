import SwiftUI
import FernletDomainModel
import ProximityKit
import FernletConnections
import FernletSocial
import FernletUI

/// The Group Activities screen (Phase 6 / B5). A NavigationLink sub-screen off the Friends tab — NOT a
/// top-level tab (the app's tab bar is a hand-rolled 6-item pager; a 7th would compress it, and nested
/// paged TabViews conflict). Reaches the activity brain via `store.meshFeatures.activities`.
///
/// States (all driven by the manager's observable state, no scattered booleans):
///  * host form — always available (until the host cap) to start an activity nearby;
///  * nearby invites — activities a committed friend offered this session, with "Ask to join";
///  * hosting — activities I run: live roster + expiry + per-member remove + end + the join-prompt sheet;
///  * joined — activities I'm a member of: host + roster + token/staleness + leave;
///  * empty hint — when nothing is live.
struct ActivitiesView: View {
    var store: FernletStore
    private var manager: ProximityActivityManager { store.meshFeatures.activities }

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
            .padding(16)
        }
        // The title is on the panel's plate (`fernletPushedPage` at the push); the dots show here.
        .fernletPageBackground()
        .onAppear { manager.gcExpired() }
        // Pushed from the Friends album: a re-tap of the Friends tab asks before it pops a typed
        // activity name or place away.
        .tabReselectDraft(isDirty: !draftTitle.isEmpty || !draftLocation.isEmpty)
        .sheet(isPresented: joinPromptBinding) {
            if let first = manager.pendingJoinRequests.first {
                JoinPromptSheet(
                    requests: manager.pendingJoinRequests,
                    targetName: titleForActivity(first.activityID),
                    displayName: { PeerNameDisplay.shown($0.displayName, fingerprint: $0.verifiedFingerprint, in: .fernlet) },
                    accessibilityPrefix: "activity.join",
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
        } message: {
            // A `Text` key, not a mapped `String`: `Text(String)` is the verbatim overload.
            if let target = pendingRemoval { Text("Remove \(target.name) from this activity?") }
        }
    }

    // MARK: - Host form

    private var canHostMore: Bool { manager.hostedActivities.count < ActivityLimits.maxHosted }

    @ViewBuilder private var hostForm: some View {
        FernletCard {
            hostFormContent
        }
    }

    /// The form inside the Start an activity card (`b2-activities`): framed fields and chips, and a
    /// framed Start that dims until the activity has a name.
    @ViewBuilder private var hostFormContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Start an activity")
                .font(FernletFramedFont.cardTitle)
                .foregroundStyle(WorldPalette.bark)
            Text("Anyone you're with right now can ask to join. It stays on your devices — nothing is uploaded.")
                .font(FernletFramedFont.body)
                .foregroundStyle(WorldPalette.dim)
                .fixedSize(horizontal: false, vertical: true)

            if canHostMore {
                TextField("Activity name", text: $draftTitle, prompt: .fieldPrompt("Activity name"))
                    .sheetTextInput()
                    .onChange(of: draftTitle) { _, new in
                        draftTitle = ItemNameModeration.sanitizedName(new)
                        titleWarning = nil
                    }
                    .accessibilityIdentifier("activities.titleField")

                chipRow(ActivityTypeOption.allCases, selected: draftType) { draftType = $0 } label: { $0.displayName }
                chipRow(ActivityDurationOption.allCases, selected: draftDuration) { draftDuration = $0 } label: { $0.displayName }

                TextField("Where? (optional, e.g. \"the park\")", text: $draftLocation,
                          prompt: .fieldPrompt("Where? (optional, e.g. \"the park\")"))
                    // Same role, same size as the name field above it — the two used to render at
                    // different type sizes in the same form.
                    .sheetTextInput()
                    .onChange(of: draftLocation) { _, new in
                        draftLocation = ItemNameModeration.sanitizedName(new)
                    }

                if let titleWarning {
                    Text(titleWarning).font(.fernlet(.labelSmall)).foregroundStyle(Color.terracotta)
                }

                Button(action: startActivity) {
                    Text("Start activity")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .disabled(draftTitle.isEmpty)
                .accessibilityIdentifier("activities.start")
            } else {
                Text("You're hosting the maximum of \(ActivityLimits.maxHosted) activities. End one to start another.")
                    .font(FernletFramedFont.body)
                    .foregroundStyle(WorldPalette.dim)
            }
        }
    }

    private func startActivity() {
        guard ItemNameModeration.isAllowedForListing(draftTitle) else {
            titleWarning = String(localized: "activities.host.nameRefused",
                                  defaultValue: "That name can't be shared — try another.",
                                  comment: "Under the activity name field when the typed name is not allowed to be shared with people nearby")
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
                    AdaptiveStack(spacing: 10, horizontalAlignment: .leading) {
                        Button("Ask to join") { manager.requestJoin(offered) }
                            .buttonStyle(ActionPillButtonStyle(.primary))
                            .accessibilityIdentifier("activities.askToJoin")
                        Button("Dismiss") { manager.dismissOffer(activityID: offered.descriptor.activityID) }
                            .buttonStyle(ActionPillButtonStyle(.secondary))
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
                               removable: true,
                               activityID: hosted.descriptor.activityID)
                    Button("End activity") { pendingEnd = hosted.descriptor.activityID }
                        .buttonStyle(ActionPillButtonStyle(.destructive))
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
                               removable: false,
                               activityID: joined.descriptor.activityID)
                    Button("Leave") { manager.leaveJoined(activityID: joined.descriptor.activityID) }
                        .buttonStyle(ActionPillButtonStyle(.destructive))
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
                            issuedAt: Date, removable: Bool, activityID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // "Roster as of … (v3)" was wire vocabulary — the snapshot version means nothing to the
            // person reading it, and "roster" is a clipboard word for a list of friends.
            Text("Updated \(rosterTimestamp(issuedAt))")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
            ForEach(participants) { member in
                // The member's chosen name, never their fingerprint (2026-09-29): the name, the
                // removal copy and the monogram all read the same filtered value.
                let memberName = PeerNameDisplay.shown(member.displayName, fingerprint: member.fingerprint, in: .fernlet)
                HStack(spacing: 10) {
                    memberAvatar(member, name: memberName)
                    HStack(spacing: 6) {
                        Text(verbatim: memberName)
                            .font(.fernlet(.headerMedium))
                            .foregroundStyle(Color.bark)
                        if member.fingerprint == hostFingerprint {
                            Text("host")
                                .font(.fernlet(.labelSmall))
                                .foregroundStyle(Color.moss)
                        }
                    }
                    Spacer()
                    if removable && member.fingerprint != hostFingerprint {
                        Button {
                            pendingRemoval = RemovalTarget(activityID: activityID, fingerprint: member.fingerprint,
                                                           name: memberName)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(Color.terracotta)
                        }
                        .buttonStyle(.plain)
                        .fernletIconButton("Remove \(memberName) from this activity")
                        // Voice Control: the row already says which activity; the name says who.
                        .accessibilityInputLabels([Text("Remove \(memberName)")])
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func memberAvatar(_ member: ActivityParticipant, name: String) -> some View {
        if let cached = store.cachedFriendState(fingerprint: member.fingerprint) {
            // Someone ELSE's companion, drawn at 40pt beside their name. T1-10: it used to inherit
            // the shared "Fernlet companion, <state>" label, so every friend in the roster
            // announced as the user's own — and leaked their fuzzed wellbeing state along the way.
            // The name is already spoken by the row; the avatar adds nothing but noise.
            CompanionView(state: cached.fuzzyState.representativeState, appearance: cached.appearance, size: 40)
                .accessibilityHidden(true)
        } else {
            ZStack {
                Circle().fill(Color.moss.opacity(0.18)).frame(width: 40, height: 40)
                Text(monogram(name))
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.moss)
            }
        }
    }

    // MARK: - Empty

    private var emptyHint: some View {
        FriendsEmptyNote(
            text: Text("No activities yet — start one above, or wait for a nearby friend to invite you."),
            systemImage: "figure.2.arms.open"
        )
        .padding(.vertical, 6)
    }

    // MARK: - Building blocks

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // The app's one section-heading treatment (uppercase, letter-spaced slate), same as
            // Move's "TODAY'S MOVEMENT" and Food's "BREAKFAST".
            SectionLabel(title)
            content()
        }
    }

    /// "Updated 7:17 PM" for a snapshot from today; a date as well once it isn't.
    private func rosterTimestamp(_ issuedAt: Date) -> String {
        Calendar.current.isDateInToday(issuedAt)
            ? issuedAt.formatted(date: .omitted, time: .shortened)
            : issuedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func activityHeader(title: String, subtitle: String?, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.moss)
            VStack(alignment: .leading, spacing: 2) {
                // Two `Text`s, not one ternary: `title` is the host's own words (verbatim), and
                // the fallback is copy (a key). A `String` ternary drew both verbatim.
                (title.isEmpty ? Text("Activity") : Text(verbatim: title))
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

    /// The type/duration option chips.
    ///
    /// Wrapped with ``FlowLayout``, not scrolled: inside the card's 16pt padding a horizontal
    /// scroller hard-clipped "Workout" mid-word at the padding edge, with no fade and no trailing
    /// peek, so the last three types were simply invisible.
    @ViewBuilder
    private func chipRow<T: Identifiable & Equatable>(_ options: [T], selected: T,
                                                      onSelect: @escaping (T) -> Void,
                                                      label: @escaping (T) -> String) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(options) { option in
                Button(label(option)) {
                    // B6: a real change ticks, through the shared helper; the caller still stores it.
                    var choice = selected
                    FernletFeedback.system.select(option, in: &choice)
                    onSelect(choice)
                }
                    .buttonStyle(ChipButtonStyle(selected: option == selected))
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
        $pendingEnd.isPresent()
    }

    private var removalBinding: Binding<Bool> {
        $pendingRemoval.isPresent()
    }

    /// The hosted activity's title, or nil when the request names one this device no longer hosts
    /// (the sheet then says "wants to join an activity" as a whole sentence).
    private func titleForActivity(_ id: UUID) -> String? {
        manager.hostedActivities.first(where: { $0.descriptor.activityID == id })?.descriptor.sanitizedTitle
    }

    /// "Walk · the park": the type in this device's words, then the host's place text as sent.
    ///
    /// The type is drawn through ``ActivityTypeOption/displayName(forToken:)``, never from the
    /// token's own spelling: the token is the sender's frozen English, so a capitalized token showed
    /// "Walk" on a Spanish phone.
    private func subtitle(type: String, location: String?) -> String {
        let t = type.isEmpty ? nil : ActivityTypeOption.displayName(forToken: type)
        // The descriptor is pinned as-received (to keep the paramsHash stable), so sanitize the coarse
        // location for display here.
        let loc = location.map { ItemNameModeration.sanitizedName($0) }.flatMap { $0.isEmpty ? nil : $0 }
        return [t, loc].compactMap { $0 }.joined(separator: " · ")
    }

    private func hostSubtitle(_ joined: ProximityActivityManager.JoinedActivity) -> String {
        let hostName = joined.lastSnapshot.participants
            .first(where: { $0.fingerprint == joined.descriptor.hostFingerprint })
            .flatMap { PeerNameDisplay.personName($0.displayName, fingerprint: $0.fingerprint, in: .fernlet) }
        let base = hostName.map {
            String(localized: "activities.joined.hostedBy", defaultValue: "Hosted by \($0)",
                   comment: "A joined activity's subtitle. %@ is the host's name. May be followed by ' · ' and the activity type and place.")
        } ?? String(localized: "activities.joined.noHostName", defaultValue: "Joined",
                    comment: "A joined activity's subtitle when the host's name is not known. May be followed by ' · ' and the activity type and place.")
        let extra = subtitle(type: joined.descriptor.activityTypeToken, location: joined.descriptor.coarseLocation)
        return extra.isEmpty ? base : "\(base) · \(extra)"
    }

    private func monogram(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "?" : String(trimmed.prefix(1)).uppercased()
    }

    // MARK: - Local model

    /// The member a "Remove member?" confirmation is about — captured when the minus button is
    /// tapped so the alert survives a roster refresh mid-confirmation.
    ///
    /// Cleared on both Remove and Cancel; `name` is pre-sanitized for the alert copy.
    private struct RemovalTarget: Equatable { let activityID: UUID; let fingerprint: String; let name: String }

    /// The host form's duration chips, mapped to the activity's absolute expiry.
    ///
    /// `seconds` is added to "now" at start time to produce the descriptor's `expiresAt`; expiry
    /// itself is then enforced by the manager (`gcExpired`) and rendered by ``ExpiryLabel``. Nothing
    /// about a duration is sent or stored but that expiry, so the chip's words are display only.
    private enum ActivityDurationOption: CaseIterable, Identifiable {
        case twoHours, oneDay, threeDays, sevenDays
        var id: Self { self }
        var seconds: TimeInterval {
            switch self {
            case .twoHours: return 2 * 3600
            case .oneDay: return 24 * 3600
            case .threeDays: return 3 * 24 * 3600
            case .sevenDays: return 7 * 24 * 3600
            }
        }

        /// The chip's words. One key per chip: each is a fixed phrase, not a count a rule picks.
        var displayName: String {
            switch self {
            case .twoHours:
                String(localized: "activities.duration.twoHours", defaultValue: "2 hours",
                       comment: "Activity length chip on the Start an activity form: the activity ends two hours from now")
            case .oneDay:
                String(localized: "activities.duration.oneDay", defaultValue: "1 day",
                       comment: "Activity length chip on the Start an activity form: the activity ends one day from now")
            case .threeDays:
                String(localized: "activities.duration.threeDays", defaultValue: "3 days",
                       comment: "Activity length chip on the Start an activity form: the activity ends three days from now")
            case .sevenDays:
                String(localized: "activities.duration.sevenDays", defaultValue: "7 days",
                       comment: "Activity length chip on the Start an activity form: the activity ends seven days from now")
            }
        }
    }

    /// The shared cream card treatment behind every activity entry (offered, hosted, joined).
    ///
    /// A modifier rather than a wrapper view so each section can keep its own content layout while
    /// the card chrome stays identical.
    private struct CardBackground: ViewModifier {
        func body(content: Content) -> some View {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WorldPalette.paper, in: RoundedRectangle(cornerRadius: FernletFramedLook.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: FernletFramedLook.cardRadius)
                    .strokeBorder(WorldPalette.ink, lineWidth: FernletFramedLook.frameWidth))
                .background { RoundedRectangle(cornerRadius: FernletFramedLook.cardRadius).fill(WorldPalette.ink.opacity(0.22)).offset(y: 3) }
        }
    }
}

/// An activity's type: the host form's chips (Walk, Coffee, …), and the one place a received type
/// token is turned back into words.
///
/// **A fork (Spanish round, 2026-10-20).** The raw value is the WIRE token, the word a host's
/// device writes into `ActivityDescriptor.activityTypeToken`. It rides the descriptor's canonical
/// bytes (`FeatureCanonicalBytes`), so every signed token and roster snapshot binds it through the
/// `activityParamsHash`, and it is kept in the device-local hosted and joined sidecars. It is frozen
/// English, byte for byte what every build since Group Activities (2026-07-12) has sent (it was the
/// chip's English label lowercased), and pinned by `LocalizationBoundaryTests.frozenActivityTypeTokens`.
/// The chip used to draw that English label, and the receiving phone drew the sender's token
/// capitalized, so a Spanish phone read "Walk" whatever its owner's language. ``displayName`` is the
/// localized word both sides now draw.
///
/// The token is forward-tolerant (`ActivityDescriptor.activityTypeToken`: "an unknown token just
/// renders generically"): a newer build may add a type, and any peer may send any word, so
/// ``displayName(forToken:)`` draws a token it does not know as received (sanitized), never
/// dropped and never re-cased.
enum ActivityTypeOption: String, CaseIterable, Identifiable {
    case walk, coffee, meal, study, workout, hangout, other
    var id: String { rawValue }

    /// The token this type is SENT as. Never localize: see the type's note.
    var token: String { rawValue }

    /// The chip's word, in this device's language.
    var displayName: String {
        switch self {
        case .walk:
            String(localized: "activities.type.walk", defaultValue: "Walk",
                   comment: "Activity type chip and label: going for a walk together")
        case .coffee:
            String(localized: "activities.type.coffee", defaultValue: "Coffee",
                   comment: "Activity type chip and label: meeting for coffee")
        case .meal:
            String(localized: "activities.type.meal", defaultValue: "Meal",
                   comment: "Activity type chip and label: sharing a meal")
        case .study:
            String(localized: "activities.type.study", defaultValue: "Study",
                   comment: "Activity type chip and label: studying together")
        case .workout:
            String(localized: "activities.type.workout", defaultValue: "Workout",
                   comment: "Activity type chip and label: exercising together")
        case .hangout:
            String(localized: "activities.type.hangout", defaultValue: "Hangout",
                   comment: "Activity type chip and label: spending time together, no set plan")
        case .other:
            String(localized: "activities.type.other", defaultValue: "Other",
                   comment: "Activity type chip and label: any other kind of activity")
        }
    }

    /// The words for a type token another device sent: this device's own word for a token it
    /// knows, and the received text as sent (sanitized) for one it does not.
    ///
    /// - Parameter token: The descriptor's `activityTypeToken`, exactly as received.
    /// - Returns: Display text.
    static func displayName(forToken token: String) -> String {
        ActivityTypeOption(rawValue: token)?.displayName ?? ItemNameModeration.sanitizedName(token)
    }
}

/// A live "Expires in …" / "Expired" label that ticks each minute.
///
/// A minute-period `TimelineView` is the only clock — no timers to invalidate — and the copy
/// flips to a terracotta "Expired" the moment the descriptor's `expiresAt` passes. Used on every
/// activity card in ``ActivitiesView``. Each reading is one whole sentence key ("Expires in %lld
/// min"), never "Expires " + a separately built phrase, so a translator can order it.
private struct ExpiryLabel: View {
    let expiresAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let remaining = expiresAt.timeIntervalSince(context.date)
            HStack(spacing: 5) {
                Image(systemName: "clock").font(.caption2)
                Self.text(remaining: remaining)
                    .font(.fernlet(.labelSmall))
            }
            .foregroundStyle(remaining <= 0 ? Color.terracotta : Color.slate)
        }
    }

    private static func text(remaining seconds: TimeInterval) -> Text {
        guard seconds > 0 else { return Text("Expired") }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return Text("Expires in \(max(1, minutes)) min") }
        let hours = minutes / 60
        if hours < 48 { return Text("Expires in \(hours) h") }
        return Text("Expires in \(hours / 24) days")
    }
}
