// The hour grid shared by Meet With (§21) and the calendar window's Day and Week views (§22): hours
// down the side, days across, each day split into sub-columns (Meet With's people), an all-day
// strip, and the now line. A click or drag on empty time asks for a new event; a block can open on
// a click, move by dragging, and change length from its bottom edge.
import AppKit
import KalendarCore
import SwiftUI

/// One event in a grid column.
struct GridBlock: Identifiable, Equatable {
    var id: String
    var start: Date
    /// Exclusive. For an all-day event, midnight after the last day.
    var end: Date
    /// nil: only free/busy is visible ("Busy").
    var title: String?
    var color: Color
    /// Drawn as an outline: free/busy only, or an invitation not yet accepted.
    var outlined = false
    /// Can be dragged to another time or resized (the grid's `onMove`).
    var movable = false
    /// Offers Delete (the grid's `onDelete`).
    var deletable = false
}

struct TimeGrid: View {
    let days: [Date]
    /// The sub-columns of every day, left to right; each holds blocks across all the days.
    let columns: [[GridBlock]]
    /// All-day events, in a strip above the hours; none, no strip.
    var allDay: [GridBlock] = []
    /// A click or drag on empty time: the span's start and end. `done` clears the highlight once the
    /// form for it closes.
    let onCreate: (_ start: Date, _ end: Date, _ done: @escaping () -> Void) -> Void
    /// A click on a block; nil, blocks don't open.
    var onOpen: ((GridBlock) -> Void)?
    /// A movable block dragged to a new start and end.
    var onMove: ((GridBlock, Date, Date) -> Void)?
    /// A movable block's context menu Delete.
    var onDelete: ((GridBlock) -> Void)?

    @State private var highlight = SlotHighlight()
    @State private var moving = BlockMove()

    private let hourHeight: CGFloat = 48
    private let gutter: CGFloat = 56
    private let slot: TimeInterval = 30 * 60
    /// Moves and resizes snap to this.
    private let step: TimeInterval = 15 * 60

