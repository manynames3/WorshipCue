# M0 · private arrangement pair · 2026-10-07

The user supplied two local arrangements of the same music with different arranger markings. They remain local inputs, not public fixtures. No chart, extracted music/lyrics, private handwriting, PDF screenshot, actual device identifier or signing identifier is recorded here.

## Inputs and visual inspection

- A: 4 pages, 612 × 800 document points; B: 4 pages, 1449 × 2048 points. Both have zero rotation and CropBox equal to MediaBox. These have different proportions as well as coordinate scales.
- Embedded annotations: 83 total in A and54 in B; FreeText/Stamp, with Square also on page3. Page4 in each has no embedded annotations. The existing arranger notes are source-PDF content, not personal PencilKit ink.
- All8 pages rendered with Poppler and actual on-device PDFKit. Both contact sheets were visually inspected; the colored arranger notes, handwritten marks and score pages remain readable. Imported source files and original Mac files retain their exact bytes/hashes.
- They are independent immutable versions. No chronology, automatic alignment, automatic merge, page synchronization or automatic song change was inferred.

## Executed final run

Toolchain: **Xcode27.0, build27A266a**, iphoneos27.0 SDK, Debug; connected **iPad (6th generation), iPadOS17.7.11**; existing authorized free Personal Team. Production app source was unchanged. No new dependency or paid enrollment.

Entry command (sensitive IDs and private source paths redacted):

```sh
WORSHIPCUE_TEST_DEVICE_ID='<discovered-device-id>' \
WORSHIPCUE_TEST_TEAM_ID='<authorized-existing-team-id>' \
python3 scripts/test_private_pdf_pair.py '<local-arrangement-A.pdf>' '<local-arrangement-B.pdf>'
```

The helper's actual build/test commands are in `scripts/test_private_pdf_pair.py`. It ran `build-for-testing` with scheme `WorshipCueUI`, then two separate `test-without-building` sessions with an external xctestrun supplying `WORSHIPCUE_PRIVATE_PDF_RUN`.

Final private run: `9E6DCE1C-F9C9-4EBC-AB4E-A82E1B8C1DA3`. Private logs, staged inputs, rendered pages, test summaries and xcresult bundles are under the external tools root's `WorshipCue/PrivateChartTests/<run>/`, outside Git.

| Operation | Exact result |
|---|---|
| Stage private copies onto the installed iPad app | exit0 |
| Debug app + hosted native + UI targets, build-for-testing | exit0 |
| `NativeInkTests/testPrivatePDFPairPreservesAnnotationsAndManualTransferAcrossDifferentGeometry` | exit0; 1 passed, 0 failed, 0 skipped |
| `MusicStandUITests/testPrivatePDFPairFingerInkSelectedTransferAndColdRelaunch` | exit0; 1 passed, 0 failed, 0 skipped |
| Collect native PDFKit renders | exit0; 8 rendered pages |
| Complete helper | exit0 |

Native evidence covers immutable import, original annotation counts/geometry, byte equality, selected personal-stroke transfer with explicit coordinates/scale, cancel/commit/undo/redo, source preservation, page/version isolation and a fresh reader's recovery. The UI case uses real finger gestures, screenshot color checks, selection of only one of two new strokes, explicit target/preview/enlargement, cancel/commit/undo/redo, version/page isolation and cold app relaunch. Existing arranger marks are not selected by personal-note tools.

## Retained failed attempts

Two preliminary native attempts exited65 because the new assertion compared cached in-memory UIColor/affine values directly with an archive's resolved colors/float coordinates. The comparison now canonicalizes both drawings through native PencilKit serialization before checking every stroke property. Existing tests/production storage were not loosened or changed.

The next native case passed, while UI exited65 on the pasted stroke's screenshot-width threshold. Its screenshot was inspected: the stroke was visible, but a same-point-size copy occupies a smaller physical width on B's larger geometry. The corrected workflow explicitly enlarges the preview with the existing controls before confirming. There is no automatic resize. Failed bundles/logs remain private. The final native session also waited for the device runner before case execution, then passed; this does not resolve the previously recorded intermittent XCTest connection problem.

## Availability in the normal app

After isolated tests finished, the two byte-verified native imports were staged into the normal local PDF vault with their supplied filenames. The5 existing chart entries were preserved, with no personal database or bookmark edit. The appended index was read back and compared. Both originals still match their initial hashes; the normal app was reopened without test arguments, exit0. Both arrangements are available through `악보 선택`.

This setup used local developer file staging after native importer qualification. It does **not** claim that the Files picker/share-sheet UI was exercised with these private files. Standard tests remain isolated and do not modify the normal vault.

## Limits

Physical Apple Pencil input, the original iPadOS16.7.16 device, zoom/rotation/pressure/resume/thermal/soak/multi-iPad checks remain **NOT VERIFIED** for these charts. The full synthetic suite was not rerun for these test-only additions; its prior qualification limits remain. The actual shared-team/backend/live features remain unimplemented. M0 is not pilot-ready.
