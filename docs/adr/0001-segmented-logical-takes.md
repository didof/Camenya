# ADR-0001: Model a Take as completed Segment files

Status: Accepted; Photos export consequence superseded by ADR-0004

## Context

Camenya must alternate front and rear cameras in one user-visible recording. Replacing a camera input while a movie-file output is actively recording is fragile, and the product permits flipping only while paused.

## Decision

Pause stops and validates the active Segment. Resume creates a new Segment. Flip changes the selected camera only when no Segment is active. Stop finalizes the ordered Segments into one movie, and only that movie is offered to Photos.

## Consequences

Capture transitions follow recording delegate callbacks. A manifest must preserve completed Segments. Finalization must handle concatenation, audio alignment, transforms, cleanup, and recovery. Internal files remain invisible to Photos.
