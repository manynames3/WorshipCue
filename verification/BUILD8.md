# Readiness, preparation and personal export · v2 Build 8

Date: 2026-10-08 EDT. This is a development checkpoint, **not an end-user release or rehearsal qualification**. The user requested all currently achievable readiness work and a stakeholder infrastructure diagram. [Build 7](CHAT7.md) and all earlier evidence remain historical.

The [curated machine-readable receipt](build8-summary.json) records actual run counts, preservation/configuration outcomes and source hashes while omitting private identifiers.

## Implemented behavior

- **Calm cue area:** a fixed 76-point area covers idle, pending, accepted and ended states. Recent history stays separate. Large-text/narrow layouts use a shorter visible open label while retaining the full accessibility label. Receiving or reconciling a cue never navigates.
- **Clear workspace:** direct team/account and chat controls, active church/team/role labels, and explicit personal/team sources in Today and Library. Team browsing searches normalized titles, aliases and Korean initial consonants. Opening a prepared item retains its exact occurrence, performance key and shared-note context; repeated songs do not borrow another item's marks. Browsing, previewing and preparing do not acknowledge a live cue.
- **Truthful preparation:** bounded durable receipts distinguish verified PDF bytes from personal/team note confirmation. Each chart can be retried independently. Missing or damaged material clears stale readiness; access failures require review. Restored receipts are rechecked against the actual immutable manifest and local files.
- **Actionable recovery:** connection/access/integrity/storage failures expose the appropriate retry or review action. Import/metadata errors do not falsely report unsaved ink. Verified cache repair retains the damaged bytes in a protected recovery copy before atomic replacement; healthy immutable documents and changed receipts cannot be overwritten.
- **Personal cloud ZIP:** schema-2 manifest, own verified PencilKit/preview bytes and authorized source PDFs needed to interpret those notes, for the selected currently authorized team. SHA-256/byte-count checks and version/page geometry references are retained. Bounds are 1 GiB total, 100 MiB per PDF, 2 MiB per ink/preview asset and 65,535 ZIP entries. Streaming export runs off the main actor, fences account/team changes, atomically finishes and removes partial/cancelled jobs. The closed share flow cleans its temporary archive. It excludes local unsynced work, drafts, other teams, other people's data, shared team ink and credentials; it is **not a whole-account backup or an automatic restore**.
- **Bounded cloud refresh:** small catalogs pack sections into one authenticated page while retaining row/byte/work bounds, cursor semantics, independent transactional permission checks and guest/setlist revision fences. Exact-token/exact-team in-flight native requests can share one operation; completed results and failures are not cached. A cancelled waiter does not cancel another waiter. No automatic retry or per-device load pacing was introduced.
- **Stakeholder diagram:** a reviewed one-page [PDF](../output/pdf/worshipcue-infrastructure.pdf), [PNG](../docs/architecture/worshipcue-infrastructure.png), [editable SVG](../docs/architecture/worshipcue-infrastructure.svg) and [plain-language guide](../docs/architecture/README.md) show offline iPad work, managed sign-in, separate team libraries/chat/setlists, durable updates and backup/monitoring. Release gates are visible.

No new production dependency, automatic song change, page synchronization, automatic note merge/transfer, offline live replay, automatic team publication, account deletion or retention cleanup was added. V1/main and the prior Supabase implementation are preserved. Free Personal Team signing continues; no annual Apple enrollment, APNs, TestFlight, billing or public app release.

## Actual results

