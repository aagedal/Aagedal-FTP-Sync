# Metadata and geocoder compatibility probe

An isolated macOS 14 / Swift 6 executable using the same exact SwiftMediaMetadata
2.0.0 pin as FTP Sync. It changes no app settings or user files. Default execution
performs offline lookups and writes/removes synthetic temporary JPEG/XMP fixtures:

```sh
swift run --package-path Tools/MetadataCompatibilityProbe MetadataCompatibilityProbe
```

Explicit opt-in online adapter checks send only fixed public Oslo coordinates
(59.9139, 10.7522) and `en_US` to Apple. Each request has a 20-second cancellation
timer. This probe does not exercise the future production queue/cache/backoff:

```sh
swift run --package-path Tools/MetadataCompatibilityProbe MetadataCompatibilityProbe --online-mapkit
swift run --package-path Tools/MetadataCompatibilityProbe MetadataCompatibilityProbe --online-corelocation
```

MapKit requires macOS 26+. Core Location is the candidate adapter for macOS 14/15;
it can also be exercised on the newer test host. Running a macOS-14-targeted binary
on a newer OS does not verify macOS 14 runtime behavior. Do not count synthetic image
I/O as coverage of every production format or downstream metadata reader.

A failed assertion/request exits unsuccessfully. The default probe checks a 50 km
maximum city distance, missing ocean result, offline Norwegian country localization,
City/Country/Person Shown Unicode round trips, retained caption and identical decoded
JPEG pixels. Build resources and dependency caches are ignored; commit the resolved pin.
