# Voice memo transcription

Open **Settings → Voice Memos**, download a model, and choose the spoken language.
Norwegian Small (NB-Whisper) and Norwegian are the initial selections. Nothing is
downloaded automatically. The catalogue includes Norwegian Tiny/Small/Medium/Large
and multilingual Whisper Tiny/Base/Small/Medium/Large-v3. Downloads use pinned
Hugging Face revisions and verify the exact byte count and SHA-256 before installation.
Models are stored in the application's sandboxed Application Support directory.
Transcription runs locally using the bundled FFmpeg/whisper.cpp runtime.

In a scheduled metadata description, open **Variables…**, enable **Resolve Variables**,
and use, for example:

```
{existingDescription}

{voiceMemoTranscript}
Photo: {photographer}
```

Enable the description's overwrite policy to replace a nonempty caption with the
combined result. Fill-empty continues to preserve a nonempty caption and does not
start transcription for that field. Existing literal descriptions remain literal.
The variable can also be used in other supported template fields; each field's own
IPTC limit still applies.

The WAV must have the same exact filename stem and directory as the image;
the WAV extension is case-insensitive (`DSC0001.JPG` + `DSC0001.WAV`). More than one
matching WAV is ambiguous and is not used. Filename adapters match the original
source identities, so renaming does not accidentally pair an unrelated recording.

## Limits and failure behavior

- Only the first **30 seconds** are decoded to a separate PCM WAV and passed to
  Whisper. Longer recordings are accepted, and the metadata log notes the limit.
- The original WAV must be nonempty and no larger than **64 MiB**. This is checked
  against the listing before remote download and passed as a download bound. FTP
  and other transports may still need to fetch the complete bounded WAV.
- Supported input has 1–8 channels and a sample rate from 8–192 kHz.
- Inference has a three-minute deadline, a bounded output file, and cancellation.
- The **complete expanded description** must fit within **2,000 UTF-8 bytes**,
  including existing text and credits. Norwegian æ/ø/å each use two bytes.
- Missing/ambiguous audio, missing models, transcription failures, and over-limit
  output preserve the affected field. Other resolvable metadata can still apply.
  Incomplete metadata prevents processed-source removal.

A late or changed WAV makes the image eligible for transfer again. A separate
per-image/WAV receipt prevents an independently transferred WAV from being mistaken
for completed image processing. Jobs using voice memo variables wait for the full
listing rather than publishing photos through the early-delivery path.

Reprocessing uses a matching local WAV when available, otherwise it reads the
matching source WAV. A local folder preview can use only WAVs present in that folder.
Normal file filters still control whether WAV files themselves are copied.

`{existingDescription}` accepts an empty existing caption. Conflicting IPTC/XMP
captions or unreadable metadata are left unresolved. When this variable is used to
write a description, a small application-specific XMP namespace stores the original
caption and a digest of the generated caption. Reprocessing uses that original
while the current caption still matches the digest, avoiding duplicate memo text.
External caption edits invalidate the match and become the next baseline. These
properties travel with JPEG XMP or the RAW sidecar; removing them also removes this
reprocessing history. The audit log records status, not transcript text.

Shared calendars using the new variables require the accompanying MetadataSync
server update. Older clients reject the unknown variables rather than expanding them.

## Bundled runtime provenance

The static arm64 FFmpeg binary is the same attributed 9.0.1 build used by Aagedal
Media Converter. Its pre-signing SHA-256, byte count and build-system revision are
in `AagedalFTPSync/Resources/WhisperRuntime/provenance.json`; bundled component
notices are in `FFmpeg-LICENSE.txt`. Xcode signs the helper with sandbox-inheritance
entitlements. Release packaging must accompany this binary with its corresponding
FFmpeg/dependency sources and build scripts, as in Media Converter's attributed
source-companion release process. The model weights are not bundled.
