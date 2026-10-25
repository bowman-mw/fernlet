import FernletUI
import SwiftUI

/// Log intimacy's "Date and time" (`ref-int-date`, `ref-int-time`, approved 2026-10-25): one framed button
/// in two halves, like Log period's date button with a time half. The date ("Fri, Oct 23, 2026") and, after
/// a 2-pt divider, a pixel clock and the time ("9:40 PM"; Spanish "vie, 23 oct 2026" and "21:40"), the
/// halves 1.55 : 1.
///
/// The date half opens iOS's own graphical calendar, tinted moss, days after today greyed out; the time
/// half opens iOS's own time wheels (hour, minute and AM/PM, or two wheels on a 24-hour clock), starting
/// at the time the sheet opened. While a picker is open its half wears a 3-pt moss ring on the chip fill.
/// Picking a day keeps the time and picking a time keeps the day (``merged(day:time:latest:calendar:)``),
/// and nothing lands after `latest`: the sheet logs what already happened.
///
/// VoiceOver: "Date, Friday, October 23, 2026, button" and "Time, 9:40 PM, button", each saying when its
/// picker is open. At the largest text the halves' words grow to 19 pt; the pickers keep iOS's size.
struct PrivateDateTimeButton: View {
    @Binding var date: Date
    /// The latest moment that may be picked (now).
    let latest: Date
    @State private var open: Half?
    @Environment(\.fernletFramedLook) private var look

    /// The button's two halves.
    enum Half: Hashable {
        case date, time
    }

    var body: some View {
        DateTimeHalves(ratio: 1.55) {
            half(.date) { Text(date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().year()) }
            half(.time) {
                HStack(spacing: 8) {
                    WorldSpriteView(sprite: FoodSprites.clock, scale: 2)
                    Text(date, format: .dateTime.hour().minute())
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(look?.ink ?? WorldPalette.ink, lineWidth: 2))
        .background { RoundedRectangle(cornerRadius: 10).fill(look?.shadow ?? WorldPalette.ink.opacity(0.22)).offset(y: 3) }
        .accessibilityElement(children: .contain)
    }

    /// The 2-pt ink rule between the halves.
    private var divider: some View {
        (look?.ink ?? WorldPalette.ink).frame(width: 2)
    }

    /// One half: its words on raised paper (the chip fill and a moss ring while its picker is open), a
    /// button that opens its picker in a popover under it.
    private func half<Label: View>(_ which: Half, @ViewBuilder label: () -> Label) -> some View {
        let isOpen = open == which
        return Button { open = which } label: {
            label()
                .font(Font.custom(FernletFontName.dmSansBold, size: 16, relativeTo: .body))
                // The halves' words grow to about 19 pt and stop there; the pickers keep iOS's size.
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .foregroundStyle(look?.text ?? WorldPalette.bark)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .padding(.leading, which == .time ? 2 : 0)
                .background(isOpen ? WorldPalette.sage : (look?.raised ?? WorldPalette.paperLight))
                .overlay(alignment: .leading) { if which == .time { divider } }
                .overlay { if isOpen { Rectangle().strokeBorder(WorldPalette.moss, lineWidth: 3).padding(.leading, which == .time ? 2 : 0) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(get: { open == which }, set: { if !$0, open == which { open = nil } })) {
            picker(which)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel(Text(which == .date ? Self.dateName : Self.timeName))
        .accessibilityValue(spokenValue(which, isOpen: isOpen))
        .accessibilityIdentifier(which == .date ? "intimacy.date" : "intimacy.time")
    }

    /// The half's picker: iOS's calendar or its time wheels, at iOS's own size.
    @ViewBuilder
    private func picker(_ which: Half) -> some View {
        switch which {
        case .date:
            DatePicker(Self.dateName, selection: dayBinding, in: ...latest, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(WorldPalette.mossInk)
                .frame(width: 320)
                .padding(10)
        case .time:
            DatePicker(Self.timeName, selection: timeBinding, in: ...latest, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .padding(.horizontal, 8)
        }
    }

    /// The calendar's day, keeping the time already picked.
    private var dayBinding: Binding<Date> {
        Binding(get: { date }, set: { date = Self.merged(day: $0, time: date, latest: latest) })
    }

    /// The wheels' time, keeping the day already picked.
    private var timeBinding: Binding<Date> {
        Binding(get: { date }, set: { date = Self.merged(day: date, time: $0, latest: latest) })
    }

    /// What VoiceOver reads after the half's name: the whole date or the time, and whether its picker is open.
    private func spokenValue(_ which: Half, isOpen: Bool) -> Text {
        let value = which == .date
            ? date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
            : date.formatted(.dateTime.hour().minute())
        guard isOpen else { return Text(verbatim: value) }
        return Text(verbatim: String(localized: "intimacy.dateTime.open", defaultValue: "\(value), expanded",
                                     comment: "Log intimacy, VoiceOver: a half of the Date and time button while its picker is open: the date or time, then that it is open"))
    }

    /// `day`'s calendar day at `time`'s hour and minute (seconds dropped), never later than `latest`.
    static func merged(day: Date, time: Date, latest: Date, calendar: Calendar = .current) -> Date {
        let clock = calendar.dateComponents([.hour, .minute], from: time)
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        parts.hour = clock.hour
        parts.minute = clock.minute
        guard let combined = calendar.date(from: parts) else { return min(day, latest) }
        return min(combined, latest)
    }

    static let dateName = LocalizedStringResource("intimacy.dateTime.date", defaultValue: "Date",
                                                  comment: "Log intimacy, VoiceOver: the date half of the Date and time button (then the date)")
    static let timeName = LocalizedStringResource("intimacy.dateTime.time", defaultValue: "Time",
                                                  comment: "Log intimacy, VoiceOver: the time half of the Date and time button (then the time)")
}

/// Lays two halves side by side at `ratio` : 1, both as tall as the taller one.
private struct DateTimeHalves: Layout {
    let ratio: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let widths = split(width)
        let height = zip(subviews, widths).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 44
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = split(bounds.width)
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width
        }
    }

    /// The two halves' widths for `width`.
    private func split(_ width: CGFloat) -> [CGFloat] {
        let first = (width * ratio / (ratio + 1)).rounded()
        return [first, width - first]
    }
}
