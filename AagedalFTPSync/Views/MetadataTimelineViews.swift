import AppKit
import SwiftUI

struct TimelineHourHeader: View {
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
                    ForEach(Array(stride(from: 0, to: 24, by: 3)), id: \.self) { hour in
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

            VStack(spacing: 0) {
                Text("24:00")
                    .monospacedDigit()
                Text(nextDayLabel)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: 68)
            .frame(maxHeight: .infinity)
            .background(Color.accentColor.opacity(0.1))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: 2)
            }
            .accessibilityLabel("Next day, \(nextDayLabel), starts at midnight")
        }
        .frame(height: 34)
        .background(.bar)
    }

    private var nextDayLabel: String {
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        return nextDay.formatted(.dateTime.weekday(.abbreviated).day())
    }

    private func currentTimeOffset(totalWidth: CGFloat) -> CGFloat {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return CGFloat(Date().timeIntervalSince(start) / end.timeIntervalSince(start)) * totalWidth
    }
}

struct TimelineTrack: View {
    let photographer: PhotographerProfile
    let clips: [MetadataScheduleClip]
    let allClips: [MetadataScheduleClip]
    let day: Date
    let color: Color
    let snapMinutes: Int
    let selectedClipIDs: Set<UUID>
    let playheadDate: Date?
    let showsPlayhead: Bool
    let canPaste: Bool
    let isSelected: Bool
    let processedFileCount: Int
    let canReprocess: Bool
    let onSelectPhotographer: () -> Void
    let onEditPhotographer: () -> Void
    let onRequestRemove: () -> Void
    let onReprocessPhotographer: () -> Void
    let onBeginReordering: () -> Void
    let onSelect: (MetadataScheduleClip) -> Void
    let onEdit: (MetadataScheduleClip) -> Void
    let onCreate: (PhotographerProfile, Date, Date) -> Void
    let onMove: (MetadataScheduleClip, TimeInterval, Bool) -> Void
    let onResize: (MetadataScheduleClip, MetadataClipResizeEdge, TimeInterval) -> Void
    let onReprocessClip: (MetadataScheduleClip) -> Void
    let onPlacePlayhead: (UUID, Date) -> Void
    let onPasteAtPlayhead: (Date, UUID) -> Void

    private let calendar = Calendar.current
    @GestureState private var creationDrag: DragGesture.Value?

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                    .contentShape(Rectangle().inset(by: -6))
                    .onDrag {
                        onBeginReordering()
                        return NSItemProvider(object: photographer.id.uuidString as NSString)
                    }
                    .help("Drag to reorder this track")

                VStack(alignment: .leading, spacing: 3) {
                    Text(photographer.photographerName).fontWeight(.medium).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(photographer.formattedFilenamePrefixes)
                            .lineLimit(1)
                        Label(processedFileCount.formatted(), systemImage: "checkmark")
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .help(processedFileHelp)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 2)

