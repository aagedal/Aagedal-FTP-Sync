import AppKit
import SwiftUI
import MetadataTemplates

struct MetadataFolderPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedItemID: String?

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
                    .labelStyle(AccessibleStatusLabelStyle(symbolColor: .green))
                Label("\(result.alreadyApplied) already applied", systemImage: "checkmark.seal.fill")
                    .labelStyle(AccessibleStatusLabelStyle(symbolColor: .blue))
                Label("\(result.skipped) skipped", systemImage: "minus.circle.fill")
                    .foregroundStyle(.secondary)
                if result.needsAttention > 0 {
                    Label("\(result.needsAttention) need review", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(AccessibleStatusLabelStyle(symbolColor: .orange))
                }
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
                Table(result.items, selection: $selectedItemID) {
                    TableColumn("File") { item in
                        Text(item.relativePath)
                            .lineLimit(1)
                            .help(item.relativePath)
                    }
                    .width(min: 220, ideal: 300)

                    TableColumn("Result") { item in
                        Label(item.status.title, systemImage: item.status.symbolName)
                            .labelStyle(AccessibleStatusLabelStyle(symbolColor: item.status.color))
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
                if let item = result.items.first(where: { $0.id == selectedItemID }) {
                    previewDetails(item)
                } else {
                    Text("Select a file to inspect proposed values and omissions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 960, minHeight: 520)
    }

    @ViewBuilder
    private func previewDetails(_ item: MetadataPreviewItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.relativePath).font(.headline)
                if let detail = item.detail { Text(detail).foregroundStyle(.secondary) }
                if let processing = item.processing {
                    if let context = processing.context {
                        Text("Frozen processing time: \(context.processingDate.formatted(Date.FormatStyle(date: .abbreviated, time: .standard, timeZone: context.processingTimeZone))) · \(context.processingTimeZone.identifier)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(captureAssumption(context.captureDate))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if processing.geocoding != .notRequested {
                        Text(geocodingDetail(processing.geocoding)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let resolution = processing.coordinateResolution {
                        Text(MetadataAuditEvidencePresentation.coordinateDecision(.init(resolution)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Field").frame(width: 100, alignment: .leading)
                        Text("Existing value").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Proposed value or outcome").frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.caption.bold())
                    ForEach(MetadataWritableField.allCases) { field in
                        if let outcome = processing.fields[field] {
                            HStack(alignment: .top) {
                                Text(field.title).fontWeight(.medium).frame(width: 100, alignment: .leading)
                                Text(existingDetail(field, item: item))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                Text(fieldDetail(field, outcome: outcome, processing: processing))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    ForEach(MetadataPlaceField.allCases, id: \.self) { field in
                        if let outcome = processing.places[field] {
                            HStack(alignment: .top) {
                                Text(field.title).fontWeight(.medium).frame(width: 100, alignment: .leading)
                                Text(existingPlaceDetail(field, item: item))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                Text(placeDetail(field, outcome: outcome, processing: processing))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
        }.frame(maxHeight: 170)
    }

    private func existingPlaceDetail(_ field: MetadataPlaceField, item: MetadataPreviewItem) -> String {
        guard let snapshot = item.existingPlaces, snapshot.readable else { return "Existing value unavailable" }
        let values = snapshot.carriers.compactMap { carrier -> String? in
            guard let value = field == .city ? carrier.city : carrier.country, !value.isEmpty else { return nil }
            return carrier.name + ": " + value
        }
        return values.isEmpty ? "No existing value" : values.joined(separator: "\n")
    }

    private func placeDetail(_ field: MetadataPlaceField, outcome: MetadataProcessingPlaceOutcome,
                             processing: MetadataProcessingResult) -> String {
        switch outcome {
        case .notRequested: return "Disabled"
        case .preservedByPolicy: return "Existing value preserved by field policy"
        case .unavailable: return "No usable location name; existing value preserved"
        case .proposed: return (field == .city ? processing.changes.places?.city : processing.changes.places?.country) ?? "No value proposed"
        case .invalidValue(let reason):
            switch reason {
            case .writerByteLimit(let maximum): return "Omitted: exceeds the \(maximum)-byte field limit"
            case .invalidXMLCharacter: return "Omitted: unsupported XML character"
            case .invalidGPSPosition: return "Omitted: invalid location"
            case .template: return "Omitted: location name could not be resolved safely"
            }
        }
    }

    private func geocodingDetail(_ stage: MetadataProcessingGeocodingOutcome) -> String {
        switch stage {
        case .notRequested: return "Location lookup was not needed."
        case .missingCoordinates: return "Location lookup unavailable: no valid coordinates."
        case .lookup(let outcome):
            switch outcome {
            case .found(let place, let identity):
                let distance = place.distanceMeters.map { String(format: " · %.0f m from the matched place", $0) } ?? ""
                return "Location lookup: \(identity.provider) · \(place.source)\(distance)"
            case .noResult: return "Location lookup found no place."
            case .tooDistant: return "Nearest place exceeded the configured distance limit."
            case .invalidProviderResult: return "Location lookup returned an invalid result."
            case .providerFailure: return "Location lookup failed."
            case .backoff: return "Location lookup is waiting after a provider failure."
            case .overloaded: return "Location lookup queue is full."
            case .deadlineExceeded: return "Location lookup exceeded its deadline."
            case .cancelled: return "Location lookup was cancelled."
            }
        }
    }

    private func existingDetail(_ field: MetadataWritableField, item: MetadataPreviewItem) -> String {
        guard !item.existingFieldsUnavailable, let snapshot = item.existingFields else { return "Unavailable: metadata could not be read" }
        let values = snapshot.carriers.compactMap { carrier -> String? in
            guard let value = carrier.fields[field] else { return nil }
            let text: String
            switch value {
            case .text(let source): text = source
            case .list(let sources): text = sources.map { "• " + $0 }.joined(separator: "\n")
            case .position(let position):
                text = "\(position.latitude), \(position.longitude)" + (position.altitudeMeters.map { " · \($0) m" } ?? "")
            }
            return carrier.name + ": " + text
        }
        return values.isEmpty ? "No existing value" : values.joined(separator: "\n")
    }

    private func captureAssumption(_ capture: MetadataCaptureDate?) -> String {
        guard let capture else { return "Capture date was not needed or could not be resolved; no resolved capture-date assumption is available." }
        switch capture.zoneSource {
        case .explicitOffset(let seconds):
            let absolute = abs(seconds)
            let offset = String(format: "%@%02d:%02d", seconds < 0 ? "−" : "+", absolute / 3600, (absolute % 3600) / 60)
            return "Capture date uses the image's explicit UTC offset \(offset)."
        case .persistedFallback(let identifier):
            return "Capture date had no offset; saved fallback zone assumed: \(identifier)."
        }
    }

    private func fieldDetail(_ field: MetadataWritableField, outcome: MetadataProcessingFieldOutcome,
                             processing: MetadataProcessingResult) -> String {
        switch outcome {
        case .notRequested: return "No value proposed"
        case .preservedByPolicy: return "Existing value preserved by field policy"
        case .omitted(let reason):
            switch reason {
            case .invalidGPSPosition: return "Omitted: invalid scheduled GPS position"
            case .invalidXMLCharacter: return "Omitted: unsupported XML character"
            case .writerByteLimit(let maximum): return "Omitted: exceeds the writer's \(maximum)-byte limit"
            case .template(let reason):
                switch reason {
                case .missingValues(let variables): return "Omitted: missing " + variables.map(\.rawValue).sorted().joined(separator: ", ")
                case .invalidDate(let variable): return "Omitted: invalid " + variable.rawValue
                case .outputLimitExceeded(let maximum): return "Omitted: exceeds the \(maximum)-byte output limit"
                case .keywordEntryLimitExceeded(let maximum): return "Omitted: exceeds the \(maximum)-keyword limit"
                }
            }
        case .proposed:
            let values = processing.changes
            switch field {
            case .headline: return values.headline
            case .description: return values.description
            case .keywords: return values.keywords.joined(separator: " · ")
            case .creator: return values.creator
            case .copyright: return values.copyright
            case .gpsPosition:
                guard let gps = values.gpsPosition else { return "No position proposed" }
                return "\(gps.latitude), \(gps.longitude)"
            }
        }
    }

}

struct ProgrammingMonthCalendar: View {
    @Binding var selection: Date
    let programmedDays: Set<Date>
    let calendar: Calendar
    let canPasteProgramming: Bool
    let onCopyProgramming: (Date) -> Void
    let onPasteProgramming: (Date) -> Void
    let onExport: (Set<Date>) -> Void
    @State private var displayedMonth: Date
    @State private var daySelection: ProgrammingDaySelection

    init(
        selection: Binding<Date>,
        programmedDays: Set<Date>,
        calendar: Calendar = .current,
        canPasteProgramming: Bool,
        onCopyProgramming: @escaping (Date) -> Void,
        onPasteProgramming: @escaping (Date) -> Void,
        onExport: @escaping (Set<Date>) -> Void
    ) {
        _selection = selection
        self.programmedDays = programmedDays
        self.calendar = calendar
        self.canPasteProgramming = canPasteProgramming
        self.onCopyProgramming = onCopyProgramming
        self.onPasteProgramming = onPasteProgramming
        self.onExport = onExport
        _displayedMonth = State(initialValue: Self.monthStart(for: selection.wrappedValue, calendar: calendar))
        _daySelection = State(initialValue: ProgrammingDaySelection(
            selectedDate: selection.wrappedValue,
            calendar: calendar
        ))
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
                    daySelection.select(today, extending: false)
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
            daySelection.synchronize(to: newSelection)
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
        let isActive = calendar.isDate(date, inSameDayAs: selection)
        let isSelected = daySelection.contains(date)
        let isProgrammed = programmedDays.contains(calendar.startOfDay(for: date))
        let isToday = calendar.isDateInToday(date)

        return Button {
            daySelection.select(date, extending: NSEvent.modifierFlags.contains(.shift))
            selection = date
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(dayBackground(
                        isActive: isActive,
                        isSelected: isSelected,
                        isProgrammed: isProgrammed
                    ))

                if isToday && !isActive {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.tint, lineWidth: 1)
                }

                VStack(spacing: 2) {
                    Text(date.formatted(.dateTime.day()))
                        .font(.body.monospacedDigit().weight(isActive || isToday ? .semibold : .regular))
                        .foregroundStyle(isActive ? Color.white : Color.primary)

                    Circle()
                        .fill(isActive ? Color.white : Color.teal)
                        .frame(width: 5, height: 5)
                        .opacity(isProgrammed ? 1 : 0)
                }
            }
            .contentShape(Rectangle())
            .aspectRatio(1.15, contentMode: .fit)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityValue(dayAccessibilityValue(isSelected: isSelected, isProgrammed: isProgrammed))
        .contextMenu {
            Button {
                selectContextDay(date)
                onCopyProgramming(date)
            } label: {
                Label("Copy All Programming for Day", systemImage: "doc.on.doc")
            }
            .disabled(!isProgrammed)

            Button {
                selectContextDay(date)
                onPasteProgramming(date)
            } label: {
                Label("Paste Programming into Day", systemImage: "doc.on.clipboard")
            }
            .disabled(!canPasteProgramming)

            Divider()

            Button {
                let exportDays = daySelection.contextSelection(for: date)
                if !daySelection.contains(date) {
                    daySelection.select(date, extending: false)
                    selection = date
                }
                onExport(exportDays)
            } label: {
                Label(exportTitle(for: date), systemImage: "square.and.arrow.up")
            }
            .help("Includes the full duration of clips touching the selected days, including overnight assignments.")
            .disabled(programmedDays.isDisjoint(with: daySelection.contextSelection(for: date)))
        }
    }

    private func selectContextDay(_ date: Date) {
        daySelection.select(date, extending: false)
        selection = date
    }

    private func dayBackground(isActive: Bool, isSelected: Bool, isProgrammed: Bool) -> Color {
        if isActive { return .accentColor }
        if isSelected { return .accentColor.opacity(0.28) }
        if isProgrammed { return .teal.opacity(0.2) }
        return .clear
    }

    private func exportTitle(for date: Date) -> String {
        daySelection.contextSelection(for: date).count == 1
            ? "Export Metadata Programming for Day…"
            : "Export Metadata Programming for Selected Days…"
    }

    private func dayAccessibilityValue(isSelected: Bool, isProgrammed: Bool) -> String {
        switch (isSelected, isProgrammed) {
        case (true, true): "Selected, programmed"
        case (true, false): "Selected, no programming"
        case (false, true): "Programmed"
        case (false, false): "No programming"
        }
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
        .accessibilityLabel(offset < 0 ? "Previous Month" : "Next Month")
        .accessibilityHint("Changes the programming calendar by one month")
        .help(offset < 0 ? "Previous Month" : "Next Month")
    }

    private static func monthStart(for date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }
}

struct ProgrammingDaySelection {
    private let calendar: Calendar
    private(set) var anchor: Date
    private(set) var days: Set<Date>

    init(selectedDate: Date, calendar: Calendar = .current) {
        self.calendar = calendar
        let day = calendar.startOfDay(for: selectedDate)
        anchor = day
        days = [day]
    }

    mutating func select(_ date: Date, extending: Bool) {
        let day = calendar.startOfDay(for: date)
        guard extending else {
            anchor = day
            days = [day]
            return
        }

        let lowerBound = min(anchor, day)
        let upperBound = max(anchor, day)
        var range: Set<Date> = []
        var cursor = lowerBound
        while cursor <= upperBound {
            range.insert(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else {
                break
            }
            cursor = next
        }
        days = range
    }

    mutating func synchronize(to date: Date) {
        guard !contains(date) else { return }
        select(date, extending: false)
    }

    func contains(_ date: Date) -> Bool {
        days.contains(calendar.startOfDay(for: date))
    }

    func contextSelection(for date: Date) -> Set<Date> {
        let day = calendar.startOfDay(for: date)
        return days.contains(day) ? days : [day]
    }
}

private extension MetadataPreviewStatus {
    var symbolName: String {
        switch self {
        case .willApply: "checkmark.circle.fill"
        case .resolutionIncomplete: "exclamationmark.triangle.fill"
        case .previewFailed: "xmark.octagon.fill"
        case .noChanges: "minus.circle"
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
        case .resolutionIncomplete: .orange
        case .previewFailed: .red
        case .noChanges: .secondary
        case .alreadyApplied: .blue
        case .existingMetadataPreserved,
             .noMatchingPhotographer,
             .noScheduledClip,
             .captureTimeUnavailable: .secondary
        }
    }
}
