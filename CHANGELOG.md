# WorshipCue development history

[Overview](README.md) · [Engineering](docs/ENGINEERING.md) · [Verification and publication status](verification/STATUS.md)

This is a feature and fix history, not an App Store release log. Build numbers identify development checkpoints; chart version numbers identify arrangements. Dates and results below are historical evidence, not live service status. The published `v2` source checkpoint is Build 8; later entries describe local development work whose source publication is pending.

## Local development · Builds 9–19 · October 9–10, 2026

### Reader and annotation experience

- Added full-screen music reading, removed redundant reader chrome, and positioned the entry control at the bottom right near the full-screen exit control.
- Added two-finger page navigation while preserving one-finger Touch-mode writing, independent page choice, page bounds and save-before-turn behavior.
- Reduced repeated page metadata/loading and unchanged-ink serialization work. Eighty alternating arrow turns on two arranger PDFs passed the rendered-p95 threshold of 250 ms; measured values were 123.52–140.72 ms across four scenarios.
- Corrected the earlier right-swipe rejection; the user confirmed both directions in Build 12.
- Build 19 reproduced and corrected premature gesture failure from uneven finger movement and overly strict diagonal rejection. An eligibility handoff correction makes the recognizer explicitly fail when paging is unavailable, allowing dependent pan/drawing recognizers to proceed. Its final device execution and post-zoom behavior remain unverified after test-runner stalls.

### Sign-in and recovery

- Added optional managed Neon email-code sign-in alongside Cognito, retaining the existing AWS team, file and chat services. Provider identities stay separate; joining a team requires an invitation.
- Corrected a managed-session cookie parsing incompatibility reproduced on Lambda's Python 3.13 runtime. A real native managed sign-in/Keychain/workspace/chat restoration check subsequently passed.
- Resending a code now clears the previous text and retains a blank entry field, including after a request error. Failed resends preserve only the prior exact-email challenge; provider expiry remains authoritative.
- Distinguished credential-storage and authentication stages in diagnostics instead of reporting every failure as a server connection error.
- Corrected debug UI-test credential-store isolation after Xcode relocated its test container. Normal app credentials use their existing namespace.

### Browser music and guest chat

- Added admin-created guest links scoped to one chat room and one service's published music, with default 24-hour expiry, ten joins and revocation.
- Guests enter a display name, view original PDFs, turn/zoom pages independently and participate in the selected group conversation.
- Added pinned, self-hosted Mozilla PDF.js after the built-in browser viewer stayed blank. No external viewer CDN is required.
- Added secure browser session cookies, reply/edit/delete/report controls, session restoration and revocation cleanup. Hosted two-client HTTP checks passed; physical phone-browser qualification remains open.

### Native chat interface

- Added outgoing/incoming bubbles, grouped sender names and timestamps, date separators, rounded composition, compact replies/chart links, a quiet welcome and an explicit latest-message control.
- Inspected light and accessible dark layouts with synthetic conversations.
- Corrected viewport/message coordinate handling and the latest-message action so read state follows visible persisted messages rather than marking offscreen messages read. The final focused chat suite passed 12 cases.

### Backend capacity and qualification

- Added guarded HTTP admission settings of 50 requests/second and 100 burst, subject to sufficient actual Lambda headroom.
- Added a capacity-only deployment path that preserves deployed code, parameters, stored content and identities and refuses unrelated resource changes. Nine focused regressions and 227 controlled backend cases passed.
- The higher settings are **prepared, not deployed**. The last recorded deployed settings remain 10 requests/second and 30 burst, with an applied account Lambda limit of ten concurrent executions.
- Preserved the failed raw 50-client result: 27 passed, 23 failed. The AWS capacity request and a separately successful paced run do not establish a corrected burst result.
- Expanded actual hosted auth/chat, independent browser-client, private-PDF, backup-restore and data-preservation checks. Their scopes and exclusions are listed in the [verification summary](verification/STATUS.md).

## Published v2 source · Build 8 and earlier · October 7–8, 2026

### Added

- Concept-directed native reader with compact chart metadata, vertical annotation tools and Today/Library/Stand navigation.
- Versioned library, Korean title/initial/alias/hymn search, favorites and explicit preferred-chart selection.
- Weekly setlists with ordered and standby songs, exact chart versions and performance keys; deliberate packet splitting and fallback PDF export.
- Separate AWS-backed team libraries, setlists and chat, including teams within the same church.
- Managed sign-in/invitations, roster and role administration, and safeguards against removing the final active admin.
- Exact-context shared ink, private personal-note synchronization with explicit conflict choices, and visual song cues requiring a tap to open.
- Team/setlist chat rooms, unread/mute, replies, edit/delete/pin, chart links, reporting, blocking and leader moderation.
- Direct team/chat access, per-chart PDF/memo preparation checks and targeted retries.
- Frozen publication requests and command IDs for safe explicit retries; validated paginated library caching.
- Selected-team personal cloud ZIP export with verified note files and authorized source PDFs.
- Backup and isolated restore tooling, scoped mail feedback handling, operational alerts and a stakeholder infrastructure diagram.

See [Build 8 evidence](https://github.com/manynames3/WorshipCue/blob/v2/verification/BUILD8.md), [Build 7 chat evidence](https://github.com/manynames3/WorshipCue/blob/v2/verification/CHAT7.md) and [AWS evidence](https://github.com/manynames3/WorshipCue/blob/v2/verification/AWS.md) for their original verification boundaries.

## Preserved v1 source · Build 3 · October 7, 2026

- Native PDFKit/PencilKit reader and local version/page-specific personal ink persistence.
- Pen, highlighter, eraser, undo/redo, finger-writing test mode and compact color selection.
- Manual selected-stroke transfer with preview, placement, confirmation/cancellation, undo and source-note preservation.
- Initial WorshipCue icon and real-device/reference verification records.

The original interface remains on [the v1 branch](https://github.com/manynames3/WorshipCue/tree/v1). The `main` branch retains that application source while presenting current product documentation.

## Remaining work

Complete the final swipe/post-zoom checks, real multi-iPad rehearsal, original iPadOS 16 hardware, physical Apple Pencil/palm behavior, interruption/memory/thermal qualification, representative concurrent-user capacity, larger restores, production email, account deletion/retention/support and release distribution. Bluetooth pedals, gesture/face controls, background push and richer setlist discovery are future work. No automatic song changes, page syncing or automatic note merging have been added.
