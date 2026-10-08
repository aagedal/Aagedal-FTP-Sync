import MapKit
import SwiftUI

/// Edits the job draft. The job editor remains responsible for saving it.
struct MetadataGeofenceEditorView: View {
    @Binding var geofences: [MetadataGeofence]
    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 59.9139, longitude: 10.7522),
        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)))
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var vertices: [MetadataGeofence.Vertex] = []
    @GestureState private var isDraggingCorner = false

    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var message: String?

    private let mapCoordinateSpaceName = "geofence-map"

    private var draft: MetadataGeofence {
        MetadataGeofence(id: editingID ?? UUID(), name: name, vertices: vertices)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Named Areas").font(.title2.bold())
                Text("The first saved area containing an image’s GPS position supplies City and {gps:city}. Areas outside the polygons use the selected location provider.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("When Country is needed, the selected provider still resolves it. Saved areas are checked in the order shown below.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(geofences) { area in
                            HStack {
                                Button(area.name) { edit(area) }
                                    .buttonStyle(.plain)
                                    .fontWeight(editingID == area.id ? .semibold : .regular)
                                Spacer()
                                Button("↑") { move(area, by: -1) }
                                    .disabled(geofences.first?.id == area.id)
                                    .help("Higher priority")
                                Button("↓") { move(area, by: 1) }
                                    .disabled(geofences.last?.id == area.id)
                                    .help("Lower priority")
                                Button(role: .destructive) { remove(area) } label: {
                                    Image(systemName: "trash")
                                }
                                .help("Remove area from this job draft")
                            }
                            .padding(7)
                            .background(editingID == area.id ? Color.accentColor.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                Button("New Area") { newArea() }
                    .disabled(geofences.count >= 50)
                    .accessibilityIdentifier("new-geofence")
                Divider()
                TextField("Area name", text: $name)
                    .accessibilityIdentifier("geofence-name")
                HStack {
                    Text("\(vertices.count) corners")
                        .font(.caption.monospacedDigit())
                    Spacer()
                    Button("Undo Corner") { _ = vertices.popLast(); message = nil }
                        .disabled(vertices.isEmpty)
                    Button("Clear Outline") { vertices = []; message = nil }
                        .disabled(vertices.isEmpty)
                }
                Text("Click the map to add corners in order. Drag a corner to move it, drag the map to pan, or scroll to zoom. Use Undo Corner to remove the last corner.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message { Text(message).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button(editingID == nil ? "Add Area" : "Update Area", action: saveArea)
                        .disabled(!draft.isValid || (editingID == nil && geofences.count >= 50))
                        .accessibilityIdentifier("save-geofence")
                    Spacer()
                    Button("Done") { dismiss() }
                }
            }
            .padding(18)
            .frame(width: 350)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    TextField("Search for a place to center the map", text: $searchText)
                        .onSubmit(search)
                    Button("Search", action: search)
                        .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(10)
                MapReader { proxy in
                    Map(position: $camera, interactionModes: isDraggingCorner ? [] : .all) {
                        ForEach(geofences.filter { $0.id != editingID }) { area in
                            MapPolygon(coordinates: coordinates(area.vertices))
                                .foregroundStyle(Color.accentColor.opacity(0.2))
                                .stroke(Color.accentColor, lineWidth: 2)
                        }
                        if vertices.count >= 3 {
                            MapPolygon(coordinates: coordinates(vertices))
                                .foregroundStyle(Color.orange.opacity(0.25))
                                .stroke(Color.orange, lineWidth: 2)
                        } else if vertices.count >= 2 {
                            MapPolyline(coordinates: coordinates(vertices))
                                .stroke(Color.orange, lineWidth: 2)
                        }
                        ForEach(vertices.indices, id: \.self) { index in
                            Annotation("Corner \(index + 1)",
                                       coordinate: coordinate(vertices[index]), anchor: .center) {
                                Circle().fill(.orange).frame(width: 11, height: 11)
                                    .overlay(Circle().stroke(.white, lineWidth: 2))
                                    .frame(width: 28, height: 28)
                                    .contentShape(Circle())
                                    .accessibilityLabel("Corner \(index + 1)")
                                    .help("Drag to move this corner")
                                    .highPriorityGesture(cornerDragGesture(at: index, proxy: proxy))
                            }
                        }
                    }
                    .coordinateSpace(name: mapCoordinateSpaceName)
                    .mapStyle(.standard(elevation: .flat))
                    .mapControls { MapCompass(); MapScaleView() }
                    .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named(mapCoordinateSpaceName)).onEnded { value in
                        guard !isDraggingCorner, vertices.count < 200,
                              !vertices.contains(where: { vertex in
                                  guard let location = proxy.convert(coordinate(vertex), to: .named(mapCoordinateSpaceName)) else { return false }
                                  return hypot(location.x - value.location.x, location.y - value.location.y) <= 14
                              }),
                              let point = proxy.convert(value.location, from: .named(mapCoordinateSpaceName)),
                              CLLocationCoordinate2DIsValid(point) else { return }
                        vertices.append(.init(latitude: point.latitude, longitude: point.longitude))
                        message = nil
                    })
                }
            }
        }
        .frame(minWidth: 950, minHeight: 620)
        .onAppear {
            if let first = geofences.first { edit(first) }
        }
        .onDisappear { searchTask?.cancel() }
    }

    private func coordinate(_ vertex: MetadataGeofence.Vertex) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: vertex.latitude, longitude: vertex.longitude)
    }

    private func coordinates(_ vertices: [MetadataGeofence.Vertex]) -> [CLLocationCoordinate2D] {
        vertices.map(coordinate)
    }

    private func edit(_ area: MetadataGeofence) {
        editingID = area.id
        name = area.name
        vertices = area.vertices
        message = nil
        let latitudes = vertices.map(\.latitude), longitudes = vertices.map(\.longitude)
        if let minLat = latitudes.min(), let maxLat = latitudes.max(),
           let minLon = longitudes.min(), let maxLon = longitudes.max() {
            camera = .region(MKCoordinateRegion(
                center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                span: .init(latitudeDelta: max((maxLat - minLat) * 1.5, 0.01),
                            longitudeDelta: max((maxLon - minLon) * 1.5, 0.01))))
        }
    }

    private func newArea() {
        editingID = nil
        name = ""
        vertices = []
        message = nil
    }

    private func cornerDragGesture(at index: Int, proxy: MapProxy) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(mapCoordinateSpaceName))
            .updating($isDraggingCorner) { _, isDragging, _ in
                isDragging = true
            }
            .onChanged { value in
                guard hypot(value.translation.width, value.translation.height) >= 3 else { return }
                moveCorner(at: index, to: value.location, proxy: proxy)
            }
            .onEnded { value in
                guard hypot(value.translation.width, value.translation.height) >= 3 else { return }
                moveCorner(at: index, to: value.location, proxy: proxy)
            }
    }

    private func moveCorner(at index: Int, to location: CGPoint, proxy: MapProxy) {
        guard vertices.indices.contains(index),
              let point = proxy.convert(location, from: .named(mapCoordinateSpaceName)),
              CLLocationCoordinate2DIsValid(point) else { return }
        vertices[index] = .init(latitude: point.latitude, longitude: point.longitude)
        message = nil
    }

    private func saveArea() {
        let area = draft
        guard area.isValid else {
            message = "Enter a name and draw at least three corners forming a simple polygon."
            return
        }
        if let index = geofences.firstIndex(where: { $0.id == editingID }) {
            geofences[index] = area
        } else {
            guard geofences.count < 50 else { return }
            geofences.append(area)
        }
        edit(area)
    }

    private func remove(_ area: MetadataGeofence) {
        geofences.removeAll { $0.id == area.id }
        if editingID == area.id { newArea() }
    }

    private func move(_ area: MetadataGeofence, by offset: Int) {
        guard let index = geofences.firstIndex(where: { $0.id == area.id }),
              geofences.indices.contains(index + offset) else { return }
        geofences.swapAt(index, index + offset)
    }

    private func search() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchTask?.cancel()
        searchTask = Task {
            do {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = query
                let response = try await MKLocalSearch(request: request).start()
                guard !Task.isCancelled, let point = response.mapItems.first?.placemark.coordinate else { return }
                camera = .region(MKCoordinateRegion(center: point,
                    span: .init(latitudeDelta: 0.08, longitudeDelta: 0.08)))
                message = nil
            } catch {
                if !Task.isCancelled { message = "Map search could not find that place." }
            }
        }
    }
}
