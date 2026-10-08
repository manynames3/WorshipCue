# Architecture and technical decisions

## A. Chosen topology
```text
Native iPad application
  SwiftUI navigation / UIKit music-stand host
  PDFKit document rendering + PencilKit personal/team canvases
  Pure domain reducers + repositories
  SQLite (GRDB) + protected Application Support PDF files
  Local personal-note outbox + verified download manifests
       |
       | managed authentication / authorized reads / transactional RPCs
       v
Supabase
  Auth: email OTP; scoped guest identity
  Postgres: tenants, versions, setlists, calls, annotation revision heads
  Private Storage: immutable PDFs, drawings, preview assets
  Realtime Postgres Changes: invalidation hints on small metadata rows
  Edge Functions: invitation redemption, bounded asset validation, account lifecycle
```

This is an engineering choice, not a previously deployed stack. The original Cloudflare proposal is superseded. The current behavior is tap-to-open, with no shared page cursor, so we do not need a bespoke real-time orchestration tier or several distributed stores. Supabase consolidates identity, relational transactions, file access policy, and event delivery. Its official Swift client and RLS/Storage facilities are documented in [S03–S06]. A managed service does not make our authorization or offline logic correct automatically.

## B. Native iPad choice
Use SwiftUI for navigation, sheets, metadata, and accessible controls; use a tightly scoped UIKit wrapper for PDFKit/PencilKit lifecycles. PDF page overlays and PencilKit integration are supported mechanisms documented by Apple [S01–S02], not a guarantee that our canvas selection, rotation, persistence, or gesture handling will work without testing.

Minimum deployment target: iPadOS 16.0 under the user-authorized D39 amendment for older iPads, including the connected device on 16.7.16. Pin a stable Xcode and Swift toolchain qualified for both the build host and oldest connected device; record exact versions. A compiler's supported deployment targets do not establish its debugger/XCTest device support. Inventory the team's oldest iPad before freezing hardware qualification. Do not require the newest OS or beta-only frameworks merely because the build machine supports them. Test the oldest supported runtime and the actual newest runtime used by the pilot team.

No React Native, Flutter, PWA, or Android music stand in the pilot. A future Android client can share the API/domain model, but PencilKit archives are not Android-editable. Preserve native archives plus documented geometry and derived transparent PNG previews. That offers a future viewing path, NOT a promise of lossless cross-platform editing. See annotation format below.

## C. Module boundaries
| Module | Responsibility | Must not do |
|---|---|---|
| Domain | Live reducer, version selection, key mismatch, identities, event validation | Import UI/framework/server SDK types |
| MusicStand | PDF lifecycle, visible pages, PencilKit adapter, local selection/preview | Infer remote state from scroll position |
| Library | Import, metadata, aliases, setlists, immutable version selection | Auto-merge by title or rewrite original PDFs |
| LocalStore | GRDB transactions, local heads, durable outbox, manifests | Lose dirty notes on logout or conflict |
| Sync | Snapshot reconciliation, retries, auth refresh, CAS resolution | Queue offline live calls or overwrite local dirty ink |
| BackendAdapter | Authenticated RPC, Storage, subscriptions | Expose service-role key or turn events directly into navigation |
| AppShell | Korean UX, roles, navigation, lifecycle | Treat network availability as proof of fresh server state |

One actor owns each local store. Stable `(owner, scope, version, page)` keys travel with immutable save requests. Never let an asynchronous page-save callback read “currently selected chart” to decide where to write.

Use GRDB migrations with WAL and foreign keys, one database writer, bounded readers, and serialized writes. Prefer a small DatabaseQueue initially; move to DatabasePool only after measured contention, not speculative optimization. GRDB is a third-party dependency; pin and review its license/version [S10].

## D. Rendering and handwriting spike
Start with PDFKit's documented page-overlay provider. Keep at most the visible pages plus a small neighbor cache alive; do not allocate a live drawing canvas for every page of a large packet. Reset recycled views fully and map page identity explicitly. Preserve drawing state before eviction. Audit whether replacing a SwiftUI view recreates the document/overlay and loses edits.

