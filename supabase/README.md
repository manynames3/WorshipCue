# Private team backend

This is an additive Supabase pilot migration, with managed Auth identities, private Storage, transactional Postgres RPCs, and small bounded Edge handlers. It does not create a cloud project, configure billing, deploy a database, or enroll anyone in Apple Developer.

Ordinary clients authenticate through managed email OTP or managed anonymous sign-in. Signing up alone grants no church access. Anonymous identities can redeem a guest invitation for one setlist; their personal notes remain local. Members receive access through an active server-managed membership. An admin or leader cannot read another person's cloud ink, drawing assets, or previews.

## Activation checklist

The migration and client are reviewable; they do not create or deploy a project. Complete these only in an explicitly authorized development environment:

1. Approve and finish the pinned production PDF parser/finalizer entry, then run actual server PDF parsing tests. The current injected validator tests do not satisfy this gate.
2. Apply the additive migration to a fresh approved development database. Keep the private bucket and its RLS policies; ordinary users never receive service-role credentials.
3. Enable managed email OTP and configure its email template to show the code (`{{ .Token }}`) used by the native verification form. Enable managed anonymous identities for scoped guests and review rate/CAPTCHA/provider settings. Signing in alone creates no membership.
4. Configure only the project's HTTPS URL and publishable key in the ignored native `Secrets.xcconfig`. Server service credentials remain in the approved Edge environment. Use the reviewed function JWT settings together with the handler's managed-user authentication, never an unauthenticated finalizer.
5. Deploy the completed handlers only with authorization. Verify real Auth, PostgREST, private Storage and Realtime policies with members, leaders/admins, a scoped guest and an outsider before putting private musician material on the service.
6. Qualify two real iPads, failed downloads/publications, lease takeover, session end, guest revocation, private-note isolation and recovery; then rehearsal/oldest-device/Pencil gates. No billing or Apple distribution is enabled by this setup.

## Transport

Every ordinary RPC takes **one `p jsonb` parameter**. PostgREST requests are `POST /rest/v1/rpc/<name>` with JSON `{ "p": <payload> }`, a publishable key in `apikey`, and the user's access token in `Authorization: Bearer …`. Table reads also require the user's token and RLS. Never put the service-role key in the iPad app.

Expected SQL errors use `message` as the stable semantic code and a JSON `details` string containing `{code,message_key,retryable,correlation_id,details}`. CAS conflict details contain the authorized current head; the client must preserve its local candidate. Edge errors return the same envelope as JSON. Do not blindly retry live publication or silently change a command UUID after timeout.

All receipts include `schema_version: 1`. IDs are UUIDs, timestamps are server UTC, pages are zero-based, revision/sequence/epoch numbers are integers in the JSON safe range. Geometry accepts native camel keys or contract snake keys, then returns canonical snake keys:

```json
{"schema_version":1,"crop_x":0,"crop_y":0,"crop_width":612,"crop_height":792,"rotation":0}
```

## Library and preparation

| RPC | `p` fields | Result |
|---|---|---|
| `create_church_and_default_team` | `display_name`, IANA `timezone` | `church_id`, `team_id`, `role: admin` |
| `create_song` | `command_id`, `church_id`, `canonical_title`, optional `rights_note` | `id`, `song_id`, `church_id`, title |
| `stage_asset` | `church_id`, `type: pdf/native/preview`, `sha256`, `expected_bytes` | `id/asset_id`, `storage_key`, hash, bytes, status |
| `publish_chart_version` | `command_id`, `song_id`, `verified_pdf_asset_id`, `written_key` string or null, `label`, `page_manifest` geometry array | immutable chart receipt |
| `create_setlist` | `command_id`, `church_id`, `team_id`, `title`, `timezone`, optional `service_time` | `id/setlist_id`, `revision: 0` |
| `save_setlist` | `command_id`, `setlist_id`, `base_revision`, optional `title`, `items` array | committed `revision` |
| `set_personal_preference` | `song_id`, `preferred_version_id` | owner preference and its revision |
| `preflight_manifest` | `setlist_id` | setlist revision, `charts`, and full exact team `annotation_heads` receipts |

