# AWS and iPad qualification · v2 Build 7 · 2026-10-08

The user reconnected the iPad and requested continued work toward end-user readiness. Build 7 adds advanced chat, team administration, durable publication retries, paged archives, personal-record export and stronger mail/backup operations. This remains a development qualification, **not an end-user release**. [Build 6](AWS.md) is preserved as historical evidence.

## Implemented behavior

- Chat: own edit/delete, replies/jump, leader pin/delete, report/block/unblock and leader report resolution/dismissal. Deleted/blocked text stays hidden even in old command receipts. Read cursors advance only from a measured visible frontier, not closed-room fetching/offscreen prefetch. Mutations retain frozen commands and require explicit retry. Authorized chart links open an independent preview; opening the music stand requires a separate tap.
- Team administration: own display names, role/access changes, explicit administrator handoff and paged invitation review/revocation. Transactional authority preserves the last active administrator under races. Malformed receipts preserve pending actions and cached rosters; privileged reads follow refreshed roles after handoff.
- Publication: original PDF bytes, frozen stage/create/finalize/publish/setlist commands and acknowledged receipts survive dropped responses. Failed catalog refresh does not duplicate publication. Changed intent is refused. Only connectivity failure can fall back to a verified cached chart; access/integrity failures cannot.
- Catalog: pages are bounded to 100 rows/512 KiB. Owner-bound opaque cursors fence exact membership, guest grants and setlist revisions. Guest pages enumerate permitted charts and historical called items. Native assembly validates the entire catalog before atomic cache promotion; partial, looping, foreign or changed-scope pages are rejected.
- Account export: protected atomic selected-team JSON includes only own membership/preferences, personal annotation records and verified personal-file references, current own chat/tombstones and chat settings. No other owners, shared/source PDFs, team ink, credentials or invitation secrets. This is a records/manifest export, **not file bytes or a standalone ink backup**. Preflight identifies sole-administrator handoff and unavailable memberships. Account deletion remains unsupported and disclosed.
- Mail: exact SNS/configuration/sender/destination validation, hashed permanent bounce/complaint suppression, repeat-code refusal, and an encrypted 14-day recovery queue covering delivery and asynchronous processing failure. Four mail and two backup alarms have exact account/source restrictions on a confirmed operator topic.
- Backup: conditional versioned S3 lease/checkpoints retain one database-backup intent. Each invocation verifies up to 100 objects; later invocations resume verified progress. Unknown creation outcomes reconcile by exact table/name. Complete manifest and completion metric require an available database backup and verified pinned copies. Bounds:100 MiB/object and 8 MiB/checkpoint/manifest. No aged-backup/orphan deletion enabled.
- Database contention: retry only a proven aborted transaction whose complete cancellation reasons are exclusively None/TransactionConflict. At most five attempts reuse identical operations, original authorization/CAS checks and one request token; maximum total jitter delay 0.75 s. Actual conditional failures stop with 409; exhausted contention/unknown outcomes reach 503. Revocation during a retry cannot create a cursor. [AWS transaction behavior](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/transaction-apis.html), [request-token contract](https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_TransactWriteItems.html)

No automatic song changes, page synchronization, automatic note merging or transfer. Existing local material and frozen v1/main are preserved. No new production dependency beyond the approved pinned PDF parser.

## Actual results

