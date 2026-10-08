# Codex kickoff: build WorshipCue

You are implementing WorshipCue, a Korean-first native iPad music stand for a church worship team. Build a dependable product, not a clickable mockup. This package is a handoff, not a claim that the app exists.

## First actions
1. Read `AGENTS.md`, `PROJECT_STATE.md`, `docs/02_DECISIONS.md`, and `docs/12_BUILD_PLAN.md`.
2. Inspect the current repository, working tree, installed toolchain, existing instructions, and any prior implementation. Preserve uncommitted work. Do not create a second app if one already exists. Merge these instructions rather than overwrite existing instructions.
3. Read the detailed specifications for the milestone you are implementing, and run the handoff reference checks where the environment supports them.
4. Write a short implementation plan. Begin **M0, the native ink/PDF reliability spike**, then complete milestones in order. Do not spend the first milestone building authentication screens or polishing a dashboard while the ink engine remains unproven.
5. Use the chosen defaults without asking optional product questions. For genuinely blocking external approvals, credentials, signing, or device access, do independent local work and report exactly what is missing.

## Non-negotiable behavior
- Native iPad first. SwiftUI shell, UIKit/PDFKit/PencilKit integration, local SQLite via GRDB, managed Supabase backend. iPadOS 16.0 is the minimum after the user's older-iPad requirement (D39 amendment); qualify the connected 16.7.16 iPad and the team's oldest real hardware before pilot release. No beta-only APIs.
- Musicians MUST TAP before a newly announced song opens. Receiving notifications, reconnecting, changing the leader's PDF, or downloading a file must never change the musician's displayed chart.
- No page-turn synchronization; no auto-follow toggle; no audio/haptic notifications.
- Latest announcement replaces older pending announcements. Keep a separate recent history, not a queue.
- Preserve preferred chart version, personal notes, and page position on incoming events. Clearly separate latest announced song/key from the musician's currently open song/key.
- Team ink overlays only the SAME performance item and exact chart version. Other versions get a preview action, never coordinate guessing.
- Source PDFs and published chart versions are immutable. Personal ink is version-specific; manual selected-note copy/paste is required. No automatic note migration or layout matching.
- Offline: downloaded charts are readable and personal notes are locally durable. No LAN sync, no offline publication of live calls, no stale live-call outbox that broadcasts later.
- One explicitly authorized controller/editor at a time, with server fencing. Do not conflate chart opened, notification received, and actual musician readiness.
- A Supabase Realtime message is an invalidation hint. Durable database state and revision numbers decide truth. Reconcile on resume/reconnect and periodically while LIVE.

## How to work
Implement one vertical milestone at a time, including its tests. Update `PROJECT_STATE.md` and a milestone evidence file after each. Continue to the next unblocked software milestone only when the previous automated gate passes. If a required physical-device gate cannot be run, mark it NOT VERIFIED; local/backend work may continue, but do not label the app pilot-ready.

Use OpenSpec only if the repo already uses it or the installed tooling is deliberately adopted in M0. Do not invent CLI commands or install a collection of agent frameworks. The supplied specs and stable decision IDs are sufficient. Use subagents for independent review/test tasks only when supported; do not let separate agents concurrently edit the same domain contracts.

Do not silently defer shared handwriting, selected-note transfer, offline personal-note durability, or tap-to-open. These are core requirements, not polish. The reference Swift package is an executable specification, not an excuse to skip production integration tests.

## Safety and delivery
Do not deploy, purchase subscriptions, alter production data, publish an App Store build, or push a repository without authorization. Do not add service-role credentials to the iPad bundle. Use real error handling, schema migrations, RLS, tests, structured logs without content, and reversible development changes.

If macOS/Xcode is unavailable, implement and test portable domain contracts and backend work, prepare the native project without claiming a successful iPad build, and state which Xcode/device checks remain. Never fabricate a passing test or a screenshot.

## End-of-milestone report
State: what works; changed files; exact commands and results; untested/blocked checks; known risks; next milestone. No generic “production-ready” claim. Never downgrade a failed test to a warning just to finish.
