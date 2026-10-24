import SwiftUI
import FernletDomainModel
import FernletFoundation
import FernletUI

/// The "Period & sensitive content" settings page (2026-08-21 hub restructure, artboard 5a —
/// SETT-14): the period/intimacy visibility gates as a first-class pushed page, because they gate
/// sensitive surfaces across the whole app.
///
/// Ported from the hub's former Period and Intimacy sections with semantics unchanged:
/// - Turning a tracking surface OFF is confirmed through ``DestructiveConfirmation`` (hiding keeps
///   the data, but changes what Fernlet reads and how the score behaves); turning it back ON is
///   not.
/// - The cosmetic cycle sub-options (predictions, fertile window, period-aware care) are offered
///   only while the hard gate is on — they still read cycle data.
/// - Under the intimacy age floor the toggle is replaced by ``AgeGateNotice`` — age is a floor,
///   not a preference, so no toggle that would silently do nothing.
/// - The visibility values consumed everywhere else remain the DERIVED
///   `FernletStore.sensitiveSurfaceVisibility` halves; this page only drives the setters.
///
/// The App lock link at the bottom completes the page's promise ("Visibility, gating, app lock"):
/// hiding controls what renders; the lock controls who can open what does render.
struct PeriodSensitiveSettingsView: View {
    @Bindable var store: FernletStore
    /// Confirmation for the two hide toggles — same shared alert every destructive Settings
    /// change uses; the mutation lives only inside `perform`.
    @State private var pendingDestructiveAction: DestructiveConfirmation?
    /// Advanced period tracking, mirrored from ``CyclePreferences`` (device-only defaults are not
    /// observable) and written back through it, which ignores a decoy session's writes.
    @State private var advancedTracking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(
                    title: "Period & sensitive content",
                    subtitle: "What Fernlet shows, reads, and protects.",
                    identifier: "screen.settings.periodSensitive",
                    // The longest page title in Settings: at the display face it needs a third line
                    // on a 402pt screen and truncates at the default two, which the audit reports as
                    // clipped text. This is what `titleLineLimit` exists for.
                    titleLineLimit: 3
                )
                periodCard
                intimacyCard
                appLockLink
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .padding(.bottom, 20)
        }
        .scrollContentBackground(.hidden)
        // World (b3-period-settings): the dotted page under the plate, whose Back names Settings and
        // shortens to its arrow for this long title.
        .fernletPageBackground()
        .fernletPushedPage(LocalizedStringResource("Period & sensitive content"))
        .navigationBarTitleDisplayMode(.inline)
        .destructiveConfirmation($pendingDestructiveAction)
        .onAppear { advancedTracking = CyclePreferences.advancedTracking(duressSessionActive: store.duressSessionActive) }
    }

    // MARK: - Period

    /// World (b3-period-settings): the section label above a framed card of switches; Advanced period
    /// tracking (new) sits under Period tracking, and the footer stays under the switches.
    private var periodCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Period")
            VStack(alignment: .leading, spacing: 14) {
                hubToggle("Period tracking", isOn: periodTrackingVisibleBinding)
                    .accessibilityIdentifier("settings.period.visible")
                // Cosmetic sub-options: these still read cycle data, so they only make sense — and
                // are only offered — while the hard gate above is on.
                if store.isPeriodTrackingVisible {
                    advancedTrackingToggle
                    hubToggle("Hide predictions", isOn: Binding(
                        get: { store.settings.hidePredictions },
                        set: { store.setHidePredictions($0) }
                    ))
                    hubToggle("Hide fertile window", isOn: Binding(
                        get: { store.settings.hideFertileWindow },
                        set: { store.setHideFertileWindow($0) }
                    ))
                    hubToggle("Period-aware care", isOn: Binding(
                        get: { store.settings.periodAwareScoringEnabled },
                        set: { store.setPeriodAwareScoringEnabled($0) }
                    ))
                }
                settingsFootnote(Text(periodFooter))
            }
            .modifier(PeriodSettingsCardFrame())
        }
    }

    /// Advanced period tracking (`b3-period-settings`, new): off by default; on, Log period offers every
    /// symptom and observation. Device-only (``CyclePreferences``); a decoy session's switch changes
    /// nothing that persists.
    private var advancedTrackingToggle: some View {
        Toggle(isOn: Binding(
            get: { advancedTracking },
            set: { newValue in
                advancedTracking = newValue
                CyclePreferences.setAdvancedTracking(newValue, duressSessionActive: store.duressSessionActive)
            }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Advanced period tracking")
                    .font(FernletFramedFont.rowTitle.weight(.semibold))
                    .foregroundStyle(WorldPalette.bark)
                Text("Log every symptom, cervical mucus, ovulation tests, basal temperature and spotting between periods.",
                     comment: "Settings › Period & sensitive content: the line under the Advanced period tracking switch, saying what it adds to Log period.")
                    .font(FernletFramedFont.rowDetail)
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
            }
        }
        .accessibilityIdentifier("settings.period.advanced")
    }

    /// A footnote under a card's switches, in the dim ink.
    private func settingsFootnote(_ text: Text) -> some View {
        text
            .font(FernletFramedFont.note)
            .foregroundStyle(WorldPalette.dim)
            .fernletWrappingText()
    }

    private var periodFooter: LocalizedStringKey {
        store.isPeriodTrackingVisible
            ? "When on, gentle cycle-phase trends can soften your daily score and surface a cycle chip and outlook on Home. Off by default, and only takes effect after a few cycles are logged.\n\nTurning off Period tracking hides every cycle surface and stops Fernlet reading your cycle data. Your entries are kept, not deleted."
            : "Cycle surfaces are hidden and Fernlet isn't reading your cycle data. Your entries are kept — turn this back on any time to see them again. Entries in Apple Health stay there either way."
    }

    // MARK: - Intimacy

    private var intimacyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Intimacy")
            VStack(alignment: .leading, spacing: 14) {
                if store.isIntimateLoggingAllowed {
                    hubToggle("Intimacy tracking", isOn: intimacyTrackingVisibleBinding)
                        .accessibilityIdentifier("settings.intimacy.visible")
                    settingsFootnote(Text(intimacyFooter))
                } else {
                    // Age is a floor, not a preference — say the true reason rather than showing a
                    // toggle that would silently do nothing. The notice also carries the only way back
                    // for someone who installed before this gate existed, or who has had a birthday.
                    AgeGateNotice(
                        gate: .intimacy,
                        feature: .intimacyTracking,
                        ageAssurance: store.ageAssurance
                    )
                }
            }
            .modifier(PeriodSettingsCardFrame())
        }
    }

    private var intimacyFooter: LocalizedStringKey {
        store.settings.intimacyTrackingVisible
            ? "Private intimacy notes, sealed on this device. Turning this off hides the feature and stops Fernlet reading it. Your notes are kept, not deleted."
            : "Intimacy surfaces are hidden and Fernlet isn't reading them. Your notes are kept — turn this back on any time. Entries in Apple Health stay there either way."
    }

    // MARK: - App lock

    /// Completes the page's "app lock" promise: hiding governs what renders, the lock governs who
    /// can open what does render.
    private var appLockLink: some View {
        NavigationLink(value: SettingsRoute.appLock) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    // World: the pixel lock and the pixel chevron.
                    FernletIcon(.lock, scale: 2)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    Text("App lock")
                        .font(FernletFramedFont.rowTitle.weight(.semibold))
                        .foregroundStyle(WorldPalette.bark)
                    Spacer()
                    FernletIcon(.chevron, scale: 2)
                        .accessibilityHidden(true)
                }
                Text("Private journal, cycle and intimacy notes can sit behind Fernlet's own passcode.")
                    .font(FernletFramedFont.rowDetail)
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(PeriodSettingsCardFrame())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.periodSensitive.appLock")
    }

    // MARK: - Bindings

    /// Turning cycle tracking OFF is confirmed; turning it back ON is not. Hiding is not
    /// destructive — entries are kept — but it has a consequence the user cannot otherwise
    /// predict: cycle-phase softening stops, so on a hard cycle day their score drops right after
    /// they chose privacy. Saying so up front is the difference between a considered choice and an
    /// unexplained punishment.
    private var periodTrackingVisibleBinding: Binding<Bool> {
        Binding(
            get: { store.isPeriodTrackingVisible },
            set: { newValue in
                guard !newValue else {
                    store.setPeriodTrackingVisible(true)
                    return
                }
                pendingDestructiveAction = DestructiveConfirmation(
                    title: "Turn off period tracking?",
                    message: """
                        Fernlet will hide every cycle surface and stop reading your cycle data. \
                        Your entries are kept — turn this back on any time to see them again.

                        Your daily score may change: Fernlet will stop softening it around your cycle. \
                        Anything you've saved in Apple Health stays in Apple Health.
                        """,
                    confirmLabel: "Turn off",
                    auditEvent: "settings.period.hideConfirmed"
                ) {
                    store.setPeriodTrackingVisible(false)
                }
            }
        )
    }

    private var intimacyTrackingVisibleBinding: Binding<Bool> {
        Binding(
            get: { store.settings.intimacyTrackingVisible },
            set: { newValue in
                guard !newValue else {
                    store.setIntimacyTrackingVisible(true)
                    return
                }
                pendingDestructiveAction = DestructiveConfirmation(
                    title: "Turn off intimacy tracking?",
                    message: """
                        Fernlet will hide intimacy logging and stop reading it. Your notes are \
                        kept — turn this back on any time to see them again.

                        Anything you've saved in Apple Health stays in Apple Health.
                        """,
                    confirmLabel: "Turn off",
                    auditEvent: "settings.intimacy.hideConfirmed"
                ) {
                    store.setIntimacyTrackingVisible(false)
                }
            }
        )
    }

    /// A switch in the app's type system — the same shape as the hub's `hubToggle`, local to this
    /// page (`LocalizedStringKey`, never `String`: a `String` parameter silently opts call sites
    /// out of localization).
    private func hubToggle(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(FernletFramedFont.rowTitle.weight(.semibold))
                .foregroundStyle(WorldPalette.bark)
        }
    }
}

/// A card on the Period & sensitive content page (`b3-period-settings`): the framed paper card of the
/// design language, the content 16 pt in.
private struct PeriodSettingsCardFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fernletFramed(WorldTheme.framedLook, fill: WorldPalette.paper, cornerRadius: FernletFramedLook.cardRadius)
    }
}
