# macOS Expat module

This module exposes the macOS SDK's `<expat.h>` and links the OS-provided `libexpat`.
No third-party parser source or binary is copied into this directory. Xcode's
`SWIFT_INCLUDE_PATHS` points here for the app and its test consumers.

Activated metadata processing uses Expat only to validate bounded original XMP
bytes before the pinned SwiftMediaMetadata parser reads those same bytes. The
pinned parser tolerates malformed XML; Foundation XMLParser/libxml2 was avoided
because the pinned dependency documents interference with ImageIO's libxml2 use.
Expat avoids launching a validator process for each image. DTDs are rejected; no
external entity handler is installed. Legacy metadata writing is unchanged.

This uses an additional system-library API. Actual runtime validation on macOS 14
remains part of the 3.0 supported-OS gate; current-SDK compilation is not that proof.
