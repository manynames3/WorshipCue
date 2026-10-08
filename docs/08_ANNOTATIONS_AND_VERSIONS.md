# Annotation, PDF version, and coordinate specification

## 1. Layers and lifetime
A chart is an immutable PDF version. Render:
- original PDF;
- team ink for the exact `(performance_item_id, chart_version_id, page_index)`;
- the viewer's personal ink for `(user_id, chart_version_id, page_index)`.

Personal layers follow reuse of the same chart version across weeks. Team rehearsal directions are tied to this particular performance occurrence, so “skip verse 2” from last week does not silently affect next week's service. Cloning a setlist creates new performance item IDs. A leader can explicitly copy last week's team layer before service; default is no copy. We do not add a second persistent/global shared-ink layer in the pilot.

Team ink is visible immediately after committed updates when BOTH occurrence and chart version match. A same-file hash is not sufficient if the chart belongs to a different version/context. A member viewing another version receives a badge and a read-only preview of the marked team chart. Do not copy remote x/y to a different PDF.

## 2. Writing tools
Required: freehand pen, highlighter, stroke eraser, undo/redo, and selected-note copy/paste/reposition. Circles, arrows, and handwritten words can be drawn freehand. Perfect-shape tools, handwriting recognition, text conversion, and drawing collaboration cursors are out of scope.

PencilKit is the native drawing engine. Restrict tools to a stable set supported by the minimum OS. Do not rely on private APIs to enumerate Apple's currently selected lasso strokes. Prototype cross-canvas native selection/copy/paste early. If public selection APIs do not expose the required action, implement an explicit app-owned selection overlay that identifies stored strokes by rendered bounds/path intersection, with a selection preview before copying. Use public PKDrawing/PKStroke data only.

Default editing scope is PERSONAL. TEAM scope is an explicit mode with persistent “팀 전체 공개” indication, accessible only to current editor. Member controls must never target the team canvas. A personal eraser does not erase team ink, and vice versa. Canvas apply-from-server must be distinguishable from user editing to prevent an echo loop.

## 3. Saving contract
Local native drawing data is canonical for editing. At each stable drawing change, capture immutable layer ID, current version/page geometry, and drawing bytes. Commit snapshot + incremented local generation + outbox record in one SQLite transaction. Do not show “기기에 저장됨” until that commit completes. The in-progress/uncommitted stroke may be lost on sudden termination; the UI must not claim it was saved.

Qualify a target of <=300 ms from pen-up to local commit for supported fixture sizes. Debouncing is allowed, but the saved indicator must remain pending while not durable. Before navigation, capture any outstanding change and await the local save boundary or preserve it in memory with an explicit error; never drop it because a view disappeared.

For team updates, coalesce to at most roughly one snapshot per second after pen-up; measure and tune. Do not transmit full page drawings on every pencil sample. Target <=2 seconds from locally saved pen-up to visible remote committed ink under the qualified network/load. This is a test target, not a guarantee. If an upload is slow, latest head waits; members retain previous correct ink.

## 4. Portable record without false portability claims
Each cloud annotation revision records:
- immutable PKDrawing archive (`native_format: pencilkit`, format schema version, originating OS/app version);
- transparent PNG preview of that ink alone;
- canonical page geometry, preview dimensions/scale, hashes, bytes, and parent revision;
- exact layer identity and visibility scope.

The PNG is a derived read-only fallback and a possible future Android viewing representation. It is NOT editable ink and does not guarantee high-zoom fidelity. Future Android editing requires an explicit portable-stroke format/adapter or a migration; do not invent this support in the pilot. Preserve native archives even if newer previews are regenerated. Exporting an annotated PDF is a separate derived file, never a source overwrite.

## 5. Canonical coordinates
Coordinate space is the **displayed CropBox after applying the PDF page rotation**, with origin at its top-left, units in document points. Store original CropBox origin/size, declared rotation (0/90/180/270), displayed width/height, and a geometry schema version. Do not use screen pixels as persistent coordinates.

Native canvas is anchored to canonical document-point dimensions; viewport zoom/scroll is a transform only. Persistent geometry must not change when the iPad rotates or the user zooms. PNG overlays use the same canonical extent. Unit-square normalized bounds are useful in a clipboard envelope, but all rendering still requires the full transform chain.

Transform chain: PDF native coordinates → CropBox translation → declared rotation → top-left canonical space → view scale/translation. Prefer documented PDFKit conversion APIs and verify their inverse, rather than assume PDF origin conventions. Store no rotation corrections that were guessed from the screenshot.

Fixtures must cover portrait, landscape, 90/180/270 rotations, nonzero CropBox origins, mixed page sizes, 100–400% zoom, and device rotation. A mark at a labeled target must remain within the agreed visual tolerance (e.g. 2 PDF points) after round trips. Pixel-only comparison is insufficient if the whole crop shifted together.

## 6. Manual transfer between versions
Selection is limited to one source page at a time in the pilot. Copy an immutable clone of selected personal strokes plus source geometry and selection bounds into an in-app clipboard. Do not automatically place a note based on OCR/music matching.

Destination flow: choose chart version → choose page → paste preview centered in the visible canonical region → drag/optional uniform scale → commit. Preserve aspect ratio; never stretch a note differently in x/y to “fit” a new page. Default placement does not claim musical alignment. Copying v1→v3 never edits v1. Cancel produces no destination change. Undo removes only the newly pasted group.

Cross-page/cross-version clipboard remains available while opening the destination. App-owned clipboard is preferable to exposing private drawings via the system pasteboard; explicit system copy/export can be a later reviewed feature. The initial task must prove that closing the source view does not destroy the clipboard selection.

## 7. Concurrency and conflicts
No CRDT in v1. Personal expectation is one active editing device, but two-device edits must not lose content. Local outbox carries `base_server_revision`. Server compare-and-swap either commits or returns a conflict. Keep local and server snapshots and offer a comparison/selected-copy path; never silently last-write-wins.

Team scope has a single writer enforced by lease/epoch on the server. Losing the lease converts subsequent edits into a local draft. Offline drafts are not auto-published on reconnect. New editor must review current head and explicitly choose whether to copy draft content. Team undo history cannot undo another editor's subsequently published work.

## 8. Version replacement
Uploading v4 never deletes v3 or transfers notes automatically. Published version records and file bytes are immutable. Source hash equality may deduplicate storage within a tenant, but vN identity still has its own key/geometry/context. Version numbering is assigned transactionally. A failed upload does not consume a visible finalized version number or make a broken default.

A member may choose a different version even during a live session; the current acknowledged song stays but version differences become visible. Opening a team preview does not change that choice. Page maps between different versions are not inferred and no shared page navigation is introduced.

## 9. Read-only and export safeguards
Members can hide team ink locally without deleting it; show that it is hidden. Personal notes never enter a team preview by default. An export dialog explicitly identifies which layers are included; an administrator cannot export another user's private ink. The result is a new PDF in temporary export storage. Cancel/failure leaves originals/notes untouched. Export requires valid content permissions; private hosting is not a blanket copyright license.
