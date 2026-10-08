import CExpat
import Foundation
import SwiftMediaMetadata

/// Strict, bounded validation before the pinned permissive XMP tokenizer.
/// Expat is independent of the process-global libxml2 state used by ImageIO.
enum MetadataXMPValidation {
    static let maximumBytes = 8 * 1024 * 1024
    private static let maximumDepth = 64
    private static let maximumElements = 100_000

    private final class State {
        let parser: XML_Parser
        var depth = 0
        var elements = 0
        var hasRDF = false
        var rootIsWrapper = false
        var refused = false
        init(parser: XML_Parser) { self.parser = parser }
        func refuse() {
            refused = true
            XML_StopParser(parser, XML_Bool(0))
        }
    }

    static func read(at url: URL) throws -> XMPData {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumBytes {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(64 * 1024, maximumBytes + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        try validate(data)
        // Parse the same captured bytes; do not reread a path after validation.
        return try XMPReader.readFromXML(data)
    }

    static func validate(_ data: Data) throws {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= maximumBytes,
              String(data: data, encoding: .utf8) != nil else {
            throw invalid()
        }
        guard let parser = XML_ParserCreateNS("UTF-8", 31) else { throw invalid() }
        defer { XML_ParserFree(parser) }
        let state = State(parser: parser)
        XML_SetUserData(parser, Unmanaged.passUnretained(state).toOpaque())
        XML_SetStartDoctypeDeclHandler(parser) { context, _, _, _, _ in
            guard let context else { return }
            Unmanaged<State>.fromOpaque(context).takeUnretainedValue().refuse()
        }
        XML_SetElementHandler(parser, { context, name, _ in
            guard let context, let name else { return }
            let state = Unmanaged<State>.fromOpaque(context).takeUnretainedValue()
            state.depth += 1
            state.elements += 1
            guard state.depth <= MetadataXMPValidation.maximumDepth, state.elements <= MetadataXMPValidation.maximumElements else {
                state.refuse(); return
            }
            let expanded = String(cString: name)
            let isRDF = expanded == "http://www.w3.org/1999/02/22-rdf-syntax-ns#\u{1f}RDF"
            if state.depth == 1 {
                state.rootIsWrapper = ["adobe:ns:meta/\u{1f}xmpmeta", "adobe:ns:meta/\u{1f}xapmeta"].contains(expanded)
                guard isRDF || state.rootIsWrapper else { state.refuse(); return }
            }
            if isRDF {
                guard !state.hasRDF, state.depth == (state.rootIsWrapper ? 2 : 1) else {
                    state.refuse(); return
                }
                state.hasRDF = true
            }
        }, { context, _ in
            guard let context else { return }
            Unmanaged<State>.fromOpaque(context).takeUnretainedValue().depth -= 1
        })
        // No DTD or external entity loading is permitted. Small chunks provide
        // cancellation points while byte/depth/element limits bound parser work.
        _ = XML_SetParamEntityParsing(parser, XML_PARAM_ENTITY_PARSING_NEVER)
        try data.withUnsafeBytes { buffer in
            let bytes = buffer.baseAddress!.assumingMemoryBound(to: CChar.self)
            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                let count = min(16 * 1024, data.count - offset)
                let final: Int32 = offset + count == data.count ? 1 : 0
                guard XML_Parse(parser, bytes.advanced(by: offset), Int32(count), final) == XML_STATUS_OK,
                      !state.refused else { throw invalid() }
                offset += count
            }
        }
        guard state.hasRDF, state.depth == 0 else { throw invalid() }
        try Task.checkCancellation()
    }

    private static func invalid() -> AppError {
        .invalidConfiguration("The existing GPS sidecar is not supported well-formed UTF-8 XMP, or exceeds the safe parsing limits. It was not treated as empty.")
    }
}
