# AWS development qualification · v2 Build 6 · 2026-10-08

The user selected AWS (D45), approved the pinned PDF parser and verified the initial email sender. The development backend is deployed in `us-east-1`. Build 6 includes the native AWS transport, isolated team workspaces and Korean team/setlist chat. This report separates actual hosted checks, controlled tests, compilation and unverified device behavior.

The user disconnected the iPad during this work. **No Build 6 native or UI test executed on a device.** Earlier [Build 5 device evidence](M2-M4-native.md) remains historical; it does not qualify the new cloud workflows.

## Implemented and deployed

- Managed Cognito email-code and invite-bound guest authentication; access-token validation, refresh, session-scoped revocation and durable auth rate limits.
- Separate libraries, setlists, shared notes, sessions and chat for each team, including teams in the same church. Church administration alone grants no other-team content access.
- Private, versioned S3 with checksum-bound conditional uploads and short-lived downloads. Server validation checks PDF bytes, immutable publication and native-compatible page geometry.
- DynamoDB conditional transactions for idempotent commands, revisions/conflicts, editor epochs, ordered cues and durable chat. Personal notes remain owner-only.
- One-use WebSocket tickets, membership/session revalidation and content-free hints. Native reconnect uses fresh tickets; catalog updates coalesce and have a 60-second missed-hint fallback.
- Native chat cache and durable drafts with explicit send/retry; team switching fences late callbacks and separates caches/outboxes. Existing standalone and legacy church vaults are preserved.
- Daily 04:00 UTC backup schedule, DynamoDB point-in-time recovery and independent version-pinned file backups with a checksummed complete manifest.

Incoming calls, catalog changes, chat, reconnect and session end never select a song or page. No automatic note merging or transfer was added. AWS credentials stay on the Mac/server; the app contains public API/WebSocket endpoints only, supplied through ignored local configuration.

## Recorded results

| Check | Exact result and scope |
|---|---|
| AWS Python suite | **101 passed, 0 failed**, exit 0: 35 domain/store, 31 identity/file/realtime boundary, 16 auth-limit, 15 backup, two empty-key query and two logout-fallback tests. Provider fakes are used except real PDF parsing. |
| Real deployed AWS smoke | **17 passed, 0 failed**, exit 0. Uses real Cognito, HTTP API/Lambda, DynamoDB, S3 and native Swift WebSocket connections with isolated synthetic identities/material. |
| Real user email authentication | Fresh email code verified; protected membership request, same-identity refresh and sign-out succeeded. Both refresh and protected access were rejected with HTTP 401 after sign-out. No code, email or tokens are recorded here. |
| Real backup/restore | Complete manifest; six file copies verified; database backup AVAILABLE. Isolated restore produced **151 rows**, with **134 stable rows exactly matching** the quiescent source scan and **six verified assets / six published file references**. Eleven immutable live rows checked; 141 live rows matched, ten changed/ephemeral rows reported separately. |
| Restore cleanup | **One scratch table deleted**, exit 0. Cleanup uses the exact private creation/ownership receipt; application table was not replaced. |
| Restore helper contracts | **11 passed, 0 failed**, exit 0. Includes wrong-byte rejection despite claimed checksum, source-table cleanup refusal and actual AWS CLI argument/restore-summary regressions. |
| Swift core | **55 passed, 0 failed**, exit 0. |
| Python reference | **32 passed**, exit 0, using the existing reference verification environment. |
| Swift local storage | **14 passed, 0 failed**, exit 0; **nine InkChecks groups passed**, exit 0. |
| Swift remote transport | **24 passed, 0 failed**, exit 0. Includes AWS keyless configuration/auth/storage, strict aggregate catalog validation, WebSocket lifecycle and fallback cadence. |
| Release native app | Xcode 27 generic iOS Release **BUILD SUCCEEDED**, exit 0, Build 6 / minimum iPadOS 16.0. Unsigned compilation only. |
| Debug native/UI test build | `WorshipCueUI` generic iOS **TEST BUILD SUCCEEDED**, exit 0. **44 hosted native cases and 11 UI cases compile; none executed in this AWS task.** |
| Actual Release bundle | **Nine configuration checks passed**, exit 0: custom keys present/expanded, AWS selected, endpoints valid and matching deployed outputs, standard metadata and iPad presentation merged. |
| Configuration checker regressions | **Five negative fixtures passed**, exit 0: missing keys, unexpanded values, wrong provider, insecure endpoint and unsupported minimum OS rejected. |

The native compile-only cases include a burst of ten catalog hints adding a newly published song without joining a live session, preserving reader/page and bounding concurrent catalog requests. Malformed catalog responses preserve cached rows. These remain compile-qualified until device execution.

