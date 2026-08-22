# Text Overlay finishing increment

## Status

Accepted product decisions. Implementation target: `codex/text-overlays`, based on the physically validated `iphone-tested-2026-08-22` baseline.

## Outcome

Camenya separates picture editing from finishing:

1. The user reviews the Primary Storyline and chooses **Finish Video**.
2. Camenya encodes a clean, captionless and overlay-free movie from the immutable Take sources.
3. Camenya validates the movie and saves it to Photos.
4. Only after Photos confirms the save does Camenya commit Picture Lock.
5. The locked Workspace exposes captions and Text Overlays as finishing tools.
6. Final export renders again from the immutable Picture Lock sources. The Clean Master is a validated checkpoint, not a transcode source.

If encode, validation, Photos save, or lock persistence fails, the Storyline remains editable. Recoverable completed media is retained and Retry repeats the exact unfinished step. The only ambiguous boundary—Photos may have committed before local confirmation—never auto-retries: the user checks Photos and explicitly confirms the save or chooses **Save Again**.

## Domain model

### Text Overlay

A Text Overlay is owned by one Picture Lock and contains:

- stable identifier;
- non-empty text;
- a positive Project-Time range wholly inside Picture Lock duration;
- a normalized center point constrained to the Content Safe Region;
- a Text Appearance copied at creation or explicit style application time.

Array order is compositing order from back to front. Captions are composited after the complete Text Overlay array and therefore always appear above every Overlay.

Deleting an Overlay is the only way to exclude it from final export. There is no enabled toggle or per-export variant matrix.

### Text Appearance

Text Appearance contains only reusable visual treatment:

- system, rounded, serif, or monospaced font design;
- regular, semibold, bold, or heavy weight;
- small, standard, or large scale;
- palette or custom text color;
- no, thin, or strong automatic-contrast outline;
- none, shadow, or rounded-box background;
- leading, center, or trailing alignment.

It excludes timing, position, box dimensions, caption density, spoken language, and word highlighting. Applying a Saved Text Style copies its current value. Later edits to the saved template do not mutate existing captions or overlays.

## Deep modules and seams

### `ProjectFinishingStore`

The persistence seam is the existing `ProjectStore` interface. It owns validation and atomic mutation for:

- Finish Video commitment;
- add, update, delete, duplicate, and reorder Text Overlay;
- unlock cleanup of every Picture-Lock-derived finishing element.

SwiftUI never writes the manifest directly.

### `ProjectFinishingTimeline`

An immutable export and preview value containing ordered Text Overlays, optional approved captions, and duration. It resolves active overlays at Project Time and preserves the invariant that captions are the top presentation layer.

### `ProjectFinishingRenderer`

One Core Animation renderer is the deterministic presentation boundary for preview and burn-in. Preview and export use the same font, wrapping, outline, background, position, and safe-region calculations.

### `FinishVideoCoordinator`

`AppModel` owns the user-visible asynchronous transaction. Media encoding remains in `ProjectExporter`; Photos mutation remains in `PhotoLibrarySaver`; durable state remains in `ProjectStore`. The coordinator exposes one operation, one progress owner, exact Retry for known outcomes, and an explicit two-choice resolution for an ambiguous Photos handoff.

## Editor experience

- The locked Workspace exposes **Text** beside the captions action.
- The editor keeps the portrait video preview dominant and opens at the current Workspace Project Time.
- A compact Text lane appears beneath the video timeline. Overlay blocks use their Project-Time width, show truncated text, and indicate selection without relying on color alone.
- A fixed central playhead represents the insertion and preview time. Playback moves the timeline beneath it. Manual scrolling pauses playback and seeks.
- **Add Text** creates a sensible default interval beginning at the playhead, capped by Picture Lock end, then focuses text entry.
- Selecting a block seeks to its start and opens inline editing controls.
- Timing uses one reusable range-control grammar: draggable handles plus named Start/End nudge alternatives. The initial increment is 0.1 seconds with an explicit fine 0.01-second option.
- Position is direct manipulation inside the safe region. Center and safe-edge guides appear only while dragging. A named Reset Position action provides a non-gesture alternative.
- The keyboard keeps the edited row and controls visible, may temporarily hide the timeline, and restores the previous editor layout and scroll context on dismissal.
- The ellipsis menu owns Duplicate, Move Forward, Move Backward, and Delete. Delete is recoverable through session Undo.
- Every mutation is one atomic session-history operation. **Done** persists the complete collection atomically; **Cancel** discards the session. Undo and Redo announce the exact operation.

## Validation seams

TDD verifies behavior through these public seams:

1. `ProjectStore` manifest operations: lock ownership, valid ranges, safe positions, ordering, duplicate semantics, unlock cleanup, schema migration.
2. `ProjectFinishingTimeline`: active interval resolution and captions-always-on-top ordering.
3. `ProjectExportPlan` and renderer layer tree: clean export excludes finishing; final export includes ordered overlays beneath captions.
4. Presentation policy and editor state: add defaults, range constraints, keyboard layout state, exact Undo/Redo operation boundaries, and accessibility labels.
5. Finish Video coordinator dependencies: lock is committed only after validated media and successful Photos save; each failure remains retryable without losing media.

Physical-iPhone acceptance covers the Photos transaction, WYSIWYG preview, final burned-in Text Overlay plus captions, unlock cleanup, relaunch persistence, and a clean rollback to `iphone-tested-2026-08-22`.

Schema-10 Picture Locks are preserved but cannot enter finishing or final export until **Finish Video** creates the required Clean Master. The upgrade retains the existing Picture Lock and Caption Track, and never fabricates a Photos save or silently removes prior work.
