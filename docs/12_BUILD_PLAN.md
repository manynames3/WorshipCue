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
Under user decision D45, implement the AWS development backend: Cognito managed auth, DynamoDB conditional transactions, exact-team API authorization, private immutable S3 assets, server PDF validation and content-free WebSocket hints. Preserve the earlier local Supabase schema/RLS/Edge implementation. Implement account/church/default-team creation, membership, invitation redemption, guest scope, source publication and personal-note CAS conflicts. Pin added dependencies and record actual deployed qualification separately from controlled tests.

Deliver: two authorized devices share library metadata/files without leaking private notes. Run adversarial API/store/file/identity tests and real hosted checks against isolated synthetic data. Database and object backup restoration must both qualify. Gate: T24,T31–36,T40,T48. A managed guest must never inherit member permissions.

### M2 amendment · Separate team workspaces (D44, 2026-10-08)

First pilot: one church/10–20 members, but adding another church/team should be authorized onboarding rows in the same deployment, not another paid backend project. A church is an organization; each team owns its separate library, setlists, sessions, shared notes and chat. Users explicitly invited into multiple teams can switch named workspaces. Organizational administration and target-team content membership are distinct.

The preserved Build 5/Supabase path scopes libraries by church and is not qualified for this amendment. Build 6/AWS adds exact-team songs/assets/versions, compound resource guards, idempotent `create_team`, scoped invitations/roles and server/account/church/team native partitions for files, preferences, outboxes, drafts, commands and chat. Capture immutable team context across async requests, flush before switching and detach previous subscriptions/live context. Existing church-only vaults remain untouched; standalone material is published only into an explicitly chosen workspace. See `verification/AWS.md` for the distinction between implemented, hosted-tested and device-unverified behavior.

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

This is required under D43. Under D45, use Cognito identity, exact-team DynamoDB operations, WebSocket hints and native account/team partitions. Initial scope remains signed-in team members, one team room plus service/setlist discussion, bounded text, replies, authorized chart links, unread state, mute and pinned preparation instructions. No separate chat provider or arbitrary media upload is required. Build 6 implemented the core native send/read/retry flow; Build 7 adds compact edit/delete/pin, reply/jump, explicit chart preview/open, room unread/mute, report/block/unblock and leader report resolve/dismiss controls. See [Build 7 evidence](../verification/CHAT7.md); the [Build 6 record](../verification/AWS.md) remains historical.

Add minimal member profiles/roster, exact-team channel membership, immutable message IDs with server ordering, stable client command UUIDs, transactional send/edit/delete, revision/tombstone reconciliation, per-user read cursors, rate limits and report/block/moderation. `private.member_of(church_id)` permits a member of any team in the church; it is insufficient for private team chat. Anonymous rehearsal guests receive no whole-team chat history. Chart links do not grant new asset rights, select a chart or acknowledge a cue.

Build 7 unread calculation counts original visible, nondeleted messages from other authors; edits/pins do not create unread messages. Legacy creation order is preserved. A shared bounded counting budget returns an unknown count when the result cannot be complete. Block/unblock generations fence old responses and fetch authorized history without depending on a changed message revision. Deleted/blocked text and chart links remain hidden in cached reconciliation, moderator reads and old-command retries. Moderation uses current exact-team role checks and revision CAS, with stable UUID receipts; an owner can clear an existing block even after the target member is removed.

Persist before showing server acceptance; reconcile ambiguous sends by the same UUID. Keep account/channel-scoped offline drafts visibly pending and require an explicit send/retry in the initial slice. Chat must not share the forbidden offline live-call publication queue or shared-ink editor lease. Realtime invalidation plus durable fetch-on-open/resume/reconnect handles duplicate/missed hints and older message edits. New chat never switches the reader or page; keep the music stand quiet.

Gate: real managed member/outsider/other-team/guest API/file/WebSocket isolation, concurrent authors, timeout-after-commit, duplicate send, delayed edit/delete, membership expiry/revocation, account switch, disconnected drafts and two real iPads. The preserved Supabase path separately requires RLS. Before App Store distribution, qualify relevant user-generated-content controls and support. Foreground chat requires no paid Apple enrollment; background APNs is a later phase needing supported paid signing capability. Push is only a hint and cannot replace message storage/reconciliation. See [infrastructure and budget](13_PILOT_AND_PRICING.md).

### Build 7 · Email feedback and current qualification

