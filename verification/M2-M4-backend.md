# M2–M4 private-team backend evidence

Date: 2026-10-08. Scope: local PostgreSQL implementation and bounded Edge security/content-validation handlers. This evidence is **not a hosted Supabase deployment, production account system, or pilot sign-off**.

## Implemented and exercised

- Atomic church/default-team/admin creation using managed identities; member/leader invitations; anonymous setlist-only guest grants. Client claims do not assign membership roles.
- RLS-scoped tables and private Storage object policies. Whole-library membership access, exact guest chart scope, cross-tenant denial, and owner-only personal annotation assets. Product leaders/admins cannot read other owners' private ink.
- Immutable staging/verified asset receipts, published chart versions, per-song serialized numbering, setlist compare-and-swap and occurrence identity. Missing/null base revision is rejected rather than bypassing CAS.
- Exact personal and occurrence/version/page team annotation revisions, verified native/preview references, canonical geometry equality, numeric parent CAS, immutable history and payload-sensitive command dedupe. No automatic merge or transfer.
- One server-clock/device/actor/epoch-fenced editor per setlist; explicit takeover, expiry, increasing epochs and idempotent committed receipts.
- Durable live sessions, transactional sequence checks, atomic extra-song occurrence publication, bounded latest/history snapshots, exact historical chart-open acknowledgement and explicit end. No page/navigation/audio/haptic/readiness protocol fields.
- Preflight `charts` plus full authorized existing team `annotation_heads` receipts for exact assigned/called occurrences and versions; private and unrelated notes are excluded. Fifty concurrent readers leave session, revision and participant state unchanged.
- Edge managed-user validation, ownership/actual hash/length verification, bounded body/response streams, complete RGBA PNG validation, token hashing and separately committed invitation-attempt throttling. No token/content/credential logging.

## Exact completed checks

| Check | Result |
|---|---|
| `python3 scripts/test_backend.py` | **Exit 0; 13 integration groups passed**, PostgreSQL 17.10 (Homebrew) |
| `deno test --config supabase/deno.json supabase/tests/edge_test.ts` | **Exit 0; 7 passed, 0 failed**, Deno 2.7.13 |
| `deno lint --config supabase/deno.json supabase/functions supabase/tests` | **Exit 0**, five TypeScript files at this checkpoint |
| `deno fmt --check --config supabase/deno.json supabase/functions supabase/tests` | **Exit 0**, five TypeScript files at this checkpoint |
| `deno check supabase/functions/redeem-invitation/index.ts` | **Exit 0** |
| `python3 -m py_compile scripts/test_backend.py` | **Exit 0** |

Final SQL report at this checkpoint: external `DeveloperTools/WorshipCue/BackendTests/backend-uv6kx26a/results.json`. Every test run creates a fresh unique cluster/database on a random localhost port, applies each additive migration transactionally, and stops only its own cluster. No existing user database is reset. Initial failures were temporary-directory/socket configuration and ambiguous PL/pgSQL names; those were repaired and the complete suite rerun. An independent review identified SQL-null CAS acceptance, which was fixed and covered with missing/null/negative revision tests. A wrong CRC in the generated PNG test fixture was corrected; strict production validation was retained.

The 13 PostgreSQL groups cover:

