# M0 · Build 2 colors and initial icon (2026-10-07)

Implemented and installed on the iPad (6th generation), iPadOS 17.7.11, using the existing free Personal Team. No enrollment, purchase, deployment or App Store upload occurred. iPadOS minimum remains 16.0; original 16.7.16 iPad and Apple Pencil qualification remain NOT VERIFIED.

## Behavior

A single 44-point color-swatch control beside the pen/highlighter opens a 288-point popover containing eight labeled colors: black, blue, red, green, purple, orange, yellow and pink. Selection dismisses it immediately; × and an outside tap also dismiss it. Selected color is indicated by a checkmark and accessibility state. Pen and marker preferences are independent and remembered locally, including after relaunch and across pages. UI-test preferences use the same isolated UUID namespace as their ink stores. Fixed RGB pigments and the existing Light canvas override prevent Dark Mode from changing new ink colors. Existing drawing archives are not recolored, merged or reset.

The user-approved teal folded-ribbon W is the initial native app icon. Its full-square, opaque production adaptation removes the presentation margin and pre-rounded mask. All ten iPad/marketing PNG slots have verified dimensions and no alpha. The actual installed icon was observed on the iPad Home screen through an unrecorded USB preview; private Home-screen imagery is not saved into this repository. `CFBundleVersion=2`, `MinimumOSVersion=16.0` and compiled `CFBundleIcons~ipad` metadata were inspected.

## Verification

- `m0-color-ui-summary.json`: Xcode 27.0, real iPad17.7.11; **1/1 UI case passed**, 36.143556s, xcodebuild exit0. Actual finger gestures verified × dismissal, outside dismissal without adding ink, selection dismissal, blue pen pixels, pink marker pixels, independent tool choices and cold-relaunch recovery. Synthetic screenshots were exported and visually inspected: `m0-color-popover.png`, `m0-blue-pen-pink-highlighter.png`.
- `m0-color-native-focused-summary.json`: **2/2 hosted native cases passed**, 0.348s total case execution, xcodebuild exit0. All eight tool pigments resolve identically in Light/Dark traits; old drawing contents remain unchanged; pen/marker preferences survive page creation/relaunch; eraser ignores color choice. The actual PDFKit-installed canvas resolves to Light appearance and receives drawing hits.
- `m0-color-black-pen-qualified-summary.json`: **1/1 UI case passed**, 32.200263s, xcodebuild exit0. Fresh black-pen visibility pixels, yellow marker, vector eraser, undo/redo and cold-relaunch save recovery pass on the updated app. The synthetic black-pen screenshot was visually inspected.
- `m0-color-icon-release-qualified.json`: actual Xcode27 Release build exit0, SDKiphoneos27.0, signing disabled, minimum16.0. Debug app/native/UI target compilation also succeeded in the device test commands. Sources now contain14 hosted cases and4 UI cases; this is not a claim that all18 executed together.
- `python3 scripts/verify_m0_project.py`: exit0; resource/scheme/Korean catalog checks pass. `sh -n scripts/test_ipad_device.sh`: exit0. Generator re-run left project and both shared schemes byte-identical; no private Team is embedded. Tested source hashes: `m0-color-icon-source-hashes.json`.

## Preserved failures and limits

- Initial `m0-color-native-run.json` exits65: one test incorrectly asserted a detached overlay's resolved traits were Light. On iPadOS17 it remained Dark before hierarchy attachment despite the override. The assertion was moved to the real PDFKit-installed hierarchy; no speculative production appearance change was made. Corrected focused checks above pass. The original failure remains in its log/result bundle.
- Full14-case native recheck `m0-color-native-qualified-run.json` stalled before any test case started. After roughly six minutes, only the verified task-owned driver was interrupted; it failed to stop cleanly after SIGINT and required SIGTERM, actual exit-15. Its xcresult has no final Info.plist and cannot be read as a completed bundle. No full14-case passing result is claimed. Previous13-case baseline evidence remains historical; the subsequent focused2-case retry succeeded.
- Xcode26.6 generic build-for-testing exits70 because its26.5 platform destination is unavailable (`m0-color-icon-xcode26-build.json`). SDK-only target retry exits65 in actool: “No available simulator runtimes for platform iphonesimulator.” (`m0-color-icon-xcode26-sdk-build.json`). No runtime download was initiated. These are retained failed builds; Xcode27 Debug/Release and installed17.7.11 runtime evidence are distinct.
- Full transfer UI requalification, original16.7.16-device writing, physical Apple Pencil, memory/thermal/resume and multi-iPad gates remain open from the M0 baseline. No automatic song changes, page synchronization or automatic note merging were added.

## Reproduction

With the existing authorized private device/team supplied through environment variables, use the external Xcode environment and the checked-in schemes. Do not check private identifiers into this document:

```sh
. scripts/external_xcode_env.sh
xcodebuild -project apps/ipad/WorshipCue.xcodeproj -scheme WorshipCueUI -configuration Debug \
  -derivedDataPath "$worshipcue_build_root/DerivedData-Xcode27-iPad17" \
  -clonedSourcePackagesDirPath "$worshipcue_build_root/SourcePackages" \
  -destination "platform=iOS,id=$WORSHIPCUE_TEST_DEVICE_ID" \
  DEVELOPMENT_TEAM="$WORSHIPCUE_TEST_TEAM_ID" CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration -parallel-testing-enabled NO \
  -only-testing:WorshipCueUITests/MusicStandUITests/testCompactColorPickerDismissalRenderedColorsAndRememberedChoices test
```

Exact filter/options/bundle paths and actual command exits are retained in the corresponding run JSONs. The device script includes a separate color UI session in addition to native, drawing, transfer and team cases; that entire script has not completed as one passing invocation.

Normal app relaunch (no UI-test launch arguments) exited0 and its reader/color control were visually inspected through an unrecorded USB preview. No screenshot of the normal workspace was copied to repository evidence.
