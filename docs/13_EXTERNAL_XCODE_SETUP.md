# External Xcode setup · 2026-10-07

User authorized installing Xcode with external storage used wherever practical.

**Latest status:** stable Xcode 27.0 is installed, first-launch/license checks pass, and the native app/test targets compile. Xcode GUI DerivedData/compilation-cache/archive locations and CLI build/package/temp paths use external storage. Runtime execution remains blocked by an absent simulator runtime and low internal free space; prior installation/license failures below are historical evidence.

## Storage prepared

Root on the existing external APFS volume:
`/Volumes/CRUCIAL 525GB - Data/Projects/general dump/DeveloperTools`

| Contents | Location below root | State |
|---|---|---|
| Stable Xcode app | `Applications/Xcode.app` | INSTALLED; 27.0 / 27A266a; full signature and Gatekeeper checks passed |
| Apple download archives | `Downloads/Xcode_27.xip` | Official signed archive; 2,014,229,334 bytes |
| Scoped command temporary files | `Temporary` | Extraction files/logs retained externally |
| WorshipCue build/index/module output | `WorshipCue/DerivedData` | Prepared |
| Xcode package checkouts | `WorshipCue/SourcePackages` | Prepared |
| Future explicitly requested archives/results | `WorshipCue/Archives`, `WorshipCue/Results` | Prepared, empty |

`scripts/with_external_xcode.sh` selects this app with per-command `DEVELOPER_DIR` and sets external `TMPDIR` and compiler module-cache paths. `scripts/test_ipad.sh` uses the same environment plus explicit external DerivedData and package-checkout paths. Existing Swift packages' `.build` directories are already in this external repository. No global command-line selection, shell startup file, system symlink, signing account, or existing cache was changed.

For another location, set `WORSHIPCUE_XCODE_APP` to its absolute app path and/or `WORSHIPCUE_TOOLS_ROOT` to another storage root. Run from this repository:

```sh
sh scripts/with_external_xcode.sh
sh scripts/with_external_xcode.sh sh scripts/check_m0_environment.sh
sh scripts/test_ipad.sh
```

## Actual installation investigation

Host: macOS 27.0.1 arm64. Apple lists stable Xcode 27 as supported on macOS 26.6 or later; beta/RC releases were not selected. At setup, external space was approximately 243 GiB free and internal Data space approximately 6.1 GiB free.

The App Store was already signed in. Its large-app external-install checkbox was inspected, but the disk menu contained no eligible disk. The checkbox was restored to its original disabled state. No App Store download was initiated. `diskutil info` confirms CRUCIAL Data is external USB/APFS, writable, owners disabled, and part of an APFS volume group. These observations do not establish why the App Store excludes it; its disk structure/settings were not altered.

The official Apple Developer downloads page was opened in Codex's browser and redirected to Apple sign-in. The user was asked to sign in there directly. No credentials were read, recorded, or supplied by the agent.

The app installation is now verified as described below. Apple license acceptance, first-launch support installation, usable SDK/runtime inventory, simulator execution, and native compilation remain NOT VERIFIED. Simulator runtime/device data and Apple system support components may still require internal storage; no unsupported system-directory relocation was performed. Check actual component sizes and available internal space before installation. Start with only the needed iOS platform rather than all platforms.

## Initial investigation results (before installation)

- `sh -n scripts/external_xcode_env.sh scripts/with_external_xcode.sh scripts/test_ipad.sh`: exit 0, shell syntax only.
- `sh scripts/with_external_xcode.sh`: exit 2 with the exact expected missing-app diagnostic; no native compilation.
- `xip --help`: initially blocked by the shell sandbox; outside-sandbox read-only invocation returned usage (exit 1 because `--help` is unsupported). Extraction attempts and results are recorded below.

