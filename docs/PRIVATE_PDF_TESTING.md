# Local testing with real arrangement PDFs

Real musician charts are opt-in local inputs. Do not put PDFs, their rendered pages, extracted score text, or personal handwriting in this public repository. The standard suite continues to use synthetic fixtures; private tests explicitly skip when no input run is supplied.

The current physical UI workflow is designed for a pair of four-page arrangements with embedded PDF annotations and different page geometry. It checks the situation where the same music has different arranger markings. These are two independent immutable imports, not an inferred older/newer ordering. There is no automatic alignment, note merging, or version replacement.

With a trusted, unlocked iPad and existing authorized development signing:

```sh
# Supply discovered device and existing free Personal Team IDs privately.
export WORSHIPCUE_TEST_DEVICE_ID='<discovered-device-id>'
export WORSHIPCUE_TEST_TEAM_ID='<authorized-Personal-Team-id>'
python3 scripts/test_private_pdf_pair.py '/private/path/arrangement-A.pdf' '/private/path/arrangement-B.pdf'
```

`WORSHIPCUE_TOOLS_ROOT` and `WORSHIPCUE_XCODE_APP` use the same external-drive defaults as the existing native scripts. The tools/results root and input PDFs must be outside the repository. The helper stages byte-preserving copies in the installed app's Documents directory, builds the Debug native/UI targets, supplies an opt-in run UUID through an external xctestrun, and executes each case in a separate device session. It never edits the originals, normal user vault, notes or bookmarks. No chart is bundled into the app.

- **Native:** the real importer validates both files; all pages retain native geometry and PDF annotation counts; copies stay byte-identical; PDFKit renders are saved privately. A selected personal stroke is manually placed/scaled on the other geometry, then cancel/commit/undo/redo, page/version isolation and cold recovery are checked. It seeds a separate pristine chart vault for UI gestures.
- **UI:** on the last page, which has no embedded annotations in this pair, actual finger input creates visible blue pen and pink highlighter strokes. Only the selected pen stroke is copied; destination, preview position and scale are explicit. Cancellation, undo/redo, source preservation, page isolation and relaunch are verified.

The arranger's existing FreeText/Stamp/Square PDF annotations stay in the source chart. They are not editable personal PencilKit strokes, and the personal-note selection tool does not copy them. Their visual appearance must also be inspected in the private PDFKit renders; annotation counts alone do not prove fidelity.

Private PDFs, XCTest screenshots/results and detailed logs remain under the external tools root. Commit only code and content-free summaries. An executed passing private test is additional evidence, not a substitute for the synthetic suite, physical Apple Pencil, iPadOS 16, rotation/zoom/resume/thermal qualification, or a real multi-device rehearsal.

## M1 native-only qualification

The private native test also assigns the two supplied arrangements to one song as v1/v2, checks explicit preference/open separation, and compares the source-only exported PDF against the original native page renders. Use `--native-only` with the existing two PDF arguments to run this path and collect renders without starting UI automation. The default still runs both native and finger UI workflows; an unrun UI case is reported explicitly. Commands are bounded, retain nonzero exits, and store all private inputs/results outside Git. See `verification/M1.md` for actual new results rather than treating the historical M0 pass as current export evidence.
