# Shared control-codec fixtures

This document covers the original shared `session.hello` codec and its fixtures, not the complete production transport. Production pairing, mutual TLS, transfers, clipboard, SMS, and notifications are implemented in the platform transport code. Parsers alone do not establish trust.

## Framing

Each frame consists of a four-byte unsigned big-endian payload length followed by that many UTF-8 JSON bytes. Valid payload lengths are 1–524,288 inclusive. Zero and oversized lengths are rejected before payload allocation. TCP read boundaries are irrelevant: parsers accept split headers, split payloads, and multiple frames in a read.

On parse error the caller must close the session. Parsers reset their internal state, but this is not permission to continue an invalid network session.

## Hello

See [the shared fixture](fixtures/hello.json).

- `protocolMajor`: integer 1; other versions rejected.
- `protocolMinor`: nonnegative integer.
- `type`: `session.hello`; other operations are outside this fixture codec.
- `messageId`: canonical UUID string, case-insensitive.
- `sessionId`: nonempty string, maximum 128 UTF-8 bytes.
- `body.deviceName`: nonempty string, maximum 128 UTF-8 bytes.
- `body.capabilities`: at most 32 unique nonempty strings, each at most 64 UTF-8 bytes.

Unknown fields may be ignored. Missing or incorrectly typed required fields are errors. JSON field ordering is not significant. Names and session IDs are display/correlation metadata, never authentication evidence.

Swift and Kotlin tests consume the same fixtures and exercise every split position, coalesced frames, bytewise delivery, invalid lengths, unsupported versions, and malformed payload recovery.

For the production wire format and handlers, see `Channel.swift` and `CompanionServer.swift` in `apps/macos/Sources/CompanionTransport`, and `PeerClient.kt` in `apps/android/app/src/main/java/dev/companion/android`.
