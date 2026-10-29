import FernletDomainModel
import FernletUI
import SwiftUI

/// The Bathroom tile's pixel art (`bb-bowel`, the mockup's `ROLL`): a toilet roll in ink on paper,
/// drawn at the Log panel's scale beside the other tiles' sprites. The Day calendar can reuse it for
/// its Bathroom visits rows.
nonisolated enum BathroomRollSprite {
    /// The roll, key for key from the approved mockup.
    static let roll = WorldSprite(
        rows: [".kkkkkk..", "kwwwwwwk.", "kw.kk.wk.", "kw.kk.wkk", "kwwwwwwkw", "kwwwwwwkw", "kwwwwwwkw", "kwwwwwwk.", ".kkkkkk.."],
        palette: ["k": 0x4A2E1C, "w": 0xFFF6E2])
}

/// What one Bathroom tap or fix feels like, from what the sealed store did with it. Pure, so the
/// rule is tested without a device.
enum BathroomTileFeedback {
    /// The haptic for a write's result: `logged` when it landed, `limit` at the day's 30, `failed`
    /// when it did not land (always with words, ``announcesFailure(_:)``). A decoy feels like an
    /// ordinary tap and shows no error; a write that changed nothing plays nothing.
    static func event(for result: BodyTallyWriteResult) -> FernletFeedbackEvent? {
        switch result {
        case .saved, .droppedInDecoy: .logged
        case .atLimit: .limit
        case .unchanged: nil
        case .failed: .failed
        }
    }

    /// Whether the result is a write that did not land, which is said aloud so it is never silent.
    static func announcesFailure(_ result: BodyTallyWriteResult) -> Bool {
        if case .failed = result { return true }
        return false
    }

    /// The fix sheet's count clamped to what a day holds (`0...30`, the store's own cap).
    static func clamped(_ count: Int) -> Int {
        min(max(count, 0), BathroomCountSheet.maximumVisits)
    }
}

/// The Log panel's Bathroom tile (World bodybuilding spec §5, `bb-bowel`): shown only while the
/// Bodybuilding goal is chosen. One tap adds one visit to today's sealed count; holding it opens
/// ``BathroomCountSheet`` to fix the count. It reads "Bathroom, 2 today" and is a button that adds
/// one, with a "Fix the count" action; Voice Control knows it by its drawn name, "Bathroom". In a
/// decoy session it shows no count and a tap keeps nothing, with no error.
struct BathroomQuickLogTile: View {
    var store: FernletStore
    /// The drawn state at accessibility sizes: the bare figure.
    var shortState: Bool
    @State private var isFixingCount = false
    @Environment(\.fernletFramedLook) private var look

    private var count: Int {
        _ = store.bodyTallyChangeToken
        return store.bathroomVisits(on: store.todayKey)
    }

