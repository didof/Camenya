# HDR Video Capture Follow-up

## Status

Deferred to a separate pull request after the Project Workspace and adaptive capture-quality increment is merged and accepted on a physical iPhone. Record the exact prerequisite pull request and commit before starting dependent implementation.

## Current boundary

The Project Workspace redesign preserves Camenya's predictable SDR/Rec.709 capture, caption rendering, and Project Export behavior. It does not claim HDR video capture or visual parity with Apple's private Camera processing pipeline.

## Why HDR is separate

Correct HDR support changes more than one camera switch. It requires a coherent contract for:

- stabilization-capable device-format selection;
- HEVC encoding and HLG/BT.2020 color metadata;
- one Project-owned dynamic-range policy across every Take and Segment;
- front/rear camera compatibility after Flip;
- pause/resume finalization across compatible media formats;
- HDR preview, thumbnail generation, and caption compositing;
- Project Export metadata and color preservation;
- Photos playback and SDR display fallback;
- cancellation, recovery, and unsupported-device behavior.

## Required decisions

- Whether HDR is automatic, optional, or fixed when a Project is created.
- Whether Project Format expands into a broader Project Capture Profile.
- How an HDR Project behaves when the requested camera or format cannot preserve that profile.
- Whether export remains HDR-only or offers an explicit SDR conversion.

## Required verification

- Deterministic tests for Project metadata, format compatibility, export planning, and caption composition decisions.
- Generic iOS Simulator build and the repository verification required by `AGENTS.md`.
- Physical-iPhone capture with the exact accepted commit, covering front and rear cameras, Pause/Resume, Flip, stabilization, captions, Project Export, Photos playback, an SDR display path, thermal behavior, and interruption recovery.
- No physical capture, HDR appearance, or Camera-app parity claim based on Simulator results.
