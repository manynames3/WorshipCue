# WorshipCue development versions

## v1 · preserved 2026-10-08

`v1` is the preserved development snapshot of Build 3, before the concept-led
interface redesign. The Git tag and branch named `v1` identify the same commit.
The preserved commit is `45c813977affb102e55737aac74dcb58428a43ee`, published as
the [v1 branch](https://github.com/manynames3/WorshipCue/tree/v1) and annotated
`v1` tag. It includes the native PDF/PencilKit reliability work and the local weekly music
stand, library, immutable chart versions, setlists, manual note transfer and PDF
export. See `verification/M1.md` for its actual test results and limitations.

This is a source checkpoint, not an App Store release or an end-user readiness
claim. Hardware qualification and backend/team/live milestones remain open.
Private PDFs, handwriting, device identifiers and signing material are excluded.

## v2 · concept-led interface · Build 4

Development continues on branch `v2`. The visual references are
`docs/ui-concepts/01-calm-music-stand.png` and
`docs/ui-concepts/02-version-note-transfer.png`: persistent Today/Library/Music
Stand navigation, compact chrome, a large chart, vertical annotation tools, and
a contextual version/manual-transfer inspector with locked source preservation.
Build 4 implements that direction with native SwiftUI: a light reader, persistent
navigation, large vertical tool targets, compact color/input popovers, preparation
cards and searchable library rows with real PDF thumbnails. A charcoal version
inspector docks beside the chart on wide landscape layouts and becomes a sheet
on narrower layouts. Selected personal ink has an exact source preview; placement,
scaling, cancellation and confirmation remain explicit actions.

The existing app and data format continue in place. Future announcement/team
elements in the concepts require real backing behavior before being shown as
working product states. No automatic song changes, page synchronization or
automatic note merging are introduced by the redesign.

The app keeps the same bundle and storage format. Development labels **v1/v2**
identify Git checkpoints; the numbered **chart versions** inside the app identify
individual immutable PDFs. Neither label indicates an App Store release.
Current builds, device tests, data-preservation evidence and limitations are
recorded in [V2 verification](../verification/V2.md).