The dedicated SES configuration set routes permanent bounces and complaints through scoped SNS/Lambda processing. Check source account, sender identity, configuration set, topic and recipient scope. Store normalized-address SHA-256 suppression keys with categorical/hash metadata; do not print mail contents, addresses, codes or tokens. Transient bounces and explicit `not-spam` feedback do not permanently suppress a destination. Suppression prevents another app code request; it is not proof of delivery.

Failed feedback has a private encrypted 14-day recovery queue and four CloudWatch alarms for processing, dead-letter delivery, SNS delivery and queue backlog. The operator subscription is confirmed and scoped CloudWatch routing passed. The deployed stack adds backup-error and missing-completion alarms, restricting operator-topic publication to exactly six alarms. The owned backup-error alarm produced a successful SNS action and naturally returned to OK; missing-completion monitoring naturally reached OK from the real completion metric. Its own notification delivery, operator inbox receipt and the operator/contact response process remain open gates. The authorized SES production-access request was submitted, initially entered review, then reported **DENIED** with production sending disabled. The account remains sandboxed. The available account API exposed no reason; authenticated Support details or the denial message are needed before considering a revised request. No repeat request was submitted. Verified sender/recipient tests do not enable arbitrary church onboarding.

Current local AWS verification: **185 unit/boundary tests passed**, including 76 domain tests. The final deployed Build 7 hosted suite has **27 passed, 0 failed**, including administration, paginated member/guest catalogs and owner-data export. Evidence is recorded in [CHAT7](../verification/CHAT7.md). Portable runs passed 55 core, 32 Python reference, 14 local storage tests and 9 ink groups; the prior remote transport run passed 24. The latest physical iPadOS 17.7.11 native run executed **86 cases: 85 passed, one optional private-PDF skip, zero failures**, comprising 46 workspace, 10 administration, 10 export and 20 ink cases. Release, generic-device Debug and nine bundle checks pass. The separate 11-case touch UI retry ran no cases because UI automation timed out. A separately opted-in real-PDF case passed with eight PDFKit page renders, and a normal Build 7 launch preserved seven PDFs and three ink files. Controlled native transport does not substitute for real-account multi-iPad qualification.

The narrow hosted catalog-read run passed **20/20 clients**, with 40 attempts and 20 HTTP 503 retries (2.047 s wall, p95 1.994 s). The **50-client run failed qualification**: 48 passed, two exhausted retries, 135 attempts, 14 HTTP 429 and 73 HTTP 503 responses (5.921 s wall), with no final-run HTTP 409. It uses two synthetic identities and one first-page read per client under the account's shared ten-execution Lambda quota. It does not satisfy the fifty-client rehearsal/session gate.

End-user readiness remains unverified for two real devices, physical Apple Pencil, original iPadOS 16 hardware, real recipients beyond the SES sandbox, disconnected/resumed work, concurrent-load qualification and rehearsal soak. File-inclusive account export, deletion, real multi-invocation backup recovery and support/retention policy remain incomplete. No paid Apple enrollment or release distribution is enabled.

The readiness slice implements bounded member display names, role-aware roster/invitation management, invitation revocation and atomic team-admin handoff in the backend and native panel. Current exact-team membership and revisions are authoritative; concurrent changes cannot demote the final active admin. Native PDF/setlist publication retains frozen payloads and command/item IDs across explicit timeout retries, including ambiguous immutable upload/finalization acceptance. Catalog pages stay below 512 KiB/100 rows, use owner-bound expiring cursors and transactionally fence guest grants; native assembly validates completeness before replacing the readable cache. Concurrent reference changes can require retry because pages are current reads, not a frozen cross-table snapshot.

Read-only account preflight and owner-data JSON/asset manifests are implemented for the selected currently authorized team, with unavailable-team disclosure and a native share sheet. They exclude file bytes and organizational shared content and do not permit account deletion. Preserve shared team materials and require reviewed retention, permanent owner-deletion restore protections and sole-admin handoff before deletion jobs. The backup worker now resumes up to 100 files per invocation under an 8 MiB checkpoint/manifest bound, retaining one database backup. A real manual run verified seven pinned files (one new copy, six verified reused copies), an available database backup and a completed manifest in one invocation. Isolated restore passed with 756 restored rows, 661 exact stable matches, seven file copies/references and 13 immutable rows; the owned scratch table was removed. Real multi-invocation recovery remains unverified; local larger-archive tests do not qualify that deployed path. No automatic aged-backup deletion was introduced.

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