| Check | Result and limits |
|---|---|
| Final AWS suite | **185 passed/0 failed**, exit 0: 76 domain, 37 backup/readiness, 32 identity/file/realtime boundary, 16 auth-limit, 8 store, 2 logout, 14 mail-feedback. Provider fakes except actual PDF parsing. |
| Real hosted scenarios | **27 passed/0 failed**, exit 0: Cognito, HTTP/Lambda, DynamoDB, private S3 and native Swift WebSockets; isolated synthetic identities/material. Includes administrator handoff/last-admin CAS, invitation review, 106-song paging, exact guest catalog/owner export and denials. Rerun passes against the final deployed contention repair. |
| Initial 20-client check | **18 passed/2 failed**, exit 1; 39 attempts, 19 retried HTTP 503, 2 final revision conflicts. Retained failure; CloudWatch independently records 2 TransactionConflicts in that window. One first-page read per simulated client using two existing synthetic managed identities. After repair: **20 passed/0 failed**, exit 0, 40 attempts/20 HTTP 503 retries; 2.047s elapsed, p95 1.994s. The changed adapter is deployed; no revision conflicts remain. |
| 50-client burst after repair | **48 passed/2 failed**, exit 1; 135 attempts, 14 HTTP 429 and 73 HTTP 503 responses; 5.921s elapsed, p95 5.756s. Two clients exhaust bounded retries. No revision conflicts. The development Lambda quota is ten; this is a failed capacity qualification, not 50-user readiness. A four-minute window around this run records 93 Lambda throttles and five internal DynamoDB transaction conflicts; the window also includes other request activity and does not attribute each response individually. |
| Actual backup worker | **Complete**, exit 0; 7 pinned file copies, 1 copied/6 verified-reused, database available and manifest written. This small actual archive completed in one invocation; real multi-invocation scale is not inferred. |
| Actual restore | **Complete**, exit 0: 756 restored rows, all 661 stable rows exactly match the quiescent source; seven verified assets/seven published file references and 13 immutable live rows checked. 749 unchanged live rows match; seven changed/ephemeral rows reported separately. One exact-receipt scratch table deleted, exit 0; no application data replacement or transactional snapshot claim. |
| Simulator feedback/recovery | **2 feedback scenarios+2 repeat-code denials pass**. Malformed asynchronously accepted event retries into private recovery; only its exact owned marker removed. Exact AWS setup probe replay: 1 processed/0 suppressions, precisely removed. SNS transport-failure injection not performed; simulator results do not prove recipient inbox delivery. |
| Operator alerts | Human subscription independently verified confirmed. Direct SNS test accepted; owned mail-backlog CloudWatch transition has successful exact-topic action history and naturally returns OK. Inbox receipt unverified. All six policies/configurations validate. An owned BackupErrors transition also proves exact-topic SNS action and natural OK, exit 0, without manual reset. BackupStaleCompletion naturally reaches OK after real completion metrics; its notification delivery remains unexercised. All six alarms end OK. |
| SES production request | One authorized submission initially PENDING; final **DENIED**, production false. Ordinary unverified recipients cannot receive codes. No resubmission/appeal. |
| Helper self-tests | **12 mail-operations, 4 mail-qualification, 13 restore, 5 load** pass, exit 0. SES draft checks pass without AWS submission. |
| Portable core/reference/local | **55 core, 32 Python reference, 14 local persistence** pass; 9 InkChecks groups pass, exit 0. |
| Swift remote | **28 passed/0 failed**, exit 0: bounded paging above 4 MiB aggregate, empty advancing pages, cursor/scope/loop checks, later-page 403/409/503 without partial return. |
| Actual iPad hosted suite | **86 executed: 85 passed+1 optional private-input skip+0 failure**, exit 0, iPadOS 17.7.11: 46 workspace/10 administration/10 account-export/20 ink. Actual administration/export screens rendered and inspected. |
| Opt-in private-PDF native | Separate **1 passed/0 failed**, exit 0 with both user arrangements; 8 PDFKit pages rendered and first pages inspected. Immutable originals, manual transfer/export and recovery pass. Private sources/images stay outside Git. |
| Touch UI retry | **Exit 65; zero actual UI cases executed**. Result bundle records 1 runner-initialization failure: timed out enabling automation mode. Blocked, not a passed touch test. |
| Native builds/config | Release and generic Debug test build succeed, exit 0, external Xcode 27.0 / 27A266a, Build 7/minimum 16.0. Actual Release/signed bundle 9 checks each pass; 5 negative fixtures rejected. |
| Project/localization | Generator reproduces project+both schemes byte-for-byte; verifier passes 18 app/4 hosted/1 UI sources. 557 Korean catalog keys. |
| Existing local material | Before/after tests and normal launch: all 7 PDFs and every column of 3 ink rows identical; both SQLite checks OK; matches prior backup. 2 original private Mac PDFs unchanged. |
| Normal installed app | Build 7 verified, launched successfully without test arguments/test-store variables. Final normal-screen capture unavailable because Mac is locked; no bypass. |

## Failures retained and corrected

