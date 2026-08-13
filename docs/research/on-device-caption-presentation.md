# On-device caption accuracy, presentation, and export overlays

Date: 2026-08-12
Scope: primary-source evaluation of recognition quality signals, spoken-word highlighting, placement, and overlay/export choices. This note makes no product-code change and records no physical-device result.

## Conclusion

Camenya has enough public API surface to propose editable captions, display a time-synchronized review overlay, and burn an approved overlay into the existing Project Export. It does **not** yet have caption product code, an empirical accuracy baseline, a chosen visual style, or physical iPhone verification.

The important precision boundary is that Speech supplies recognized units and associated timing, not a promise of perfectly aligned words. On iOS 18, an `SFTranscriptionSegment` may be a word **or a group of words**. On iOS 26, `SpeechTranscriber` can attach audio time ranges and confidence to ranges of attributed text, but the inspected interface does not promise one timed range per lexical word. Camenya can therefore highlight the currently timed recognized unit; it should call the effect “current word” only when the stored timing is actually word-granular. It should never manufacture apparent word accuracy by evenly dividing a multiword segment.

For presentation, one Take-owned cue/token model should drive three separate outputs:

1. a non-destructive SwiftUI/Core Animation overlay during review;
2. a burned-in Project Export overlay, rendered on the video timeline;
3. optionally, a selectable timed-text track for compatible players.

An in-app overlay and a burned-in overlay are not alternate sources of truth. They are two renderers of the same immutable export snapshot. A selectable track is a separate deliverable with different styling and interoperability limits.

## Current Camenya state

No caption data or presentation exists in the product code. The current immutable `ProjectExportPlan` snapshots only source URLs, Take selections, and Project format [R1, lines 6–35]. `ProjectExporter` assembles selected video/audio ranges and assigns one normalized `AVMutableVideoComposition` to an `AVAssetExportSession`, but it has no caption snapshot, layer tree, caption track, or animation tool [R1, lines 71–143 and 186–229].

Take review currently displays a bare `AVPlayerLayer` inside an aspect-fit SwiftUI view. Its controller reports player time every 0.1 seconds and handles seeking/range boundaries, but no overlay consumes that time [R2, lines 16–23, 54–119, and 204–222]. Timeline review uses a bare `AVQueuePlayer` and has no global timeline clock or overlay state [R3, lines 27–34 and 56–151].

Consequently, every accuracy, animation, placement, and overlay behavior below is either an API capability or a recommendation. None is implemented or device-verified.

## 1. Transcription accuracy: what can and cannot be known

### iOS 18 `SFSpeechRecognizer`

The legacy API exposes useful review signals:

- a best transcription and an ordered list of alternative transcriptions;
- a finality flag, after which a result no longer changes;
- ordered transcription segments;
- for each segment, text, alternative substrings, timestamp, duration, and a `0...1` confidence value [S1, lines 14–43; S2, lines 12–38; S3, lines 12–65].

These are confidence and alternative hypotheses, not a measured word-error rate for a Camenya recording. Apple explicitly describes a transcription as only a potential version that may be inaccurate [S2, lines 12–24]. The request header also says that requiring on-device recognition prevents network use only when the recognizer supports it, and explicitly warns that on-device requests will not be as accurate [S4, lines 56–64]. There is no public API in the inspected headers that reports an expected overall accuracy percentage, calibrates confidence across languages, or proves that confidence `0.8` means an 80% chance of correctness.

Accuracy can be influenced, but not guaranteed:

- `contextualStrings` accepts up to 100 short app/domain phrases and says these improve the likelihood that unusual terms are recognized;
- `taskHint` identifies the recognition task type;
- automatic punctuation can be requested;
- an optional custom language-model configuration exists from iOS 17 [S4, lines 23–73].

The same installed header still tells clients to plan around approximately one-minute recognition tasks [S5, lines 65–72]. Long Takes therefore need chunking, overlap/reconciliation, and timestamp rebasing; chunk boundaries themselves can affect recognition context and must be evaluated.