| Check | Exact result and scope |
|---|---|
| Latest full iPad native batch | **106 passed, 0 failed, 1 expected private-input skip; 107 total**, native exit 0, build-for-testing exit 0, iPad (6th generation)/iPadOS **17.7.11**. Actual PencilKit/PDFKit/local storage and controlled cloud responses; not real-account multi-device interactions. |
| Last adaptive cue change | **1 passed, 0 failed, 0 skipped**, build and focused test exit 0 after the full batch. Eight actual hosted renders cover cue states/widths. The 320-point, extra-large-text pending cue shows a complete short open label; component height remains 76 points. |
| Private arrangement pair | **1 required native case passed**, staging/build/native/collection exits 0. Both supplied four-page PDFs import, retain arranger marks and support deliberate transfer, recovery and export checks. **All eight fresh PDFKit page renders inspected**; no blank/displaced/rotated/corrupted pages observed. Original Mac PDF hashes unchanged. This is structural visual inspection, not pixel equivalence or physical Pencil input. |
| Touch UI batch | Build exit 0; test exit **65**; wrapper exit 1. **Zero actual workflow cases ran.** The result reports one runner error, “Timed out while enabling automation mode,” before the eleven selected cases. Not a passed touch workflow and not a demonstrated product-workflow failure. Direct on-device authentication/approval was requested; no bypass. |
| Portable core/local/reference | **55 core**, **14 local persistence**, **32 Python reference** tests and **9 InkChecks groups** pass, exits 0. Existing pinned reference dependency installed in an external isolated environment after the first missing-dependency attempt. |
| Swift remote transport | **31 passed, 0 failed**, exit 0. Includes exact-team in-flight coalescing, cancellation and scope separation alongside paging/security regressions. |
| AWS controlled suite | **190 passed, 0 failed**, exit 0, including **81 domain cases**. Provider fakes except actual PDF parsing. Helper counts can overlap this suite; do not add them together as independent coverage. |
| Actual hosted AWS | **27 passed, 0 failed**, exit 0, against deployed managed identity/HTTP/Lambda/DynamoDB/private S3/native Swift WebSockets and isolated synthetic data. Separate workspace-name/isolation checks **4/4 pass**. |
| Cloud package/deployment | **436,847-byte** package, existing **50-resource** development stack `UPDATE_COMPLETE`, Lambda update `Successful`, deployed code checksum matches the package. Resource definitions unchanged; no quota, billing, email or retention policy mutation. |
| Small catalog comparison | Identical authorized eight-row result: baseline **6 RPCs/26 gets/10 queries/6 ACL transactions** versus candidate **1 RPC/3 gets/8 queries/1 independent ACL transaction**. This bounded case is not a general performance measurement. |
| Raw 50-client burst | **48 passed, 2 failed**, exit 1. **155 attempts**, **18 HTTP 429**, **89 HTTP 503** responses; **6.149 s** elapsed, **5.903 s** p95. Bounded retries exhausted for two clients. Failed capacity qualification retained. |
| Separate paced comparison | **50 passed, 0 failed**, exit 0; 50 starts spread over five seconds, **50 attempts/no retries**, **5.248 s** wall time, **0.382 s** request p95, **0.399 s** max. This is a test-harness arrival mode, not shipped client pacing or 50-user readiness. |
| Load scope | Both runs use two existing synthetic managed identities and one first-page read per simulated client. No WebSocket fanout, sustained rehearsal or full-user session qualification. Shared Lambda concurrency quota remains **10**. Load/smoke helper self-checks **7/7** and **5/5** pass. |
| Native build/configuration | Final Release build exit **0** after the adaptive cue change. Build **8**, version **0.0.1**, minimum **16.0**, AWS endpoints match private configuration; **9 bundle checks** pass. Native Debug app/hosted/UI targets compile. External Xcode **27.0 / 27A266a**, Swift **6.4**; no simulator runtime installed. |
| Project/localization | **19 app/4 hosted/1 UI Swift sources** included; resource/scheme/catalog verifier passes. Reproducible Build-8 generator and **650 Korean catalog keys**; actual compiler string extraction found no missing keys. |
| Existing normal iPad store | Before/after tests and normal launch: all **7 original PDF paths/bytes** and every column of **3 personal-ink records** identical; both SQLite `quick_check` results **OK**. No reset, fixture substitution or normal-store deletion. |
| Installed normal app | Read-only exact-bundle inventory exit **0**, confirms **Build 8 / 0.0.1**. Normal process launch with no test arguments accepted, exit **0**. A fresh normal full-screen capture was not obtained; hosted view captures below have a separate scope. |
| SES/operations | Final read at **2026-10-09 02:21:26 UTC / October 8 22:21 EDT**: review **DENIED**, production access **false**, sending **true in sandbox only**. All **6 exact operational alarms OK**, actions enabled and scoped configurations verified. Deployed code also matches every current backend source file. Support follow-up receipt is preserved; submission is not approval. |

## Rendered native views

These are **actual hosted views on the iPad**, using synthetic material and controlled transport. They verify rendering and isolated model actions, not full touch automation, real-account cloud UX or a complete normal running screen.