Initial signed run: 50 passes/1 private-input skip/1 visible-chat-read failure across 52 cases. Actual viewport preference was overwritten by default geometry; repaired reducer passes focused device case and final suite. Touch-runner timeout remains blocked.

Initial operator-topic deployment rolled back because SNS statement IDs were not unique; focused regression and corrected 50-resource deployment pass. Existing database/buckets/Cognito retained. Malformed-feedback versus exact AWS setup-probe handling repaired; original privately preserved/replayed precisely. Initial async recovery command failed before acceptance; corrected binary-payload invocation passes.

Independent review reproduced the final guest-grant fence gap; canonical grants now participate in the final transaction and revoked/stale guest access fails. A reused smoke fixture also failed an unfiltered exact-two-chart expectation after a previous scenario gave the synthetic member another legitimate team membership. The helper now selects the exact team, checks every team/church identity and uniqueness, requires the baseline charts and rejects known foreign IDs; five local checks and the final 27-scenario run pass. Initial 20-client contention failures led to the adapter distinction above; 20 clients now pass, but the 50-client throttling failure remains an open capacity gate. Initial restore used an invalid argument name and exited 2 before any restore. After successful restoration, cleanup returned SCRATCH_IDENTITY_REQUIRED while AWS omitted identity fields during DELETING. The repaired helper accepts omission only for an already saved deletion request and immutable identity, rejects present mismatches, and passes five new regressions. Reconciliation confirms the table absent without repeating DeleteTable. Original failures remain retained.

## Commands and evidence

Run from repository root. Private config, identifiers/tokens, mail payloads, source scans, raw device results/screenshots stay on the external drive. Ignored `verification/chat7-*.log` retain exact local exits/corrections. Curated `chat7-*.json` contain only sanitized counts/status.

```sh
PYTHONPATH='../DeveloperTools/WorshipCue/AWS/vendor:aws/src' python3 -m unittest discover -s aws/tests
python3 aws/package_backend.py --output '../DeveloperTools/WorshipCue/AWS'
python3 aws/scripts/deploy.py --config /absolute/external/AWS/private-config.json
python3 aws/scripts/smoke.py --config /absolute/external/AWS/private-config.json --state-directory /absolute/external/AWS/HostedSmoke
python3 aws/scripts/load_check.py --config /absolute/external/AWS/private-config.json --state-file /absolute/external/AWS/HostedSmoke/qualification-state.json --clients 20
python3 aws/scripts/restore_check.py --config /absolute/external/AWS/private-config.json --state-dir /absolute/external/AWS/RestoreCheck-Build 7 --source-snapshot /absolute/external/AWS/RestoreCheck-Build 7/quiescent-source.json
python3 scripts/test_m1_device.py --group native --full-native --command-timeout 300
```

Portable checks use `scripts/with_external_xcode.sh swift test` for reference/WorshipCueCore, packages/WorshipCueLocal and packages/WorshipCueRemote; `swift run` for InkChecks; the existing reference environment runs `scripts/verify_package.py`. Scratch directories remain under external DeveloperTools/WorshipCue.

Final hosted device bundle: external Results/Chat7-All-Final-20261008.xcresult. Private PDF run explicitly supplies user files; destinations are observed, never invented. Operational receipts: external AWS/MailQualification, MailOperations, RestoreCheck-Build 7. [SES operations](../docs/SES_PRODUCTION_READINESS.md), [account/retention facts](../docs/ACCOUNT_DATA_AND_RETENTION.md).

## Open release gates

SES denied production access. Status API gives no explanation; Support API reading returned SubscriptionRequiredException. Browser access awaits direct user sign-in or actual denial explanation. No paid Support upgrade/speculative appeal. Broader onboarding blocked.

Actual native real-account cloud workflows, new-build physical touch UI, two iPads, physical Pencil, original iPadOS 16 hardware, background/resume/airplane stress, maximum-file performance, WebSocket fanout and two-hour rehearsal remain unverified. Account deletion, approved retention/orphan cleanup, complete-file account export and support/distribution readiness remain unfinished. Backup is not an atomic database/files snapshot. Shared development Lambda concurrency quota 10; bounded API burst checks do not replace representative sustained load.

Free Personal Team profile expires October 14. No annual Apple enrollment/APNs/TestFlight/billing feature/public app release. AWS usage projections are not measured bills.
