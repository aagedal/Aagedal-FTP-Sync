import Foundation
import SwiftExif

enum MetadataWriter {
    static func apply(_ assignment: MetadataAssignment, to fileURL: URL) throws {
        var metadata = try ImageMetadata.read(from: fileURL)
        let fields = assignment.clip.fields

        let headline = fields.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = fields.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let creator = assignment.photographer.creator.trimmingCharacters(in: .whitespacesAndNewlines)
        let copyright = assignment.photographer.copyrightNotice.trimmingCharacters(in: .whitespacesAndNewlines)
        let keywords = fields.normalizedKeywords

        if !headline.isEmpty { try metadata.iptc.setValue(headline, for: .headline) }
        if !description.isEmpty { try metadata.iptc.setValue(description, for: .captionAbstract) }
        if !keywords.isEmpty { try metadata.iptc.setValues(keywords, for: .keywords) }
        if !creator.isEmpty { try metadata.iptc.setValue(creator, for: .byline) }
        if !copyright.isEmpty { try metadata.iptc.setValue(copyright, for: .copyrightNotice) }
        metadata.syncIPTCToXMP()
        try metadata.write(to: fileURL)
    }
}
