# Pilot, buyer validation, and pricing hypothesis

## Positioning
For this initial Korean-speaking, iPad-using team: preserve personal chart work through revisions, share rehearsal handwriting, and communicate spontaneous song calls without controlling the musician's screen. Do not claim every Korean church has the same equipment, rehearses the same way, or will pay.

## First pilot setup
One church, one worship team, one keyboardist/controller, 3–10 active iPads, a compatible Pencil for users who handwrite, 10–20 currently used songs and a manageable standby collection. Import both individual PDFs and packet PDFs. Use material the church is authorized to reproduce/share. Verify title/key/version metadata manually. Inventory device models and stylus support before locking the deployment target.

Prepare a fallback export/print set. Do not ask the first team to migrate its entire historical catalog. Teach just five actions: open this week; write a personal note; choose/copy between versions; view team marking; tap an announced song.

## Validation sequence
1. Observe the existing preparation/rehearsal once and time real friction. Treat user statements as design input, not measured frequency.
2. Run two rehearsals with deliberate changes: revised ending, same song in another key, team circle/arrow, missing download, temporary internet loss, and a spontaneously called prepared song.
3. Run four services only after P0 safety checks pass. Keep a known-good build and fallback.
4. Debrief bandmaster and musicians separately. Check how often they return to another note app, whether notifications are noticed, whether version indicators are confusing, and whether shared marks help more than they interrupt.

## Success signals (pilot targets)
At least 80% of participating tablet users choose WorshipCue for the whole rehearsal/service; repeated personal-note use; no saved-note loss or unsolicited screen changes; no wrong-version team overlay; the leader can prepare/announce without abandoning playing for an awkward search; church decision-maker agrees the value merits a paid continuation discussion. These are targets, not proof of market fit.

Measure raw timing samples and incidents rather than only testimonials. An unused live feature does not invalidate the product if revision/annotation trust is strongly valuable, but it should change the product pitch. An impressive announcement demo does not compensate for unreliable handwriting.

## Who pays
Chosen model: one church subscription with free musician/guest participation. Do not charge a visiting musician to open the service or impose a mid-service seat/paywall error. No billing code in the free pilot.

A later interview may test a simple church plan around ₩19,900/month for Korea or $19/month for a US church, as separate hypotheses, not equivalent exchange-rate pricing and not a validated recommendation. First establish who approves the worship budget and what replacement/saved work they value. Avoid multiple tiers, lifetime deals, per-song licensing bundles, and per-musician seats before buyer evidence.

App Store purchase-path treatment must be settled before charging; church-paid does not automatically qualify for a particular exception. Infrastructure budget/quota checks are required before a live pilot, but do not silently purchase or upgrade a plan.

## Feedback that blocks expansion
Users still prepare all notes in Goodnotes because ink/selection feels unreliable; leaders cannot operate the panel while on keys; members miss the latest banner; common chart versions are unavailable offline; team notes need additional workflows not covered; or nobody can name the church buyer. Resolve those before adding AI or Android.

## Cloud infrastructure and budget · 2026-10-08

Status: researched recommendation, not a deployment or hosting benchmark. Assumptions pending user sizing: one church, 10–20 members, one hosted project and in-app chat first. No account/credential/resource/billing change occurred. Existing Supabase remains the primary backend under D20; AWS is an optional supporting service, not an approved replacement.

| Stage | Recommended setup | Planning budget, USD/month |
|---|---|---|
| Development | Supabase Free, local development database, verified SMTP sender | $0–5, assuming an existing domain and small backup/email usage |
| Real rehearsal pilot | One Supabase Pro Micro project, SMTP, independent file/database backup | $25–35 estimate, before tax/domain/Apple fees |
| AWS-only alternative | Cognito/SES, Lambda, HTTP + WebSocket API Gateway, DynamoDB, private S3 | $2–10 illustrative variable usage; substantially more implementation and operations work |

