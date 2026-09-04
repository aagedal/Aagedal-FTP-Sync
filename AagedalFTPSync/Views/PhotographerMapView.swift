import MapKit
import SwiftUI
import WeatherKit

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

    static func selectionInstant(
        in clip: MetadataScheduleClip,
        at fraction: Double
    ) -> Date {
        let duration = max(clip.endsAt.timeIntervalSince(clip.startsAt), 0)
        let clampedFraction = min(max(fraction, 0), 1)
        let offset = min(duration * clampedFraction, max(duration - 0.001, 0))
        return clip.startsAt.addingTimeInterval(offset)
    }

    static func clipFrame(
        for clip: MetadataScheduleClip,
        dayStart: Date,
        dayDuration: Double,
        totalWidth: CGFloat
    ) -> CGRect {
        let start = max(0, min(dayDuration, clip.startsAt.timeIntervalSince(dayStart)))
        let end = max(start, min(dayDuration, clip.endsAt.timeIntervalSince(dayStart)))
        let safeDuration = max(dayDuration, 1)
        let x = CGFloat(start / safeDuration) * totalWidth
        let width = max(CGFloat((end - start) / safeDuration) * totalWidth, 2)
        return CGRect(x: x, y: 0, width: width, height: 0)
    }
}

enum PhotographerMapCameraFraming {
    static func mapRect(for positions: [ScheduledGPSPosition]) -> MKMapRect? {
        let mapPoints = positions.compactMap { position -> MKMapPoint? in
            guard position.isValid else { return nil }
            return MKMapPoint(CLLocationCoordinate2D(
                latitude: position.latitude,
                longitude: position.longitude
            ))
        }
        guard let firstPoint = mapPoints.first else { return nil }

        var mapRect = MKMapRect(
            x: firstPoint.x,
            y: firstPoint.y,
            width: 1,
            height: 1
        )
        for point in mapPoints.dropFirst() {
            mapRect = mapRect.union(MKMapRect(
                x: point.x,
                y: point.y,
                width: 1,
                height: 1
            ))
        }

        let centerLatitude = MKMapPoint(
            x: mapRect.midX,
            y: mapRect.midY
        ).coordinate.latitude
        let minimumSpan = MKMapPointsPerMeterAtLatitude(centerLatitude) * 2_500
        let paddedWidth = max(mapRect.width * 1.3, minimumSpan)
        let paddedHeight = max(mapRect.height * 1.3, minimumSpan)
        return MKMapRect(
            x: mapRect.midX - (paddedWidth / 2),
            y: mapRect.midY - (paddedHeight / 2),
            width: paddedWidth,
            height: paddedHeight
        )
    }
}

private struct PhotographerMapWeatherTarget: Hashable {
    let latitude: Double
    let longitude: Double

    init?(_ coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}

private struct PhotographerMapWeatherSnapshot {
    let target: PhotographerMapWeatherTarget
    let current: CurrentWeather

    func isFresh(
        for requestedTarget: PhotographerMapWeatherTarget,
        at date: Date = Date()
    ) -> Bool {
        current.metadata.expirationDate > date
            && target.location.distance(from: requestedTarget.location) < 3_000
    }
}

struct PhotographerMapLabelAnchor: Equatable {
    let id: UUID
    let point: CGPoint
    let labelWidth: CGFloat
    let isSelected: Bool
}

enum PhotographerMapLabelLayout {
    static let labelHeight: CGFloat = 23
    static let pinHeight: CGFloat = 31
    private static let labelGap: CGFloat = 3
    private static let mapInset: CGFloat = 7
    private static let verticalStep: CGFloat = labelHeight + 7

