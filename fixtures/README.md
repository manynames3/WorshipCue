# Synthetic test fixtures

All PDFs here were generated specifically for this handoff. They contain invented test titles, section labels, and elementary chord sequences, not commercial worship scores or lyrics. Use them for project testing; do not present them as playable licensed worship arrangements.

- `song_A_v1_G.pdf`: two pages; chorus on page 1.
- `song_A_v2_G.pdf`: three pages; chorus moved to page 2.
- `song_A_v3_A.pdf`: different written key and ending.
- `song_B_v1_D.pdf`: second song for call transitions.
- `geometry_rotations.pdf`: four pages with 0/90/180/270-degree rotation and nonzero CropBox.
- `weekly_packet.pdf`: cover on page 1; song A pages 2–3; song B pages 4–5.
- `corrupt_negative.pdf`: intentionally truncated and expected to fail parsing. NEVER import as a successful published version.

`pdf-manifest.json` supplies real bytes/hashes/page geometry for these generated PDF files. Schema JSON examples are contract examples, not a complete seed database. In particular, `sample-annotation-revision.json` uses placeholder native/preview asset references to validate shape; no fake PencilKit archive was generated. M0 must create genuine drawing fixtures on Apple platforms and capture pen/eraser/highlighter/selection cases. The cross-platform helper tests do not verify PDFKit transforms or handwriting.

Create an additional large/high-resolution scan performance corpus and real PencilKit data during M0/M1. Test all legal source chart permissions separately from these synthetic fixtures.
