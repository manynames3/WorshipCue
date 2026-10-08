# WorshipCue development versions

## v1 · preserved 2026-10-08

`v1` is the preserved development snapshot of Build 3, before the concept-led
interface redesign. The Git tag and branch named `v1` identify the same commit.
It includes the native PDF/PencilKit reliability work and the local weekly music
stand, library, immutable chart versions, setlists, manual note transfer and PDF
export. See `verification/M1.md` for its actual test results and limitations.

This is a source checkpoint, not an App Store release or an end-user readiness
claim. Hardware qualification and backend/team/live milestones remain open.
Private PDFs, handwriting, device identifiers and signing material are excluded.

## v2 · concept-led interface development

Development continues on branch `v2`. The visual references are
`docs/ui-concepts/01-calm-music-stand.png` and
`docs/ui-concepts/02-version-note-transfer.png`: persistent Today/Library/Music
Stand navigation, compact chrome, a large chart, vertical annotation tools, and
a contextual version/manual-transfer inspector with locked source preservation.

The existing app and data format continue in place. Future announcement/team
elements in the concepts require real backing behavior before being shown as
working product states. No automatic song changes, page synchronization or
automatic note merging are introduced by the redesign.
