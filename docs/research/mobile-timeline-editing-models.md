# Mobile timeline editing models for Camenya

Date: 2026-08-14
Scope: primary-source comparison of phone-first video editors and a product-model recommendation for Camenya. This note does not change product code, the domain glossary, ADRs, or GitHub issues. No editor was inspected interactively and no physical-device behavior is claimed.

Decision status: this research supplied evidence for the later accepted product decision. ADR 0008 and `docs/epics/primary-storyline.md` are authoritative where they narrow its recommendations. In particular, music is entirely outside the initial architecture, and Title Cards and bounded text overlays are separate post-core increments.

## Conclusion

Camenya should not copy TikTok or Instagram screen-for-screen, and it should not become a reduced iMovie. It should adopt a **capture-first, clip-based primary storyline with bounded timed layers**:

1. one ordered primary storyline of video clips;
2. direct, non-destructive operations on a selected clip: trim, split, reorder, remove, mute, and later duplicate;
3. a global Project playhead and zoomable time scale;
4. focused, constrained editing modes for captions and later simple text/title presentation;
5. hard cuts as the default and only transition in the first editing increment;
6. one immutable edit snapshot shared by Timeline preview and Project Export.

The decisive domain consequence is that a **Take can no longer also mean one Timeline item**. A Take is the immutable recorded source produced from one recording session; a Timeline Clip is an editable occurrence that references a range of that source. Splitting at the playhead should atomically replace one Timeline Clip with two adjacent occurrences referencing the same Take media. It should not render two new movies or duplicate bytes.

This is an inference from the documented product patterns below, combined with Camenya's existing local-first and media-preservation invariants. It is not a claim that any competitor exposes the same internal data model.

## Method and evidence boundary

Only first-party product help, user guides, and dated official feature announcements were used for competitor behavior. An announcement establishes what its owner documented at that date, not universal current availability; current help was preferred where available. General marketing language was not treated as proof of an editing operation. Where official documentation does not describe persistence, file ownership, or implementation, this note records that as unknown rather than inferring internals.

The comparison is about conceptual patterns and supported operations, not visual imitation. Feature availability may vary by app version, account, locale, or rollout; the linked documentation was checked on 2026-08-14.

## Current Camenya model and the pressure created by Split

Camenya currently defines a Take as both one recording and one user-visible clip. A Take can contain multiple camera Segments, but finalization composes those Segments into one immutable in-app movie. The Timeline is the ordered collection of every Take, and every Take is exported; removal means permanent Take deletion ([domain glossary](../../CONTEXT.md), [ADR 0004](../adr/0004-separate-take-finalization-from-project-export.md)).

Current editing is correspondingly Take-oriented:

- the manifest stores an ordered `[ProjectTake]`, with at most one effective range and one caption track per Take ([ProjectModels.swift](../../Camenya/Projects/ProjectModels.swift));
- the list can reorder and permanently delete Takes, while Silence Trim changes only retained-range metadata ([ProjectStore.swift](../../Camenya/Projects/ProjectStore.swift), [TakeListScreen.swift](../../Camenya/UI/TakeListScreen.swift));
- Timeline review queues one player item per Take and explicitly promises hard cuts, but has no global playhead, filmstrip, or editing surface ([TimelineReviewScreen.swift](../../Camenya/UI/TimelineReviewScreen.swift));
- export inserts each Take's selected source range in order, then applies the Project video composition and approved captions ([ProjectExporter.swift](../../Camenya/Projects/ProjectExporter.swift));
- the Original Range remains recoverable because trimming is metadata, not a rewritten movie ([ADR 0006](../adr/0006-preserve-takes-and-trim-through-metadata.md)).

An in-place `Take -> two Takes` operation would overload identity and ownership. It would make it unclear whether the two results are new recordings, whether deleting one may delete shared media, and which object owns Take-relative captions and trim history. A separate Timeline Clip concept resolves those questions without weakening immutable-source recovery.

## Documented editor patterns

### Apple Clips: the closest capture-first analogue

