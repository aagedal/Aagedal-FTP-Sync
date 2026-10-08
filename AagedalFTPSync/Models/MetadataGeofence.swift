import Foundation

/// A job-local named area. The first matching area in the saved list wins.
struct MetadataGeofence: Codable, Hashable, Identifiable, Sendable {
    struct Vertex: Codable, Hashable, Sendable {
        var latitude: Double
        var longitude: Double

        init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }

        private enum CodingKeys: String, CodingKey, CaseIterable { case latitude, longitude }

        init(from decoder: Decoder) throws {
            let all = try decoder.container(keyedBy: MetadataGeofence.AnyKey.self)
            guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
                throw MetadataGeocodingSettingsError.invalidSettings
            }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            latitude = try values.decode(Double.self, forKey: .latitude)
            longitude = try values.decode(Double.self, forKey: .longitude)
        }

        var isValid: Bool {
            latitude.isFinite && longitude.isFinite &&
            (-90...90).contains(latitude) && (-180...180).contains(longitude)
        }
    }

    let id: UUID
    var name: String
    var vertices: [Vertex]

    init(id: UUID = UUID(), name: String, vertices: [Vertex]) {
        self.id = id
        self.name = name
        self.vertices = vertices
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case id, name, vertices }
    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: AnyKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw MetadataGeocodingSettingsError.invalidSettings
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        vertices = try values.decode([Vertex].self, forKey: .vertices)
    }

    var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 256,
              (3...200).contains(vertices.count), vertices.allSatisfy(\.isValid),
              Set(vertices).count == vertices.count else { return false }
        // A local polygon is deliberately kept on one side of the date line.
        // This avoids treating a short edge across it as a world-spanning edge.
        let longitudes = vertices.map(\.longitude)
        guard (longitudes.max()! - longitudes.min()!) < 180 else { return false }
        var twiceArea = 0.0
        for i in vertices.indices {
            let a = vertices[i], b = vertices[(i + 1) % vertices.count]
            twiceArea += a.longitude * b.latitude - b.longitude * a.latitude
        }
        guard abs(twiceArea) > 1e-12 else { return false }
        for i in vertices.indices {
            let a = vertices[i], b = vertices[(i + 1) % vertices.count]
            for j in vertices.indices where j > i + 1 {
                if i == 0 && j == vertices.count - 1 { continue }
                let c = vertices[j], d = vertices[(j + 1) % vertices.count]
                if Self.intersects(a, b, c, d) { return false }
            }
        }
        return true
    }

    func contains(latitude: Double, longitude: Double) -> Bool {
        guard isValid, latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return false }
        let point = Vertex(latitude: latitude, longitude: longitude)
        var inside = false
        for i in vertices.indices {
            let a = vertices[i], b = vertices[(i + 1) % vertices.count]
            if Self.onSegment(point, a, b) { return true }
            if (a.latitude > latitude) != (b.latitude > latitude) {
                let crossing = a.longitude + (latitude - a.latitude) *
                    (b.longitude - a.longitude) / (b.latitude - a.latitude)
                if longitude < crossing { inside.toggle() }
            }
        }
        return inside
    }

    private static func cross(_ a: Vertex, _ b: Vertex, _ c: Vertex) -> Double {
        (b.longitude - a.longitude) * (c.latitude - a.latitude) -
        (b.latitude - a.latitude) * (c.longitude - a.longitude)
    }

    private static func onSegment(_ p: Vertex, _ a: Vertex, _ b: Vertex) -> Bool {
        abs(cross(a, b, p)) < 1e-12 &&
        p.longitude >= min(a.longitude, b.longitude) - 1e-12 &&
        p.longitude <= max(a.longitude, b.longitude) + 1e-12 &&
        p.latitude >= min(a.latitude, b.latitude) - 1e-12 &&
        p.latitude <= max(a.latitude, b.latitude) + 1e-12
    }

    private static func intersects(_ a: Vertex, _ b: Vertex, _ c: Vertex, _ d: Vertex) -> Bool {
        if onSegment(a, c, d) || onSegment(b, c, d) ||
            onSegment(c, a, b) || onSegment(d, a, b) { return true }
        let abC = cross(a, b, c), abD = cross(a, b, d)
        let cdA = cross(c, d, a), cdB = cross(c, d, b)
        return (abC < 0) != (abD < 0) && (cdA < 0) != (cdB < 0)
    }
}
