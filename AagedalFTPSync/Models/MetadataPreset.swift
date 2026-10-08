import Foundation

struct MetadataPreset: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var fields: ScheduledMetadataFields

    init(
        id: UUID = UUID(),
        name: String,
        fields: ScheduledMetadataFields = ScheduledMetadataFields()
    ) {
        self.id = id
        self.name = name
        self.fields = fields
    }

    var hasActivatedTemplates: Bool { fields.hasActivatedTemplates }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var validationMessage: String? {
        trimmedName.isEmpty ? "Give the metadata preset a name." : nil
    }

    func normalized() -> MetadataPreset {
        var result = self
        result.name = trimmedName
        // Active source is not a resolved keyword list. Preserve each byte and
        // ordered entry until the template engine expands it for a specific image.
        if fields.templateVersions["keywords"] == nil { result.fields.keywords = fields.normalizedKeywords }
        return result
    }
}

extension MetadataScheduleClip {
    func applying(_ preset: MetadataPreset) -> MetadataScheduleClip {
        var result = self
        result.fields = preset.fields
        return result
    }
}
