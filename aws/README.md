# WorshipCue AWS development backend

The user selected AWS under D45. This implementation keeps each team's PDF library, setlists, shared notes, live session and chat separate, even when teams belong to the same church. Existing standalone iPad files and the earlier Supabase implementation are preserved.

## Infrastructure

| Service | Purpose |
|---|---|
| Cognito Essentials + verified SES sender | Managed email-code accounts and invite-bound guest identities; no application-issued tokens |
| API Gateway HTTP + Lambda | Authenticated operations, exact-team authorization and real PDF validation |
| DynamoDB on demand | Strong reads, conditional transactions, command receipts, editor epochs, annotation heads and durable chat |
| Private versioned S3 | Immutable checksum-bound PDFs/native snapshots/previews, short-lived signed downloads |
| API Gateway WebSocket | One-use connection tickets and content-free hints; durable data is fetched separately |
| Resumable daily backup Lambda | Independent version-pinned file copies, DynamoDB backup, protected checkpoints and checksummed manifest |
| SES configuration set → SNS → Lambda | Scoped permanent-bounce/complaint feedback and SHA-256 address suppression before another code request |
| Private SQS recovery queue + CloudWatch/SNS | Failed feedback recovery, four mail alarms and two backup alarms; confirmed operator subscription and scoped routing |

There is no EC2 instance, RDS database, load balancer, NAT gateway or custom KMS key. Deployment is scoped to `worshipcue-dev` in `us-east-1`; the code bucket has its own small development stack. The account currently permits ten concurrent Lambda executions, so this deployment uses the shared account limit. HTTP throttling and application auth limits protect the pilot, but are not a billing hard cap.

## Implemented behavior

- Church/default-team and additional-team creation, explicit membership, invitations, revocation and setlist-scoped guests.
- Bounded personal display names, current-role roster and invitation management, member role/removal checks and atomic admin handoff. The final active admin is preserved with transactional guards; invitation lists never expose tokens or hashes. Local, controlled native and real hosted checks pass; multi-device rehearsal remains separate qualification.
- Paginated catalog responses stay below 512 KiB and 100 rows. Owner-bound cursors expire after one hour and fence changed access; hidden resource IDs never enter cursors. Native consumers must validate a complete assembled catalog before replacing the readable cache. Pages represent current authorized reads, not one frozen cross-table snapshot; changed references require a later retry.
- Read-only account preflight identifies sole-admin handoffs and unavailable teams. Personal-data export pages include only the current owner's records and matching verified personal-file references in the currently authorized team. This is a JSON/asset manifest, not a file backup or account deletion; revoked teams and organizational PDFs/shared ink are excluded.
- Immutable charts with server-verified PDF bytes, hashes and page geometry. S3 rejects checksum errors and overwrites. Publication is a separate transaction.
- Native PDF/setlist publication keeps frozen payloads and stable command/item UUIDs across explicit retries. A lost response cannot start a second operation with changed content.
- Personal note ownership and compare-and-swap conflicts; shared snapshots with exact item/version/page identity and fenced editor leases.
- Durable, sequenced live calls, terminal session end and historical acknowledgements. Announcements never move a reader or page.
- Team/setlist chat with server ordering, stable send IDs, catch-up, replies, edits, tombstones, read cursors, mute, pin, report and block/unblock operations. Guests receive no team chat.
- Native Korean chat panel with compact edit/delete/pin actions, reply/jump, authorized chart preview/open, room unread/mute, report/block/unblock and leader report resolve/dismiss controls. Drafts and actions are durable and explicitly retried; new device behavior remains a separate qualification.
- Creation-based unread counts exclude edits/pins, deleted messages, blocked authors and the reader's own sends. A rooms request uses a shared 200-event counting budget with bounded lookahead; incomplete counts return `unread_count: null` with `unread_complete: false`. Legacy messages retain their original creation ordering through durable deltas.
- Published chart links require exact-team membership and a verified source; they never grant new file permissions or navigate automatically. Deleted/blocked bodies and chart links are redacted during snapshots, moderation reads and old-command retries. Block generations force bounded history reconciliation after unblock.
- Leader/admin report listing and CAS resolution/dismissal, bounded pagination and stable command receipts. A moderator's old receipt cannot bypass current role or membership checks.
- Foreground WebSocket reconnect with fresh tickets, bounded backoff and polling recovery. No background push is implemented.

Authorization runs before cached command receipts are returned. Church administration does not grant another team's content access. Published asset downloads require a permitted chart or annotation reference. Personal activity does not generate team-wide hints.

## Email delivery feedback (Build 7)

