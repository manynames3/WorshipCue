# Older iPad compatibility · 2026-10-07

## Current qualification (2026-10-07)

The app remains iPadOS16.0 minimum. Xcode26.6 / iphoneos26.5 compile the Debug app, 13 hosted tests, 3 UI tests and Release app (exit0); the latest UI-source rebuild is recorded in `verification/m0-final-ui-xcode26-build.json`. Release excludes the DEBUG UI-test store flag. Compilation does not qualify original iPad6,7 /16.7.16 execution: its development connection/profile remains unavailable on this Mac. Xcode27 runs the 13 native tests and finger UI verification on the separate iPad7,5 /17.7.11. Actual Pencil, original16.7.16 runtime, pressure/thermal/latency and multi-device gates remain open. Earlier five/six-test and connection records below are historical.


The user requires compatibility with their older iPad, not a forced hardware/OS upgrade. USB reports **iPad6,7**; the user supplied **ML0T2LL/A** and **iPadOS 16.7.16**. Pencil generation is unknown. No app has been installed or operated on it.

## Implemented minimum

D39 now sets **iPadOS 16.0**. App Debug/Release configurations, the reproducible generator, and core/local/ink Swift package platform declarations agree. Scene-phase persistence uses the older SwiftUI callback supported by iOS 16. PDFKit overlays, PencilKit drawing/clipboard, canonical geometry and transactional local storage remain required and implemented; no browser replacement or reduced older-device feature set was added.

Actual device app compilation passes with stable Xcode 27.0. Mach-O and app bundle minimum both report 16.0. Reference/specification/storage/native-macOS checks pass at 55/32/9/4 respectively. These are build/contract/framework checks, not physical handwriting/recovery/alignment evidence. Raw logs and exact commands are in `verification/M0.md`.

## Device testing toolchain