Final source checks passed: generated 31-resource template equals the checked-in template; packaged backend source and deployed code hash match; project/resource/scheme checks, Python compilation and `git diff --check` pass. All 77 checked landing-page/setup/report local links resolve. Independent review repeated 66 focused boundary/domain tests and found no concrete new defect; the 52 pending public text files had no detected credentials or private deployment identifiers.

### Real hosted scenarios

All of the following passed in the final smoke run:

1. Hosted API health.
2. Managed synthetic identity setup.
3. Managed refresh and rejection of ID tokens used as access tokens.
4. Church/default-team and additional-team command idempotency.
5. Signed PDF checksum validation, finalization and overwrite rejection.
6. Published PDF download byte integrity.
7. Same-church other-team and outside-church access denial.
8. Setlist compare-and-swap conflicts.
9. Cross-team chart rejection from setlists.
10. Personal archive ownership and revision conflicts.
11. Durable chat send deduplication, catch-up and exact-team scope.
12. Managed guest exact-setlist restriction and team-chat denial.
13. Aggregate catalog member/guest equivalence and selected-team denial.
14. Live sequence/deduplication, historical acknowledgement and terminal session end.
15. One-use realtime ticket, content-free hint delivery and durable catch-up.
16. Revocation denying requests and old cached command receipts.
17. Session-scoped logout and malformed-access-header fallback through a valid refresh token.

The last fallback uses a deliberately malformed access header, **not a measured one-hour expiration**. Synthetic native-archive bytes qualify server privacy/revision handling, **not actual PencilKit serialization or device rendering**.

## Commands and toolchain

Tools used: Python **3.14.6**, AWS CLI **2.34.31**, external Xcode **27.0 / 27A266a**, Swift **6.4**. Deployed Lambdas use Python **3.13 / ARM64**. `pypdf==6.19.0` is the only added production dependency; its approved BSD-3-Clause wheel hash and notice are in [dependency review](../aws/THIRD_PARTY.md).

Commands below were run from the repository. Private inputs, code packages, build caches and restore scans stay on the external drive under `../DeveloperTools/WorshipCue`; actual account/device identifiers are omitted.

```sh
python3 aws/generate_template.py
python3 aws/package_backend.py --output '../DeveloperTools/WorshipCue/AWS'
PYTHONPATH='../DeveloperTools/WorshipCue/AWS/vendor:aws/src' \
  python3 -m unittest discover -s aws/tests
python3 aws/scripts/deploy.py --config '../DeveloperTools/WorshipCue/AWS/private-config.json'
python3 aws/scripts/configure_native.py --config '../DeveloperTools/WorshipCue/AWS/private-config.json'
python3 aws/scripts/smoke.py --config '../DeveloperTools/WorshipCue/AWS/private-config.json' \
  --state-directory '../DeveloperTools/WorshipCue/AWS/HostedSmoke'

sh scripts/with_external_xcode.sh swift test --package-path reference/WorshipCueCore \
  --scratch-path '../DeveloperTools/WorshipCue/CorePackageBuild-M1'
/tmp/worshipcue-reference-verification-venv/bin/python3 scripts/verify_package.py
sh scripts/with_external_xcode.sh swift test --package-path packages/WorshipCueLocal \
  --scratch-path '../DeveloperTools/WorshipCue/LocalPackageBuild-M1'
sh scripts/with_external_xcode.sh swift run --package-path packages/WorshipCueLocal \
  --scratch-path '../DeveloperTools/WorshipCue/LocalPackageBuild-M1' InkChecks
sh scripts/with_external_xcode.sh swift test --package-path packages/WorshipCueRemote
python3 scripts/verify_m0_project.py

sh scripts/with_external_xcode.sh xcodebuild \
  -project apps/ipad/WorshipCue.xcodeproj -scheme WorshipCue \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath '../DeveloperTools/WorshipCue/DerivedData-AWS' \
  -clonedSourcePackagesDirPath '../DeveloperTools/WorshipCue/SourcePackages' \
  CODE_SIGNING_ALLOWED=NO build
sh scripts/with_external_xcode.sh xcodebuild \
  -project apps/ipad/WorshipCue.xcodeproj -scheme WorshipCueUI \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath '../DeveloperTools/WorshipCue/DerivedData-AWS-Tests' \
  -clonedSourcePackagesDirPath '../DeveloperTools/WorshipCue/SourcePackages' \
  CODE_SIGNING_ALLOWED=NO build-for-testing
python3 scripts/verify_native_configuration.py \
  --app '../DeveloperTools/WorshipCue/DerivedData-AWS/Build/Products/Release-iphoneos/WorshipCue.app' \
  --aws-config '../DeveloperTools/WorshipCue/AWS/private-config.json' --build-number 6

python3 aws/scripts/restore_check.py --self-test
python3 aws/scripts/restore_check.py \
  --config '../DeveloperTools/WorshipCue/AWS/private-config.json' \
  --source-snapshot '../DeveloperTools/WorshipCue/AWS/restore-source-scan.json' \
  --state-dir '../DeveloperTools/WorshipCue/AWS/RestoreCheck' --keep
python3 aws/scripts/restore_check.py \
  --config '../DeveloperTools/WorshipCue/AWS/private-config.json' \
  --state-dir '../DeveloperTools/WorshipCue/AWS/RestoreCheck' --cleanup
```