    static func offsets(
        for anchors: [PhotographerMapLabelAnchor],
        in bounds: CGRect
    ) -> [UUID: CGSize] {
        guard bounds.width > 0, bounds.height > 0 else { return [:] }
        let safeBounds = bounds.insetBy(dx: mapInset, dy: mapInset)
        let orderedAnchors = anchors.enumerated().sorted { first, second in
            if first.element.isSelected != second.element.isSelected {
                return first.element.isSelected
            }
            if first.element.point.y != second.element.point.y {
                return first.element.point.y < second.element.point.y
            }
            if first.element.point.x != second.element.point.x {
                return first.element.point.x < second.element.point.x
            }
            return first.offset < second.offset
        }.map(\.element)

        var occupiedLabels: [CGRect] = []
        var result: [UUID: CGSize] = [:]
        for anchor in orderedAnchors {
            let candidates = candidateOffsets(for: anchor, in: safeBounds)
            let otherPins = anchors
                .filter { $0.id != anchor.id }
                .map { pinFrame(at: $0.point) }
            let chosen = candidates.first { candidate in
                let frame = labelFrame(for: anchor, offset: candidate)
                return !occupiedLabels.contains(where: { $0.intersects(frame) })
                    && !otherPins.contains(where: { $0.intersects(frame) })
            } ?? candidates.min { first, second in
                collisionScore(
                    labelFrame(for: anchor, offset: first),
                    offset: first,
                    occupiedLabels: occupiedLabels,
                    otherPins: otherPins
                ) < collisionScore(
                    labelFrame(for: anchor, offset: second),
                    offset: second,
                    occupiedLabels: occupiedLabels,
                    otherPins: otherPins
                )
            } ?? .zero
            result[anchor.id] = chosen
            occupiedLabels.append(labelFrame(for: anchor, offset: chosen))
        }
        return result
    }

    static func labelFrame(
        for anchor: PhotographerMapLabelAnchor,
        offset: CGSize
    ) -> CGRect {
        CGRect(
            x: anchor.point.x - (anchor.labelWidth / 2) + offset.width,
            y: anchor.point.y - pinHeight - labelGap - labelHeight + offset.height,
            width: anchor.labelWidth,
            height: labelHeight
        )
    }

    private static func candidateOffsets(
        for anchor: PhotographerMapLabelAnchor,
        in bounds: CGRect
    ) -> [CGSize] {
        let horizontalStep = max(anchor.labelWidth * 0.62 + 28, 80)
        let belowPin = pinHeight + (2 * labelGap) + (2 * labelHeight)
        let rawCandidates: [CGSize] = [
            .zero,
            CGSize(width: 0, height: -verticalStep),
            CGSize(width: 0, height: -2 * verticalStep),
            CGSize(width: -horizontalStep, height: 0),
            CGSize(width: horizontalStep, height: 0),
            CGSize(width: -horizontalStep, height: -verticalStep),
            CGSize(width: horizontalStep, height: -verticalStep),
            CGSize(width: -horizontalStep, height: -2 * verticalStep),
            CGSize(width: horizontalStep, height: -2 * verticalStep),
            CGSize(width: 0, height: -3 * verticalStep),
            CGSize(width: 0, height: belowPin),
            CGSize(width: -horizontalStep, height: belowPin),
            CGSize(width: horizontalStep, height: belowPin),
        ]
        var candidates: [CGSize] = []
        for rawCandidate in rawCandidates {
            let constrained = constrainedOffset(rawCandidate, for: anchor, in: bounds)
            guard !candidates.contains(where: {
                abs($0.width - constrained.width) < 0.5
                    && abs($0.height - constrained.height) < 0.5
            }) else { continue }
            candidates.append(constrained)
        }
        return candidates
    }

    private static func constrainedOffset(
        _ offset: CGSize,
        for anchor: PhotographerMapLabelAnchor,
        in bounds: CGRect
    ) -> CGSize {
        var constrained = offset
        let frame = labelFrame(for: anchor, offset: offset)
        if frame.minX < bounds.minX {
            constrained.width += bounds.minX - frame.minX
        } else if frame.maxX > bounds.maxX {
            constrained.width -= frame.maxX - bounds.maxX
        }
        if frame.minY < bounds.minY {
            constrained.height += bounds.minY - frame.minY
        } else if frame.maxY > bounds.maxY {
            constrained.height -= frame.maxY - bounds.maxY
        }
        return constrained
    }

    private static func pinFrame(at point: CGPoint) -> CGRect {
        CGRect(
            x: point.x - (pinHeight / 2),
            y: point.y - pinHeight,
            width: pinHeight,
            height: pinHeight
        )
    }