Supabase Free includes 1 GB file storage and 5 GB uncached plus 5 GB cached egress. Pro starts at $25/month with one Micro project covered by compute credits, 100 GB files and 250 GB each cached/uncached egress; another hosted project adds compute cost. Free may pause after seven inactive days, while Pro avoids inactivity pausing and includes seven daily database backups. Quotas are usage allowances, not pilot acceptance evidence or a Pro uptime SLA. [Pricing](https://supabase.com/pricing), [production checklist](https://supabase.com/docs/guides/deployment/going-into-prod).

Use Supabase Auth for managed email OTP/guest identities, Postgres for authorized metadata/private note heads/team heads/calls/chat, private Storage for immutable PDFs/native archives/previews, and Realtime for small authorized invalidation hints. No separate app server, Redis, Kubernetes, chat vendor or paid backend custom domain is needed initially. Select a region near the first team and keep data/compute together; no multi-region claim.

Sign-in email requires custom SMTP: the built-in provider is restricted to project-team addresses and two emails/hour. Resend Free offers 3,000 emails/month, 100/day. Alternatively use the user's AWS SES: current à-la-carte outbound is $0.10/1,000 emails; new account/region combinations default to Essentials at $0.16/1,000. Verify an owned domain/DNS, configure sender authentication, and request SES production access before unverified members can receive email. No dedicated IP is needed for this pilot. [Supabase SMTP](https://supabase.com/docs/guides/auth/auth-smtp), [Resend pricing](https://resend.com/pricing), [SES pricing](https://aws.amazon.com/ses/pricing/), [SES production access](https://docs.aws.amazon.com/ses/latest/dg/request-production-access.html).

The AWS-only estimate assumes 20 members, 2 GB files, 20 GB monthly downloads, 100,000 HTTP requests, 400,000 small WebSocket deliveries, 144,000 connected minutes and 200 OTP emails; shared ongoing allowances remain available. Representative US East rates: API HTTP $1/million, WebSocket $1/million deliveries plus $0.25/million connected minutes, S3 Standard $0.023/GB-month plus requests, Cognito Essentials first 10,000 direct/social MAU free. Account-wide allowances may already be consumed. New-customer promotional credits must not be assumed on this existing AWS account. This alternative rebuilds identity adapters, RLS-equivalent authorization, atomic revision/publication, invitations and realtime recovery. Avoid running a full self-hosted Supabase/EC2 stack just to reduce a small managed fee. [API Gateway](https://aws.amazon.com/api-gateway/pricing/), [S3](https://aws.amazon.com/s3/pricing/), [Cognito](https://aws.amazon.com/cognito/pricing/), [Free Tier eligibility](https://aws.amazon.com/free/free-tier-faqs/).

### Reliability and cost controls

- Cache verified immutable files once, download only missing/changed exact revisions, send metadata instead of stroke streams, and subscribe only to authorized active context. Example: 20 members × 20 newly downloaded charts × 2 MB × four weeks is 3.2 GB, before notes/API traffic. This is an illustration; cache reuse reduces it while full-library setup and large scans increase it. Text chat is inexpensive; PDF/preview history and downloads are likely larger cost drivers.
- Back up database metadata **and actual Storage objects** to a protected independent destination, optionally private AWS S3. Supabase database backups omit the objects themselves. Use consistent referenced-file manifests/hash verification and rehearse restoration before trusting a backup. Set a recovery target and retained copies; do not erase original charts/notes as a cost shortcut. [Backup limitations](https://supabase.com/docs/guides/platform/backups).
- Keep Pro's covered-usage spend cap enabled, add usage/error/email-delivery checks and AWS budget alerts if AWS is used. The Pro cap excludes explicitly provisioned compute/add-ons and can restrict service at quota; AWS budgets are alerts with delays, not an instantaneous billing cap. Do not provision branching, PITR, log drains, NAT or dedicated IP without a measured requirement and authorization. [Supabase cost control](https://supabase.com/docs/guides/platform/cost-control), [AWS budgets](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html).
- Free cloud upload maximum is 50 MB, below the existing 100 MiB local source-packet requirement. Retain large files locally and show an explicit provider limitation before cloud upload; paid cloud qualification must cover the full contract. Do not truncate, recompress or change source bytes to fit. Add resumable/file-backed upload behavior for larger PDFs. [File limits](https://supabase.com/docs/guides/storage/uploads/file-limits), [upload guidance](https://supabase.com/docs/guides/storage/uploads/standard-uploads).
- Finish the approved pinned PDF parser/finalizer and profile representative/malformed files in the deployed environment. Edge has 256 MB memory and two seconds CPU/request on both Free and paid plans; current buffered download may use nearly twice source size before parsing. Pro alone does not solve a parser CPU/memory limit. If evidence requires it, use a small bounded AWS Lambda validation worker behind the same managed authentication/finalization contract. No worker or new parser dependency is approved by this plan. [Runtime limits](https://supabase.com/docs/guides/functions/limits).

### Activation and new feature sequence

1. Obtain approval for the pinned parser dependency; finish and test production validation and cloud provider size guards.
2. Authorize one development Supabase project, sender/domain/DNS configuration and any AWS SES/backup resources. Configure real managed Auth/private Storage/Realtime. Keep client publishable settings separate from server-only credentials.
3. Qualify two iPads, accounts/guest scope, private note conflicts, team ink/cues, disconnects, lease takeover and backup restoration. Existing controlled HTTP/local SQL tests do not complete this gate.
4. Add the user-required text chat slice in the build plan. Enforce exact team membership, durable idempotent messages/edits, drafts, unread/mute and moderation; preserve the reader. Chat adds no separate fixed hosting subscription.
5. Add background chat push after the user elects paid Apple enrollment. Apple's capability matrix excludes Push Notifications from free Personal Team. Foreground cloud/chat can be developed now; APNs is not durable storage or guaranteed silent delivery. Qualify report/block/filter/support controls before distribution. [Apple capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-ios), [background notification limitations](https://developer.apple.com/documentation/UserNotifications/pushing-background-updates-to-your-app), [user-generated content](https://developer.apple.com/app-store/review/guidelines/#user-generated-content).
6. Other poster features need native work: keyboard-style Bluetooth pedal page commands with real accessory/typing/debounce tests; optional on-device camera/Vision gesture calibration and false-trigger/thermal/old-iPad qualification; reusable service templates/history/tempo and complete shared search metadata. Existing local clone/setlists/search already cover part of this. Camera frames need no cloud upload, and none of these should synchronize pages. Audio playback and broader AI/OCR remain separate excluded scope.

No new runtime code or app qualification occurred for this planning update. Actual hosted costs, provider account allowances, chat implementation, deployments and managed end-to-end behavior remain unverified.