The dedicated SES configuration set sends permanent bounces and complaints to a scoped SNS topic and Lambda consumer. Processing checks the topic, source account, sender identity, configuration set and destination membership. Suppression rows store normalized-address SHA-256 hashes, categorical reasons and hashed event references; addresses and message contents are not emitted in application logs. Transient bounces and explicit `not-spam` feedback do not create permanent suppression. Suppressed destinations cannot request new codes through the app.

Failed feedback can retry and is retained in a private encrypted 14-day recovery queue. Four alarms monitor Lambda errors, dead-letter delivery errors, SNS delivery failures and queue backlog. The operator email subscription is confirmed, and scoped CloudWatch-to-SNS routing passed. The latest template also routes backup errors and missing completion to the same topic, with exactly six permitted alarm sources. The owned backup-error alarm produced a successful SNS action and naturally returned to OK. Missing-completion monitoring naturally reached OK from the real completion metric; its own notification delivery was not exercised. All six alarms are currently OK. Operator inbox receipt remains unverified. Hash-only suppression rows do not mean the private SES/SNS recovery event is stripped of its original mail fields.

`prepare_ses_request.py` prepares a private review draft outside Git; `mail_operations.py` handles the separately authorized submission and operational checks. The production-access request was accepted for review, then AWS reported **DENIED** with production access disabled. SES remains sandboxed. The account API exposed no reason; the Support case API returned `SubscriptionRequiredException`, so the authenticated Support page or denial message must supply the explanation. No repeat request was submitted. Confirmed subscription/routing does not establish that an operator has read or acted on an incident; the contact/support process and real recipient onboarding still need qualification.

## Development setup

Use an AWS CLI profile already authorized for this isolated development environment. Keep a private configuration JSON **outside the repository** with `region`, `stack` and the verified `sender`. Do not put credentials, sender addresses, account IDs or outputs in Git. The deployment runner saves outputs and provider errors privately.

```sh
python3 aws/generate_template.py
python3 aws/package_backend.py --output /absolute/external/AWS
PYTHONPATH=/absolute/external/AWS/vendor:aws/src python3 -m unittest discover -s aws/tests
python3 aws/scripts/deploy.py --config /absolute/external/AWS/private-config.json
python3 aws/scripts/configure_native.py --config /absolute/external/AWS/private-config.json
```

Run tests successfully before deployment. Packaging verifies the approved `pypdf==6.19.0` wheel checksum; see [dependency review](THIRD_PARTY.md). The iPad receives public API/WebSocket URLs only, through ignored `Secrets.xcconfig`. The explicit source Info.plist expands these values into the built bundle; verify the artifact, not just the project settings.

```sh
python3 scripts/verify_native_configuration.py --app /absolute/build/WorshipCue.app \
  --aws-config /absolute/external/AWS/private-config.json --build-number 7
python3 aws/scripts/smoke.py --self-test
python3 aws/scripts/smoke.py --config /absolute/external/AWS/private-config.json \
  --state-directory /absolute/external/AWS/HostedSmoke
```

The smoke runner creates isolated synthetic managed identities and data. It never uploads the user's local chart collection or prints credentials. It uses the existing AWS CLI, native Swift WebSockets and approved parser; no additional production dependency is required.

Current Build 7 verification has **185 passing AWS unit/boundary tests**, including 76 domain tests, and **27 passing real hosted scenarios, zero failures**, against the final deployed Build 7 backend, including administration, paginated member/guest catalogs and owner-data export. The physical iPad native suite has 85 passes, one optional private-PDF skip and zero failures across 86 cases, using isolated stores/controlled transport. The separately opted-in real-PDF case passed with eight PDFKit page renders; a normal app launch retained seven PDFs and three ink files. Separate email-feedback/native/device evidence is recorded in [Build 7 evidence](../verification/CHAT7.md). Historical Build 6 retains its 101 unit tests, 17 hosted scenarios and backup/restore results in [AWS evidence](../verification/AWS.md); they are not new device results.

An earlier reused-fixture smoke rerun failed its catalog assertion because the test queried every authorized team after administration cases had added another synthetic membership. A read-only probe confirmed that every returned team had active membership; the explicitly selected-team query returned only its two baseline charts. The repaired test checks every row's exact team/church, required and forbidden chart IDs, and uniqueness while permitting additional legitimate same-team charts. **Five smoke self-tests pass**, and the repaired full hosted suite reran successfully with **27/27 passes, exit 0**, against the deployed adapter repair. The earlier failed run remains recorded in [Build 7 evidence](../verification/CHAT7.md).

The latest 436,244-byte package deployed successfully to the 50-resource development stack. Narrow concurrent catalog reads passed **20/20 clients** in 40 attempts with 20 HTTP 503 retries: 2.047 s wall time, p95 1.994 s. The **50-client run failed qualification**: 48 passed, two exhausted their retry budget, 135 attempts, 14 HTTP 429 and 73 HTTP 503 responses, 5.921 s wall time. No HTTP 409 occurred in these final runs. Scope is two synthetic identities and one first-page catalog read per client under the shared ten-execution Lambda quota; this is not proof of 50 complete user sessions.

