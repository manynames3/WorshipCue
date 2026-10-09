# Personal data, backup and account lifecycle

Build 8 implements a file-inclusive selected-team personal cloud ZIP and account preflight. It does **not** implement account deletion or claim complete erasure. These are technical product facts, not a promise that an unfinished release meets every distribution requirement.

## What a musician can export now

The account panel offers an explicit export for the currently selected, accessible team. A protected ZIP includes a schema-2 JSON manifest of the musician’s membership/profile, preferences, personal annotation layers/heads/revisions, verified own native/preview files, own current chat messages, room preferences and block settings. It also includes currently authorized immutable source PDFs needed to interpret the exported personal annotations. Other authors’ personal records, team ink, unrelated shared PDFs, other teams, sign-in credentials, invitation secrets and archived command receipts are excluded. A deleted message remains a tombstone; an old receipt cannot recover its previous text.

This is a **selected-team cloud bundle**, not a complete account or device backup. Local unsynced notes, local drafts and standalone device charts are excluded and clearly disclosed. Use the existing chart PDF export for a readable copy containing selected local layers. ZIP creation verifies every file’s size and SHA-256 receipt, validates source chart/page geometry, writes one file at a time off the main actor, and publishes the completed archive atomically. Failure, cancellation or a changed account/team removes the partial job; closing the export sheet removes its temporary archive after explicit sharing/saving. There is no automatic restore/import.

The ZIP is bounded to 1 GiB total, 100 MiB per PDF and 2 MiB per native/preview asset, with at most 65,535 unique safe relative entry names. Large-archive memory, storage pressure and background interruption still require device qualification.

The backend verifies the exact active team membership on every page. Owner-bound opaque cursors expire after one hour and bind to that membership; a catalog cursor cannot be reused for account export. Pages contain at most 100 records and 512 KiB. The native assembler allows at most 1,000 pages, 50,000 rows and 64 MiB of response data. Head/revision references must match the exported personal layer and verified asset type, hash, byte count and key before the file is written.

Preflight lists accessible teams and identifies a sole administrator who needs to hand off the team. It discloses the count of unavailable memberships; revoked teams’ cloud records are excluded. Guest identities cannot use this account export, and guest logout warns that the identity/invitation may not be recoverable. Local PDF export should precede guest logout when a musician needs their markings.

## Backup behavior and present limits

The development backup uses a private versioned S3 checkpoint with a conditional lease. It starts at most one daily job after 04:00 UTC and resumes through the existing five-minute schedule. Each invocation verifies/copies up to 100 current source objects; an invocation approaching its time limit preserves only verified progress. One DynamoDB backup intent/name is retained across runs, including a pending provider backup. A lost creation response is reconciled by exact table/name rather than blindly creating another backup.

A schema-1 complete manifest is published only after its version-pinned copies and database backup verify. A completion metric follows that verified manifest; scoped operator alerts cover Lambda failures and no verified completion in the expected 48-hour window. Mail routing has four separate failure alarms on the same confirmed operator topic. An operator must inspect the exact saved job/manifest before intervening in an uncertain outcome.

Limits remain explicit: 100 MiB per source object and 8 MiB per checkpoint/manifest, plus the restore checker’s 50,000-row scan bound. More than 1,000 file entries can now be backed up/restored within that byte bound. This is not an atomic database-and-files snapshot; concurrent uploads/publication require restore-reference validation. Source files, versioned copies and database backups are retained. No aged-backup, orphan-file or revision deletion was enabled.

## Required deletion design before release

A complete deletion implementation needs a durable, resumable operation, rather than a single optimistic request:

1. Preflight and offer an export; require sole administrators to hand off organizational ownership.
2. Record the exact owner and request, mark the account closing, revoke sessions and prevent new owner writes. A timeout must resume the same operation.
3. Enumerate and remove only proven owner-personal records and owner-exclusive assets. Preserve published charts, shared setlists and team ink; tombstone own chat/profile where needed to preserve the team’s history.
4. Revoke remaining exact memberships/grants and delete the managed identity only after owned cleanup is qualified. Retain a minimal independent deletion ledger without chart, handwriting, chat or email contents.
5. Apply that ledger during every restore before restored data is made available; a prior backup must not resurrect a deleted account or its personal data.
6. Implement, test and obtain the user’s approval for a concrete backup-retention policy before enabling irreversible aged-backup cleanup. A proposed policy must cover database snapshots, every S3 source/copy version, job checkpoints and exported operational recovery records together.

No retention duration is silently selected here. Until the ledger, cleanup worker and approved retention are implemented and tested, the product must continue to disclose that deletion is unsupported and must not claim backup erasure.

See [Build 8 qualification](../verification/BUILD8.md), [Build 7 qualification](../verification/CHAT7.md) for actual results and [SES operations](SES_PRODUCTION_READINESS.md) for email review and operator recovery.
