# Test and acceptance plan

## Evidence levels
`SPEC TESTED` = reference/domain tests. `IMPLEMENTED` = production code exists. `INTEGRATION TESTED` = native/server path exercised. `DEVICE VERIFIED` = real iPad/Apple Pencil tested. Never use one label as a substitute for another. The package reference test results are not application validation.

## Release blockers (P0)
Any lost locally-confirmed note, wrong-version/context overlay, unsolicited song/page switch, cross-tenant/private-note leak, false successful publication, stale controller accepted, corrupted file marked offline-ready, or unrecoverable crash in core reading blocks the pilot release.

## Automated cases
| ID | Scenario | Pass condition |
|---|---|---|
| T01 | Receive new call while reading page 2 | Only latest banner changes; chart/version/page unchanged |
| T02 | Receive calls 2, 4, 3, 4 | Latest remains 4; no duplicate history; no navigation |
| T03 | Same sequence has conflicting payload | Protocol error/refetch; no guessed state |
| T04 | Banner changes between touch-down and action | Old intent rejected; new banner shown |
| T05 | New call arrives while accepted PDF downloads | Old completion cannot replace screen |
| T06 | Same song/key called again | New sequence needs explicit acknowledgement; current page preserved if same chart |
| T07 | Same song, new key | Pending key separate; no PDF edit; accept preserves current chart page |
| T08 | Team version differs from preferred | Preferred retained; version and key differences visible |
| T09 | Preferred file missing, team file cached | No silent fallback; explicit one-time alternative |
| T10 | User opens history or preview | Latest call not acknowledged; no preference change |
| T11 | Manual navigation cancels pending open | Delayed callback cannot jump back |
| T12 | Session ends | Current readable chart remains |
| T13 | Reconnect after multiple calls | Latest banner only; no queue replay/no navigation |
| T14 | Controller retry after timeout | Same command produces one call, not two |
| T15 | Old controller device sends after takeover | New command rejected by epoch |
| T16 | Two users attempt controller claim | One valid owner; explicit takeover semantics |
| T17 | Personal v1 note, then v2 upload | v1 note preserved; v2 is clean until manual copy |
| T18 | Copy selected notes v1→v3, move, undo | Source unchanged; destination group reversible |
| T19 | Team ink v3; viewer v1 | Preview indicator only; no v3 coordinates on v1 |
| T20 | Same version but different performance occurrence | Shared ink not leaked across occurrences |
| T21 | Personal eraser/undo with team visible | Team ink unaffected |
| T22 | Team incoming update while member writes | Personal canvas/undo history unchanged |
| T23 | Page view recycled during async save | Save lands on captured exact version/page |
| T24 | Two devices edit same private layer | Conflict preserved, not silent overwrite |
| T25 | Offline team edit after lease loss | Local draft only; no surprise publication |
| T26 | Force kill after local save acknowledgement | Saved strokes recover exactly |
| T27 | Force kill during file download | Partial file never counted ready |
| T28 | Hash mismatch / corrupt PDF | Existing chart retained; invalid file rejected |
| T29 | Disk full during note/download write | No false saved/ready; previous data preserved |
| T30 | Offline cold launch | Last downloaded chart opens without login round trip |
| T31 | Token refresh fails | Viewing continues; private data preserved; sync paused |
| T32 | Revoke member / expire guest | Online reads, writes, storage, subscriptions denied |
| T33 | Guess another church IDs or storage paths | RLS/RPC/storage reject every path |
| T34 | Admin attempts another person's private ink | Denied through DB, storage, export, realtime |
| T35 | Anonymous identity without grant | No church access despite authenticated role |
| T36 | Malformed cross-tenant FK RPC input | Rejected atomically; no partial rows |
| T37 | Korean whitespace/initials/NFD text/aliases | Deterministic expected results |
| T38 | Same title for different songs | No automatic merge |
| T39 | PDF import split with cover and repeated ranges | Correct pages; source preserved; duplicate confirmation |
| T40 | Interrupted upload/publish | Draft resumable; no broken finalized version |
| T41 | Copy last week's setlist | New occurrence IDs; no automatic team-ink carryover |
| T42 | Export personal/team layers | Only chosen authorized layers; no original mutation |
| T43 | Rotate/crop/zoom geometry | Canonical targets remain aligned, including nonzero CropBox |
| T44 | Repeated open/close/rotate PDF views | No stale drawing, crashes, or unbounded live canvases |
| T45 | Haptic/audio API audit | No announcement sound/haptic path |
| T46 | Page navigation protocol audit | No page/scroll command exists in live contract |
| T47 | Dependency/schema upgrade | Additive migration preserves offline notes/history |
| T48 | Missing/failed asset referenced by commit | Server rejects head/publication; previous good head retained |

## Physical-device matrix
At minimum: two real iPads with different screen sizes; oldest pilot hardware; newest OS used by pilot; compatible Pencil generations actually owned. Record models, OS, app build, stylus model, network, and fixture size. Inventory first; do not invent compatibility results.

Mandatory manual checks: palm contact, Pencil vs finger distinction, rapid undo/erase, copied-note movement, rotation while writing, zoom at 100/200/400%, portrait/landscape, app background/foreground, device lock/unlock, low battery, large scanned PDFs, memory pressure, and viewing on a stand while playing keys. Two simulators do not substitute for these.

## Network and concurrency test rig
Use 50 simulated authenticated clients plus 3–10 physical musicians in an actual rehearsal. Inject 5% message loss, duplicate/delayed events, 1–3 second latency, HTTP timeout after commit, 30-second and 5-minute outages, expired token, controller takeover, and out-of-order completion. Use a seeded simulation so failures reproduce. No public load tests against production without approval.

Measure separately: publication commit, client receipt/fetch, PDF already cached, document render, and musician acknowledgement. Do not count human reaction time as network latency or declare users “not ready” based on it.

## Qualification targets, not advertised guarantees
| Metric | Initial target and measurement |
|---|---|
| Cached chart first meaningful render | p95 <=750 ms on oldest pilot iPad for qualified standard fixture |
| Warm manual page change | p95 <=150 ms; measure without hidden downloads |
| Committed call → visible notification | p95 <=1.5 s on qualified healthy network, 50 clients |
| Shared saved ink → visible remote ink | p95 <=2 s after pen-up under qualified fixture/network |
| Personal local save boundary | p95 <=300 ms after pen-up; never falsely show saved |
| Session duration | 2-hour continuous rehearsal soak with no core crash/loss and bounded memory |
| Fault recovery | No unsolicited navigation, duplicate publication, or loss of saved ink across injected failures |

If a target fails, record actual results and fix/revise transparently. Do not weaken data-safety invariants. Establish real baseline performance before promising marketing numbers.

## Pilot sign-off
All P0 cases pass at their relevant integration/device level. Perform at least two full rehearsals before using live in service. Then four services with a readily accessible print/export fallback. Record critical incidents immediately and keep a known-good build. A successful demo or 100% reference test pass rate is not pilot sign-off.
