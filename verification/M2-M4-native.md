# Build 5 · Local rehearsal and private-team native evidence

Executed 2026-10-08 on branch `v2`, marketing 0.0.1 / Build **5**, minimum **iPadOS 16.0**. Mac: macOS 27.0.1 arm64, scoped external Xcode **27.0 (27A266a)** / Swift **6.4**. Physical device: **iPad (6th generation), iPadOS 17.7.11**. V1/main remain at `45c813977affb102e55737aac74dcb58428a43ee`; the starting v2 commit was `4036007716b1ff0013fe357f591d092298ad2f2f`.

This is implementation and development evidence, **not a hosted Supabase deployment, full milestone acceptance, end-user readiness or rehearsal sign-off**. Managed service configuration is empty. No paid Apple Developer enrollment, cloud deployment, billing, automatic song change, page synchronization, automatic note merging or offline live replay occurred.

## Implemented

- Existing local immutable PDF/library/setlist/packet/exact personal-ink workflow is preserved. Published team PDFs are additionally verified for hash, length, native PDF parse and exact page geometry before atomic cache publication. Imports/preflight/preferences do not navigate.
- Foundation-managed Auth/RPC/Storage transport and Realtime invalidation hints in `WorshipCueRemote`, with no new SDK dependency. HTTPS/publishable-key validation rejects secret/service-role keys. Managed OTP/anonymous/refresh shapes, bounded downloads and current-session-only logout are implemented.
- Protected server/account/church vaults and device-only Keychain tokens. Old account responses cannot populate the next account's catalog, conflicts, drafts, view or private store. Original local material is not silently uploaded.
- Shared immutable charts and setlists, member/guest scope, source-PDF publication with a rights confirmation, fresh catalog/preflight and separate offline preferences. Existing exact team native snapshots and clean owner heads prepare without selecting a reader. Guest ink remains local.
- Personal note outbox migration, immutable attempted commands/frozen payloads, numeric revision CAS, descendant-parent rebasing, monotonic accepted heads and explicit two-copy conflict resolution. No automatic merge. Native installation freezes/checks canvases before advancing storage; active/debounced/in-flight local strokes take precedence.
- Exact occurrence/version/page read-only team ink, separate local editor drafts and native/PNG publication, lease takeover/fencing, frozen uncertain payloads and manual whole-copy replacement preserving both copies. A committed publication remains successful when a following display refresh fails. Unknown offline ink does not hide a verified PDF or trap a durably saved prior-page draft.
- Visual latest pending cue, separate recent history, explicit tap-to-open using a preferred or explicitly selected version, cancellable async opens, rendered-only acknowledgement, ad-hoc occurrence identity, durable terminal session end and cold/offline reader restoration. Incoming hints, downloads, account preference changes, reconnect and end do not switch the reader. Page changes send no live events.
- Korean catalog entries extracted by the Swift compiler. Unconfigured team UI honestly reports setup pending and keeps the local workflow usable. Controller controls match the selected setlist's lease/live session.

## Exact completed commands and results

`$TOOLS` denotes the external `DeveloperTools` directory beside this repository. Native/package commands use `sh scripts/with_external_xcode.sh`; device/signing values are supplied privately through the already authorized environment and are not stored here. Raw logs, xcresults, staging inputs, signing material and backups remain outside Git.