## Backup and recovery

The table has point-in-time recovery. Both asset and backup buckets are private and versioned. The latest worker starts at most one daily job after 04:00 UTC; its five-minute schedule resumes a protected conditional checkpoint. Each invocation copies at most 100 immutable source object versions, retaining one database backup across retries. A complete manifest is written only after the database backup is available and all file checks pass. Failed or incomplete work does not report completion. Existing verified copies are reused; no automatic retention deletions occur in this pilot.

The earlier 1,000-object stop is replaced by resumable pages, with an 8 MiB checkpoint/manifest bound and 100 MiB per source object. Native ink and preview revisions also consume manifest space; this is not an unlimited song archive. Thirty-seven backup/readiness tests pass locally, including more than 1,000 files and one retained database backup. A real manual run verified seven pinned files: one new copy, six verified reused copies, an `AVAILABLE` database backup and a completed manifest. This small archive completed in one invocation. Isolated restore passed: 756 rows, 661 exact stable matches, seven published file references, seven file copies and 13 immutable rows. The live comparison recorded 749 unchanged rows and seven changed/ephemeral rows. Real multi-invocation recovery and missing-completion notification delivery remain unverified. Archive growth, orphan staging cleanup and retention still need an operational policy before a broader pilot.

`restore_check.py` hashes actual downloaded backup bytes, restores a database backup into a separate UUID-named test table, validates row digests and published file references, and optionally compares stable rows to a private quiescent source scan. It keeps the scratch table by default. Cleanup is restricted to a table created by its exact private ownership receipt; it cannot replace the application table. The latest owned scratch table was deleted after qualification. The first cleanup attempt failed because AWS omits identity fields while a table is already deleting; receipt-bound reconciliation fixed that case without repeating DeleteTable, and 18 restore-helper self-tests passed. The original failure remains in the evidence.

## Current limits

The SES production-access request is **DENIED**, production access is disabled, and the account remains in the sandbox: recipients must also be verified. Verifying the sender alone does not enable arbitrary church members' email codes. Real email-code verification, protected membership access, refresh and sign-out passed with the user's verified recipient; both refresh and protected requests were denied after sign-out.

Cloud qualification uses synthetic data and does not qualify a multi-iPad rehearsal. Physical native checks pass with controlled transport; real-account device sharing, actual PencilKit archive uploads, disconnected drafts, background/resume, original iPadOS 16 hardware, physical Pencil, concurrent-load qualification, fifty clients, a two-hour soak and representative maximum-sized PDF performance remain unverified. The owner-record JSON/asset manifest excludes file bytes and unavailable teams; complete account export and deletion remain unsupported. Support/moderation response, retention, real multi-invocation backup recovery and mail onboarding beyond verified recipients are operational gates. No paid Apple enrollment, APNs, TestFlight or public release is enabled.

See [Build 7 evidence](../verification/CHAT7.md), [historical Build 6 AWS evidence](../verification/AWS.md), [milestone plan](../docs/12_BUILD_PLAN.md) and [project state](../PROJECT_STATE.md).

## 2026-10-08 · Authenticated SES case clarification

Authenticated AWS Support follow-up (2026-10-08): the case is **Pending customer action** and requests six specific use-case details before a final decision. The earlier account API **DENIED** receipt remains recorded; no fresh account API read or production approval occurred. The user submitted the complete follow-up; authenticated correspondence confirms receipt at 20:26 EDT on October 8, and the case now shows **Customer action completed**. No production approval or new account API status read is established by this response. See [Support follow-up](../verification/SES-support-followup.md).

## Build 8 refresh and readiness qualification

The existing development stack is updated without new resource definitions or quota changes. Small authorized catalogs can fill one bounded response instead of requiring six section requests; native identical in-flight requests share one exact-session/exact-team operation. Each returned page still has an independent final permission fence. Authorized membership rows include church/team display names.

Controlled checks: 190 AWS cases, 31 remote transport cases, 7 load-helper and 5 smoke-helper cases pass. Actual service checks: 27 hosted scenarios and 4 workspace-name/isolation checks pass. The **raw 50-client burst remains failed: 48 pass / 2 fail**. An explicitly separate test spreading 50 first-page starts across five seconds passes 50/50 without retries; that pacing is a comparison-harness mode, not proof of 50 rehearsing devices. Quota and representative sustained-load qualification remain open. See [Build 8 evidence](../verification/BUILD8.md) and the [stakeholder architecture](../docs/architecture/README.md).
