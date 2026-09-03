# GPS Metadata and Photographer Map Implementation Plan

## Goal

Allow each metadata schedule clip to carry an optional GPS position, write that
position to matched images, and provide a map window that shows every
photographer's scheduled position at a selected point in time.

## Progress

- [x] Add the GPS position model, validation, active-position resolution, and
      backward-compatible persistence tests.
- [x] Write GPS to embedded Exif and RAW XMP sidecars while honoring the existing
      fill-empty/overwrite policy.
- [x] Add location editing to the metadata clip editor and a location indicator
      to timeline clips.
- [x] Add a Photographer Map window with job/date selection, a time scrubber,
      change-point navigation, and photographer markers.
- [x] Add entry points from Metadata Programming and the menu bar.
- [x] Run targeted tests, the full unit-test suite, and a clean application build.

## Product Rules

- Location belongs to a schedule clip, not to the permanent photographer profile.
- A photographer appears on the map only while a clip with a location is active.
- Clip intervals retain the existing half-open rule: `start <= time < end`.
- Latitude and longitude are treated as one atomic value when preserving or
  replacing existing metadata.
- Missing locations are never inferred from an earlier clip.
- GPS coordinates are exported with metadata programming, but remain independent
  of reusable headline/description/keyword presets.

## Verification Targets

- Old JSON without GPS still decodes.
- Invalid and non-finite coordinates are rejected.
- Position changes occur exactly at clip boundaries.
- Embedded-image and XMP-sidecar writes both preserve or overwrite GPS correctly.
- Copy, paste, day export, and configuration transfer retain clip locations.
- The map handles no job, no clips, missing locations, overlapping coordinates,
  and day changes without crashing or moving the selected time unexpectedly.

## Verification Results

- Application build succeeded with code signing disabled.
- GPS-focused metadata automation and writer tests passed.
- Full suite passed: 305 tests executed, 9 skipped, 0 failures.
- `git diff --check` passed.
- Automated UI attachment timed out for the menu-bar-only debug app, so the map
  and editor were source-reviewed but not claimed as visually smoke-tested.
