# Captions review UX increment

## Goal

Make the iPhone path from transcription to approved export obvious and efficient without changing caption recognition, source media, or export semantics.

## Primary path

Open Takes → identify caption state → transcribe or edit → review uncertain phrases → preview → approve → export.

## Scope

- Show a plain caption status on every Take.
- Keep the active phrase visibly selected and scroll it into view during playback.
- Keep video, playback, and preview settings fixed while only the transcript scrolls.
- Let a tap on a phrase seek playback to that phrase.
- Offer a direct next-uncertain action when low-confidence phrases remain.
- Keep routine review compact; disclose timing and recognition alternatives per phrase.
- Replace the unlabeled inclusion switch with an explicit action.
- Warn before dismissing edits that were neither saved nor approved.
- Improve hierarchy in the Take-list project actions without hiding Captions or Export.
- Keep the exported background fitted to the actual phrase and map Top/Center/Bottom consistently between SwiftUI and Core Animation coordinates.

## Non-goals

- No new caption styles, font controls, freeform positioning, or synthetic word timing.
- No recognition or export-model changes.
- No physical-device claims before the exact build is tested on iPhone.

## Verification

- State-level tests for dirty tracking and uncertain-phrase navigation.
- Existing caption-focused tests and the full iOS Simulator suite.
- Generic iOS Simulator build and `git diff --check`.
- Manual iPhone check for density, keyboard behavior, auto-scroll, overlay placement, and export.
