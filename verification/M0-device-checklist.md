# M0 physical-device record

Current verified gate: 13/13 hosted native tests and 2/2 independently qualified UI workflows (drawing/save/relaunch and read-only team isolation) pass on iPad (6th generation), iPadOS 17.7.11. The final corrected transfer UI recheck is blocked by test-runner connection failures; an earlier full functional transfer workflow passed and the current black preview was visually inspected. Physical Apple Pencil and original iPadOS 16.7.16 runtime qualification remain NOT VERIFIED. Original hardware is iPad6,7 / iPad Pro (12.9-inch), iPadOS 16.7.16; no app has executed there. Actual Pencil generation remains unknown. Synthetic XCTest gestures exercise the connected 17.7.11 device; they do not clear physical rows below.

The original16.7.16 development connection remains unqualified: Instruments Unknown/offline; no eligible Xcode26.6 scheme destination; its GUI is incompatible with this macOS27 host. The second17.7.11 iPad has a working Xcode27 development connection and test runner. Xcode27 device/test support starts at17. Earlier18.0-minimum and missing-Xcode results in `M0.md` are historical and superseded by the user-authorized16.0 amendment and compiler checks.

The user approved existing signing/profile creation and iPad registration with Apple. The current free Personal Team profile contains the17.7.11 iPad; signing, installation and launch pass for it. The original16.7.16 iPad still lacks a qualified development connection and matching profile. The user requires free Personal Team development with no paid enrollment until release. Do not infer physical results from profile creation, compilation, reference tests or macOS framework checks.

Run `sh scripts/check_m0_environment.sh` for tool/runtime/device inventory. It does not verify physical behavior. Exact build results and limitations are in `M0.md` and `docs/14_OLDER_IPAD_COMPATIBILITY.md`.

Record for each run: tester/date, iPad model, iPadOS version, Pencil model/generation, app version/build, Xcode version, network state, fixture name/bytes, and observed result. Inventory the oldest intended pilot iPad before freezing hardware support at the new iPadOS 16.0 minimum. Repeat on two different screen sizes and actual Pencil generations in the team.

## Automated portions on the connected17.7.11 iPad

| Feature / failure path | Actual coverage | Qualification |
| --- | --- | --- |
| Pen/highlighter/eraser/undo/redo | Actual XCTest finger gestures, visible black pen pixel assertion, marker screenshot, erase/undo/redo | PASS |
| Saved note / version / page recovery | Exact archive native tests plus UI terminate/relaunch of the isolated app workspace | PASS; airplane-mode force-kill gate remains open |
| Invalid PDF and cache corruption | Native vault/model tests: immutable imports, malformed/oversized/excessive-page assets, hash verification, readable-chart preservation | PASS; live Files-provider UI remains open |
| Save failure / retry | Production SQLite transaction fault injection, pending bytes retained, blocked navigation, durable retry | PASS; whole-device disk-full/interrupted save remains open |
| Corrupt ink restore | Writing disabled until repaired native archive loads durably | PASS |
| Stroke/navigation timing | Real PencilKit delegate callbacks, pen-up/late callback save, captured version/page identity | PASS; physical active Pencil navigation remains open |
| CropBox/rotation/zoom mapping | Native PDFKit conversions: four rotations and three scales | PASS; physical rotated writing alignment remains open |
| Manual selected-note transfer | Earlier complete UI workflow passed; current black preview visually inspected; final corrected UI recheck blocked by runner connection | Latest full qualification NOT VERIFIED |
| Team/personal isolation | Actual UI draw/erase/undo; exact version/page show-hide; retained visible screenshot | PASS for local sample; multi-iPad synchronization is not implemented |

## Physical acceptance gates