### iOS 26 `SpeechAnalyzer` / `SpeechTranscriber`

`SpeechTranscriber` exposes presets for normal, alternative-bearing, time-indexed, progressive, and time-indexed progressive transcription. Its reporting options include volatile results, alternatives, and fast results; attribute options include audio time range and transcription confidence [S6, lines 407–473]. Each result carries a result time range, finalization time, attributed text, and alternative attributed strings [S6, lines 492–510].

When requested, the attributed string can contain a `Double` confidence attribute and a `CMTimeRange` audio-time attribute. A helper maps an intersecting audio time range back to a range in the attributed string [S6, lines 177–218]. This is materially better suited to timed review than plain cue text.

However, the public Swift interface does not state:

- a guaranteed token/word granularity for those attributes;
- a calibrated interpretation for confidence;
- a guaranteed alternative for every text range;
- any accuracy score comparable across locale, device, audio quality, or OS release.

The iOS 26 route is therefore richer, not authoritative.

### Product recommendation

Treat recognition as an editable proposal:

- Persist the chosen hypothesis and its original timed units, alternatives, confidence, locale, recognizer generation, and whether each text span was user-edited.
- Use confidence only to prioritize review, for example by marking low-confidence spans. Do not show a project-level “accuracy percentage” unless Camenya later computes it against corrected ground truth.
- Offer alternatives as replacement suggestions where the recognizer actually supplied them.
- After a user correction, the user's text is authoritative. Recognition confidence should no longer be presented as confidence in that edited text.
- Keep punctuation reviewable. Automatic punctuation is also recognition output, not ground truth.
- Preserve a hard local-only unavailable/error state. Never improve apparent accuracy by silently retrying in the cloud.

### Required physical verification

No source inspected provides Camenya-specific quality data. A physical iPhone evaluation set should include Italian and any supported launch languages, quiet/noisy rooms, near/far speech, fast speech, pauses, proper names, numbers, mixed-language phrases, portrait/landscape capture, long Takes crossing chunk boundaries, and edited text. Record word error and timing error against manually corrected ground truth; simulator compilation cannot substitute for this.

## 2. Highlighting or animating the currently spoken word

### API capability

Playback can be synchronized in two public ways:

- `AVPlayer` periodic observers report player-timeline time for UI updates, although Apple may invoke them less often than requested for very short intervals. Boundary observers fire when specified times are traversed; both kinds must be explicitly removed [S7, lines 427–475].
- `AVSynchronizedLayer` synchronizes a Core Animation subtree to an `AVPlayerItem` timeline, including documented animation timing behavior [S8, lines 12–79]. Apple separately directs clients to `AVSynchronizedLayer` for real-time playback, while `AVVideoCompositionCoreAnimationTool` is for offline rendering [S9, lines 768–780].

The current Take player already reports playback time at a requested 0.1-second interval [R2, lines 69–100]. That is enough for a basic active-unit highlight, but it is not frame-accurate and does not yet exist in Timeline review.

For selectable captions, `AVCaption` can carry a built-in `characterReveal` animation and describes caption cues as capable of dynamic presentation. The public animation enum exposed here is only `none` or `characterReveal` [S10, lines 348–368 and 824–826]. `AVMutableCaption` also supports static text/background color and font styling over UTF-16 ranges [S10, lines 565–687 and 689–801]. The inspected API does not expose a direct “highlight this word from time A to B inside one cue” property.

### Precision limitation

On iOS 18, `SFTranscriptionSegment` represents an utterance that may be a vocalized word **or group of words** [S3, lines 12–24]. Its timestamp and duration apply to that entire recognized segment [S3, lines 41–53]. Therefore:

- a one-word segment can drive a genuine current-word interval;
- a multiword segment can drive only a genuine current-segment interval;
- dividing a multiword duration evenly among its words is an animation heuristic, not speech alignment, and should not be shipped as if accurate.

