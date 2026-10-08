# Portable domain reference

This package contains small, dependency-free Swift domain rules: latest-only live announcements, explicit race-safe opening, preferred-version resolution, musical-key mismatch, Korean search, and team-layer identity. It is an executable specification that may be adopted into the production domain module.

It is NOT a native iPad app, server implementation, offline store, permission system, PDF renderer, or drawing adapter. Passing its tests does not prove any of those implementations correct. In particular, `fileVerified` must be supplied by a real checksum/parser/download adapter; it is not a security control. Production call authorization and revisions belong to the server.

```sh
swift test --package-path reference/WorshipCueCore
```
Run this command from the handoff root. The package supports Swift Package Manager on Linux for portable rule testing and is intended to remain free of UIKit/PencilKit/Supabase dependencies. Native rendering/geometry tests belong to the Xcode targets Codex creates in M0.