The restore operator completed the corrected helper against the existing isolated restore; provider receipts and file hashes remain private. Raw logs are local/ignored: `aws-tests.log`, `aws-hosted-smoke.log`, `aws-owner-auth-check.log`, `aws-core-tests.log`, `aws-reference-tests.log`, `aws-local-tests.log`, `aws-ink-checks.log`, `aws-remote-tests.log`, `aws-native-release-build.log`, `aws-native-test-build.log`, `aws-native-bundle-config.log`, `aws-native-config-regression.log` and `aws-restore-cleanup.log`. Private restore completion/ownership receipts remain external. Results above do not rely on the failed preliminary `aws-restore-check.log`.

## Failures retained and corrected

- Initial deployment with ten reserved Lambda executions failed because the account limit is ten and AWS requires ten unreserved. Empty resources from that failed creation were removed only after ownership/emptiness checks. Retry succeeded using the shared account quota. Current main stack is `UPDATE_COMPLETE`; the code-artifact stack is `CREATE_COMPLETE`.
- The first real transactional operation returned 503 because the IAM role lacked `dynamodb:ConditionCheckItem`. Actual IAM simulation confirmed denial; the specific development-table permission was added and hosted operations passed.
- Real WebSocket connect/ticket succeeded but hint delivery failed: DynamoDB rejects `begins_with(SK, '')`. Whole-partition queries now use a PK-only condition; two regression tests and real hint delivery passed.
- A Swift actor-access build error was fixed by exposing immutable Sendable transport configuration without actor isolation.
- Build settings contained endpoints, but the compiled bundle omitted the custom Info keys. An explicit source Info.plist now merges expanded configuration; artifact checks pass.
- Restore helper retries retained actual CLI parameter-validation errors and a missing `RestoreSummary` after ACTIVE. The corrected helper uses explicit object arguments and the exact creation identity. A premature cleanup attempt failed safely with `SCRATCH_IDENTITY_REQUIRED`; final qualified cleanup succeeded.
- The first user email-code verification session expired after approximately 28 minutes. AWS confirmed expiration; a fresh code/session then completed all real authentication checks. Codes and sessions remain private.

## Unverified requirements and operating limits

- **Email onboarding:** SES is still sandboxed. Only verified recipients can receive codes. Sender verification and one successful account do not permit arbitrary church users. No SES production-access request was submitted.
- **Device behavior:** Build 6 installation, native/UI execution, real PencilKit archive sync, actual disconnected drafts/account switches, two iPads sharing marks/cues/chat, physical Apple Pencil, original iPadOS 16.7.16 hardware and background/resume remain unverified. Minimum 16.0 is compilation evidence only for that older hardware.
- **Rehearsal/performance:** Fifty clients, concurrency/latency targets, representative maximum-sized PDFs, memory/thermal pressure and two-hour soak remain unverified. Current shared Lambda concurrency quota is ten, not evidence of 100-user capacity.
- **Backup operations:** The restore used a quiescent source scan, not a transactional concurrent database/files snapshot. No automatic retention deletion exists. Initial backup bound is 1,000 objects including ink/previews, each up to 100 MiB; this is not a 1,000-song capacity claim. Retention, orphan cleanup, growth limits and delivered operator alerts remain operational work.
- **Chat/account completeness:** Server reply/edit/delete/read/mute/pin/report/block operations exist; several native controls, authorized chart links and moderator workflow are unfinished. Account export/deletion explicitly reject unsupported requests.
- **Distribution:** Free Apple Personal Team remains the only authorized signing setup. No annual membership, APNs, TestFlight, app billing or public release is enabled. AWS resources incur usage charges; cost models are estimates, not measured bills or hard spend caps.

M2–M5 are implemented in part and hosted-qualified as stated above. Their device/rehearsal gates remain open. This is a development checkpoint, not an end-user-ready release.