On iOS 26, attributed audio-time ranges can drive finer highlights when the returned attribute runs are word-granular. The product must inspect and preserve the actual ranges instead of assuming that they are.

Edits create a second timing problem. Replacing one timed token can reasonably inherit its interval, but inserting, deleting, splitting, or merging words changes alignment. The app needs an explicit rule: retain timing only for spans whose mapping remains known; otherwise mark word timing as needing adjustment and fall back to cue/segment highlighting. Silent interpolation would make review look more precise than the data.

### Product recommendation

Use one deterministic active-span resolver over stored rational media times:

1. Rebase Take-relative timed spans through the approved Take selection and Timeline offset.
2. At playback time, binary-search the active cue and then its actual timed span.
3. Highlight a word only for a one-word/timed text range; otherwise highlight the recognized phrase or the whole cue.
4. Recompute immediately after seeks and Take changes, not only on the next periodic callback.
5. Respect Reduce Motion by changing emphasis without scale/bounce animation.

For the initial increment, a color/weight/background change is more predictable than kinetic word movement. The same time schedule can drive a SwiftUI review overlay and timeline-based Core Animation during export. The selectable-track `characterReveal` effect is not an equivalent rendering and should not define the Camenya look.

### Required physical verification

Test play, pause, seek forward/backward, rapid scrubbing, replay, Take boundaries, trimmed starts, queue transitions, AirPlay/external playback if supported, different playback rates if exposed, interruptions, and Reduce Motion. Compare the review overlay against the burned-in file on the physical iPhone. “Looks synchronized in the simulator” is not physical verification.

## 3. Caption positioning, regions, and safe areas

### Selectable-track capability

`AVCaption` uses caption regions. Geometry can be expressed in cells or percentages relative to an enclosing rectangle [S10, lines 22–93]. `AVCaptionRegion` exposes origin, size, scroll mode, display alignment, and writing mode; predefined top, bottom, left, right, and SRT-bottom regions also exist [S10, lines 95–257]. `AVMutableCaptionRegion` exposes mutable origin, size, scroll, display alignment, and writing mode [S10, lines 289–346], while each mutable caption can select a region and text alignment [S10, lines 665–683 and 803–825].

This permits per-cue region metadata. It does **not** create a Camenya- or social-platform-safe area automatically. The inspected caption APIs contain no semantic “keep clear of home indicator, controls, faces, or social app chrome” property. Their percentages describe caption-format geometry, not SwiftUI safe-area insets or downstream-app overlays.

### Review overlay capability

The actual visible video may not equal the containing view because of aspect fit/fill. `AVPlayerLayer.videoGravity` controls that mapping, and `videoRect` exposes the displayed video's current size and position inside the layer [S11, lines 71–94]. Camenya currently uses `.resizeAspect` [R2, lines 204–216]. A review overlay must therefore lay itself out relative to the video rectangle, not blindly relative to the entire SwiftUI view, or captions can land in letterbox space.

### Burned-in export capability

The current exporter already normalizes every source into a fixed 1080×1920 or 1920×1080 render canvas and uses aspect-fill transforms [R1, lines 186–229]. Burned-in captions should be positioned in that render coordinate space. Preview should map the same normalized caption coordinates into `AVPlayerLayer.videoRect` so review and export agree.

There are two different “safe” concepts:

- **App UI safe area:** protects controls from device cutouts/home indicator; it is irrelevant to pixels in an exported movie.
- **Video/content safe zone:** a product-defined inset/guide inside the export canvas to keep captions away from edges, subject matter, and likely downstream controls. Apple APIs inspected here do not choose this zone for Camenya.

### Product recommendation

Persist layout in normalized video coordinates rather than screen points. Start with a small Project-level style and placement system—such as lower, center, and upper zones—inside a visible content-safe guide. Keep line count, maximum width, wrapping, text alignment, and edge padding deterministic for both orientations.

