# M4 bounded face work and job controls

Date: 2026-09-12
App-code commit: `5a4798076c263c9d5cdac6c3e3d843295a2fee86`
Release status: implementation evidence only; production recognition remains disabled.

## Implemented

- `FaceRecognitionAnalysisService` now owns a one-active FIFO worker with
  provisional admission limits for queued work, total staged bytes, faces,
  people, embeddings, comparisons and elapsed time. Invalid limits and every
  rejected boundary have typed, redacted errors.
- A one-shot staged-input lease binds the exact byte charge to the actual image
  URL. Active cancellation and deadline expiry return promptly while retaining
  the worker slot, byte charge and staged-file lifetime until uncooperative
  hidden work exits. Queued cancellation and timeout release immediately.
- The service validates complete analyzer output before publishing any result.
  Release construction remains unavailable until a future identity-bound token
  admits a verified model, preprocessing contract, library and calibrated policy.
- The job editor exposes **Recognize people locally**, **Add recognized names to
  Keywords**, a visible status, and **Manage People Library…**. It explains that
  accepted names append to Person Shown and that recognition never enrolls new
  reference faces automatically.
- A stopped job may retain future recognition settings. Saving or starting a job
  that requests the unavailable runtime fails closed. **Start All** starts
  eligible jobs while keeping blocked face jobs stopped and reports their names.

The numeric ceilings are safety limits, not accepted performance budgets. The
standard comparison cap is intentionally conservative and needs measurement
against representative large libraries before production admission.

## Review and verification

Independent review found three material boundaries: staged-file lifetime could
end before hidden work, an unsaved draft was described as saved, and direct
enable/Start All paths could create an automatic retry loop. All three were
fixed. Final independent review reported no commit blockers.

- Focused result:
  `build/DerivedData-face-bounds-ui/Logs/Test/Test-AagedalFTPSync-2026.09.12_18-04-50-+0200.xcresult`
- 31 passed, zero failed, zero skipped across the complete analysis-service and
  settings suites plus the activation admission case.
- A macOS Release build passed with code signing disabled using
  `build/DerivedData-face-bounds-ui-release` after the final source changes.
- `git diff --check` passed before the app-code commit.

## Remaining production blockers

- One application-owned worker must be bound to an identity-checked production
  runtime; per-service seriality alone does not prove global seriality.
- Photo Agent must produce deterministic schema-2 ZIP32 packages, and the two
  apps need a shared App Group design before automatic library sync can ship.
- AuraFace BGR/RGB preprocessing requires committed cross-runtime reference-vector
  proof. The real model, production key and fixed distribution hosts remain absent.
- Durable audit needs an additive redacted recognition decision containing typed
  status, aggregate counts and immutable provenance. It must exclude names,
  person/library identifiers, embeddings, scores, geometry, paths and provider text.
- Job UI still needs model state and per-image outcomes from the production runtime.
  Native keyboard, VoiceOver, actual-image, supported-OS, calibration and resource
  measurement gates remain open.
