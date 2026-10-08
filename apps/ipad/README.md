# WorshipCue native iPad app

Native SwiftUI workspace and PDFKit/PencilKit reader. Build **3** adds local library search, immutable chart versions, weekly packet extraction, planned/standby setlists, file preflight and PDF fallback export. Minimum **iPadOS 16.0** under D39. Current full native run on iPad (6th generation), iPadOS **17.7.11**: **18 passed, 0 failed, 1 opt-in private-PDF skip**. A fresh real-PDF native case also passes. Weekly-preparation, compact-color and export/share UI workflows pass separately; remaining UI qualification is recorded in [M1 evidence](../../verification/M1.md). Xcode 27 Debug/device targets and Release compile. No backend/live publishing is implemented.

Physical Apple Pencil and original iPadOS 16.7.16 runtime qualification remain **NOT VERIFIED**. Earlier M0, color/icon and private-PDF evidence remains in [M0 history](../../verification/M0.md), [Build 2 history](../../verification/M0-colors-icon.md) and [private-pair evidence](../../verification/M0-private-pdf-pair.md). Separate passing sessions do not imply pilot readiness.

Open `WorshipCue.xcodeproj`, scheme `WorshipCue`. GRDB 7.11.1 requires Swift 6.1 / Xcode 16.3 or newer; use a supported stable Xcode. Signing uses the existing development identity through a private command-line team override; no team identifier or credential is checked into this project. Signed app compilation and signature verification pass. The current Xcode27 profile includes the17.7.11 test iPad and expires2026-10-14T22:45:20Z; the older profile excluded the original16.7.16 iPad. Original-device provisioning/installation remains pending. Development must stay on the free Personal Team until release, per user instruction. `../../packages/WorshipCueLocal` pins GRDB exactly; `../../reference/WorshipCueCore` is deliberately reused as the app's pure domain package, so identity/version rules retain one owner.

## First slice

The app seeds synthetic v1/v2/v3, a rotated/nonzero-CropBox PDF, and a weekly packet into protected Application Support storage. Files imports create new version IDs and app-owned immutable source assets after size, parse, geometry, and SHA-256 checks. Cached PDFs are verified again before opening. Cold startup restores the last local version/page; a broken remembered chart requires explicit alternate choice. No existing readable chart is replaced by an import/open failure.

The personal layer uses a development-only local church/owner identity. The store actor commits drawing bytes, exact owner/version/page geometry, generation, and an unsent personal outbox snapshot together. Unsent full snapshots coalesce per exact layer/base to bound growth. There is no synchronization worker; outbox reconciliation, CAS, managed identity, and backend authorization belong to later milestones. No team-write outbox or live-call outbox exists.

The visible input selector defaults to **Apple Pencil**; fingers pan/zoom in this mode. Choose **손가락 필기** to write using a finger, and return to Apple Pencil mode to move/zoom the chart with fingers. PDFKit markup mode enables hit testing of its actual page overlays. The pen uses black ink and the annotation layer overrides its appearance to Light, as required to retain visible ink on white PDF paper in Dark Mode. Pen, marker, vector stroke eraser, undo, and redo target only personal ink; the selected tool has a checkmark. Each canvas owns its undo manager. Draw a selection rectangle, inspect highlighted candidate strokes, copy, explicitly choose a destination version/page, paste, drag/scale preview, then commit or cancel. Clipboard data survives source view release and stays inside the app. One undo group removes the pasted strokes. The separate red team sample is read-only and scoped to v2/page 1 of this local performance occurrence.

There is a 100 ms save debounce after pen-up. "기기에 저장됨" follows the SQLite commit; save errors retain pending bytes and block chart/page transitions. The <=300 ms target has not been measured. Transitions freeze canvases and capture current bytes; an active Pencil stroke must end before navigation. PDFKit's documented coordinate conversion supplies the canvas transform; all persistent dimensions are rotated CropBox document points.

## Commands

From the repository root:

```sh
swift run --package-path packages/WorshipCueLocal InkChecks
sh scripts/check_macos_frameworks.sh
python3 scripts/verify_m0_project.py
sh scripts/check_m0_environment.sh
sh scripts/test_ipad.sh
```

