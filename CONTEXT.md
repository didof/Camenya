# Camenya domain glossary

## Camenya

The official project and product identity. Camenya is a local-first iPhone recording tool that helps one person assemble a story from multiple Takes and camera perspectives without uploading unfinished media. The name replaces the historical FlipCam codename.

## Local Signing Configuration

An untracked, machine-local plist containing the Apple Development Team, physical iPhone destination, and unique bundle identifier selected by the person building Camenya. It is input to a local build and never part of the Project, app data, repository, release artifacts, support logs, or contributor identity.

## Project

One ephemeral, local-only editable recording workspace. A Project owns an ordered collection of Takes and all supporting media, which never synchronize and are excluded from device and cloud backups. A Project never expires automatically: it remains available only inside the app until the user explicitly deletes the Project or an individual Take. Deleting a Project permanently deletes every Take and supporting media it owns. A Project may be exported as one final movie.

## Project Library

The collection of all Projects currently owned by the app. It is the user's entry point and orders Projects by their most recent modification.

## Take

One user-visible clip within a Project. A Take begins when Record is confirmed and ends when Stop completes its in-app finalization or the user discards it. A Take may contain several Segments.

## Original Range

The complete playable interval of a Take's finalized movie. It remains available and unchanged regardless of later cleanup decisions.

## Trim Suggestion

A proposed retained interval near the first and last sustained audio activity in a Take. It has no effect on playback or Project Export until the user reviews it.

## Take Selection

The retained interval that the user explicitly approves for a Take. A Take without a Take Selection uses its Original Range.

## Trim Review

The optional Project workflow in which the user compares a Trim Suggestion with the Original Range, adjusts its boundaries, and either approves a Take Selection or keeps the Original Range.

## Effective Duration

The duration used by Timeline playback and Project Export: the Take Selection's duration when one is approved, otherwise the Original Range's duration.

## Segment

One uninterrupted camera recording between Record/Resume and Pause/Stop. A Segment uses exactly one camera position and contains no paused time.

## Pause

A logical Take state in which no Segment is active. The preview remains live, the recording timer is frozen, and the user may edit the Project Note, Flip, Resume, or Stop.

## Flip

A change of the selected camera while no Segment is active. Repeated Flips during one Pause affect only which camera the next Segment uses.

## Finalization

The process that validates and orders a Take's Segments and produces exactly one in-app movie without paused time.

## Project Export

The explicit process that orders a Project's Takes and produces one final movie that may be saved to Photos. In-app Takes remain independent from the exported movie.

## Timeline

The single ordered collection of every Take currently owned by a Project. Every Take in the Timeline is included in Project Export; unwanted Takes are removed rather than hidden or disabled.

## Project Format

The portrait or landscape presentation shared by every Take in a Project and by its exported movie. The first Take establishes the Project Format; later Takes must match it.

## Project Name

The editable label used to distinguish a Project. A new Project receives a date-and-time-based name automatically, so naming never blocks recording.

## Project Note

One persistent, local-only block of text owned by a Project and available while recording its Takes. It is never part of captured or exported media.

## Take Deletion

The explicit, permanent removal of one Take and its supporting media from a Project. The user is shown the Take's duration and storage impact and must confirm the destructive action.

## Project Deletion

The explicit, permanent removal of a Project and every Take and supporting media it owns. Before deletion, the user is shown the number of Takes and storage that will be removed and must confirm the destructive action. There is no Recently Deleted state or automatic expiration.

## Recovery

Reconstructing and finalizing an unfinished Take from its persisted manifest and valid completed Segments within the Project that owns it. Legacy recoverable Takes without a Project are adopted by a Project named Recovered.

## Caption Configuration

The Project-owned explicit transcription locale plus shared visual style and normalized placement inherited by its captions.

## Caption Track

The Take-owned, non-destructive collection of timed Caption Cues produced from one Effective Range and then reviewed by the user. A Caption Track may need review, be approved, or become stale.

## Caption Cue

One editable, optionally enabled text interval within a Caption Track. It preserves recognized text, alternatives, confidence, and only the timing granularity actually supplied by recognition or review.

## Stale Caption Track

A Caption Track whose source Effective Range or Project locale no longer matches current Project metadata. Stale captions remain recoverable for review but cannot enter preview approval or Project Export.

## Captioned Export

A Project Export whose immutable export snapshot contains approved Caption Tracks and renders them into the finalized movie.

## Note

Deprecated term for Project Note.
