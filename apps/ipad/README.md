# WorshipCue native iPad app

Native SwiftUI/PDFKit/PencilKit workspace. **v2 / Build 7** extends the concept-based reader and user-selected AWS workspace with compact chat, team administration, durable publication retries, bounded catalog loading and owner-record export. Local PDFs, personal ink, setlists, search, manual transfer and PDF export continue without a server. The AWS workspace supports managed login, scoped invitations, immutable shared charts, protected personal sync/conflicts, exact team handwriting and visual tap-to-open cues. See [Build 7 evidence](../../verification/CHAT7.md); [Build 6 AWS](../../verification/AWS.md), the earlier Supabase implementation and Build 5 evidence remain preserved.

Build 3 is preserved as branch/tag **v1**, and `main` stays there. Minimum **iPadOS 16.0**. Current native/device and controlled-HTTP evidence is in [Build 5 evidence](../../verification/M2-M4-native.md); independent SQL/Edge evidence is in [backend evidence](../../verification/M2-M4-backend.md). [V2 design](../../verification/V2.md) and [v1/M1](../../verification/M1.md) reports retain prior results.

Physical Apple Pencil and original iPadOS 16.7.16 runtime qualification remain **NOT VERIFIED**. Earlier M0, color/icon and private-PDF evidence remains in [M0 history](../../verification/M0.md), [Build 2 history](../../verification/M0-colors-icon.md) and [private-pair evidence](../../verification/M0-private-pdf-pair.md). Separate passing sessions do not imply pilot readiness.

Build 7's latest physical iPadOS 17.7.11 run executed **86 cases: 85 passed, one optional private-PDF case skipped, zero failures**. It includes 46 workspace, 10 administration, 10 owner-export and 20 ink cases. Release, generic-device Debug and nine bundle checks pass. The separate 11-case touch UI retry failed before any case executed because UI automation timed out. The hosted/native tests use isolated synthetic stores and controlled network responses; they do not qualify a real multi-iPad rehearsal. A separate opted-in private-PDF case passed with eight PDFKit page renders. Normal Build 7 launch without test arguments preserved the existing seven PDFs and three ink files.

Open `WorshipCue.xcodeproj`, scheme `WorshipCue`. GRDB 7.11.1 requires Swift 6.1 / Xcode 16.3 or newer; use a supported stable Xcode. Signing uses the existing development identity through a private command-line team override; no team identifier or credential is checked into this project. Signed app compilation and signature verification pass. The current Xcode27 profile includes the17.7.11 test iPad and expires2026-10-14T22:45:20Z; the older profile excluded the original16.7.16 iPad. Original-device provisioning/installation remains pending. Development must stay on the free Personal Team until release, per user instruction. `../../packages/WorshipCueLocal` pins GRDB exactly; `../../reference/WorshipCueCore` is deliberately reused as the app's pure domain package, so identity/version rules retain one owner.

## First slice

The app seeds synthetic v1/v2/v3, a rotated/nonzero-CropBox PDF, and a weekly packet into protected Application Support storage. Files imports create new version IDs and app-owned immutable source assets after size, parse, geometry, and SHA-256 checks. Cached PDFs are verified again before opening. Cold startup restores the last local version/page; a broken remembered chart requires explicit alternate choice. No existing readable chart is replaced by an import/open failure.

The personal layer uses a development-only local church/owner identity. The store actor commits drawing bytes, exact owner/version/page geometry, generation, and an unsent personal outbox snapshot together. Unsent full snapshots coalesce per exact layer/base to bound growth. The optional managed workspace has a separate durable personal-sync worker with numeric revision CAS, frozen retry payloads and explicit two-copy conflict choices. The original local development reader is not silently uploaded or converted into an account. No team-write outbox or live-call outbox exists.

The visible input selector defaults to **Apple Pencil**; fingers pan/zoom in this mode. Choose **손가락 필기** to write using a finger, and return to Apple Pencil mode to move/zoom the chart with fingers. PDFKit markup mode enables hit testing of its actual page overlays. The pen defaults to black ink and the annotation layer overrides its appearance to Light, as required to retain visible ink on white PDF paper in Dark Mode. Pen, marker, vector stroke eraser, undo, and redo target only personal ink; the selected tool exposes a selected state and accessibility value. Each canvas owns its undo manager. Draw a selection rectangle, inspect highlighted candidate strokes, copy, explicitly choose a destination version/page, paste, drag/scale preview, then commit or cancel. Clipboard data survives source view release and stays inside the app. One undo group removes the pasted strokes. The separate red team sample is read-only and scoped to v2/page 1 of this local performance occurrence.

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

Selected-stroke clipboard logic now lives in the shared `packages/WorshipCueInk` module. Its macOS framework harness compiled and passed with real PencilKit drawings; the earlier M0 run passed thirteen hosted iPad tests on 17.7.11, including actual PDFKit-installed overlay hit testing. Synthetic tests do not replace physical input and lifecycle qualification. Two potential high-end designs are saved under `docs/ui-concepts`; these are generated concepts, not running app screenshots. External tool/build storage and exact native build evidence are recorded in `docs/13_EXTERNAL_XCODE_SETUP.md` and `verification/M0.md`.


