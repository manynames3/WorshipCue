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
| Daily backup Lambda | Independent version-pinned file copies, DynamoDB backup and checksummed manifest |

There is no EC2 instance, RDS database, load balancer, NAT gateway or custom KMS key. Deployment is scoped to `worshipcue-dev` in `us-east-1`; the code bucket has its own small development stack. The account currently permits ten concurrent Lambda executions, so this deployment uses the shared account limit. HTTP throttling and application auth limits protect the pilot, but are not a billing hard cap.

## Implemented behavior

- Church/default-team and additional-team creation, explicit membership, invitations, revocation and setlist-scoped guests.
- Immutable charts with server-verified PDF bytes, hashes and page geometry. S3 rejects checksum errors and overwrites. Publication is a separate transaction.
- Personal note ownership and compare-and-swap conflicts; shared snapshots with exact item/version/page identity and fenced editor leases.
- Durable, sequenced live calls, terminal session end and historical acknowledgements. Announcements never move a reader or page.
- Team/setlist chat with server ordering, stable send IDs, catch-up, replies, edits, tombstones, read cursors, mute, pin, report and block operations. Guests receive no team chat.
- Native Korean chat panel with cached history and durable, explicitly retried drafts. Several advanced chat operations still need native controls and qualification.
- Foreground WebSocket reconnect with fresh tickets, bounded backoff and polling recovery. No background push is implemented.

Authorization runs before cached command receipts are returned. Church administration does not grant another team's content access. Published asset downloads require a permitted chart or annotation reference. Personal activity does not generate team-wide hints.

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
  --aws-config /absolute/external/AWS/private-config.json --build-number 6
python3 aws/scripts/smoke.py --config /absolute/external/AWS/private-config.json \
  --state-directory /absolute/external/AWS/HostedSmoke
```

The smoke runner creates isolated synthetic managed identities and data. It never uploads the user's local chart collection or prints credentials. It uses the existing AWS CLI, native Swift WebSockets and approved parser; no additional production dependency is required.

## Backup and recovery

The table has point-in-time recovery. Both asset and backup buckets are private and versioned. At 04:00 UTC daily, the backup worker creates an on-demand database backup, copies immutable source object versions, verifies bytes/checksums and writes a complete manifest. Failed or incomplete work does not produce a successful result. Existing verified copies are reused; no automatic retention deletions occur in this pilot.

The initial bound is 1,000 objects, including native ink and preview revisions, with 100 MiB per object. This is not a 1,000-song archive guarantee. Raise it deliberately after workload and restore qualification. Backup growth, orphan staging cleanup, retention and operator alert delivery still need an operational policy before a broader pilot.

`restore_check.py` hashes actual downloaded backup bytes, restores a database backup into a separate UUID-named test table, validates row digests and published file references, and optionally compares stable rows to a private quiescent source scan. It keeps the scratch table by default. Cleanup is restricted to a table created by its exact private ownership receipt; it cannot replace the application table.

## Current limits

The SES account remains in the sandbox: recipients must also be verified. Verifying the sender alone does not enable arbitrary church members' email codes. Production SES access is a separate approval gate. Real email-code verification, protected membership access, refresh and sign-out passed with the user's verified recipient; both refresh and protected requests were denied after sign-out.

Cloud qualification is synthetic, not a multi-iPad rehearsal. Actual PencilKit archive uploads, disconnected drafts, background/resume, original iPadOS 16 hardware, fifty clients, a two-hour soak and representative maximum-sized PDF performance remain unverified. Account export/deletion explicitly reject unsupported requests. Native moderation controls, moderator workflow and authorized chart links are unfinished. No paid Apple enrollment, APNs, TestFlight or public release is enabled.

See [exact AWS evidence](../verification/AWS.md), [milestone plan](../docs/12_BUILD_PLAN.md) and [project state](../PROJECT_STATE.md).
