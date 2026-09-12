# BigInt vendor provenance

- Upstream: `https://github.com/attaswift/BigInt.git`
- Version: `5.7.0`
- Revision: `e07e00fa1fd435143a2dcf8b7eec9a7710b2fdfe`
- License: MIT; retained in `LICENSE.md`

The library source tokens are unchanged from that revision; imported trailing
whitespace was normalized. The local package manifest raises only the watchOS
declaration from 4 to 9 because Xcode 27 diagnoses the upstream declaration as
deprecated during every downstream package resolution. FTP Sync targets macOS 14,
so this manifest-only compatibility change does not alter the application's
deployment target or runtime behavior.
