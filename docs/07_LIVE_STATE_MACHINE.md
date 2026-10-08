# Live state machine: no involuntary navigation

## Independent state
1. **Latest announced call**: server-authoritative session/sequence/song/version/key, possibly unacknowledged.
2. **Displayed chart**: local song/version/page/zoom/performance-item context. Only deliberate local navigation changes it.
3. **Acknowledged call**: the exact call the musician explicitly opened/confirmed. Not necessarily the latest call.
4. **Prepared call**: controller-local selection, invisible to the team until committed.
5. **Preview**: temporary read-only team/version view; never changes preference, displayed chart underneath, or acknowledgement.
6. **Connection**: offline/connecting/connected/stale, with last successful authoritative sync time.

Do not implement a single `currentSong` that conflates these concepts.

## Core invariant
For any incoming notification, polling result, reconnect, new PDF upload, or downloaded asset completion, `displayedChart` must remain unchanged unless completing an explicit, still-valid user-open intent. The reference reducer/tests cover this at the domain level; the production UI must prove it too.

## Transition table
| Event | Required change | Forbidden change |
|---|---|---|
| Join active session | Subscribe, fetch latest snapshot, show pending call | Automatically open leader's chart |
| Receive newer call | Replace latest pending banner; append recent history bounded to 10 | Navigate, turn page, change preference |
| Receive older/duplicate call | Ignore older; dedupe identical | Regress latest pointer or stack prompts |
| Same sequence, different payload | Treat as protocol inconsistency and refetch/log metadata | Guess which version is true |
| Tap current banner | Create exact `OpenIntent(call_id, sequence, version_id)`; resolve/verify file | Accept whatever newer call exists under the same button without checking |
| New call during file load | Replace pending banner; invalidate obsolete open completion | Open the obsolete download automatically |
| Successful current open | Change displayed chart atomically; acknowledge after a frame is rendered | Report “opened” before render succeeds |
| Open failed | Keep existing chart and notes; show retry | Replace chart with blank/error page |
| Manual page turn | Update local page/bookmark only | Write shared session page state |
| Preview team markup | Present read-only exact team version; preserve underlying state | Set preferred version or acknowledge call |
| Offline | Keep files/notes; indicate stale latest call; disable publish | Queue controller calls for later automatic send |
| Reconnect/foreground | Fetch latest, update banner, retry personal-note outbox safely | Replay missed calls as navigation |
| End session | Mark session ended, stop live publication | Close currently displayed music |
| Key-only call | New pending acknowledgement with new performance key | Change PDF chords or accepted key label without tap |

## Latest-only behavior
Show the latest announced call as one persistent banner. A collapse action may reduce it to a persistent header chip, not erase the fact that current and announced states differ. History shows the last 10 calls, newest first, explicitly labeled as past announcements. No count of missed calls and no sequence of confirmations to “catch up.” This is chosen for the keyboardist-led workflow, not because every church uses identical conventions.

## Open flow and file fallback
1. Bind the tap to the displayed banner's call_id/sequence. On a connected client, reconcile if freshness is unknown; compare again before final display swap.
2. Resolve member's preferred version for this song. If none, choose the exact team version. Never silently choose another version merely because it downloaded faster.
3. If the preferred file is unavailable but another authorized chart exists, show choices: download preferred; explicitly open team chart once; cancel. Opening once does not change permanent preference.
4. Keep the current chart while downloading. Verify checksum and parseability. Produce a prepared document off the UI critical path without losing the old document.
5. Recheck call identity, user's navigation intent, and version identity. An intervening newer call OR manual navigation cancels old completion. The musician must tap again for the newer call.
6. Commit local display change. New different song → first page; same chart already open → preserve current page. Clear only the acknowledged banner, not a later arrival. Send `acknowledge_open` after successful rendering, not notification receipt.

If offline, the user may intentionally open a cached LAST RECEIVED call with a visible offline timestamp. It is not a claim of current server state. Persist the local acknowledgement, but after reconnect do not report it as the latest opened call unless IDs match. Historical acknowledgement must never advance server latest or imply current readiness.

## Key and version display
Current chart header: displayed song, displayed version, written key, and accepted performance key for that displayed musical occurrence (if any).
Pending banner: latest announced song, performance key, and optional team-version difference.
A song mismatch must never cause the new song's key to appear as the current chart's performance key. Unknown written key is “악보 키 미확인,” not silently treated as matching. Enharmonic equality can be normalized for warning logic but preserve the leader's written display spelling. No transposition occurs.

## Wrong announcement
There is no magical global undo after an announcement. To correct a mistake, controller explicitly sends the intended call as a NEW sequence. This updates pending banners but does not revert charts already opened. Keep the original immutable history. UI may offer a convenience “이전 곡 다시 안내,” which is still a new deliberate publication.

## Controller continuity
Controller lease survives network hiccups only until server expiry; no assumption that same device owns control forever. On lost lease, preserve prepared selection and team drafts but disable publication. Reacquiring control requires an explicit action and current epoch. A stale network retry that already committed returns its deduped receipt; a new stale command is rejected. No local clock overrides server lease.

## Participant status semantics
`received` means the client fetched the durable call. `opened` means that exact call's selected chart rendered. `last_seen` is an approximate heartbeat, not proof someone is looking. A different preferred version is informational. There is no automatic “all musicians ready” check and no reason to prevent a leader calling a song because one device is offline.

## App lifecycle
Expect iPadOS to suspend background execution; do not promise persistent socket delivery in background. Flush local note state on lifecycle transitions, restore the last chart on foreground, then reconcile network state without moving it. Old callback results carry scope IDs and intent tokens so they cannot update the newly opened session/chart.
