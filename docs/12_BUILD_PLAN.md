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

### M2 amendment · Separate team workspaces (D44, 2026-10-08)

First pilot: one church/10–20 members, but adding another church/team should be authorized onboarding rows in the same deployment, not another paid backend project. A church is an organization; each team owns its separate library, setlists, sessions, shared notes and chat. Users explicitly invited into multiple teams can switch named workspaces. Organizational administration and target-team content membership are distinct.

Build 5 currently scopes libraries by church, permits an admin bypass across team setlists, and partitions native catalog/preferences/cache/outboxes by server/account/church. This does not meet the new requirement. Add a versioned team-ownership migration for songs/assets/chart versions and compound cross-resource guards; exact-team RLS/RPC/Storage/Realtime access; idempotent `create_team`, scoped invitations/roles; and server/account/church/team native partitions for files, preferences, outboxes, drafts, commands and chat. Capture immutable team context across every async request, flush before switching, and detach prior subscriptions/live context. Existing standalone local material remains preserved and is published only into an explicitly chosen workspace.

Backfill default-team ownership only when provable. Classify any existing church-wide chart referenced by multiple teams rather than automatically duplicating/merging its notes. Test two teams inside Church A and a team inside Church B: members/leaders/admins without explicit target membership, guests, outsiders, guessed IDs, mixed-team setlist/chart/asset references, same-title/byte charts, multi-team users, late callbacks, offline jobs after switching, revocation, duplicate team creation and full metadata/object restoration. A church-admin content bypass is not accepted as isolation. Existing one-team-per-church tests do not qualify this amendment. No current cloud data or schema was changed by this plan.

## M3 · Team handwriting, safely synchronized
Implement per-performance-item/version/page shared layers; one editor lease/epoch; immutable snapshots and heads; native archive + preview assets; same-version rendering and other-version preview. Use durable head fetches after notifications; add reconnect reconciliation. Preserve offline/team-conflict drafts without automatic publishing.

Deliver: bandmaster circles a passage; matching-version iPad sees the circle; different-version iPad sees a preview indicator and can inspect exact team chart. Gate: two real iPads, independent personal edits, wrong-version and wrong-occurrence tests, lease takeover, snapshot corruption/retry. This is core MVP, not deferred polish.

## M4 · Live song announcements
Implement controller private preparation, transactional call publication, persistent visual-only latest banner, explicit musician open action, race-safe async file opening, key mismatch, no page sync, no automatic navigation, history, session end, and truthful received/opened telemetry.

Deliver: keyboardist prepares and announces an off-setlist song, musicians open only after tapping, each retains chart choice, planned setlist remains unchanged. Gate: T01–16,T45–46 with duplicate/reordered events, timeout-after-commit, file miss, and key-only calls. No hidden auto-follow feature.

## M5 · Failure hardening and preparation
Implement full preflight downloads for team/preferred/standby material; connection freshness; lifecycle restoration; corrupted/partial-file recovery; disk-full handling; account/data partitioning; export; diagnostic reports; clean state transitions; migration/backup/restore tests. Polish touch targets, Korean copy, accessible states, low-distraction controller panel. Qualify oldest real hardware and 50 simulated clients.

Deliver: two-hour soak evidence and fault-injection report. Gate: no P0 failures, measurable performance, versioned native build, verified backup restore (metadata AND assets), safe release configuration, no service keys in bundle/logs.

## User-requested extension · Team chat (2026-10-08)

Implement after the managed workspace is activated and qualified; this is newly required under D43, not present in Build 5. Reuse Supabase Auth/Postgres/Realtime and existing app account partitions. Initial scope: signed-in team members, one team room plus service/setlist discussion, bounded text, replies, authorized links to existing charts, unread state, mute and pinned preparation instructions. No separate chat provider or arbitrary media upload is required for this slice.

Add minimal member profiles/roster, exact-team channel membership, immutable message IDs with server ordering, stable client command UUIDs, transactional send/edit/delete, revision/tombstone reconciliation, per-user read cursors, rate limits and report/block/moderation. `private.member_of(church_id)` permits a member of any team in the church; it is insufficient for private team chat. Anonymous rehearsal guests receive no whole-team chat history. Chart links do not grant new asset rights, select a chart or acknowledge a cue.

Persist before showing server acceptance; reconcile ambiguous sends by the same UUID. Keep account/channel-scoped offline drafts visibly pending and require an explicit send/retry in the initial slice. Chat must not share the forbidden offline live-call publication queue or shared-ink editor lease. Realtime invalidation plus durable fetch-on-open/resume/reconnect handles duplicate/missed hints and older message edits. New chat never switches the reader or page; keep the music stand quiet.

Gate: real managed member/outsider/other-team/guest RLS and Realtime isolation, concurrent authors, timeout-after-commit, duplicate send, delayed edit/delete, membership expiry/revocation, account switch, disconnected drafts and two real iPads. Before App Store distribution, qualify relevant user-generated-content controls and support. Foreground chat requires no paid Apple enrollment; background APNs is a later phase needing supported paid signing capability. Push is only a hint and cannot replace message storage/reconciliation. See [infrastructure and budget](13_PILOT_AND_PRICING.md).

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
