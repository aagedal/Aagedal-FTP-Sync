import Foundation

/// The pinned Photo Agent FEM2 wire encoding, independent of host byte order.
/// Successful decoding establishes vector validity only: library admission must
/// separately verify the model, embedding space and preprocessing manifest.
enum FaceRecognitionEmbeddingCodec {
    enum ValidationError: Error, Equatable {
        case invalidLength
        case unsupportedEncoding
        case invalidDimension
    }

    static let encodedByteCount = 8 + 512 * 4
    private static let magic: UInt32 = 0x46454D32

    static func decode(_ data: Data) throws -> FaceRecognitionEmbedding {
        // Check the fixed bound before allocating or trusting the encoded count.
        guard data.count == encodedByteCount else { throw ValidationError.invalidLength }
        return try data.withUnsafeBytes { bytes in
            func word(at offset: Int) -> UInt32 {
                UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
            guard word(at: 0) == magic else { throw ValidationError.unsupportedEncoding }
            guard word(at: 4) == 512 else { throw ValidationError.invalidDimension }
            let values = (0..<512).map { Float(bitPattern: word(at: 8 + $0 * 4)) }
            return try FaceRecognitionEmbedding(validatingNormalized: values)
        }
    }

    static func encode(_ embedding: FaceRecognitionEmbedding) -> Data {
        var data = Data(capacity: encodedByteCount)
        func append(_ value: UInt32) {
            var word = value.littleEndian
            withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
        }
        append(magic)
        append(512)
        for value in embedding.values { append(value.bitPattern) }
        return data
    }
}
