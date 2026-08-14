# Epic: non-destructive Primary Storyline

## Status

Accepted for sequential implementation. Product and domain decisions were confirmed on 2026-08-14 after research and design review.

## Outcome

Camenya is a narrative recorder with a non-destructive Primary Storyline. It lets users select, trim, split, reorder, remove, and mute the Clips needed to construct a story. It is not a multitrack video editor or creator suite.

This Epic replaces the current one-Take-per-Timeline-row assumption with an immutable Take source and editable Timeline Clip occurrences. It must preserve Camenya's capture reliability, local-first recovery guarantees, and explicit Project Export boundary.

## Sources of truth

- Product position and principles: `PRODUCT.md`
- Native iPhone experience and design system: `DESIGN.md`
- Canonical language: `CONTEXT.md`
- Architectural decision: `docs/adr/0008-adopt-a-non-destructive-primary-storyline.md`
- Comparative evidence, not product authority: `docs/research/mobile-timeline-editing-models.md`
- Repository constraints and verification: `AGENTS.md`

If implementation pressure conflicts with these sources, stop and surface the conflict. Do not silently widen the product ceiling.

## Product boundary

### Included editing grammar

- Select one Timeline Clip.
- Seek with one global Playhead on a horizontally zoomable filmstrip.
- Trim a Clip within its Available Range.
- Split a Clip at the Playhead.
- Reorder Clips in the Primary Storyline.
- Remove and restore Clips without deleting their Takes.
- Mute a Clip's source audio.
- Undo and redo edits during the current editing session.
- Preview and export from the same immutable Storyline snapshot.

### Explicitly deferred

- Background music.
- Arbitrary multitrack video or audio.
- Imported video.
- Speed controls.
- Transition catalogs.
- Duplicate Clip.
- Image and sticker overlays.
- Keyframes and freeform animation.
- A general media library.

Title Cards and one bounded text overlay per Clip are accepted future concepts, but implementation starts only after the core video Storyline is validated.

## Domain contract

### Take and Timeline Clip

- A Take is an immutable finalized recording source.
- A Timeline Clip is one editable occurrence that references one Take.
- A new finalized Take automatically creates a full-range Timeline Clip at the end of the Primary Storyline and opens review.
- Only an explicit removal can move that Take out of the active story.
- Removing a Timeline Clip never deletes its Take.
- A Take referenced by any active or Removed Clip cannot be permanently deleted. The UI identifies dependent Clips.
- Project Deletion is the only cascading deletion.

### Ranges and Split

- Every Take has one Source Range.
- Every Timeline Clip has an Available Range and a Clip Selection within it.
- Reset Trim restores the Clip Selection to the Clip's Available Range, not to the whole Take.
- Minimum Clip Selection duration is 1.0 second.
- Split atomically replaces one Clip with two adjacent Clips referencing the same Take. It does not render or copy media.
- Split preserves the immediate output.
- If a parent has Available Range `[0, 20)`, Clip Selection `[2, 18)`, and is split at `8`, the left result has Available Range `[0, 8)` and Clip Selection `[2, 8)`, while the right result has Available Range `[8, 20)` and Clip Selection `[8, 18)`.
- After Split, the Playhead remains at the cut, the right Clip is selected, playback stays paused, and VoiceOver announces the result.
- No initial Join command is required. After relaunch, the user can remove the split Clips and use `Add Full Take to Storyline` from the unused Take.

### Remove, restore, and unused media

- Removed Clips persist their identity, Take reference, ranges, mute state, and placement context.
- Restore first attempts the original neighbors, then the nearest valid position.
- Removed Clips never expire automatically.
- `Removed & Unused` is a discrete management destination, not an always-visible media library.
- A Removed Clip offers Restore Clip and Delete Removed Clip Permanently. Deleting its metadata never deletes Take media.
- A Take becomes Unused when no active Timeline Clip references it, even if Removed Clips still do.
- An Unused Take always offers Add Full Take to Storyline. It offers Delete Take Permanently only after no Removed Clip references it.

### Undo and redo

- Undo and redo are session-only.
- Split, Move, Remove, Restore, and Mute each commit as one command.
- A trim drag previews continuously and commits one command on release.
- Every 0.1-second nudge is one command. Do not group nudges with timers or sleeps.
- A new edit after Undo clears Redo.
- Durable recovery comes from immutable Takes and persisted Removed Clips, not from a persistent command log.

### Captions and silence analysis

- Caption Tracks are Take-owned and source-relative.
- Text corrections are shared by every Clip referencing that Take.
- Each Clip projects only cues within its Clip Selection into Project Time.
- Adjacent Split does not invalidate caption approval by itself.
- Trim includes only cues in the selected range.
- A structural edit that makes a cue semantically unsafe creates a Caption Timeline Issue.
- Video export may continue without the affected cue, but that caption cannot return until explicitly reviewed and approved.
- Never invent or silently interpolate recognition timing.
- Silence analysis may reuse a Take-owned audio envelope, but Trim Suggestion and approval are per Clip and bounded by its Available Range.

