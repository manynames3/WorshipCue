# Data model, invariants, and server contract

This is the implementation specification for production Postgres migrations/RLS/RPCs. The handoff does NOT include a deployable, security-verified Supabase migration. Codex must implement it, run it against local Postgres/Supabase, and prove the access matrix before staging. The executable SQL included in `db/` is only the local SQLite reference cache.

## 1. Global conventions
Use UUIDs generated once per entity/command; integer revisions/sequences within the JSON safe integer range; UTC ISO-8601 server timestamps; explicit church timezone (IANA identifier); and `schema_version=1` on persisted/transported contracts. Server generates order, not client clocks. IDs are never inferred from titles, filenames, displayed version numbers, or page object addresses.

Clients display pages 1..N; contracts and storage use `page_index=0..N-1`. Enforce conversion in one adapter. Every tenant-scoped foreign key must preserve tenant identity using composite constraints or a validated RPC. A supplied `church_id` is never sufficient authorization.

## 2. Entities
| Entity | Key fields and rules |
|---|---|
| churches | id, name, timezone, lifecycle; billing boundary |
| teams | id, church_id, name; default one per church |
| memberships | church_id, team_id, user_id, role, active; server-controlled role, not user-editable metadata |
| songs | id, church_id, canonical_title, normalized_title, initials, optional composer/source id, archived_at |
| song_aliases | id, song_id, church_id, alias, normalized_alias, type; optional hymn number MUST include edition |
| assets | id, church_id, owner_user_id, type, immutable storage key, SHA-256, bytes, status staging/verified/rejected; only finalizer may verify |
| chart_versions | id, church_id, song_id, monotonically assigned version_number, label, written_key nullable, PDF asset_id, page_count, immutable page geometry/hash manifest, published_at, archived_at |
| source_imports | id, church_id, source_asset_id, draft state, publisher, completion checkpoints |
| import_slices | source_import_id, source page indices, provisional song metadata, output asset; may omit covers |
| setlists | id, church_id, team_id, title, service_time/timezone, revision, state draft/published/archived |
| performance_items | id, church_id, setlist_id, song_id, team_chart_version_id, performance_key, position nullable, kind planned/standby/ad_hoc, revision; repeated song appearances have different IDs |
| personal_preferences | user_id, church_id, song_id, preferred_version_id, revision; private to owner |
| editor_leases | setlist_id, controller_user_id/device_id, epoch increasing, expires_at; single editor/controller for the setlist |
| live_sessions | id, church_id, setlist_id, status, latest_sequence, latest_call_id, state_revision; max one active per setlist |
| live_calls | id, church_id, session_id, sequence, command_id, performance_item_id, song_id, team_chart_version_id, performance_key, actor_user_id, controller_epoch, created_at; immutable |
| participants | session_id, user_id, device_id, last_seen_at, latest_received_call_id, last_opened_call_id and chosen version; never actual-ready boolean |
| annotation_layers | id, church_id, chart_version_id, page_index, scope personal/team, owner_user_id nullable, performance_item_id nullable; exact uniqueness and constraints below |
| annotation_revisions | id, layer_id, parent_revision, server_revision, command_id, native_asset_id, preview_asset_id, geometry_version, editor_user/device, created_at; immutable |
| annotation_heads | layer_id, revision_id, revision_number; small metadata for authorized realtime |
| guest_grants | user_id, church_id, setlist_id, expires_at, revoked_at; narrow access to this setlist + its standby/ad_hoc called charts |
| invitations | token_hash, church_id, team/setlist scope, inviter, permitted role, expiry, max_uses, used_count, revoked_at; no plaintext token storage |
| audit_events | actor, tenant, resource ID, action, time; no PDF/ink content |

### Critical relational checks
- A chart's song/church matches its containing performance item.
- A call's performance item belongs to the session's setlist; call song/version belong to that item/song/church. The immutable call captures its chosen version/key even if the planned item is edited later.
- `unique(song_id, version_number)`; versions assigned transactionally, not `count+1` without locking.
- `unique(session_id, sequence)` and `unique(session_id, command_id)`.
- Personal layer: owner non-null; performance item null. Team layer: performance item non-null; owner null. Use check constraints and partial unique indexes.
- Team layer chart belongs to the same song as the performance item, regardless of which chart the member prefers.
- Unique team layer `(performance_item_id, chart_version_id, page_index)`; unique personal layer `(owner_user_id, chart_version_id, page_index)`.
- Immutable originals/versions/calls/revisions cannot be directly updated or deleted by client roles. Archive references rather than remove historical material.
- Deletion or changed defaults cannot invalidate an already committed call or published version. Retention/legal deletion goes through reviewed server workflows.

## 3. Authentication and API surface
Use managed Supabase Auth for OTP and anonymous identities [S03,S08]. Member signup does not itself grant a church membership. Anonymous authenticated users are NOT regular members. App obtains only access scoped by `memberships`/`guest_grants`.

Normal authorized reads may use the Swift SDK with RLS. Mutations requiring multiple writes or invariants are RPCs. Do not build both REST and GraphQL layers. The required RPCs are listed in `contracts/rpc-contracts.json`; exact PostgREST function signatures must match these payload semantics and get integration tests.

