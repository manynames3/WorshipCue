# Security, privacy, invitations, and rights

## Threat model
Protect against cross-church reads/writes, guessing object paths, guest privilege escalation, leaked invitation tokens, a stale controller sending calls, another user's personal-note disclosure, malformed documents, unsafe export, credential logging, and data loss masquerading as synchronization.

App UI hiding a button is not authorization. RLS and RPC checks must be tested directly. Supabase anonymous users use authenticated identity semantics; never give every authenticated identity all member permissions [S08].

## Access policy
- Members: only active memberships grant team/library access, as defined for their church/team.
- Leaders: manage authorized setlists/versions; actual live/team editing also needs a valid editor lease/epoch.
- Admins: organizational content and membership administration, not other people's personal-note content.
- Guests: only the granted setlist, its planned/standby charts, and later ad_hoc charts explicitly announced in that session. No whole-church browsing.
- Personal drawing rows/assets: owner only. Service operators may technically hold privileged infrastructure access; no end-to-end-encryption claim is made. Product roles must not expose private ink.
- All client-direct writes to immutable published tables are denied; allowed transactions go through narrowly scoped verified RPCs.

Use private Storage buckets [S05]. Paths are identifiers, not access grants. Authorize every download. Prefer authenticated downloads; if signed URLs are required, use short TTL, no logging, and disclose that a leaked link remains usable until expiry. Never embed service-role credentials in a client or fixture.

## Invitations and guest onboarding
Create a scoped, high-entropy invitation token; store its cryptographic hash. Prefer individual-use invites or explicitly bounded service invites, expire after a configured short period, and allow revocation. A 128-bit-or-stronger token in a link/QR is appropriate; do not use an unthrottled four/six-digit code as a bearer credential.

Native app can accept the link via universal link or scan QR from an explicit action. If universal-link domain configuration is unavailable, use an in-app invitation-code flow with a sufficiently long random code, expiry, and rate limiting. Do not guess a deployable domain. Installation is required in this pilot; the invitation landing screen must say so. Do not invent an account-free browser reader.

Use managed anonymous Auth for guest identity, then redeem invitation server-side. A guest with a display name is not a verified member. Store guest private notes locally only for the pilot and explain lack of account recovery. Before live distribution, verify auth-provider quotas, CAPTCHA/abuse controls, native email OTP delivery, and invitation error recovery. A failed invite must not reveal whether an unrelated church/setlist exists.

## RLS and function tests
Test unauthenticated, anonymous-without-grant, valid guest, expired guest, member A, member B, leader, admin, revoked member, stale controller, and service operator in isolated fixtures. Verify rows, storage objects, RPCs, and realtime subscriptions. A guest should not receive private-note payloads even if it guesses a subscription filter. Avoid large/sensitive realtime payloads entirely.

SECURITY DEFINER is not a shortcut around RLS. Fix search_path, authenticate auth.uid(), validate every linked tenant, revoke PUBLIC execution, grant minimally, and test ownerless/service-role code paths. Membership role is maintained by privileged server actions, not mutable user profile metadata. Do not introduce SQL injection through sort or search input.

## Document handling
Only accept PDF/native-drawing/PNG types required by the app with size limits and content validation. Keep PDF external links inert during performance unless user explicitly opens them. Do not execute embedded JavaScript or launch attachments. Treat filenames and titles as untrusted text. Import copies outside the source provider, preserves original bytes, and never runs shell commands derived from file metadata.

A server may not fully parse PencilKit archives; validate bounded size/ownership/hash and test native decode safely. Server “asset verified” means defined validation passed, not a malware-free or semantically correct guarantee. Malformed PDF tests must be run on actual renderer without automatically exposing arbitrary attachments to other users.

## Privacy and telemetry
Minimize collected data to account identity, display name, optional instrument, membership, and operational state needed to share charts. No microphone, voice recognition, geolocation, contact harvesting, religious profiling, advertising IDs, or content training. Camera only when user explicitly chooses QR scan. Do not collect full copyrighted lyrics for search in v1.

Operational logs contain opaque IDs/timings/error categories, not user names, email addresses, church names, song titles/lyrics, handwriting, tokenized URLs, or PDFs. Publish a privacy policy, data retention policy, support channel, account-deletion flow, and an explicit description of any crash-reporting vendor before wider release.

## Copyright and content rights
A private church library is NOT automatically lawful. CCLI's published license descriptions distinguish covered uses and applicable terms; their US and Korean summaries are reference points, not blanket permission for every uploaded PDF [S11–S12]. Territory, repertoire, typesetting/publisher rights, and reproduction/storage/sharing permissions must be checked by the church with the licensor or qualified adviser where needed.

Require uploaders to confirm permission for the intended team use and preserve source/rights notes in metadata. Do not scrape SongSelect, share licensed charts across churches, bundle copyrighted commercial scores, remove copyright notices, or imply the app subscription includes a music license. No unauthorized public song database. Provide a rights complaint/removal process. Synthetic fixture charts contain no commercial lyrics or scores.

## App Store and money
First pilot is free via TestFlight; billing is intentionally disabled. Church-paid with free member/guest participation is a product model, not an App Store exemption. Apple's current rules distinguish organizational and other purchase contexts, and their application to a church/volunteer subscription needs review [S13]. Do not add external checkout links or assume “enterprise” approval. Resolve billing mechanism, account deletion, privacy labels, content reporting/removal controls, support info, and review demo access before a public submission. Recheck current official policy then; this document cannot guarantee approval.

## Destructive operations
User-owned personal notes must be exportable or warned about before account/data removal. Organizational chart retention versus an individual's account deletion is a documented policy decision, not an implicit `CASCADE` across all church assets. Do not promise remote deletion of downloaded copies while offline. Legal removal and compromised credentials require a reviewed incident path, not silent emergency data deletion from an active music stand.