    var body: some View {
        GeometryReader { geo in
            let dayWidth = max((geo.size.width - gutter - 8) / CGFloat(max(days.count, 1)), 40)
            VStack(spacing: 0) {
                header(dayWidth: dayWidth)
                if !allDay.isEmpty { allDayStrip(dayWidth: dayWidth) }
                Theme.line.frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        grid(dayWidth: dayWidth)
                        // the now line alone redraws each minute, not the whole grid
                        .overlay(alignment: .topLeading) {
                            TimelineView(.everyMinute) { context in nowLine(dayWidth: dayWidth, now: context.date) }
                                .allowsHitTesting(false)
                        }
                        // one marker per hour, laid out (not offset) so scrollTo can find them
                        .background(alignment: .top) {
                            VStack(spacing: 0) {
                                ForEach(0..<24, id: \.self) { Color.clear.frame(height: hourHeight).id($0) }
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                    // opens at the day's start (§12); the next turn of the run loop, once laid out
                    .onAppear { DispatchQueue.main.async { proxy.scrollTo(Preferences.shared.dayStartHour, anchor: .top) } }
                }
            }
        }
    }

    // MARK: Header and all-day strip

    private func header(dayWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 0)
            ForEach(days, id: \.self) { day in
                let today = Calendar.current.isDateInToday(day)
                VStack(spacing: 2) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .uiFont(11, weight: .semibold)
                        .foregroundStyle(today ? Theme.accent : Theme.muted)
                    Text(day.formatted(.dateTime.day()))
                        .uiFont(18, weight: today ? .bold : .regular)
                        .foregroundStyle(today ? Theme.accent : Theme.text)
                }
                .frame(width: dayWidth)
            }
        }
        .padding(.bottom, 6)
    }

    /// Each day's all-day events, one row each, stacked.
    private func allDayStrip(dayWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("all-day").uiFont(10).foregroundStyle(Theme.muted)
                .frame(width: gutter - 8, alignment: .trailing).padding(.trailing, 8)
            ForEach(days, id: \.self) { day in
                let next = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
                VStack(spacing: 2) {
                    ForEach(allDay.filter { $0.start < next && $0.end > day }) { block in
                        BlockView(block: block)
                            .frame(height: 18)
                            .contentShape(Rectangle())
                            .onTapGesture { onOpen?(block) }
                            .contextMenu { deleteMenu(block) }
                    }
                }
                .padding(.horizontal, 1)
                .frame(width: dayWidth, alignment: .top)
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder private func deleteMenu(_ block: GridBlock) -> some View {
        if let onDelete, block.deletable { Button("Delete") { onDelete(block) } }
    }

    // MARK: Grid

    private func grid(dayWidth: CGFloat) -> some View {
        let columnWidth = dayWidth / CGFloat(max(columns.count, 1))
        return ZStack(alignment: .topLeading) {
            // empty time: under the blocks, so a press on an openable or movable block goes to the block
            createLayer(dayWidth: dayWidth)
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 4) {
                    Text(hourLabel(hour)).uiFont(11).foregroundStyle(Theme.muted)
                        .frame(width: gutter - 8, alignment: .trailing)
                        .offset(y: -7)
                    Theme.line.frame(height: 1)
                }
                .frame(height: hourHeight, alignment: .top)
                .offset(y: CGFloat(hour) * hourHeight)
                .allowsHitTesting(false)
            }
            ForEach(Array(days.enumerated()), id: \.element) { dayIndex, day in
                let x = gutter + CGFloat(dayIndex) * dayWidth
                Theme.line.frame(width: 1, height: 24 * hourHeight).offset(x: x).allowsHitTesting(false)
                ForEach(Array(columns.enumerated()), id: \.offset) { column, blocks in
                    let laid = Availability.lanes(blocks.compactMap { clip($0, to: day) }, start: \.start, end: \.end)
                    // by the block's id, so a reload during a drag can't hand the drag's view another block
                    ForEach(laid, id: \.item.block.id) { placed in
                        let width = columnWidth / CGFloat(placed.lanes)
                        let frame = CGRect(x: x + CGFloat(column) * columnWidth + CGFloat(placed.lane) * width,
                                           y: y(placed.item.start, in: day), width: width,
                                           height: y(placed.item.end, in: day) - y(placed.item.start, in: day))
                        block(placed.item.block, frame: frame, dayWidth: dayWidth)
                    }
                }
            }
            // a block being moved or resized, drawn where it would land
            BlockMoveView(moving: moving) { move in
                rect(for: Span(day: days.firstIndex(of: Calendar.current.startOfDay(for: move.start)) ?? -1,
                               start: move.start, end: move.end), dayWidth: dayWidth)
            }
            // last, so the span being chosen shows over the events it overlaps
            SlotHighlightView(highlight: highlight) { rect(for: $0, dayWidth: dayWidth).insetBy(dx: 1, dy: 0) }
        }
        .frame(width: gutter + CGFloat(days.count) * dayWidth, height: 24 * hourHeight, alignment: .topLeading)
    }

    /// The whole grid's empty time: the hover highlight, and a click or drag that asks for a new event.
    private func createLayer(dayWidth: CGFloat) -> some View {
        Color.clear
            .frame(width: gutter + CGFloat(days.count) * dayWidth, height: 24 * hourHeight)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                // with the button down, a drag owns the highlight
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                // only a new slot redraws, and only the highlight view reads `highlight`
                var span: Span?
                if case .active(let point) = phase { span = slot(at: point, dayWidth: dayWidth).map(defaultSpan) }
                if span != highlight.span { highlight.span = span }
            }
            // a click asks for an event of the default duration; a drag, for the slots dragged across
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    guard let span = span(of: drag, dayWidth: dayWidth) else { return }
                    if span != highlight.span { highlight.span = span }
                }
                .onEnded { drag in
                    guard let span = span(of: drag, dayWidth: dayWidth) else { return }
                    highlight.span = span
                    let highlight = highlight
                    // a form replaced by the next one closes after that one set its span
                    onCreate(span.start, span.end) { if highlight.span == span { highlight.span = nil } }
                })
    }

    /// A block, inset 1 pt on every side so events side by side or back to back keep a gap. An
    /// openable block opens on a click; a movable one moves when dragged, or changes its end when
    /// dragged from the bottom 6 pt.
    @ViewBuilder
    private func block(_ block: GridBlock, frame: CGRect, dayWidth: CGFloat) -> some View {
        let height = max(frame.height - 2, 12)
        Group {
            let view = BlockView(block: block)
                .frame(width: max(frame.width - 2, 2), height: height)
                .opacity(moving.blockID == block.id ? 0.4 : 1)
            if onOpen == nil && !block.movable {
                // clicks go through to the empty time beneath, as on Meet With's other people's events
                view.allowsHitTesting(false)
            } else {
                view
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 3)
                            .onChanged { drag in
                                guard block.movable, onMove != nil else { return }
                                let resize = drag.startLocation.y > height - 6
                                moving.move = moved(block, by: drag.translation, resize: resize, dayWidth: dayWidth)
                            }
                            .onEnded { _ in
                                defer { moving.move = nil }
                                // only a movable block's drag sets `moving.move`
                                guard let move = moving.move, move.start != move.block.start || move.end != move.block.end
                                else { return }
                                onMove?(move.block, move.start, move.end)
                            }
                            .exclusively(before: TapGesture().onEnded { onOpen?(block) }))
                    .contextMenu { deleteMenu(block) }
            }
        }
        // after the gestures: an offset moves the drawing, not the frame they are hit-tested in
        .offset(x: frame.minX + 1, y: frame.minY + 1)
    }

    /// Where a drag puts `block`: whole days across and 15-minute steps down, or for a resize only the
    /// end, at least one step after the start.
    private func moved(_ block: GridBlock, by translation: CGSize, resize: Bool, dayWidth: CGFloat) -> BlockMove.Move {
        let minutes = ((translation.height / hourHeight * 3600) / step).rounded() * step
        if resize {
            return .init(block: block, start: block.start, end: max(block.end.addingTimeInterval(minutes), block.start.addingTimeInterval(step)))
        }
        let calendar = Calendar.current
        // held to the days shown; a block that started before them moves only in time
        let first = days.firstIndex(of: calendar.startOfDay(for: block.start))
        let days = first.map { min(max(Int((translation.width / dayWidth).rounded()), -$0), self.days.count - 1 - $0) } ?? 0
        let start = calendar.date(byAdding: .day, value: days, to: block.start)?.addingTimeInterval(minutes) ?? block.start
        return .init(block: block, start: start, end: start.addingTimeInterval(block.end.timeIntervalSince(block.start)))
    }

    @ViewBuilder
    private func nowLine(dayWidth: CGFloat, now: Date) -> some View {
        if let dayIndex = days.firstIndex(where: { Calendar.current.isDate(now, inSameDayAs: $0) }) {
            Theme.bad.frame(width: dayWidth, height: 2)
                .offset(x: gutter + CGFloat(dayIndex) * dayWidth, y: y(now, in: days[dayIndex]))
        }
    }

    // MARK: Geometry

    /// The event a press or drag describes: from the slot pressed to the one under the pointer, in
    /// that day's column, either direction; the default duration while the pointer is in the slot
    /// pressed, so a click that jitters, or a drag brought back, isn't a 30-minute event.
    private func span(of drag: DragGesture.Value, dayWidth: CGFloat) -> Span? {
        guard let from = slot(at: drag.startLocation, dayWidth: dayWidth) else { return nil }
        // the pointer may leave the grid; it is held to the day's first and last slots
        let y = min(max(drag.location.y, 0), 24 * hourHeight - 1)
        guard let to = slot(at: CGPoint(x: drag.startLocation.x, y: y), dayWidth: dayWidth) else { return nil }
        guard to != from else { return defaultSpan(from) }
        let (first, last) = from.start <= to.start ? (from, to) : (to, from)
        return Span(day: from.day, start: first.start, end: last.start.addingTimeInterval(slot))
    }

    private func defaultSpan(_ slot: Slot) -> Span {
        Span(day: slot.day, start: slot.start,
             end: slot.start.addingTimeInterval(TimeInterval(Preferences.shared.defaultDuration * 60)))
    }

    /// `span`'s rectangle in its day; empty for a day outside the grid.
    private func rect(for span: Span, dayWidth: CGFloat) -> CGRect {
        guard days.indices.contains(span.day) else { return .zero }
        let day = days[span.day]
        let top = y(span.start, in: day)
        return CGRect(x: gutter + CGFloat(span.day) * dayWidth, y: top, width: dayWidth, height: y(span.end, in: day) - top)
    }

    /// The 30-minute slot at `point`, by day column.
    private func slot(at point: CGPoint, dayWidth: CGFloat) -> Slot? {
        let day = Int((point.x - gutter) / dayWidth)
        guard point.x >= gutter, days.indices.contains(day) else { return nil }
        let seconds = Double(point.y / hourHeight) * 3600
        let snapped = (seconds / slot).rounded(.down) * slot
        guard snapped >= 0, snapped < 86400 else { return nil }
        // the clock time under the pointer, which on a daylight-saving day isn't midnight plus `snapped`
        let minutes = Int(snapped) / 60
        return Slot(day: day, start: Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0,
                                                           of: days[day]) ?? days[day])
    }

    /// The part of `block` inside `day`, with the block it came from; nil when it doesn't touch the day.
    private func clip(_ block: GridBlock, to day: Date) -> Clipped? {
        guard let next = Calendar.current.date(byAdding: .day, value: 1, to: day),
              block.end > day, block.start < next else { return nil }
        return Clipped(block: block, start: max(block.start, day), end: min(block.end, next))
    }

    /// Where `date`'s clock time falls in `day`'s 24 hour rows; the next midnight is the bottom. By
    /// clock time, so events after a daylight-saving change still line up with the hour labels.
    private func y(_ date: Date, in day: Date) -> CGFloat {
        let calendar = Calendar.current
        guard let next = calendar.date(byAdding: .day, value: 1, to: day), date < next else { return 24 * hourHeight }
        guard date >= day else { return 0 }
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return (CGFloat(c.hour ?? 0) + CGFloat(c.minute ?? 0) / 60 + CGFloat(c.second ?? 0) / 3600) * hourHeight
    }

    private func hourLabel(_ hour: Int) -> String {
        guard hour > 0, let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) else { return "" }
        return date.formatted(.dateTime.hour())
    }
}

