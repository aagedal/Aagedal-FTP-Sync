import AppKit
import CoreLocation
import MapKit
import SwiftUI

struct TimelineGroupDragPreview: Equatable {
    let anchorID: UUID
    let interval: TimeInterval
}

struct TimelineHourHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let day: Date
    private let calendar = Calendar.current

    private var photographerLabelWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 240 : 165
    }

    private var nextDayWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 104 : 68
    }

    private var headerHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 58 : 34
    }

    var body: some View {
        HStack(spacing: 0) {
            Text("Photographer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: photographerLabelWidth, alignment: .leading)
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
            .frame(width: nextDayWidth)
            .frame(maxHeight: .infinity)
            .background(Color.accentColor.opacity(0.1))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: 2)
            }
            .accessibilityLabel("Next day, \(nextDayLabel), starts at midnight")
        }
        .frame(height: headerHeight)
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let photographer: PhotographerProfile
    let clips: [MetadataScheduleClip]
    let allClips: [MetadataScheduleClip]
    let day: Date
    let color: Color
    let snapMinutes: Int
    let selectedClipIDs: Set<UUID>
    let groupDragPreview: TimelineGroupDragPreview?
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
    let onMove: (MetadataScheduleClip, TimeInterval, Int, Bool) -> Void
    let onPreviewMove: (MetadataScheduleClip, TimeInterval) -> Void
    let onEndMovePreview: () -> Void
    let onResize: (MetadataScheduleClip, MetadataClipResizeEdge, TimeInterval) -> Void
    let onResizeBoundary: (MetadataScheduleClip, MetadataScheduleClip, TimeInterval) -> Void
    let onReprocessClip: (MetadataScheduleClip) -> Void
    let onPlacePlayhead: (UUID, Date) -> Void
    let onPasteAtPlayhead: (Date, UUID) -> Void

    private let calendar = Calendar.current
    @GestureState private var creationDrag: DragGesture.Value?

    private var photographerColumnWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 252 : 177
    }

    private var nextDayWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 104 : 68
    }

    private var trackHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 96 : 58
    }

    private var canvasHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 90 : 52
    }

    private var clipHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 76 : 44
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .contentShape(Rectangle().inset(by: -6))
                    .onDrag {
                        onBeginReordering()
                        return NSItemProvider(object: photographer.id.uuidString as NSString)
                    }
                    .help("Drag to reorder this track")

                VStack(alignment: .leading, spacing: 3) {
                    Text(photographer.photographerName)
                        .fontWeight(.medium)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    HStack(spacing: 5) {
                        Text(photographer.formattedFilenamePrefixes)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
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
                .accessibilityLabel("Edit Photographer")
                .accessibilityHint("Opens this photographer’s profile and work hours")
                .help("Edit photographer and work hours")
            }
            .padding(.horizontal, 8)
            .frame(width: photographerColumnWidth, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelectPhotographer)
            .help(isSelected
                ? "Selected as a paste target. Shift-click another track to add or remove targets."
                : "Select this track. Shift-click to add it as another paste target.")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(creationGesture(totalWidth: proxy.size.width))
                        .simultaneousGesture(playheadGesture(totalWidth: proxy.size.width))
                        .help("Click to place the playhead, drag to create a metadata clip, or use the arrow keys to move by track and snap interval")
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
                            selectedClipCount: selectedClipIDs.count,
                            groupPreviewOffset: groupPreviewOffset(
                                for: clip,
                                secondsPerPoint: dayDuration / max(proxy.size.width, 1)
                            ),
                            continuesFromPreviousDay: clip.startsAt < dayStart,
                            continuesIntoNextDay: clip.endsAt > nextDay,
                            timeLabel: timeLabel(for: clip),
                            secondsPerPoint: dayDuration / max(proxy.size.width, 1),
                            trackHeight: trackHeight,
                            canReprocess: canReprocess,
                            onSelect: { onSelect(clip) },
                            onEdit: { onEdit(clip) },
                            onReprocess: { onReprocessClip(clip) },
                            onMove: { interval, trackOffset, duplicating in
                                onMove(clip, interval, trackOffset, duplicating)
                            },
                            onPreviewMove: { interval in onPreviewMove(clip, interval) },
                            onEndMovePreview: onEndMovePreview,
                            onResize: { edge, interval in onResize(clip, edge, interval) }
                        )
                        .frame(width: clipWidth(clip, totalWidth: proxy.size.width), height: clipHeight)
                        .offset(x: clipOffset(clip, totalWidth: proxy.size.width))
                    }
                    ForEach(linkedBoundaries) { boundary in
                        TimelineLinkedBoundaryHandle(
                            leading: boundary.leading,
                            trailing: boundary.trailing,
                            color: color,
                            secondsPerPoint: dayDuration / max(proxy.size.width, 1),
                            snapMinutes: snapMinutes,
                            onSelect: { onSelect(boundary.leading) },
                            onResize: { interval in
                                onResizeBoundary(boundary.leading, boundary.trailing, interval)
                            }
                        )
                        .offset(
                            x: boundaryOffset(boundary.leading.endsAt, totalWidth: proxy.size.width) - 15,
                            y: (trackHeight - 24) / 2
                        )
                    }
                    playheadMarker(totalWidth: proxy.size.width)
                }
            }
            .padding(.horizontal, 4)

            Rectangle()
                .fill(Color.accentColor.opacity(0.08))
                .frame(width: nextDayWidth)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.65))
                        .frame(width: 2)
                }
                .allowsHitTesting(false)
                .accessibilityLabel("Next day")
        }
        .frame(height: trackHeight)
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

    private var linkedBoundaries: [TimelineLinkedBoundary] {
        zip(clips, clips.dropFirst()).compactMap { leading, trailing in
            guard leading.photographerID == trailing.photographerID,
                  leading.endsAt == trailing.startsAt,
                  leading.endsAt > dayStart,
                  leading.endsAt < nextDay else {
                return nil
            }
            return TimelineLinkedBoundary(leading: leading, trailing: trailing)
        }
    }

    private var contextMenuPasteTitle: String {
        guard let playheadDate else { return "Place Playhead to Paste" }
        return "Paste at \(playheadDate.formatted(date: .omitted, time: .shortened))"
    }

    @ViewBuilder
    private func workHoursBackground(totalWidth: CGFloat) -> some View {
        if let interval = photographer.workHours(on: day, calendar: calendar)?.interval(on: day, calendar: calendar) {
            Rectangle()
                .fill(color.opacity(0.12))
                .frame(width: intervalWidth(interval, totalWidth: totalWidth), height: canvasHeight)
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
                .frame(width: intervalWidth(interval, totalWidth: totalWidth), height: clipHeight)
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
                .frame(width: intervalWidth(interval, totalWidth: totalWidth), height: canvasHeight)
                .offset(x: intervalOffset(interval, totalWidth: totalWidth))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func currentTimeMarker(totalWidth: CGFloat) -> some View {
        if calendar.isDateInToday(day) {
            Rectangle()
                .fill(.red.opacity(0.75))
                .frame(width: 1, height: canvasHeight)
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
                    .frame(width: 2, height: canvasHeight)
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

    private func boundaryOffset(_ boundary: Date, totalWidth: CGFloat) -> CGFloat {
        CGFloat(boundary.timeIntervalSince(dayStart) / dayDuration) * totalWidth
    }

    private func groupPreviewOffset(
        for clip: MetadataScheduleClip,
        secondsPerPoint: TimeInterval
    ) -> CGFloat {
        guard let groupDragPreview,
              groupDragPreview.anchorID != clip.id,
              selectedClipIDs.contains(clip.id) else {
            return 0
        }
        return CGFloat(groupDragPreview.interval / max(secondsPerPoint, 0.001))
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let clip: MetadataScheduleClip
    let color: Color
    let isSelected: Bool
    let selectedClipCount: Int
    let groupPreviewOffset: CGFloat
    let continuesFromPreviousDay: Bool
    let continuesIntoNextDay: Bool
    let timeLabel: String
    let secondsPerPoint: TimeInterval
    let trackHeight: CGFloat
    let canReprocess: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onReprocess: () -> Void
    let onMove: (TimeInterval, Int, Bool) -> Void
    let onPreviewMove: (TimeInterval) -> Void
    let onEndMovePreview: () -> Void
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
                .offset(
                    x: moveState.translation.width + groupPreviewOffset,
                    y: moveState.translation.height
                )
        }
        .foregroundStyle(color)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .gesture(interactionGesture)
        .onChange(of: moveState.translation) { oldValue, newValue in
            if oldValue != .zero, newValue == .zero {
                onEndMovePreview()
            }
        }
        .contextMenu {
            Button(action: onEdit) {
                Label("Edit Clip…", systemImage: "slider.horizontal.3")
            }
            Button(action: onReprocess) {
                Label("Reprocess This Clip’s Files…", systemImage: "arrow.clockwise")
            }
            .disabled(!canReprocess)
        }
        .help(interactionHelp)
    }

    private var isPreviewingDuplicate: Bool {
        !(isSelected && selectedClipCount > 1)
            && moveState.isDuplicating
            && gestureDistance(moveState.translation) >= 3
    }

    private var interactionHelp: String {
        if isSelected, selectedClipCount > 1 {
            return "Drag to move all \(selectedClipCount) selected clips while preserving their relative times and tracks."
        }
        return "Click to select, double-click to edit, drag horizontally in time or vertically to another track, Option-drag to duplicate, or drag an edge to resize."
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
                    HStack(spacing: 3) {
                        Text(timelineTitle).font(.caption.weight(.semibold)).lineLimit(1)
                        if clip.gpsPosition != nil {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.caption2.weight(.semibold))
                                .accessibilityLabel("Has GPS location")
                        }
                    }
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
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 3)
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
                    translation: value.translation,
                    isDuplicating: NSEvent.modifierFlags.contains(.option)
                )
            }
            .onChanged { value in
                guard isSelected,
                      selectedClipCount > 1,
                      gestureDistance(value.translation) >= 3 else { return }
                onPreviewMove(value.translation.width * secondsPerPoint)
            }
            .onEnded { value in
                onEndMovePreview()
                guard gestureDistance(value.translation) >= 3 else {
                    onSelect()
                    return
                }
                onMove(
                    value.translation.width * secondsPerPoint,
                    Int((value.translation.height / trackHeight).rounded()),
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
            .frame(width: 5, height: dynamicTypeSize.isAccessibilitySize ? 34 : 20)
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

private struct TimelineLinkedBoundary: Identifiable {
    let leading: MetadataScheduleClip
    let trailing: MetadataScheduleClip

    var id: String { "\(leading.id.uuidString)-\(trailing.id.uuidString)" }
}

private struct TimelineLinkedBoundaryHandle: View {
    let leading: MetadataScheduleClip
    let trailing: MetadataScheduleClip
    let color: Color
    let secondsPerPoint: TimeInterval
    let snapMinutes: Int
    let onSelect: () -> Void
    let onResize: (TimeInterval) -> Void

    @GestureState private var translation: CGFloat = 0

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(color.opacity(0.9), lineWidth: 1)
                    }
                Image(systemName: "arrow.left.and.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(color)
            }
            .frame(width: 30, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: translation)
        .highPriorityGesture(
            DragGesture(minimumDistance: 1)
                .updating($translation) { value, state, _ in
                    state = value.translation.width
                }
                .onEnded { value in
                    onSelect()
                    onResize(value.translation.width * secondsPerPoint)
                }
        )
        .onKeyPress(.leftArrow) {
            onSelect()
            onResize(-TimeInterval(max(snapMinutes, 1) * 60))
            return .handled
        }
        .onKeyPress(.rightArrow) {
            onSelect()
            onResize(TimeInterval(max(snapMinutes, 1) * 60))
            return .handled
        }
        .accessibilityLabel("Adjust boundary between \(leading.name) and \(trailing.name)")
        .help("Drag to resize both adjacent clips together, or use the left and right arrow keys.")
    }
}