The native test script builds scheme `WorshipCue` and chooses an actual available iPad simulator from `simctl` JSON. It fails honestly if Xcode or an iPad runtime is absent. Device installation requires authorized signing. Actual17.7.11 test/install commands and result bundles are recorded in `verification/M0.md`. App/test runtime paths include bundled Frameworks in both Debug and Release. `scripts/generate_ipad_project.py` reproduces the checked-in project with standard-library Python; it does not require XcodeGen or a new production dependency.

See `verification/M0.md` and `verification/M0-device-checklist.md` for exact evidence and outstanding physical gates.

Selected-stroke clipboard logic now lives in the shared `packages/WorshipCueInk` module. Its macOS framework harness compiled and passed with real PencilKit drawings; thirteen hosted iPad tests now pass on17.7.11, including actual PDFKit-installed overlay hit testing. Synthetic tests do not replace physical input and lifecycle qualification. Two potential high-end designs are saved under `docs/ui-concepts`; these are generated concepts, not running app screenshots. External tool/build storage and exact native build evidence are recorded in `docs/13_EXTERNAL_XCODE_SETUP.md` and `verification/M0.md`.


## Real-device UI verification

Scheme `WorshipCue` runs the hosted native gate. Scheme `WorshipCueUI` also contains `MusicStandUITests`: actual finger gestures for pen/highlighter/eraser/undo/redo/save/cold relaunch; selected-note copy/paste/preview/cancel/commit/version-page isolation; read-only team-layer isolation. Screenshot pixel checks prevent an invisible archived stroke from counting as visible pen success. PDFKit text stays accessible; a small container exposes the current app-owned annotation layers.

DEBUG-only `--ui-test-store <UUID>` launches use a separate Application Support store. Tests never reset normal user notes or bookmarks. Release excludes this launch flag.

Optional real-arrangement tests read private PDFs staged on the device and skip when those inputs are absent. See [private PDF testing](../../docs/PRIVATE_PDF_TESTING.md). PDFs and their device screenshots remain outside the public repository.

```sh
# Supply discovered identifiers privately; do not commit them.
WORSHIPCUE_TEST_DEVICE_ID='<discovered-device-id>' \
WORSHIPCUE_TEST_TEAM_ID='<authorized-Personal-Team-id>' \
sh scripts/test_ipad_device.sh
```

The device script requires normal Trust, Developer Mode, developer certificate trust and XCTest UI Automation approval. It runs hosted tests and each UI case in independent sessions, stops on any failure and keeps xcresult bundles on the external drive. Combined UI runs previously lost their testmanagerd connection between cases; those failures remain recorded. Separate passing sessions do not prove that Apple runner issue is resolved. No paid developer enrollment is required for this authorized local testing setup.

## Build 2 · compact ink colors and initial icon

Select 펜 or 형광펜, then tap the small color swatch beside the tools. Eight labeled colors appear in a compact popover. Picking a color closes it; × and an outside tap also dismiss it. Pen and highlighter preferences are independent and persist locally. Preferences follow the UUID-scoped test namespace during UI testing; normal notes/bookmarks are not reset. Color values are fixed pigments and new choices affect subsequent strokes only.

The approved teal folded-ribbon W is now the native `AppIcon` asset. Build 2 compiles 14 hosted native cases and 4 UI cases. See `verification/M0-colors-icon.md` for current results and toolchain limitations.

## Local weekly preparation (Build 3)

Use **오늘 · 라이브러리** to search, edit song metadata, favorite songs, select/prefer numbered versions, import a new song/version, and create an editable setlist with standby entries. The chart detail’s **악보 작업** menu opens manual weekly-packet page ranges. The reader’s note-copy destination panel previews only explicitly copied personal strokes; confirmation remains a separate action. **PDF 내보내기** offers source/arranger content with optional personal ink and a native share sheet.

Existing M0 chart IDs, PDF bytes, ink SQLite and bookmarks are preserved. `pdfs/catalog.sqlite` replaces the JSON catalog after a transactional migration; the old `index.json` remains a receipt and must not be edited as a current catalog. New imports verify the promoted file before catalog publication. Setlist edits use revision checks and exact song/version foreign keys. See `verification/M1.md` and run `python3 scripts/test_m1_device.py` with privately supplied, already-authorized device/team environment values.