| Check | Result and raw evidence |
|---|---|
| `python3 scripts/test_m1_device.py --group native --full-native --command-timeout 300` | **Build exit 0; native exit 0; 34 passed, 0 failed, 1 expected private-input skip, total 35.** Final bundle `$TOOLS/WorshipCue/Results/M1-c9370cf5-d183-4898-971c-59ce9aab4a7b/native.xcresult`. |
| `python3 scripts/test_m1_device.py --group ui --only team-setup --command-timeout 240` | **Build exit 0; UI exit 0; 1 passed, 0 failed/skipped.** `$TOOLS/WorshipCue/Results/M1-4277e9dd-7497-4e65-8a91-fba31dbeab9d`. Pen stroke, chart/page retained across opening/closing unconfigured team setup; stored ink remains visible after cold relaunch. |
| `python3 scripts/test_private_pdf_pair.py "$PRIVATE_A" "$PRIVATE_B" --native-only` | **Stage/build/native/collect exit 0; 1 native private case passed, 0 failed/skipped.** `$TOOLS/WorshipCue/PrivateChartTests/81B2C511-1299-4D43-B0CB-E03FE94B017B`. Current source through this checkpoint; no UI run in this invocation. Later fixes affect remote paths and are covered above. |
| `swift test --package-path reference/WorshipCueCore --scratch-path "$TOOLS/WorshipCue/CorePackageBuild-M1-v2-local"` | **Exit 0; 55 passed, 0 failed.** `final-reference-d2a2bd4b-5605-49bf-bb95-553469a4e0ee/core.log`. |
| `swift run --package-path packages/WorshipCueLocal --scratch-path "$TOOLS/WorshipCue/LocalPackageBuild-M1-v2-local" InkChecks` | **Exit 0; 9 check groups passed.** Same external result directory, `ink.log`. |
| `/tmp/worshipcue-reference-verification-venv/bin/python3 scripts/verify_package.py` | **Exit 0; 32 passed.** Same result directory, `reference.log`. Uses the existing isolated verification dependency. |
| `python3 scripts/verify_m0_project.py` | **Exit 0.** Same result directory, `project.log`: source/resources/package references, both hosted files and schemes verified. |
| `swift test --package-path packages/WorshipCueLocal --scratch-path "$TOOLS/WorshipCue/LocalPackageBuild-M1-v2-local"` | **Exit 0; 14 passed, 0 failed**, including 6 durable sync cases. Earlier exact log `local-sync-70c8edb5-4b4c-4ce4-ae80-ee8274e04b73.log`; final rerun recorded below. |
| `swift test --package-path packages/WorshipCueRemote --scratch-path "$TOOLS/WorshipCue/RemotePackageBuild"` | **Exit 0; 11 passed, 0 failed.** Earlier exact log `remote-aee50dc0-a90b-4cc5-8a75-94f5d4c358a9.log`; final rerun recorded below. |
| Independent Mac local/framework/private checks | **8 local tests, 9 ink groups, 55 core, 32 reference, 4 real framework groups and 5 private arrangement groups passed** at their documented source checkpoint. [Exact independent scope/results](M1-v2-local.md). These do not replace the current native checks. |
| Local backend | **13 PostgreSQL integration groups, 7 Deno handler cases, lint/fmt/check passed.** [Exact backend scope/results](M2-M4-backend.md). SQL uses actual non-owner RLS with test Auth/Storage schemas; Edge uses controlled HTTP responses. |

The 15 final workspace-adapter cases exercise the real UIKit/PDFKit/PencilKit reader, protected native stores and actual Foundation transport through controlled URLProtocol responses. They cover:

1. Incoming latest/history leaves chart/page/exact private ink/preference/displayed-call preview context unchanged.
2. Offline cold source/page/preferences/acknowledgement recovery without live replay.
3. User navigation cancels an in-flight cue open and its acknowledgement.
4. End is durable and terminal even after an older LIVE response.
5. Different off-setlist songs with the same key get distinct uncertain commands/occurrences.
6. Draft publication freezes edits and preserves an identical retry payload.
7. Preflight refreshes catalog and personal heads without navigation.
8. Accounts in the same church keep independent chart/page/private ink namespaces.
9. A frozen personal predecessor acknowledgement rebases a later local snapshot to the correct numeric parent.
10. Actual downloaded personal/team native archives restore offline as separate exact layers.
11. A delayed old-account conflict cannot enter the next account or its partition.
12. Same-chart manual reopens preserve the acknowledged occurrence, key and read-only team layer.
13. Verified multi-page team paper remains readable without cached ink; a saved previous-page draft remains accessible without trapping the editor.
14. A paused personal head/download cannot advance storage beneath an active local canvas stroke; pen-up/flush saves the exact local archive.
15. An accepted publication remains successful if a subsequent head/display refresh fails, without issuing a changed retry command.

