# M1 / v2 independent local qualification

Executed 2026-10-08 on macOS **27.0.1 (26A434)**, arm64, scoped Xcode **27.0 (27A266a)** / Swift **6.4**. This report covers independent Mac checks of the existing local rehearsal workflow. It does not claim an iPad UI run, physical Pencil qualification, UIKit export qualification or a hosted backend.

The starting checkout was v2 commit `4036007716b1ff0013fe357f591d092298ad2f2f`. The portable/library runs below completed before the concurrent M2 cache/outbox additions. The private harness compiled an exact, hash-checked copy of that commit's `DocumentVault.swift`, without modifying it. Its other production dependencies are the existing `WorshipCueLocal` and `WorshipCueInk` packages. Newly added remote-cache/CAS behavior is not inferred to pass from these existing-API checks and needs its separate current tests.

No repository production source or tests were changed by this qualification task. No physical device, signing setup, normal app vault, original musician input, cloud account or backend was altered. Inputs, private renders, SQLite stores, ephemeral harness sources, binaries and full logs stay outside Git on the external drive. Private result directories are restricted to the current user.

## Exact commands and results

All native commands were scoped through `sh scripts/with_external_xcode.sh`; no global Xcode selection was changed. `$TOOLS` is the external `DeveloperTools` directory beside this repository. Each build used an external scratch path; each temporary store used a new UUID namespace.

| Executed check | Result |
|---|---|
| `sh scripts/with_external_xcode.sh swift test --package-path packages/WorshipCueLocal --scratch-path "$TOOLS/WorshipCue/LocalPackageBuild-M1-v2-local"` | **Exit 0; 8 tests passed, 0 failures.** Numbered immutable versions, preference/bookmarks, rollback, legacy migration, search/favorites, wrong-song guards, setlist repeats/reorder/clone/revisions and packet provenance. |
| `sh scripts/with_external_xcode.sh swift run --package-path packages/WorshipCueLocal --scratch-path "$TOOLS/WorshipCue/LocalPackageBuild-M1-v2-local" InkChecks` | **Exit 0; 9 check groups passed.** Durable heads/outbox, exact layer identity, stale/conflicting saves, geometry/size guards, injected transactional failure, rotations/CropBox transforms, exact team gating, delayed restore and corrupt address rejection. |
| `sh scripts/with_external_xcode.sh swift test --package-path reference/WorshipCueCore --scratch-path "$TOOLS/WorshipCue/CorePackageBuild-M1-v2-local"` | **Exit 0; 55 tests passed, 0 failures.** These are executable domain contracts, not a real backend or multi-device test. |
| `sh scripts/with_external_xcode.sh /tmp/worshipcue-reference-verification-venv/bin/python3 scripts/verify_package.py` | **Exit 0; 32 tests passed.** Existing isolated verification environment; no dependency installation. |
| `sh scripts/with_external_xcode.sh swift build --package-path packages/WorshipCueInk --scratch-path "$TOOLS/WorshipCue/FrameworkPackageBuild-M1-v2-local" --product FrameworkChecks` | **Exit 0.** |
| `sh scripts/with_external_xcode.sh "$LOCAL_RESULTS/FrameworkChecks.app/Contents/MacOS/FrameworkChecks" "$REPO"` | **Exit 0; 4 Mac framework check groups passed.** Actual PencilKit archive through production SQLite/reopen/decode; selected-stroke clipboard and uniform placement; native PDFKit CropBox/rotation; corrupt-PDF rejection. The executable was placed in a real macOS `.app` bundle as required by the existing framework harness. |
| `sh scripts/with_external_xcode.sh swift build --package-path "$PRIVATE/MacHarness" --scratch-path "$PRIVATE/Build" --product PrivatePDFChecks` (qualified harness) | **Exit 0.** Exact production vault, local catalog/ink packages and PencilKit clipboard; private executable bundle, no app target or production dependency added. |
| `sh scripts/with_external_xcode.sh "$PRIVATE/QualifiedPrivatePDFChecks.app/Contents/MacOS/PrivatePDFChecks" "$PRIVATE/Qualified-cfd9ecbd-6c6d-49e1-860f-debfa0cfa03e"` | **Exit 0; 5 private Mac check groups passed.** Scope below; not an iPad run. |

Portable/framework raw results: `M1-v2-local-b797da8a-b26c-439f-9c55-a94fbfdce6a3`, under `$TOOLS/WorshipCue/Results/`. `$LOCAL_RESULTS` denotes that directory; `$REPO` denotes this repository's absolute path.

Private raw results: `M1-v2-mac-4972f8b1-34bf-4cd8-a77c-59a3b55e5536`, under `$TOOLS/WorshipCue/PrivateChartTests/`; `$PRIVATE` denotes that directory. The local `results.json`, private build/run `*-result.json`, qualified `result.json`/`qualification.json`, source/binary receipts and logs record actual commands/results. The exact qualified UUID above must match `qualified-location.json`; no private PDF path, score content or handwriting appears in this report.