| Check | Procedure / evidence required | Current result |
| --- | --- | --- |
| Finger input regression | Choose visible 손가락 필기, draw once with 펜 and once with 형광펜; verify visible ink and saved status | Actual-device XCTest finger gestures and black-pen screenshot pixel check PASS; physical Pencil/palm remains NOT VERIFIED |
| Pencil/palm/finger | Pen/marker/stroke eraser; palm resting; fingers pan/zoom; 20 rapid undo/redo actions; finger test mode OFF | NOT VERIFIED |
| Confirmed-note recovery (T26) | Draw v1/page 2, wait for saved, force-kill, airplane-mode cold launch; compare complete drawing and page/version | NOT VERIFIED |
| Interrupted save / storage fault (T29) | Kill before saved; exercise a development storage fault/full disk; no false saved and previously committed notes remain | NOT VERIFIED |
| Canonical geometry (T43) | `geometry_rotations.pdf` has CropBox (20,28,572,740) and rotations 0/90/180/270. Mark labeled targets; verify <=2 document-point tolerance after 100/200/400% zoom, portrait/landscape, close/reopen | NOT VERIFIED |
| Active stroke/navigation (T23,T44) | Begin stroke and attempt page/version changes; no transition until pen-up. Rapid v1/page2→v2/page1→v1/page2; correct bytes restored | NOT VERIFIED |
| Selected-note transfer (T18) | Draw two separated notes on v1; rectangle-select one and inspect preview. Copy, close source, choose v2/page2, paste/drag/uniform-scale/cancel, then commit/undo/redo. v1 unchanged | NOT VERIFIED |
| Team isolation (T19–22) | Enable read-only sample on v2/page1; erase/undo personal strokes; red team ring unchanged. v1/other pages show no ring | NOT VERIFIED |
| PDF validation (T28) | Import corrupt fixture, partial PDF and >100MB source; current chart retained, invalid file never listed ready | NOT VERIFIED |
| Lifecycle | Background/foreground, lock/unlock after first unlock, rotate while writing, low battery, device memory pressure; notes retained | NOT VERIFIED |
| Bounded view resources | Repeated opening/page changes with Instruments allocation tracking; verify released canvases and no unbounded live views | NOT VERIFIED |
| Save latency | Record pen-up to SQLite acknowledgment p50/p95/max for qualified archives; target p95 <=300ms, no claimed measurement yet | NOT VERIFIED |
| Render/page latency | Measure cached meaningful render and warm page navigation on oldest hardware; targets p95 <=750ms / <=150ms | NOT VERIFIED |
| Scanned/large PDF and thermal | Authorized large scan; two-hour reading/writing soak on stand while playing keys; record memory, thermal state, crashes/loss | NOT VERIFIED |

Original-device signing/access, actual Pencil selection UX, real rotation/zoom alignment, force-kill recovery, and measured memory/latency remain open gates. M0 is not gate-complete and this app is not pilot-ready.

## Second device candidate: iPadOS17.7.11

Verified OS17.7.11; Configurator model iPad(6th Generation), USB productiPad7,5. Current state: wired development connection paired, Developer Mode enabled, signed app installed, user confirmed developer trust, thirteen hosted native integration tests passed. This cannot replace original16.7.16-device acceptance evidence or real Pencil/gesture/soak measurements. The touch fix was installed and launched, and the visible input selector/checkmarked pen were inspected through a non-recording QuickTime USB preview. The earlier Screen Time approval used normal user controls. See `m0-ipad17-connection.json`. The connection failures below are historical.

After the user unlocked the second iPad, CoreDevice verifies **17.7.11**, wired/unpaired/tunnel disconnected. Device Hub now displays this iPad and **“Pairing Required”**, instructing Trust on the device. `devicectl manage pair --device <private CoreDevice identifier> --timeout45 --json-output <external Temporary file>` times out at45 seconds before Trust completion; the JSON outcome is timeout (native command exit was not separately retained by the evidence wrapper). Requested direct iPad Trust/passcode completion. The user reports Developer Mode off/missing; no setting was changed by the agent. No new app registration, installation or test execution yet. The initial locked-state record above is historical; current blocker is Trust pairing.

The user confirmed Trust on the second iPad. Finder independently confirms iPadOS17.7.11. A Finder sync/backup was observed automatically running on the internal drive and stopped using its Stop control; subsequent UI shows Sync/Back Up Now instead of active backup, confirming cancellation. No backup data was deleted and sync preferences were not changed. Latest internal free space1.2GiB /external199GiB. After Trust, CoreDevice pairing again times out45seconds, **native exit2** (`m0-ipad17-pair-trusted.log`). Apple's `/usr/bin/devmodectl list` **exit0** confirms the new iPad's Developer Mode is **disabled**; no other listed device was operated. Requested direct Settings→Privacy & Security→Developer Mode enable/restart/confirmation. `devmodectl help single` was read only; no Developer Mode setup command executed. No registration/install/native test pass is claimed.

The user reports Developer Mode still missing. `/usr/bin/devmodectl single <new-iPad-UDID>` **exit1**, “Failed to arm: Device has a passcode set”; subsequent status read **exit0**, still disabled. No passcode/security setting was removed or changed. Normal Xcode27 scheme/device **build exit70**, “Unable to find a device matching the provided destination” (`m0-ipad17-scheme-build.log`); no native compile/install/test pass follows from it. A scheme destination query **exit0** lists generic devices/My Mac but no usable real iPad (`m0-ipad17-destinations.log`).

Configurator's Activity list was empty, then its idle app was quit through its normal app menu and absence in the running-app inventory verified. This changed the diagnostic condition without canceling a Configurator operation. CoreDevice pair with Configurator closed **exit1**, no RemotePairingDeviceRepresentation (only RestorableDeviceRefDeviceRepresentation); lock-state query **exit1**, no supported usage assertion. This does not prove a specific cause of the missing setting. Apple's bundled cfgutil restricted to this iPad returns **isPaired=true, isSupervised=false, pairingAllowed=true, OS17.7.11**; aggregate command **exit1** (partial property response), preserved as such in `m0-ipad17-classic-properties.json`. USB trust and development pairing are distinct findings. Requested one normal iPad restart/reconnect/unlock and keeping it awake for the next retry. No erase, privacy reset, enrollment purchase, successful new-device registration or app installation occurred.