Per-cue placement is technically possible and useful when text would cover a face or important content. Prefer a constrained vertical-zone override per cue over arbitrary free dragging in the first increment. It is easier to review, accessible without drag-only controls, and less likely to make captions jump unpredictably. If a cue has no override, it inherits the Project placement.

Do not confuse SwiftUI safe-area insets with export placement, and do not hard-code preview points into persisted metadata. The exact default inset and vertical zone require visual/device validation; this research does not assert a universal social-platform-safe percentage.

### Required physical verification

Verify portrait and landscape projects, long/short text, two-line wrapping, large accessibility text in the editor, right-to-left and non-Latin text for supported locales, near-edge placement, all current source transforms/crops, and the final Photos playback result. If selectable captions are offered, validate how the chosen container/codec preserves region and styling on physical-device playback and through intended sharing destinations.

## 4. What “overlay” can mean

### A. Non-destructive review overlay

A SwiftUI text overlay over `PlayerLayerView`, driven by player time, is the simplest editable preview. It never touches Take media. For stronger timeline synchronization or a shared animation schedule, an `AVSynchronizedLayer` subtree can sit over the player. Either approach must use the actual displayed `videoRect` and Take/Timeline time rebasing.

This is the right interaction layer for Original/Captioned review, low-confidence markers, selection, editing, and current-span emphasis. It is not part of the exported file by itself.

### B. Burned-in export overlay

`AVVideoCompositionCoreAnimationTool` composites a Core Animation layer tree with video during offline rendering through `AVAssetExportSession` or `AVAssetReader`. Its animations run on the video timeline, not wall-clock time, and the header documents the required nonzero begin time and non-removal behavior [S9, lines 768–834]. This fits the current exporter because it already creates and assigns a video composition [R1, lines 136–143 and 186–208].

Burn-in makes captions visible in every downstream player because they become video pixels. The tradeoffs are permanent styling, a full render, no viewer toggle, no selectable text, and the need to ensure review/export renderer parity. Export must attach the overlay to the immutable caption snapshot, not mutable live editor state.

The repository engineering rules currently list Swift, SwiftUI, AVFoundation, PhotoKit, and OSLog only. `AVVideoCompositionCoreAnimationTool` is an AVFoundation API but consumes `CALayer`/Core Animation types. Before implementation, record whether this standard AVFoundation integration is accepted under that constraint; otherwise there is no equally direct burn-in mechanism in the currently permitted framework set identified by this research.

### C. Selectable timed-text track

On iOS 18, `AVAssetWriterInputCaptionAdaptor` appends `AVCaption` or caption groups to a text or closed-caption writer input. Caption start times must be monotonic and durations numeric; groups add additional non-overlap ordering requirements [S12, lines 806–859]. This preserves captions as timed metadata rather than pixels and lets compatible players toggle them.

This path is not a visual overlay renderer. It requires an `AVAssetWriter` path and a selected caption format, and format support determines which regions, characters, styling, and animation survive. For example, the `AVCaption` header documents format-specific restrictions and says Apple iTT does not allow overlapping captions in one region [S10, lines 372–426]. It also documents that some style properties are ignored or restricted by iTT/CEA-608 [S10, lines 565–663].

Selectable captions therefore should not be assumed to reproduce Camenya's burned-in design or current-word highlight. They are an accessibility/interoperability deliverable requiring separate tests.

### Recommended first product boundary

For the first caption PR after the prerequisite gate opens:

- Store one non-destructive, editable timed cue/span model.
- Build an Original/Captioned review overlay from that model.
- Use a modest, project-level style and constrained placement with optional per-cue zone override only if included in acceptance scope.
- Burn the approved snapshot into the sole finalized Project Export.
- Treat active-word styling as best-effort based on real timing granularity, with cue/segment fallback.
- Defer selectable tracks and external SRT/VTT unless explicitly scoped as a separately testable increment.

This keeps the user-visible promise honest: readable, reviewable captions that survive sharing, without claiming timing or transcription precision the APIs do not guarantee.