1. Authentication/no-identity denial; anonymous-without-grant denial; active/revoked membership; direct role escalation denied.
2. Service-only finalization; missing/wrong actor denial; hash/size receipts; immutable storage; cross-tenant object denial.
3. Exact validated geometry; malformed manifest rejection; concurrent numbered publication; command dedupe/conflict; immutable chart/history.
4. Setlist CAS/idempotency; missing/null/negative base revision rejection; exact song/version occurrence; failed batch rollback.
5. Hashed one-use invitations; bounded scope; redemption dedupe; denied exhaustion; guest cloud-write denial; durable failed-attempt rate cap.
6. Device-fenced leases; missing/null controller/device/sequence denial; immutable call sequences; timeout retry returning current latest head; stale call rejection.
7. Exact owner/version/page personal CAS; missing/null parent/geometry/owner rejection; conflict retains current head; leader/admin drawing-row/asset/storage denial.
8. Team exact context; member write denial; guest read-only; explicit takeover; old/new command fencing; safe deduped receipts after losing editor role.
9. Concurrent same-sequence publication accepts exactly one command; atomic ad-hoc occurrence; unchanged planned order; historical acknowledgement does not advance latest.
10. Fifty independent authenticated readers agree on the durable snapshot without controller access. These are database sessions, **not Realtime/network latency tests**.
11. Full preflight team heads include exact assigned and called ad-hoc contexts; exclude private, different-setlist occurrence and unassigned alternate-version heads; preferred-version chart remains available; guest authorization is enforced; fifty readers mutate no session, revision or participant state.
12. Ten-call history cap; expired lease checked after a delayed transaction; increasing reacquisition epoch; ended session rejects new call; guest revocation denies tables/storage/snapshots/preflight.
13. Every security-definer function has a fixed empty search path.

The database uses a small test-only Supabase Auth/JWT and Storage-schema shim. Assertions execute real PostgreSQL SQL/RLS using **non-owner `authenticated` roles**, then exercise narrowly granted `service_role` paths. The shim does not implement authentication. Synthetic SQL validation metadata is a trusted-server boundary fixture; it does not prove real PDF bytes were parsed. Synthetic native fixtures are bounded opaque bytes; they do not prove PencilKit decoding.

The seven Deno tests exercise real handlers and built-in SHA-256/decompression with injected HTTP responses: bounded streams, managed-user verification, hashed invitation/actor propagation, failed-token throttling, downloaded byte/hash/owner checks, full PNG CRC/decoded extent/truncation rejection, and error privacy. Those injected responses are **not real GoTrue or Storage HTTP tests**.

## Outstanding checks and deployment gates

- PDF parser dependency approval and actual PDF finalizer entry/real-PDF content tests were pending at the checkpoint above. Do not call the file workflow end-to-end verified until that entry is complete and its synthetic actual PDF tests pass.
- No Docker daemon/Supabase CLI runtime was available. Managed OTP/anonymous sign-in, native email delivery, CAPTCHA/abuse controls, provider quotas, actual PostgREST/Storage HTTP and Realtime subscription authorization/delivery are **NOT VERIFIED**.
- No project URLs/keys are configured or committed. No cloud account, billing, schema, function, service, or production data was changed. Native remote-account workflows need an explicitly configured approved development Supabase project or actual local Supabase stack.
- Fifty-client message loss/duplicates/delays/timeouts, network recovery, backup/restore of metadata **and files**, two-hour soak and 3–10 physical iPads remain **NOT VERIFIED**.
- Account export/deletion and content-rights removal require a reviewed managed-Auth/organizational-retention workflow before wider distribution. No destructive account endpoint is exposed. No billed pilot or paid Apple Developer enrollment is performed here.
- Guest grant expiry/revocation stops online access; it cannot guarantee remote erasure of already downloaded offline copies. Native private-note logout isolation and account recovery require device qualification.
- The native client must preserve the currently displayed chart for every snapshot/invalidation/download/end event, explicitly tap/revalidate/render before acknowledgement, never queue unsent live calls or auto-publish offline team drafts, and retain personal conflict candidates. Backend tests cannot replace those UI/device gates.

Supabase documentation checked for [anonymous identity semantics](https://supabase.com/docs/guides/auth/auth-anonymous), [private Storage RLS and upsert permissions](https://supabase.com/docs/guides/storage/security/access-control), and [database RLS](https://supabase.com/docs/guides/database/postgres/row-level-security). The actual SQL/API shapes and local commands are in [supabase/README.md](../supabase/README.md).
