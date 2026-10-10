import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// A month of the chat: each day that has messages carries a dot, a day
/// without any is faint and cannot be picked, and the days to come are not
/// offered. Picking a day goes to its first message, or, with "Search Day"
/// chosen below, keeps the search to that day.
struct SearchCalendar: View {
    let search: ChatSearch
    let model: AppModel
    let close: () -> Void
    @State private var month: Date
    /// Picking a day keeps the search to it instead of going there.
    @AppStorage("chatSearchCalendarFilters") private var filters = false
    private let calendar = Calendar.current

    init(search: ChatSearch, model: AppModel, close: @escaping () -> Void) {
        self.search = search
        self.model = model
        self.close = close
        let calendar = Calendar.current
        _month = State(initialValue: calendar.dateInterval(of: .month, for: search.day ?? .now)?.start ?? .now)
    }

    var body: some View {
        VStack(spacing: Metrics.s) {
            header
            weekdays
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cell), spacing: 2), count: 7), spacing: 2) {
                ForEach(days, id: \.self) { day in
                    cell(day)
                }
            }
            Picker(selection: $filters) {
                Text(searchText("search.calendar.goto")).tag(false)
                Text(searchText("search.calendar.filter")).tag(true)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if search.day != nil {
                Button(searchText("search.calendar.every")) {
                    model.setChatSearchDay(nil)
                    close()
                }
                .buttonStyle(.link)
            }
        }
        .padding(Metrics.m)
        .onChange(of: month, initial: true) { model.askChatSearchDays(spanStarts) }
    }

    static let cell: CGFloat = 34

    // MARK: Parts

    private var header: some View {
        HStack {
            MonthButton(symbol: "chevron.left", help: searchText("search.calendar.previous")) {
                month = calendar.date(byAdding: .month, value: -1, to: month) ?? month
            }
            Spacer()
            VStack(spacing: 0) {
                Text(month, format: .dateTime.month(.wide))
                    .font(.headline)
                Text(month, format: .dateTime.year())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            MonthButton(symbol: "chevron.right", help: searchText("search.calendar.next")) {
                month = calendar.date(byAdding: .month, value: 1, to: month) ?? month
            }
            .disabled(isCurrentMonth)
        }
    }

    private var weekdays: some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        let ordered = Array(symbols[first...] + symbols[..<first])
        return HStack(spacing: 2) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.cell)
            }
        }
    }

    @ViewBuilder
    private func cell(_ day: Date) -> some View {
        let start = Int64(day.timeIntervalSince1970)
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let future = day > .now
        let known = search.days[start]
        let first = known ?? nil
        let empty = known != nil && first == nil
        let chosen = search.day.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        Button {
            if filters {
                model.setChatSearchDay(day)
            } else {
                model.jumpToChatSearchDay(start)
            }
            close()
        } label: {
            DayLabel(
                number: calendar.component(.day, from: day),
                today: calendar.isDateInToday(day),
                weekend: calendar.isDateInWeekend(day),
                faint: !inMonth,
                hasMessages: first != nil,
                chosen: chosen
            )
        }
        .buttonStyle(DayButtonStyle())
        .disabled(future || first == nil)
        .opacity(future || empty ? 0.35 : 1)
        .help(empty ? searchText("search.calendar.empty") : "")
        .contextMenu {
            if first != nil {
                Button(searchText("search.calendar.goto")) {
                    model.jumpToChatSearchDay(start)
                    close()
                }
                Button(searchText("search.calendar.filter")) {
                    model.setChatSearchDay(day)
                    close()
                }
            }
        }
    }

    // MARK: Dates

    private var isCurrentMonth: Bool {
        calendar.isDate(month, equalTo: .now, toGranularity: .month)
    }

    /// Six weeks from the week the month starts in.
    private var days: [Date] {
        let weekday = calendar.component(.weekday, from: month)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        guard let first = calendar.date(byAdding: .day, value: -lead, to: month) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    /// Each day's first instant, and the end of the last day: the spans the
    /// archive is asked about. Days are not all 86,400 seconds long.
    private var spanStarts: [Int64] {
        let days = days
        guard let last = days.last, let end = calendar.date(byAdding: .day, value: 1, to: last) else { return [] }
        return (days + [end]).map { Int64($0.timeIntervalSince1970) }
    }
}

private struct DayLabel: View {
    let number: Int
    let today: Bool
    let weekend: Bool
    let faint: Bool
    let hasMessages: Bool
    let chosen: Bool

    var body: some View {
        ZStack {
            if today {
                Circle().fill(.tint)
            } else if chosen {
                Circle().strokeBorder(.tint, lineWidth: 1.5)
            }
            Text(number, format: .number)
                .font(.callout.monospacedDigit().weight(today ? .semibold : .regular))
                .foregroundStyle(color)
            if hasMessages, !today {
                Circle()
                    .fill(.tint)
                    .frame(width: 4, height: 4)
                    .offset(y: 10)
            }
        }
        .frame(width: SearchCalendar.cell, height: SearchCalendar.cell)
    }

    private var color: AnyShapeStyle {
        if today { return AnyShapeStyle(.white) }
        if faint { return AnyShapeStyle(.tertiary) }
        if weekend { return AnyShapeStyle(Color.red) }
        return AnyShapeStyle(.primary)
    }
}

private struct DayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DayButtonBody(label: configuration.label, pressed: configuration.isPressed)
    }
}

/// A day lit under the pointer; a view of its own, since a style keeps no state.
private struct DayButtonBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        label
            .background {
                Circle().fill(.primary.opacity(pressed ? 0.14 : hovering && isEnabled ? 0.07 : 0))
            }
            .contentShape(Circle())
            .onHover { hovering = $0 }
    }
}

private struct MonthButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(.quaternary, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
