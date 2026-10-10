<p align="center">
  <img src="apps/ipad/WorshipCue/Assets.xcassets/AppIcon.appiconset/Icon-167.png" width="112" alt="WorshipCue folded-ribbon W icon">
</p>
<h1 align="center">WorshipCue</h1>
<p align="center"><strong>Keep the music. Keep your notes. Stay together.</strong></p>
<p align="center">A Korean-first native iPad music stand for worship teams.</p>
<p align="center">악보와 필기는 각자 편하게. 곡 안내와 팀 필기는 함께.</p>
<p align="center"><a href="README.ko.md">한국어</a> · <a href="CHANGELOG.md">Features & fixes</a> · <a href="docs/ENGINEERING.md">Engineering</a> · <a href="verification/STATUS.md">Verification</a></p>

WorshipCue brings PDF arrangements, personal handwriting, weekly setlists and team conversation into one rehearsal workflow. Musicians keep control of their music stand while leaders share chart markings and quiet song cues.

A product and engineering project by **[Aiden Rhaa](https://github.com/manynames3)**, spanning native iPad interaction, offline persistence, cloud authorization and a browser companion. Read [how the system is built](docs/ENGINEERING.md) for the decisions, debugging and verification behind the experience.

> **Active development, not an App Store release.** This overview includes actual local work through Build 19. Published application source remains v1 / Build 3 on `main` and `v1`, and v2 / Build 8 on `v2`. Later source changes are pending publication. [Build and verification status](verification/STATUS.md#publication-and-builds).

## Why this exists

A worship chart carries more than notes and chords. It carries the bridge repeat, the vocal entrance, the voicing and the version the team actually rehearsed. A new arrangement should not erase that preparation. A last-minute song call should not pull the page away while someone is still playing.

WorshipCue is built for the people living those moments: musicians and singers rehearsing from PDFs, and bandmasters who need to guide a team while performing. It keeps personal preparation useful, shared changes clear and navigation deliberate.

## From preparation to the music stand

| In rehearsal | What WorshipCue provides |
| --- | --- |
| “Which arrangement are we using?” | A searchable, versioned library with favorites, explicit preferred charts and exact-version setlists. Korean initials, aliases and hymn numbers support familiar ways of finding music. |
| “I need my notes on the new chart.” | Preserve the original PDF and its ink. Select only the strokes you want, preview their placement on another version and confirm the transfer. |
| “Let me mark that entrance.” | Native pen/highlighter, eraser, undo/redo and a small color popover; pen and highlighter remember separate colors. |
| “Is Sunday's set ready on this iPad?” | Ordered and standby songs, individual PDF/memo readiness checks and targeted retries. Prepared local charts and personal notes remain usable offline. |
| “The leader changed the second chorus.” | Team marks tied to the exact performance item, chart version and page, with personal handwriting kept separate. |
| “What did we agree about the ending?” | Team/setlist chat, replies, chart links, pinned instructions and unread/mute controls, with explicit send/retry behavior. |
| “A guest needs the music and conversation.” | A revocable browser link to one chat room and one service's published PDFs. Guests enter a name and join without installing the iPad app. |
| “We're moving to a different song.” | A quiet visual cue. The musician taps to open it and turns their own pages. |

These are implemented development capabilities with different qualification scopes. Real multi-iPad rehearsal, final gesture checks and other release gates remain open; see [the recorded results](verification/STATUS.md).

## Actual implementation captures

<p align="center">
  <img src="verification/swipe12-normal.png" width="780" alt="WorshipCue native iPad music stand with a synthetic chart, annotation tools and independent page controls">
</p>

The iPad music stand: music in the center, annotations within reach and a full-screen control at the bottom right.

<p align="center">
  <img src="verification/chat17-light.png" width="390" alt="WorshipCue native chat with incoming and outgoing bubbles, replies and chart links using synthetic messages">
</p>

Native team chat with familiar message bubbles, grouped senders and inline rehearsal context.

<p align="center">
  <img src="verification/browser14-desktop.jpg" width="780" alt="WorshipCue browser guest companion showing a synthetic PDF beside its scoped group chat">
</p>

Browser guests can read music and talk with the group. Captures use synthetic charts and conversations; the native chat view uses controlled transport. These are actual implementation captures, not design concepts or proof of a live multi-iPad session. [Capture provenance](verification/STATUS.md#screenshot-provenance).

## Capabilities in development

- **Local preparation:** immutable PDF imports, library metadata/search, favorites, version selection, weekly sets, deliberate packet splitting and fallback PDF export.
- **Native music stand:** PDFKit rendering, PencilKit annotations, independent personal/team layers, selected-note transfer, page restoration, full-screen reading and two-finger paging. At fitted zoom, two fingers turn pages; Touch mode keeps one finger available for writing. Zoomed charts pan. Latest swipe/post-zoom behavior still needs final device confirmation.
- **Private team workspaces:** each team has separate PDFs, setlists and chat—even within the same church. Invitations, roles and last-admin safeguards control membership. Team admins cannot read another musician's personal ink.
- **Managed sign-in:** optional Neon email-code authentication connects to the existing AWS services alongside the original Cognito route. Identity and cached data stay separated across providers. Development delivery works; production email branding/configuration remains unfinished.
- **Conversation and coordination:** durable chat with replies, edit/delete/pin, chart links, moderation/report/block controls, saved drafts and explicit retries. Live hints prompt authorized state reads; chat never navigates the reader.
- **Scoped browser sharing:** default 24-hour / ten-join guest links, original PDF viewing with self-hosted PDF.js, independent page/zoom controls, group chat and revocation. Personal native notes stay private.
- **Recovery and portability:** checksum-verified downloads, atomic cache promotion, frozen publication commands, explicit whole-copy note conflict choices, selected-team personal cloud ZIP export, scheduled backups and isolated restore tooling. The ZIP excludes local unsynced work and is not a whole-account restore.

[The changelog](CHANGELOG.md) records additions and fixes, including the authentication handoff, code resend, chat visibility, page-turn performance and capacity safeguards.

## Principles that shape the product

- **The musician chooses when to open a song.** Cues are visual only; no automatic song changes, sounds or vibrations.
- **Pages remain personal.** There is no page syncing.
- **Notes belong to the chart that was marked.** PDFs are immutable; version transfer is manual, with no automatic note merging or guessed alignment.
- **Shared ink has an exact context.** A different version requires preview, not an overlay on the wrong arrangement.
- **“Saved” and “ready” mean verified work.** Local save follows a database commit; a downloaded file becomes ready only after validation and atomic promotion.
- **A key label does not transpose a PDF.** Performance metadata and printed notation are distinct.

## Engineering behind the experience

**Swift / SwiftUI · PDFKit / PencilKit · SQLite / GRDB · Python · AWS · Neon Auth · PDF.js**

The iPad owns the readable local chart and personal notes. AWS API Gateway and Lambda enforce managed identity and exact-team permissions before accessing DynamoDB records or private S3 files. WebSocket hints help clients catch up to durable state. Neon provides the alternative managed sign-in path; it does not replace the AWS database, storage or messaging.

The [engineering walkthrough](docs/ENGINEERING.md) includes an architecture diagram and concrete cases: preserving ink across document versions, diagnosing a Python-runtime authentication mismatch, correcting message read-state geometry, measuring real PDF page turns and guarding a capacity deployment.

Recent recorded evidence includes **227 controlled backend tests**, a **12-case real hosted Neon/AWS check**, a **22-check independent browser-client run**, and **122 passed / three skipped physical native cases** before the final gesture handoff change. These are separate runs, not a combined release qualification. The [verification summary](verification/STATUS.md) retains failed burst and gesture checks alongside passing results.

## Run the published development checkpoint

The app targets **iPadOS 16.0+**. Physical development checks have used an iPad (6th generation) on iPadOS 17.7.11; the original iPadOS 16 device and physical Apple Pencil still require qualification.

Use macOS, Xcode with an iOS SDK and a Swift 6.1+ toolchain. Configure your own device signing locally. The development device has used a free Personal Team; paid distribution is not enabled.

```sh
git clone https://github.com/manynames3/WorshipCue.git
cd WorshipCue
git switch v2
open apps/ipad/WorshipCue.xcodeproj
```

Choose **WorshipCue** for the app/native tests or **WorshipCueUI** for UI workflows. Local reading does not require a cloud account; cloud operations require your private deployment configuration. Credentials and signing identities must stay out of commits.

[Native setup](https://github.com/manynames3/WorshipCue/blob/v2/apps/ipad/README.md) · [AWS setup](https://github.com/manynames3/WorshipCue/blob/v2/aws/README.md) · [Optional external-drive Xcode setup](https://github.com/manynames3/WorshipCue/blob/v2/docs/13_EXTERNAL_XCODE_SETUP.md)

Portable package checks, with the appropriate Xcode toolchain selected:

```sh
swift test --package-path reference/WorshipCueCore
swift test --package-path packages/WorshipCueLocal
swift test --package-path packages/WorshipCueRemote
swift run --package-path packages/WorshipCueLocal InkChecks
```

The [published verification records](https://github.com/manynames3/WorshipCue/tree/v2/verification) contain checkpoint-specific commands and scopes. Later local results are summarized separately in [current verification](verification/STATUS.md).

## Explore the repository

| Area | Responsibility |
| --- | --- |
| [Native iPad app](https://github.com/manynames3/WorshipCue/tree/v2/apps/ipad) | Reader, annotation/transfer UI, team workspace and device tests. |
| [Local persistence](https://github.com/manynames3/WorshipCue/tree/v2/packages/WorshipCueLocal) | Transactional library/setlist metadata, ink storage and geometry. |
| [Remote transport](https://github.com/manynames3/WorshipCue/tree/v2/packages/WorshipCueRemote) | Authentication, authorized operations and live invalidation hints. |
| [AWS backend](https://github.com/manynames3/WorshipCue/tree/v2/aws) | Infrastructure, permissions, publication, chat, backup and recovery. |
| [Core rules](https://github.com/manynames3/WorshipCue/tree/v2/reference/WorshipCueCore) | UI-independent domain behavior and executable contracts. |
| [Product decisions](https://github.com/manynames3/WorshipCue/blob/v2/docs/02_DECISIONS.md) / [build plan](https://github.com/manynames3/WorshipCue/blob/v2/docs/12_BUILD_PLAN.md) | Published decisions, invariants and milestone requirements. |

[Original v1](https://github.com/manynames3/WorshipCue/tree/v1) preserves the first working interface. The earlier Supabase implementation remains in the development tree as historical work. For implementation, read the branch's `AGENTS.md`, decisions and `PROJECT_STATE.md` first.

## Release status and rights

The main remaining gates are final gesture/login UI checks, two-device rehearsal, older hardware/Pencil qualification, sustained offline/reconnect and memory testing, representative backend capacity, larger recovery checks, production email, account deletion/retention/support and distribution. Bluetooth pedals, face/gesture controls and background push remain future work. [Full verification status](verification/STATUS.md).

Only synthetic charts and conversations appear in this repository. Churches and musicians need permission for the PDFs they import and share; WorshipCue does not provide a commercial song catalog or music license. Dependency notices are in the [native app](https://github.com/manynames3/WorshipCue/blob/v2/apps/ipad/WorshipCue/ThirdPartyNotices.txt) and [backend](https://github.com/manynames3/WorshipCue/blob/v2/aws/THIRD_PARTY.md). No open-source license has been granted for WorshipCue's own source.
