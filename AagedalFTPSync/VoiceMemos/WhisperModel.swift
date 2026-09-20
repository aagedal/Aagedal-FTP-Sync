import Foundation

/// Pinned upstream GGML artifacts; downloaded files must match both length and SHA-256.
struct WhisperModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let bytes: Int64
    let sha256: String
    let source: String
    var downloadURL: URL { URL(string: source)! }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    var memoryLabel: String {
        if bytes < 200_000_000 { return "About 1 GB RAM" }
        if bytes < 600_000_000 { return "About 2 GB RAM" }
        if bytes < 2_000_000_000 { return "About 5 GB RAM" }
        return "About 10 GB RAM"
    }
    static let catalogue: [Self] = [
        .init(id: "nb_tiny", name: "Norwegian Tiny (NB-Whisper)", bytes: 77691730,
              sha256: "2f9dd799ee36b6a9c8d642e9b1df8ecf2135efdd5a91b1d9ca0b3c0decda535f",
              source: "https://huggingface.co/NbAiLab/nb-whisper-tiny/resolve/8b38492d0e4111d5d6ad825e979cb082a2da013a/ggml-model.bin"),
        .init(id: "nb_small", name: "Norwegian Small (NB-Whisper)", bytes: 487601984,
              sha256: "a0fc1555f5bd51044b0ea88bb9b7891e1ee331a8087eddb0afc3a05839db48ab",
              source: "https://huggingface.co/NbAiLab/nb-whisper-small/resolve/e9bb5cb83cb74c96239fd506163aa97cff2fce4c/ggml-model.bin"),
        .init(id: "nb_medium", name: "Norwegian Medium (NB-Whisper)", bytes: 1533763076,
              sha256: "f73141401d203ee77fc7ddf7bf97926a8a85fe85faa6066a6920e4815f48a73d",
              source: "https://huggingface.co/NbAiLab/nb-whisper-medium/resolve/0ed074d5985bd56ca4140159a9dbffbc3fb5117e/ggml-model.bin"),
        .init(id: "nb_large", name: "Norwegian Large (NB-Whisper)", bytes: 3095033483,
              sha256: "0f2f66f22e11a7c7da3c582d8e5c89cb2c0011753ba9c7c9731e320a4ba33e76",
              source: "https://huggingface.co/NbAiLab/nb-whisper-large/resolve/8c6249fdeeb4dcd05e5735a4c39640607eb6e4ac/ggml-model.bin"),
        .init(id: "tiny", name: "Whisper Tiny", bytes: 77691713,
              sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
              source: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-tiny.bin"),
        .init(id: "base", name: "Whisper Base", bytes: 147951465,
              sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
              source: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.bin"),
        .init(id: "small", name: "Whisper Small", bytes: 487601967,
              sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
              source: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small.bin"),
        .init(id: "medium", name: "Whisper Medium", bytes: 1533763059,
              sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208",
              source: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-medium.bin"),
        .init(id: "large-v3", name: "Whisper Large-V3", bytes: 3095033483,
              sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2",
              source: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3.bin")
    ]
    static let defaultID = "nb_small"
}

struct VoiceMemoSettings: Equatable, Sendable {
    static let modelKey = "voiceMemo.model"
    static let languageKey = "voiceMemo.language"
    let modelID: String
    let language: String
    static var current: Self {
        Self(modelID: UserDefaults.standard.string(forKey: modelKey) ?? WhisperModel.defaultID,
             language: UserDefaults.standard.string(forKey: languageKey) ?? "no")
    }
    static let languages: [(id: String, name: String)] = [
        ("no", "Norwegian"), ("en", "English"), ("sv", "Swedish"), ("da", "Danish"),
        ("de", "German"), ("fr", "French"), ("es", "Spanish"), ("auto", "Auto-detect")
    ]
    var model: WhisperModel? { WhisperModel.catalogue.first { $0.id == modelID } }
    var isValid: Bool {
        guard model != nil, Self.languages.contains(where: { $0.id == language }) else { return false }
        return !modelID.hasPrefix("nb_") || ["no", "en", "auto"].contains(language)
    }
}