## Real-device UI verification

Scheme `WorshipCue` runs the hosted native gate. Scheme `WorshipCueUI` also contains `MusicStandUITests`: actual finger gestures for pen/highlighter/eraser/undo/redo/save/cold relaunch; selected-note copy/paste/preview/cancel/commit/version-page isolation; read-only team-layer isolation. Screenshot pixel checks prevent an invisible archived stroke from counting as visible pen success. PDFKit text stays accessible; a small container exposes the current app-owned annotation layers.

DEBUG-only `--ui-test-store <UUID>` launches use a separate Application Support store. Tests never reset normal user notes or bookmarks. `--ui-test-inspector` can open the panel for an isolated visual inspection only when that valid UUID flag is supplied; it is not a test pass. Release excludes these launch flags.

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

The approved teal folded-ribbon W is now the native `AppIcon` asset. Build 2 compiles 14 hosted native cases and 4 UI cases. See `verification/M0-colors-icon.md` for historical results and toolchain limitations.

## Local weekly preparation (Build 3)

Use **오늘 · 라이브러리** to search, edit song metadata, favorite songs, select/prefer numbered versions, import a new song/version, and create an editable setlist with standby entries. The chart detail’s **악보 작업** menu opens manual weekly-packet page ranges. The reader’s note-copy destination panel previews only explicitly copied personal strokes; confirmation remains a separate action. **PDF 내보내기** offers source/arranger content with optional personal ink and a native share sheet.

Existing M0 chart IDs, PDF bytes, ink SQLite and bookmarks are preserved. `pdfs/catalog.sqlite` replaces the JSON catalog after a transactional migration; the old `index.json` remains a receipt and must not be edited as a current catalog. New imports verify the promoted file before catalog publication. Setlist edits use revision checks and exact song/version foreign keys. See `verification/M1.md` and run `python3 scripts/test_m1_device.py` with privately supplied, already-authorized device/team environment values.

## V2 interface (Build 4)

Use the persistent **오늘 / 라이브러리 / 악보대** navigation. Open **버전과 메모** in the header to inspect actual version thumbnails and separately open or prefer a chart. In landscape the panel docks beside the white chart; on narrower layouts it is a dismissible dark sheet. Source notes remain preserved through selection, preview and confirmed paste. **터치 / Pencil** opens the input settings; the team toggle is explicitly a read-only local example. Export and import remain in **악보 작업**.

No live announcement/team mismatch state is fabricated to imitate the bitmaps. The UI uses the existing local operations; no automatic navigation, page syncing or note merging was added. Run the focused workflow with the private device/team environment above:

```sh
python3 scripts/test_m1_device.py --group all --full-native \
  --only native v2 --command-timeout 300
```

`--regressions --only colors` selects rendered pigments and popover dismissal;
`--only workspace export-ui packet clone` selects existing local preparation
paths. `--command-timeout` bounds commands and records a timeout as unverified.
Raw results stay outside Git. See [V2 verification](../../verification/V2.md).


## Private team configuration (Build 6)

The project references `Configuration/Team.xcconfig`, whose empty endpoints preserve local-only operation. Copy the example to ignored **`Configuration/Secrets.xcconfig`**, or use `aws/scripts/configure_native.py` with private deployment outputs. Set `REMOTE_PROVIDER = aws` and the public HTTPS API/WSS URLs. AWS needs no client API key. Existing legacy Supabase public settings can remain in the ignored file. Never include AWS credentials or server privileges. The `$()` syntax preserves URL slashes through Xcode's comment parser. Explicit `WorshipCue/Info.plist` expands custom settings into the app; `scripts/verify_native_configuration.py` checks the actual compiled artifact.

Review [AWS setup](../../aws/README.md). The development service is deployed with the approved pinned PDF parser. The SES sender is verified, but the account remains in the sandbox: other recipient addresses need verification until separate production email access is approved. Core hosted tests use synthetic identities/data; they do not prove native device login, handwriting sharing or a multi-iPad rehearsal. No paid Apple enrollment or background push was enabled.

Build 7 adds permanent-bounce/complaint feedback suppression to the server, with a private recovery queue. The operator subscription is confirmed and scoped CloudWatch routing passes. The deployed infrastructure includes four mail and two backup alarms. A manual backup verified seven pinned files, with an available database backup and complete manifest. Isolated restore passed with 756 restored rows, 661 exact stable matches, seven published references and 13 immutable rows; the owned scratch table was removed. This was a small one-invocation backup, so real multi-invocation recovery remains unverified. The owned backup-error alert reached SNS and naturally returned to OK; operator inbox receipt and missing-completion alert delivery remain unverified. The authorized SES production-access request was submitted and now reports **DENIED** after initially entering review. Production sending is disabled; the account remains sandboxed. The available account API does not expose the reason, and no repeat request was submitted. Suppression is distinct from a delivered OTP or a successful account session.