References: [Apple Xcode requirements](https://developer.apple.com/xcode/system-requirements), [official downloads](https://developer.apple.com/download/all/?q=Xcode), [nonstandard command-line tool location](https://developer.apple.com/documentation/xcode/configuring-command-line-tools-settings), [App Store external installation](https://support.apple.com/guide/app-store/fir06754f864/mac).

## Authenticated download and extraction continuation

The user completed Apple Developer sign-in. Selected the **stable Xcode 27** entry dated September 14, 2026, with the official `https://download.developer.apple.com/Developer_Tools/Xcode_27/Xcode_27.xip` link. The browser download API timed out, but the actual download completed at `/Users/aiden/Downloads/Xcode_27.xip`, exactly **2,014,229,334 bytes**. It was moved without overwriting an existing file to external `Downloads/Xcode_27.xip`; no additional Xcode download remained in internal Downloads at that check.

`pkgutil --check-signature` reported **signed Apple Software**, exit 0, with the Software Update → Apple Software Update Certification Authority → Apple Root CA chain. No signature-validation or Gatekeeper checks were disabled.

The first `xip --expand` attempt used an external working directory and external `TMPDIR`, but process inspection showed it writing to the internal app-group staging directory. The process was stopped with SIGTERM (exit 143) before exhausting internal storage. Its identified staging UUID is `7473911D-ABEE-4E30-8045-F6F46988A8A1`; only that task-created staging folder was targeted for external recovery. Shell moving was blocked by macOS app-group access protection; Finder started a move to external `Temporary/7473911D-ABEE-4E30-8045-F6F46988A8A1`. **Completion of that move still needs verification.** No unrelated internal files were targeted.

Alternative extraction uses Apple-provided tools and stays on the external volume:

```sh
# External working directory: DeveloperTools/Temporary/xcode-signed-content
xar -xf ../../Downloads/Xcode_27.xip
compression_tool -decode -i Content -o Xcode.cpio
ditto -x --hfsCompression Xcode.cpio ../../Applications
```

Actual first `xar` command used absolute paths and `-C` to the external working directory. `xar` and `compression_tool` both exited 0; the decoded file is a 10,275,147,776-byte ASCII CPIO archive. A generic `tar` attempt produced SDK link/overwrite permission errors, including outside the sandbox, and was stopped (exit 143). Its error log remains at external `Temporary/extract-xcode.log`. Apple `ditto` completed with exit 0; `Temporary/ditto-xcode.log` is empty. A partial app from the interrupted original attempt was preserved at external `Temporary/xcode-incomplete-apple-xip.app`.

## Verified installation; initial first-launch blocker

- Full `codesign --verify --deep --strict --verbose=2 Applications/Xcode.app`: exit 0, **valid on disk; satisfies its Designated Requirement**. Raw output: `Temporary/codesign-xcode.log`.
- `spctl --assess --type execute --verbose=2 Applications/Xcode.app`: exit 0, **accepted; source=Apple System**. Raw output: `Temporary/gatekeeper-xcode.log`.
- `sh scripts/with_external_xcode.sh`: exit 0, **Xcode 27.0; Build version 27A266a**.
- App disk usage: approximately **3.6 GiB** on the external drive. Latest storage observation: **4.3 GiB internal Data free**, **220 GiB external free**. Free space changes as other applications run.
- iPhoneOS/iPhoneSimulator platform directories exist in the signed app; directory existence does not verify SDK usability or an installed simulator runtime.
- `sh scripts/with_external_xcode.sh xcodebuild -showsdks`: exit **69**, Apple license not accepted.
- `sh scripts/with_external_xcode.sh xcodebuild -checkFirstLaunchStatus`: exit **69**, no output. Silence is not a successful first-launch check.
- `sudo -n true`: exit **1**, an administrator password is required. No password was requested in chat or recorded.
- Xcode computer control was not approved, so first-launch UI was handed to the user; no alternative UI automation bypass was used.
- `sh scripts/test_ipad.sh`: exit **69** before native compilation. Raw output: `verification/m0-native-external-xcode.log`.
- External Xcode Swift reference-test attempt: exit **1**, because SDK lookup invokes `xcrun`, which is blocked by the license (underlying exit 69). Raw output: `verification/reference-swift-test-external-xcode.log`.
- Python reference verification: exit **0**, **32 tests passed**; project structure check and setup-script shell syntax: exit **0**. Raw output: `verification/reference-package-external-setup.log`, `verification/m0-project-external-setup.log`.

The interrupted staging recovery destination exists externally and occupies approximately 4.0 GiB. Internal free space recovered after Finder moved it; the source app-group directory still cannot be listed by the shell because of macOS access protection. Source absence/full move completion is therefore not claimed. All task-created extraction intermediates remain recoverable on the external drive.

The user must open the external Xcode app, review/accept Apple's license and complete administrator setup directly. Skip optional simulator downloads until internal storage requirements have been checked. Then rerun the SDK inventory and `sh scripts/test_ipad.sh`; do not report a native build or native tests as passing until they actually execute. The app bundle, archive, build output, package checkouts, module caches and scoped temporary files use external storage; first-launch system support and simulator/device storage are not yet qualified for external relocation.

## First launch complete and native builds verified

The user completed license/admin setup and approved Xcode control. `xcodebuild -showsdks` and `-checkFirstLaunchStatus` now exit 0. Actual SDK inventory is saved to `verification/xcode-sdk-inventory-licensed.log`. The Swift reference suite passes **55 tests**, exit 0. Native generic simulator app build and hosted test build both pass, exit 0, after fixing the first compile error; exact commands/logs are in `verification/M0.md`.

In Xcode Settings → Locations, set and verified:

| GUI storage | External location below DeveloperTools |
| --- | --- |
| Derived Data | `Xcode/DerivedData` (Custom) |
| Compilation Cache | `Xcode/DerivedData/CompilationCache.noindex` (follows Derived Data) |
| Archives | `Xcode/Archives` (Custom) |

These apply to GUI builds. CLI WorshipCue builds continue to specify `WorshipCue/DerivedData` and `WorshipCue/SourcePackages`; existing internal caches were not deleted or moved. Global command-line selection remains unchanged because project scripts scope their developer directory. The real project is open in Xcode with scheme `WorshipCue`.

`verification/xcode-installed-runtimes.json` contains an empty runtime list. Xcode Components shows iOS 27.0 (SDK build 24A430) as **Get**, **8.05 GB**, and no other installed platforms. The inspected Components/info controls expose no external install path. `simctl help runtime` describes adding images to secure storage without an install-location option. Apple's download/export workflow does not by itself establish that installed runtime storage is external; no unsupported relocation or security change was attempted.

Latest observed free space: **2.9 GiB internal Data / 219 GiB external**. The final native test script exits 1 after a successful build because no available iPad simulator exists. No native integration test executed and no simulator download was initiated. Runtime execution requires additional storage qualification or a real iPad with authorized device/signing setup. Hardware/Pencil gates remain NOT VERIFIED.

## Older-device requirement

The user connected an iPad on 16.7.16 and explicitly required older-iPad support. D39/app/packages now target 16.0; actual app compilation and minimum-version metadata pass. Xcode 27's connected-device/test libraries start at 17, so an older toolchain still needs qualification. Stable Xcode 26.6 Apple silicon (2.16 GB) was located on Apple's official authenticated downloads page. Its documented host range is macOS 26.x; operation on this macOS 27 host is unverified. Current Xcode 27 remains installed and unchanged.

Latest internal free space: **2.6 GiB**. Direct unauthenticated HTTP access to the older archive redirects to Apple's unauthorized page; no browser cookies or credentials were extracted. Chrome's download-settings page was rejected by browser security policy, so no alternate surface was used to change that setting. The user was asked to sign in in the prepared Chrome tab and use **Save Link As** to place the archive directly in external `DeveloperTools/Downloads`. The older archive has not yet arrived. Detailed requirements and current evidence: `docs/14_OLDER_IPAD_COMPATIBILITY.md`.

### Authenticated Save Link As blocked

At the user's request, native Chrome **Save Link As** was used on the official Xcode 26.6 Apple silicon archive link. The Save dialog showed the exact external `DeveloperTools/Downloads` folder and filename `Xcode_26.6_Apple_silicon.xip`; Save was clicked. Chrome's Recent Download History then reported **“Blocked by your organization”** for that filename. A shell directory check returned exit 0 and showed only the existing `Xcode_27.xip`; no older archive or partial download was present. Thus no download, signature check, extraction, older installation, or new device test succeeded. Browser policies/security protections were not changed or bypassed. This browser restriction must be resolved by the user or responsible administrator before continuing this download route.

### Manual download succeeded

The user initiated the download manually to the external folder. It completed as `Downloads/Xcode_26.6_Apple_silicon.xip`, exactly **2,318,258,791 bytes**. `pkgutil --check-signature` exited **0**, reporting **signed Apple Software** with the Software Update → Apple Software Update Certification Authority → Apple Root CA chain (`verification/xcode26-archive-signature.log`). SHA-256 is recorded in `verification/xcode26-archive-sha256.log`. The earlier browser message did not identify an organization or establish who caused the restriction; manual success leaves that cause unresolved. Automated diagnostic access to `chrome://policy` was separately rejected by Codex's browser URL policy; no alternate surface was used to bypass that rejection.

External `Temporary/xcode-26.6-signed-content`: `xar -xf ../../Downloads/Xcode_26.6_Apple_silicon.xip` and `compression_tool -decode -i Content -o Xcode.cpio` both exited **0**. The decoded archive is **9,486,355,968 bytes**. `ditto -x --hfsCompression Xcode.cpio ../../Applications/Xcode-26.6` completed with exit **0** into its separate external parent. Raw extraction logs are `xar.log`, `decode.log`, and `ditto.log` in that staging directory. Full deep/strict app signature verification and Gatekeeper assessment both completed with exit **0**; Xcode 27 is preserved. See qualification results below.

## Xcode 26.6 qualification on macOS 27

Alternate app: `DeveloperTools/Applications/Xcode-26.6/Xcode.app`, approximately 3.7 GiB externally. `codesign --verify --deep --strict --verbose=2` exits **0**, valid on disk/satisfies Designated Requirement (`verification/xcode26-app-signature.log`). `spctl --assess --type execute --verbose=2` exits **0**, accepted/source Apple System (`xcode26-gatekeeper.log`). No protections or signed app metadata were changed.

Scoped CLI checks all exit **0**: version **26.6 / 17F113**, first-launch status, SDK inventory **iOS/iOS Simulator 26.5**, Swift **6.3.3**. Raw files: `xcode26-host-version.log`, `xcode26-first-launch.log`, `xcode26-sdk-inventory.log`, `xcode26-swift-version.log`. `xcodebuild -runFirstLaunch -checkForNewerComponents` exits **0**, “No new updates for 17F113” (`xcode26-device-support-setup.log`). This does not install a simulator runtime.

LaunchServices rejects the Xcode 26.6 GUI with **kLSIncompatibleApplicationVersionErr (-10664)**. Apple's documented host range ends at macOS 26.x; actual host remains macOS 27.0.1. CLI compilation is verified below, but supported GUI/device operation is not established. Two attempts to select the existing Xcode 27 GUI timed out. Finder nevertheless displays the connected iPad Pro and confirms **iPadOS 16.7.16** without a Trust prompt; Instruments still reports Unknown/offline.

The first generic device build was stopped after a stall while the internal disk was full (**143**; `m0-xcode26-device-build.log`). After the user freed space (4.5–4.7 GiB at that observation), the retry exited **70**, no eligible destination / “iOS 26.5 is not installed” (`m0-xcode26-device-build-retry.log`). Its automatic error result bundle was written internally under `/var/folders/.../T`; Apple's xcrun caches also use internal storage. The scoped TMPDIR does not guarantee all Apple tool storage is external. A read-only process sample found a coordinated-file-read wait; it did not establish an app-source defect. A bounded project-list probe timed out at 20 seconds (**124**) under 26.6, while 27 succeeded (**0**, 7.24 seconds).

Explicit `-sdk iphoneos26.5 -target WorshipCue` builds **successfully (0)** with external SYMROOT/OBJROOT. The test target's first manual-order build exited **65** on a package dependency cycle; adding the documented **`-parallelizeTargets`** option resolves it, **BUILD SUCCEEDED (0)**. No source/specification was changed to resolve this invocation problem. All five native tests compile; none has executed. App/test/dependency embedded minimums are <=16.0. The alternate-toolchain reference suite passes **55 tests, zero failures (0)**. Exact commands/logs are in `verification/M0.md`.

An explicit-SDK scheme destination query still reports no usable iOS destination (**0** query exit, ineligible generic device; `xcode26-explicit-sdk-destinations.log`). SDK headers/libraries and target compilation are usable even though the scheme/device workflow is blocked. Do not equate SDK inventory or compilation with a working iPad connection.

A build-settings query confirms `SDK_STAT_CACHE_DIR` is overridable. The authorized signing attempt sets it to external `WorshipCue/DerivedData-Xcode26`; build products, intermediates, packages and module caches remain external. Provisioning profiles stay in Apple's standard internal location. No unsupported system-cache/runtime symlinks were created.

## Authorized free signing and Configurator result

The user explicitly defers paid Developer Program enrollment until customer release. Continue with free Personal Team development only; no enrollment, purchase, publishing or paid workaround was performed.

Authorized signing uses the successful explicit-SDK app-target command above with `-parallelizeTargets`, external `SDK_STAT_CACHE_DIR`, a private existing-team override (`DEVELOPMENT_TEAM`), `CODE_SIGN_STYLE=Automatic`, `-allowProvisioningUpdates`, `-allowProvisioningDeviceRegistration`, and signing enabled (omit `CODE_SIGNING_ALLOWED=NO`). **Build exit0; deep/strict app signature exit0.** The prompt access denial was handed to the user; the key-use step subsequently completed. It is no longer the signing blocker.

A second command also added `-destination 'platform=iOS,id=<connected-iPad-identifier>' -destination-timeout20`. Native command **exit0**, but warning: **“Ignoring provided run destination because no scheme was passed.”** A profile inspection after both commands confirms the connected iPad is absent; no device-registration success is claimed. The local development profile expires **2026-10-14 21:33:01 UTC**. Redacted signing/profile evidence is under `verification/m0-xcode26-signing*.log` and `m0-xcode26-connected-profile.log`; private raw logs and identifiers remain outside the repository, under external Temporary. No certificate/private key was exported.

Apple Configurator2.21 is installed from the official free App Store listing, **76.8 MB**, at `/Applications/Apple Configurator.app` (standard Store location). Signature verification **exit0**. It displays the connected iPad and its16.7.16 OS (`verification/apple-configurator-installation.log`). This small Store utility and standard signing profile remain internal; the two Xcode apps/archives, packages, products, intermediates, module/SDK-stat caches remain external. No app was installed on the iPad because the signed app's profile excludes it. No device erase, Prepare, supervision or restore was used.

Xcode27 Device Hub lists no devices after All Devices is selected. Xcode26.6 scheme/device destination and GUI limitations remain. On this free account, Apple documents that Personal Team devices/profiles are managed in Xcode: [Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account/). Correct registration needs a usable compatible development connection; Configurator recognition alone does not qualify it. Latest free space:1.7 GiB internal /199 GiB external. No runtime download or unsupported protection/OS workaround was attempted.

## Device execution and external symbol cache · 2026-10-07

Xcode27 installed and ran WorshipCue on iPad7,5 /17.7.11 with the existing free Personal Team; all five hosted tests passed. No annual enrollment purchase. The profile expires2026-10-14T22:45:20Z and will need normal Xcode reprovisioning. Original16.7.16 device execution remains unverified; Xcode26.6 final app/tests explicit-SDK compile passed.

Xcode downloaded4.0GiB of this new iPad's symbol files into the user cache, outside DerivedData settings. That specific generated folder was preserved externally at:
`/Volumes/CRUCIAL 525GB - Data/Projects/general dump/DeveloperTools/WorshipCue/DeviceSupport/iPad7,5 17.7.11 (21H461)`

Its original per-device path at `/Users/aiden/Library/Developer/Xcode/iOS DeviceSupport/iPad7,5 17.7.11 (21H461)` is a symlink to that external folder;882 relative file/link entries and sizes matched. No global xcode-select or protected system-directory relocation. Subsequent launch/USB preview worked; symbol lookup performance was not measured. Keep the external drive mounted for Xcode and this cache. To reverse, close development tools, replace only this per-device symlink with the preserved cache folder, and verify space beforehand. Other device versions can create additional internal caches.

Latest internal headroom after relocation:4.2GiB. Profiles/xcrun/system temporary data are still internal; do not claim all developer storage is external. No simulator runtime was downloaded. Full commands/results and physical requirements are in `verification/M0.md`.