    private static func collisionScore(
        _ frame: CGRect,
        offset: CGSize,
        occupiedLabels: [CGRect],
        otherPins: [CGRect]
    ) -> CGFloat {
        let labelOverlap = occupiedLabels.reduce(CGFloat.zero) { result, occupied in
            result + intersectionArea(frame, occupied)
        }
        let pinOverlap = otherPins.reduce(CGFloat.zero) { result, pin in
            result + intersectionArea(frame, pin)
        }
        return (labelOverlap * 10) + (pinOverlap * 4) + hypot(offset.width, offset.height)
    }

    private static func intersectionArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}

struct PhotographerMapView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("photographerMapRenderingMode") private var renderingMode: PhotographerMapRenderingMode = .standard
    @AppStorage("photographerMapShows3DBuildings") private var shows3DBuildings = false
    @State private var selectedDate = Date()
    @State private var secondsIntoDay: Double = 12 * 60 * 60
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedPhotographerID: UUID?
    @State private var selectedClipID: UUID?
    @State private var draggedClipID: UUID?
    @State private var draggedTranslation: CGSize = .zero
    @State private var weatherTarget: PhotographerMapWeatherTarget?
    @State private var weatherSnapshot: PhotographerMapWeatherSnapshot?
    @State private var weatherAttribution: WeatherAttribution?
    @State private var weatherLoadingTarget: PhotographerMapWeatherTarget?
    @State private var weatherErrorMessage: String?
    @State private var showsWeatherAttribution = false

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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
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
            selectedClipID = nil
            fitAllClipLocations()
        }
        .onChange(of: store.selectedJobID) { _, _ in
            selectedPhotographerID = nil
            selectedClipID = nil
            fitAllClipLocations()
        }
        .onChange(of: selectedInstant) { _, _ in
            if let selectedPhotographerID,
               !positions.contains(where: { $0.photographer.id == selectedPhotographerID }) {
                self.selectedPhotographerID = nil
            }
        }
        .task(id: weatherTarget) {
            guard let weatherTarget else { return }
            await loadWeather(for: weatherTarget)
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
            .accessibilityLabel("Previous Day")
            .accessibilityHint("Shows the previous day’s photographer schedule")
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
            .accessibilityLabel("Next Day")
            .accessibilityHint("Shows the next day’s photographer schedule")
            .help("Next Day")

            Button("Today") {
                selectedDate = calendar.startOfDay(for: Date())
                secondsIntoDay = seconds(on: Date())
            }

            Button {
                fitAllClipLocations()
            } label: {
                Label("Show All", systemImage: "scope")
            }
            .disabled(dayMapRect == nil)
            .help("Fit every clip location for the selected day on the map")
        }
        .padding(14)
    }

    private var map: some View {
        MapReader { proxy in
            GeometryReader { geometry in
                let labelOffsets = labelOffsets(proxy: proxy, mapSize: geometry.size)
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
                                isSelected: selectedPhotographerID == item.photographer.id,
                                labelOffset: labelOffsets[item.photographer.id, default: .zero]
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
                .onMapCameraChange(frequency: .onEnd) { context in
                    updateWeatherTarget(context.camera.centerCoordinate)
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
                .overlay(alignment: .bottomLeading) {
                    weatherIndicator
                        .padding(.leading, 12)
                        .padding(.bottom, 36)
                }
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
        HStack(spacing: 8) {
            Button(action: previousChange) {
                Label("Previous Change", systemImage: "backward.end.fill")
                    .labelStyle(.iconOnly)
            }
            .disabled(previousChangePoint == nil)
            .help("Previous location change")

            Text(selectedInstant.formatted(date: .omitted, time: .standard))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .frame(width: 74)
                .accessibilityIdentifier("photographer-map-selected-time")
                .accessibilityLabel("Selected Map Time")
                .accessibilityValue(selectedInstant.formatted(date: .omitted, time: .standard))

            Button(action: nextChange) {
                Label("Next Change", systemImage: "forward.end.fill")
                    .labelStyle(.iconOnly)
            }
            .disabled(nextChangePoint == nil)
            .help("Next location change")

            MapMiniTimeline(
                seconds: $secondsIntoDay,
                dayStart: dayStart,
                dayDuration: dayDuration,
                rows: mapTimelineRows,
                selectedPhotographerID: $selectedPhotographerID,
                selectedClipID: $selectedClipID,
                color: color(for:),
                onOpenClip: openMetadataProgramming(for:at:)
            )
            .help(changePointSummary)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(height: 60)
        .background(.bar)
    }

    @ViewBuilder
    private var weatherIndicator: some View {
        if let weatherSnapshot, let weatherAttribution {
            Button {
                showsWeatherAttribution.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: weatherSnapshot.current.symbolName)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 17))

                    Text(weatherSnapshot.current.temperature.formatted(
                        .measurement(width: .abbreviated)
                    ))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()

                    Divider()
                        .frame(height: 16)

                    WeatherAttributionImage(
                        url: colorScheme == .dark
                            ? weatherAttribution.combinedMarkLightURL
                            : weatherAttribution.combinedMarkDarkURL,
                        size: CGSize(width: 74, height: 14)
                    )

                    if weatherLoadingTarget == weatherTarget {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .contentShape(Capsule())
                .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Current weather at the center of the map")
            .accessibilityLabel("Current weather at map center")
            .accessibilityValue(weatherSnapshot.current.temperature.formatted(
                .measurement(width: .wide)
            ))
            .popover(isPresented: $showsWeatherAttribution) {
                PhotographerMapWeatherAttributionView(attribution: weatherAttribution)
            }
        } else if weatherLoadingTarget == weatherTarget {
            ProgressView()
                .controlSize(.small)
                .padding(9)
                .background(.regularMaterial, in: Circle())
                .accessibilityLabel("Loading weather at map center")
        } else if let weatherErrorMessage {
            Image(systemName: "cloud.slash")
                .font(.system(size: 15, weight: .medium))
                .padding(9)
                .background(.regularMaterial, in: Circle())
                .help("Weather unavailable: \(weatherErrorMessage)")
                .accessibilityLabel("Weather unavailable")
        }
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

    private var dayMapRect: MKMapRect? {
        PhotographerMapCameraFraming.mapRect(
            for: mapTimelineRows.flatMap(\.clips).compactMap(\.gpsPosition)
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

    private func fitAllClipLocations() {
        guard let dayMapRect else {
            cameraPosition = .automatic
            weatherTarget = nil
            weatherSnapshot = nil
            weatherErrorMessage = nil
            return
        }
        cameraPosition = .rect(dayMapRect)
        updateWeatherTarget(MKMapPoint(x: dayMapRect.midX, y: dayMapRect.midY).coordinate)
    }

    private func updateWeatherTarget(_ coordinate: CLLocationCoordinate2D) {
        guard let target = PhotographerMapWeatherTarget(coordinate) else { return }
        weatherTarget = target
    }

    @MainActor
    private func loadWeather(for target: PhotographerMapWeatherTarget) async {
        if let weatherSnapshot, weatherSnapshot.isFresh(for: target) {
            weatherErrorMessage = nil
            return
        }

        if let weatherSnapshot,
           weatherSnapshot.target.location.distance(from: target.location) >= 3_000 {
            self.weatherSnapshot = nil
        }
        weatherLoadingTarget = target
        weatherErrorMessage = nil

        defer {
            if weatherTarget == target {
                weatherLoadingTarget = nil
            }
        }

        do {
            try await Task.sleep(for: .milliseconds(250))
            let current = try await WeatherService.shared.weather(
                for: target.location,
                including: .current
            )
            let attribution = if let weatherAttribution {
                weatherAttribution
            } else {
                try await WeatherService.shared.attribution
            }
            try Task.checkCancellation()
            guard weatherTarget == target else { return }

            weatherAttribution = attribution
            weatherSnapshot = PhotographerMapWeatherSnapshot(
                target: target,
                current: current
            )
        } catch is CancellationError {
            return
        } catch {
            guard weatherTarget == target else { return }
            weatherErrorMessage = error.localizedDescription
        }
    }

    private func moveDay(by value: Int) {
        selectedDate = calendar.date(byAdding: .day, value: value, to: selectedDate) ?? selectedDate
    }

    private func applyRequestedDate() {
        let requested = store.metadataMapRequestedDate ?? Date()
        selectedDate = calendar.startOfDay(for: requested)
        secondsIntoDay = seconds(on: requested)
        fitAllClipLocations()
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

    private func labelOffsets(proxy: MapProxy, mapSize: CGSize) -> [UUID: CGSize] {
        let anchors = positions.compactMap { item -> PhotographerMapLabelAnchor? in
            guard let convertedPoint = proxy.convert(
                coordinate(for: item),
                to: .named(mapCoordinateSpaceName)
            ) else { return nil }
            let dragOffset = markerOffset(for: item)
            let point = CGPoint(
                x: convertedPoint.x + dragOffset.width,
                y: convertedPoint.y + dragOffset.height
            )
            return PhotographerMapLabelAnchor(
                id: item.photographer.id,
                point: point,
                labelWidth: estimatedLabelWidth(item.photographer.photographerName),
                isSelected: selectedPhotographerID == item.photographer.id
            )
        }
        return PhotographerMapLabelLayout.offsets(
            for: anchors,
            in: CGRect(origin: .zero, size: mapSize)
        )
    }

    private func estimatedLabelWidth(_ name: String) -> CGFloat {
        min(max(CGFloat(name.count) * 9 + 18, 64), 240)
    }

    private func markerGesture(
        for item: ScheduledPhotographerPosition,
        proxy: MapProxy
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(mapCoordinateSpaceName))
            .onChanged { value in
                guard gestureDistance(value.translation) >= 3 else { return }
                selectedPhotographerID = item.photographer.id
                draggedClipID = item.clip.id
                draggedTranslation = value.translation
            }
            .onEnded { value in
                if gestureDistance(value.translation) < 3 {
                    selectedPhotographerID = item.photographer.id
                    selectedClipID = item.clip.id
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
        openMetadataProgramming(for: item.clip, at: selectedInstant)
    }

    private func openMetadataProgramming(for clip: MetadataScheduleClip, at date: Date) {
        guard let selectedJob else { return }
        store.requestMetadataProgramming(
            for: clip.id,
            jobID: selectedJob.id,
            at: date
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

private struct WeatherAttributionImage: View {
    let url: URL
    let size: CGSize

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .scaledToFit()
            } else {
                Text("Weather")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

private struct PhotographerMapWeatherAttributionView: View {
    @Environment(\.colorScheme) private var colorScheme
    let attribution: WeatherAttribution

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WeatherAttributionImage(
                url: colorScheme == .dark
                    ? attribution.combinedMarkLightURL
                    : attribution.combinedMarkDarkURL,
                size: CGSize(width: 126, height: 22)
            )

            Link(destination: attribution.legalPageURL) {
                Label("Weather data sources", systemImage: "arrow.up.right.square")
                    .font(.caption)
            }
        }
        .padding(14)
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
    let labelOffset: CGSize

    var body: some View {
        VStack(spacing: 2) {
            Text(item.photographer.photographerName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 222)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .foregroundStyle(.primary)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule().stroke(color, lineWidth: isSelected ? 3 : 1)
                }
                .offset(labelOffset)

            Image(systemName: "mappin.circle.fill")
                .font(.system(size: isSelected ? 31 : 27))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, color)
                .shadow(radius: 2, y: 1)
        }
        .overlay {
            if labelOffset != .zero {
                GeometryReader { geometry in
                    Path { path in
                        let pinTop = geometry.size.height - PhotographerMapLabelLayout.pinHeight
                        path.move(to: CGPoint(x: geometry.size.width / 2, y: pinTop))
                        path.addLine(to: CGPoint(
                            x: (geometry.size.width / 2) + labelOffset.width,
                            y: pinTop - 2 + labelOffset.height
                        ))
                    }
                    .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                }
                .allowsHitTesting(false)
            }
        }
        .help("Click to select, drag to update this clip’s GPS location, or double-click to edit the metadata clip.")
    }
}

private struct MapMiniTimeline: View {
    @State private var scrubPreviewSeconds: Double?
    @State private var lastScrubCommit = Date.distantPast
    @Binding var seconds: Double
    let dayStart: Date
    let dayDuration: Double
    let rows: [PhotographerMapTimelineRow]
    @Binding var selectedPhotographerID: UUID?
    @Binding var selectedClipID: UUID?
    let color: (PhotographerProfile) -> Color
    let onOpenClip: (MetadataScheduleClip, Date) -> Void

    private let scrubCommitInterval: TimeInterval = 1.0 / 12.0

    var body: some View {
        GeometryReader { proxy in
            let trackHeight = max(proxy.size.height - 11, 1)
            let laneHeight = trackHeight / CGFloat(max(rows.count, 1))

            VStack(spacing: 1) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.1))

                    if rows.isEmpty {
                        Text("No clips")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    } else {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            timelineLane(
                                row,
                                laneHeight: laneHeight,
                                totalWidth: proxy.size.width
                            )
                            .offset(y: CGFloat(index) * laneHeight)
                        }
                    }

                    Rectangle()
                        .fill(Color.primary.opacity(0.85))
                        .frame(width: 1, height: trackHeight)
                        .offset(x: playheadOffset(totalWidth: proxy.size.width) - 0.5)
                        .allowsHitTesting(false)
                }
                .frame(height: trackHeight)
                .contentShape(Rectangle())
                .simultaneousGesture(scrubGesture(
                    totalWidth: proxy.size.width,
                    trackHeight: trackHeight
                ))

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
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 240, maxWidth: .infinity, minHeight: 38, maxHeight: 44)
        .focusable()
        .onKeyPress(.leftArrow) {
            adjustTime(by: -5 * 60)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            adjustTime(by: 5 * 60)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photographer-map-timeline")
        .accessibilityLabel("Photographer metadata clip timeline")
        .accessibilityValue(accessibilityTime)
        .accessibilityHint("Adjust, or use the left and right arrow keys, to change the map time by five minutes")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                adjustTime(by: 5 * 60)
            case .decrement:
                adjustTime(by: -5 * 60)
            @unknown default:
                break
            }
        }
    }

    private func timelineLane(
        _ row: PhotographerMapTimelineRow,
        laneHeight: CGFloat,
        totalWidth: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: totalWidth, height: laneHeight)

            ForEach(row.clips) { clip in
                clipBar(
                    clip,
                    photographer: row.photographer,
                    laneHeight: laneHeight,
                    totalWidth: totalWidth
                )
            }
        }
        .frame(width: totalWidth, height: laneHeight)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photographer-map-timeline-row-\(row.id.uuidString)")
        .accessibilityLabel("\(row.photographer.photographerName) metadata clips")
    }

    private func clipBar(
        _ clip: MetadataScheduleClip,
        photographer: PhotographerProfile,
        laneHeight: CGFloat,
        totalWidth: CGFloat
    ) -> some View {
        let frame = PhotographerMapTimeline.clipFrame(
            for: clip,
            dayStart: dayStart,
            dayDuration: dayDuration,
            totalWidth: totalWidth
        )
        let hasLocation = clip.gpsPosition?.isValid == true
        let isActive = clip.contains(dayStart.addingTimeInterval(displayedSeconds))
        let isSelected = selectedClipID == clip.id
        let clipColor = color(photographer)
        let lineHeight = min(max(laneHeight * 0.55, 1.5), isSelected || isActive ? 4 : 3)

        return Button {
            _ = select(
                clip,
                photographerID: photographer.id,
                locationX: frame.width / 2,
                displayWidth: frame.width
            )
        } label: {
            Capsule()
                .fill(clipColor.opacity(hasLocation ? 0.95 : 0.3))
                .frame(height: lineHeight)
                .overlay {
                    Capsule()
                        .stroke(
                            isSelected || isActive
                                ? Color.primary
                                : clipColor.opacity(hasLocation ? 0.9 : 0.5),
                            style: StrokeStyle(
                                lineWidth: isSelected ? 1.5 : (isActive ? 1 : 0.5),
                                dash: hasLocation ? [] : [3, 2]
                            )
                        )
                }
        }
            .buttonStyle(.plain)
            .frame(width: frame.width, height: laneHeight)
            .position(x: frame.midX, y: laneHeight / 2)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                let date = select(
                    clip,
                    photographerID: photographer.id,
                    locationX: frame.width / 2,
                    displayWidth: frame.width
                )
                onOpenClip(clip, date)
            })
            .help("\(clip.name) · \(hasLocation ? "location set" : "no location") · Click to select or double-click to edit")
            .accessibilityElement()
            .accessibilityIdentifier("photographer-map-clip-\(clip.id.uuidString)")
            .accessibilityLabel("\(clip.name), \(photographer.photographerName)")
            .accessibilityValue("\(isSelected ? "Selected" : "Not selected"), \(hasLocation ? "location set" : "no location")")
            .accessibilityHint("Click to select this clip or double-click to edit it in Metadata Programming")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Open in Metadata Programming") {
                let date = select(
                    clip,
                    photographerID: photographer.id,
                    locationX: frame.width / 2,
                    displayWidth: frame.width
                )
                onOpenClip(clip, date)
            }
    }

    private func scrubGesture(
        totalWidth: CGFloat,
        trackHeight: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let scrubbedSeconds = seconds(at: value.location.x, totalWidth: totalWidth)
                if scrubPreviewSeconds == nil {
                    lastScrubCommit = .distantPast
                }
                scrubPreviewSeconds = scrubbedSeconds

                let now = Date()
                if now.timeIntervalSince(lastScrubCommit) >= scrubCommitInterval {
                    seconds = scrubbedSeconds
                    lastScrubCommit = now
                }

                let rowID = row(at: value.location.y, trackHeight: trackHeight)?.photographer.id
                if selectedPhotographerID != rowID {
                    selectedPhotographerID = rowID
                }
                if hypot(value.translation.width, value.translation.height) >= 3,
                   selectedClipID != nil {
                    selectedClipID = nil
                }
            }
            .onEnded { value in
                let finalSeconds = seconds(at: value.location.x, totalWidth: totalWidth)
                seconds = finalSeconds
                scrubPreviewSeconds = nil
                lastScrubCommit = .distantPast

                guard hypot(value.translation.width, value.translation.height) < 3 else { return }
                let date = dayStart.addingTimeInterval(
                    finalSeconds
                )
                selectedClipID = row(at: value.location.y, trackHeight: trackHeight)
                    .flatMap { clip(at: date, in: $0)?.id }
            }
    }

    private func row(at locationY: CGFloat, trackHeight: CGFloat) -> PhotographerMapTimelineRow? {
        guard !rows.isEmpty else { return nil }
        let fraction = min(max(locationY / max(trackHeight, 1), 0), 0.999_999)
        return rows[min(Int(fraction * CGFloat(rows.count)), rows.count - 1)]
    }

    private func seconds(at locationX: CGFloat, totalWidth: CGFloat) -> Double {
        let fraction = min(max(locationX / max(totalWidth, 1), 0), 1)
        return min(Double(fraction) * dayDuration, maximumSeconds)
    }

    private func clip(
        at date: Date,
        in row: PhotographerMapTimelineRow
    ) -> MetadataScheduleClip? {
        row.clips.first { clip in
            clip.startsAt <= date && date < clip.endsAt
        }
    }

    private func select(
        _ clip: MetadataScheduleClip,
        photographerID: UUID,
        locationX: CGFloat,
        displayWidth: CGFloat
    ) -> Date {
        let fraction = Double(min(max(locationX / max(displayWidth, 1), 0), 1))
        let date = PhotographerMapTimeline.selectionInstant(in: clip, at: fraction)
        seconds = min(max(date.timeIntervalSince(dayStart), 0), maximumSeconds)
        selectedPhotographerID = photographerID
        selectedClipID = clip.id
        return date
    }

    private func playheadOffset(totalWidth: CGFloat) -> CGFloat {
        CGFloat(min(max(displayedSeconds / max(dayDuration, 1), 0), 1)) * totalWidth
    }

    private func adjustTime(by interval: Double) {
        seconds = min(max(seconds + interval, 0), maximumSeconds)
        let row = rows.first { $0.photographer.id == selectedPhotographerID } ?? rows.first
        selectedPhotographerID = row?.photographer.id
        selectedClipID = row.flatMap {
            clip(at: dayStart.addingTimeInterval(seconds), in: $0)?.id
        }
    }

    private var maximumSeconds: Double {
        max(dayDuration - 0.001, 0)
    }

    private var displayedSeconds: Double {
        scrubPreviewSeconds ?? seconds
    }

    private var accessibilityTime: String {
        dayStart.addingTimeInterval(min(max(seconds, 0), maximumSeconds))
            .formatted(date: .omitted, time: .shortened)
    }
}