Open **악보 작업 → 팀 작업 공간**. Unconfigured builds show an honest preparation message. A configured build can sign in, create a private church/default team, redeem an invitation, publish an authorized local source PDF as a new immutable version, edit team setlists, prepare downloads and explicitly open a shared chart. Guests see only their invited setlist; their personal ink stays local. The controller chooses a setlist, explicitly acquires its lease, starts a session, prepares a song/key, then sends a cue. Shared ink has a separate draft canvas and explicit publish action. Musicians retain page/chart control and can preview the exact team version without replacing their reader.

Server/account/church/team caches use protected Application Support directories distinct from the existing `WorshipCueM0` vault. Prior church-only vaults are preserved without inferred ownership. Device-only Keychain credentials, captured identity/generation fences, immutable PDF verification, frozen personal retries and explicit conflicts protect the boundary. Logout clears visible state before current-session-only server logout. Realtime hints trigger durable reconciliation with bounded reconnect; they never navigate. The chat sheet reads team/setlist discussion and saves pending drafts before explicit send/retry. Physical cloud/device behavior remains unverified.

## Team administration and data (Build 7)

The team panel offers your display name, current roster and role-aware invitation/member controls. Admins can revoke an invitation, change roles, remove a member or hand administration to another active member. Current exact-team roles and revision checks remain authoritative; two simultaneous changes cannot demote the final active admin. Invitation lists show status and creation time without retaining invitation tokens or hashes.

PDF and setlist publication intents persist frozen metadata, item UUIDs and command IDs before transmission. Explicit retries reuse the same operation, including recovery after immutable upload or publication acceptance whose response was lost. Cached charts remain readable after an ordinary network failure; authorization and file-integrity failures still stop access.

AWS catalog pages carry at most 100 rows and 512 KiB. Opaque owner/team cursors expire after one hour and fence changed access, including guest grant revocation at the final transaction. The native client assembles and validates every required array before atomically promoting the catalog. Partial or inconsistent results preserve the previous readable cache. These are current-state pages; concurrent reference changes can require a later explicit retry.

Account preflight shows currently authorized teams, unavailable-team count and required sole-admin handoffs. The native share sheet exports a protected JSON document containing the selected team's owner records and matching verified personal-file references. It excludes PDF/ink file bytes, organizational PDFs/shared ink and unavailable-team records. This is not a complete account backup; account deletion is explicitly unsupported pending safe retention and restore protections.

## Advanced team chat (Build 7)

Choose the team room or a setlist discussion from the compact room list. Read cursors and mute settings are per member and room. Unread counts use original message creation, excluding edits, pins, your own messages and hidden/deleted authors. When the server's bounded history cannot establish a complete count, the UI shows an unknown state instead of a guessed number.

Message actions provide reply, jump to the original, edit/delete, pin, report and author block/unblock. Leaders can inspect reports and explicitly resolve or dismiss them. Edits and moderation use revision checks; actions and sends keep stable command IDs for explicit retries. Old command receipts cannot restore deleted text. Block changes have a generation fence: cached text and chart links are hidden, and an explicit unblock fetches current authorized history even if message revisions did not change.

A composer can attach a published chart from the selected team's authorized library. Its preview/open actions require a tap, retain normal file checks and never acknowledge a cue. A link or incoming message does not switch the reader, turn a page, publish ink or grant access to another team's material. Guest rehearsal identities receive no team chat.

Current backend verification: **185 AWS unit/boundary tests passed**, including **76 domain tests**; **27 real hosted scenarios passed, zero failures**, against the final deployed Build 7 backend, including administration, paginated member/guest catalogs and owner-data export. Exact native/device evidence belongs to [Build 7 verification](../../verification/CHAT7.md). Prior portable checks passed 55 core, 32 Python reference, 14 local storage, 24 remote transport tests and 9 ink groups. These totals are distinct from a physical chat/rehearsal qualification.

The narrow concurrent catalog-read check passed 20/20 clients in 40 attempts with 20 HTTP 503 retries (2.047 s wall, p95 1.994 s). The 50-client run failed: 48 passed, two exhausted retries, 135 attempts, 14 HTTP 429 and 73 HTTP 503 responses (5.921 s wall). It used two synthetic identities and one first-page read per client under the account's shared 10-execution Lambda quota; it does not qualify 50 complete user sessions.

Two real iPads, physical Pencil, the original iPadOS 16 device, concurrent-load qualification, real multi-invocation backup recovery, prolonged offline/resume use, rehearsal soak, real onboarding beyond verified SES recipients, file-inclusive account export, account deletion and support/retention remain open requirements.

Additional checks:

```sh
sh scripts/with_external_xcode.sh swift test --package-path packages/WorshipCueRemote
python3 scripts/test_backend.py
deno test --config supabase/deno.json supabase/tests/edge_test.ts
python3 scripts/test_m1_device.py --group ui --only team-setup --command-timeout 240
```

Use external scratch/result paths as in the evidence reports and privately supplied device/signing environment values for device scripts. `TeamWorkspaceTests` use the real native vault, store and client with controlled URLSession HTTP responses; they do not substitute for a managed service, email delivery or two iPads.
