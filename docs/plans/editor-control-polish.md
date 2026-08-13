# Editor control polish

## Goal

Keep the Take drawer compact while making caption regeneration and Silence Trim state explicit.

## Interaction model

- `Clean Edges` is a menu with distinct Analyze and Review verbs.
- `Captions` is a menu with distinct Review and Settings verbs.
- Each Take's overflow menu uses its current state to name the next action, for example Analyze Silence, Review Silence Trim, Create Captions, or Regenerate Captions.
- Caption Settings owns project-wide language and placement.
- Applying settings transcribes only missing or outdated Takes. Regenerate All deliberately replaces every caption track.
- Any operation that replaces caption text, timing, or corrections requires confirmation and reiterates that recorded media is unchanged.

## Verification

- Pure selection tests cover normal versus full regeneration.
- Presentation tests cover state-specific labels.
- Coordinator tests cover per-Take caption routing.
- Run the complete iOS Simulator suite and required generic build.
- Verify language change, full regeneration, per-Take routing, and export on the physical iPhone.