                Button(action: onEditPhotographer) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Edit photographer and work hours")
            }
            .padding(.horizontal, 8)
            .frame(width: 177, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelectPhotographer)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(creationGesture(totalWidth: proxy.size.width))
                        .simultaneousGesture(playheadGesture(totalWidth: proxy.size.width))
                        .help("Click to place the playhead or drag to create a metadata clip")
                    workHoursBackground(totalWidth: proxy.size.width)
                    hourGrid
                    overlapHighlights(totalWidth: proxy.size.width)
                    currentTimeMarker(totalWidth: proxy.size.width)
                    creationPreview(totalWidth: proxy.size.width)
                    ForEach(clips) { clip in
                        TimelineClipView(
                            clip: clip,
                            color: color,
                            isSelected: selectedClipIDs.contains(clip.id),
                            continuesFromPreviousDay: clip.startsAt < dayStart,
                            continuesIntoNextDay: clip.endsAt > nextDay,
                            timeLabel: timeLabel(for: clip),
                            secondsPerPoint: dayDuration / max(proxy.size.width, 1),
                            canReprocess: canReprocess,
                            onSelect: { onSelect(clip) },
                            onEdit: { onEdit(clip) },
                            onReprocess: { onReprocessClip(clip) },
                            onMove: { interval, duplicating in onMove(clip, interval, duplicating) },
                            onResize: { edge, interval in onResize(clip, edge, interval) }
                        )
                        .frame(width: clipWidth(clip, totalWidth: proxy.size.width), height: 44)
                        .offset(x: clipOffset(clip, totalWidth: proxy.size.width))
                    }
                    playheadMarker(totalWidth: proxy.size.width)
                }
            }
            .padding(.horizontal, 4)

            Rectangle()
                .fill(Color.accentColor.opacity(0.08))
                .frame(width: 68)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.65))
                        .frame(width: 2)
                }
                .allowsHitTesting(false)
                .accessibilityLabel("Next day")
        }
        .frame(height: 58)
        .contentShape(Rectangle())
        .contextMenu {
            Button(action: onEditPhotographer) {
                Label("Edit Photographer…", systemImage: "slider.horizontal.3")
            }
            Button(action: onReprocessPhotographer) {
                Label("Reprocess This Photographer’s Files…", systemImage: "arrow.clockwise")
            }
            .disabled(!canReprocess)
            Button(role: .destructive, action: onRequestRemove) {
                Label("Remove Track", systemImage: "minus.circle")
            }
            Divider()
            Button {
                if let playheadDate { onPasteAtPlayhead(playheadDate, photographer.id) }
            } label: {
                Label(contextMenuPasteTitle, systemImage: "doc.on.clipboard")
            }
            .disabled(!canPaste || playheadDate == nil)
        }
    }

    private var dayStart: Date { calendar.startOfDay(for: day) }

    private var processedFileHelp: String {
        let files = processedFileCount == 1 ? "1 unique file" : "\(processedFileCount) unique files"
        return "Metadata successfully applied to \(files) for this photographer in the current job."
    }

    private var nextDay: Date {
        calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
    }

    private var dayDuration: TimeInterval { nextDay.timeIntervalSince(dayStart) }

    private var contextMenuPasteTitle: String {
        guard let playheadDate else { return "Place Playhead to Paste" }
        return "Paste at \(playheadDate.formatted(date: .omitted, time: .shortened))"
    }

    @ViewBuilder
    private func workHoursBackground(totalWidth: CGFloat) -> some View {
        if let interval = photographer.workHours(on: day, calendar: calendar)?.interval(on: day, calendar: calendar) {
            Rectangle()
                .fill(color.opacity(0.12))
                .frame(width: intervalWidth(interval, totalWidth: totalWidth), height: 52)
                .offset(x: intervalOffset(interval, totalWidth: totalWidth))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var hourGrid: some View {
        HStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { _ in
                Rectangle()
                    .fill(.separator.opacity(0.45))
                    .frame(width: 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func creationPreview(totalWidth: CGFloat) -> some View {
        if let creationDrag {
            let interval = creationInterval(for: creationDrag, totalWidth: totalWidth)
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                }
                .overlay(alignment: .leading) {
                    Text(creationTimeLabel(interval))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(color)
                        .padding(.horizontal, 8)
                        .lineLimit(1)
                }
                .frame(width: intervalWidth(interval, totalWidth: totalWidth), height: 44)
                .offset(x: intervalOffset(interval, totalWidth: totalWidth))
                .allowsHitTesting(false)
        }
    }

    private func creationGesture(totalWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .updating($creationDrag) { value, state, _ in
                state = value
            }
            .onEnded { value in
                let interval = creationInterval(for: value, totalWidth: totalWidth)
                onCreate(photographer, interval.start, interval.end)
            }
    }

    private func playheadGesture(totalWidth: CGFloat) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .local)
            .onEnded { value in
                onPlacePlayhead(photographer.id, playheadDate(at: value.location.x, totalWidth: totalWidth))
            }
    }

    private func playheadDate(at location: CGFloat, totalWidth: CGFloat) -> Date {
        let fraction = min(max(location / max(totalWidth, 1), 0), 1)
        let unsnapped = dayStart.addingTimeInterval(Double(fraction) * dayDuration)
        let snapped = MetadataTimelineEditing.snapped(unsnapped, toMinutes: snapMinutes, calendar: calendar)
        let latest = nextDay.addingTimeInterval(-TimeInterval(max(snapMinutes, 1) * 60))
        return min(max(snapped, dayStart), latest)
    }

    private func creationInterval(
        for drag: DragGesture.Value,
        totalWidth: CGFloat
    ) -> DateInterval {
        let safeWidth = max(totalWidth, 1)
        return MetadataTimelineEditing.creationInterval(
            on: day,
            from: Double(drag.startLocation.x / safeWidth),
            to: Double(drag.location.x / safeWidth),
            snapMinutes: snapMinutes,
            calendar: calendar
        )
    }

    private func creationTimeLabel(_ interval: DateInterval) -> String {
        let start = interval.start.formatted(date: .omitted, time: .shortened)
        let end = interval.end.formatted(date: .omitted, time: .shortened)
        return "\(start)–\(end)"
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

    @ViewBuilder
    private func playheadMarker(totalWidth: CGFloat) -> some View {
        if showsPlayhead, let playheadDate {
            let offset = CGFloat(playheadDate.timeIntervalSince(dayStart) / dayDuration) * totalWidth
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: 52)
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .offset(y: -3)
            }
            .offset(x: offset - 1)
            .allowsHitTesting(false)
            .help("Paste starts at \(playheadDate.formatted(date: .omitted, time: .shortened))")
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
    let canReprocess: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onReprocess: () -> Void
    let onMove: (TimeInterval, Bool) -> Void
    let onResize: (MetadataClipResizeEdge, TimeInterval) -> Void

    @GestureState private var moveState = TimelineClipMoveState()
    @GestureState private var startTranslation: CGFloat = 0
    @GestureState private var endTranslation: CGFloat = 0

    var body: some View {
        ZStack {
            if isPreviewingDuplicate {
                clipBody(showsResizeHandles: false)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isSelected ? color : color.opacity(0.7), lineWidth: isSelected ? 2.5 : 1)
                    }
                    .allowsHitTesting(false)
            }

            clipBody(showsResizeHandles: true)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            isPreviewingDuplicate ? color.opacity(0.9) : (isSelected ? color : color.opacity(0.7)),
                            style: StrokeStyle(
                                lineWidth: isSelected ? 2.5 : 1,
                                dash: isPreviewingDuplicate ? [5, 3] : []
                            )
                        )
                }
                .overlay(alignment: .topTrailing) {
                    if isPreviewingDuplicate {
                        Image(systemName: "plus.circle.fill")
                            .font(.caption.weight(.semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, color)
                            .padding(4)
                    }
                }
                .offset(x: moveState.translation)
        }
        .foregroundStyle(color)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .gesture(interactionGesture)
        .contextMenu {
            Button(action: onEdit) {
                Label("Edit Clip…", systemImage: "slider.horizontal.3")
            }
            Button(action: onReprocess) {
                Label("Reprocess This Clip’s Files…", systemImage: "arrow.clockwise")
            }
            .disabled(!canReprocess)
        }
        .help("Click to select, double-click to edit, drag to move, Option-drag to duplicate, or drag an edge to resize.")
    }

    private var isPreviewingDuplicate: Bool {
        moveState.isDuplicating && abs(moveState.translation) >= 3
    }

    private func clipBody(showsResizeHandles: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.22))

            HStack(spacing: 3) {
                if continuesFromPreviousDay {
                    Image(systemName: "arrow.left")
                        .font(.caption2.weight(.bold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(timelineTitle).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(timeLabel).font(.caption2.monospacedDigit()).lineLimit(1)
                }
                Spacer(minLength: 0)
                if continuesIntoNextDay {
                    Image(systemName: "arrow.right")
                        .font(.caption2.weight(.bold))
                }
            }
            .padding(.horizontal, 9)

            if showsResizeHandles {
                HStack(spacing: 0) {
                    resizeHandle(edge: .start)
                    Spacer(minLength: 0)
                    resizeHandle(edge: .end)
                }
            }
        }
    }

    private var interactionGesture: some Gesture {
        selectionAndMoveGesture
            .simultaneously(with: TapGesture(count: 2).onEnded { onEdit() })
    }

    private var selectionAndMoveGesture: some Gesture {
        // A single tap used to be exclusive with the double-tap gesture, which
        // delayed selection until the system's double-click interval elapsed.
        // Treat a zero-distance drag as an immediate click while retaining the
        // same movement threshold for dragging clips.
        DragGesture(minimumDistance: 0)
            .updating($moveState) { value, state, _ in
                guard gestureDistance(value.translation) >= 3 else { return }
                state = TimelineClipMoveState(
                    translation: value.translation.width,
                    isDuplicating: NSEvent.modifierFlags.contains(.option)
                )
            }
            .onEnded { value in
                guard gestureDistance(value.translation) >= 3 else {
                    onSelect()
                    return
                }
                onMove(
                    value.translation.width * secondsPerPoint,
                    NSEvent.modifierFlags.contains(.option)
                )
            }
    }

    private func gestureDistance(_ translation: CGSize) -> CGFloat {
        hypot(translation.width, translation.height)
    }

    private var timelineTitle: String {
        let headline = clip.fields.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        return headline.isEmpty ? clip.name : headline
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

private struct TimelineClipMoveState {
    var translation: CGFloat = 0
    var isDuplicating = false
}

struct MetadataClipEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @State private var draft: MetadataScheduleClip
    @State private var keywordsText: String
    @State private var selectedPresetID: UUID?
    @State private var newPresetName: String
    @State private var presetPendingDeletion: MetadataPreset?
    @State private var validationMessage: String?

    let photographers: [PhotographerProfile]
    let onSave: (MetadataScheduleClip) -> Void

    init(
        clip: MetadataScheduleClip,
        photographers: [PhotographerProfile],
        onSave: @escaping (MetadataScheduleClip) -> Void
    ) {
        var editorClip = clip
        if editorClip.fields.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            editorClip.fields.headline = clip.name
        }
        _draft = State(initialValue: editorClip)
        _keywordsText = State(initialValue: editorClip.fields.keywords.joined(separator: ", "))
        _selectedPresetID = State(initialValue: nil)
        _newPresetName = State(initialValue: editorClip.fields.headline)
        self.photographers = photographers
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Programming") {
                    Picker("Photographer", selection: $draft.photographerID) {
                        ForEach(photographers) { Text($0.name).tag($0.id) }
                    }
                }

                Section("IPTC Metadata") {
                    TextField("Headline", text: $draft.fields.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description")
                        TextEditor(text: $draft.fields.description)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(minHeight: 90)
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(.separator, lineWidth: 1)
                            }
                    }
                    TextField("Keywords", text: $keywordsText, prompt: Text("politics, conference, Oslo"))
                }

                Section("Reusable Presets") {
                    Picker("Preset", selection: $selectedPresetID) {
                        Text("Choose a preset").tag(Optional<UUID>.none)
                        ForEach(store.metadataPresets) { preset in
                            Text(preset.name).tag(Optional(preset.id))
                        }
                    }

                    HStack {
                        Button("Load", action: loadSelectedPreset)
                            .disabled(selectedPreset == nil)
                        Button("Update", action: updateSelectedPreset)
                            .disabled(selectedPreset == nil)
                        Button("Delete", role: .destructive) {
                            presetPendingDeletion = selectedPreset
                        }
                        .disabled(selectedPreset == nil)
                    }

                    HStack {
                        TextField("New preset name", text: $newPresetName)
                        Button("Save as New", action: saveNewPreset)
                            .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Text("Loading copies only the metadata values. Clips remain standalone, so later preset changes do not alter existing programming.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        .frame(width: 620, height: 620)
        .confirmationDialog(
            "Delete reusable preset?",
            isPresented: Binding(
                get: { presetPendingDeletion != nil },
                set: { if !$0 { presetPendingDeletion = nil } }
            ),
            presenting: presetPendingDeletion
        ) { preset in
            Button("Delete \(preset.name)", role: .destructive) {
                if store.removeMetadataPreset(preset.id) {
                    selectedPresetID = nil
                }
                presetPendingDeletion = nil
            }
        } message: { preset in
            Text("Existing clips that used \(preset.name) keep their copied metadata values.")
        }
    }

    private func attemptSave() {
        normalizeKeywords()
        let trimmedHeadline = draft.fields.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHeadline.isEmpty else {
            validationMessage = "Give the metadata a headline."
            return
        }
        draft.fields.headline = trimmedHeadline
        draft.name = trimmedHeadline
        validationMessage = nil
        commitSave()
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

    private var selectedPreset: MetadataPreset? {
        guard let selectedPresetID else { return nil }
        return store.metadataPresets.first(where: { $0.id == selectedPresetID })
    }

    private func loadSelectedPreset() {
        guard let selectedPreset else { return }
        draft = draft.applying(selectedPreset)
        keywordsText = draft.fields.keywords.joined(separator: ", ")
    }

    private func saveNewPreset() {
        normalizeKeywords()
        let preset = MetadataPreset(name: newPresetName, fields: draft.fields)
        guard store.saveMetadataPreset(preset) else { return }
        selectedPresetID = preset.id
        newPresetName = draft.name
    }

    private func updateSelectedPreset() {
        guard var preset = selectedPreset else { return }
        normalizeKeywords()
        preset.fields = draft.fields
        _ = store.saveMetadataPreset(preset)
    }
}
