# Adopt a non-destructive Primary Storyline

Camenya remains a narrative recorder rather than becoming a general mobile video editor, but arranging a spoken story requires more than treating every Take as one indivisible Timeline row. A finalized Take is therefore an immutable recording source, while each Timeline Clip is an independently editable occurrence in one Primary Storyline; trim, split, reorder, remove, and mute change occurrence metadata, and preview and Project Export consume the same immutable Storyline snapshot.

## Considered options

- Keep one Take equal to one Timeline item. This preserves the current model but makes Split ambiguous and turns removal into source deletion.
- Build a general multitrack editor. This supports more creator workflows but conflicts with Camenya's capture-first purpose and multiplies timing, recovery, accessibility, and export complexity.
- Use one bounded Primary Storyline with timed presentation layers. This supports narrative editing while keeping one global clock and a clear product ceiling.

## Consequences

The Project may own Takes that are not currently used, and removing a Timeline Clip does not delete its Take. Split partitions one Clip's Available Range into two adjacent Clips without rendering or copying media. Caption Tracks remain Take-owned and source-relative, while Clip selection projects them into Project Time. Music, arbitrary media tracks, speed controls, transition catalogs, keyframes, and imported video remain outside the initial model.

This decision supersedes ADR 0004 only where that ADR equates Project Export order with every owned Take, and ADR 0006 only where it assigns an approved selection directly to a Take. The separate export boundary, immutable source, and metadata-only editing guarantees remain in force. It clarifies ADR 0007 by separating a Take-owned Caption Track from its per-Clip projection into Project Time.
