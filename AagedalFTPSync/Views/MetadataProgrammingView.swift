import AppKit
import SwiftUI

struct MetadataProgrammingView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedDate = Date()
    @State private var draft = MetadataAutomation()
    @State private var loadedJobID: UUID?
    @State private var selectedPhotographerID: UUID?
    @State private var editingClipID: UUID?
    @State private var photographerPendingDeletion: PhotographerProfile?
    @State private var saveConfirmation = false
    @State private var selectedClipIDs: Set<UUID> = []
    @State private var copiedClips: [MetadataScheduleClip] = []
    @State private var snapMinutes = 15
    @State private var pendingClipChange: PendingClipChange?
    @FocusState private var timelineFocused: Bool

    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 0) {
            windowHeader
            Divider()

            if selectedJob == nil {
                ContentUnavailableView(
                    "No sync job selected",
                    systemImage: "tag.slash",
                    description: Text("Create or select a sync job before programming metadata.")
                )
            } else {
                HSplitView {
                    librarySidebar
                        .frame(minWidth: 285, idealWidth: 315, maxWidth: 370)
                    dayTimeline
                        .frame(minWidth: 650)
                }
            }

            Divider()
            footer
        }
        .frame(minWidth: 980, minHeight: 650)
        .onAppear(perform: loadSelectedJob)
        .onChange(of: store.selectedJobID) { _, _ in loadSelectedJob() }
        .sheet(isPresented: Binding(
            get: { editingClipID != nil },
            set: { if !$0 { editingClipID = nil } }
        )) {
            if let clipID = editingClipID,
               let clip = draft.clips.first(where: { $0.id == clipID }) {
                MetadataClipEditor(
                    clip: clip,
                    photographers: draft.photographers,
                    onSave: updateClip,
                    onCopy: copyClip
                )
            }
        }
        .confirmationDialog(
            "Remove photographer?",
            isPresented: Binding(
                get: { photographerPendingDeletion != nil },
                set: { if !$0 { photographerPendingDeletion = nil } }
            ),
            presenting: photographerPendingDeletion
        ) { photographer in
            Button("Remove \(photographer.name)", role: .destructive) {
                removePhotographer(photographer)
            }
        } message: { photographer in
            Text("This also removes every metadata clip on \(photographer.name)’s track.")
        }
        .alert(
            "Extend into another day?",
            isPresented: Binding(
                get: { pendingClipChange != nil },
                set: { if !$0 { pendingClipChange = nil } }
            ),
            presenting: pendingClipChange
        ) { change in
            Button("Cancel", role: .cancel) { pendingClipChange = nil }
            Button("Apply Change") {
                applyClipChange(change.clip)
                pendingClipChange = nil
            }
        } message: { change in
            Text("Resizing \(change.clip.name) crosses midnight, so it will appear on more than one day’s timeline.")
        }
    }

    private var windowHeader: some View {
        HStack(spacing: 14) {
            Label("Metadata Programming", systemImage: "tag.fill")
                .font(.title2.weight(.semibold))

            Spacer()

            Picker("Sync job", selection: selectedJobBinding) {
                ForEach(store.jobs) { job in
                    Text(job.name).tag(Optional(job.id))
                }
            }
            .frame(width: 270)

            Toggle("Automatic metadata", isOn: $draft.isEnabled)
                .toggleStyle(.switch)
                .disabled(!canEnableMetadata)
                .help(canEnableMetadata
                    ? "Apply scheduled metadata as files arrive"
                    : "Choose a one-way job with a local destination")
        }
        .padding(16)
    }

    private var librarySidebar: some View {
        VStack(spacing: 0) {
            GroupBox("Calendar") {
                DatePicker(
                    "Day",
                    selection: $selectedDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
            }
            .padding(12)

            Divider()

            HStack {
                Text("Photographers").font(.headline)
                Spacer()
                Button(action: addPhotographer) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add Photographer")
                Button(action: requestPhotographerRemoval) {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selectedPhotographer == nil)
                .help("Remove Photographer")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            List(selection: $selectedPhotographerID) {
                ForEach(draft.photographers) { photographer in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(photographer.name.isEmpty ? "Untitled Photographer" : photographer.name)
                            .fontWeight(.medium)
                        Text(photographer.normalizedPrefix.isEmpty ? "No filename prefix" : "\(photographer.normalizedPrefix)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(photographer.id)
                }
            }
            .frame(minHeight: 130)

            if let photographerID = selectedPhotographerID,
               let binding = photographerBinding(for: photographerID) {
                Divider()
                PhotographerEditor(photographer: binding)
                    .padding(12)
            }
        }
    }

    private var dayTimeline: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { moveDay(by: -1) } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Previous Day")

                Text(selectedDate.formatted(date: .complete, time: .omitted))
                    .font(.headline)
                    .frame(minWidth: 250)

                Button { moveDay(by: 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .help("Next Day")

                Button("Today") { selectedDate = Date() }

                Spacer()

                Picker("Snap", selection: $snapMinutes) {
                    Text("5 min").tag(5)
                    Text("15 min").tag(15)
                    Text("30 min").tag(30)
                    Text("1 hour").tag(60)
                }
                .pickerStyle(.menu)
                .frame(width: 125)

                Button(action: editSelectedClip) {
                    Image(systemName: "pencil")
                }
                .disabled(selectedClipIDs.count != 1)
                .help("Edit Selected Clip (Return)")

                Button(action: copySelectedClips) {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(selectedClipIDs.isEmpty)
                .help("Copy Selected Clips (Command-C)")

                Button(action: pasteClips) {
                    Image(systemName: "doc.on.clipboard")
                }
                .disabled(copiedClips.isEmpty)
                .help("Paste Clips on Selected Day (Command-V)")

                Button(role: .destructive, action: deleteSelectedClips) {
                    Image(systemName: "trash")
                }
                .disabled(selectedClipIDs.isEmpty)
                .help("Delete Selected Clips")

                Button(action: addClip) {
                    Label("Add Metadata Clip", systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedPhotographer == nil)
                .help(selectedPhotographer == nil ? "Select a photographer first" : "Add a clip to the selected photographer")
            }
            .padding(14)

            Divider()

            if timelinePhotographers.isEmpty {
                ContentUnavailableView {
                    Label("No programming for this day", systemImage: "calendar.badge.plus")
                } description: {
                    Text("Select a photographer from the library, then add a metadata clip.")
                } actions: {
                    Button("Add Metadata Clip", action: addClip)
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedPhotographer == nil)
                }
            } else {
                ScrollView([.horizontal, .vertical]) {
                    VStack(spacing: 0) {
                        TimelineHourHeader(day: selectedDate)
                        ForEach(timelinePhotographers) { photographer in
                            TimelineTrack(
                                photographer: photographer,
                                clips: clips(for: photographer),
                                allClips: draft.clips,
                                day: selectedDate,
                                color: color(for: photographer),
                                selectedClipIDs: selectedClipIDs,
                                onSelect: selectClip,
                                onEdit: { editingClipID = $0.id },
                                onMove: moveClip,
                                onResize: resizeClip
                            )
                            Divider()
                        }
                    }
                    .frame(minWidth: 920)
                }
                .focusable()
                .focused($timelineFocused)
                .onKeyPress(.leftArrow) {
                    selectAdjacentClip(horizontalOffset: -1)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    selectAdjacentClip(horizontalOffset: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selectAdjacentTrack(offset: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    selectAdjacentTrack(offset: 1)
                    return .handled
                }
            }

            keyboardShortcuts
        }
    }

    private var keyboardShortcuts: some View {
        Group {
            Button("Copy", action: copySelectedClips)
                .keyboardShortcut("c", modifiers: .command)
            Button("Paste", action: pasteClips)
                .keyboardShortcut("v", modifiers: .command)
            Button("Select All Clips", action: selectAllClipsForDay)
                .keyboardShortcut("a", modifiers: .command)
            Button("Edit Clip", action: editSelectedClip)
                .keyboardShortcut(.return, modifiers: [])
            Button("Delete Clips", action: deleteSelectedClips)
                .keyboardShortcut(.delete, modifiers: [])
            Button("Previous Day") { moveDay(by: -1) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Next Day") { moveDay(by: 1) }
                .keyboardShortcut("]", modifiers: .command)
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let message = draft.validationMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if let selectedJob, draft.isEnabled, !canEnableMetadata {
                Label("\(selectedJob.name) needs a one-way local destination.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Matching uses the filename prefix and the source file’s modification time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if saveConfirmation {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Button("Save Programming", action: save)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(loadedJobID == nil || draft.validationMessage != nil || (draft.isEnabled && !canEnableMetadata))
        }
        .padding(14)
    }

    private var selectedJobBinding: Binding<UUID?> {
        Binding(
            get: { store.selectedJobID },
            set: { store.selectedJobID = $0 }
        )
    }

    private var selectedJob: SyncJob? {
        guard let selectedJobID = store.selectedJobID else { return nil }
        return store.jobs.first(where: { $0.id == selectedJobID })
    }

    private var canEnableMetadata: Bool {
        guard let selectedJob, selectedJob.direction != .bidirectional else { return false }
        let target = selectedJob.direction == .leftToRight ? selectedJob.right : selectedJob.left
        return target.kind == .local
    }

    private var selectedPhotographer: PhotographerProfile? {
        guard let selectedPhotographerID else { return nil }
        return draft.photographers.first(where: { $0.id == selectedPhotographerID })
    }

    private var timelinePhotographers: [PhotographerProfile] {
        draft.photographers
    }

    private func clips(for photographer: PhotographerProfile) -> [MetadataScheduleClip] {
        draft.clips
            .filter {
                $0.photographerID == photographer.id
                    && $0.overlaps(dayContaining: selectedDate, calendar: calendar)
            }
            .sorted { $0.startsAt < $1.startsAt }
    }

    private func photographerBinding(for id: UUID) -> Binding<PhotographerProfile>? {
        guard let index = draft.photographers.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { draft.photographers[index] },
            set: { draft.photographers[index] = $0 }
        )
    }

    private func loadSelectedJob() {
        guard let job = selectedJob else {
            loadedJobID = nil
            draft = MetadataAutomation()
            selectedPhotographerID = nil
            return
        }
        loadedJobID = job.id
        draft = job.metadataAutomation ?? MetadataAutomation()
        selectedPhotographerID = draft.photographers.first?.id
        selectedClipIDs = []
        copiedClips = []
    }

    private func addPhotographer() {
        let photographer = PhotographerProfile(
            name: "Photographer",
            filenamePrefix: uniquePrefix(),
            creator: "",
            copyrightNotice: ""
        )
        draft.photographers.append(photographer)
        selectedPhotographerID = photographer.id
    }

    private func uniquePrefix() -> String {
        let used = Set(draft.photographers.map(\.normalizedPrefix))
        for prefix in ["AAA", "BBB", "CCC", "DDD", "EEE", "FFF", "GGG"] where !used.contains(prefix) {
            return prefix
        }
        var number = draft.photographers.count + 1
        while used.contains("P\(number)") { number += 1 }
        return "P\(number)"
    }

    private func requestPhotographerRemoval() {
        photographerPendingDeletion = selectedPhotographer
    }

    private func removePhotographer(_ photographer: PhotographerProfile) {
        draft.photographers.removeAll { $0.id == photographer.id }
        draft.clips.removeAll { $0.photographerID == photographer.id }
        selectedClipIDs = selectedClipIDs.filter { id in draft.clips.contains(where: { $0.id == id }) }
        selectedPhotographerID = draft.photographers.first?.id
        photographerPendingDeletion = nil
    }

    private func addClip() {
        guard let photographer = selectedPhotographer else { return }
        let dayStart = calendar.startOfDay(for: selectedDate)
        let startHour = calendar.isDateInToday(selectedDate)
            ? min(max(calendar.component(.hour, from: Date()), 0), 22)
            : 9
        let start = calendar.date(byAdding: .hour, value: startHour, to: dayStart) ?? dayStart
        let end = calendar.date(byAdding: .hour, value: 1, to: start) ?? start.addingTimeInterval(3_600)
        let clip = MetadataScheduleClip(
            photographerID: photographer.id,
            name: "Metadata preset",
            startsAt: start,
            endsAt: end
        )
        draft.clips.append(clip)
        selectedClipIDs = [clip.id]
        editingClipID = clip.id
    }

    private func updateClip(_ clip: MetadataScheduleClip) {
        guard let index = draft.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        draft.clips[index] = clip
        editingClipID = nil
    }

    private func copyClip(_ clip: MetadataScheduleClip, to photographerID: UUID) {
        var copy = clip
        copy.id = UUID()
        copy.photographerID = photographerID
        draft.clips.append(copy)
    }

    private func selectClip(_ clip: MetadataScheduleClip) {
        if NSEvent.modifierFlags.contains(.command) {
            if selectedClipIDs.contains(clip.id) {
                selectedClipIDs.remove(clip.id)
            } else {
                selectedClipIDs.insert(clip.id)
            }
        } else {
            selectedClipIDs = [clip.id]
        }
        selectedPhotographerID = clip.photographerID
        timelineFocused = true
    }

    private func editSelectedClip() {
        guard selectedClipIDs.count == 1, let id = selectedClipIDs.first else { return }
        editingClipID = id
    }

    private func copySelectedClips() {
        copiedClips = draft.clips
            .filter { selectedClipIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.startsAt != rhs.startsAt { return lhs.startsAt < rhs.startsAt }
                return lhs.photographerID.uuidString < rhs.photographerID.uuidString
            }
    }

    private func pasteClips() {
        guard !copiedClips.isEmpty else { return }
        let sourceDay = calendar.startOfDay(for: copiedClips.map(\.startsAt).min() ?? selectedDate)
        let targetDay = calendar.startOfDay(for: selectedDate)
        let dayOffset = calendar.dateComponents([.day], from: sourceDay, to: targetDay).day ?? 0
        let sourcePhotographers = Set(copiedClips.map(\.photographerID))
        let singleTarget = sourcePhotographers.count == 1 ? selectedPhotographerID : nil

        let pasted = copiedClips.map { source -> MetadataScheduleClip in
            var copy = source
            copy.id = UUID()
            copy.photographerID = singleTarget ?? source.photographerID
            copy.startsAt = calendar.date(byAdding: .day, value: dayOffset, to: source.startsAt) ?? source.startsAt
            copy.endsAt = calendar.date(byAdding: .day, value: dayOffset, to: source.endsAt) ?? source.endsAt
            return copy
        }
        draft.clips.append(contentsOf: pasted)
        selectedClipIDs = Set(pasted.map(\.id))
        timelineFocused = true
    }

    private func deleteSelectedClips() {
        guard !selectedClipIDs.isEmpty else { return }
        draft.clips.removeAll { selectedClipIDs.contains($0.id) }
        selectedClipIDs = []
    }

    private func selectAllClipsForDay() {
        selectedClipIDs = Set(draft.clips.filter {
            $0.overlaps(dayContaining: selectedDate, calendar: calendar)
        }.map(\.id))
        timelineFocused = true
    }

    private func moveClip(_ clip: MetadataScheduleClip, by interval: TimeInterval) {
        let changed = MetadataTimelineEditing.moving(
            clip,
            by: interval,
            snapMinutes: snapMinutes,
            calendar: calendar
        )
        applyClipChange(changed)
    }

    private func resizeClip(
        _ clip: MetadataScheduleClip,
        edge: MetadataClipResizeEdge,
        by interval: TimeInterval
    ) {
        let changed = MetadataTimelineEditing.resizing(
            clip,
            edge: edge,
            by: interval,
            snapMinutes: snapMinutes,
            calendar: calendar
        )
        let originallyCrossedMidnight = !calendar.isDate(clip.startsAt, inSameDayAs: clip.endsAt)
        let nowCrossesMidnight = !calendar.isDate(changed.startsAt, inSameDayAs: changed.endsAt)
        if nowCrossesMidnight && !originallyCrossedMidnight {
            pendingClipChange = PendingClipChange(clip: changed)
        } else {
            applyClipChange(changed)
        }
    }

    private func applyClipChange(_ clip: MetadataScheduleClip) {
        guard let index = draft.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        draft.clips[index] = clip
        selectedClipIDs = [clip.id]
        selectedPhotographerID = clip.photographerID
    }

    private func selectAdjacentClip(horizontalOffset: Int) {
        let visible = draft.clips
            .filter { $0.overlaps(dayContaining: selectedDate, calendar: calendar) }
            .sorted { $0.startsAt < $1.startsAt }
        guard !visible.isEmpty else { return }
        guard selectedClipIDs.count == 1,
              let selectedID = selectedClipIDs.first,
              let selected = visible.first(where: { $0.id == selectedID }) else {
            selectClip(visible[horizontalOffset < 0 ? visible.count - 1 : 0])
            return
        }
        let sameTrack = visible.filter { $0.photographerID == selected.photographerID }
        guard let index = sameTrack.firstIndex(where: { $0.id == selected.id }) else { return }
        let target = min(max(index + horizontalOffset, 0), sameTrack.count - 1)
        selectClip(sameTrack[target])
    }

    private func selectAdjacentTrack(offset: Int) {
        guard !timelinePhotographers.isEmpty else { return }
        let selected = selectedClipIDs.count == 1
            ? draft.clips.first(where: { $0.id == selectedClipIDs.first })
            : nil
        let currentPhotographerID = selected?.photographerID ?? selectedPhotographerID
        let currentIndex = timelinePhotographers.firstIndex(where: { $0.id == currentPhotographerID }) ?? 0
        let targetIndex = min(max(currentIndex + offset, 0), timelinePhotographers.count - 1)
        let targetPhotographer = timelinePhotographers[targetIndex]
        let trackClips = clips(for: targetPhotographer)
        selectedPhotographerID = targetPhotographer.id
        guard !trackClips.isEmpty else {
            selectedClipIDs = []
            return
        }
        let referenceDate = selected?.startsAt ?? calendar.startOfDay(for: selectedDate)
        let nearest = trackClips.min {
            abs($0.startsAt.timeIntervalSince(referenceDate)) < abs($1.startsAt.timeIntervalSince(referenceDate))
        }
        if let nearest { selectedClipIDs = [nearest.id] }
    }

    private func moveDay(by value: Int) {
        selectedDate = calendar.date(byAdding: .day, value: value, to: selectedDate) ?? selectedDate
        selectedClipIDs = selectedClipIDs.filter { id in
            draft.clips.first(where: { $0.id == id })?.overlaps(dayContaining: selectedDate, calendar: calendar) == true
        }
    }

    private func color(for photographer: PhotographerProfile) -> Color {
        let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .teal, .indigo]
        let index = draft.photographers.firstIndex(where: { $0.id == photographer.id }) ?? 0
        return colors[index % colors.count]
    }

    private func save() {
        guard let loadedJobID,
              store.saveMetadataAutomation(draft, for: loadedJobID) else {
            saveConfirmation = false
            return
        }
        saveConfirmation = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            saveConfirmation = false
        }
    }
}

private struct PhotographerEditor: View {
    @Binding var photographer: PhotographerProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Photographer Profile").font(.headline)
            TextField("Name", text: $photographer.name)
            TextField("Filename prefix", text: $photographer.filenamePrefix)
                .textCase(.uppercase)
            TextField("Creator / byline", text: $photographer.creator)
            TextField("Copyright notice", text: $photographer.copyrightNotice)
            Text("Profiles stay in the library even on days when they have no timeline clips.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PendingClipChange: Identifiable {
    let id = UUID()
    let clip: MetadataScheduleClip
}

private struct TimelineHourHeader: View {
    let day: Date
    private let calendar = Calendar.current

    var body: some View {
        HStack(spacing: 0) {
            Text("Photographer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 165, alignment: .leading)
                .padding(.leading, 12)

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    ForEach(Array(stride(from: 0, through: 24, by: 3)), id: \.self) { hour in
                        Text(String(format: "%02d:00", hour))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .offset(x: max(0, proxy.size.width * CGFloat(hour) / 24 - 15))
                    }
                    if calendar.isDateInToday(day) {
                        Rectangle()
                            .fill(.red.opacity(0.75))
                            .frame(width: 1)
                            .offset(x: currentTimeOffset(totalWidth: proxy.size.width))
                    }
                }
            }
        }
        .frame(height: 28)
        .background(.bar)
    }

    private func currentTimeOffset(totalWidth: CGFloat) -> CGFloat {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return CGFloat(Date().timeIntervalSince(start) / end.timeIntervalSince(start)) * totalWidth
    }
}

private struct TimelineTrack: View {
    let photographer: PhotographerProfile
    let clips: [MetadataScheduleClip]
    let allClips: [MetadataScheduleClip]
    let day: Date
    let color: Color
    let selectedClipIDs: Set<UUID>
    let onSelect: (MetadataScheduleClip) -> Void
    let onEdit: (MetadataScheduleClip) -> Void
    let onMove: (MetadataScheduleClip, TimeInterval) -> Void
    let onResize: (MetadataScheduleClip, MetadataClipResizeEdge, TimeInterval) -> Void

    private let calendar = Calendar.current

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(photographer.name).fontWeight(.medium).lineLimit(1)
                Text(photographer.normalizedPrefix).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 165, alignment: .leading)
            .padding(.leading, 12)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    hourGrid
                    gapHighlights(totalWidth: proxy.size.width)
                    overlapHighlights(totalWidth: proxy.size.width)
                    currentTimeMarker(totalWidth: proxy.size.width)
                    ForEach(clips) { clip in
                        TimelineClipView(
                            clip: clip,
                            color: color,
                            isSelected: selectedClipIDs.contains(clip.id),
                            continuesFromPreviousDay: clip.startsAt < dayStart,
                            continuesIntoNextDay: clip.endsAt > nextDay,
                            timeLabel: timeLabel(for: clip),
                            secondsPerPoint: dayDuration / max(proxy.size.width, 1),
                            onSelect: { onSelect(clip) },
                            onEdit: { onEdit(clip) },
                            onMove: { onMove(clip, $0) },
                            onResize: { edge, interval in onResize(clip, edge, interval) }
                        )
                        .frame(width: clipWidth(clip, totalWidth: proxy.size.width), height: 44)
                        .offset(x: clipOffset(clip, totalWidth: proxy.size.width))
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 58)
    }

    private var dayStart: Date { calendar.startOfDay(for: day) }

    private var nextDay: Date {
        calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
    }

    private var dayDuration: TimeInterval { nextDay.timeIntervalSince(dayStart) }

    private var hourGrid: some View {
        HStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { _ in
                Rectangle()
                    .fill(.separator.opacity(0.45))
                    .frame(width: 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func gapHighlights(totalWidth: CGFloat) -> some View {
        ForEach(MetadataTimelineAnalysis.gaps(
            in: allClips,
            for: photographer.id,
            on: day,
            calendar: calendar
        ), id: \.self) { interval in
            Rectangle()
                .fill(.orange.opacity(0.055))
                .overlay(alignment: .center) {
                    if intervalWidth(interval, totalWidth: totalWidth) > 70 {
                        Text("gap")
                            .font(.caption2)
                            .foregroundStyle(.orange.opacity(0.65))
                    }
                }
                .frame(width: intervalWidth(interval, totalWidth: totalWidth), height: 52)
                .offset(x: intervalOffset(interval, totalWidth: totalWidth))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func overlapHighlights(totalWidth: CGFloat) -> some View {
        ForEach(MetadataTimelineAnalysis.overlaps(
            in: allClips,
            for: photographer.id,
            on: day,
            calendar: calendar
        ), id: \.self) { interval in
            Rectangle()
                .fill(.red.opacity(0.2))
                .frame(width: intervalWidth(interval, totalWidth: totalWidth), height: 52)
                .offset(x: intervalOffset(interval, totalWidth: totalWidth))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func currentTimeMarker(totalWidth: CGFloat) -> some View {
        if calendar.isDateInToday(day) {
            Rectangle()
                .fill(.red.opacity(0.75))
                .frame(width: 1, height: 52)
                .offset(x: CGFloat(Date().timeIntervalSince(dayStart) / dayDuration) * totalWidth)
                .allowsHitTesting(false)
        }
    }

    private func clippedInterval(
        for clip: MetadataScheduleClip
    ) -> (start: TimeInterval, end: TimeInterval, dayDuration: TimeInterval) {
        return (
            max(clip.startsAt, dayStart).timeIntervalSince(dayStart),
            min(clip.endsAt, nextDay).timeIntervalSince(dayStart),
            nextDay.timeIntervalSince(dayStart)
        )
    }

    private func clipOffset(_ clip: MetadataScheduleClip, totalWidth: CGFloat) -> CGFloat {
        let interval = clippedInterval(for: clip)
        return CGFloat(interval.start / interval.dayDuration) * totalWidth
    }

    private func clipWidth(_ clip: MetadataScheduleClip, totalWidth: CGFloat) -> CGFloat {
        let interval = clippedInterval(for: clip)
        return max(42, CGFloat((interval.end - interval.start) / interval.dayDuration) * totalWidth)
    }

    private func timeLabel(for clip: MetadataScheduleClip) -> String {
        let start = clip.startsAt.formatted(date: .omitted, time: .shortened)
        let end = clip.endsAt.formatted(date: .omitted, time: .shortened)
        return "\(start)–\(end)"
    }

    private func intervalOffset(_ interval: DateInterval, totalWidth: CGFloat) -> CGFloat {
        CGFloat(interval.start.timeIntervalSince(dayStart) / dayDuration) * totalWidth
    }

    private func intervalWidth(_ interval: DateInterval, totalWidth: CGFloat) -> CGFloat {
        CGFloat(interval.duration / dayDuration) * totalWidth
    }
}

private struct TimelineClipView: View {
    let clip: MetadataScheduleClip
    let color: Color
    let isSelected: Bool
    let continuesFromPreviousDay: Bool
    let continuesIntoNextDay: Bool
    let timeLabel: String
    let secondsPerPoint: TimeInterval
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onMove: (TimeInterval) -> Void
    let onResize: (MetadataClipResizeEdge, TimeInterval) -> Void

    @GestureState private var moveTranslation: CGFloat = 0
    @GestureState private var startTranslation: CGFloat = 0
    @GestureState private var endTranslation: CGFloat = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.22))

            HStack(spacing: 3) {
                if continuesFromPreviousDay {
                    Image(systemName: "arrow.left")
                        .font(.caption2.weight(.bold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.name).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(timeLabel).font(.caption2.monospacedDigit()).lineLimit(1)
                }
                Spacer(minLength: 0)
                if continuesIntoNextDay {
                    Image(systemName: "arrow.right")
                        .font(.caption2.weight(.bold))
                }
            }
            .padding(.horizontal, 9)

            HStack(spacing: 0) {
                resizeHandle(edge: .start)
                Spacer(minLength: 0)
                resizeHandle(edge: .end)
            }
        }
        .foregroundStyle(color)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? color : color.opacity(0.7), lineWidth: isSelected ? 2.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .offset(x: moveTranslation)
        .onTapGesture(count: 2, perform: onEdit)
        .onTapGesture(perform: onSelect)
        .gesture(moveGesture)
        .help("Click to select, Command-click for multiple selection, drag to move, or drag an edge to resize. Double-click to edit.")
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .updating($moveTranslation) { value, state, _ in state = value.translation.width }
            .onEnded { value in onMove(value.translation.width * secondsPerPoint) }
    }

    private func resizeHandle(edge: MetadataClipResizeEdge) -> some View {
        let translation = edge == .start ? startTranslation : endTranslation
        return Capsule()
            .fill(isSelected ? color : color.opacity(0.7))
            .frame(width: 5, height: 27)
            .padding(.horizontal, 2)
            .offset(x: translation)
            .contentShape(Rectangle().inset(by: -4))
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .updating(edge == .start ? $startTranslation : $endTranslation) { value, state, _ in
                        state = value.translation.width
                    }
                    .onEnded { value in onResize(edge, value.translation.width * secondsPerPoint) }
            )
    }
}

private struct MetadataClipEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MetadataScheduleClip
    @State private var keywordsText: String
    @State private var copyTargetID: UUID?
    @State private var showNextDayConfirmation = false
    @State private var validationMessage: String?

    let photographers: [PhotographerProfile]
    let onSave: (MetadataScheduleClip) -> Void
    let onCopy: (MetadataScheduleClip, UUID) -> Void

    init(
        clip: MetadataScheduleClip,
        photographers: [PhotographerProfile],
        onSave: @escaping (MetadataScheduleClip) -> Void,
        onCopy: @escaping (MetadataScheduleClip, UUID) -> Void
    ) {
        _draft = State(initialValue: clip)
        _keywordsText = State(initialValue: clip.fields.keywords.joined(separator: ", "))
        _copyTargetID = State(initialValue: photographers.first(where: { $0.id != clip.photographerID })?.id)
        self.photographers = photographers
        self.onSave = onSave
        self.onCopy = onCopy
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Metadata Clip") {
                    TextField("Name", text: $draft.name)
                    Picker("Photographer", selection: $draft.photographerID) {
                        ForEach(photographers) { Text($0.name).tag($0.id) }
                    }
                    DatePicker("Starts", selection: $draft.startsAt)
                    DatePicker("Ends", selection: $draft.endsAt)
                }

                Section("IPTC Metadata") {
                    TextField("Headline", text: $draft.fields.headline)
                    LabeledContent("Description") {
                        TextEditor(text: $draft.fields.description)
                            .font(.body)
                            .frame(minHeight: 90)
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(.separator, lineWidth: 1)
                            }
                    }
                    TextField("Keywords", text: $keywordsText, prompt: Text("politics, conference, Oslo"))
                    Text("Separate keywords with commas. Creator and copyright come from the photographer profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if photographers.count > 1 {
                    Section("Copy") {
                        HStack {
                            Picker("Copy this programming to", selection: $copyTargetID) {
                                ForEach(photographers.filter { $0.id != draft.photographerID }) {
                                    Text($0.name).tag(Optional($0.id))
                                }
                            }
                            Button("Copy") {
                                normalizeKeywords()
                                if let copyTargetID { onCopy(draft, copyTargetID) }
                            }
                            .disabled(copyTargetID == nil)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: attemptSave)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 590, height: 560)
        .alert("Extend into the next day?", isPresented: $showNextDayConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Extend and Save") { commitSave() }
        } message: {
            Text("This metadata clip ends on a different day. It will also appear on that day’s timeline.")
        }
    }

    private func attemptSave() {
        normalizeKeywords()
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "Give the metadata clip a name."
            return
        }
        guard draft.endsAt > draft.startsAt else {
            validationMessage = "The clip must end after it starts."
            return
        }
        draft.name = trimmedName
        validationMessage = nil

        if !Calendar.current.isDate(draft.startsAt, inSameDayAs: draft.endsAt) {
            showNextDayConfirmation = true
        } else {
            commitSave()
        }
    }

    private func commitSave() {
        onSave(draft)
        dismiss()
    }

    private func normalizeKeywords() {
        draft.fields.keywords = keywordsText
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
