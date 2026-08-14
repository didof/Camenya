# Camenya domain glossary

## Product

**Camenya**:
A local-first iPhone narrative recorder that helps one person construct a story from multiple recordings and camera perspectives without uploading unfinished media.

**Project**:
One local-only recording workspace that owns its Takes, Primary Storyline, caption configuration, and supporting media. A Project remains available until explicitly deleted and may produce one finished movie through Project Export.

**Project Library**:
The collection of all Projects currently owned by the app, ordered by most recent modification.

**Project Format**:
The portrait or landscape presentation shared by every Take, Storyline Item, and exported movie in one Project.

**Project Name**:
The editable label used to distinguish a Project. A new Project receives a date-and-time-based name automatically.

**Project Note**:
One persistent, local-only block of text owned by a Project and available while recording its Takes. It is never part of captured or exported media.
_Avoid_: Note

## Recorded sources

**Take**:
One finalized, immutable recording source owned by a Project. A Take begins when Record is confirmed, ends when Stop completes finalization, and may contain several Segments.
_Avoid_: Clip, Timeline item

**Source Range**:
The complete playable interval of a finalized Take. It remains unchanged by Storyline editing.
_Avoid_: Original Range, Effective Range

**Segment**:
One uninterrupted camera recording between Record or Resume and Pause or Stop. A Segment uses exactly one camera position and contains no paused time.

**Pause**:
A Take state in which no Segment is active. The preview remains live, the recording timer is frozen, and the user may edit the Project Note, Flip, Resume, or Stop.

**Flip**:
A change of the selected camera while no Segment is active. Repeated Flips during one Pause affect only which camera the next Segment uses.

**Finalization**:
The process that validates and orders a Take's Segments and produces exactly one immutable in-app movie without paused time.

**Recovery**:
Reconstructing and finalizing an unfinished Take from its valid completed Segments within the Project that owns it.

**Unused Take**:
A recoverable Take that is not referenced by any active Timeline Clip. It may still be referenced by Removed Clips and remains owned by its Project until added to the Primary Storyline or safely deleted.

## Storyline editing

**Primary Storyline**:
The single ordered sequence of Storyline Items that defines the Project's video narrative and duration. Items meet with hard cuts and share one Project Time.
_Avoid_: Video track, multitrack timeline

**Storyline Item**:
One ordered, duration-bearing member of the Primary Storyline. Timeline Clip is the initial type; Title Card is an accepted post-core type.

**Timeline Clip**:
One editable occurrence of a Take in the Primary Storyline. It has its own Available Range, Clip Selection, mute state, and Storyline position while leaving the referenced Take unchanged.
_Avoid_: Take

**Available Range**:
The recoverable source-time bounds assigned to one Timeline Clip. Reset Trim restores the Clip Selection to these bounds rather than to the whole Take.

**Clip Selection**:
The interval within a Timeline Clip's Available Range that currently contributes picture, duration, and optionally source audio to the Primary Storyline.
_Avoid_: Take Selection, Effective Range

**Project Time**:
The shared clock produced by the ordered durations of the Primary Storyline. Timed presentation and Project Export are evaluated against this clock.

**Timeline**:
The time-based editor and visual representation of the Primary Storyline.
_Avoid_: Take list

**Playhead**:
The current Project Time used for seeking, preview, and time-based editing actions.

**Split**:
An edit that replaces one Timeline Clip with two adjacent Timeline Clips at the Playhead while preserving the immediate output and the recoverable outer ranges of both results.

**Removed Clip**:
A recoverable Timeline Clip excluded from the Primary Storyline while retaining its Take reference, ranges, mute state, and prior placement context.

**Removed Clip Deletion**:
The explicit, permanent discard of one Removed Clip's edit metadata. It does not delete its Take, but may remove the final reference that prevents an Unused Take from being deleted.

**Mute**:
A Timeline Clip state that excludes its source audio without changing its picture or Take.

**Session Edit History**:
The reversible sequence of Timeline edits available during the current editing session. It is not durable recovery storage.

**Trim Suggestion**:
A proposed Clip Selection derived from audio activity within a Timeline Clip's Available Range. It does not affect playback or Project Export until approved.

**Trim Review**:
The optional workflow in which the user compares a Trim Suggestion with a Timeline Clip's Available Range and approves or adjusts its Clip Selection.

**Title Card**:
A Storyline Item that presents text for an explicit duration without referencing a Take.

**Text Overlay**:
A timed text element attached to one Timeline Clip and positioned within the Project's safe presentation region.

## Captions

**Caption Configuration**:
The Project-owned transcription locale plus shared visual style and normalized placement inherited by its captions.

**Caption Track**:
The Take-owned, source-relative collection of timed Caption Cues. Text corrections are shared by every Timeline Clip that references the Take.

**Caption Cue**:
One editable, optionally enabled text interval within a Caption Track. It preserves recognized text, alternatives, confidence, and only the timing granularity supplied by recognition or review.

**Caption Projection**:
The portion of a Take's Caption Track that maps through a Timeline Clip's Clip Selection into Project Time.

**Caption Timeline Issue**:
A review requirement created when a structural Storyline edit makes a Caption Cue semantically unsafe to project. The affected caption stays out of export until explicitly reapproved.

**Stale Caption Track**:
A Caption Track whose Take source or Project locale no longer matches current Project metadata. It remains recoverable for review but cannot enter approved preview or Project Export.

## Export and deletion

**Project Export**:
The explicit process that renders one immutable snapshot of the Primary Storyline into a finished movie that may be saved to Photos. In-app Takes remain independent from the exported movie.

**Export Snapshot**:
The fixed Storyline, media ranges, mute states, and approved timed presentation used by one Project Export.

**Take Deletion**:
The explicit, permanent removal of one Unused Take and its supporting media from a Project. A Take referenced by any active or Removed Clip cannot be deleted independently.

**Project Deletion**:
The explicit, permanent removal of a Project and every Take, Storyline Item, caption, and supporting media it owns. It is the only operation that may cascade through referenced Takes.

## Development support

**Local Signing Configuration**:
An untracked, machine-local plist containing the Apple Development Team, physical iPhone destination, and unique bundle identifier selected by the person building Camenya. It is never part of app data, the repository, release artifacts, support logs, or contributor identity.
