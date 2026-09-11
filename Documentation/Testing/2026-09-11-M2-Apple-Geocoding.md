# M2 Apple provider and request pacing — 2026-09-11

Implementation commit: `7887a84`, following clean baseline `811e288`.

Development checkpoint; production geocoding settings and pipeline integration remain
pending. This continues the heartbeat triggered on 2026-09-10 at 15:22 UTC.

## Request scheduling

The shared geocoding service now supports an explicit minimum pause after a serial
provider finishes before starting its next request. Offline processing remains unpaced.
Paced configurations require one worker. This conservative pause covers executor delays
and slow native completion rather than measuring only detached task dispatch. An
abandoned provider still owns its slot, and its actual completion starts the pause too.
Only one wake timer is retained; early wakes recheck monotonic time, and queued caller
deadlines/cancellation remain effective during the pause.

Independent review found the initial dispatch-time spacing could permit requests to
start close together after delayed executor scheduling. Completion-based spacing and
a deterministic slow-provider regression corrected that before validation.

## Apple adapter

An inert factory requires explicit permission to send supplied image coordinates to
Apple. It creates no location manager and requests no device location permission.
Actual resolution uses MapKit on macOS 26+ and Core Location on macOS 14/15, with the
frozen concrete locale. It does not parse formatted addresses or guess missing city
names. There is no fallback to another provider or language.

Retain a single service across jobs/previews: it uses one worker, a provisional one-second
pause after completion, at most 16 unique work items and 64 callers. These are initial
bounds, not a throughput or Apple quota guarantee. Native cancellation only signals the
request; the worker remains occupied until the native callback returns. If an underlying
request never completes, callers still reach their deadlines and the bounded queue
cannot start replacement native requests behind it.

Independent review corrected MapKit's no-placemark error to `noResult`; exact error
domain/code checks avoid imposing global provider backoff for a valid empty lookup.
Injected tests cover inert opt-in construction, exact coordinates/locale, cancellation
while the callback remains held, synchronous callbacks, missing fields, constructor
failure and the no-result/error distinction. No request tests contact Apple.

API sources: [MapKit reverse geocoder](https://developer.apple.com/documentation/mapkit/mkreversegeocodingrequest),
[preferred locale](https://developer.apple.com/documentation/mapkit/mkreversegeocodingrequest/preferredlocale),
and [Core Location locale API](https://developer.apple.com/documentation/corelocation/clgeocoder/reversegeocodelocation(_:preferredlocale:completionhandler:)).
Local Xcode SDK headers confirm macOS 26 availability and MapKit address city/region
properties. Building these availability branches does not prove macOS 14 execution.

## Remaining gates

No real Apple network lookup, native GUI observation or supported-macOS runtime pass
is implied by injected request tests. Online activation must remain explicit in the
future job settings; offline must never silently switch providers. The earlier startup
GUI timeout remains open. The RAW existing-sidecar/no-GPS alignment, activated template
context, portable persistence, field policies and source-removal checks remain required
before production enrichment. Candidate identity and manual-test results remain unadvanced.

## Validation

Full suite: **763 discovered, 748 passed, 15 opt-in skips, zero failures**, exit 0
at 2026-09-11 09:09:51 Europe/Oslo; 39.766 seconds. Seven new injected Apple adapter
tests and two pacing tests passed. Source stayed unchanged after this run. Independent
review covered the adapter and pacing fixes; the coordinator inspected integration.

The initial build failed because test NSError constructors require Int while the
MapKit SDK's error codes use UInt. Explicit Int conversions corrected the fixtures;
the failed log is retained separately as `build/m2-apple-geocoding/initial-compile-failure.log`.

```sh
xcodegen generate
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

Environment: Xcode 26.6 (17F113), arm64 macOS 27.0 (26A428), development app 2.9.2 (37).
The installed stable app was not replaced. Dirty state at test time was limited to
this slice's source/project and checklist/evidence documentation.

- Log: `build/m2-apple-geocoding/full-tests.log`
- SHA-256: `87fcc7e16558ba28fcf77376760eaa46ffb94ae655e8794aaba33e2d1eb93d5c`
- xcresult: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/Test-AagedalFTPSync-2026.09.11_09-09-04-+0200.xcresult`

No manual case passed. Checklist instructions now explicitly require both OS adapters
and native callback lifetime/pacing observations. Human result file remains absent.
