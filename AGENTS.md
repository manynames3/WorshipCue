# WorshipCue engineering rules

## Authority and scope
Read `docs/02_DECISIONS.md` first. These decisions supersede earlier pitch documents. This is a native iPad pilot with a managed Supabase backend, not a generic church-management platform. Respect existing repository work and the user's current instructions. Never overwrite or discard unrelated changes.

## Product invariants
1. Incoming live calls NEVER navigate; musician taps do.
2. Page turns are local only. No page events in the live protocol.
3. Visual notifications only. No haptic/audio APIs for announcements.
4. Latest pending call only; history is separate.
5. Personal notes belong to owner + exact chart version + page.
6. Team notes belong to performance item + exact chart version + page; wrong-version notes are preview-only.
7. Published PDFs never mutate. No automatic note transfer.
8. Source choice, document loading, notification acknowledgement, and actual readiness are separate concepts.
9. Save locally before reporting “saved.” File download success is not cache-ready until verification and atomic promotion finish.
10. No offline live-call replay. Reconnect does not switch charts. One controller with an increasing epoch.
11. Admin and leader application roles cannot read personal ink. Tenant ID supplied by a client is not authorization.
12. Never claim a PDF transposed because a key label changed.

## Implementation
Use small modules with explicit interfaces. Pure domain rules must not import SwiftUI, PDFKit, PencilKit, or Supabase. Keep mutable PDF/ink view lifecycles on their required actor and use immutable IDs captured with each save operation. Local storage uses transactional migrations and a durable outbox for personal-note synchronization, NOT for live publication.

Start with native framework behavior; do not add private Apple APIs or a generic drawing/collaboration engine. No CRDT, AI/OCR, custom authentication, multi-platform UI, subscriptions, chat, scheduling, or MIDI in the pilot. Do not adopt a dependency just for one trivial helper. Lock dependencies and document license/security review.

Use Korean String Catalog localization, explicit accessibility labels, calm error language, large action targets, and no critical color-only state. Do not put a full-screen loader over a chart that is already readable.

## Tests and evidence
Run targeted tests while iterating, then all milestone tests. Before claiming completion: compile affected targets, run domain/integration/UI checks available, inspect critical screens, and record exact results. Physical Apple Pencil, device memory, resume, thermal, and multi-iPad tests cannot be replaced by mock tests.

Handoff checks:
```sh
swift test --package-path reference/WorshipCueCore
python3 scripts/verify_package.py
```
During M0 add actual app commands to `PROJECT_STATE.md` after discovering valid scheme and simulator IDs. Never invent a destination UUID. Keep coverage focused on invariants and failure paths, not an arbitrary percentage.

## Security and operations
No secrets, PDFs, handwriting, emails, invite tokens, or copyrighted lyrics in logs or fixtures. Supabase publishable keys still require RLS; service-role keys are server-only. Secure-definer RPCs require explicit actor checks, fixed search paths, minimal grants, and adversarial tests. Use immutable asset paths and access-controlled storage.

Do not modify cloud accounts, billing, production schema, publishing, or repository remotes without permission. Do not run destructive reset/clean commands. Keep `PROJECT_STATE.md` factual and current; write milestone evidence to `verification/`. Report assumptions and blocked tests honestly.
