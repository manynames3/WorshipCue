# Decision register and superseded proposals
Date: 2026-10-07. `USER` means explicitly chosen in the conversation. `DEFAULT` means selected under the user's request to make remaining decisions. Defaults are implementation requirements unless evidence requires a documented revision; do not reopen optional questions.

| ID | Status | Decision |
|---|---|---|
| D01 | USER | Prioritize version/note trust and spontaneous-song coordination; weekly convenience supports both. |
| D02 | USER | Team is willing to do actual reading and note-taking inside the app, replacing its Goodnotes workflow. |
| D03 | USER | Select v1/v2/v3; retain old PDFs and personal notes; manually select/copy/paste/reposition notes. No automatic merge. |
| D04 | USER | Each musician retains a preferred chart version. The leader's version does not override it. |
| D05 | USER | Controller performs on keys; chooses songs or receives a cue before the worship leader begins. |
| D06 | USER | Show performance key, flag written-key differences, offer a matching chart when present; PDF key labels do not transpose music. |
| D07 | USER | Offline stops synchronization, not access to previously downloaded music. |
| D08 | USER | Church pays; musicians and guests join free. Price and budget approval remain unvalidated. |
| D09 | USER | iPad first; Android only later if needed. |
| D10 | USER | Both individual PDF files and old multi-song weekly PDF packets exist. |
| D11 | USER | Shared circles, arrows, and handwriting are required in the pilot, not just typed instructions. |
| D12 | USER | Shared ink is exact-version-specific. A different-version musician sees an indicator and team-chart preview. |
| D13 | USER | NO page-turn synchronization, even on the same version. |
| D14 | USER | Musicians must tap before changing songs. No auto-switching. |
| D15 | USER | Visual notifications only; no sound or haptics. |
| D16 | DEFAULT | Latest pending announcement only, with last 10 calls in a separate history. No missed-call count or backlog workflow. |
| D17 | DEFAULT | Incoming or resumed state NEVER changes the chart, version, page, preference, or open preview. |
| D18 | DEFAULT | Controller privately stages song + exact team chart + performance key, then sends with one explicit action. Search/preview/upload never publish. |
| D19 | DEFAULT | Main screens: Today, Library, Music Stand. Versions, transfer, session history, preparation, invitations, and controller tools are contextual panels. |
| D20 | DEFAULT | Native SwiftUI + UIKit/PDFKit/PencilKit, local SQLite/GRDB, Supabase Auth/Postgres/private Storage/Realtime. No browser-based music stand in pilot. |
| D21 | DEFAULT | Realtime is a wake-up/invalidation signal. Durable server snapshots, monotonic sequences, idempotency, and reconciliation define state. |
| D22 | DEFAULT | One controller/shared-ink editor per setlist at a time; explicit takeover, expiring lease, increasing fencing epoch. No simultaneous shared canvas editing. |
| D23 | DEFAULT | Personal ink persists per user + version + page. Shared ink is per performance item + version + page, preventing last week's “repeat twice” from silently carrying over. |
| D24 | DEFAULT | Published chart versions are immutable, including written key and page geometry. Archive instead of destructive deletion. Correct bad metadata through a new confirmed version. |
| D25 | DEFAULT | Before service download team charts AND personal preferred versions for the setlist and standby collection. Readiness is per device and exact version. |
| D26 | DEFAULT | Personal note changes may sync later. Offline live calls never queue. Offline team changes remain private drafts until explicitly reviewed and published after reconnect. |
| D27 | DEFAULT | Member sign-in uses managed email OTP. Guest access uses managed anonymous identity plus a narrowly scoped expiring invitation. Guest private notes are local-only in pilot. |
| D28 | DEFAULT | Invitations are private, revocable, rate-limited, and scoped. A guest does not gain whole-church library access. Installing the iPad app is required; no false browser-join promise. |
| D29 | DEFAULT | Core pen, highlighter, stroke eraser, undo/redo, selected-note copy/paste. Circles/arrows are freehand in v1; no shape-recognition requirement. |
| D30 | DEFAULT | Search supports normalized Korean, initial consonants, English/alternate title, optional first-line alias and hymn number+edition. No copyrighted lyrics catalog bundled. |
| D31 | DEFAULT | Downloads verified by byte count/hash/PDF opening before “ready”; current chart is never replaced by a download error screen. |
| D32 | DEFAULT | Returning to the original setlist is a local navigation action for members. The controller may announce a setlist item explicitly. Extra live songs do not reorder the planned setlist. |
| D33 | DEFAULT | In-session “opened” telemetry means the exact call was rendered, not that a musician is prepared or performing. Leader sees no private note contents. |
| D34 | DEFAULT | A new key for the same song is a new announcement requiring acknowledgement; it never rewrites PDF chords. |
| D35 | DEFAULT | Same chart already open: accepting its new call keeps the page. A different song opened from a call starts on page 1. Manual back navigation may restore its bookmark. |
| D36 | DEFAULT | Target 3–10 physical iPads in pilot; test 50 simulated session clients. These are qualification targets, not paid plan limits. |
| D37 | DEFAULT | Keep billing disabled for the free pilot. Resolve App Store payment treatment before charging; organization sales are not automatically exempt. |
| D38 | DEFAULT | TestFlight pilot needs native/device evidence; no claim of zero bugs or production readiness from reference tests. |
| D39 | USER, amended 2026-10-07 | Support older iPads like the connected iPad6,7 on iPadOS 16.7.16. Minimum target is iPadOS 16.0; qualify actual oldest pilot hardware before release. No beta frameworks or automatic forced OS upgrades. |
| D40 | DEFAULT, amended 2026-10-08 | No AI/OCR, chord transposition, scheduling, lyric projection, multitracks, MIDI, metronome, or LAN-only sync in pilot. Team chat is explicitly authorized under D43. |
| D41 | DEFAULT | New-version and shared-note previews are read-only contextual views; opening one does not save a new preference or acknowledge a live call. |
| D42 | DEFAULT | One member edits private ink on one device at a time in the expected pilot workflow. Concurrent edits still preserve both revisions and require manual resolution. |
| D43 | USER | Team chat is required, added 2026-10-08. Reuse managed identities and exact team permissions; do not change song/page/ink behavior when a message arrives. Cloud accounts, spending and paid Apple enrollment still require authorization. Implementation and activation gates are recorded in the build plan. |