## Real arrangement pair

Both user-supplied files were copied byte-for-byte into a new private namespace as A/B. Each contains four pages. They were explicitly assigned to one local song as two versions; there was no inferred arrangement order, layout matching or note merging.

1. **Immutable import / geometry:** the exact production vault validates and imports both files, preserves all eight native page geometries and annotation counts, and retains byte-identical source copies. Versions have separate UUIDs/receipts and numbers 1/2. Opening B preserves preference A; B's local bookmark survives reopening.
2. **Arranger markings:** native PDFKit rendered every original page. Removing annotations on a separate copied page changes the pixels on every annotated page, demonstrating visible output rather than relying only on counts. All eight private source renders were inspected. The last page of each arrangement has no embedded annotations. Existing markings remain part of the source PDF, separate from personal PencilKit strokes.
3. **Selected personal note:** two synthetic native PencilKit strokes were saved on A/page 0. The production clipboard copies only the selected stroke with its exact source address/geometry, rejects zero/infinite scales, and explicitly places/scales it on B's different geometry. Preview computation writes nothing; an explicit destination save preserves the exact source archive. A fresh store decodes two source strokes, one destination stroke, and no ink on B/page 1. This checks the clipboard/store seam, not iPad cancel/confirm/undo gestures.
4. **Setlists / recovery:** the real imported chart IDs populate planned and standby entries with repeated occurrences. Reorder, stale-revision rejection, clone occurrence isolation, catalog reopening and per-version bookmark recovery pass through the production local store.
5. **Manual packet extraction:** B was manually split into inclusive ranges 1–2 and 3–4 through the exact production vault. All four derived pages retain geometry, annotation count/type/bounds/contents and the source base-content pixels. Their native renders were inspected. A valid/invalid-key batch fails atomically, publishes no partial versions and cleans only its new derived files. Original input/imported PDF bytes remain unchanged.

## Failures and packet diagnosis retained

The first private harness build exited **1** because the throwaway harness used `LibraryError.staleRevision` instead of the existing `staleSetlist` case. Only the private harness spelling was corrected; its initial log remains external. The corrected build exited **0**.

Two separate fresh-store executions of the first strict harness exited **1** at `packet-render-fidelity`, after the first four groups passed. That initial check required every thumbnail pixel to be identical after PDFKit page-copy serialization. The failures were not converted into passing commands.

A focused diagnostic build/run both exited **0**, with no fidelity pass claimed. Repeated source rendering was pixel-identical. Removing annotations from independent source/derived copies made all four base pages pixel-identical. Differences were confined to serialized annotation appearances:

| Original B page | Annotated mean channel error, 0–255 | Annotation-free mean error | Changed channels / total |
|---|---:|---:|---:|
| 1 | 0.0029966114 | 0 | 1,048 / 3,423,200 |
| 2 | 0.0001486913 | 0 | 190 / 3,423,200 |
| 3 | 0.0000674807 | 0 | 88 / 3,423,200 |
| 4 | 0 | 0 | 0 / 3,423,200 |

All derived renders were visually inspected against the originals; no missing/repositioned base content or arranger marking was observed. The qualified harness uses the **already established native M1 render criterion, mean error < 5**, and additionally requires exact annotation type/bounds/contents and exact annotation-free pixels. Its fresh run exits **0** with all five groups passing. No repository specification, production importer or existing test assertion was weakened or edited. This finding does not establish pixel identity for serialized annotation appearances.

## Requirements not verified by these Mac checks

- Current iPad Files-provider import/save, v2 controls, finger gestures, actual copy/paste cancel/confirm/undo/redo, palette dismissal, UIKit share sheet and the actual `PDFExporter` require separate device evidence. This harness cannot compile the UIKit exporter on macOS and does not substitute a different implementation.
- Physical Apple Pencil pressure, palm rejection, latency, selection behavior, rotation/zoom while writing, lifecycle/interrupted-save, offline network transitions, disk-full behavior across all new paths, memory/thermal measurements and two-hour rehearsal remain unverified here.
- The original iPadOS **16.7.16** device and two real iPads remain release gates. Deployment minimum 16.0 and Mac package passes do not prove that runtime.
- Managed accounts/workspace, tenant RLS, invitation/guest scope, personal sync conflicts, shared team ink and live tap-to-open cues require their own current integration tests. No cloud publication, annual Apple enrollment, automatic song changes, page sync or automatic note merging occurred in this qualification.

The local Mac checks support continued implementation and device qualification. They do not make WorshipCue rehearsal-ready or end-user-ready.
