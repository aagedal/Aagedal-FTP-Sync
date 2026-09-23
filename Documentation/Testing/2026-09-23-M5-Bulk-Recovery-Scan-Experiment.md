# M5 bulk recovery scan experiment — 2026-09-23

The existing reprocessing profile attributes most large-folder publication time to
fresh recovery admission. Each admission must inspect the destination root again:
a retained transaction can appear while metadata processing is suspended. This
experiment tested whether macOS `getattrlistbulk` could replace the current
`readdir` loop without changing that requirement.

## Method

A disposable directory under `/tmp` contained 50,000 empty files with ordinary
names. A Swift program alternated eight full `readdir` and `getattrlistbulk`
scans of the same directory. The bulk scan requested only `ATTR_CMN_NAME` and
the required `ATTR_CMN_RETURNED_ATTRS`, used a 64 KiB buffer, and parsed every
returned record. Both paths opened a fresh directory descriptor per scan. The
program was compiled with `swiftc -O` on this macOS 27 arm64 development host.
The `readdir` count includes `.` and `..`; the bulk API omits them.

| API | Entries per scan | Median of eight scans | Range |
| --- | ---: | ---: | ---: |
| `readdir` | 50,002 | 0.0481 s | 0.0328–0.0538 s |
| `getattrlistbulk` | 50,000 | 0.3262 s | 0.2771–0.3992 s |

The bulk path was about 6.8 times slower at the median. A first interpreted
Swift run also favored `readdir`, but the optimized compiled run is the relevant
comparison. These are warm-cache microbenchmarks on a shared development host,
not a release workload or an end-to-end reprocessing measurement.

## Decision

Keep the current fresh `readdir` admission. No production change was made: the
bulk API would increase the dominant cost, and this experiment did not justify
weakening late-artifact, cancellation, hidden-name or error handling. The next
performance investigation should profile a full representative reprocessing
batch on a quiet release target before changing the admission design.