private struct TimelineClipMoveState {
    var translation: CGSize = .zero
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

                Section("GPS Location") {
                    ClipLocationEditor(position: $draft.gpsPosition)
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
                        .labelStyle(AccessibleStatusLabelStyle(symbolColor: .orange))
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: attemptSave)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 680, height: 780)
        .accessibilityIdentifier("metadata-clip-editor")
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
        if draft.gpsPosition?.isValid == false {
            validationMessage = "Enter a latitude from −90 to 90 and a longitude from −180 to 180."
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

struct LocationPlaceNaming {
    static func coordinateLabel(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    static func preferredName(
        areasOfInterest: [String],
        name: String?,
        locality: String?,
        administrativeArea: String?,
        country: String?,
        fallback: String
    ) -> String {
        firstNonempty(areasOfInterest.map(Optional.some) + [name, locality, administrativeArea, country]) ?? fallback
    }

    static func displayName(
        name: String?,
        thoroughfare: String?,
        locality: String?,
        administrativeArea: String?,
        country: String?
    ) -> String? {
        let streetAndNumber = [name, thoroughfare]
            .compactMap(trimmed)
            .first
        return distinct([streetAndNumber, locality, administrativeArea, country]).joined(separator: ", ").nilIfEmpty
    }

    private static func firstNonempty(_ values: [String?]) -> String? {
        values.compactMap(trimmed).first
    }

    private static func distinct(_ values: [String?]) -> [String] {
        var seen = Set<String>()
        return values.compactMap(trimmed).filter { value in
            seen.insert(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)).inserted
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct ClipLocationSearchResult: Identifiable {
    let id: String
    let name: String
    let details: String?
    let coordinate: CLLocationCoordinate2D

    init?(mapItem: MKMapItem, index: Int) {
        let coordinate = mapItem.placemark.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let fallback = LocationPlaceNaming.coordinateLabel(coordinate)
        let placemark = mapItem.placemark
        let name = LocationPlaceNaming.preferredName(
            areasOfInterest: placemark.areasOfInterest ?? [],
            name: mapItem.name ?? placemark.name,
            locality: placemark.locality,
            administrativeArea: placemark.administrativeArea,
            country: placemark.country,
            fallback: fallback
        )
        self.id = "\(coordinate.latitude),\(coordinate.longitude),\(index)"
        self.name = name
        self.details = LocationPlaceNaming.displayName(
            name: placemark.name,
            thoroughfare: placemark.thoroughfare,
            locality: placemark.locality,
            administrativeArea: placemark.administrativeArea,
            country: placemark.country
        )
        self.coordinate = coordinate
    }
}

private enum ClipLocationLookupActivity: Equatable {
    case idle
    case searching
    case resolvingName
}

private struct ClipLocationEditor: View {
    @Binding var position: ScheduledGPSPosition?
    @State private var mapPosition: MapCameraPosition
    @State private var searchText: String
    @State private var searchResults: [ClipLocationSearchResult] = []
    @State private var lookupActivity = ClipLocationLookupActivity.idle
    @State private var lookupError: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var reverseGeocodingTask: Task<Void, Never>?

    private static let defaultCoordinate = CLLocationCoordinate2D(latitude: 59.9139, longitude: 10.7522)

    init(position: Binding<ScheduledGPSPosition?>) {
        _position = position
        let coordinate = position.wrappedValue.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        } ?? Self.defaultCoordinate
        _mapPosition = State(initialValue: .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        )))
        _searchText = State(initialValue: position.wrappedValue?.displayLabel ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Add a GPS position to files matched by this clip", isOn: hasPositionBinding)

            if position != nil {
                locationSearch

                MapReader { proxy in
                    Map(position: $mapPosition) {
                        if let coordinate {
                            Marker(position?.displayLabel ?? "Clip location", coordinate: coordinate)
                                .tint(.red)
                        }
                    }
                    .mapStyle(.standard(elevation: .flat))
                    .simultaneousGesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                guard let coordinate = proxy.convert(value.location, from: .local) else { return }
                                updateCoordinateAndResolveName(coordinate)
                            }
                    )
                    .overlay(alignment: .topLeading) {
                        if lookupActivity == .resolvingName {
                            Label("Finding place name…", systemImage: "mappin.and.ellipse")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                                .padding(8)
                        }
                    }
                }
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 1)
                }

                Text("Search for a place, click the map to place the marker, or enter exact coordinates below. Place names are filled in automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(position?.displayLabel ?? coordinate.map(LocationPlaceNaming.coordinateLabel) ?? "Selected location")
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        if let coordinate {
                            Text(LocationPlaceNaming.coordinateLabel(coordinate))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                TextField("Location name", text: labelBinding, prompt: Text("Automatic, or enter a custom name"))

                HStack {
                    TextField("Latitude", value: latitudeBinding, format: coordinateFormat)
                        .onSubmit { resolveCurrentCoordinate() }
                    TextField("Longitude", value: longitudeBinding, format: coordinateFormat)
                        .onSubmit { resolveCurrentCoordinate() }
                }

                HStack {
                    Toggle("Altitude", isOn: hasAltitudeBinding)
                        .fixedSize()
                    if position?.altitudeMeters != nil {
                        TextField("Meters", value: altitudeBinding, format: coordinateFormat)
                            .frame(maxWidth: 180)
                        Text("m")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onDisappear {
            searchTask?.cancel()
            reverseGeocodingTask?.cancel()
        }
    }

    @ViewBuilder
    private var locationSearch: some View {
        HStack(spacing: 8) {
            TextField("Search for an address or place", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(searchPlaces)
            Button(action: searchPlaces) {
                if lookupActivity == .searching {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Search", systemImage: "magnifyingglass")
                }
            }
            .disabled(lookupActivity == .searching)
        }

        if !searchResults.isEmpty {
            VStack(spacing: 2) {
                ForEach(searchResults) { result in
                    Button {
                        selectSearchResult(result)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "mappin")
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.name)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                if let details = result.details, details != result.name {
                                    Text(details)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }

        if let lookupError {
            Label(lookupError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .labelStyle(AccessibleStatusLabelStyle(symbolColor: .orange))
        }
    }

    private var coordinate: CLLocationCoordinate2D? {
        guard let position else { return nil }
        return CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude)
    }

    private var coordinateFormat: FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(0...6))
    }

    private var hasPositionBinding: Binding<Bool> {
        Binding(
            get: { position != nil },
            set: { enabled in
                if enabled, position == nil {
                    let newPosition = ScheduledGPSPosition(
                        latitude: Self.defaultCoordinate.latitude,
                        longitude: Self.defaultCoordinate.longitude,
                        label: LocationPlaceNaming.coordinateLabel(Self.defaultCoordinate)
                    )
                    position = newPosition
                    searchText = newPosition.label ?? ""
                    centerMap(on: Self.defaultCoordinate)
                    scheduleReverseGeocoding(for: Self.defaultCoordinate, delay: .milliseconds(150))
                } else if !enabled {
                    reverseGeocodingTask?.cancel()
                    searchTask?.cancel()
                    lookupActivity = .idle
                    lookupError = nil
                    searchResults = []
                    position = nil
                }
            }
        )
    }

    private var labelBinding: Binding<String> {
        Binding(
            get: { position?.label ?? "" },
            set: { value in
                reverseGeocodingTask?.cancel()
                if lookupActivity == .resolvingName { lookupActivity = .idle }
                mutatePosition { $0.label = value }
            }
        )
    }

    private var latitudeBinding: Binding<Double> {
        Binding(
            get: { position?.latitude ?? Self.defaultCoordinate.latitude },
            set: { value in
                mutatePosition { $0.latitude = value }
                scheduleCurrentCoordinateLookup()
            }
        )
    }

    private var longitudeBinding: Binding<Double> {
        Binding(
            get: { position?.longitude ?? Self.defaultCoordinate.longitude },
            set: { value in
                mutatePosition { $0.longitude = value }
                scheduleCurrentCoordinateLookup()
            }
        )
    }

    private var hasAltitudeBinding: Binding<Bool> {
        Binding(
            get: { position?.altitudeMeters != nil },
            set: { enabled in
                mutatePosition { $0.altitudeMeters = enabled ? ($0.altitudeMeters ?? 0) : nil }
            }
        )
    }

    private var altitudeBinding: Binding<Double> {
        Binding(
            get: { position?.altitudeMeters ?? 0 },
            set: { value in mutatePosition { $0.altitudeMeters = value } }
        )
    }

    private func updateCoordinateAndResolveName(_ coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        mutatePosition {
            $0.latitude = coordinate.latitude
            $0.longitude = coordinate.longitude
            $0.label = LocationPlaceNaming.coordinateLabel(coordinate)
        }
        searchText = LocationPlaceNaming.coordinateLabel(coordinate)
        searchResults = []
        lookupError = nil
        scheduleReverseGeocoding(for: coordinate, delay: .zero)
    }

    private func searchPlaces() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            lookupError = "Enter at least two characters."
            searchResults = []
            return
        }

        searchTask?.cancel()
        reverseGeocodingTask?.cancel()
        lookupActivity = .searching
        lookupError = nil
        searchResults = []
        let searchRegion = coordinate.map {
            MKCoordinateRegion(
                center: $0,
                span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2)
            )
        }
        searchTask = Task { @MainActor in
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.resultTypes = [.address, .pointOfInterest]
            if let searchRegion { request.region = searchRegion }

            do {
                let response = try await MKLocalSearch(request: request).start()
                try Task.checkCancellation()
                let results = response.mapItems.prefix(5).enumerated().compactMap {
                    ClipLocationSearchResult(mapItem: $0.element, index: $0.offset)
                }
                searchResults = results
                lookupActivity = .idle
                if results.isEmpty { lookupError = "No matching places found." }
            } catch is CancellationError {
                if lookupActivity == .searching { lookupActivity = .idle }
            } catch {
                lookupActivity = .idle
                lookupError = "Location search is unavailable. Check your connection and try again."
            }
        }
    }

    private func selectSearchResult(_ result: ClipLocationSearchResult) {
        reverseGeocodingTask?.cancel()
        searchTask?.cancel()
        lookupActivity = .idle
        lookupError = nil
        searchResults = []
        searchText = result.details ?? result.name
        mutatePosition {
            $0.latitude = result.coordinate.latitude
            $0.longitude = result.coordinate.longitude
            $0.label = result.name
        }
        centerMap(on: result.coordinate)
    }

    private func resolveCurrentCoordinate() {
        guard let coordinate, CLLocationCoordinate2DIsValid(coordinate) else { return }
        centerMap(on: coordinate)
        scheduleReverseGeocoding(for: coordinate, delay: .zero)
    }

    private func scheduleCurrentCoordinateLookup() {
        guard let coordinate, CLLocationCoordinate2DIsValid(coordinate) else { return }
        mutatePosition { $0.label = LocationPlaceNaming.coordinateLabel(coordinate) }
        searchText = LocationPlaceNaming.coordinateLabel(coordinate)
        scheduleReverseGeocoding(for: coordinate, delay: .milliseconds(650))
    }

    private func scheduleReverseGeocoding(
        for coordinate: CLLocationCoordinate2D,
        delay: Duration
    ) {
        reverseGeocodingTask?.cancel()
        searchTask?.cancel()
        lookupError = nil
        reverseGeocodingTask = Task { @MainActor in
            do {
                if delay != .zero { try await Task.sleep(for: delay) }
                try Task.checkCancellation()
                guard currentPositionMatches(coordinate) else { return }
                lookupActivity = .resolvingName
                let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                let placemarks = try await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: .current)
                try Task.checkCancellation()
                guard currentPositionMatches(coordinate) else { return }
                let fallback = LocationPlaceNaming.coordinateLabel(coordinate)
                guard let placemark = placemarks.first else {
                    lookupActivity = .idle
                    lookupError = "The point was saved, but its place name could not be found."
                    return
                }
                let name = LocationPlaceNaming.preferredName(
                    areasOfInterest: placemark.areasOfInterest ?? [],
                    name: placemark.name,
                    locality: placemark.locality,
                    administrativeArea: placemark.administrativeArea,
                    country: placemark.country,
                    fallback: fallback
                )
                let details = LocationPlaceNaming.displayName(
                    name: placemark.name,
                    thoroughfare: placemark.thoroughfare,
                    locality: placemark.locality,
                    administrativeArea: placemark.administrativeArea,
                    country: placemark.country
                )
                mutatePosition { $0.label = name }
                searchText = details ?? name
                lookupActivity = .idle
            } catch is CancellationError {
                if lookupActivity == .resolvingName { lookupActivity = .idle }
            } catch {
                guard currentPositionMatches(coordinate) else { return }
                lookupActivity = .idle
                lookupError = "The point was saved, but its place name could not be found."
            }
        }
    }

    private func currentPositionMatches(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard let position else { return false }
        return abs(position.latitude - coordinate.latitude) < 0.000_000_1
            && abs(position.longitude - coordinate.longitude) < 0.000_000_1
    }

    private func centerMap(on coordinate: CLLocationCoordinate2D) {
        mapPosition = .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        ))
    }

    private func mutatePosition(_ mutation: (inout ScheduledGPSPosition) -> Void) {
        guard var updated = position else { return }
        mutation(&updated)
        position = updated
    }
}