| View | Evidence |
|---|---|
| Team library, current team and explicit chart open | [Rendered library](build8-team-library.png) |
| Per-chart PDF/note preparation and individual retry | [Rendered checklist](build8-team-preparation.png) |
| Exact prepared-item/team-chart preview | [Rendered preview](build8-prepared-preview.png) |
| Selected-team cloud export scope/preflight | [Rendered export](build8-personal-export.png) |
| Narrow pending cue with large text | [Rendered cue](build8-cue-compact.png) |

Wide and narrow library/preparation views, preview, export preflight and cue states were visually inspected. Private PDF renders, personal handwriting, identifiers, signing setup, credentials and raw results remain external and are not committed.

## Retained failures and corrections

The initial full device suite returned **103 passed/2 failed/1 skipped**, total 106, exit 65. Both failures were in verification assumptions:

1. PencilKit legitimately reserializes a decoded drawing (775 versus 753 bytes). The corrected test asserts the saved base64 archive exactly equals the original committed bytes, then compares decoded tools/path geometry. Note durability was not weakened.
2. The host fitting size included a 20-point safe area. The corrected test measures the actual cue component as **76 points** and subtracts the measured host safe area, retaining the 76-point product requirement.

Both focused tests subsequently passed, followed by a **105-pass/0-failure/1-skip** full rerun. A new wide/narrow team-browser render case then brought the final full batch to **106 passes/0 failures/1 skip**. Those renders exposed a large-text cue action wrapping outside its allotted area; the adaptive visible label was corrected, rendered and passed separately. Release was rebuilt after this last production change. The last full-suite result and final focused result are separate runs.

Initial sandboxed portable builds stopped before tests at `XCBuildData` manifest permissions (`EPERM`). Narrow authorized external builds passed. The first Python reference attempt could not import its existing `jsonschema` dependency; after installing its already-pinned development requirement in the external environment, **32/32** passed. No failed attempt was relabeled as a pass.

The first backup inspection queried a nonexistent `ink_pages` table; the app-data copy itself succeeded. Inspection was corrected to the actual `personal_ink` schema, and the final comparison includes every stored column. The raw load failure and touch-runner failure remain unresolved; the paced load pass does not erase them.

## Executed commands and private evidence

All paths below are relative to the repository unless absolute. Build/cache/results live on the external drive. Device/signing values came from the actual private inventory and existing authorized Personal Team. Tokens/endpoints/identities are never copied into this report.

```sh
sh scripts/with_external_xcode.sh swift test --package-path reference/WorshipCueCore \
  --disable-sandbox --cache-path ../DeveloperTools/WorshipCue/SwiftPMCache \
  --scratch-path ../DeveloperTools/WorshipCue/CorePackageBuild-M1
sh scripts/with_external_xcode.sh swift test --package-path packages/WorshipCueLocal \
  --disable-sandbox --cache-path ../DeveloperTools/WorshipCue/SwiftPMCache \
  --scratch-path ../DeveloperTools/WorshipCue/LocalPackageBuild-M1
sh scripts/with_external_xcode.sh swift run --package-path packages/WorshipCueLocal \
  --disable-sandbox --cache-path ../DeveloperTools/WorshipCue/SwiftPMCache \
  --scratch-path ../DeveloperTools/WorshipCue/LocalPackageBuild-M1 InkChecks
../DeveloperTools/WorshipCue/ReferencePython/bin/python3 scripts/verify_package.py

# Device and signing environment variables were supplied privately.
python3 scripts/test_m1_device.py --group native --full-native
python3 scripts/test_private_pdf_pair.py '<private PDF A>' '<private PDF B>' --native-only
python3 scripts/test_m1_device.py --group ui --regressions --batch-ui --command-timeout 600
python3 scripts/verify_m0_project.py
python3 scripts/verify_native_configuration.py \
  --app '../DeveloperTools/WorshipCue/DerivedData-AWS/Build/Products/Release-iphoneos/WorshipCue.app' \
  --provider aws --aws-config '../DeveloperTools/WorshipCue/AWS/private-config.json' --build-number 8
```

The native script performs `build-for-testing` on the discovered exact device, then `test-without-building` with parallel testing disabled and a fresh result bundle. The final cue case was separately selected with `-only-testing:WorshipCueTests/TeamWorkspaceTests/testRenderedCueBannerReservesHeightAcrossIdlePendingAcceptedAndEnded`; its raw invocation and bundle are retained locally. Release used scheme `WorshipCue`, configuration `Release`, generic iOS destination, external DerivedData/source packages and `CODE_SIGNING_ALLOWED=NO build`.

