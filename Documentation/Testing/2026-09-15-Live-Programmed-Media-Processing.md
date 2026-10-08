# Live programmed-media processing — 2026-09-15

Test source: `c61a49e` on `codex/version-3-0-plan`; application source includes
`7907b8c`. The tracked development candidate remains the older unsigned
`9f04fad` build and is not promoted by this test. The run used macOS 27.0
(`26A428`), arm64, disposable localhost FTP/implicit FTPS/SFTP services,
isolated server roots and local folders. The JPEG is a generated, decodable
8×8 image with embedded GPS. The `.CR3` payload is deliberately opaque test
bytes, paired with a valid XMP sidecar carrying GPS and an existing keyword.
No private image, recipient, library or model was used.

`AFTPSYNC_TEST_DERIVED_DATA=build/v3-media-live
build/3.0-benchmark-venv/bin/python Scripts/run-remote-transport-tests.py`
passed 14/14 cases with exit 0. The ignored full-run log is
`build/v3-media-full.log`. The focused case also passed with exit 0 at the same
test source; its ignored log is `build/v3-media-focused.log`. Xcode built the
application and test targets without code signing for this integration run.

For each transport, the programmed current-day photographer filter selected
the JPEG, RAW and sidecar. Activated Headline expansion wrote
`Fixture author in Oslo` to JPEG IPTC and the RAW sidecar. The injected offline
place provider wrote City/Country from the images' embedded/XMP coordinates.
The JPEG source and RAW payload bytes remained intact, and the sidecar retained
its existing keyword. A repeated sync transferred no files. A changed
activated Headline was shown by read-only preview without altering the JPEG;
explicit local reprocessing then updated both outputs and again preserved the
RAW bytes. The test checked the server's listed modification timestamp against
the scheduled clip and checked remote staging cleanliness after fixture removal.

The first draft wrote City/Country but left the place-dependent Headline
unresolved, as designed: the fixture had enabled field writes while leaving
the independent `resolveVariables` option off. After enabling that option,
the focused and complete suites passed. This did not require an application
code change.

This closes the disposable real-JPEG/valid-XMP transport, preview and
reprocessing slice. It does not establish proprietary camera RAW decoding,
native activated app UI behavior, a live Apple provider, macOS 14 operation,
external-reader integrity, real-face calibration or release-candidate checks.
