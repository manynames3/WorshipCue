# Project state
Updated: 2026-10-07

## Current state

Build2 adds an eight-color compact popover with independent remembered pen/highlighter preferences and the approved teal ribbon-W app icon. The color and black-pen UI workflows (2 cases) and2 focused native cases pass on17.7.11; Xcode27 Release builds pass. A full14-case native rerun was interrupted after a device-connection stall, and Xcode26.6 asset compilation is runtime-blocked. Earlier M0 baseline evidence below remains historical. See `verification/M0-colors-icon.md`.
A native M0 reliability app is implemented and installed on the connected iPad (6th generation), iPadOS17.7.11. Free Personal Team signing and device provisioning are configured with user authorization; no paid enrollment, hosted backend, cloud deployment or repository push occurred.

Prior full M0 baseline: 13/13 hosted native tests and 2/2 independently qualified UI workflows (drawing/save/relaunch and read-only team isolation) pass on iPad (6th generation), iPadOS 17.7.11. The final corrected transfer UI recheck is blocked by test-runner connection failures; an earlier full functional transfer workflow passed and the current black preview was visually inspected. Physical Apple Pencil and original iPadOS 16.7.16 runtime qualification remain NOT VERIFIED. PDFKit markup routing is enabled; the annotation layer is pinned to Light appearance so PencilKit cannot render white pen ink on white PDF paper in Dark Mode. The visible Korean input selector and selected-tool checkmarks remain. Builds, package caches and device symbols are external; Apple profiles/system caches partly remain internal. Free Personal Team signing only. Historical failures below are preserved.

Implemented: native PDFKit/PencilKit reader, immutable PDF import, transactional personal-ink save/restore, manual selected-note transfer and exact-context read-only team sample, plus the portable reference model, contracts, fixtures and tests. See `verification/M0.md` for the current native evidence and `verification/REPORT.md` for reference evidence.

## Next milestone
M0: repository/toolchain inventory, local iPad PDF/PencilKit reliability spike, and physical-device ink testing. Read `docs/12_BUILD_PLAN.md`.

## External prerequisites (not reasons to stop all work)
- macOS with a supported stable Xcode for native building.
- Actual Apple Pencil qualification and two-device integration remain required. Known hardware: original iPad Pro (12.9-inch),16.7.16 and iPad (6th generation),17.7.11. Only the latter has a qualified development connection; Pencil generation remains unknown.
- Supabase development project configuration when M2 begins, or local Supabase tooling for backend tests.
- Apple signing/TestFlight configuration before distributing to the church.
- Administrator-authorized, appropriately licensed real church charts for the actual pilot.

## Not yet validated
Apple Pencil UX; PDF rendering under real-device pressure; physical selected-note transfer; Supabase migrations/RLS/RPCs; actual network performance; latest iPadOS behavior; App Store approval; church willingness to pay. Minimum target is iPadOS16.0 under D39; original16.7.16 physical qualification remains required.

## Update format
After each milestone append date, implementation status, exact test commands, device/OS details, failures, limitations, and next milestone. Keep “implemented,” “automatically tested,” and “physically verified” distinct.

## 2026-10-07 · M0 first native vertical slice

Status: **IMPLEMENTED IN SOURCE; PORTABLE CHECKS PASS; NATIVE/DEVICE GATE NOT VERIFIED**.

The handoff was extracted into this new workspace folder without overwrites. No prior native app or Git checkout existed here. Existing reference/domain sources, contracts/specifications, original evidence and neighboring projects are preserved. No cloud account, remote, signing setup or deployment was changed.

Added iPad target `apps/ipad/WorshipCue.xcodeproj`, shared scheme `WorshipCue`, SwiftUI/PDFKit/PencilKit reader, fixture/Files import with verified immutable app-owned PDFs, canonical CropBox transforms, transactional personal-ink store/recovery, app-owned selected-stroke transfer preview/commit/cancel/undo, and exact-context read-only local team sample. The app deliberately reuses `reference/WorshipCueCore` as its pure production domain package; `packages/WorshipCueLocal` pins the selected GRDB 7.11.1 dependency. No automatic song changes, page syncing or note merging was added.

