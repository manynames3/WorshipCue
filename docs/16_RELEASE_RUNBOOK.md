# Release, incident, and recovery runbook

## Before staging
Run fresh migrations in isolated local Supabase; verify foreign keys, unique constraints, RLS, RPC grants, private storage, auth/grant lifecycle, idempotency, and malicious cross-tenant inputs. Re-run the handoff domain tests after adapting production code. Confirm no service keys or real church documents in source history/test reports. Record pinned dependencies/toolchain and supported schema versions.

## Before TestFlight
Build on macOS with a stable supported Xcode, actual bundle identifier and authorized signing. Use a unique version/build number. Provide tester access, support instructions, synthetic demo set, data/permission explanation, known limitations, and no paid feature gating. Test invitation installation/link flow, email OTP, app relaunch offline, and correct user partitioning on shared devices. Check current Apple requirements [S13]. Do not claim App Store approval in advance.

## Before each rehearsal/service
Leader verifies correct setlist, team chart versions, performance keys, and standby collection. Each device checks exact-version downloads, battery/power, Pencil operation, local saved notes, and current session connection. Do not equate another device's preparation success with this device's. Keep an export/print fallback. No app/backend upgrades immediately before service except a deliberate emergency decision.

## Safe deployment
Use separate dev/staging/production data. Prefer additive schema changes compatible with old clients; deploy server additions before client reliance. Do not remove a field used by the prior active TestFlight build. Schedule outside the team's service window. Keep migration backups and record rollback instructions. An app binary rollback may require an available prior build; do not assume it can instantly be pushed to every iPad.

## Incident severity
P0: lost saved notes; wrong chart context; involuntary navigation; unauthorized access; corrupt “ready” file; false call publication. Stop expanding deployment. Preserve relevant diagnostics without content, switch team to fallback if necessary, and fix with a regression test. Security incidents also require credential/access review and an appropriate notification process.

P1: delayed sync, repeated import failure, excessive battery/memory, invitation issues. Preserve readability, surface honest state, investigate with a reproducible fixture. A P1 becomes P0 if it causes data loss or unsafe state.

## Backup and restore
Back up database metadata and asset inventory/bytes according to the chosen managed plan and recovery requirements; verify what the provider actually includes. A DB restore that points to missing PDF/ink objects is not a successful restore. In staging, restore to a clean environment and prove a chart with both private and team ink opens at the right version/geometry with access rules intact. Document recovery time observed and recovery point available; do not invent an SLA.

Local recovery: verify SQLite migration/backups, last good drawing snapshots, file hashes, and manifest repair. Never delete corrupt/dirty material before a safe copy is retained for recovery. Do not export private chart/ink contents into a general bug log.

## Authentication or subscription problems during worship
Existing cached content stays readable for the legitimate user unless an explicit verified access-revocation/legal-removal policy applies. Token refresh failure alone is not proof access is revoked. No mid-service paywall. Unsent calls cannot be published offline; tell the keyboardist to use the established verbal cue/fallback process.

## User exit and data deletion
Offer authorized PDF/annotation export. Explicitly distinguish personal notes, church-owned files, and guest temporary data. A user deletion action cannot arbitrarily remove charts belonging to the church. Logouts with dirty notes need a save/export warning. Handle legal deletion via a documented server workflow and acknowledge offline-copy limitations.

## Release sign-off checklist
All P0 tests passed at relevant native/backend/device level; minimum hardware qualified; two-hour soak recorded; two rehearsals completed; no known data-safety blocker; rollback and asset restore tested; permissions/rights checks completed; user copy reviewed in Korean; pilot owner named; support channel available. Otherwise mark release BLOCKED with the exact missing gate.
