import SwiftUI

struct PhotographerEditor: View {
    @Binding var photographer: PhotographerProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Photographer Profile").font(.headline)
            TextField("Photographer / creator", text: photographerNameBinding)
            TextField("Filename initials", text: $photographer.filenamePrefix)
                .textCase(.uppercase)
            Text("Separate initials from multiple cameras with commas, for example JAD, JDX.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Copyright notice", text: $photographer.copyrightNotice)
            Text("Used as the photographer name and IPTC Creator/byline.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var photographerNameBinding: Binding<String> {
        Binding(
            get: { photographer.photographerName },
            set: { newValue in
                photographer.name = newValue
                photographer.creator = newValue
            }
        )
    }
}

struct PhotographerWorkHoursControl: View {
    @Binding var photographer: PhotographerProfile
    let day: Date?
    let calendar: Calendar
    @State private var isPresented = false

    init(
        photographer: Binding<PhotographerProfile>,
        day: Date? = nil,
        calendar: Calendar = .current
    ) {
        _photographer = photographer
        self.day = day
        self.calendar = calendar
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Work Hours")
                    .fontWeight(.medium)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Edit…") {
                isPresented = true
            }
            .popover(isPresented: $isPresented, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Work Hours")
                        .font(.title3.weight(.semibold))

                    PhotographerDefaultWorkHoursEditor(
                        photographer: $photographer,
                        calendar: calendar
                    )

                    if let day {
                        Divider()
                        PhotographerDayWorkHoursEditor(
                            photographer: $photographer,
                            day: day,
                            calendar: calendar
                        )
                    }
                }
                .padding(18)
                .frame(width: 430)
            }
        }
    }

    private var summary: String {
        guard let day else {
            guard let hours = photographer.workHours else { return "No profile default" }
            return "Profile default \(formatted(hours))"
        }

        let date = day.formatted(date: .abbreviated, time: .omitted)
        if let override = photographer.workHoursOverride(on: day, calendar: calendar) {
            guard let hours = override.hours else { return "Day off on \(date)" }
            return "Custom \(formatted(hours)) on \(date)"
        }
        guard let hours = photographer.workHours else { return "No hours set for \(date)" }
        return "Profile default \(formatted(hours)) on \(date)"
    }

    private func formatted(_ hours: PhotographerWorkHours) -> String {
        "\(formatted(minutes: hours.startMinutes))–\(formatted(minutes: hours.endMinutes))"
    }

    private func formatted(minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

private struct PhotographerDefaultWorkHoursEditor: View {
    @Binding var photographer: PhotographerProfile
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Use profile default hours", isOn: workHoursEnabled)
            if photographer.workHours != nil {
                HStack {
                    DatePicker(
                        "From",
                        selection: workHourBinding(isStart: true),
                        displayedComponents: .hourAndMinute
                    )
                    DatePicker(
                        "To",
                        selection: workHourBinding(isStart: false),
                        displayedComponents: .hourAndMinute
                    )
                }
            }
            Text("Default hours apply unless a specific calendar day overrides them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var workHoursEnabled: Binding<Bool> {
        Binding(
            get: { photographer.workHours != nil },
            set: { isEnabled in
                photographer.workHours = isEnabled ? photographer.workHours ?? .standard : nil
            }
        )
    }

    private func workHourBinding(isStart: Bool) -> Binding<Date> {
        Binding(
            get: {
                let hours = photographer.workHours ?? .standard
                let minutes = isStart ? hours.startMinutes : hours.endMinutes
                return calendar.date(
                    bySettingHour: minutes / 60,
                    minute: minutes % 60,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { date in
                let components = calendar.dateComponents([.hour, .minute], from: date)
                let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                var hours = photographer.workHours ?? .standard
                if isStart {
                    hours.startMinutes = min(minutes, 24 * 60 - 2)
                    if hours.endMinutes <= hours.startMinutes {
                        hours.endMinutes = min(hours.startMinutes + 60, 24 * 60 - 1)
                    }
                } else {
                    hours.endMinutes = max(minutes, 1)
                    if hours.endMinutes <= hours.startMinutes {
                        hours.startMinutes = max(hours.endMinutes - 60, 0)
                    }
                }
                photographer.workHours = hours
            }
        )
    }
}

private enum PhotographerDayWorkHoursMode: String, CaseIterable, Identifiable {
    case profileDefault
    case custom
    case dayOff

    var id: Self { self }

    var title: String {
        switch self {
        case .profileDefault: "Profile Default"
        case .custom: "Custom Hours"
        case .dayOff: "Day Off"
        }
    }
}

private struct PhotographerDayWorkHoursEditor: View {
    @Binding var photographer: PhotographerProfile
    let day: Date
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hours for \(day.formatted(date: .abbreviated, time: .omitted))")
                .font(.headline)

            Picker("Schedule", selection: modeBinding) {
                ForEach(PhotographerDayWorkHoursMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if mode == .custom {
                HStack {
                    DatePicker(
                        "From",
                        selection: customWorkHourBinding(isStart: true),
                        displayedComponents: .hourAndMinute
                    )
                    DatePicker(
                        "To",
                        selection: customWorkHourBinding(isStart: false),
                        displayedComponents: .hourAndMinute
                    )
                }
            } else {
                Text(dayScheduleDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Menu("Apply to This Week") {
                Button("Apply to Weekdays") {
                    applyCurrentScheduleToWeek(weekdaysOnly: true)
                }
                Button("Apply to All 7 Days") {
                    applyCurrentScheduleToWeek(weekdaysOnly: false)
                }
                Divider()
                Button("Reset Week to Profile Defaults") {
                    resetWeekToProfileDefaults()
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var mode: PhotographerDayWorkHoursMode {
        guard let override = photographer.workHoursOverride(on: day, calendar: calendar) else {
            return .profileDefault
        }
        return override.hours == nil ? .dayOff : .custom
    }

    private var modeBinding: Binding<PhotographerDayWorkHoursMode> {
        Binding(
            get: { mode },
            set: { newMode in
                switch newMode {
                case .profileDefault:
                    photographer.clearWorkHoursOverride(on: day, calendar: calendar)
                case .custom:
                    let hours = photographer.workHours(on: day, calendar: calendar) ?? .standard
                    photographer.setWorkHoursOverride(hours, on: day, calendar: calendar)
                case .dayOff:
                    photographer.setWorkHoursOverride(nil, on: day, calendar: calendar)
                }
            }
        )
    }

    private var dayScheduleDescription: String {
        switch mode {
        case .profileDefault:
            guard let hours = photographer.workHours else {
                return "No default hours are set."
            }
            return "Using profile default: \(formatted(hours))."
        case .dayOff:
            return "This photographer is not working on this date."
        case .custom:
            return ""
        }
    }

    private func customWorkHourBinding(isStart: Bool) -> Binding<Date> {
        Binding(
            get: {
                let hours = photographer.workHoursOverride(on: day, calendar: calendar)?.hours ?? .standard
                let minutes = isStart ? hours.startMinutes : hours.endMinutes
                return calendar.date(
                    bySettingHour: minutes / 60,
                    minute: minutes % 60,
                    second: 0,
                    of: day
                ) ?? day
            },
            set: { date in
                let components = calendar.dateComponents([.hour, .minute], from: date)
                let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                var hours = photographer.workHoursOverride(on: day, calendar: calendar)?.hours ?? .standard
                if isStart {
                    hours.startMinutes = min(minutes, 24 * 60 - 2)
                    if hours.endMinutes <= hours.startMinutes {
                        hours.endMinutes = min(hours.startMinutes + 60, 24 * 60 - 1)
                    }
                } else {
                    hours.endMinutes = max(minutes, 1)
                    if hours.endMinutes <= hours.startMinutes {
                        hours.startMinutes = max(hours.endMinutes - 60, 0)
                    }
                }
                photographer.setWorkHoursOverride(hours, on: day, calendar: calendar)
            }
        )
    }

    private func applyCurrentScheduleToWeek(weekdaysOnly: Bool) {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: day) else { return }
        let sourceOverride = photographer.workHoursOverride(on: day, calendar: calendar)
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: week.start),
                  !weekdaysOnly || !calendar.isDateInWeekend(date) else {
                continue
            }
            if let sourceOverride {
                photographer.setWorkHoursOverride(sourceOverride.hours, on: date, calendar: calendar)
            } else {
                photographer.clearWorkHoursOverride(on: date, calendar: calendar)
            }
        }
    }

    private func resetWeekToProfileDefaults() {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: day) else { return }
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: week.start) else { continue }
            photographer.clearWorkHoursOverride(on: date, calendar: calendar)
        }
    }

    private func formatted(_ hours: PhotographerWorkHours) -> String {
        "\(formatted(minutes: hours.startMinutes))–\(formatted(minutes: hours.endMinutes))"
    }

    private func formatted(minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

struct TimelinePhotographerEditor: View {
    @Binding var photographer: PhotographerProfile
    let day: Date
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Edit Photographer Track")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }

            PhotographerEditor(photographer: $photographer)
            Divider()
            PhotographerWorkHoursControl(
                photographer: $photographer,
                day: day
            )
        }
        .padding(20)
        .frame(width: 480)
    }
}

struct TimelineAddPhotographerRow: View {
    let knownPhotographers: [PhotographerProfile]
    let onAddNew: () -> Void
    let onAddKnown: (PhotographerProfile) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                Button(action: onAddNew) {
                    Label("New Photographer", systemImage: "person.badge.plus")
                }

                if !knownPhotographers.isEmpty {
                    Divider()
                    Section("Known Photographers") {
                        ForEach(knownPhotographers) { photographer in
                            Button {
                                onAddKnown(photographer)
                            } label: {
                                Text("\(photographer.photographerName) (\(photographer.formattedFilenamePrefixes))")
                            }
                        }
                    }
                }
            } label: {
                Label("Add Photographer", systemImage: "plus.circle.fill")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 177)
            .help(knownPhotographers.isEmpty ? "Add a photographer" : "Add a new or known photographer")

            Rectangle()
                .fill(.quaternary.opacity(0.25))
                .overlay(alignment: .leading) {
                    Text("Tracks are matched using filename initials")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 12)
                }
        }
        .frame(height: 52)
    }
}

struct PhotographerTrackDropDelegate: DropDelegate {
    let destinationID: UUID
    @Binding var draggedPhotographerID: UUID?
    let onMove: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedPhotographerID,
              draggedPhotographerID != destinationID else {
            return
        }

        withAnimation(.snappy(duration: 0.18)) {
            onMove(draggedPhotographerID, destinationID)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedPhotographerID = nil
        return true
    }
}