Actual host: macOS 27.0.1 arm64, Swift 6.4, selected Command Line Tools only; full Xcode/iOS SDK/simctl/XCTest absent. No real iPad/OS/Pencil/signing configuration was verified.

Executed:

```sh
swift test --package-path reference/WorshipCueCore
swift build --package-path reference/WorshipCueCore
/tmp/worshipcue-reference-verification-venv/bin/python3 scripts/verify_package.py
swift run --package-path packages/WorshipCueLocal InkChecks
python3 scripts/verify_m0_project.py
swiftc -frontend -parse apps/ipad/WorshipCue/*.swift apps/ipad/WorshipCueTests/*.swift
sh scripts/check_m0_environment.sh
xcodebuild -project apps/ipad/WorshipCue.xcodeproj -scheme WorshipCue -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
sh scripts/test_ipad.sh
```

Results: reference Swift library build passed; Python reference suite **32 passed** after installing its existing test dependency in an isolated venv; production local-store/geometry executable **9 check groups passed**, including write rollback, delayed restore and corrupted identity. Project resource/scheme checks and native Swift syntax parse passed. Fresh reference XCTest **failed before running tests** (missing XCTest). Native build/test commands **failed before native compilation/execution** (full Xcode absent). Original manifest **56/56 matched before edits**. These failures are preserved, not downgraded to passing evidence.

With supported Xcode installed, valid checked-in project/scheme commands are `sh scripts/test_ipad.sh` (build then actual available iPad simulator discovery/test) and `sh scripts/check_m0_environment.sh` (inventory). No simulator UUID was invented; none could be discovered on this host.

Five native integration tests exist but remain NOT RUN. Actual Pencil selection/writing, force-kill recovery, rotated/CropBox alignment, gesture routing, iPad restart/resume/memory/thermal behavior and performance measurements remain NOT VERIFIED. Minimum target remains provisional iPadOS 18.0 pending oldest-device inventory. See `verification/M0.md` for exact results/risks and `verification/M0-device-checklist.md` for required device evidence.

Next: finish M0's unverified native/device gate, then M1. No pilot-ready claim; M1/backend work was not started in this task.

### Continued M0 verification and UI concepts

The production selected-stroke clipboard is now shared in `packages/WorshipCueInk` and linked to both native targets. `sh scripts/check_macos_frameworks.sh` compiles/runs real macOS PencilKit/PDFKit checks against production clipboard/storage: **4 framework check groups passed**, exit 0. These add actual drawing archive recovery and uniform selected-stroke placement evidence without claiming iPad adapter verification. Initial failed scaling assertion and bare-CLI framework trap logs remain preserved; measured whole-point render-bound rounding was resolved with exact path-coordinate and bounded-render-box checks. See `verification/M0.md` for details.

Two potential high-end native UI concepts are saved in `docs/ui-concepts` with prompts/notes: calm music stand and contextual version/note transfer. They are generated proposals, not app screenshots or an M1/M4 implementation claim. M0 native build/test/device gates remain NOT VERIFIED because Xcode/iPad/Pencil access is still absent.

Recent committed drawing archives are pruned after view eviction/commit when no restore/save operation is outstanding, while pending unsaved ink remains retained. Native memory qualification remains a device gate.

### External Xcode installed; first launch pending

Stable **Xcode 27.0 / 27A266a** is installed at external `DeveloperTools/Applications/Xcode.app`. The official archive signature, full app signature and Gatekeeper assessment passed (exit 0); the scoped wrapper reports the actual version (exit 0). Native scripts use external DerivedData/package checkouts/temp/module caches. App Store offered no eligible external disk; its setting was restored. Apple Developer sign-in and official download completed. Extraction used Apple's `xar`, `compression_tool`, and `ditto` after interrupted `xip`/generic `tar` failures; exact failures and preserved logs are recorded in `docs/13_EXTERNAL_XCODE_SETUP.md`.

