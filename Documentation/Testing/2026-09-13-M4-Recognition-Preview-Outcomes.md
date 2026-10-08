# M4 recognition preview outcomes

Recorded 2026-09-13 on branch `codex/version-3-0-plan`.

- Application source: `7cb0844c195da36d47161d54664907952514795f`
- App version remains 2.9.2 (37).
- Candidate status: development only; not ready for user acceptance.

## Implemented

- The read-only metadata preview now presents each file's typed recognition result,
  including detected, accepted, unmatched, ambiguous and quality-filtered counts.
  Rejected, failed and cancelled results use the same privacy-safe reasons as the
  durable audit trail.
- Recognition preview shows existing Person Shown names beside the final proposed
  merged list. It uses the writer's stable, case-insensitive normalization instead
  of presenting accepted names as a replacement.
- When no new identity is accepted, or recognition does not complete, the preview
  says that existing names are preserved. When the job requests Keywords insertion,
  the preview explains that accepted names are appended without removing keywords.
- The new preview content has a per-file accessibility container and all added static
  strings are present in the English string catalog.

The preview still writes nothing. Its visible Person Shown list may contain local
names because the user explicitly requested a file preview; durable recognition
evidence remains redacted and stores no names or person/library identifiers.

## Verification

The focused preview and recognition-evidence selection passed 21 tests with zero
failures or skips. The face-only preview regression now starts with an existing
Person Shown value, admits one new identity, verifies the merged proposal and proves
that the image bytes and folder contents remain unchanged.

The complete application suite passed at the exact source revision:

- 1,141 tests discovered
- 1,125 passed
- 16 opt-in tests skipped
- zero failed

`Scripts/check-security-baseline.sh` passed. An unsigned Release build completed at
`build/DerivedData-recognition-preview-release/Build/Products/Release/AagedalFTPSync.app`.
The executable SHA-256 is
`1f712b5dc10a5c3b08071c7ed46424385caa266d00909b98d097a2783d559fe0`.
Build warnings remained in vendored Citadel/swift-nio-ssh sources.

## Remaining boundary

This closes the source-level per-image recognition presentation gap in preview and
retains the already implemented durable audit disclosure. It is not a native GUI or
VoiceOver observation. Production trust/hosts and signed artifacts, installer UI,
calibrated policy, authorized real-face evaluation, supported-OS execution, resource
tuning, the complete M5 matrix and M6 release checks remain open.
