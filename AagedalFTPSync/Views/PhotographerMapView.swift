import MapKit
import SwiftUI

struct PhotographerMapTimelineRow: Identifiable, Equatable, Sendable {
    let photographer: PhotographerProfile
    let clips: [MetadataScheduleClip]

    var id: UUID { photographer.id }
}

enum PhotographerMapTimeline {
    static func rows(
        for automation: MetadataAutomation,
        on day: Date,
        calendar: Calendar = .current
    ) -> [PhotographerMapTimelineRow] {
        let photographersByID = Dictionary(
            uniqueKeysWithValues: automation.photographers.map { ($0.id, $0) }
        )
        let clips = MetadataTimelineEditing.clips(
            from: automation.clips,
            restrictedTo: day,
            calendar: calendar
        )
        let clipsByPhotographer = Dictionary(grouping: clips, by: \.photographerID)

        return automation.photographerIDs(on: day, calendar: calendar).compactMap { photographerID in
            guard let photographer = photographersByID[photographerID] else { return nil }
            return PhotographerMapTimelineRow(
                photographer: photographer,
                clips: clipsByPhotographer[photographerID, default: []]
            )
        }
    }
}

struct PhotographerMapView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("photographerMapRenderingMode") private var renderingMode: PhotographerMapRenderingMode = .standard
    @AppStorage("photographerMapShows3DBuildings") private var shows3DBuildings = false
    @State private var selectedDate = Date()
    @State private var secondsIntoDay: Double = 12 * 60 * 60
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedPhotographerID: UUID?
    @State private var draggedClipID: UUID?
    @State private var draggedTranslation: CGSize = .zero
    @State private var currentMapCamera: MapCamera?

    private let calendar = Calendar.current
    private let mapCoordinateSpaceName = "photographer-map"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if selectedJob == nil {
                ContentUnavailableView(
                    "No sync job selected",
                    systemImage: "map",
                    description: Text("Choose a sync job to view its scheduled photographer locations.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if automation.photographers.isEmpty {
                ContentUnavailableView(
                    "No photographers programmed",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Add photographer tracks and metadata clips before opening the map.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                map
                Divider()
                timelineControls
            }
        }
        .frame(minWidth: 900, minHeight: 650)
        .onAppear(perform: applyRequestedDate)
        .onChange(of: store.metadataMapRequestedDate) { _, _ in applyRequestedDate() }
        .onChange(of: selectedDate) { _, newDate in
            selectedDate = calendar.startOfDay(for: newDate)
            selectedPhotographerID = nil
            cameraPosition = .automatic
        }
        .onChange(of: selectedInstant) { _, _ in
            if let selectedPhotographerID,
               !positions.contains(where: { $0.photographer.id == selectedPhotographerID }) {
                self.selectedPhotographerID = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Label("Photographer Map", systemImage: "map.fill")
                .font(.title2.weight(.semibold))

            Picker("Sync Job", selection: $store.selectedJobID) {
                Text("Choose a job").tag(Optional<UUID>.none)
                ForEach(store.jobs) { job in
                    Text(job.name).tag(Optional(job.id))
                }
            }
            .frame(minWidth: 220, maxWidth: 320)

            Spacer()

            Menu {
                Picker("Map Style", selection: $renderingMode) {
                    ForEach(PhotographerMapRenderingMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }

                Divider()

                Toggle("3D Buildings", isOn: $shows3DBuildings)
            } label: {
                Label(renderingMode.title, systemImage: renderingMode.systemImage)
            }
            .help("Choose the map appearance and whether buildings are shown in 3D")

            Button {
                moveDay(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("Previous Day")

            DatePicker(
                "Date",
                selection: $selectedDate,
                displayedComponents: .date
            )
            .labelsHidden()

            Button {
                moveDay(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .help("Next Day")

            Button("Today") {
                selectedDate = calendar.startOfDay(for: Date())
                secondsIntoDay = seconds(on: Date())
            }

            Button {
                cameraPosition = .automatic
            } label: {
                Label("Show All", systemImage: "scope")
            }
            .disabled(positions.isEmpty)
            .help("Fit all active photographers on the map")
        }
        .padding(14)
    }

    private var map: some View {
        MapReader { proxy in
            Map(position: $cameraPosition, selection: $selectedPhotographerID) {
                ForEach(positions) { item in
                    Annotation(
                        "",
                        coordinate: coordinate(for: item),
                        anchor: .bottom
                    ) {
                        PhotographerMapMarker(
                            item: item,
                            color: color(for: item.photographer),
                            isSelected: selectedPhotographerID == item.photographer.id
                        )
                        .offset(markerOffset(for: item))
                        .tag(item.photographer.id)
                        .accessibilityLabel(markerAccessibilityLabel(item))
                        .gesture(markerGesture(for: item, proxy: proxy))
                    }
                }
            }
            .coordinateSpace(name: mapCoordinateSpaceName)
            .mapStyle(mapStyle)
            .onMapCameraChange(frequency: .continuous) { context in
                currentMapCamera = context.camera
            }
            .mapControls {
                MapCompass()
                MapScaleView()
                MapPitchToggle()
            }
            .overlay(alignment: .topLeading) {
                mapSummary
                    .padding(12)
            }
        }
    }

    private var mapStyle: MapStyle {
        let elevation: MapStyle.Elevation = shows3DBuildings ? .realistic : .flat

        switch renderingMode {
        case .standard:
            return .standard(elevation: elevation)
        case .standardWithoutPointsOfInterest:
            return .standard(
                elevation: elevation,
                pointsOfInterest: .excludingAll
            )
        case .satellite:
            return .hybrid(elevation: elevation)
        case .satelliteWithoutLabels:
            return .imagery(elevation: elevation)
        }
    }

    private var mapSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(selectedInstant.formatted(date: .abbreviated, time: .shortened))
                .font(.headline.monospacedDigit())

            if positions.isEmpty {
                Text("No photographer has a location at this time.")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(positions.count) of \(automation.photographers.count) photographers shown")
                    .foregroundStyle(.secondary)
                if let selectedPosition {
                    Divider()
                    Text(selectedPosition.photographer.photographerName)
                        .fontWeight(.semibold)
                    Text(selectedPosition.clip.name)
                    Text(locationDescription(selectedPosition.position))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .frame(maxWidth: 310, alignment: .leading)
    }

    private var timelineControls: some View {
        VStack(spacing: 9) {
            HStack(spacing: 12) {
                Button(action: previousChange) {
                    Label("Previous Change", systemImage: "backward.end.fill")
                }
                .disabled(previousChangePoint == nil)

                Text(selectedInstant.formatted(date: .omitted, time: .standard))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 105)

                Button(action: nextChange) {
                    Label("Next Change", systemImage: "forward.end.fill")
                }
                .disabled(nextChangePoint == nil)

                Spacer()

                Text(changePointSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            MapMiniTimeline(
                seconds: $secondsIntoDay,
                dayStart: dayStart,
                dayDuration: dayDuration,
                rows: mapTimelineRows,
                selectedPhotographerID: $selectedPhotographerID,
                color: color(for:)
            )
        }
        .padding(14)
        .background(.bar)
    }

    private var selectedJob: SyncJob? {
        guard let selectedJobID = store.selectedJobID else { return nil }
        return store.jobs.first { $0.id == selectedJobID }
    }

    private var automation: MetadataAutomation {
        selectedJob?.metadataAutomation ?? MetadataAutomation()
    }

    private var dayStart: Date {
        calendar.startOfDay(for: selectedDate)
    }

    private var nextDay: Date {
        calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)
    }

    private var dayDuration: Double {
        nextDay.timeIntervalSince(dayStart)
    }

    private var selectedInstant: Date {
        dayStart.addingTimeInterval(min(max(secondsIntoDay, 0), max(dayDuration - 0.001, 0)))
    }

    private var positions: [ScheduledPhotographerPosition] {
        automation.positionedPhotographers(at: selectedInstant)
    }

    private var selectedPosition: ScheduledPhotographerPosition? {
        guard let selectedPhotographerID else { return nil }
        return positions.first { $0.photographer.id == selectedPhotographerID }
    }

    private var changePoints: [Date] {
        automation.mapChangePoints(on: selectedDate, calendar: calendar)
    }

    private var mapTimelineRows: [PhotographerMapTimelineRow] {
        PhotographerMapTimeline.rows(
            for: automation,
            on: selectedDate,
            calendar: calendar
        )
    }

    private var previousChangePoint: Date? {
        changePoints.last { $0 < selectedInstant.addingTimeInterval(-0.5) }
    }

    private var nextChangePoint: Date? {
        changePoints.first { $0 > selectedInstant.addingTimeInterval(0.5) }
    }

    private var changePointSummary: String {
        let count = changePoints.count
        return count == 1 ? "1 location change this day" : "\(count) location changes this day"
    }

    private func previousChange() {
        guard let previousChangePoint else { return }
        secondsIntoDay = previousChangePoint.timeIntervalSince(dayStart)
    }

    private func nextChange() {
        guard let nextChangePoint else { return }
        secondsIntoDay = nextChangePoint.timeIntervalSince(dayStart)
    }

    private func moveDay(by value: Int) {
        selectedDate = calendar.date(byAdding: .day, value: value, to: selectedDate) ?? selectedDate
    }

    private func applyRequestedDate() {
        let requested = store.metadataMapRequestedDate ?? Date()
        selectedDate = calendar.startOfDay(for: requested)
        secondsIntoDay = seconds(on: requested)
        cameraPosition = .automatic
    }

    private func seconds(on date: Date) -> Double {
        date.timeIntervalSince(calendar.startOfDay(for: date))
    }

    private func color(for photographer: PhotographerProfile) -> Color {
        let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .teal, .indigo]
        let index = automation.photographers.firstIndex { $0.id == photographer.id } ?? 0
        return colors[index % colors.count]
    }

    private func coordinate(for item: ScheduledPhotographerPosition) -> CLLocationCoordinate2D {
        return CLLocationCoordinate2D(
            latitude: item.position.latitude,
            longitude: item.position.longitude
        )
    }

    private func markerOffset(for item: ScheduledPhotographerPosition) -> CGSize {
        draggedClipID == item.clip.id ? draggedTranslation : .zero
    }

    private func markerGesture(
        for item: ScheduledPhotographerPosition,
        proxy: MapProxy
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(mapCoordinateSpaceName))
            .onChanged { value in
                guard gestureDistance(value.translation) >= 3 else { return }
                if draggedClipID == nil, let currentMapCamera {
                    // Automatic framing follows changing annotations. Freeze the
                    // rendered camera before the eventual coordinate update.
                    cameraPosition = .camera(currentMapCamera)
                }
                selectedPhotographerID = item.photographer.id
                draggedClipID = item.clip.id
                draggedTranslation = value.translation
            }
            .onEnded { value in
                if gestureDistance(value.translation) < 3 {
                    selectedPhotographerID = item.photographer.id
                } else if let coordinate = movedCoordinate(
                    for: item,
                    translation: value.translation,
                    proxy: proxy
                ) {
                    saveMovedCoordinate(coordinate, for: item)
                }
                draggedClipID = nil
                draggedTranslation = .zero
            }
            .simultaneously(with: TapGesture(count: 2).onEnded {
                openMetadataProgramming(for: item)
            })
    }

    private func movedCoordinate(
        for item: ScheduledPhotographerPosition,
        translation: CGSize,
        proxy: MapProxy
    ) -> CLLocationCoordinate2D? {
        let originalCoordinate = CLLocationCoordinate2D(
            latitude: item.position.latitude,
            longitude: item.position.longitude
        )
        guard let originalPoint = proxy.convert(
            originalCoordinate,
            to: .named(mapCoordinateSpaceName)
        ) else { return nil }
        let movedPoint = CGPoint(
            x: originalPoint.x + translation.width,
            y: originalPoint.y + translation.height
        )
        return proxy.convert(movedPoint, from: .named(mapCoordinateSpaceName))
    }

    private func saveMovedCoordinate(
        _ coordinate: CLLocationCoordinate2D,
        for item: ScheduledPhotographerPosition
    ) {
        guard let selectedJob,
              coordinate.latitude.isFinite,
              coordinate.longitude.isFinite else { return }
        var position = item.position
        position.latitude = coordinate.latitude
        position.longitude = coordinate.longitude
        _ = store.updateMetadataClipPosition(
            position,
            clipID: item.clip.id,
            jobID: selectedJob.id
        )
    }

    private func openMetadataProgramming(for item: ScheduledPhotographerPosition) {
        guard let selectedJob else { return }
        store.requestMetadataProgramming(
            for: item.clip.id,
            jobID: selectedJob.id,
            at: selectedInstant
        )
        RegularWindowController.shared.prepareForOpening(windowID: "metadata-programming")
        openWindow(id: "metadata-programming")
    }

    private func gestureDistance(_ translation: CGSize) -> CGFloat {
        hypot(translation.width, translation.height)
    }

    private func markerAccessibilityLabel(_ item: ScheduledPhotographerPosition) -> String {
        "\(item.photographer.photographerName), \(item.clip.name), \(locationDescription(item.position))"
    }

    private func locationDescription(_ position: ScheduledGPSPosition) -> String {
        let coordinates = String(
            format: "%.5f, %.5f",
            locale: Locale(identifier: "en_US_POSIX"),
            position.latitude,
            position.longitude
        )
        if let label = position.displayLabel {
            return "\(label) · \(coordinates)"
        }
        return coordinates
    }
}

private enum PhotographerMapRenderingMode: String, CaseIterable, Identifiable {
    case standard
    case standardWithoutPointsOfInterest
    case satellite
    case satelliteWithoutLabels

    var id: Self { self }

    var title: String {
        switch self {
        case .standard:
            return "Standard"
        case .standardWithoutPointsOfInterest:
            return "Standard Without Points of Interest"
        case .satellite:
            return "Satellite"
        case .satelliteWithoutLabels:
            return "Satellite Without Labels"
        }
    }

    var systemImage: String {
        switch self {
        case .standard:
            return "map"
        case .standardWithoutPointsOfInterest:
            return "map"
        case .satellite:
            return "globe.americas.fill"
        case .satelliteWithoutLabels:
            return "photo"
        }
    }
}

private struct PhotographerMapMarker: View {
    let item: ScheduledPhotographerPosition
    let color: Color
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(item.photographer.photographerName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .foregroundStyle(.primary)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule().stroke(color, lineWidth: isSelected ? 3 : 1)
                }

            Image(systemName: "mappin.circle.fill")
                .font(.system(size: isSelected ? 31 : 27))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, color)
                .shadow(radius: 2, y: 1)
        }
        .help("Click to select, drag to update this clip’s GPS location, or double-click to edit the metadata clip.")
    }
}

private struct MapMiniTimeline: View {
    @Binding var seconds: Double
    let dayStart: Date
    let dayDuration: Double
    let rows: [PhotographerMapTimelineRow]
    @Binding var selectedPhotographerID: UUID?
    let color: (PhotographerProfile) -> Color

    private let labelWidth: CGFloat = 118
    private let rowHeight: CGFloat = 20

    var body: some View {
        VStack(spacing: 5) {
            if rows.isEmpty {
                Text("No photographer tracks on this day")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 3) {
                        ForEach(rows) { row in
                            timelineRow(row)
                        }
                    }
                }
                .scrollIndicators(rows.count > 4 ? .visible : .hidden)
                .frame(height: min(CGFloat(rows.count) * (rowHeight + 3), 92))
            }

            HStack(spacing: 8) {
                Color.clear.frame(width: labelWidth)
                HStack {
                    Text("00:00")
                    Spacer()
                    Text("06:00")
                    Spacer()
                    Text("12:00")
                    Spacer()
                    Text("18:00")
                    Spacer()
                    Text("24:00")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private func timelineRow(_ row: PhotographerMapTimelineRow) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color(row.photographer))
                    .frame(width: 7, height: 7)
                Text(row.photographer.photographerName)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.caption)
            .frame(width: labelWidth, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))

                    ForEach(row.clips) { clip in
                        clipBar(
                            clip,
                            photographer: row.photographer,
                            totalWidth: proxy.size.width
                        )
                    }

                    Rectangle()
                        .fill(Color.primary.opacity(0.9))
                        .frame(width: 2)
                        .offset(x: playheadOffset(totalWidth: proxy.size.width) - 1)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(scrubGesture(
                    totalWidth: proxy.size.width,
                    photographerID: row.photographer.id
                ))
            }
            .frame(height: 16)
        }
        .frame(height: rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time on \(row.photographer.photographerName)’s schedule")
        .accessibilityValue(accessibilityTime)
        .accessibilityHint("Adjust to change the time shown on the map")
        .accessibilityAdjustableAction { direction in
            let step: Double = 5 * 60
            switch direction {
            case .increment:
                seconds = min(seconds + step, maximumSeconds)
            case .decrement:
                seconds = max(seconds - step, 0)
            @unknown default:
                break
            }
            selectedPhotographerID = row.photographer.id
        }
    }

    private func clipBar(
        _ clip: MetadataScheduleClip,
        photographer: PhotographerProfile,
        totalWidth: CGFloat
    ) -> some View {
        let start = max(0, clip.startsAt.timeIntervalSince(dayStart))
        let end = min(dayDuration, clip.endsAt.timeIntervalSince(dayStart))
        let x = CGFloat(start / max(dayDuration, 1)) * totalWidth
        let width = max(CGFloat((end - start) / max(dayDuration, 1)) * totalWidth, 2)
        let hasLocation = clip.gpsPosition?.isValid == true
        let isActive = clip.contains(dayStart.addingTimeInterval(seconds))
        let clipColor = color(photographer)

        return RoundedRectangle(cornerRadius: 3)
            .fill(clipColor.opacity(hasLocation ? 0.78 : 0.2))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(
                        isActive ? Color.primary : clipColor.opacity(hasLocation ? 0.9 : 0.5),
                        style: StrokeStyle(
                            lineWidth: isActive ? 2 : 1,
                            dash: hasLocation ? [] : [3, 2]
                        )
                    )
            }
            .frame(width: width, height: 14)
            .offset(x: x)
            .help("\(clip.name) · \(hasLocation ? "location set" : "no location")")
            .allowsHitTesting(false)
    }

    private func scrubGesture(totalWidth: CGFloat, photographerID: UUID) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let fraction = min(max(value.location.x / max(totalWidth, 1), 0), 1)
                seconds = min(Double(fraction) * dayDuration, maximumSeconds)
                selectedPhotographerID = photographerID
            }
    }

    private func playheadOffset(totalWidth: CGFloat) -> CGFloat {
        CGFloat(min(max(seconds / max(dayDuration, 1), 0), 1)) * totalWidth
    }

    private var maximumSeconds: Double {
        max(dayDuration - 0.001, 0)
    }

    private var accessibilityTime: String {
        dayStart.addingTimeInterval(min(max(seconds, 0), maximumSeconds))
            .formatted(date: .omitted, time: .shortened)
    }
}