| RPC/action | Semantics |
|---|---|
| create_church_and_default_team | Authenticated non-guest owner; create church/team/admin membership atomically, rate-limited |
| redeem_invitation | Bounded Edge Function; validate hash/expiry/use count/rate limit, authenticate actor, grant only allowed scope atomically |
| finalize_asset | Server verifies uploaded asset ownership/hash/size/type; immutable verified asset receipt |
| publish_chart_version | Validate asset and PDF manifest; serialize song version counter; make immutable version; return receipt |
| save_setlist | Compare `base_revision`; validate item foreign keys; never publish a live call |
| acquire_editor | Authorized leader/admin requests lease with expected epoch; explicit takeover when occupied; increasing epoch |
| renew_editor | Same user + device + epoch, currently valid; update expiry |
| release_editor | Same controller epoch; end own lease, no takeover |
| start_session | Setlist editor + epoch; enforce one active session; no initial auto-navigation |
| publish_call | Transactional protocol below |
| get_session_snapshot | Authorized session read; consistent latest call, status, controller epoch, relevant heads |
| acknowledge_open | Actor-owned participant; exact call + chosen version + render time; never rewinds latest call |
| save_annotation_revision | Verified native/preview assets, exact layer identity and parent revision; CAS with idempotency |
| get_annotation_head | Authorized exact layer, current revision metadata; native asset access still protected |
| end_session | Active controller/admin with audited action; current member chart remains visible |
| export_account / delete_account | Authenticated lifecycle functions with confirmation, retained organizational content handling |

No client mutation may set the server's current sequence, “verified asset” flag, arbitrary other user ID, admin role, or chart's tenant. Authentication errors must not discard local notes.

## 4. `publish_call` atomic algorithm
Inputs: session_id, command_id (UUID), expected_controller_epoch, expected_latest_sequence, performance_item_id, song_id, team_chart_version_id, performance_key; optional `ad_hoc_draft` for a not-yet-persisted, controller-prepared occurrence. Its proposed UUID is validated/created inside this same transaction, never assumed to refer to an existing item.

1. Authenticate actor; verify active membership/role and setlist access. Lock the session row (and editor lease in a fixed lock order shared by other writers).
2. If the same command_id was already committed, compare the immutable payload digest. Identical payload returns the original call receipt plus the current latest head; a different payload returns IDEMPOTENCY_CONFLICT. A replay never rewinds the session head.
3. For a new command, verify active session, unexpired lease, matching controller user/device/epoch, and `expected_latest_sequence`. Reject stale sequence; do not silently publish a potentially obsolete selection.
4. Validate chart/item/song/tenant/asset and nonempty performance key; unknown written key is allowed but not a falsely known performance key. Referenced PDF must be published/verified. Create an ad_hoc performance item atomically if this is a prepared off-setlist call, leaving planned order unchanged.
5. Increment sequence on the locked session, insert immutable call, update session latest pointer/state revision. Insert minimal audit event. Commit once.
6. Return receipt. Realtime metadata change wakes clients; their durable snapshot is truth.

On HTTP timeout, query command status or resend the SAME command_id/payload. Do not generate a fresh ID until user intentionally makes a new announcement. Retry previously committed commands safely even if a controller later lost the lease, provided authorization to read the receipt remains. New commands from a stale controller must fail.

Lease defaults: 60 seconds, renew every 15 seconds while foreground/connected. Both controller ID/device ID and epoch are checked. A matching user on another iPad does not get an implicit shared writer. Lease expiry does not auto-assign a new controller. Explicit reacquisition is needed. A delayed old network command is rejected.

## 5. `save_annotation_revision` algorithm
Capture exact layer key when editing begins. Save local native drawing and outbox entry in ONE transaction before claiming local saved. For cloud:
1. Upload immutable native archive and derived preview to owned staging keys; finalize each asset.
2. Server validates role and exact scope; team writes additionally require current setlist editor epoch.
3. Lock the annotation head. Check command dedupe, then compare parent revision.
4. If parent matches, insert immutable revision and advance head in one transaction. Return receipt.
5. If parent differs, return REVISION_CONFLICT with current head. Preserve local and server candidates; do not silently replace either. Personal conflicting content becomes a recoverable local branch. Team stale/offline drafts require explicit review by the active editor before a fresh commit.

A placeholder preview or missing asset must not become a head. Applying a remote revision is not a local edit. The client preserves local dirty strokes while a download is in flight and rechecks revision before installation.

## 6. Repeated songs and same-song key changes
Each performance item is a musical occurrence. Recalling the same item uses its existing shared notes; creating a new occurrence gives new team-note context. Personal notes remain attached to the chart across occurrences. Key changes publish a new immutable call with a new sequence. The key in a received but unacknowledged call belongs to the banner, not the user's current accepted chart header.

If the same chart is already displayed, accepting the call updates the acknowledged musical context but preserves page/zoom. A different-song call begins at page 1 only after explicit acceptance. Member page changes never affect any session row.

## 7. Error envelope
`{code, message_key, retryable, correlation_id, details}`. Details contain no sensitive content. SQL/RPC transport status mapping may differ, but semantic codes remain stable. See `contracts/error-codes.json`. Expected errors include STALE_CALL, STALE_CONTROLLER, REVISION_CONFLICT, FILE_NOT_READY, HASH_MISMATCH, ASSET_NOT_AUTHORIZED, SESSION_ENDED, ACCESS_REVOKED, AUTH_REQUIRED, RATE_LIMITED, INVALID_PAGE, INVALID_KEY, and IDEMPOTENCY_CONFLICT.

## 8. Security-definer functions
Prefer SECURITY INVOKER where feasible. Any SECURITY DEFINER RPC must use a fixed, safe search_path, schema-qualified objects, authenticated `auth.uid()` checks, no arbitrary SQL, explicit grants only to intended roles, and protection against cross-tenant foreign keys. Revoke default PUBLIC execute. Do not expose a generic bypass function. Never rely on a client-provided role or an editable profile claim. Test unauthorized requests directly against RPC and Storage, not just UI hidden buttons.