    var body: some View {
        face
            .contentShape(Rectangle())
            .onTapGesture { addOne() }
            .onLongPressGesture(minimumDuration: 0.45) {
                // A custom long press gets no press feel from the system, so say it was caught.
                FernletFeedback.system.play(.held)
                isFixingCount = true
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Bathroom, \(stateText(short: false))"))
            .accessibilityHint(Text("Adds one."))
            .accessibilityInputLabels([Text("Bathroom")])
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { addOne() }
            .accessibilityAction(named: Text("Fix the count")) { isFixingCount = true }
            .accessibilityIdentifier("home.quickLog.bathroom")
            .sheet(isPresented: $isFixingCount) {
                BathroomCountSheet(store: store)
            }
    }

    /// The tile's face: the framed paper tile in the World look, today's plain tile without it.
    @ViewBuilder private var face: some View {
        if let look {
            WorldQuickLogTileFace(icon: WorldLogIcon(sprite: BathroomRollSprite.roll),
                                  noun: Text("Bathroom"), state: stateText(short: shortState), look: look)
        } else {
            VStack(spacing: 3) {
                Image(systemName: FernletShortcut.bathroom.systemImage)
                    .font(.title3)
                Text("Bathroom")
                    .font(.custom(FernletFontName.dmSansMedium, size: 12, relativeTo: .caption))
                stateText(short: shortState)
                    .font(.custom(FernletFontName.dmSans, size: 11, relativeTo: .caption))
                    .foregroundStyle(Color.slate)
                    .contentTransition(.numericText())
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(count > 0 ? Color.moss : Color.slate)
        }
    }

    /// "2 today", or "none yet"; the bare figure when `short`.
    private func stateText(short: Bool) -> Text {
        let visits = count
        if visits == 0 { return Text("none yet") }
        return short ? Text(verbatim: "\(visits)") : Text("\(visits) today")
    }

    /// The tap: one more visit today, felt as it landed (``BathroomTileFeedback``).
    private func addOne() {
        let result = withAnimation(.easeInOut(duration: 0.18)) {
            store.addBathroomVisit(on: store.todayKey)
        }
        BathroomTileFeedback.report(result)
    }
}

extension BathroomTileFeedback {
    /// Plays the result's haptic and, for a write that did not land, says so.
    static func report(_ result: BodyTallyWriteResult) {
        if let event = event(for: result) { FernletFeedback.system.play(event) }
        guard announcesFailure(result) else { return }
        FernletAnnouncer.system.announce(.error, LocalizedStringResource(
            "bathroom.notSaved", defaultValue: "That bathroom count didn't save. Try again.",
            comment: "Log panel, Bathroom tile (Bodybuilding goal): spoken when a tap or a fixed count could not be saved on the device"))
    }
}

/// The Bathroom tile's hold-to-fix sheet: today's count with − and +, 0 to 30, saved on Done. A count
/// per day, nothing else.
struct BathroomCountSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    /// Nil until seeded on appear, so the sheet opens on the saved count.
    @State private var draft: Int?

    /// The most visits a day holds, the sealed store's own cap.
    static let maximumVisits = 30

    private var saved: Int { store.bathroomVisits(on: store.todayKey) }
    private var value: Int { draft ?? saved }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Bathroom", subtitle: "A count for today.", onCancel: { dismiss() }, onDone: save)
            ScrollView {
                VStack(spacing: 18) {
                    Text(verbatim: "\(value)")
                        .font(.custom(FernletFontName.frauncesSemiBold, size: 76, relativeTo: .largeTitle))
                        .foregroundStyle(WorldPalette.bark)
                        .contentTransition(.numericText())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("Bathroom today"))
                        .accessibilityValue(Text(verbatim: "\(value)"))
                        .accessibilityAdjustableAction { direction in
                            step(by: direction == .increment ? 1 : -1)
                        }
                        .accessibilityIdentifier("bathroom.count")
                    stepper
                }
                .frame(maxWidth: .infinity)
                .padding(20)
            }
            .accessibilityAction(.escape) { dismiss() }
        }
        .fernletSheetStyle()
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(value != saved)
        .onAppear { if draft == nil { draft = saved } }
    }

    /// − and + as the water sheet draws them: framed squares, + on the accent.
    private var stepper: some View {
        HStack(spacing: 22) {
            stepButton(plus: false, label: "Remove one", disabled: value <= 0) { step(by: -1) }
            stepButton(plus: true, label: "Add one", disabled: value >= Self.maximumVisits) { step(by: 1) }
        }
    }

    private func stepButton(plus: Bool, label: LocalizedStringKey, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(FernletMotion.fast) { action() }
        } label: {
            Image(systemName: plus ? "plus" : "minus")
                .font(.title2.weight(.heavy))
                .foregroundStyle(plus ? WorldPalette.onAccent : WorldPalette.mossInk)
                .frame(width: 64, height: 64)
                .background((plus ? WorldPalette.accent : WorldPalette.paperLight).opacity(disabled ? 0.45 : 1),
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(WorldPalette.ink, lineWidth: 2.5))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .fernletIconButton(label)
        .accessibilityValue(Text(verbatim: "\(value)"))
    }

    /// One step inside `0...30`, a tick each, the limit at either end.
    private func step(by delta: Int) {
        let after = BathroomTileFeedback.clamped(value + delta)
        draft = after
        FernletFeedback.system.play(after == 0 || after == Self.maximumVisits ? .limit : .tick)
    }

    /// Done: saves the count when it changed, then closes.
    private func save() {
        if value != saved {
            let result = store.setBathroomVisits(value, on: store.todayKey)
            BathroomTileFeedback.report(result)
        }
        dismiss()
    }
}