[Apple's compatibility table](https://developer.apple.com/xcode/system-requirements) distinguishes deployment targets from connected-device support. Xcode 27 can build with minimum 16, but connected-device and XCTest library support start at 17. The 16.0 hosted-test build succeeds with explicit warnings that XCTest/Swift support dylibs were built for 17. Those warnings prevent treating it as a usable 16.7.16 test runner.

Stable Xcode **26.6** lists device support from iOS 15 and Swift 6.3 (satisfying the pinned GRDB Swift 6.1 requirement). Its documented host range is **macOS 26.2–26.x**; this host is macOS 27.0.1. Do not claim supported host operation until checked. If it cannot operate here, qualify an appropriate Mac/toolchain or another documented installation/testing path; do not disable Apple protections or silently substitute compilation for runtime testing.

Official Apple silicon archive found on the authenticated [Apple downloads page](https://developer.apple.com/download/all/?q=Xcode%2026.6): **Xcode 26.6 Apple silicon.xip**, **2.16 GB**, published June 25, 2026. It is not a beta/RC.

Save it directly to:

`/Volumes/CRUCIAL 525GB - Data/Projects/general dump/DeveloperTools/Downloads/Xcode_26.6_Apple_silicon.xip`

Chrome's Save Link As dialog permits an explicit destination without changing global downloads preferences. Browser security policy rejected automated access to Chrome downloads settings, so the user was handed that save operation. No archive download/older installation is claimed yet. Do not fill the internal disk (latest 2.6 GiB free) or extract with `xip`'s observed internal staging behavior.

The user subsequently requested that the agent perform the save. Native Chrome's Save dialog was navigated to the exact external folder and Save was clicked. Chrome reported **“Blocked by your organization”** for `Xcode_26.6_Apple_silicon.xip`; external Downloads still contains only Xcode 27's existing archive. Download remains blocked, with no older toolchain installed or qualified. No browser policy/security protection was bypassed.

After the archive arrives, verify Apple's signature, extract with verified Apple tools into a separate external application location, verify the full app signature/Gatekeeper, then check actual host operation and device discovery. Preserve Xcode 27. Use `WORSHIPCUE_XCODE_APP` with the existing scoped wrapper for the alternate app; keep DerivedData/checkouts/temp/results externally. License/admin prompts require direct user handling if needed. Device installation requires legitimate signing and pairing; no certificates/private keys are exported or stored in the repository.

## Qualification required before claiming support

Run the five real hosted native integration tests on iPadOS 16.7.16 with a qualified test runner; verify chart/ink screens, Pencil/palm/finger routing, selected-note copy/placement/undo, exact version/page persistence and team-layer isolation. Then complete force-kill/offline recovery, rotated/nonzero-CropBox alignment at 1×/2×/4×, rapid reuse, resize/resume, disk failure and old-hardware latency/memory/thermal checks in `verification/M0-device-checklist.md`. No physical gate is cleared by a deployment-target setting.

## Current qualification update

The user manually downloaded the official archive; Xcode 26.6 is now installed separately on the external drive, with archive/full-app/Gatekeeper verification all passing. CLI version, first-launch status and iOS 26.5 SDK checks pass. LaunchServices refuses its GUI on this macOS 27 host (-10664); supported device operation remains unqualified.

Explicit SDK/target app and hosted native test builds pass (**0**) with `-parallelizeTargets`, external products/intermediates/packages and minimum **16.0**. Direct binary inspection confirms every embedded app/test framework minimum is <=16.0, removing the Xcode 27 test-library minimum-17 problem for this build. Reference XCTest passes **55 tests, zero failures** under 26.6. These results do not execute the five hosted native tests.

Finder confirms iPad Pro / iPadOS **16.7.16** and an accessible General pane. Instruments still reports Unknown/offline; scheme destination discovery remains ineligible (“iOS 26.5 is not installed”). Component support check reports no new updates. Actual installation, Pencil behavior and all hardware acceptance gates remain unverified.

The user explicitly approved using the existing development signing setup, registering this iPad with Apple, and creating/downloading a profile for `com.worshipcue.spike`. Automatic provisioning downloaded a development profile, but its device list does **not** contain the attached iPad identifier. Signing is paused at Apple's key-access password prompt, which the user must operate directly. Profile download is not evidence of registration or installation. A supported signed-IPA installation route through Apple's free Configurator is being prepared. No enrollment purchase, publication or new certificate/private-key export was performed.

### Latest signing/install qualification

Signing/key access is now complete: two explicit-SDK app builds succeed and the app signature validates (all exit0). The second target build ignores its explicit destination because no scheme was passed; the profile still excludes this iPad. It expires2026-10-14 21:33:01 UTC. This is a signed development app, **not a qualified installable build for this device**.

Configurator2.21 is installed and directly confirms iPad Pro(12.9-inch)/16.7.16(20H392). Xcode27 Device Hub shows no usable device. No app installation or native test execution occurred. The user forbids paid enrollment during development; keep the free Personal Team route. Apple documents free-team devices/profiles as Xcode-managed. A usable compatible Xcode connection is required to finish registration; current unsupported-host26.6 GUI and ineligible destinations have not satisfied that gate.

## Separate17.7.11 execution evidence

The second iPad (6th generation),17.7.11, now pairs with Xcode27 after normal Trust and Developer Mode confirmation. Free Personal Team registration/profile/installation succeeded; all five native hosted tests passed and the actual synthetic chart UI was inspected. The app target remains16.0; no forced OS update or paid enrollment occurred. Final Xcode26.6 app/tests explicit-SDK compile also passed after the runtime-path and restore-test corrections. That final26 build is unsigned (`CODE_SIGNING_ALLOWED=NO`), superseding the earlier signed26 build artifacts while retaining their historical signing logs. It still does not qualify original16.7.16 execution, Pencil interactions, memory/thermal/latency or multi-device behavior. See `verification/M0.md`.

### Touch-input correction compile

After fixing actual PDFKit overlay hit routing with `isInMarkupMode`, using black pen ink for Dark Mode, and exposing finger input selection, the **six** hosted native tests pass on17.7.11. The updated app and all six tests again compile with Xcode26.6 /iphoneos26.5, **exit0**, signing disabled (`verification/m0-xcode26-finger-tests-build.log`). The updated app bundle minimum remains16.0 (`m0-xcode26-finger-minimum.json`). This public PDFKit API is available from iOS16; no newer-only API or raised minimum was introduced. Original16.7.16 installation, runtime and physical qualification still have not occurred.
