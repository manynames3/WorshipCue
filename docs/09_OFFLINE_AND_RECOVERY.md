# Offline-first behavior and recovery

## Offline guarantee, precisely
An authorized user on a previously prepared device can open verified downloaded PDFs, manually navigate, and durably save personal notes without internet. A chart that was never downloaded cannot be fetched offline. The last received live call is stale information and must be labeled as such. No device-to-device/LAN synchronization is promised.

The current chart is not a disposable cache. Store pinned PDFs under protected Application Support, not a purgeable temporary cache directory. Maintain content hashes and a manifest. Image thumbnails may be evicted; original pinned PDFs and dirty notes may not.

## Preflight download manifest
Manifest identifies exact setlist revision, standby item IDs, team chart versions, each user's preferred versions, PDF hashes/bytes, and known annotation heads. Download BOTH team and preferred charts where they differ; this makes team-mark preview usable offline as of its last saved revision.

State: not_started → downloading → verifying → ready, or failed. “Ready” requires complete byte length/hash, successful parse, atomic file promotion, and committed DB cache metadata. An HTTP 200 response alone is insufficient. Mark stale-but-usable team ink separately from missing PDF data. Never silently include a failed item in the green total.

## Atomic files and notes
PDF: stream to a temporary file on the same volume; verify; atomically rename to a content-addressed final path; commit SQLite metadata. On crash between rename and DB commit, reconcile verified orphan finals; on crash before rename, resume/discard partial temp safely. Do not replace a verified file with incomplete bytes.

Ink: commit native BLOB + generation + pending outbox mutation in the SAME local SQLite transaction. This avoids a cross-file/DB atomicity gap for private notes. SQLite WAL and migration state need clean tests. Keep at least the prior good local snapshot plus current dirty snapshot until safe retention cleanup. The application must not claim indefinite forensic recovery from disk corruption or device loss.

## Outbox rules
Allowed automatic retry: a member's private annotation revision, personal preference, non-destructive draft metadata where authorized.
Not allowed: publishing live calls, silently taking over controller lease, automatically publishing offline team-ink drafts, privileged role changes.

Retries are idempotent with durable command IDs, bounded exponential backoff and jitter. After transient authentication refresh failure, preserve local content and mark sync paused. For revision conflict, keep both copies and stop blind retry. For revoked access, stop server writes and handle local content per the disclosed policy; never mislabel authorization denial as a connection outage.

## Reconnect and lifecycle
On foreground/resume: restore last displayed chart and local notes first. Then authenticate if possible, subscribe, fetch authoritative session/latest heads, and reconcile. Do not navigate on that fetch. Retrying personal notes does not interrupt viewing. A teammate's new mark updates only a matching scope/version; it does not replace a dirty local personal canvas.

If the last opened call is no longer current, show the new latest banner. Do not replay older calls. Never resend a controller's unsent selection simply because Wi-Fi returned. Store a private preparation selection only; require an explicit send.

## Missing and damaged files
If a newly selected chart fails: keep existing chart; show retry or explicit available alternative. Re-download into a new temporary path before replacing corrupted data. If current file later fails verification, keep any already readable page/previous good local copy as a last resort while clearly flagging recovery state. Do not render corruption as an apparently authoritative chart.

Disk full: preserve existing data, stop adding new files, and show which downloads could not complete. Offer deletion only of unpinned, clean, unused cached originals with a clear size estimate. Do not automatically delete current session material or unsynced ink. Report import limits rather than truncate.

## Retention and privacy
No automatic deletion of annotated chart versions during the pilot. Unreferenced staging uploads may be cleaned by server jobs only after verifying no current/history reference. Archived versions remain readable to authorized members who depend on them.

Guest grants expire and online access is revoked promptly, but already downloaded material cannot be guaranteed to disappear from disconnected devices. Disclose this boundary; do not promise DRM or instant remote wipe. Enforce grant expiry/revocation on reconnect and best-effort local cleanup under disclosed policy. A logged-out app should not expose another member's private notes on a shared iPad. Partition local data by user/tenant and confirm unsynced-note handling before logout.

## App/backend upgrade
Migration is transactional and reversible where possible. Back up local DB before a destructive-format migration; prefer additive migrations. A minimum-supported-server response must not erase a readable local chart. No forced upgrade or paywall is inserted mid-service. Schedule deployments outside the team's declared service window; see runbook.

## Recovery goals for pilot qualification
- All strokes explicitly marked locally saved survive force termination/relaunch in test.
- Offline launch restores the last verified chart without contacting the server.
- A dropped notification is recovered by reconnect/foreground/poll reconciliation.
- Recovered server state never forces chart navigation.
- No false offline-ready indicator under partial download, corrupt hash, disk-full simulation, or expired access.
- Cloud backup/restore procedures must cover BOTH metadata and files; a database backup alone is not proof that PDF/ink assets can be recovered.