Each setlist item is `{id,song_id,team_chart_version_id,performance_key,position,kind}`. Planned positions are zero-based; standby position is null. Kind is `planned` or `standby`; only `publish_call` creates an `ad_hoc` occurrence. Removing an item marks it inactive rather than deleting history. Repeated songs need separate item UUIDs. Changing the song of an existing occurrence is rejected.

Chart receipts contain `id/chart_version_id`, `church_id`, `song_id`, `version_number`, `label`, `written_key`, `pdf_asset_id`, `pdf_sha256`, `pdf_bytes`, `page_count`, `page_manifest`, and `pages`. The last two contain the same canonical geometry array. Published PDF bytes and chart metadata cannot mutate; failed publication consumes no visible version number. A key label never transposes a PDF.

The preflight manifest includes team planned/standby charts, the signed-in member's preferred versions, and explicitly called extra charts. A guest gets only assigned exact team/called versions. Its `annotation_heads` array contains full authorized team revision receipts for exact active planned/standby item+team-version pairs and exact immutable called item+version pairs, including ad-hoc occurrences. It excludes personal notes, another setlist's occurrence, and unassigned/uncalled alternate-version heads even when the member prefers that alternate PDF. Download only the existing referenced snapshots rather than probing every possible page; readiness requires verified PDFs and those exact heads. Downloading the manifest or files never selects a displayed chart, acknowledges a call, or mutates server state.

## Assets and invitations

Upload the original bytes to private bucket **`worshipcue-private`**, at exactly the staging receipt's `storage_key`, using `upsert=false`. Storage update/delete is denied to clients. The original is not overwritten when a different version is published.

**Activation gate:** the shared handler below is tested with an injected PDF validator. Its production `finalize-asset` entry and actual PDF parser tests still require approval for a pinned parser dependency; this endpoint is not deployable yet. No cloud service is running.

`POST /functions/v1/finalize-asset` takes `{asset_id,sha256,expected_bytes}` with the user's bearer token. The Edge handler authenticates that token with managed Auth, checks ownership, downloads bounded bytes, compares actual length and SHA-256, parses PDF geometry or validates complete RGBA PNG data, then calls the service-only finalizer. PDF source limit is 100 MiB/200 pages; a published song chart is at most 20 pages. Native drawing and preview are each at most 2 MiB. Native verification is **bounded opaque archive verification**, not a server PencilKit decode or malware-free guarantee; actual native decode still occurs on iPad.

Server Edge environment is `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` (or legacy `SUPABASE_ANON_KEY`), and server-only `SUPABASE_SERVICE_ROLE_KEY`. No environment values or invitation tokens are logged. `verify_jwt=false` in the Edge configuration delegates validation to an explicit managed `/auth/v1/user` check; it does not permit unauthenticated actions.

`create_invitation` takes `{church_id,team_id,permitted_role,setlist_id,expires_at,max_uses}`. Only an admin may create it. Role is member, leader, or guest; no admin invitation is accepted. Member/leader scope has null setlist ID; guest scope requires an exact matching team/setlist. Expiry is within seven days; usage is 1–50. A high-entropy 64-character token is returned **once**. Only its SHA-256 is stored. `revoke_invitation` takes `invitation_id`; `revoke_guest_grant` takes `setlist_id,user_id`. Existing downloaded copies cannot be remotely erased while offline.

`POST /functions/v1/redeem-invitation` takes `{token,display_name?}` with a managed identity bearer token. The handler commits a per-identity attempt counter before validating the token, hashes it, and calls a service-only redemption transaction. Bounded use count and dedupe are locked together. The receipt is `{church_id,team_id,setlist_id,role,expires_at}`. Installation of the native app is required. `display_name` is bounded but deliberately not retained by this pilot schema; it is not proof of a verified member.

`finalize_asset`, `consume_invitation_attempt`, and SQL `redeem_invitation` are not executable by an ordinary authenticated client. Their server actor ID comes from the Edge's managed Auth response, never a body-supplied identity.

## Live calls and shared notes