### Empty and busy states

- An empty Primary Storyline is valid but cannot be exported.
- Structural editing is unavailable while a Take is recording or paused. The user finishes the Take first.
- Structural editing is unavailable during Project Export.
- Project Export consumes one immutable snapshot and may be cancelled.
- A persisted mutation blocks its affected Clip until commit.
- Thumbnail and filmstrip generation run after commit and do not determine mutation success.
- Transcription and silence analysis consume explicit source and revision snapshots.
- A stale asynchronous result cannot overwrite a newer Storyline revision.

### Naming and scale

- Timeline Clips have no custom names initially.
- Visible labels such as `Clip 1` are derived from current Storyline order.
- A Take retains stable date and source identity.
- Thumbnails, ranges, and durations distinguish Clips that reference the same Take.
- Do not impose an arbitrary initial Project duration or Clip count limit.
- Perform storage preflight before recording and export.
- Introduce limits only from measured physical-iPhone evidence.

## Native iPhone UX contract

- The main editing environment is visual: standard navigation, large viewer, global Playhead, horizontal zoomable filmstrip, selected Clip, and compact contextual inspector.
- A list may remain for management and accessibility but is not the main editor.
- Use native SwiftUI controls, semantic system colors, SF Symbols, Dynamic Type, and standard navigation before creating custom UI.
- Custom controls are justified for the filmstrip, Playhead, and trim handles, while still providing 44-point hit regions, VoiceOver semantics, and named non-gesture alternatives.
- Use system tint for selection, System Red for recording or destruction, and System Yellow for attention. Do not communicate state by color alone.
- Motion communicates edit state in 150 to 250 milliseconds and respects Reduce Motion.
- Verify compact widths, accessibility text sizes, Light Mode, Dark Mode, Increase Contrast, and both Project Formats.

## Persistence baseline

The pre-Epic development schema does not require a user-data migration because it has not shipped beyond the sole developer. The schema introduced by this Epic becomes the stable baseline. Every later persistence change must migrate or preserve existing Project data.

## Delivery sequence

Each phase is one independently testable branch and pull request. Do not start a dependent phase until its prerequisite has been accepted and, where required, validated on a physical iPhone. A stacked draft requires explicit maintainer approval.

1. **Foundation:** Take and Timeline Clip separation, Primary Storyline persistence, Project Time mapping, shared immutable snapshot, automatic full-range Clip creation, and stable revision rules.
2. **Playback surface:** global Playhead, viewer, horizontal filmstrip, zoom, selection, and accessibility navigation.
3. **Clip Trim:** Available Range, Clip Selection, handles, 0.1-second nudges, reset, minimum duration, and per-Clip Silence Trim adaptation.
4. **Split:** atomic range partition, selection behavior, accessibility announcement, and persistence.
5. **Reorder:** visible drag state, named accessible alternative, Project Time recalculation, and stable commit.
6. **Remove and restore:** Removed Clips, Unused Takes, dependency-safe deletion, and deterministic restoration.
7. **Session Undo and Redo:** command boundaries and redo invalidation.
8. **Mute:** per-Clip source-audio exclusion through preview and export.
9. **Caption projection:** Take-relative tracks, Clip projection, Caption Timeline Issues, and shared preview/export behavior.
10. **Post-core Title Card:** one duration-bearing text item in the Primary Storyline, only after the video core is accepted.
11. **Post-core text overlay:** one bounded text overlay owned by a Timeline Clip, only after Title Card is independently accepted.

Existing issues must be reconciled with this order before implementation. In particular, issues #6, #9, #10, #12, #14, and #18 are related but do not by themselves define the Epic architecture.

## Quality gates for every phase

- The public issue states the user problem, smallest useful outcome, non-goals, acceptance criteria, and exact prerequisite.
- Domain language matches `CONTEXT.md`; any change updates the glossary and, when warranted, an ADR.
- Interface design follows `DESIGN.md` and is shaped before UI code is written.
- Tests are written first for deterministic state and time mapping.
- Media mutations remain outside SwiftUI views and asynchronous state is revision-safe.
- The required Simulator build succeeds.
- Relevant automated tests run only on an installed iOS Simulator destination.
- The Core Animation caption burn-in integration test does not run on Simulator.
- `git diff --check` succeeds.
- A standards and correctness review finds no unresolved blocking issues.
- The draft pull request records exact commands, results, and whether physical iPhone verification occurred.

## Epic completion

The Epic is complete when phases 1 through 9 are individually accepted, the editor and export consume the same deterministic Storyline snapshot, all destructive paths preserve the documented recovery contract, and the complete grammar has been validated on a physical iPhone. Phases 10 and 11 are separate follow-up product increments and do not block the core Epic.