These are **not actual Supabase Auth, Storage, Realtime or multi-iPad tests**. The 15-second polling fallback and socket hints remain subject to real service qualification.

## Final portable and Release reruns

- `final-packages-3a59391f-d258-4220-9ffe-d0ba717aa3cf/local.log`: **exit 0, 14 tests / 0 failures**; `remote.log`: **exit 0, 11 tests / 0 failures**, external `$TOOLS/WorshipCue/Results`.
- Final app-source Release command: `sh scripts/with_external_xcode.sh xcodebuild -project apps/ipad/WorshipCue.xcodeproj -scheme WorshipCue -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$TOOLS/WorshipCue/DerivedData-Team-Release" -clonedSourcePackagesDirPath "$TOOLS/WorshipCue/SourcePackages" SDK_STAT_CACHE_DIR="$TOOLS/WorshipCue/DerivedData-Team-Release" CODE_SIGNING_ALLOWED=NO build` — **exit 0 / BUILD SUCCEEDED**. Exact log `team-final-release-181f49a8-4600-4617-8206-e98421c643e7.log`. Built Info.plist verifies Build 5 / minimum 16.0 / no configured service URL or key. This generic-device unsigned build does not prove original-device execution.
- Curated report links, project Python syntax and `git diff --check`: **exit 0**. Source catalog has 386 compiler-extracted Korean keys. Explicit main/v1 commit checks retain the frozen checkpoint.
- Independent security/race review found the issues covered by final workspace cases 12–15. The final read-only pass found no further concrete blocker in those paths; it is code inspection, not managed-service or physical input verification.
- Actual UI attachments from the team-setup, recovered reader and weekly preparation workflows were exported and inspected: readable Korean status, close control, separated planned/standby rows, explicit key mismatch and local preflight result. These use synthetic scores and isolated stores. Two inspected synthetic captures are included as `m2-v2-reader.png` and `m2-team-setup.png`; private arrangement captures remain outside Git.

## Real arrangement inputs and visual inspection

Both supplied arrangements have four pages. The opt-in native case checks immutable original/imported source bytes, preserved embedded arranger annotation identities/geometry, personal version/page isolation, explicit selected-note transfer, reopening and actual fallback PDF rendering against the established native criterion. All eight fresh source renders were inspected privately; distinct arranger colors/markings remain visible, and the final pages remain unannotated as in the inputs. No score text, musician notes, raw filenames or pixels are committed. The full opt-in UI workflow was not rerun in this invocation.

## Failures retained

- Initial SwiftUI/native compilation errors while connecting the new transport, closures and test shapes were corrected; raw build logs remain external. The private test transport originally left a fire-and-forget logout task running after invalidation. `M1-ce2f4bcc-1633-471d-a547-9b7fe5f4bbb6`: build 0, native **65**, 22 passed / 4 failed / 1 skipped, total 27. The client now clears local account state first and awaits a bounded scoped Auth logout. Later full 28/30/34-case runs pass.
- `M1-baebb2bb-49ef-4cec-9611-3560e104159e`: build **65**, tests did not run; a new test incorrectly treated the read-only UIImageView as a PKCanvasView. Assertions now verify the restored archive and actual read-only rendered image; production representation was preserved.
- `M1-414c5863-f6f2-4340-a997-04949770c652`: build 0, native **65**, 33 passed / 1 failed / 1 skipped, total 35. The new offline-paper test incorrectly expected two pages in the three-page synthetic A2 fixture. Only that fixture expectation was corrected; all three pages and the upper bound are now exercised. Final suite is 34/0/1 above.
- Earlier local UI attempt `M1-f8e6e438-a098-460d-a641-01b120b83122`: workspace and export passed individually; packet/clone/v2 commands each timed out (124) before complete case evidence. These are not passes. Later current results are recorded below.
- Early transport XCTest HTTP body assertions failed because Foundation delivered a body stream; the test inspects the actual stream. The exact initial failure logs remain external. No production response-size, key, hash, geometry, identity or CAS validation was weakened.