**Current blocker: Apple license/admin first-launch setup.** SDK inventory, first-launch status and native test script exit **69**; no iPad compilation/tests ran. External Xcode reference Swift test exits **1** because its SDK lookup is license-blocked (underlying 69). Fresh Python reference verification **32 passed**, project structure and setup shell syntax checks passed. The user was asked to review/accept the license and complete administrator setup directly in the external Xcode app. Latest free space was 4.3 GiB internal / 220 GiB external; simulator downloads have not been started. iPad/Pencil/signing/device requirements remain NOT VERIFIED; M0 is still open.

### Xcode first launch complete; native compilation verified

The user accepted the license/completed setup and approved Xcode UI control. `xcodebuild -showsdks` and `-checkFirstLaunchStatus` now exit **0**; the iOS 27.0 device and simulator SDKs are available. `sh scripts/with_external_xcode.sh swift test --package-path reference/WorshipCueCore` exits **0**, **55 tests, zero failures**.

The first actual native build failed (exit **65**) on a fixture-import `catch` assignment that shadowed the model's error property. Fixed it to `self.error`. Added an explicit `@preconcurrency` PDFKit overlay-provider conformance to preserve main-actor isolation/runtime checks across the Objective-C protocol boundary and remove the compiler isolation warning. Final generic iOS Simulator **build** and **build-for-testing** both exit **0**. All five hosted native tests compile; they have not executed. Exact commands and original/final logs are in `verification/M0.md`.

Xcode Settings now use external `DeveloperTools/Xcode/DerivedData` and `DeveloperTools/Xcode/Archives`; the GUI compilation cache follows external DerivedData automatically. Existing caches were not deleted or mass-symlinked. CLI build/package/temp locations remain external under `DeveloperTools/WorshipCue`. The actual `WorshipCue.xcodeproj` is open in Xcode, scheme `WorshipCue`.

**Remaining blocker: no installed simulator runtime or qualified connected iPad.** `simctl` reports an empty runtime list. `sh scripts/test_ipad.sh` builds successfully, then exits **1** with “no installed available iPad simulator”; no native tests run. Xcode offers iOS 27.0 at 8.05 GB, with no external install path in the inspected component controls. Latest free space is **2.9 GiB internal / 219 GiB external**; optional runtime downloads were not initiated. Need sufficient internal headroom or authorized real-iPad setup. Physical writing, gesture/alignment/durability/memory/thermal gates remain NOT VERIFIED; M1 has not started.

The user selected real-iPad testing and connected by USB. Device `build-for-testing` with generic iOS destination/signing disabled exits **0**. USB inventory sees an iPad; CoreDevice reports **iPad6,7**, booted, pairing **unsupported**, incomplete information. Instruments lists it as Unknown/offline. Requested Model Name/iPadOS Version from the iPad's About screen to resolve compatibility with the provisional iPadOS 18 minimum. No installation, signing change or physical test is claimed.