Apple Clips starts from recording or adding clips directly into a video project. Its clip editor exposes trim, split, mute, delete, duplicate, effects, and saving a clip; a separate operation moves clips in the sequence ([make a video](https://support.apple.com/guide/clips/make-a-video-dev57f9eb69d/ios), [edit clips](https://support.apple.com/guide/clips/edit-clips-devf7e94c16a/ios), [save and delete clips](https://support.apple.com/guide/clips/save-and-delete-clips-dev48d597466/ios)).

Clips keeps several capabilities deliberately higher-level than a general track editor:

- music is Project-wide; songs and included soundtracks are automatically adjusted to the video's length, and the user can choose the song's starting section ([add soundtracks and songs](https://support.apple.com/guide/clips/add-soundtracks-and-songs-devccc194267/ios));
- Live Titles are generated from speech, can be restyled and text-corrected, and remain associated with a clip ([record with Live Titles](https://support.apple.com/guide/clips/record-with-live-titles-dev77e5e5619/ios));
- imported audio replacement is explicitly documented as not undoable ([import songs](https://support.apple.com/guide/clips/import-songs-devbb38367d4/ios)).

The useful pattern for Camenya is not Clips' visual design. It is the narrow editing grammar: capture creates clips, the main sequence stays understandable, selecting one clip reveals bounded actions, and global music does not require exposing a full multitrack mixer.

### iMovie on iPhone: the upper complexity boundary

iMovie's movie-project Timeline provides a primary sequence with a playhead. It supports moving, trimming, duplicating, splitting, and removing clips. Its documentation says duplication does not copy the media or consume additional device storage, and the duplicate can be edited independently. Splitting inserts a cut between the two results ([arrange video clips and photos](https://support.apple.com/guide/imovie-iphone/arrange-video-clips-and-photos-knac788312/ios)).

iMovie then adds capabilities that materially increase the editor's state space:

- per-boundary transitions with type and duration ([adjust transitions](https://support.apple.com/guide/imovie-iphone/adjust-transitions-kna737b471f/ios));
- multiple speed ranges inside one clip plus freeze frames ([adjust video speed](https://support.apple.com/guide/imovie-iphone/adjust-video-speed-kna47ca84b07/ios));
- cutaway, picture-in-picture, split-screen, and green/blue-screen overlay clips ([add video overlay effects](https://support.apple.com/guide/imovie-iphone/add-video-overlay-effects-kna831efee4d/ios));
- background music that loops to the Project length, multiple songs arranged serially, audio clips, volume, fade, and speed controls ([add music and soundtracks](https://support.apple.com/guide/imovie-iphone/add-music-and-soundtracks-kna257fc2a9/ios), [adjust audio](https://support.apple.com/guide/imovie-iphone/adjust-audio-knabf616edbf/ios));
- clip-attached titles with editable text, position, size, font, and color ([add titles](https://support.apple.com/guide/imovie-iphone/add-titles-kna14aaa4db/ios));
- undo and redo only up to the last time iMovie was opened ([add video clips and photos](https://support.apple.com/guide/imovie-iphone/add-video-clips-and-photos-knac787725/ios)).

iMovie establishes that a capable phone editor can use a playhead, trim handles, clip selection, a contextual inspector, and timeline zoom. It also shows why Camenya should define a lower ceiling: speed ranges, arbitrary video overlays, transition handles, and independently editable audio clips interact combinatorially with split, captions, Timeline duration, and export.

### TikTok: constrained direct manipulation, not a general NLE

TikTok's current official editing guide documents one ordered video track on which a selected clip can be trimmed, split at the playhead, and reordered by long-press/drag. Speed is a clip operation with an apply-to-all option; transitions are attached only at joins between two clips; text and photo/video overlays have time bounds and are positioned in the preview ([edit TikTok videos and photos](https://support.tiktok.com/en/using-tiktok/creating-videos/editing-tiktok-videos-and-photos)). TikTok's dated launch announcement corroborates stack, trim, split, sound duration, timed text, overlays, and per-clip speed ([TikTok Newsroom, 2022-10-06](https://newsroom.tiktok.com/editing-tools/?lang=en)).

Creator Captions are automatically transcribed, can be previewed and corrected line by line, and expose font style and color changes ([TikTok accessibility tools](https://support.tiktok.com/en/using-tiktok/creating-videos/accessibility)). By contrast, the inspected official sources do not document video-clip duplication, undo/history, source immutability, ripple behavior, or preview/export parity. TikTok also warns that drafts may disappear after uninstall/reinstall or moving to another device or account ([editing, posting, and deleting](https://support.tiktok.com/en/using-tiktok/creating-videos/editing-posting-and-deleting)).

The useful pattern is a primary ordered track plus a small number of shallow timed asset types. Camenya should borrow that bounded grammar, not TikTok's publishing workflow or undocumented recovery semantics.

### Instagram Reels: unified timing, with deeper editing moved elsewhere

Instagram describes Reels as one or multiple recorded clips; its original launch documentation says clips can be captured one at a time, all at once, or uploaded, and describes timer, align-to-prior-frame, audio, effects, and speed ([Introducing Instagram Reels, 2020-08-05](https://about.fb.com/news/2020/08/introducing-instagram-reels/), [record a Reel](https://www.facebook.com/help/instagram/225190788256708)). Meta later documented a unified Reels editing screen for video clips, audio, stickers, and text so elements could be visually aligned and timed ([Meta Newsroom, 2023-04-14](https://about.fb.com/news/2023/04/instagram-reels-trending-audio-and-gifts-updates/)).

Meta's official May 2023 announcement documents Split, per-clip Speed, and Replace. Replace is defined to preserve the timing and order of the other clips, audio, and other elements, which is a valuable transactional contract even though it is not a full persistence specification ([Meta Newsroom, 2023-05-17](https://about.fb.com/news/2023/05/introducing-new-features-to-make-the-most-of-your-instagram-experience/)). Drafts can be resumed and extended with more clips, music, effects, stickers, and text, but they are device-local and are lost on uninstall; downloaded camera-roll copies do not retain music added from Instagram's music library ([save and edit drafts](https://www.facebook.com/help/639718330257952/)).

Meta launched the separate Edits app in 2025 with a frame-accurate timeline, clip-level editing, project management, transitions, green screen, and watermark-free export ([Introducing Edits, 2025-04-22](https://about.fb.com/news/2025/04/introducing-edits-streamlined-video-creation-app/)). The product-boundary inference is that native Reels remains a simpler publishing composer while deeper editing is delegated to a dedicated tool. Camenya should likewise choose its complexity ceiling explicitly rather than accumulating every social editing feature in the capture flow.

### YouTube Shorts: one time ruler for media and timed decoration

YouTube documents a multi-segment camera with undo/redo of the most recently recorded segment and draft saving ([get started creating Shorts](https://support.google.com/youtube/answer/10059070)). Its current Shorts editor puts video, text, stickers, music, and voiceover in one timeline; individual video clips can be trimmed and reordered, the timeline can be zoomed for precise edits, and timed elements get start/stop bounds. It also exposes separate volume levels for music, original audio, and voiceover; automatic captions can have text corrections and font/color changes ([enhance your Shorts](https://support.google.com/youtube/answer/16215842?co=GENIE.Platform%3DiOS&hl=en)).

This supports a useful architectural pattern for Camenya: the primary video sequence and timed decorations need one shared Project clock, even when their editing controls remain separate. It does **not** require a visually dense multitrack editor on day one.

### Google Photos: useful save-copy boundary, not a Timeline model

Google Photos on iPhone documents single-video trim, mute, crop/rotate, and ranged speed changes, with edits saved as a copy ([edit your videos](https://support.google.com/photos/answer/10729480?co=GENIE.Platform%3DiOS&hl=en)). Its Android documentation additionally exposes text, local music, separate video/soundtrack volume, and device-dependent audio tools, again saving a copy ([Android video editor](https://support.google.com/photos/answer/10729480?co=GENIE.Platform%3DAndroid&hl=en)).

This is evidence for an output boundary—editable source plus explicit rendered copy—not for multi-clip Timeline interaction. Camenya already follows the stronger version of that boundary: in-app sources remain independent and only an explicit Project Export may be saved to Photos.

## Pattern comparison

| Capability | Clips | iMovie iPhone | TikTok | Instagram Reels | YouTube Shorts | Camenya recommendation |
|---|---|---|---|---|---|---|
| Capture segments/clips | Capture/add clips into a video | Record/import into a project | Camera start/stop; exact segment identity undocumented | One or multiple captured/uploaded clips | Multi-segment camera; import | Preserve Take capture/finalization; edit occurrences afterward |
| Primary sequence | Ordered clips | Full primary storyline | Ordered linear clips | Unified clip-and-assets screen | Ordered video clips in shared timeline | One ordered primary storyline |
| Trim | Per clip | Per clip, reversible within source bounds | Per clip | Clip editing documented; exact trim contract not established here | Per clip/segment | Per Timeline Clip, metadata-only |
| Split | Per clip | At playhead; results separated by a cut | At playhead | One clip into two | Not stated in inspected official page | Yes, core operation after domain migration |
| Reorder | Yes | Yes | Long-press/drag | Not established in inspected sources | Yes | Yes, direct manipulation plus accessible actions |
| Delete/remove | Delete clip | Remove from project, source remains available | Exact clip-delete semantics undocumented | Exact clip-delete semantics undocumented | Recording-stage last-segment undo documented | Remove occurrence; purge source only when unreferenced and explicitly confirmed |
| Duplicate | Tool is exposed | Reference-like; no media copy/storage | Text only documented | Not established | Not documented | Next-step operation; reference the same Take source |
| Speed | Not documented in inspected clip guide | Per clip and multiple ranges | Per clip/apply all | Per clip | Recording controls exist; timeline range behavior not established here | Defer until caption/audio time mapping is designed |
| Transitions | Not documented in inspected clip guide | Per boundary, adjustable | At clip joins | Not established in inspected sources | Not established in inspected docs | Hard cuts first; simple dissolve only if later evidence warrants it |
| Audio | Clip mute; Project music | Separate audio clips, music, mixing/fades | One sound plus clip volume/effects | Music/effects/original audio | Music/original/voiceover layers and volume | Per-Clip source-audio mute; music excluded from the initial architecture |
| Text/captions | Clip effects and Live Titles | Titles attached to clips | Timed text/overlays and editable creator captions | Timed text/stickers in unified screen | Timed text/captions on shared clock | Caption lane plus constrained title cards; no arbitrary sticker system initially |
| Undo/history | Some replacement is explicitly irreversible | Session undo/redo until reopen | Not documented | Current durable contract not documented | Last recorded segment and voiceover undo/redo documented | Session command undo/redo plus durable source recovery |
| Output boundary | Editable project then shared/saved video | Editable project then shared file | Draft then publish/save; recovery weakly documented | Device-local draft; licensed music can differ in download | Preview then publish/draft | Immutable export snapshot; only finalized Project Export reaches Photos |

“Not documented” means the inspected official sources do not establish the capability; it does not prove the app lacks it.

## Recommended Camenya domain model

The exact names should be decided in an ADR, but the semantic boundary should be explicit:

```text
Project
├── TakeSource[]              immutable finalized recordings and support media
├── TimelineClip[]            ordered primary-storyline occurrences
│   ├── sourceTakeID
│   ├── availableRange
│   ├── clipSelection
│   └── sourceAudioEnabled
├── CaptionTrack/Cues         projected onto the Project clock from known source timing
└── ExportSnapshot            immutable resolved edit decision list
```

`TakeSource` is a descriptive name in this note, not a settled public term. The user can continue seeing “Take” for the captured recording and “Clip” for its occurrence in the edit.

Important ownership rules:

- Take media remains immutable and local.
- A Timeline Clip owns only an identity, a reference, and edit metadata.
- Multiple clips may reference one Take without duplicating media.
- Removing a Timeline Clip is reversible while the source still exists.
- Permanently deleting the last reference and its Take media remains an explicit, confirmed destructive operation.
- Captions retain source-relative timing where it is genuinely known; Project preview/export resolves that timing through each clip occurrence.
- The same resolved edit decision list drives preview and export. Export must never reinterpret live mutable editor state.

This model changes the current glossary invariant that the Timeline is exactly all Project Takes. It therefore requires an explicit ADR and migration plan before implementation, not an opportunistic `splitTake()` method.

## Split contract

For a clip with source interval `[a, b)` and a valid playhead time `s`, where `a < s < b`, Split should perform one atomic metadata transaction:

```text
before: Clip X -> Take A [a, b)
after:  Clip Y -> Take A [a, s)
        Clip Z -> Take A [s, b)
```

The rendered Project must be frame-equivalent immediately before and after Split. There is no transition, overlap, gap, media rewrite, thumbnail-dependent commit, or invented timestamp. Both results can then be trimmed, moved, muted, or removed independently.

Required edge rules:

- reject split at or too close to an edge according to one documented minimum clip duration;
- quantize once to a stable media timescale and use the resulting boundary for both children;
- commit both children or neither;
- retain the source if persistence, thumbnail generation, or later export fails;
- make Split undoable as one command;
- regenerate or derive thumbnails asynchronously without making them the source of truth;
- resolve source-relative captions through both child ranges so Split alone does not change caption output;
- when later edits separate or remove the children, flag a caption cue crossing the edit boundary for review rather than inventing word timing.

## Interaction model on iPhone

The recommended editing surface is a progressive-disclosure editor, not the current list with more swipe actions:

1. Viewer at the top, one global Project playhead, and one horizontally scrollable/zoomable primary filmstrip.
2. Tapping a clip selects it and opens a compact inspector with named buttons. Gestures may accelerate trim/reorder/split but cannot be the only path.
3. Trim handles edit the selected occurrence's source range. A dedicated Split button acts at the playhead. Reorder is a long-press drag with accessible “Move Earlier/Later” alternatives.
4. Captions and later bounded text presentation are entered as focused modes on the same Project clock. They should not be permanently visible as dense tracks on an iPhone screen.
5. Exact time readouts and nudge controls complement dragging for precision.
6. Every operation previews immediately from metadata; expensive rendering happens only for finalized Project Export.

This interaction recommendation is an inference from the recurring documented use of playheads, trim handles, clip selection, contextual controls, timeline zoom, and separate focused tools in iMovie, Clips, and Shorts. It needs Camenya-specific usability and accessibility testing; documentation alone cannot establish that the proposed layout is comfortable.

## Capability boundary

### Core editing increment

- global Project playhead and seekable Timeline preview;
- select one Timeline Clip;
- metadata trim with original range recoverable;
- atomic Split;
- reorder;
- reversible removal from the storyline;
- per-clip original-audio mute;
- session undo/redo for structural edits;
- hard cuts;
- deterministic preview/export parity.

### Later core and post-core increments

- reference-based Duplicate;
- captions on the shared Project clock, including split-boundary review;
- a constrained Title Card increment, followed separately by bounded text overlays with safe zones;
- persisted edit history only if user testing shows session undo plus source recovery is insufficient.

### Explicitly defer

- speed changes, because they remap audio and every caption/overlay time;
- background music and a soundtrack schema;
- arbitrary multitrack video and picture-in-picture;
- per-boundary transition catalogue;
- keyframes, masks, chroma key, and freeform compositing;
- beat-sync automation and social-platform trend/template systems;
- an unlimited audio mixer.

Deferral is not a judgment that these features lack value. It keeps the first Timeline model coherent and preserves Camenya's promise of predictable capture and recoverable media.

## Why not a TikTok/Instagram clone or mini-iMovie

Social creation tools optimize an end-to-end path into their own publishing surfaces, with platform music, stickers, effects, and safe-zone concerns. Camenya's differentiator is a local-first recording workspace whose unfinished media stays private and whose output is an explicit export. It should borrow their shared time ruler and focused editing modes, not their publishing-dependent feature surface.

iMovie proves the feasibility of rich phone editing, but copying its operation set would immediately require a general timeline engine. Camenya currently has a strong, narrower grammar—record Takes, preserve originals, order a story, review captions, export once. The recommended model deepens that grammar instead of replacing it.

## Decision sequence

Before filing an implementation issue for Split:

1. Record an ADR separating immutable Take source identity from Timeline Clip occurrence identity.
2. Decide whether source media without any Timeline Clip remains in a recoverable Project bin or is immediately offered for confirmed permanent deletion. A recoverable bin is safer; immediate purge better matches the current simple Project model.
3. Define metadata migration from schema version 3 `[ProjectTake]` to sources plus ordered clip occurrences.
4. Define caption projection and the crossing-cue review state.
5. Define a structural edit command model for undo/redo.
6. Build the global Project clock and preview/export resolver.
7. Only then implement metadata trim, Split, reorder, remove, and mute as separate user-testable increments.

## Unknowns requiring product or device validation

- The official TikTok and Instagram help material does not consistently document every editing operation or its persistence semantics; absence from their documentation must not be treated as absence from their current apps.
- Competitor documentation does not expose whether their split/trim operations share underlying media or render intermediates. The Camenya recommendation comes from its own preservation requirements plus iMovie's explicit storage-free duplication behavior.
- The best iPhone Timeline density, clip minimum width, handle hit targets, auto-scroll behavior, and haptics require prototype testing.
- Preview/export frame parity, audio discontinuities at splits, caption boundary behavior, and performance with many clip references require automated tests and physical-iPhone verification.
- There is no physical capture or editing verification in this research.

## Primary sources

### Apple Clips

- [Make a video](https://support.apple.com/guide/clips/make-a-video-dev57f9eb69d/ios)
- [Edit clips](https://support.apple.com/guide/clips/edit-clips-devf7e94c16a/ios)
- [Save and delete clips](https://support.apple.com/guide/clips/save-and-delete-clips-dev48d597466/ios)
- [Add soundtracks and songs](https://support.apple.com/guide/clips/add-soundtracks-and-songs-devccc194267/ios)
- [Import songs](https://support.apple.com/guide/clips/import-songs-devbb38367d4/ios)
- [Record with Live Titles](https://support.apple.com/guide/clips/record-with-live-titles-dev77e5e5619/ios)

### Apple iMovie for iPhone

- [Arrange video clips and photos](https://support.apple.com/guide/imovie-iphone/arrange-video-clips-and-photos-knac788312/ios)
- [Adjust transitions](https://support.apple.com/guide/imovie-iphone/adjust-transitions-kna737b471f/ios)
- [Adjust video speed](https://support.apple.com/guide/imovie-iphone/adjust-video-speed-kna47ca84b07/ios)
- [Add video overlay effects](https://support.apple.com/guide/imovie-iphone/add-video-overlay-effects-kna831efee4d/ios)
- [Add music and soundtracks](https://support.apple.com/guide/imovie-iphone/add-music-and-soundtracks-kna257fc2a9/ios)
- [Adjust audio](https://support.apple.com/guide/imovie-iphone/adjust-audio-knabf616edbf/ios)
- [Add titles](https://support.apple.com/guide/imovie-iphone/add-titles-kna14aaa4db/ios)
- [Add video clips and photos / undo and redo](https://support.apple.com/guide/imovie-iphone/add-video-clips-and-photos-knac787725/ios)

### TikTok

- [Edit TikTok videos and photos](https://support.tiktok.com/en/using-tiktok/creating-videos/editing-tiktok-videos-and-photos)
- [More ways to create and connect with TikTok, 2022-10-06](https://newsroom.tiktok.com/editing-tools/?lang=en)
- [Accessibility for TikTok videos](https://support.tiktok.com/en/using-tiktok/creating-videos/accessibility)
- [Camera tools](https://support.tiktok.com/en/using-tiktok/creating-videos/camera-tools)
- [Editing, posting, and deleting](https://support.tiktok.com/en/using-tiktok/creating-videos/editing-posting-and-deleting)

### Instagram / Meta

- [Introducing Instagram Reels, 2020-08-05](https://about.fb.com/news/2020/08/introducing-instagram-reels/)
- [Record a Reel on Instagram](https://www.facebook.com/help/instagram/225190788256708)
- [Reels unified editing screen, 2023-04-14](https://about.fb.com/news/2023/04/instagram-reels-trending-audio-and-gifts-updates/)
- [Split, Speed, and Replace, 2023-05-17](https://about.fb.com/news/2023/05/introducing-new-features-to-make-the-most-of-your-instagram-experience/)
- [Save and edit Reel drafts](https://www.facebook.com/help/639718330257952/)
- [Introducing Edits, 2025-04-22](https://about.fb.com/news/2025/04/introducing-edits-streamlined-video-creation-app/)

### Google/YouTube

- [Get started creating YouTube Shorts](https://support.google.com/youtube/answer/10059070)
- [Enhance YouTube Shorts on iPhone and iPad](https://support.google.com/youtube/answer/16215842?co=GENIE.Platform%3DiOS&hl=en)
- [Edit videos in Google Photos on iPhone and iPad](https://support.google.com/photos/answer/10729480?co=GENIE.Platform%3DiOS&hl=en)
- [Edit videos in Google Photos on Android](https://support.google.com/photos/answer/10729480?co=GENIE.Platform%3DAndroid&hl=en)

## Decision-ready summary

Build a Camenya editor around a **single primary video storyline**, not around the current one-Take/one-row identity and not around unlimited tracks. Introduce a Timeline Clip occurrence that references immutable Take media. Make trim, split, reorder, remove, mute, and undo the foundational grammar; project captions onto the same global clock; keep hard cuts and export snapshots deterministic. Split is then a small atomic metadata transformation with a strong invariant—the output does not change until the user edits one of the two resulting clips—instead of a risky media-copy operation. Music must not shape the initial schema or Interface.