/// A block's part in one day.
private struct Clipped {
    var block: GridBlock
    var start: Date
    var end: Date
}

/// A 30-minute slot: the day's column and the start.
private struct Slot: Equatable {
    var day: Int
    var start: Date
}

/// An event's place in the grid: the day's column, the start and the end.
private struct Span: Equatable {
    var day: Int
    var start: Date
    var end: Date
}

/// The span under the pointer (the default duration) or being dragged. Its own object, read only by
/// `SlotHighlightView`, so moving the pointer redraws the highlight and not the grid.
@Observable
private final class SlotHighlight {
    var span: Span?
}

private struct SlotHighlightView: View {
    let highlight: SlotHighlight
    let frame: (Span) -> CGRect

    var body: some View {
        if let span = highlight.span {
            let rect = frame(span)
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.accent.opacity(0.15))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.accent, lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }
}

/// The block being moved or resized and where it would land. Its own object, read by
/// `BlockMoveView`, so a drag redraws that preview, not the grid (beyond dimming the block once).
@Observable
private final class BlockMove {
    struct Move: Equatable {
        var block: GridBlock
        var start: Date
        var end: Date

        /// The block at its new times.
        var landed: GridBlock {
            var b = block
            b.start = start
            b.end = end
            return b
        }
    }
    var move: Move? {
        didSet { if move?.block.id != oldValue?.block.id { blockID = move?.block.id } }
    }
    /// The moving block's id, changed only when a drag starts or ends.
    private(set) var blockID: String?
}

