# Risk register
| Risk | Severity | Mitigation / first gate |
|---|---|---|
| PencilKit/PDF canvas lifecycle loses or misplaces notes | Critical | M0 native spike, stable captured identity, transaction-bound saved state, crop/rotation/reuse tests |
| Team markings appear on wrong version or occurrence | Critical | Exact composite identity, no cross-version projection; T19–20 |
| Incoming call unexpectedly navigates | Critical | Pure reducer + UI invariant tests; race-safe open intent; no auto-follow setting |
| False local-save or offline-ready status | Critical | Commit/verification-based UI, crash/disk/hash tests |
| Private note/cross-church exposure | Critical | Private storage, RLS/RPC adversarial tests, no content in realtime channels |
| Lost network notification leaves stale song unnoticed | High | Durable current state, reconnect/foreground/gap/periodic reconciliation, freshness label |
| Two controllers publish inconsistent directions | High | Explicit single controller, server lease/epoch, transactional sequence, idempotent commands |
| Concurrent private edits overwrite one another | High | CAS conflict with both snapshots preserved, no timestamp last-write-wins |
| Member's chart key differs from live key | High | Separate labels, persistent mismatch indication, explicit matching-version choice |
| Different key or reflow makes copied notes misleading | High | Manual transfer preview/reposition, no automatic alignment claims |
| Controller on keys cannot operate search | High | Standby/favorites/recents, private preparation, one deliberate send; observe full rehearsal |
| Guest invite gives whole-church access | High | Explicit scoped grant, anonymous identity distinct from member, subscription/storage tests |
| Native archive locks future Android editing | Medium | Preserve original archive and derived geometry/preview, document later migration; no false portability promise |
| App Store payment classification differs from plan | High before paid release | Free TestFlight pilot, current policy review before billing implementation |
| Existing license does not cover uploaded chart use | High | Source/permission check, private authorized sharing, no scraping, rights-removal workflow |
| Free-tier quota/pause or bad Wi-Fi disrupts pilot | High | Verify current hosting availability/quotas, offline preflight, no presumed SLA, fallback export |
| Growing scope delays usable reader | High | Milestone gates; no AI/Android/administration/billing until pilot evidence |
| Real-device behavior differs from reference tests | Critical release gate | Physical iPad/Pencil qualification; report NOT VERIFIED until performed |