| RPC | `p` fields |
|---|---|
| `acquire_editor` | `setlist_id`, `device_id`, `expected_epoch`, `explicit_takeover` |
| `renew_editor` / `release_editor` | `setlist_id`, `device_id`, `epoch` |
| `start_session` | `setlist_id`, `command_id`, `device_id`, `epoch` |
| `publish_call` | `session_id`, `command_id`, `device_id`, `expected_controller_epoch`, `expected_latest_sequence`, `performance_item_id`, `song_id`, `team_chart_version_id`, `performance_key`, optional `ad_hoc_draft: {id}` |
| `get_session_snapshot` | `session_id` |
| `acknowledge_open` | `session_id`, `call_id`, `device_id`, `selected_chart_version_id` |
| `end_session` | `session_id`, `command_id`, `device_id`, `epoch`; optional admin-only `explicit_admin_end: true` |

Lease receipts contain `setlist_id`, `controller_user_id`, `device_id`, `epoch`, `expires_at`, `active`. Leases last 60 seconds; foreground connected clients renew every 15 seconds. Device, actor, expiry, and increasing epoch all fence writes. Expiry uses the current server clock after locks, not a stale transaction-start time. Expiry never elects a new controller.

Session snapshots contain `id/session_id`, `church_id`, `setlist_id`, `status: LIVE/ENDED`, `latest_sequence`, `state_revision`, `controller_epoch`, nullable `latest_call`, newest-first `history` capped at ten, exact team `annotation_heads`, and `access: {scope,can_control,can_write_personal}`. Publication returns `{call,latest_call,latest_sequence,snapshot}`. An identical committed command retry returns its original immutable call plus the **current** latest head; it does not rewind history. A conflicting payload with that UUID is rejected.

An extra prepared song uses a fresh `performance_item_id` and `ad_hoc_draft: {id: same_uuid}`. Its song/chart/key comes from the validated top-level fields. The occurrence and call commit atomically without reordering planned songs. There are no page, navigation, haptic, audio, or readiness fields.

Acknowledgement records that one exact chart rendered. It can be historical and never advances the session's latest call. Receipt includes `opened`, `is_latest`, and `meaning: rendered_not_ready`; it does not claim the musician is ready. The client must **tap before opening** and recheck the exact call before swapping its display. Realtime publication includes only session/head metadata; treat every event as an invalidation hint and refetch the durable snapshot.

`save_annotation_revision` takes:

```json
{
  "layer_identity": {"church_id":"UUID","chart_version_id":"UUID","page_index":0,"scope":"personal","owner_user_id":"UUID","performance_item_id":null},
  "command_id":"UUID","parent_revision":0,"native_asset_id":"UUID","preview_asset_id":"UUID",
  "geometry":{"schema_version":1,"crop_x":0,"crop_y":0,"crop_width":612,"crop_height":792,"rotation":0},
  "device_id":"UUID"
}
```

Team identity uses `scope: team`, null owner, exact performance item, plus `controller_epoch_if_team`. Both assets must be verified, uploaded by the actor, and in the same church; geometry must equal that exact PDF page. Team writes require the valid setlist editor lease. Parent revision is numeric: zero for a new layer. CAS conflicts preserve the existing head. Same command/payload returns the same revision; altered content with that command UUID fails.

`get_annotation_head` takes `layer_id` or `layer_identity`. It returns JSON null for an authorized exact identity with no head. A receipt includes the full exact identity, `revision_id`, `revision_number`, parent/command, canonical geometry, native/preview asset IDs, storage keys, SHA-256, and byte counts. PNG is derived read-only ink; it is not editable or automatically applied to another version. Different occurrences and versions never share a layer implicitly.

## Running verification

```sh
python3 scripts/test_backend.py
deno test supabase/tests/edge_test.ts
```

The Python check creates a unique **external-drive** PostgreSQL cluster on a fresh localhost port, uses Supabase-compatible Auth/Storage schema shims, runs the migration, tests actual authenticated non-owner RLS/RPCs, and stops only its own cluster. It accepts no existing database URL and resets nothing. Evidence is written outside Git under `DeveloperTools/WorshipCue/BackendTests`.

Those tests do not qualify managed email delivery, native OTP, actual Storage HTTP, Realtime authorization/delivery, a cloud deployment, service backup/restore, account lifecycle, or physical multi-iPad rehearsal. Account export/deletion and content-rights removal need a reviewed retention/Auth workflow before wider distribution; no destructive account endpoint is exposed. No service is currently configured or deployed by these files. See [backend evidence](../verification/M2-M4-backend.md).