## Capability, recommendation, and verification status

| Topic | Public API capability | Product recommendation | Verified on physical iPhone? |
|---|---|---|---|
| Recognition quality | Alternatives, confidence, finality, timed units; richer attributed ranges on iOS 26 | Show uncertain spans and require correction/approval; no synthetic accuracy percentage | No |
| Current-word effect | Player-time synchronization; word/segment timing when supplied; Core Animation timelines | Highlight only genuinely timed spans; fall back to segment/cue after coarse timing or disruptive edits | No |
| Placement | Caption regions; displayed `videoRect`; fixed export canvas | Normalized content-safe zones, Project default, constrained per-cue override | No |
| Review overlay | SwiftUI/player-time or `AVSynchronizedLayer` | Non-destructive Original/Captioned preview from shared cue data | No |
| Burn-in | Offline `AVVideoCompositionCoreAnimationTool` composition | Default finalized export for predictable visibility | No |
| Selectable track | `AVCaption` plus caption writer adaptor | Separate advanced deliverable; do not promise style/highlight parity | No |

## Primary sources inspected

All SDK paths are under:

`/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.2.sdk/`

- **S1 — recognition results and alternatives:** `System/Library/Frameworks/Speech.framework/Headers/SFSpeechRecognitionResult.h`
- **S2 — transcription status and segments:** `System/Library/Frameworks/Speech.framework/Headers/SFTranscription.h`
- **S3 — legacy recognized-unit timing, confidence, and alternatives:** `System/Library/Frameworks/Speech.framework/Headers/SFTranscriptionSegment.h`
- **S4 — legacy request accuracy controls and local-only warning:** `System/Library/Frameworks/Speech.framework/Headers/SFSpeechRecognitionRequest.h`
- **S5 — legacy duration/failure guidance:** `System/Library/Frameworks/Speech.framework/Headers/SFSpeechRecognizer.h`
- **S6 — iOS 26 transcriber presets/results/attributes:** `System/Library/Frameworks/Speech.framework/Modules/Speech.swiftmodule/arm64e-apple-ios.swiftinterface`
- **S7 — player time observers:** `System/Library/Frameworks/AVFoundation.framework/Headers/AVPlayer.h`
- **S8 — playback-synchronized animation layers:** `System/Library/Frameworks/AVFoundation.framework/Headers/AVSynchronizedLayer.h`
- **S9 — offline Core Animation video composition:** `System/Library/Frameworks/AVFoundation.framework/Headers/AVVideoComposition.h`
- **S10 — caption cue timing, regions, styles, and animation:** `System/Library/Frameworks/AVFoundation.framework/Headers/AVCaption.h`
- **S11 — displayed video geometry:** `System/Library/Frameworks/AVFoundation.framework/Headers/AVPlayerLayer.h`
- **S12 — selectable caption writing:** `System/Library/Frameworks/AVFoundation.framework/Headers/AVAssetWriterInput.h`

## Repository sources inspected

- **R1 — current immutable export plan and normalized export:** [`Camenya/Projects/ProjectExporter.swift`](../../Camenya/Projects/ProjectExporter.swift)
- **R2 — current Take playback and player layer:** [`Camenya/UI/TakeReviewScreen.swift`](../../Camenya/UI/TakeReviewScreen.swift)
- **R3 — current Timeline queue playback:** [`Camenya/UI/TimelineReviewScreen.swift`](../../Camenya/UI/TimelineReviewScreen.swift)

## Decision-ready summary

Camenya can ship a polished caption overlay, but the honest promise is “reviewable timed captions with best-effort active-span emphasis,” not guaranteed perfect transcription or word alignment. Use normalized placement and one shared renderer-independent cue model; preview it non-destructively, snapshot it for export, and burn it into the video by default. Keep selectable captions and format-specific styling as a separate interoperability feature. No accuracy, synchronization, layout, or export claim is physically verified until the exact caption PR build is tested on the iPhone.
