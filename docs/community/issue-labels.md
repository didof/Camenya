# Issue labels and contribution paths

Labels describe scope and readiness; they are not roadmap promises. An issue normally receives one `type:`, one or more `area:`, and—when needed—one `status:` or governance label.

## `good first issue`

Maintainers add `good first issue` only after an idea has:

- an accepted user outcome and explicit non-goals;
- a small implementation surface with named files or seams;
- deterministic acceptance criteria;
- no unresolved product, privacy, media-recovery, or distribution decision;
- no requirement for private Apple identity;
- either no physical-device requirement or an explicitly arranged maintainer verification step.

The label means “well bounded for a newcomer,” not “unimportant.” A feature name by itself is never sufficient.

## Candidate feature tracks

### Flash control

Start with capability discovery and an explicit state model for unavailable hardware, front-camera selection, interruptions, and capture-session errors. Torch mutations must remain serialized with other capture-session operations. A pure capability/model increment may become a good first issue; physical behavior requires the `physical iPhone required` label.

### Teleprompter

Keep script text local and define whether it belongs to a Project or only to the current recording session. The first increment should cover read-only presentation and recording-state interaction without networking, accounts, script generation, or captured overlays. This needs design before implementation.

### Caption style customization

Add one bounded, accessible preset at a time and keep preview and burn-in driven by the same immutable style model. Deterministic layout and timeline tests are required. A single preset or isolated model test can be newcomer-friendly after the rendering contract is documented.

### Overlays

Define the media source, ownership, persistence, preview/export parity, and failure recovery before UI work. Importing arbitrary Photos would change the permission boundary and is therefore a protected change. A first track should use project-owned text or generated shapes and no new permission.

## Applying the labels

The canonical names, colors, and descriptions live in `.github/labels.yml`. Create or update the matching labels in GitHub before public launch, then protect their meaning during triage. Do not use `good first issue` merely to advertise a large desired feature.