PDFKit coordinate conversions, page rotation, CropBox offsets, zoom, and screen resize require round-trip fixture tests. Do not assume normalized x/y alone fixes all alignment. Keep personal and team canvases independent; member interaction hits only personal ink. A team snapshot being applied must not recursively trigger a new outbound team write.

If the documented overlay approach fails reproducible physical-device correctness tests, isolate an alternative native CGPDF page renderer behind the same adapter. Document evidence and keep the rest of the product unchanged. Do not adopt a large third-party PDF SDK or silently raise OS requirements as a workaround.

## E. Realtime and durable state
Subscribe to small `live_sessions` head changes and authorized `annotation_heads` metadata changes, not raw drawing payloads. On notification, query the corresponding current durable snapshot. Do not broadcast private ink to a team channel, even encrypted or hidden by client code.

Realtime delivery is not an offline replay mechanism; Supabase documents that Postgres Changes does not guarantee replay after a disconnect [S07]. Therefore:
- Fetch on join, foreground resume, reconnect, and any sequence gap.
- Subscribe first, then fetch, and fetch again if an event raced with the initial read.
- While foreground LIVE, reconcile a small snapshot every 15 seconds as a recovery backstop, with jitter. Tune only after testing; this is not a hard latency guarantee.
- Treat out-of-order or duplicate heads as hints and use monotonically increasing server sequences/revisions.
- Files/notes are always fetched via authenticated access and validated before replacing a local head.
- Persist calls before acknowledging publication. “Send accepted” cannot depend on an in-memory WebSocket handler.

Use Realtime Postgres Changes in the first pilot, not a preview/alpha replay feature. If scaling later requires broadcast, keep durable heads and reconciliation unchanged.

## F. Local and server authorities
Server authority: tenant membership, published chart metadata, setlist identity, active controller epoch, accepted calls, committed team-note heads.
Local authority: musician navigation, personal version preference until synchronized, current page/zoom, local committed personal strokes not yet uploaded.
Shared objects use explicit revisions. No timestamp-based last-write-wins for ink. A client clock must never decide which musical direction is latest.

## G. File operations
Import/parse locally first in a background task with bounded work and cancellation. Copy from security-scoped URLs into application storage. Do not rely on a temporary Files provider URL remaining valid. Do not OCR the packet in v1.

Upload to immutable per-tenant/per-owner staging keys. An asset-finalization endpoint validates ownership, size/hash and existence before it may be referenced by a published chart or drawing revision. Database publication is a separate transaction. Crashed imports stay resumable drafts; orphan staging objects are cleaned after a conservative delay and only when unreferenced.

Initial qualification limits: 100 MB / 200 pages per source packet; 20 pages per song chart; 2 MB per native drawing page snapshot. These are adjustable pilot guardrails, not assertions of platform limits. Reject clearly and preserve data rather than truncate. Large/high-resolution scans belong in the performance corpus. Do not turn a correctness limit into silent data loss.

## H. Development configuration
Create `apps/ipad`, `packages/domain` or adopt the existing module layout; place server migrations/functions under `supabase`. The included `reference/WorshipCueCore` is a portable reference; reuse or migrate it deliberately to the production domain module and keep a single owner for each rule.

Keep `.xcconfig.example` with only placeholder Supabase URL/publishable key. The real local config is ignored. Server secrets remain in a secrets manager or development environment. Supabase publishable/anon keys are not authorization: every table/bucket/RPC still needs RLS and grants.

Use separate local/dev/staging/production environments. No production migrations during initial building. Pin native SDKs and Supabase CLI after verifying current official interfaces. No hard-coded claimed current library version in this document.

## I. Observability
Record errors by category and opaque correlation IDs: import failure, checksum failure, stale call rejection, outbox conflict, lease loss, auth failure, cache recovery, and rendering crash. Do not log raw URLs/tokens, emails, PDF titles/content, pen strokes, or religious profile attributes. Show an optional exportable diagnostic report with explicit review and no uploaded charts. Counts and timings are enough for first-pilot reliability.
