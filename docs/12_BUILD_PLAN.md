# Milestone build plan and Codex task boundaries

## Ground rules
No “build everything” mega-commit. Each milestone yields a usable vertical slice and evidence. No critical placeholder paths, fake sync, mock security, or blanket `try?` error swallowing. A test that needs hardware is NOT VERIFIED until run. Local/backend progress may continue while hardware access is pending, but device gates remain release blockers.

## M0 · Native reliability spike, before polished product UI
Inspect repo/toolchain, preserve work, record device assumptions, create minimal native target and pure domain package. Load synthetic PDF from Files/local fixtures. Render one page, overlay a personal PencilKit canvas, persist locally, restore after app restart. Prove page changes/rotation/zoom/canvas reuse cannot save onto a wrong version. Prototype selected-note copy from v1 to v2 with an app-owned clipboard and undo. Show team read-only overlay locally with separate undo scope.

Deliver: buildable iPad project; deterministic fixtures; local-state tests; basic native integration tests; device check script; `verification/M0.md`. Gate: native build, saved-note recovery, rotated/CropBox alignment, actual Pencil writing and selection. Do not start by designing sign-in or buying infrastructure. If PDFKit overlay reliability fails, investigate adapter alternatives before broad features.

## M1 · Local-first weekly music stand
Implement library metadata, Korean search, individual/multi-song packet import, immutable version numbering, setlist/standby editing, personal preference, version chooser, and note-transfer UX. Add transactional local SQLite store, verified file manifests, offline startup, and authorized-layer PDF export. All data can be local test data for now.

Deliver: one iPad can prepare a weekly set, annotate, choose versions, transfer notes, close/reopen offline, and export a fallback. Gate: import/geometry/restore/copy tests; no misleading “saved.” No server dependency for core reader.

## M2 · Real backend and private workspace
Create local Supabase schema, migrations, indexes, constraints, RLS, managed auth, private asset policies, and finalization pipeline. Implement account/church/default-team creation, private membership, invitation redemption, guest scope, source upload/version publication, and personal-note sync with CAS conflicts. Pin SDK/CLI versions after checking official docs. Create staging only with authorization/configuration.

Deliver: two authorized devices share library metadata/files without leaking private notes. SQL/RLS/RPC/storage integration tests; fresh schema reset/migration test in isolated development only. Gate: T24,T31–36,T40,T48. Do not let an `authenticated` guest inherit member permissions.

## M3 · Team handwriting, safely synchronized
Implement per-performance-item/version/page shared layers; one editor lease/epoch; immutable snapshots and heads; native archive + preview assets; same-version rendering and other-version preview. Use durable head fetches after notifications; add reconnect reconciliation. Preserve offline/team-conflict drafts without automatic publishing.

Deliver: bandmaster circles a passage; matching-version iPad sees the circle; different-version iPad sees a preview indicator and can inspect exact team chart. Gate: two real iPads, independent personal edits, wrong-version and wrong-occurrence tests, lease takeover, snapshot corruption/retry. This is core MVP, not deferred polish.

## M4 · Live song announcements
Implement controller private preparation, transactional call publication, persistent visual-only latest banner, explicit musician open action, race-safe async file opening, key mismatch, no page sync, no automatic navigation, history, session end, and truthful received/opened telemetry.

Deliver: keyboardist prepares and announces an off-setlist song, musicians open only after tapping, each retains chart choice, planned setlist remains unchanged. Gate: T01–16,T45–46 with duplicate/reordered events, timeout-after-commit, file miss, and key-only calls. No hidden auto-follow feature.

## M5 · Failure hardening and preparation
Implement full preflight downloads for team/preferred/standby material; connection freshness; lifecycle restoration; corrupted/partial-file recovery; disk-full handling; account/data partitioning; export; diagnostic reports; clean state transitions; migration/backup/restore tests. Polish touch targets, Korean copy, accessible states, low-distraction controller panel. Qualify oldest real hardware and 50 simulated clients.

Deliver: two-hour soak evidence and fault-injection report. Gate: no P0 failures, measurable performance, versioned native build, verified backup restore (metadata AND assets), safe release configuration, no service keys in bundle/logs.

## M6 · Rehearsal pilot / TestFlight
Build signed TestFlight pilot only with authorized Apple setup. Provide tester instructions, demo data, known limitations, support contact, permission/rights review, and issue intake. Two full rehearsals, then four services with fallback. Billing remains disabled. Capture whether note-taking is genuinely good enough to stay in the app.

Gate: actual musicians can find/open a called song and interpret version/key differences without coaching; no unsolicited navigation; no saved-note loss. Gather church buyer feedback before expanding scope. No claim of market fit from one church.

## Deferred after evidence
Billing/App Store purchase-path review; iPhone/Android/web views; optional two-page and Bluetooth pedal features; automatic import assistance; structured chord charts/transposition; more complex multi-editor/team/global annotation scopes. Do not add them to finish the first pilot.

## Suggested development cadence
One task = one behavior + failure path + tests, e.g. “capture page identity before async ink save,” not “implement annotations.” After each milestone update project state and evidence. A new bug fixes a regression test first. Use independent review for security and race conditions when tooling supports it, but maintain one owner for shared contracts.

## Environment blocking rules
- No Mac: pure Swift domain/reference and backend work may be implemented/tested; native target cannot be declared built.
- No actual iPads/Pencil: simulator evidence is allowed but device gates stay NOT VERIFIED.
- No server credentials: local Supabase/stubs restricted to development; no fake hosted-sync claim.
- No Apple signing: local native build may proceed; do not claim installable TestFlight release.
- No real chart rights: use synthetic fixtures; do not scrape or import third-party scores.

## Milestone report template
```
Milestone:
Implemented behavior:
Changed files:
Tests run (exact command, toolchain, result):
Physical device checks (model/OS/Pencil/result):
Not verified / blocked:
Known issues and severity:
Next milestone:
```
