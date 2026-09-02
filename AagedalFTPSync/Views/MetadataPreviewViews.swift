import SwiftUI

struct MetadataFolderPreviewView: View {
    @Environment(\.dismiss) private var dismiss

    let folderName: String
    let timestampPolicy: MetadataTimestampPolicy
    let result: MetadataPreviewResult

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Metadata Preview")
                        .font(.title2.weight(.semibold))
                    Text("\(folderName) · \(timestampPolicy.title)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            HStack(spacing: 18) {
                Label("\(result.scanned) scanned", systemImage: "doc.text.magnifyingglass")
                Label("\(result.willApply) will apply", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("\(result.alreadyApplied) already applied", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.blue)
                Label("\(result.skipped) skipped", systemImage: "minus.circle.fill")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Read-only preview — no files were changed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if result.items.isEmpty {
                ContentUnavailableView(
                    "No matching file types",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("The selected job’s file filter found nothing to preview in this folder.")
                )
            } else {
                Table(result.items) {
                    TableColumn("File") { item in
                        Text(item.relativePath)
                            .lineLimit(1)
                            .help(item.relativePath)
                    }
                    .width(min: 220, ideal: 300)

                    TableColumn("Result") { item in
                        Label(item.status.title, systemImage: item.status.symbolName)
                            .foregroundStyle(item.status.color)
                    }
                    .width(min: 150, ideal: 190)

                    TableColumn("Photographer") { item in
                        Text(item.photographerName ?? "—")
                    }
                    .width(min: 120, ideal: 160)

                    TableColumn("Clip") { item in
                        Text(item.clipName ?? "—")
                    }
                    .width(min: 120, ideal: 180)

                    TableColumn("Schedule time") { item in
                        if let scheduledAt = item.scheduledAt {
                            Text(scheduledAt.formatted(date: .abbreviated, time: .standard))
                        } else {
                            Text("—")
                        }
                    }
                    .width(min: 160, ideal: 190)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 960, minHeight: 520)
    }
}

struct ProgrammingMonthCalendar: View {
    @Binding var selection: Date
    let programmedDays: Set<Date>
    let calendar: Calendar
    @State private var displayedMonth: Date

    init(
        selection: Binding<Date>,
        programmedDays: Set<Date>,
        calendar: Calendar = .current
    ) {
        _selection = selection
        self.programmedDays = programmedDays
        self.calendar = calendar
        _displayedMonth = State(initialValue: Self.monthStart(for: selection.wrappedValue, calendar: calendar))
    }

    var body: some View {
        VStack(spacing: 12) {
            monthHeader

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }

                ForEach(Array(monthDays.enumerated()), id: \.offset) { _, date in
                    if let date {
                        dayButton(date)
                    } else {
                        Color.clear
                            .aspectRatio(1.15, contentMode: .fit)
                            .accessibilityHidden(true)
                    }
                }
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(.teal)
                    .frame(width: 7, height: 7)
                Text("Programmed")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Today") {
                    let today = Date()
                    selection = today
                    displayedMonth = Self.monthStart(for: today, calendar: calendar)
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.medium))
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity)
        .onChange(of: selection) { _, newSelection in
            let selectionMonth = Self.monthStart(for: newSelection, calendar: calendar)
            if !calendar.isDate(selectionMonth, equalTo: displayedMonth, toGranularity: .month) {
                displayedMonth = selectionMonth
            }
        }
    }

    private var monthHeader: some View {
        HStack(spacing: 10) {
            monthButton(systemImage: "chevron.left", offset: -1)

            Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
                .frame(maxWidth: .infinity)

            monthButton(systemImage: "chevron.right", offset: 1)
        }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard !symbols.isEmpty else { return [] }
        let firstIndex = max(min(calendar.firstWeekday - 1, symbols.count - 1), 0)
        return Array(symbols[firstIndex...] + symbols[..<firstIndex])
    }

    private var monthDays: [Date?] {
        guard let dayRange = calendar.range(of: .day, in: .month, for: displayedMonth) else { return [] }
        let weekday = calendar.component(.weekday, from: displayedMonth)
        let leadingBlanks = (weekday - calendar.firstWeekday + 7) % 7
        var days = Array<Date?>(repeating: nil, count: leadingBlanks)
        days.append(contentsOf: dayRange.compactMap { day -> Date? in
            calendar.date(bySetting: .day, value: day, of: displayedMonth)
        })
        let trailingBlanks = (7 - days.count % 7) % 7
        days.append(contentsOf: Array<Date?>(repeating: nil, count: trailingBlanks))
        return days
    }

    private func dayButton(_ date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: selection)
        let isProgrammed = programmedDays.contains(calendar.startOfDay(for: date))
        let isToday = calendar.isDateInToday(date)

        return Button {
            selection = date
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(dayBackground(isSelected: isSelected, isProgrammed: isProgrammed))

                if isToday && !isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.tint, lineWidth: 1)
                }

                VStack(spacing: 2) {
                    Text(date.formatted(.dateTime.day()))
                        .font(.body.monospacedDigit().weight(isSelected || isToday ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)

                    Circle()
                        .fill(isSelected ? Color.white : Color.teal)
                        .frame(width: 5, height: 5)
                        .opacity(isProgrammed ? 1 : 0)
                }
            }
            .contentShape(Rectangle())
            .aspectRatio(1.15, contentMode: .fit)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityValue(isProgrammed ? "Programmed" : "No programming")
    }

    private func dayBackground(isSelected: Bool, isProgrammed: Bool) -> Color {
        if isSelected { return .accentColor }
        if isProgrammed { return .teal.opacity(0.2) }
        return .clear
    }

    private func monthButton(systemImage: String, offset: Int) -> some View {
        Button {
            displayedMonth = calendar.date(byAdding: .month, value: offset, to: displayedMonth)
                .map { Self.monthStart(for: $0, calendar: calendar) }
                ?? displayedMonth
        } label: {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: 28, height: 28)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(offset < 0 ? "Previous Month" : "Next Month")
    }

    private static func monthStart(for date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }
}

private extension MetadataPreviewStatus {
    var symbolName: String {
        switch self {
        case .willApply: "checkmark.circle.fill"
        case .alreadyApplied: "checkmark.seal.fill"
        case .existingMetadataPreserved: "lock.circle.fill"
        case .noMatchingPhotographer: "person.crop.circle.badge.questionmark"
        case .noScheduledClip: "calendar.badge.exclamationmark"
        case .captureTimeUnavailable: "camera.badge.ellipsis"
        }
    }

    var color: Color {
        switch self {
        case .willApply: .green
        case .alreadyApplied: .blue
        case .existingMetadataPreserved,
             .noMatchingPhotographer,
             .noScheduledClip,
             .captureTimeUnavailable: .secondary
        }
    }
}