The user confirmed **ML0T2LL/A**, **iPadOS 16.7.16**. It cannot run the current 18.0 app target; Xcode 27 connected-device support also starts at iOS 17 per [Apple requirements](https://developer.apple.com/xcode/system-requirements). Lowering the target alone does not resolve the toolchain/device blocker. No target/OS/signing change was made. Native execution needs an iPad running iPadOS 18+, sufficient storage for a simulator runtime, or separately authorized older-device compatibility work. Exact device requirements remain in `verification/M0-device-checklist.md`.

### User requires older-iPad compatibility; minimum amended to 16.0

The user explicitly required compatibility with older iPads like this device. D39 is amended accordingly. App Debug/Release targets, reproducible project generator and all three local Swift packages now target **16.0**. Scene lifecycle saving uses the iOS 16 SwiftUI `onChange` callback; no PDF/ink/selected-transfer/storage behavior was removed.

Unsigned generic iOS `build-for-testing`: **exit 0**, app and hosted tests compile (`verification/m0-ipados16-device-build.log`). Actual app Mach-O `LC_BUILD_VERSION` and bundle `MinimumOSVersion` both report **16.0** (`m0-ipados16-binary-minimum.log`). **The test build warns that Xcode 27 XCTest/Swift support libraries require iOS 17; it is not runnable test evidence on iPadOS 16.** Post-change reference suite **55 passed**; Python specifications **32 passed**; production storage/geometry **9 groups passed**; real macOS PDFKit/PencilKit **4 groups passed**. Structure and script syntax checks pass.

Stable Xcode **26.6 Apple silicon** was located on Apple's authenticated official downloads page (2.16 GB). Apple lists connected-device support from iOS 15, but its documented host range stops at macOS 26.x; usability on this macOS 27 host still needs actual verification. Browser download-settings access was blocked by browser security policy. With only 2.6 GiB internal free, the user was asked to save the archive directly into external `DeveloperTools/Downloads` through Chrome's Save Link As dialog. No older Xcode has been downloaded/installed yet and current Xcode 27 is preserved. No signing/profile/OS changes or app installation occurred. See `docs/14_OLDER_IPAD_COMPATIBILITY.md`.

The user then asked the agent to perform the download. Native Chrome Save Link As selected the correct external Downloads folder and filename; clicking Save resulted in **“Blocked by your organization.”** Directory inspection (exit 0) confirms only the existing Xcode 27 archive, with no older archive/partial file. No browser policy was bypassed. The current download restriction requires user/administrator resolution; older-toolchain host/device qualification and physical iPad tests remain pending.

### External Xcode 26.6 compiled the iPadOS 16 slice

The user's manual download completed. Xcode **26.6 / 17F113** is installed separately at external `DeveloperTools/Applications/Xcode-26.6/Xcode.app`; official archive, full app signature and Gatekeeper checks all exit **0**. CLI version/first-launch/SDK checks pass; iOS SDK is **26.5**, Swift **6.3.3**. Its GUI is rejected on macOS 27 (-10664), outside Apple's documented macOS 26 host range. Existing Xcode 27 remains preserved.

Generic-device retries retained exact failures: initial stall stopped (**143**) during internal-disk exhaustion; retry after user space cleanup (**70**), no eligible iOS destination. Explicit SDK/target app build succeeds (**0**); test target succeeds (**0**) with documented `-parallelizeTargets`, following an initial manual-order dependency cycle (**65**). All five native tests compile, **zero execute**. App and every embedded app/test binary minimum are <=16.0. Alternate-toolchain reference suite: **55 tests, zero failures**, exit **0**. See `verification/M0.md` and `docs/13_EXTERNAL_XCODE_SETUP.md` for exact commands/logs/storage exceptions.

Finder confirms the USB-connected **iPad Pro / 16.7.16**; Instruments still lists Unknown/offline and scheme destination discovery remains ineligible. Component update check exits 0 / no newer updates. No simulator runtime was downloaded.

User explicitly approved existing development signing, this iPad's Apple registration, and a `com.worshipcue.spike` development profile. Automatic provisioning downloaded a profile, but inspection shows it does **not** include this iPad. Signing currently waits at Apple's password/key-access prompt; Codex safety policy rejects operating SecurityAgent, so direct user handling was requested. Apple Configurator installation was initiated from the official free Mac App Store listing (Apple, 76.8 MB), currently pending Store authentication. No signed-build completion, this-iPad registration, IPA installation or physical test is claimed yet. No private key or credential was exported. M0 remains open.

### Signing completed; free-account/device gate remains open

The user requires **no paid Apple Developer Program enrollment during development**; they intend to purchase membership when ready for customer release. Do not enroll, purchase, or introduce a paid workaround. Existing free Personal Team signing is permitted.

Both explicit-SDK signing builds exit **0 / BUILD SUCCEEDED**. Deep/strict app signature validation exits **0**, valid on disk/satisfies Designated Requirement. The local development profile expires **2026-10-14 21:33:01 UTC**, but its single provisioned device is **not** the connected iPad (case-insensitive UDID comparison). The second target build supplied the iPad destination; Xcode explicitly warned it ignored that destination because no scheme was passed. It did not register this iPad. Raw redacted evidence: `m0-xcode26-signing.log`, `m0-xcode26-signing-validation.log`, `m0-xcode26-signing-connected.log`, `m0-xcode26-connected-profile.log`. An evidence-wrapper NameError occurred after the second native command succeeded; postprocessing was corrected without repeating the build.

Apple Configurator **2.21** is installed from Apple's official free Mac App Store listing at `/Applications/Apple Configurator.app`; its full signature verification exits **0**. Its Info pane confirms **iPad Pro (12.9-inch), booted, iPadOS16.7.16 (20H392)**. Device serial/UDID/network addresses were omitted from repository evidence. No Prepare/Restore/supervision/sync action was performed. Xcode27 Device Hub remains empty after selecting All Devices. Current Apple account page offers enrollment and no device/profile management tools; free Personal Team assets are managed through Xcode per Apple documentation.

Key access completed sufficiently for signing success; it is no longer the active blocker. The remaining blocker is **a development profile containing this iPad and a usable compatible development connection**. Current Xcode26.6 scheme destinations remain ineligible and its GUI cannot launch on macOS27; Xcode27 development-device support excludes16. A compatible supported Mac/Xcode connection remains necessary unless another documented free registration route is verified. Configurator access alone cannot create that profile. No IPA installation or physical native/Pencil test is claimed. Latest storage observation: **1.7 GiB internal / 199 GiB external**; no simulator download was initiated. M0 still requires native test execution and the physical checklist.

Post-Configurator Xcode26.6 device inventory repeated after the newly installed utility confirmed USB access: **exit0**, still **Unknown/offline** (`verification/xcode26-configurator-device-inventory.log`). Current project/resource/scheme/localization check repeated after final documentation edits: **exit0**. No physical gate changed.

### New iPadOS17 test device connected · 2026-10-07

The user connected another iPad, reporting **iPadOS17.7.11**. USB/CoreDevice inventory identifies **iPad7,5**; Configurator confirms **iPad(6th Generation)** and displays a lock icon with incomplete OS details. CoreDevice lists booted/pairing unsupported/tunnel unavailable, and Xcode27 Instruments still lists Unknown/offline. This reported OS falls within Xcode27's listed17+ device support, so the macOS26 testing environment discussed for the original16.7.16 iPad is not yet needed for this newer-device attempt. Do not assume OS verification, pairing, profile inclusion or installation from that support table.

Requested unlock/awake/Trust confirmation and Developer Mode status for the new iPad. No device erase/update/supervision, new signing attempt, registration, installation or test execution occurred in this locked state. App minimum remains16.0; the older16.7.16 physical gate remains open. Free Personal Team/no paid enrollment restriction persists. Redacted inventory is `verification/m0-ipad17-connection.json`; raw identifiers stay in external Temporary. Native tests executed on this device: **zero**. Computer-control pipe closed while selecting the new Finder device; no substitute UI-control mechanism was used.

After the user unlocked the second iPad, CoreDevice verifies **17.7.11**, wired/unpaired/tunnel disconnected. Device Hub now displays this iPad and **“Pairing Required”**, instructing Trust on the device. `devicectl manage pair --device <private CoreDevice identifier> --timeout45 --json-output <external Temporary file>` times out at45 seconds before Trust completion; the JSON outcome is timeout (native command exit was not separately retained by the evidence wrapper). Requested direct iPad Trust/passcode completion. The user reports Developer Mode off/missing; no setting was changed by the agent. No new app registration, installation or test execution yet. The initial locked-state record above is historical; current blocker is Trust pairing.

The user confirmed Trust on the second iPad. Finder independently confirms iPadOS17.7.11. A Finder sync/backup was observed automatically running on the internal drive and stopped using its Stop control; subsequent UI shows Sync/Back Up Now instead of active backup, confirming cancellation. No backup data was deleted and sync preferences were not changed. Latest internal free space1.2GiB /external199GiB. After Trust, CoreDevice pairing again times out45seconds, **native exit2** (`m0-ipad17-pair-trusted.log`). Apple's `/usr/bin/devmodectl list` **exit0** confirms the new iPad's Developer Mode is **disabled**; no other listed device was operated. Requested direct Settings→Privacy & Security→Developer Mode enable/restart/confirmation. `devmodectl help single` was read only; no Developer Mode setup command executed. No registration/install/native test pass is claimed.

The user reports Developer Mode still missing. `/usr/bin/devmodectl single <new-iPad-UDID>` **exit1**, “Failed to arm: Device has a passcode set”; subsequent status read **exit0**, still disabled. No passcode/security setting was removed or changed. Normal Xcode27 scheme/device **build exit70**, “Unable to find a device matching the provided destination” (`m0-ipad17-scheme-build.log`); no native compile/install/test pass follows from it. A scheme destination query **exit0** lists generic devices/My Mac but no usable real iPad (`m0-ipad17-destinations.log`).

Configurator's Activity list was empty, then its idle app was quit through its normal app menu and absence in the running-app inventory verified. This changed the diagnostic condition without canceling a Configurator operation. CoreDevice pair with Configurator closed **exit1**, no RemotePairingDeviceRepresentation (only RestorableDeviceRefDeviceRepresentation); lock-state query **exit1**, no supported usage assertion. This does not prove a specific cause of the missing setting. Apple's bundled cfgutil restricted to this iPad returns **isPaired=true, isSupervised=false, pairingAllowed=true, OS17.7.11**; aggregate command **exit1** (partial property response), preserved as such in `m0-ipad17-classic-properties.json`. USB trust and development pairing are distinct findings. Requested one normal iPad restart/reconnect/unlock and keeping it awake for the next retry. No erase, privacy reset, enrollment purchase, successful new-device registration or app installation occurred.

### Development pairing succeeded; Developer Mode is the next gate

After the user confirmed a normal iPad restart/unlock, CoreDevice pairing still timed out at25 seconds (**exit2**, `verification/m0-ipad17-pair-postrestart.log`). Apple's bundled Configurator `cfgutil --ecid <new-iPad-ECID> --timeout10 pair` then succeeded (**exit0**, one device, `verification/m0-ipad17-classic-pair.log`). The immediate CoreDevice inventory remained unpaired and Developer Mode disabled; classic USB pairing alone did not prove development readiness.

The Xcode27 Device Hub subsequently offered a **Pair** button. Clicking it changed the visible screen to **Enable Developer Mode**, directing Settings→Privacy & Security→Developer Mode. A subsequent CoreDevice inventory **exit0** now reports **paired**, tunnel unavailable. This resolves the development-pairing step. Requested direct iPad Developer Mode enable/restart/Turn On confirmation; the agent cannot perform those iPad-screen confirmations through the current Mac-only control tools. No registration/profile inclusion, app installation or native test execution is claimed. The free Personal Team restriction and original16.7.16 physical qualification gate remain in effect.

### Native device execution passed · final status 2026-10-07

Device: **iPad (6th generation), iPad7,5, iPadOS17.7.11 (21H461)**. The user enabled Developer Mode, confirmed developer-certificate trust, and completed the device's normal Screen Time approval. CoreDevice verifies enabled Developer Mode, paired/wired/connected tunnel and available development services.

| Check | Exact outcome | Evidence |
| --- | --- | --- |
| First build during preparation | exit70; device selection failed. The final destination list contained the iPad; retry used its exact listed identifier | `m0-ipad17-enabled-build.log` |
| Prepared iPad scheme build, Automatic free Personal Team, registration/provisioning updates permitted | exit0 / BUILD SUCCEEDED | `m0-ipad17-prepared-build.log` |
| Embedded profile decode, deep/strict signature | exit0 each; connected iPad included; app minimum16.0; profile expires2026-10-14T22:45:20Z | `m0-ipad17-signed-validation.json` |
| Native app installation | exit0 | `m0-ipad17-install.log` |
| First launch / first hosted test attempt before certificate trust | launch1 / test65; explicit Developer App Certificate not trusted, zero tests ran | `m0-ipad17-launch.log`, `m0-ipad17-native-tests.log` |
| Launch after direct user trust | exit0; process launch accepted (does not independently prove sustained render) | `m0-ipad17-trusted-launch.log` |
| First trusted test attempt | exit65, zero tests ran; dyld could not resolve bundled package frameworks because the generated app lacked its Frameworks runtime path | `m0-ipad17-trusted-tests.log` |
| After runtime-path fix | exit65; five executed, four passed, one restore archive re-encoding assertion failed (775 vs753bytes) | `m0-ipad17-runpath-tests.log` |
| Final native hosted tests | **exit0; five executed, five passed, zero failures**, suite0.349seconds; this is automated suite duration, not Pencil/save latency | `m0-ipad17-content-tests.log` |
| Final app launch after testing | exit0; then music stand visually inspected on actual USB display | `m0-ipad17-final-launch.log` |
| Final Xcode26.6 explicit SDK/app+hosted-test compile | exit0 / BUILD SUCCEEDED; native tests were not executed on16.7.16 | `m0-xcode26-final-tests-build.log` |

The runtime fix adds `$(inherited) @executable_path/Frameworks` to app Debug/Release and adds that path plus `@loader_path/Frameworks` to hosted tests. Both the project and generator agree; regeneration was checked to alter only these four build configurations, preserving source membership/resources/scheme. No production dependency or feature behavior changed.

The initial restore failure was an invalid expectation of stable PencilKit re-encoding after new canvas attachment. **The byte-exact SQLite archive assertion remains unchanged and passes.** Restored drawing verification now compares bounds, ordered stroke count, ink type/color, transform, mask/ranges, random seed, creation date, and every point's location, size, time, opacity, force, azimuth and altitude against the decoded committed archive. All exact content assertions pass on17.7.11. This is not a relaxation of note durability, position or identity requirements.

Five passing tests: canonical PDFKit/rotated CropBox canvas alignment at1/2/4x; save/version-switch/overlay recreation isolation; personal paste undo without modifying team ink; real PencilKit archive/store reopen; selected clipboard surviving source closure and preserving uniform scale. These use synthetic programmatic ink, not physical Pencil strokes.

Executed test command (private identifiers are redacted in repository logs; full local logs remain in external Temporary):

```sh
. scripts/external_xcode_env.sh
xcodebuild -project apps/ipad/WorshipCue.xcodeproj -scheme WorshipCue -configuration Debug \
  -derivedDataPath "$worshipcue_build_root/DerivedData-Xcode27-iPad17" \
  -clonedSourcePackagesDirPath "$worshipcue_build_root/SourcePackages" \
  -destination 'platform=iOS,id=<exact discovered iPad UDID>' -destination-timeout 30 \
  -resultBundlePath '<fresh external result bundle path>' \
  SDK_STAT_CACHE_DIR="$worshipcue_build_root/DerivedData-Xcode27-iPad17" \
  DEVELOPMENT_TEAM='<existing free Personal Team>' CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -parallel-testing-enabled NO test
```

Actual final result bundle: `/Volumes/CRUCIAL 525GB - Data/Projects/general dump/DeveloperTools/WorshipCue/Results/M0-iPad17-InkContent-20261007-184959.xcresult`. No UUID was invented; the retry copied the lowercase destination identifier exactly from Xcode's observed list. The earlier uppercase attempt failed during device preparation; case sensitivity versus preparation timing was not independently isolated.

Visual evidence: Device Hub screen sharing reports a27+ requirement on this17 device. QuickTime's documented USB Screen input successfully displays the real iPad without starting recording (ZeroKB). After the user cleared the observed Screen Time limit through normal device controls, the current synthetic v1G/page1-of2 PDF, Korean tools, local page buttons and saved-on-device footer were visually inspected. The horizontally scrolling tool strip extends beyond the portrait viewport by design; no automatic song/page actions were added.

Storage: Xcode downloaded a new4.0GiB per-device symbol cache internally, exhausting available space and causing a temporary screenshot/temp-file failure. Moved only that newly generated cache to external `DeveloperTools/WorshipCue/DeviceSupport/iPad7,5 17.7.11 (21H461)` and retained a **per-device user-cache symlink** at `~/Library/Developer/Xcode/iOS DeviceSupport/…`.882 relative file/link entries and sizes match before/after. Internal free space recovered to4.2GiB; later app launch/USB preview work. This is distinct from system-directory relocation; global xcode-select remains unchanged. Symbol lookup performance was not measured. Apple profiles, xcrun and some system temporary data remain internal. See `m0-ipad17-symbol-storage.json`.

Still **NOT VERIFIED**: original16.7.16-device runtime/Pencil behavior, physical Pencil/palm/finger routing and lasso interactions, airplane-mode force-kill cold recovery, interrupted save/full-device-disk behavior, actual rotation while writing, memory/thermal two-hour soak, multi-iPad behavior and latency targets. The hosted tests clear the native automated execution gate for17.7.11 only. **M0 is not fully device-qualified or pilot-ready; M1/backend/live sync have not started.** Free development signing expires after seven days and needs reprovisioning; no paid enrollment or purchase occurred.

### Touch-input bug reproduced and fixes installed · 2026-10-07

The user confirmed pen/highlighter still did not draw after enabling the old finger-test toggle. Added a hosted regression against the actual PDFKit-installed overlay: exit65, one failure before enabling `PDFView.isInMarkupMode`; exit0 after that public-API fix. A Dark Mode assertion separately reproduced white `.label` pen ink (exit65); black pen ink resolves it. Added visible Apple Pencil / 손가락 필기 input selection, Korean guidance and selected-tool checkmarks.

The same scoped device command above with fresh result bundle `DeveloperTools/WorshipCue/Results/M0-Finger-All-20261007-191220.xcresult` now exits0: **six tests, six passed, zero failures/skips**, iPad(6th generation), iPadOS17.7.11. Updated app launch exits0 and the new selector/selected pen are visually inspected on the real USB display. Physical post-fix finger strokes are pending the user; no physical Pencil or oldest16.7.16 qualification is inferred.

Updated Xcode26.6 explicit SDK/app+test build command in `verification/M0.md` exits0 / BUILD SUCCEEDED, minimum bundle16.0, zero native tests executed on16. Project/source/scheme/Korean catalog check exits0. Earlier reference55/spec32/storage9/macOS-framework4 evidence remains valid; portable sources did not change. Exact red/green/final commands, result bundles and redacted logs are recorded in `verification/M0.md`. No paid enrollment, new dependency, cloud operation or automatic song/page/note behavior was introduced. M0 physical qualification remains open.


### End-to-end M0 qualification and retained UI-runner blocker · 2026-10-07

Implemented the actual-overlay accessibility bridge, isolated DEBUG UI-test stores, visible input/tool state, and Light appearance for white-paper PencilKit ink. Screenshot regression proves the previous invisible archived pen becomes visible; current synthetic pen/marker and team-layer screenshots were inspected. Added native immutable-import/error-preservation/storage-rollback/active-stroke/late-callback/corrupt-restore/cold-reader coverage and three real-device UI workflows. No speculative save or extra preview trait patch remains.

Executed on iPad7,5 /17.7.11: **13 hosted cases pass, exit0; current drawing and team UI workflows each pass independently, exit0**. Earlier full transfer UI workflow passed; the final corrected screenshot check could not be requalified because standalone runners hung before connection and a grouped attempt lost testmanagerd during transfer setup. Failed exits65 and final deliberately interrupted exit75 are retained. Xcode26.6 destination discovery still marks this paired device ineligible; no new runtime/platform download started.

Fresh external-wrapper reference Swift55/specifications32/storage9groups/macOS frameworks4groups pass. Xcode26.6 /iphoneos26.5 Debug app+13 native tests, Debug app+3 UI tests and Release compile; latest UI source rebuild exits0. Release excludes DEBUG test-store launch arguments. Minimum16.0 remains compile-qualified only; original16.7.16 runtime and physical Pencil/airplane-force-kill/pressure/rotation/latency/soak/two-device gates remain open.

Private signing settings removed; restored project matches pre-signing backup; generated project/both shared schemes reproduce after normalizing task-owned GUI scheme edits. Source hashes unchanged, structure/shell checks pass, private identifier scan0matches. Normal workspace app launch exits0 without test arguments. Free Personal Team only; no annual fee, purchase, upload or auto song/page/note behavior. Exact commands and records: `verification/M0.md`, `m0-final-qualification.json` and the physical checklist. M0 remains open; next work is qualification rather than a pilot-ready or M1 claim. System command-line selection correction requires direct Mac administrator authentication; it fixes missing diagnostic utility access without yet proving a primary runner fix.