private struct BlockMoveView: View {
    let moving: BlockMove
    let frame: (BlockMove.Move) -> CGRect

    var body: some View {
        if let move = moving.move {
            let rect = frame(move)
            BlockView(block: move.landed)
                .frame(width: max(rect.width - 2, 2), height: max(rect.height - 2, 12))
                .offset(x: rect.minX + 1, y: rect.minY + 1)
                .shadow(radius: 4)
                .allowsHitTesting(false)
        }
    }
}

/// One event: the title and, with room, the time range; "Busy" when only free/busy is visible.
struct BlockView: View {
    let block: GridBlock

    var body: some View {
        let times = Formatting.timeRange(block.start, block.end)
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                Text(block.title ?? "Busy").uiFont(11, weight: .semibold).lineLimit(geo.size.height > 30 ? 2 : 1)
                // a narrow block has room only for the title
                if geo.size.width >= 70 && geo.size.height > 30 { Text(times).uiFont(10).lineLimit(1) }
            }
        }
        .foregroundStyle(block.outlined ? Theme.text : .white)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(block.outlined ? block.color.opacity(0.3) : block.color.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(block.color, lineWidth: block.outlined ? 1 : 0))
        .clipped()
        .help("\(block.title ?? "Busy"), \(times)")
    }
}
