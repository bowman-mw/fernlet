import SwiftUI
import LocalPersistence
import FernletFoundation
import FernletDomainModel
import FernletScoring
import FoodCatalog
import PrivateHealthStore
import ProximityKit
import FernletConnections
import FernletSocial
import AppServices
import FernletUI

/// Gentle, low-cost "ambient" home surfaces (spec §12): an at-most-once-a-day gentle offer
/// (breathing / worry box / short walk), a looking-back journal card, a macro-gap meal nudge,
/// forgotten-favorite meal chips, a forgotten-good workout nudge, the gentle reminders (a forgotten
/// recipe or calm tool, last year's seasonal rhythm — `AmbientReminders.swift`), and a dismissible
/// preventive-care micronutrient bubble.
///
/// The gentle reminders, the meal chips and the workout nudge share one switch (Settings › Your day ›
/// Reminders › Gentle reminders) and the caps of `AmbientReminderSchedule`: each kind at most once a
/// month, at most two on one day, and "Not now" puts a kind away for a month. They read only unsealed
/// stores (CAP-2): meals, recipes, workouts, water and this iPhone's breathing finish dates.
///
/// Each card renders only when it has something worth surfacing, so the section quietly
/// disappears on a sparse day rather than nagging. Rendered by `HomeView`; the history reads
/// (full-day scans, weather) run once in the `.task`, off the per-render path. The looking-back
/// read runs on each appearance and only while the Private tab's journal is open (CAP-2).
struct AmbientCardsView: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?
    /// Calendar-math next-period outlook, already gated by the caller for opt-in + hide-predictions.
    /// Nil when there is nothing to show (locked, too few cycles, or surfacing turned off).
    var periodPrediction: CyclePrediction? = nil
    /// Today's opt-in body-signals reading, already gated by the caller on `stressAwarenessEnabled`
    /// (nil when opted out, cold-starting, or simply fine). One of the gentle-offer gates.
    var stressState: StressState? = nil
    /// The meal-logged toast. Both meal chips report what they logged to it, so a one-tap log from
    /// Home gets the same Undo, Adjust and spoken confirmation as a log from the meal sheet.
    var onMealsLogged: MealLogReporter = .none

    @State private var didLoad = false
    @State private var lookBack: LookBack?
    @State private var forgottenFavorites: [String] = []
    @State private var forgottenWorkout: String?
    /// Today's gentle reminders after the caps (meal chips and the workout nudge among them).
    @State private var reminders: [AmbientReminder] = []
    /// Today's friend card after the caps (one at most), and what its send button did.
    @State private var friendNudge: AmbientFriendNudge?
    @State private var friendNudgeOutcome: FriendNudgeOutcome?
    @State private var weatherPrompt: String?
    @State private var walkComfort: WeatherComfort?

    /// How far back the forgotten-good-workout scan reaches. The card compares "did this before" with
    /// "haven't lately", so a year is plenty — and it keeps the name-count dictionary bounded by a
    /// window instead of by the user's entire history.
    private static let forgottenWorkoutLookbackDays = 365

    /// One resurfaced journal moment for the looking-back card: the window label ("A year ago
    /// today") plus the entry text.
    ///
    /// Computed on each appearance by `computeLookBack()`, and only while the Private tab's journal
    /// is open (CAP-2): Home is not behind the lock, so it never decrypts sealed text on its own.
    struct LookBack: Equatable { let label: String; let text: String }

    var body: some View {
        VStack(spacing: 12) {
            receivedHeartCard
            gentleOfferCard
            lookingBackCard
            macroGapCard
            forgottenFavoritesCard
            forgottenWorkoutCard
            friendNudgeCard
            gentleReminderCards
            weatherCard
            periodPredictionBubble
            micronutrientBubble
        }
        .onAppear {
            // CAP-2: asked again on every appearance (no decryption at all while the journal is
            // closed), so a look-back read in one Private session is dropped once it closes.
            lookBack = computeLookBack()
        }
        .task {
            // History reads (decryption, full-day scan) are done once, off the per-render path.
            guard !didLoad else { return }
            didLoad = true
            let days = store.loadDays()
            let favorites = computeForgottenFavorites()
            let workout = computeForgottenWorkout(days: days)
            forgottenFavorites = favorites
            forgottenWorkout = workout
            // The friend card is chosen first, so a friend in the shared two-a-day limit comes before
            // the forgotten things and the seasons.
            friendNudge = chooseFriendNudge()
            reminders = chooseReminders(days: days, hasForgottenMeals: !favorites.isEmpty, hasForgottenWorkout: workout != nil)
            if store.settings.weatherPromptsEnabled {
                // Both reads share the service's ≤90-min conditions cache (one fetch, two prompts).
                weatherPrompt = await WeatherKitService.shared.moodRecoveryPrompt()
                walkComfort = await WeatherKitService.shared.currentComfort()
            }
        }
    }

    // MARK: - Received heart (good vibes from a friend)

    /// A warm, dismissible note when a friend sent good vibes in person — first name only, no
    /// counts, nothing numeric (good-vibes 10a). A floating dusty-rose heart badge crowns a soft
    /// cream bubble; tapping anywhere tucks it away. Dismissing hides the bubble; the health bar's
    /// golden warmth keeps fading on its own 24h clock.
    @ViewBuilder
    private var receivedHeartCard: some View {
        if let heart = store.pendingHeartBubble {
            Button {
                store.dismissHeartBubble(id: heart.id)
            } label: {
                // A soft cream bubble crowned by a floating dusty-rose heart that overlaps the
                // top edge (good-vibes 10a). The heart badge is drawn as an overlay so it can rise
                // half above the card; extra top padding inside keeps the title clear of it.
                FernletCard {
                    VStack(spacing: FernletMetrics.spaceSm) {
                        Text("Good vibes")
                            .font(.fernlet(.header))
                            .foregroundStyle(Color.bark)

                        Text("\(PresenceManager.firstName(of: heart.senderDisplayName, in: .fernlet)) sent you some warmth — a friend is thinking of you.")
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.slate)
                            .multilineTextAlignment(.center)
                            .fernletWrappingText()

                        Divider()
                            .overlay(Color.bark.opacity(0.08))
                            .padding(.top, FernletMetrics.spaceXs)

                        Text("tap to tuck away")
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.softTaupe)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
                    .padding(.bottom, FernletMetrics.spaceXs)
                }
                .overlay(alignment: .top) {
                    Image(systemName: "heart.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.dustyRose)
                        .frame(width: 44, height: 44)
                        .background(Color.cream, in: Circle())
                        .overlay(Circle().stroke(Color.dustyRose.opacity(0.22), lineWidth: 1))
                        .shadow(color: Color.terracotta.opacity(0.22), radius: 8, y: 4)
                        .offset(y: -22)
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 22)
            .accessibilityIdentifier("home.receivedHeart")
            .accessibilityLabel("Good vibes from \(PresenceManager.firstName(of: heart.senderDisplayName, in: .fernlet)). Tap to tuck away.")
            // Voice Control: the card draws "Good vibes" and "tap to tuck away"; either says it.
            .accessibilityInputLabels([Text("Tuck away"), Text("Good vibes")])
        }
    }

    // MARK: - Gentle offer (max one per day)

    /// One quiet invitation on a heavier day. Gated by the pure `GentleOfferEngine` (body signals
    /// tense/needs-care, or moodTrend "needs gentleness"); dismissing OR accepting consumes it
    /// until tomorrow (persisted via the settings dismissal map — see `DiaryStore`).
    @ViewBuilder
    private var gentleOfferCard: some View {
        if let kind = activeGentleOffer {
            FernletCard {
                HStack(alignment: .top, spacing: 12) {
                    Button {
                        acceptGentleOffer(kind)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            ambientIcon(kind.icon, tint: .moss)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("A gentle offer")
                                    .font(.fernlet(.labelSmall))
                                    // F3: text ink, not the `moss` accent (3.74:1, fails 4.5:1 small text).
                                    .foregroundStyle(Color.mossInk)
                                Text(kind.invitation)
                                    .font(.fernlet(.body))
                                    .foregroundStyle(Color.bark)
                                    .fernletWrappingText()
                                // The walk is the one offer the weather decides, so it credits it.
                                if kind == .shortWalk { AppleWeatherCaption() }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.gentleOffer")
                    Button {
                        store.dismissGentleOffer()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.slate)
                            .frame(width: 28, height: 28)
                            .background(Color.slate.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(.plain)
                    // The 28pt disc keeps its look; the target around it grows to 44pt.
                    .fernletIconButton("Not today")
                }
            }
        }
    }

    private var activeGentleOffer: GentleOfferKind? {
        guard store.isGentleOfferAvailableToday else { return nil }
        let moodTrend = store.derivedSignals.first { $0.signalName == "moodTrend" }?.value
        return GentleOfferEngine.offer(
            dateKey: store.todayKey,
            stressAwarenessEnabled: store.settings.stressAwarenessEnabled,
            stressState: stressState,
            moodTrendValue: moodTrend,
            walkIsInviting: (walkComfort?.isPleasant ?? false) && (walkComfort?.isDaytime ?? false)
        )
    }

    /// Accepting an offer opens the matching tool and consumes today's offer (the walk has no
    /// in-app tool — accepting it is simply a warm send-off).
    private func acceptGentleOffer(_ kind: GentleOfferKind) {
        // The yes landed (the card leaves until tomorrow); felt at the tap, before any sheet opens.
        FernletFeedback.system.play(.logged)
        store.dismissGentleOffer()
        switch kind {
        case .breathing:
            activeSheet = .firstAid(.breathing)
        case .worryBox:
            activeSheet = .firstAid(.worryBox)
        case .shortWalk:
            break
        }
    }

    // MARK: - Looking back

    @ViewBuilder
    private var lookingBackCard: some View {
        // CAP-2: re-checked at render, so text read while the journal was open never outlives it.
        if let lookBack, store.isSealedJournalOpen {
            FernletCard {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.goldenrod).frame(width: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lookBack.label)
                            .font(.fernlet(.labelSmall))
                            // T1-3: text ink, not the `goldenrod` accent (2.22:1). The bar at
                            // left stays the decorative accent.
                            .foregroundStyle(Color.goldenrodInk)
                        Text(lookBack.text)
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                            .lineLimit(4)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func computeLookBack() -> LookBack? {
        let windows: [(Int, String)] = [
            (365, String(localized: "home.lookBack.yearAgo", defaultValue: "A year ago today",
                         comment: "Home looking-back card: the label over a journal entry written exactly a year ago.")),
            (180, String(localized: "home.lookBack.sixMonthsAgo", defaultValue: "Six months ago",
                         comment: "Home looking-back card: the label over a journal entry written six months ago.")),
            (90, String(localized: "home.lookBack.threeMonthsAgo", defaultValue: "Three months ago",
                        comment: "Home looking-back card: the label over a journal entry written three months ago.")),
        ]
        for (days, label) in windows {
            guard let date = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { continue }
            // CAP-2: the store answers only while the Private tab's journal is open.
            if let text = store.lookBackJournalText(for: FernletDate.dayKey(for: date)) {
                return LookBack(label: label, text: text)
            }
        }
        return nil
    }

    // MARK: - Macro gap

    @ViewBuilder
    private var macroGapCard: some View {
        if let gap = macroGapSuggestion() {
            Button { activeSheet = .meal } label: {
                FernletCard {
                    HStack(spacing: 12) {
                        ambientIcon("fork.knife", tint: .fern)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Room for a little more")
                                .font(.fernlet(.header))
                                .foregroundStyle(Color.bark)
                            Text(gap)
                                .font(.fernlet(.body))
                                .foregroundStyle(Color.slate)
                                .fernletWrappingText()
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func macroGapSuggestion() -> String? {
        guard !store.day.meals.isEmpty else { return nil }
        let proteinGap = store.nutritionTargets.protein - store.macroTotals.protein
        guard proteinGap >= 20 else { return nil }
        return String(localized: "home.macroGap.protein",
                      defaultValue: "About \(proteinGap)g protein left today — yogurt, eggs, or chicken would help close it.",
                      comment: "Home 'Room for a little more' card: grams of protein still under today's target (always 20 or more), with a gentle suggestion. Never a scold.")
    }

    // MARK: - Forgotten favorites (food)

    @ViewBuilder
    private var forgottenFavoritesCard: some View {
        if !forgottenFavorites.isEmpty, isShowing(.forgottenMeal) {
            FernletCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Haven't had these in a while")
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)
                        .fernletWrappingText()
                    FlowLayout(spacing: 8) {
                        ForEach(forgottenFavorites, id: \.self) { name in
                            Button {
                                let meal = store.addMeal(from: name, date: store.todayKey)
                                forgottenFavorites.removeAll { $0 == name }
                                onMealsLogged([meal])
                            } label: {
                                Text(name)
                                    .font(.fernlet(.label))
                                    .foregroundStyle(Color.bark)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.goldenrod.opacity(0.16), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    notNowButton(.forgottenMeal)
                }
            }
        }
    }

    private func computeForgottenFavorites() -> [String] {
        let meals = store.recentMeals
        guard meals.count >= 5 else { return [] }
        let recentNames = Set(meals.prefix(7).map { $0.name.lowercased() })
        let counts = Dictionary(grouping: meals, by: { $0.name }).mapValues(\.count)
        return counts
            .filter { $0.value >= 2 && !recentNames.contains($0.key.lowercased()) }
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map(\.key)
    }

    // MARK: - Forgotten-good workout

    @ViewBuilder
    private var forgottenWorkoutCard: some View {
        if let name = forgottenWorkout, isShowing(.forgottenWorkout) {
            FernletCard {
                VStack(alignment: .leading, spacing: 8) {
                    Button { activeSheet = .workout } label: {
                        HStack(spacing: 12) {
                            ambientIcon("figure.run", tint: .moss)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Remember this one?")
                                    .font(.fernlet(.header))
                                    .foregroundStyle(Color.bark)
                                    .fernletWrappingText()
                                Text("You did \u{201C}\(name)\u{201D} before — it might feel good again.")
                                    .font(.fernlet(.body))
                                    .foregroundStyle(Color.slate)
                                    .fernletWrappingText()
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    notNowButton(.forgottenWorkout)
                }
            }
        }
    }

    /// The workout done at least twice in the last year and not in the last two weeks, by its drawn name.
    private func computeForgottenWorkout(days: [String: FernletDay]) -> String? {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) else { return nil }
        let cutoffKey = FernletDate.dayKey(for: cutoff)
        // R3: bound the scan (and therefore `counts`) to one year of history rather than the whole
        // diary — this hint only compares recent-vs-earlier, so unbounded growth buys nothing.
        guard let lookbackStart = Calendar.current.date(byAdding: .day, value: -Self.forgottenWorkoutLookbackDays, to: Date()) else { return nil }
        let lookbackKey = FernletDate.dayKey(for: lookbackStart)
        var counts: [String: Int] = [:]
        // Counted by the STORED name, drawn by `displayedName`: a blank-named activity is stored as
        // its English default ("Pool Swim"), which the card would otherwise quote in English.
        var shown: [String: String] = [:]
        var recent: Set<String> = []
        for (key, day) in days where key >= lookbackKey {
            for workout in day.workouts {
                let name = workout.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                counts[name, default: 0] += 1
                if shown[name] == nil {
                    shown[name] = workout.displayedName.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if key >= cutoffKey { recent.insert(name.lowercased()) }
            }
        }
        return counts
            .filter { $0.value >= 2 && !recent.contains($0.key.lowercased()) }
            .sorted { $0.value > $1.value }
            .first
            .map { shown[$0.key] ?? $0.key }
    }

    // MARK: - Gentle reminders (forgotten good things, seasonal rhythm)

    /// Whether today's caps let `kind` show.
    private func isShowing(_ kind: AmbientReminderKind) -> Bool {
        reminders.contains { $0.kind == kind }
    }

    /// The new reminders' cards (the meal chips and the workout draw their own above).
    @ViewBuilder
    private var gentleReminderCards: some View {
        ForEach(reminders.filter { AmbientReminderCopy.body(for: $0) != nil }, id: \.kind) { reminder in
            gentleReminderCard(reminder)
        }
    }

    /// What a friend card's "Send a heart" did: accepted for delivery, or the app's own refusal line.
    enum FriendNudgeOutcome: Equatable {
        /// The drop-off queue accepted the heart.
        case sent
        /// The queue refused it; the line is `AwayHeartsCopy.queueLine`'s answer.
        case refused(String)
    }

    /// The friend card: the owner's draft with "Send a heart" and "Not now", then "Heart on its way"
    /// once the queue accepted the heart.
    @ViewBuilder
    private var friendNudgeCard: some View {
        if let nudge = friendNudge {
            let companion = store.worldCompanionName
            let sent = friendNudgeOutcome == .sent
            let title = sent ? AmbientReminderCopy.friendSentTitle
                : AmbientReminderCopy.friendTitle(nudge.draft, name: nudge.firstName, companion: companion)
            let sentence = sent ? AmbientReminderCopy.friendSentBody(name: nudge.firstName)
                : AmbientReminderCopy.friendBody(nudge.draft, name: nudge.firstName, companion: companion)
            FernletCard {
                HStack(alignment: .top, spacing: 12) {
                    ambientIcon("heart", tint: .dustyRose)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.fernlet(.header))
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                        Text(sentence)
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                        if case .refused(let line) = friendNudgeOutcome {
                            Text(line)
                                .font(.fernlet(.bodySmall))
                                .foregroundStyle(Color.goldenrodInk)
                                .fernletWrappingText()
                                .accessibilityIdentifier("home.friendNudge.refused")
                        }
                        if !sent {
                            FlowLayout(spacing: 8) {
                                if friendNudgeOutcome == nil {
                                    Button { sendFriendHeart(nudge) } label: {
                                        Text(AmbientReminderCopy.friendSend)
                                            .font(.fernlet(.label))
                                            .foregroundStyle(Color.bark)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .frame(minHeight: 44)
                                            .background(Color.dustyRose.opacity(0.18), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("home.friendNudge.send")
                                }
                                Button { putAwayFriend(nudge) } label: {
                                    Text(AmbientReminderCopy.notNow)
                                        .font(.fernlet(.label))
                                        .foregroundStyle(Color.slate)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .frame(minHeight: 44)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("home.friendNudge.notNow")
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .accessibilityIdentifier("home.friendNudge.\(nudge.kind.rawValue)")
        }
    }

    /// "Send a heart": the same away-heart queue as the friend's row on Friends. "Heart on its way"
    /// only when the queue accepted it; otherwise the app's own line for why not. Either way the
    /// friend's cards rest for a month.
    private func sendFriendHeart(_ nudge: AmbientFriendNudge) {
        guard let peer = store.trustedProximityPeers.first(where: { $0.fingerprint == nudge.fingerprint }) else {
            friendNudgeOutcome = .refused(AwayHeartsCopy.queueLine(for: .failed, firstName: nudge.firstName, problem: nil))
            return
        }
        let outcome = store.heartDropService.queueHeart(to: peer)
        FernletFeedback.system.play(FriendListView.awayHeartEvent(for: outcome))
        friendNudgeOutcome = Self.friendNudgeOutcome(for: outcome, firstName: nudge.firstName)
        var schedule = AmbientReminderMemory.schedule()
        schedule.hideFriend(nudge.fingerprint, now: Date())
        AmbientReminderMemory.save(schedule)
    }

    /// What the card shows for a queue answer: "Heart on its way" only for `.queued`.
    static func friendNudgeOutcome(for outcome: HeartDropService.QueueOutcome, firstName: String) -> FriendNudgeOutcome {
        guard outcome == .queued else {
            return .refused(AwayHeartsCopy.queueLine(for: outcome, firstName: firstName, problem: nil))
        }
        return .sent
    }

    /// "Not now" on a friend card: that friend's cards rest for a month.
    private func putAwayFriend(_ nudge: AmbientFriendNudge) {
        var schedule = AmbientReminderMemory.schedule()
        schedule.hideFriend(nudge.fingerprint, now: Date())
        AmbientReminderMemory.save(schedule)
        friendNudge = nil
        friendNudgeOutcome = nil
    }

    /// One reminder: its title and sentence, its open button when it has one, and "Not now".
    private func gentleReminderCard(_ reminder: AmbientReminder) -> some View {
        FernletCard {
            HStack(alignment: .top, spacing: 12) {
                ambientIcon(Self.reminderIcon(reminder.kind), tint: reminder.kind.isSeasonal ? .goldenrod : .moss)
                VStack(alignment: .leading, spacing: 8) {
                    Text(AmbientReminderCopy.title(for: reminder) ?? "")
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)
                        .fernletWrappingText()
                    Text(AmbientReminderCopy.body(for: reminder) ?? "")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                    FlowLayout(spacing: 8) {
                        if let action = AmbientReminderCopy.action(for: reminder) {
                            Button { openReminder(reminder) } label: {
                                Text(action)
                                    .font(.fernlet(.label))
                                    .foregroundStyle(Color.bark)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.moss.opacity(0.16), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("home.reminder.\(reminder.kind.rawValue).open")
                        }
                        notNowButton(reminder.kind)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityIdentifier("home.reminder.\(reminder.kind.rawValue)")
    }

    /// The decorative icon for a reminder kind.
    private static func reminderIcon(_ kind: AmbientReminderKind) -> String {
        switch kind {
        case .forgottenRecipe, .seasonalSoup: "book"
        case .forgottenCalm: "wind"
        case .seasonalWalks: "figure.walk"
        case .seasonalWorkouts, .forgottenWorkout: "figure.run"
        case .seasonalWater: "drop"
        case .forgottenMeal: "fork.knife"
        }
    }

    /// "Not now": puts `kind` away for a month and takes its card off Home.
    private func notNowButton(_ kind: AmbientReminderKind) -> some View {
        Button { putAway(kind) } label: {
            Text(AmbientReminderCopy.notNow)
                .font(.fernlet(.label))
                .foregroundStyle(Color.slate)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.reminder.\(kind.rawValue).notNow")
    }

    /// Hides `kind` for a month (the schedule's "Not now") and drops its card from today's list.
    private func putAway(_ kind: AmbientReminderKind) {
        var schedule = AmbientReminderMemory.schedule()
        schedule.hide(kind, now: Date())
        AmbientReminderMemory.save(schedule)
        reminders.removeAll { $0.kind == kind }
    }

    /// The open button: the recipe, the calm tool on the pattern the card named, or the recipe book to
    /// find a soup. Opening also puts the card away for the month — it did its job.
    private func openReminder(_ reminder: AmbientReminder) {
        switch reminder.subject {
        case .recipe(let id, _):
            if let recipe = store.recipes.first(where: { $0.id == id }) {
                activeSheet = .editRecipe(recipe)
            } else if let saved = store.savedRecipes.first(where: { $0.id == id }) {
                activeSheet = .editSavedRecipe(saved)
            } else {
                activeSheet = .recipeBook
            }
        case .calm(let tool):
            if let presetID = tool.breathingPresetID {
                // The breathing screen opens on the pattern the card named (its own stored choice).
                UserDefaults.standard.set(presetID, forKey: "fernlet.breathing.presetID")
                activeSheet = .firstAid(.breathing)
            } else {
                activeSheet = .firstAid(.grounding)
            }
        case .season, .none:
            activeSheet = .recipeBook
        }
        putAway(reminder.kind)
    }

    /// Today's reminders after the caps, from unsealed history only (CAP-2); none while the Gentle
    /// reminders switch is off. Records what showed, so the monthly and daily caps hold.
    private func chooseReminders(days: [String: FernletDay], hasForgottenMeals: Bool,
                                 hasForgottenWorkout: Bool) -> [AmbientReminder] {
        guard store.settings.gentleRemindersEnabled else { return [] }
        let now = Date()
        let history = AmbientHistory.gather(days: days, recipes: store.recipes + store.savedRecipes, now: now)
        let found = AmbientReminderFinder.candidates(
            history: history, calmFinishes: AmbientReminderMemory.calmFinishes(),
            hasForgottenMeals: hasForgottenMeals, hasForgottenWorkout: hasForgottenWorkout,
            now: now, southern: AmbientSeason.isSouthern(region: Locale.current.region?.identifier))
        var schedule = AmbientReminderMemory.schedule()
        let chosen = schedule.choose(from: found.map(\.kind), dayKey: store.todayKey, now: now)
        AmbientReminderMemory.save(schedule)
        return found.filter { chosen.contains($0.kind) }
    }

    /// Today's friend card after the caps; none while the Gentle reminders switch is off. Reads only
    /// what Friends shows unlocked (CAP-2): names and last-met dates from the trust vault, and the
    /// fuzzy vibe a friend shared in person.
    private func chooseFriendNudge() -> AmbientFriendNudge? {
        guard store.settings.gentleRemindersEnabled else { return nil }
        let now = Date()
        let found = AmbientFriendNudgeFinder.candidates(friends: nudgeFriends(), dayKey: store.todayKey, now: now)
        var schedule = AmbientReminderMemory.schedule()
        let chosen = schedule.chooseFriend(from: found, dayKey: store.todayKey, now: now)
        AmbientReminderMemory.save(schedule)
        return chosen
    }

    /// The kept friends as the friend nudges see them. A heart can go only while hearts and delivery
    /// while apart are on with nothing failing (Home has no consent step of its own), the friend is
    /// not blocked or revoked, and no heart to them is settling.
    private func nudgeFriends() -> [AmbientFriend] {
        let awayReady = store.settings.allowNearbyHearts && store.settings.heartsAwayDelivery
            && store.heartDropService.deliveryProblem == nil
        return store.trustedProximityPeers.map { peer in
            let canSend = awayReady && peer.blockedAt == nil && peer.revokedAt == nil
                && !peer.keyAgreementPublicKey.isEmpty && store.heartLedger.canSendHeart(to: peer.fingerprint)
            return AmbientFriend(
                fingerprint: peer.fingerprint,
                firstName: PeerNameDisplay.firstName(peer.displayName, fingerprint: peer.fingerprint, placeholder: .met, in: .fernlet),
                lastVibeWasLow: store.cachedFriendState(fingerprint: peer.fingerprint)?.fuzzyState == .struggling,
                lastMetAt: peer.lastSeenAt,
                canReceiveHeart: canSend)
        }
    }

    // MARK: - Weather-aware recovery

    @ViewBuilder
    private var weatherCard: some View {
        if let weatherPrompt {
            FernletCard {
                HStack(alignment: .top, spacing: 12) {
                    ambientIcon("cloud.rain", tint: .slate)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A gentler day")
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.slate)
                        Text(weatherPrompt)
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                        AppleWeatherCaption()
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Period outlook

    @ViewBuilder
    private var periodPredictionBubble: some View {
        if let prediction = periodPrediction {
            FernletCard {
                HStack(alignment: .top, spacing: 12) {
                    ambientIcon("calendar", tint: .dustyRose)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cycle outlook")
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.dustyRose)
                        Text(periodOutlookText(prediction))
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// The outlook sentence: one whole sentence per confidence tier, never a qualifier fragment
    /// spliced into an English sentence, with the date window as its one placeholder.
    private func periodOutlookText(_ prediction: CyclePrediction) -> String {
        let start = FernletDate.shortDate(for: prediction.likelyStartRange.lowerBound)
        let end = FernletDate.shortDate(for: prediction.likelyStartRange.upperBound)
        let window = start == end ? start : String(
            localized: "home.cycleOutlook.window", defaultValue: "\(start)–\(end)",
            comment: "Home cycle outlook: the range of days the next period is likely to start, e.g. 'Mar 3–Mar 6'. Both are short dates.")
        if prediction.confidence >= 0.7 {
            return String(localized: "home.cycleOutlook.likely",
                          defaultValue: "Your next period is likely around \(window). Gentle planning, no pressure.",
                          comment: "Home cycle outlook card. The placeholder is a short date or a date range. Calm, never a countdown.")
        }
        if prediction.confidence >= 0.4 {
            return String(localized: "home.cycleOutlook.settling",
                          defaultValue: "Your next period is likely around \(window), still settling. Gentle planning, no pressure.",
                          comment: "Home cycle outlook card while the prediction is still settling (moderate confidence). The placeholder is a short date or a date range.")
        }
        return String(localized: "home.cycleOutlook.early",
                      defaultValue: "Your next period is likely around \(window), an early estimate. Gentle planning, no pressure.",
                      comment: "Home cycle outlook card while the prediction is only an early estimate (low confidence). The placeholder is a short date or a date range.")
    }

    // MARK: - Preventive-care micronutrient bubble

    @ViewBuilder
    private var micronutrientBubble: some View {
        if let suggestion = activeNutrientSuggestion() {
            let gap = suggestion.gap
            FernletCard {
                HStack(alignment: .top, spacing: 12) {
                    ambientIcon("leaf", tint: .fern)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(NutrientNudgeCopy.headline)
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.fern)
                        Text(nutrientCopy(for: suggestion))
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                        // "add it": log one serving of the curated food, grounded in its PINNED
                        // catalog FoodItem (real macros + the actual micronutrient profile that
                        // carries the nudged nutrient) rather than re-parsing the display name as
                        // free text — which fabricates macros and binds an arbitrary branded row
                        // that often carries none of the nudged nutrient, suppressing the nudge
                        // without moving the gap. Only offered when a 14-day gap named a food;
                        // accepting consumes the per-nutrient suppression.
                        if let food = suggestion.foods.first {
                            Button {
                                // R7: a nil is an unresolvable pinned food, i.e. nothing was
                                // logged. Recovery is to leave the bubble standing — dismissing it
                                // would retire the nudge for a meal that never landed.
                                guard let meal = store.logNutrientSuggestionFood(food, date: store.todayKey) else {
                                    FernletAuditLog.log(
                                        "food.nutrientSuggestion.logFailed",
                                        context: ["nutrient": food.nutrientKey]
                                    )
                                    return
                                }
                                store.dismissNutrientBubble(gap.nutrientKey)
                                onMealsLogged([meal])
                            } label: {
                                Text(NutrientNudgeCopy.addButtonLabel(food: food))
                                    .font(.fernlet(.label))
                                    .foregroundStyle(Color.bark)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.fern.opacity(0.16), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add \(food.displayName) to today")
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        store.dismissNutrientBubble(gap.nutrientKey)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.slate)
                            .frame(width: 28, height: 28)
                            .background(Color.slate.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(.plain)
                    // The 28pt disc keeps its look; the target around it grows to 44pt.
                    .fernletIconButton("Dismiss nutrient nudge")
                }
            }
        }
    }

    private func nutrientCopy(for plan: NutrientNudgePlanner.Plan) -> String {
        plan.namesFoods
            ? NutrientNudgeCopy.suggestion(nutrientName: plan.gap.nutrientName, foods: plan.foods)
            : NutrientNudgeCopy.passive(nutrientName: plan.gap.nutrientName)
    }

    /// Delegates to the pure `NutrientNudgePlanner` (which dedups the 7/14-day signals —
    /// §3.5 bug fix — keeps the passive card on the 7-day window, and names curated foods
    /// only for a 14-day gap, per decision §11.1). Suppression uses the same
    /// per-nutrient-key `nutrientBubbleDismissedUntil` window as before.
    private func activeNutrientSuggestion() -> NutrientNudgePlanner.Plan? {
        NutrientNudgePlanner.plan(
            from: store.derivedSignals.flatMap(\.nutrientGaps),
            sources: CuratedNutrientSources.shared,
            isActive: { store.isNutrientBubbleActive(for: $0) }
        )
    }

    // MARK: - Shared

    private func ambientIcon(_ systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.headline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(tint.opacity(0.14), in: Circle())
    }
}