Cloud/transport entry points used below refer to the existing private external AWS folder and private qualification state. The AWS controlled suite uses the approved external parser vendor and `aws/src` in its Python import path; no credentials are required by those controlled tests.

```sh
PYTHONPATH="$WORSHIPCUE_AWS_DIR/vendor:aws/src" python3 -m unittest discover -s aws/tests
python3 aws/scripts/load_check.py --self-test
python3 aws/scripts/smoke.py --self-test
sh scripts/with_external_xcode.sh swift test --disable-sandbox \
  --package-path packages/WorshipCueRemote --scratch-path /absolute/external/Build8RemoteScratch \
  --cache-path /absolute/external/Build8RemoteCache --manifest-cache local
python3 aws/package_backend.py --output "$WORSHIPCUE_AWS_DIR"
python3 aws/scripts/deploy.py --config "$WORSHIPCUE_AWS_DIR/private-config.json"
python3 aws/scripts/smoke.py --config "$WORSHIPCUE_AWS_DIR/private-config.json" \
  --state-directory "$WORSHIPCUE_AWS_DIR/HostedSmoke"
python3 aws/scripts/load_check.py --config "$WORSHIPCUE_AWS_DIR/private-config.json" \
  --state-file "$WORSHIPCUE_AWS_DIR/HostedSmoke/qualification-state.json" --clients 50
python3 aws/scripts/load_check.py --config "$WORSHIPCUE_AWS_DIR/private-config.json" \
  --state-file "$WORSHIPCUE_AWS_DIR/HostedSmoke/qualification-state.json" --clients 50 \
  --arrival-window-seconds 5
```

Raw native evidence under `../DeveloperTools/WorshipCue/Results/`:

- Final full batch: `M1-2ad3b9f3-465d-4701-b686-0fa27237dc21/native.xcresult` and `results.json`.
- Earlier red batch: `M1-a361bd4a-f3ff-4523-9f19-819de4f7eaed/native.xcresult`.
- Corrected full rerun: `Build8-final-native-914e86c4-bde1-4788-b796-9a6b18a49e0c/`.
- Final adaptive cue: `Build8-final-cue-cf3e7f4c-05c9-4fa6-b9bb-e9969c8a3e8f/`.
- Private PDF: `../PrivateChartTests/F9A5DC75-BF23-44B2-BDBA-2AB090EBE238/` relative to Results; `build8-private-pdf-result.json` records immutable Mac sources.
- Touch runner: `M1-f995a8b1-938e-44b4-8115-5823753f2a88/ui-batch.xcresult` and `results.json`.
- Release: `build8-release-qualified.log/result.json`; portable checks: `build8-*-verified-escalated.log`, `build8-reference-verified.log` and matching result files.
- Normal app/preservation: `build8-installed-result.json`, `build8-preservation-result.json`; protected before/after copies under external `PrivateBackups/Build8-f568695a-0355-4c28-8b3f-a3f528d48dc4/`.

Cloud receipts live in protected external `../DeveloperTools/WorshipCue/AWS/Build8Qualification/`: `deployment.log`, `deployment-verification.json`, `hosted-functional.log`, `workspace-names.json`, `load-raw-50.log`, `load-paced-50.log`, `current-operational-status.json`. Public counts here exclude private API/account/device identifiers. See [AWS commands](../aws/README.md) for the existing packaging, controlled tests, deployment and hosted checks.

## Remaining release gates

SES production access for general recipients; a representative concurrent workload beyond the ten-execution development quota; real-account two-iPad handwriting/cues/chat; physical Pencil/palm behavior; original iPadOS **16.7.16** runtime; maximum-file, disk-pressure, offline/reconnect/resume, thermal/memory and two-hour rehearsal checks remain **NOT VERIFIED**. The touch test runner must actually initialize and run before new touch workflows can be claimed.

The previously qualified small metadata/file restore does not prove larger multi-invocation recovery. Operator inbox receipt, support/response ownership, approved deletion/retention policy and complete-account/local-unsynced export remain unresolved. No irreversible cleanup or account-deletion job is enabled. Free signing is for local development; release distribution awaits the user's later Apple enrollment and release authorization.