## Explicit supersessions
- The original one-page PDF is historical context, not current specification. Do not bundle it as authoritative build instructions.
- “Leader pushes → every screen changes instantly” is replaced by “leader announces → persistent visual banner → member taps.”
- “Song/page follow” is replaced by song announcements only; page state is private local navigation.
- “A PWA works on every device with a QR link” is replaced by an installed native iPad app for this pilot.
- “Automatically merge or align notes” is replaced by immutable versions and manual selected-note copy/paste.
- “Shared markup is easy” is NOT an engineering assumption. It is an early risk spike with strict version/context/coordinate and concurrency tests.
- Earlier suggested Cloudflare D1/R2/Durable Objects topology is not binding. A single managed Supabase backend is now chosen to reduce custom authentication and cross-store coordination; see architecture ADR.
- No secret plan to reintroduce auto-follow as an optional setting. It is out of scope.

## Decision amendments
Record ID, old behavior, new behavior, evidence, affected tests, and whether user approval is required. Never change a USER decision because a framework makes a different behavior easier.

2026-10-08 · **D40/D43**: the user explicitly requested team chat while asking for a reliable, inexpensive cloud plan. Remove only the prior chat exclusion; retain all other exclusions and live-reader invariants. This records a requirement and planning scope, not implemented chat or authorization to deploy/bill. Add exact-team RLS, member/guest isolation, idempotent message retries, edits/deletions, account-switch, reconnect and no-navigation tests before claiming the feature. Foreground chat can use free development signing; real APNs and wider distribution remain subject to the user's later Apple enrollment.

2026-10-07 · **D39**: replaced provisional iPadOS 18.0 with **16.0** after the user explicitly required compatibility with their USB-connected iPad (iPad6,7 / ML0T2LL/A / iPadOS 16.7.16). The app, all local packages and reproducible project generator share the new minimum. Scene lifecycle handling uses the iOS 16 SwiftUI callback. Core PDF/PencilKit/storage/selected-transfer functionality remains required. Validate native app/test builds and actual recovery/geometry/gesture tests on 16.7.16; a deployment-target edit alone is not proof of runtime compatibility. User authorization is recorded by this explicit requirement. Xcode 27 supports building for iOS 16 but its connected-device support starts at 17; older-device tooling must be qualified separately. No other product decision changed.
