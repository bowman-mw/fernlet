// R8: the one custom condition (Docs/Power-of-10-Swift.md §R8) — the App Review demo build only.
#if FERNLET_DEMO
import SwiftUI
import FernletDomainModel
import FernletLock
import FernletUI
import PrivateHealthStore

/// Welcome's second, quieter button, under Continue: "Look around with sample data".
///
/// Shows a spinner while ``ReviewDemo`` sets the passcode and plants the sample data (a few seconds:
/// the photos are sealed), and a line under it if the passcode could not be set up.
struct ReviewDemoStartLink: View {
    /// The onboarding model's demo start (`OnboardingCoordinatorModel.startReviewDemo`).
    let start: (FernletLockService) async -> Bool
    @Environment(FernletLockService.self) private var lockService
    @State private var isStarting = false
    @State private var didFail = false

    var body: some View {
        VStack(spacing: 6) {
            Button {
                begin()
            } label: {
                HStack(spacing: 8) {
                    if isStarting { ProgressView() }
                    Text("Look around with sample data")
                        .font(.fernlet(.body))
                        .underline()
                }
                .foregroundStyle(WorldPalette.mossInk)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(isStarting)
            .accessibilityHint(Text("Fills Fernlet with sample data so you can see every screen. Leave the demo in Settings."))
            .accessibilityIdentifier("onboarding.welcome.reviewDemo")
            if didFail {
                Text("Couldn't start the demo. Try again.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.terracotta)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func begin() {
        guard !isStarting else { return }
        isStarting = true
        didFail = false
        Task {
            let started = await start(lockService)
            isStarting = false
            didFail = !started
        }
    }
}

/// The first Settings section while the demo runs: says this is sample data, gives the Private
/// passcode, and leaves the demo (erase everything, back to Welcome).
struct ReviewDemoSettingsSection: View {
    /// The app's store, which the leave erases.
    let store: FernletStore
    @Environment(FernletLockService.self) private var lockService
    @State private var pendingLeave: DestructiveConfirmation?
    @State private var isLeaving = false
    @State private var didFail = false

    var body: some View {
        if ReviewDemo.isActive {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("You're looking at sample data")
                        .font(.fernlet(.body).weight(.semibold))
                    Text("Private passcode: \(ReviewDemo.passcode)")
                        .font(.fernlet(.bodySmall))
                    Text("Nothing here reaches iCloud or Apple Health. \(FernletStore.reviewDemoFriendName) is a pretend friend; meeting real friends needs two iPhones in the same room.")
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(WorldPalette.dim)
                        .fernletWrappingText()
                }
                .padding(.vertical, 7)
                .accessibilityElement(children: .combine)
                Button(role: .destructive) {
                    pendingLeave = DestructiveConfirmation(
                        title: "Leave the demo?",
                        message: "All sample data and the demo passcode are erased, and Fernlet starts again from Welcome.",
                        confirmLabel: "Erase sample data",
                        auditEvent: "reviewDemo.leave"
                    ) { await leave() }
                } label: {
                    HStack {
                        Text("Leave demo and start fresh")
                        if isLeaving { Spacer(); ProgressView() }
                    }
                    .foregroundStyle(Color.terracotta)
                }
                .disabled(isLeaving)
                .accessibilityIdentifier("settings.reviewDemo.leave")
                if didFail {
                    Text("Couldn't erase all the sample data. Try again.")
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.terracotta)
                }
            } header: {
                SectionLabel("Demo")
            }
            .listRowBackground(Color.cream)
            .destructiveConfirmation($pendingLeave)
        }
    }

    private func leave() async {
        guard !isLeaving else { return }
        isLeaving = true
        didFail = false
        let left = await ReviewDemo.leave(store: store, lockService: lockService)
        isLeaving = false
        didFail = !left
    }
}

/// `ContentView`'s two demo hooks, kept out of its `body` (Power-of-10 R4).
///
/// - The demo's intimacy entries are owed from onboarding — only `ContentView` may build the intimacy
///   funnel — and are written the first time the Private hub opens.
/// - The pretend friend's memory-only shop reopens once launch finishes, at every launch.
struct ReviewDemoLaunchHooks: ViewModifier {
    /// The app's store.
    let store: FernletStore
    /// `ContentView`'s intimacy funnel, the one the seed writes through.
    let intimacyStore: IntimacyLogStore
    /// Whether `ContentView`'s launch has finished.
    let isLaunchDone: Bool
    @Environment(FernletLockService.self) private var lockService

    func body(content: Content) -> some View {
        content
            .onChange(of: lockService.state) { _, newState in
                guard newState.isUnlocked(for: .privateHub),
                      let key = lockService.contentKey(for: .privateHub) else { return }
                store.seedReviewDemoIntimacyIfPending(in: intimacyStore, privateHubKey: key)
            }
            .task(id: isLaunchDone) {
                if isLaunchDone { store.refreshReviewDemoFriendShop() }
            }
    }
}

/// The demo passcode, over the Private tab's passcode screen while the demo runs, so nobody has to
/// look it up.
struct ReviewDemoPasscodeHint: View {
    /// Whether the hub is still closed; the hint goes once it opens.
    let isLocked: Bool

    var body: some View {
        if isLocked && ReviewDemo.isActive {
            Text("Demo passcode: \(ReviewDemo.passcode)")
                .font(.fernlet(.bodySmall).weight(.semibold))
                .foregroundStyle(WorldPalette.bark)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.cream))
                .padding(.top, 8)
                .accessibilityIdentifier("private.reviewDemo.passcodeHint")
        }
    }
}
#endif