## Current UI command limits and diagnosed Screen Time gate

`M1-3c9acbd3-cae0-4f51-a55d-190788aca46d`: build **exit 0**, workspace **exit 0 / 1 passed**. The export command hit **124**, with an incomplete xcresult (no readable summary). Its remote raw case eventually logs a **22.596-second case pass**, but the command/result bundle remains unverified. The next packet command was interrupted during runner diagnosis before any case began; clone/v2/colors were not run in that driver. `interrupted-results.json` retains those distinctions. The outer interrupted helper exits **241**; this is not a passing suite.

A single-session retry (`--group ui --regressions --only export-ui packet clone v2 colors --batch-ui --command-timeout 420`) in `M1-ddc32da6-d88e-4530-944a-02483ef7b30b` builds **exit 0**, then hits **124**, with no readable test summary or completed selected cases. No combined UI pass is claimed.

Public CoreDevice probes show a responsive development connection and unlocked device, with no matching app/test process at the sampled stall. Directly launching the observed test-runner bundle exits **0**; the read-only USB display then shows **“Time Limit — You've reached your limit on WorshipCueUITests-Runner.”** This is a concrete Screen Time gate separate from the regular app. The user was asked to complete the iPad's normal Ignore Limit / Ask For More Time approval directly. No Screen Time setting/passcode was changed or bypassed. The USB preview never recorded. Subsequent affected UI checks require that approval; elapsed time is not approval.

## Normal-store preservation and installed build

Before Build 5, a fresh protected external backup (`pre-team-75791ab1-4e4d-4919-ac7b-694be8b23a5e`) contained **7 PDFs / 3 private ink rows**. Post-update public CoreDevice copy-from exits **0**, saved to `post-team-f98b790b-21d7-4cfa-9f91-45cdc8884fda` under `$TOOLS/WorshipCue/PrivateBackups`. The qualified comparison exits **0**: all seven original relative PDF paths and SHA-256 bytes match, all three original layer keys/address/geometry/generation/archive columns match exactly, and both pre/post SQLite databases return **ok** from `PRAGMA quick_check`. Seven PDFs and three rows remain; no normal store reset/overwrite occurred.

The first comparison exited **1** because the private backup's vault was under `vault/` while the new copy root was `WorshipCueM0/`. Its raw `preservation.json` is retained. A diagnostic confirmed identical seven-file basename/hash sets, then the corrected comparison explicitly normalized only those backup roots and compared exact per-vault relative paths and bytes. `qualified-preservation.json` records the final pass; no app file or note was changed to obtain it.

The latest signed device app's deep/strict signature check exits **0**; Info.plist is Build **5**, minimum **16.0**, unconfigured service. Device native and passing UI commands install this build. The native reader UI render is separately inspected from the isolated passing team-setup workflow, not from the musician's normal store. The normal app is not claimed visually requalified during the Screen Time-blocked test-runner prompt.

## Requirements still unverified

- A pinned production PDF parser dependency is awaiting explicit approval under the user's no-new-production-dependency rule. The shared finalizer handler is tested with an injected PDF validator; its deployable entry and actual server PDF parsing tests remain unfinished. Cloud file publication cannot be called end-to-end verified.
- No approved Supabase project/configuration or running local Supabase stack: managed OTP/email/anonymous lifecycle, private Storage HTTP, Realtime authorization/delivery/token refresh/recovery, invitation abuse settings and backup/restore are unverified. No cloud account/schema/function/billing change occurred.
- Two actual iPads, physical Apple Pencil/palm rejection/pressure/latency, original iPadOS 16.7.16 runtime, actual 50-client network faults, memory/thermal/resume, disk-full in all new paths and a two-hour rehearsal remain physical/service gates.
- Account export/deletion, rights removal and retention workflows remain required before wider distribution. Offline downloaded files cannot be remotely erased by revoking a guest.
- Release/device installations use the existing free development setup. No App Store/TestFlight/public distribution is claimed.
