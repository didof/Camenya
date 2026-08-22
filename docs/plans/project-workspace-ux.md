# Project Workspace UX

## Status

Approved for implementation through the stacked TDD workflow recorded below. Material product behavior that conflicts with this document requires a new maintainer decision and corresponding documentation update.

## Objective

Redesign the complete Camenya experience around a calm, native iPhone hierarchy with fewer simultaneous controls, less instructional copy, and predictable placement. The result should feel consistent with a focused built-in Apple app while preserving Camenya's local-first recording and non-destructive editing model.

### Interface language

- Camenya's initial product interface is English even when product decisions are discussed or documented with an Italian-speaking maintainer.
- User-facing labels, accessibility output, errors, confirmations, and App Store-ready screenshots use concise natural English.
- Italian phrases used during grilling are explanatory translations, not approved in-app copy.

## Accepted experience

### Project Library

- Camenya opens on a native Projects library rather than directly on the camera or a dashboard.
- Existing Projects appear in a two-column visual collection optimized for portrait 9:16 media.
- Each Project item gives its media preview visual priority and shows only the Project name, current Storyline duration, and a restrained last-modified date.
- Take count, Project Format, storage usage, processing state, and instructional copy do not occupy the normal library item.
- Tapping an item opens its Project Workspace.
- Pressing and holding an item reveals its secondary management actions, including Rename and Delete Project, without placing permanent buttons on every item.
- Delete Project remains destructive, explicitly confirmed, and states that its owned media will be deleted.
- The standard navigation toolbar contains the concise Projects title and one New Project action using the system plus symbol.
- The empty state uses one short explanation and one prominent New Project action; it does not duplicate a complete onboarding guide.
- Projects are ordered by most recent modification.
- A Project cover is derived from the first useful frame of its current active Storyline and refreshes when the leading Clip changes; empty Projects use one neutral placeholder.
- Manual cover selection is outside the initial redesigned experience.

### Project entry

- New Project creates and persists a Project immediately, assigns a localized date-and-time name such as `21 August, 14:32`, and enters Capture.
- Creation does not present a naming form, format picker, settings page, or other modal prerequisite.
- Project Format remains unset until the first Take establishes it from the device orientation under the existing predictable-format contract.
- The automatic name can be changed later from the Project Workspace or the Project item's contextual library actions.
- Leaving a newly created Project with no Take, recoverable Take, or Project Note removes that contentless auto-named Project instead of adding an empty draft to the library.
- A non-empty Project Note or any recoverable media is sufficient to preserve the Project.
- Creating a new empty Project enters immersive Capture immediately.
- Opening a Project that already owns a Take enters the Project Workspace.
- Starting another Take moves from the Workspace into Capture.
- Completing or abandoning that capture returns predictably to the Workspace.
- The camera is a dedicated mode, not the container for project management.

### Permission requests

- Camenya does not add a permission carousel or general onboarding flow before Project creation.
- Camera and microphone access are requested in context on the first entry into Capture, where their relationship to recording is unambiguous.
- Photos access is requested only when the user first asks to save a finalized Project Export to Photos; in-app Takes are never offered for that operation.
- Speech-recognition access is requested only when the user first asks Camenya to create captions.
- A denied camera or microphone permission replaces unusable Capture controls with one stable, concise unavailable state containing Open Settings and Back.
- Camenya does not repeatedly trigger the system request, stack explanatory alerts, or imply that access was granted when the current authorization state denies it.

### Workspace modes

- The Workspace opens in View mode with the current Primary Storyline as its dominant content.
- The portrait viewer is the dominant View-mode surface and exposes Play or Pause as a direct overlay instead of adding a separate permanent transport panel.
- The complete Storyline overview sits immediately below the viewer.
- Edit is a standard textual toolbar action rather than one of several competing bottom buttons.
- Prepare Project appears as one compact status row only while derived preparation work exists; the row disappears when the Project is ready.
- New Take is the only large bottom action in View mode.
- Project Export uses the familiar system share symbol in the navigation toolbar rather than competing with New Take as another large call to action.
- View mode keeps playback essential, the Storyline compact, and explanatory text exceptional.
- An explicit Edit action enters a dedicated editing mode.
- Edit mode preserves viewer and Storyline context while revealing only controls relevant to the selected Clip and current operation.
- Done returns to View mode.
- Playback navigation, zoom, source management, captions, and export do not compete as a permanent wall of controls.

### Edit-mode composition

- Entering Edit transforms the current Workspace in place instead of navigating to a disconnected editor.
- The Edit toolbar replaces Edit with Done and preserves the Project identity and current media context.
- The portrait viewer remains visible but contracts enough to give the Storyline a practical precision-editing region.
- The complete overview expands into the detailed horizontally navigable filmstrip, with the fixed Playhead and current Project Time clearly related.
- The selected Clip is visually primary while adjacent Clip context remains visible.
- The persistent contextual tool row contains only Trim, Split, and More.
- New Take, Prepare Project, and Project Export leave the editing surface until Done returns to View mode.
- Viewer Play and Pause remain available so a cut can be evaluated across neighboring Clips without leaving Edit.

### Edit-mode timeline scale

- A pinch gesture changes the detailed filmstrip's temporal scale without adding permanent zoom buttons.
- Scaling remains anchored to the fixed Playhead so the media instant under evaluation does not jump during the gesture.
- The minimum and maximum scales preserve useful neighboring context at one extreme and frame-accurate positioning at the other.
- Timeline scale is transient editing-session state and is not persisted as Project or Clip data.
- Accessibility actions provide named Zoom In Timeline and Zoom Out Timeline alternatives to the gesture.

### Workspace entry playback state

- Opening an existing Project never starts playback automatically.
- A fresh Project entry presents the first frame of the active Storyline with its Play affordance available.
- Playback starts from the current Playhead and traverses the complete active Storyline rather than playing only the selected Clip.
- Returning from Edit or Capture during the same Workspace session preserves the selected Clip and meaningful Playhead context.
- Leaving the Project ends that transient viewing context; reopening starts from the beginning rather than persisting a hidden resume position in Project data.

### Project menu and secondary media

- A restrained chevron adjacent to the Project title opens a native menu containing Rename, Project Note, Project Media, and Delete Project.
- Project Media uses one compact native list with Removed Clips, Unused Takes, and Used Takes sections rather than a second visual dashboard.
- A media row prioritizes its thumbnail and duration; permanent action buttons do not repeat on every row.
- Contextual actions preview media, restore a Removed Clip, add an Unused Take to the Storyline, or permanently delete only an unreferenced Take after confirmation.
- Used Takes remain inspectable but cannot be deleted while any active or Removed Clip references them.
- Project deletion remains destructive and explicitly communicates that all Project-owned media and metadata will be removed.

### Project Note persistence

- Project Note opens in a native sheet from the Project-title menu and retains the compact Capture access already defined.
- Text saves locally as it changes; Done closes the sheet without adding a redundant Save action.
- A persistence failure never clears the current in-memory text and provides one concise Retry path.

### View-mode playback

- The central Play overlay starts complete-Storyline playback and changes to Pause while controls are visible.
- Playback controls recede while media plays; tapping the viewer reveals them without introducing a permanent transport console.
- Pause preserves the exact current Playhead position.
- Tapping a Clip in the complete Storyline overview selects it and seeks to its first selected frame.
- Dragging across the overview scrubs Project Time continuously, with restrained haptic feedback when crossing a Clip boundary.
- Playback advances through every active Clip in Storyline order and stops on the final frame; it does not loop automatically.
- View mode does not add permanent skip-forward or skip-back buttons.

### Storyline visibility

- View mode fits the complete Primary Storyline into one overview so the user can understand the order and relative duration of all active Timeline Clips at a glance.
- Selecting a Clip identifies it without immediately exposing every editing control.
- Edit mode expands the same Storyline into a horizontally navigable, time-proportional filmstrip centered around the selected Clip.
- The Edit mode Playhead remains fixed while the Storyline moves beneath it.
- Only the selected Clip and its useful neighboring context need to remain fully legible at editing scale; the Workspace still communicates its position in the complete Storyline.
- Returning to View mode restores the complete Storyline overview.

### View-mode Storyline appearance

- Each active Clip is represented primarily by sampled source imagery rather than a permanent text label.
- Clip widths communicate relative selected duration across the complete Storyline; boundaries remain visually explicit.
- The selected Clip receives the only persistent selection outline.
- A concise label adjacent to the overview identifies the current selection, for example `Clip 3 of 8 · 12 s`, instead of repeating name, index, and duration inside every Clip.
- Missing preparation may add one restrained state indicator to the affected Clip; captions, trim, warning, source, and duration icons do not accumulate into a badge stack.
- VoiceOver exposes the Clip's position, duration, preparation state, and other actionable status even when those values are not printed permanently.

### Primary media format

- The principal design and physical-device acceptance scenario is a portrait 9:16 talking-head Project containing several Takes.
- Portrait video must receive the dominant preview area without forcing its controls below an impractically tall screen.
- Existing landscape Project compatibility remains intact unless a later product decision explicitly changes Project Format support.

### Reordering Timeline Clips

- Reordering is available in Edit mode, not in View mode.
- A tap selects a Clip; a deliberate press-and-hold lifts it for drag-and-drop reordering.
- The Storyline shows an unambiguous insertion gap, scrolls when the lifted Clip approaches an edge, and preserves the lifted state until placement or cancellation.
- Releasing at a valid destination commits exactly one atomic Storyline edit and produces restrained haptic feedback.
- Session Undo reverses the complete reorder operation.
- Move Earlier and Move Later remain available as named contextual and accessibility alternatives without occupying the permanent editing surface.

### Splitting a Timeline Clip

- Split remains an essential, user-facing Storyline operation for isolating and removing mistakes within one recorded Take.
- Split must be discoverable from the selected Clip's normal editing context rather than treated as an expert or hidden recovery command.
- The interface must make the exact cut position, the two resulting Clip boundaries, the newly selected result, and the availability of Undo visually unmistakable.
- In Edit mode, Split is a visible contextual action alongside Trim and More while one Clip is selected.
- The fixed Playhead defines the exact split frame; the command requires at least one second of selected media on each side.
- An unavailable Split remains visible and provides a concise reason instead of disappearing.
- A valid Split commits immediately without confirmation, pauses playback at the cut, selects the right resulting Clip, shows the new shared boundary, and produces restrained haptic and accessibility feedback.
- Session Undo restores the original Clip as one complete operation.

### Joining split Clips

- Join Clip is the persistent contextual inverse of Split and lives in the selected Clip's More menu rather than the permanent tool row.
- Join is available only for adjacent Clips from the same Take whose Available Ranges share the original split boundary, whose Clip Selections meet without a gap or overlap, and whose source-audio states match.
- A valid Join replaces the two Clips atomically with one Clip while preserving every frame and audio decision in the immediate output.
- A valid Join replaces the two Clips atomically with one Clip while preserving every frame and audio decision in the immediate output.
- Join never expands a trim, reintroduces excluded media, resolves mismatched audio implicitly, or guesses which content the user intended.
- Session Undo reverses the complete Join operation.

### Trimming Timeline Clips

- Trim belongs to every Timeline Clip and remains available before or after Split.
- Trim changes only the Clip Selection and can never move outside that Clip's Available Range.
- After Split, the shared split boundary partitions the two Available Ranges; neither result can trim across that boundary or overlap the other.
- Reset Trim restores the selected Clip to its own Available Range, not automatically to the complete Take Source Range.
- Removing a split boundary requires Session Undo or an eligible Join; expanding a trim never erases a Split implicitly.
- A trim interaction previews continuously and commits one atomic edit when the user finishes the adjustment.
- Trim opens as a focused submode of the current Edit Workspace rather than a separate navigation destination.
- The detailed filmstrip focuses the selected Clip, exposes only its leading and trailing trim handles, and keeps excluded source media visible in a subdued treatment.
- The contextual chrome reduces to Cancel and Done while Trim is active.
- Moving either handle updates the viewer at the relevant boundary without changing the persisted Clip Selection yet.
- Done commits the complete before-and-after Selection change as one undoable edit; Cancel restores the exact Selection that existed on entry.
- Trim presents a restrained audio waveform beneath the selected Clip's filmstrip so talking-head speech onset, pauses, and trailing noise are visually discoverable.
- Camenya derives waveform samples locally from the finalized Take audio using AVFoundation and may cache only the reduced visualization data; the immutable source media remains unchanged.
- The waveform is informative only: it does not create a separate audio selection, silently snap a trim, or imply silence removal.
- Waveform generation is progressive and never blocks Trim. Until reduced samples are available, the complete visual trimming interaction remains usable.
- While a trim handle moves, the viewer follows the relevant boundary frame and audio remains silent; releasing a handle does not trigger automatic playback.
- Play within Trim previews only the current candidate Clip Selection from its proposed beginning to end, then stops.
- After Done exits Trim, Play again evaluates the complete active Storyline so neighboring edits can be judged in context.

### Removing Clips and deleting Takes

- Removing a selected Timeline Clip from the Primary Storyline is a recoverable editing action, not source-media deletion.
- Remove from Storyline lives in the selected Clip's contextual More menu and does not require destructive confirmation.
- After removal, the nearest valid Clip becomes selected and Session Undo can restore the complete operation immediately.
- A removed Clip remains available in a secondary Removed destination and can be restored with its edit metadata and prior placement context.
- The referenced Take remains unchanged.
- Permanent Take deletion is available only from source-Take management, never from the normal Storyline editing surface.
- Permanent deletion requires explicit confirmation and remains unavailable while any active or Removed Clip references the Take.

### Project Preparation

- Every selected Timeline Clip keeps a contextual entry point to its own trim and other pre-lock video work.
- A global Prepare Project action derives one Preparation Queue from current Project state instead of storing a second mutable work list.
- The queue contains only missing, unresolved, or explicitly requested pre-lock work and follows active Storyline order.
- Adding a new Take adds only work owned by that Take, its new Clip, or the changed complete-Storyline check.
- Captions do not participate in pre-lock Clip preparation and never constrain Trim, Split, Join, reorder, or recoverable removal.
- Queue items can be approved, corrected, or skipped and remain reachable individually from their associated Clip or Take.
- Ready to Lock presents Add Captions as an explicit optional final action while the standard Share action remains able to export the current video without captions.
- Exporting a clean video does not force Picture Lock or prompt repeatedly for captions; starting captions and exporting clean media are independent user choices.

#### Guided sequence

1. Prepare Project first enters Fix Clips and presents only missing or unresolved per-Clip trim work in active Storyline order.
2. It then enters Check Video, which previews the complete current Storyline and surfaces only unresolved picture- or audio-editing issues.
3. A Project with no remaining required work reaches Ready to Lock.
4. Every review step presents one focused subject at a time with Continue and Skip.
5. Adding a later Take reintroduces only work owned by that Take, its new Clip, or the changed complete-Storyline check.

### Caption generation setup and language

- Caption setup no longer combines transcription status, language, visual placement, safety explanations, and destructive regeneration in one form.
- Caption generation is an optional final-stage action available only after the current Primary Storyline is ready to become a Picture Lock.
- The first post-lock caption-generation request presents one compact Create Captions sheet containing only the proposed spoken-language value, Cancel, and the primary Create Captions action.
- The chosen language becomes the Project's default caption language rather than inheriting invisibly from the iPhone forever.
- Caption placement and visual style move to the visual caption editor, where their effect can be evaluated on the video.
- Change Project Language and Regenerate Captions remain separate, explicitly confirmed actions because they can replace existing Project-Time text, timing, and manual corrections.
- A Take may override the Project's default spoken language for recordings intentionally made in another language.
- Every Clip derived from that Take shares its effective Take language while the locked Storyline maps those language regions into Project Time.
- The Take-language override is reachable from the associated Clip's context so the user does not need to navigate to source management to find it.
- Camenya does not introduce language regions within one Take in this experience. A different-language passage is expected to be recorded as a separate Take.
- A focused preparation item displays the effective Take language as one compact inherited value rather than requiring a language decision for every Take.
- Changing a Take language before Picture Lock is immediate.
- Changing Project or Take language after captions exist requires the explicit caption-reset behavior defined for the locked Project.
- The override is also available from the associated Clip's More menu as Spoken Language; other Take-language settings remain unchanged.
- One Create Captions action partitions the locked Project Time internally into consecutive regions with the same effective Project or Take language and merges recognition output into one Project-Time Caption Track.
- Changing any effective language after generated captions exist requires confirmation and regenerates the complete Caption Track; caption style and placement persist, while existing Cue text, timing, and manual corrections are replaced.

### Caption editor foundation

- Caption review and correction use a dedicated full-screen editor reached from the locked Project's caption action.
- In normal review, the portrait viewer receives approximately two fifths of the available height and renders the same current caption presentation used to evaluate the final burn-in.
- A slim transport associated with the viewer provides Play or Pause, current time, total time, and direct scrubbing without becoming a second editing timeline.
- The lower region is one synchronized transcript, not a collection of oversized cards.
- Each caption uses a compact native row whose primary content is its text; timestamps and exceptional status remain visually secondary.
- During playback, the active row receives one restrained highlight and the transcript follows it continuously without requiring the user to search or scroll manually.
- Tapping any caption pauses playback, seeks to that caption's start time, selects its row, and leaves playback paused until the user explicitly presses Play.
- Tapping the selected row's text begins correction without losing its video position.
- Opening the software keyboard pauses playback and switches to a stable text-editing layout whose dimensions are derived from the remaining keyboard-safe area rather than continually resizing around the video.
- The caption being edited remains fully visible and fixed in that remaining area.
- When space allows, that field is framed by one subdued single-line preview of the preceding caption and one of the following caption so linguistic context remains visible without recreating a scrollable card list.
- In a more constrained keyboard-safe height, the neighboring previews collapse before the current editable caption loses usable space.
- When the remaining height cannot support a useful video preview and text editor simultaneously, the viewer is removed instead of being reduced to an unusable sliver.
- Dismissing the keyboard restores the normal viewer-and-transcript composition and the same selected caption and Playhead position.
- Exiting the editor returns to the same locked Workspace Project Time that opened it.

### Caption-row commands

- An unselected transcript row carries no permanent action cluster.
- The selected row exposes one More control containing Edit Text, Adjust Timing, Split at Cursor, eligible Merge with Previous or Merge with Next actions, and Delete Caption.
- Split at Cursor is also available from the keyboard accessory while text is being edited because its result depends on insertion-point position.
- Merge actions appear only when their adjacency and timing preconditions are satisfied; unavailable structural actions do not create inert buttons.
- One Add Caption action in the editor toolbar creates an empty caption at the current Playhead rather than adding a plus control to every row.
- Destructive caption deletion remains visually destructive and participates in editor Undo.

### Project caption presentation

- Caption visual presentation is one Project-owned configuration so the final video remains coherent across every Take and Timeline Clip.
- Caption text and timing belong to the locked Project-Time Caption Track and are not regenerated when presentation changes.
- The caption editor previews Project presentation changes against the current video before they are accepted.
- This experience does not introduce per-Clip visual-style overrides.
- Preview and final burn-in use the same deterministic caption layout rules, font metrics, safe-region definition, line breaks, and normalized placement.
- Portrait 9:16 presentation reserves conservative space for common short-form social controls instead of treating the complete frame as unobstructed.
- One platform-neutral Content Safe Region supplies that constraint; Camenya does not ask for a TikTok or Instagram export profile.
- The same region constrains future burned-in titles, stickers, or visual overlays so each feature does not invent incompatible edge margins.
- Safe-region geometry is a versioned presentation rule rather than permanent knowledge of third-party interface coordinates, which may change independently of Camenya.
- The style editor may visualize the social-safe region while configuring captions, but guide geometry and platform chrome are never burned into the export.
- Captions remain horizontally centered inside that safe region; position adjustment is vertical and constrained so a Project cannot accidentally place text beneath the reserved edge regions.
- Opening caption Style reveals the Content Safe Region directly over the current video preview.
- Direct manipulation moves the caption block vertically only and snaps with restrained haptic feedback to Upper, Center, and Lower anchors inside the region.
- Lower is the default anchor. Horizontal placement remains centered and cannot be dragged beneath reserved side chrome.
- A named Position control exposes the same Upper, Center, and Lower values for accessibility and precise non-gesture operation.
- Closing Style removes every safe-region guide and placement indicator from ordinary caption review and from Project Export.
- Multiline captions use measured rendered widths and linguistic break opportunities rather than ordinary greedy word wrapping.
- The layout avoids one full line followed by an orphaned short line and never solves overflow by shrinking text below the Project's readable minimum.
- When text cannot form an acceptable maximum two-line block, Camenya divides presentation into consecutive timed caption units at valid word boundaries instead of truncating content.

### Caption style controls

- Style first presents three curated, live-previewed presets rather than exposing a full graphics inspector.
- Clean uses a bold system face, white text, a translucent dark rounded container, and an accent-colored active word.
- Impact uses a heavy rounded system face, a protective outline or shadow without a full-width container, and an accent pill for the active word.
- Minimal uses a semibold system face, no container, a protective shadow, and no word highlighting by default.
- A secondary Customize disclosure offers only system, rounded, or serif system designs; Small, Standard, or Large size; a curated text-color palette; None, Colored Text, or Pill highlighting; a curated accent color; None, Shadow, or Rounded Box background; and three container-opacity levels.
- Camenya provides Reset Style and prevents or automatically corrects combinations that fail the product's contrast requirement.
- Arbitrary fonts, unconstrained color pickers, freeform effect stacks, and precision sliders do not turn this focused editor into a general graphics application.
- Word highlighting is available only while trustworthy word timing exists and never guesses the active token.

### Caption line composition

- A cue uses one line when its measured text fits comfortably and never uses more than two rendered lines.
- For a two-line cue, the layout evaluates valid word boundaries using actual output font metrics and chooses a balanced result rather than the first boundary reached by greedy wrapping.
- Natural punctuation and linguistic phrase boundaries receive preference while orphaned articles, prepositions, and single short final words receive strong penalties.
- Except for unavoidable long-word cases, the shorter rendered line targets at least approximately 65 percent of the longer line's width.
- If no acceptable two-line composition fits the readable font and Content Safe Region, Camenya divides presentation into consecutive timed cues at a valid timed-word boundary.
- The chosen lines remain fixed for the cue's complete duration; active-word weight, color, or pill treatment cannot cause reflow.
- Preview and burn-in consume the same resolved line composition rather than independently wrapping the source string.

### Highlighting after text correction

- Case, punctuation, and whitespace-only corrections preserve existing trustworthy word timing and highlighting.
- A lexical correction disables word highlighting only for that Caption Cue because Camenya cannot prove a new word-to-time mapping without recognition or manual word timing.
- The affected cue retains the Project's font, text color, placement, and background and renders without an active-word treatment.
- Other cues in the locked Project Caption Track continue highlighting when their word timing remains trustworthy.
- Restore Recognized Text restores that cue's recognized text and eligible original word timing; Camenya does not regenerate or heuristically realign a lexical correction in the background.

### Caption text density

- Caption Configuration owns one Text per Caption density: Less, Standard, or More; Standard is the default.
- Less targets approximately three to five words and usually one line, Standard approximately five to eight words across one or two lines, and More approximately eight to twelve words across at most two lines.
- Those ranges are composition targets rather than blind character limits. Trustworthy word timing, punctuation, natural phrase boundaries, display duration, Content Safe Region fit, and line balance take precedence.
- Changing density previews the result on the current locked video and regroups only unedited material with trustworthy word timing; it does not run speech recognition again.
- A manually edited cue is a protected reflow boundary. Its exact current text and time range survive every later density change, including changing from More to Standard.
- Eligible unedited material before and after a protected cue may reflow independently without crossing, replacing, merging, or splitting that cue.
- Apply Density commits one undoable reflow operation separately from prior text edits; undoing the reflow never undoes those edits.
- Camenya reports the number of preserved edited cues concisely and uses the current Project density when regenerating the locked Project Caption Track.

### Picture Lock and caption lifecycle

- Create Captions first creates an explicit immutable Picture Lock from the current Primary Storyline and its source-audio decisions.
- Recognition produces one Caption Track timed directly in Project Time against the complete locked narrative; no Caption Cue belongs to or projects through an individual Take.
- Trim, Split, Join, reorder, recoverable removal, and New Take remain unrestricted before Picture Lock because no captions exist to reconcile during picture editing.
- While the Picture Lock exists, structural Storyline controls are unavailable as ordinary immediate edits.
- Choosing Edit Video after Picture Lock explains that the existing captions and their manual corrections will be removed, requires confirmation, then returns to the normal editable Storyline.
- Confirmed unlock removes the Picture Lock and its derived Caption Track without changing any Take or pre-lock Storyline edit.
- Camenya may derive a local audio mix or temporary preview from the lock for speech recognition and caption review, but that artifact is replaceable supporting media rather than the canonical finished video.
- Final captioned Project Export renders from the locked source Takes and approved overlays in one final encode, avoiding generational loss from burning captions into an already recompressed master.

### Caption-generation progress

- Confirming Create Captions establishes the Picture Lock before recognition work begins.
- The caption editor may open immediately with the locked video playable before any generated Caption Cue is available.
- The transcript region presents one compact state such as Creating Captions with the effective language, or Preparing Language while iOS prepares a required local model.
- Caption generation is dismissible. Returning to the Workspace shows only restrained activity on the captions control rather than a blocking progress screen.
- Work continues while the app remains operational; if iOS suspends it, Camenya resumes safely on return without presenting normal suspension as an error.
- Cancel Generation removes only incomplete caption-generation output and preserves the Picture Lock, its language choices, and caption-presentation configuration.
- Completion transitions into the synchronized review editor without creating a separate result-summary dashboard.
- Completed recognition regions are checkpointed incrementally. A recoverable failure offers Retry from the first missing region instead of repeating completed work.
- Partial results remain ineligible for captioned export and may be removed explicitly with Cancel Generation.

### Caption review completion

- Generated captions begin in one Project-level Needs Review state; Camenya does not require an approval tap for every Caption Cue.
- Done preserves review progress and permits the user to return later without claiming completion.
- Complete Review marks the Caption Track ready for captioned export.
- Objective invalid states such as overlapping Cue ranges, empty intervals, or text that cannot fit the Content Safe Region block completion until corrected.
- Low recognition confidence is visually discoverable but does not force an individual approval or prevent the user from completing review.

### Caption timing adjustment

- Adjust Timing opens a focused inline caption-editor submode with the locked-video viewer and Project-Time waveform visible.
- Leading and trailing handles change only the selected Cue range and cannot cross each other, overlap neighboring cues, or leave an empty interval.
- Play evaluates only the candidate Cue range; Cancel restores the prior range and Done commits one undoable timing edit.
- Manually changing Cue timing disables word highlighting only for that cue because the original word-to-time relationship is no longer guaranteed.

### Project Export interaction

- Before completed captions exist, the standard Share action exports the clean locked or current Storyline result directly.
- After caption review is complete, Share presents With Captions as the primary variant and Without Captions as the secondary variant.
- Export encoding reports compact dismissible progress without replacing the Workspace with a dashboard.
- Completion opens the standard iOS share sheet, including its system Save Video action, without adding a separate success or celebration screen.
- Only a finalized Project Export is passed to sharing or Photos; an in-app Take is never offered directly.
- Export failure preserves every Take, Picture Lock, Caption Track, and generated output that remains valid and offers a concise Retry action.

### Locked Workspace presentation and unlock

- Picture Lock does not replace the Workspace with a dashboard: the same viewer and Storyline remain the dominant surfaces.
- One restrained lock symbol adjacent to the Project name communicates the locked state and exposes an accessible Video Locked value; no explanatory banner remains on screen.
- A familiar captions symbol opens the post-lock caption editor and Share exports the current locked result.
- New Take leaves the locked surface because adding source media necessarily changes picture; the standard edit symbol remains available as the route to unlock.
- Choosing Edit Video explains that generated Caption Cues, timing, and manual caption corrections will be removed, while all Takes and every pre-lock Storyline edit remain intact.
- Confirming unlock removes the Picture Lock and its derived Caption Track, restores New Take and structural editing, and enters Edit at the current meaningful Playhead context.
- Caption presentation preferences, Project default language, Take-language overrides, and text-density preference survive unlock so a later caption round starts with the user's established configuration.
- A later Create Captions action forms a new Picture Lock and generates a new Project-Time Caption Track against the revised complete video.
- Unlock does not retain a hidden stale Caption Track or attempt to merge obsolete caption edits into a later lock; the explicit warning is the recovery boundary.

### Completing a new Take

- Stop first finalizes and persists the Take before changing the visible workflow context.
- Successful finalization returns directly to the Project Workspace without forcing a separate Take-review screen.
- The new Take creates one full-range Timeline Clip at the end of the Primary Storyline.
- The new Clip becomes selected and the paused viewer presents its first frame.
- One brief confirmation communicates that the Take was added; no persistent explanatory panel is introduced.
- Silence analysis and caption transcription do not start automatically after capture.
- Project Preparation derives the new Clip and Take work and surfaces it without modifying previously prepared material.
- Reordering, recoverable removal, or recording another Take remain the user's explicit next actions.

## Capture experience

### Idle Capture

- Capture is an immersive portrait 9:16 live-preview mode with no Project Timeline, source management, preparation, or export controls.
- The top chrome contains only Back and the Project name; readiness copy and status pills remain absent unless the user must act.
- The bottom chrome uses three stable positions modeled on familiar system camera controls: Project Note on the left, the dominant Record control in the center, and Flip on the right.
- Project Note and Flip may use symbol-only controls with 44-point targets, precise accessibility names and hints, and unambiguous state; a restrained indicator may show that the Project Note contains text.
- Record is the only visually dominant idle action and becomes unavailable when capture is not ready.
- Capture failure or unavailability introduces only the concise operational message and recovery action required by that state.

### Recording a Segment

- The live portrait preview remains dominant while one Segment is recording.
- A red recording indicator and monospaced elapsed Take time occupy the top center; ordinary navigation, Project title, and Capture options leave the active recording surface.
- Pause is the large dominant bottom-center action because it is the normal way to preserve the current Take while preparing another Segment or camera perspective.
- Stop remains visible as a smaller, clearly labeled bottom-leading action with shape and symbol semantics distinct from Pause.
- The unused bottom-trailing position stays empty rather than introducing an invalid or decorative action.
- Flip and Project Note leave the active-Segment chrome because they are unavailable while a Segment records.
- Point focus and temporary exposure adjustment remain operable without ending the Segment.
- Pause and Stop drive their visible transitions only from AVFoundation recording-completion callbacks; neither assumes that the Segment ended when tapped.

### Paused Take

- The live preview remains visible while elapsed Take time is frozen and identified with a concise paused state at the top.
- Stop occupies the bottom-leading position, Resume is the dominant bottom-center action, and Flip occupies the bottom-trailing position.
- Flip changes only the selected camera for the next Segment and never mutates a completed Segment.
- A compact Project Note bar sits above the controls and shows at most one line of existing text.
- Tapping the bar opens a native, expandable sheet for reading or editing the complete Project Note; no large note panel covers the preview automatically.
- The Project Note sheet must close before Resume can start a new Segment.
- Resume begins a new Segment only after AVFoundation confirms recording start and continues the logical Take timer from its frozen value.

### Interrupted Take

- A system interruption never silently resumes recording and never discards a completed Segment.
- If an active Segment is interrupted, Camenya first finishes and persists that Segment through the AVFoundation completion callback, then presents the Take as Recording Interrupted.
- The recovery surface states concisely that completed Segments are safe; it does not present the interruption as lost work or a generic camera failure.
- When capture is operational again, Continue Take is the primary action and Finish Take is the secondary action.
- Continue Take starts a new Segment only after AVFoundation confirms recording start; it never attempts to extend the interrupted Segment.
- Delete Current Take remains a destructive action in More and requires confirmation.
- Project Note remains reachable while interrupted. Flip becomes available only after the camera is operational and affects only the next Segment.
- If capture remains unavailable, Camenya offers only the applicable system-recovery action and Finish Take; it does not offer a Continue action that cannot succeed.
- Leaving the app with an interrupted Take preserves all completed Segments and the recoverable Take manifest.

### Relaunch recovery

- Discovering an unfinished Take after process relaunch presents one focused recovery state before normal use of its Project.
- Recover Take is the primary action and finalizes the valid completed Segments into one Take and full-range Storyline Clip.
- Delete Unfinished Take is secondary, destructive, and confirmed.
- Camenya does not append a new Segment to a pre-relaunch unfinished Take; after recovery, the user may begin a new Take normally.
- An interruption handled while the same app process remains alive continues to offer Continue Take under the separate Interrupted Take contract.
- Multiple unfinished Takes are handled one at a time in deterministic order.
- Validation or finalization failure preserves files and manifest, offers Retry, and never converts recovery failure into automatic deletion.

### App suspension and return

- Moving Camenya to the background is an expected app-lifecycle transition, not a camera failure.
- An idle or paused Capture suspends its capture session quietly. Returning to Camenya restores the session without flashing a generic camera-error alert.
- A camera interruption or runtime notification produced while Camenya is intentionally suspending or restoring capture is classified against that lifecycle state before any user-facing failure is published.
- While restoration is pending, the existing Capture composition remains stable and the preview resumes naturally as frames become available.
- Record is temporarily unavailable and carries a restrained activity treatment during restoration; no alert, banner, explanatory copy, or replacement screen flashes during a normal return.
- A genuine failure is surfaced only when the active foreground session cannot become usable, with one concise recovery action appropriate to the cause.
- Backgrounding during an active Segment follows the Interrupted Take contract: the current Segment is safely finalized, the Take remains recoverable, and return shows its recovery state rather than a generic alert.
- Physical-iPhone acceptance covers idle, recording, and paused background/foreground transitions; rapid app switching; device lock and unlock; absence of transient alerts; and preservation of completed Segments.

### Adaptive video stabilization

- Camenya prioritizes stable talking-head output over preserving the camera's widest possible field of view.
- Capture format selection considers stabilization capability instead of selecting the first nominal 1080p/30 format.
- For recorded output, Camenya requests the strongest supported mode in this order: Cinematic Extended Enhanced, Cinematic Extended, Cinematic, then Standard.
- Unsupported modes fall back predictably without making capture unavailable; the active result is observed and logged without private device identity.
- Stabilization remains automatic and does not introduce a permanent technical control into Capture.
- Moderate stabilization crop, additional pipeline latency, and memory use are accepted when required for materially smoother output.
- Physical-iPhone acceptance compares representative front-camera walking footage and confirms framing, visible shake, crop, thermal behavior, and segment consistency; Simulator success is not capture-quality evidence.

### Subject following

- On a supported front-camera format, Camenya integrates with Center Stage to let the system pan, tighten, or widen the effective framing around people.
- Camenya uses cooperative Center Stage control: an in-app change and a user change from iOS Control Center remain synchronized, and neither silently overrides the more recent user intent.
- The user-facing term is Follow Subject; Center Stage remains the underlying system capability name where iOS presents it.
- Follow Subject appears only in secondary Capture options and never displaces Project Note, Record, or Flip from the primary Capture chrome.
- Unsupported devices and formats omit the option and continue with the strongest supported stabilization mode.
- Capture may communicate the active state briefly, but does not add a permanent explanatory banner.
- Follow Subject defaults to enabled when the active front-camera device and format support it.
- The user's latest choice persists as one app-level camera preference rather than Project data.
- Switching to a rear camera makes the capability inactive without discarding the saved front-camera preference.
- Once the user disables Follow Subject, Camenya does not silently re-enable it on a later capture session.

### Automatic image quality

- Camenya configures continuous autofocus, continuous auto exposure, and continuous automatic white balance whenever the active device supports them.
- Face-driven autofocus and face-driven auto exposure remain enabled when supported so a talking-head subject receives priority without manual setup.
- Geometric distortion correction is enabled when supported and compatible with the selected camera format and subject-following policy.
- Capture-format selection preserves these automatic capabilities alongside the approved stabilization priority instead of choosing a nominal resolution and frame rate in isolation.
- The policy is reapplied and verified after every camera or active-format change.
- Unsupported capabilities fall back without blocking capture or exposing professional camera controls.

### Point focus and exposure

- Tapping a supported point in the live preview requests focus and exposure at that point without adding a permanent Capture control.
- A familiar, temporary focus indicator confirms the selected point and disappears after the adjustment.
- Focus and exposure return to their continuous automatic modes after the point adjustment rather than remaining silently locked.
- The gesture remains available during a recording without ending or restarting its active Segment.
- Unsupported adjustment falls back without disrupting recording.
- Assistive technology receives a named alternative; direct manipulation of the preview is not the only operable path.
- Camenya does not add a long-press AE/AF lock to the initial redesigned experience.

### Temporary exposure compensation

- After point focus, a temporary system-familiar brightness affordance lets the user bias automatic exposure lighter or darker with a vertical drag.
- Automatic exposure continues adapting around the selected bias instead of becoming locked.
- The adjustment remains within the active device's supported exposure-target range and provides a clear neutral detent.
- The bias lasts only for the current Capture session and resets when Capture ends or the selected camera changes.
- The transient control supports named accessibility increment, decrement, and reset actions without adding permanent camera chrome.

### Current color pipeline boundary

- This increment preserves a predictable SDR/Rec.709 capture and export pipeline.
- Automatic focus, exposure, white balance, geometric correction, subject following, and stabilization do not imply HDR capture.
- HDR video capture is deliberately deferred to a separate, independently testable pull request described in [hdr-video-capture.md](hdr-video-capture.md).
- The current pull request must not claim HDR capture, HDR caption rendering, or HDR export parity with Apple's Camera app.

### Automatic low-light boost

- Capture options expose Low Light as an app-level Auto preference without adding permanent live-preview chrome.
- Auto defaults to enabled when the active device and selected format support low-light boost.
- A temporary state indicator appears only while the device actually engages boost.
- Unsupported configurations omit the option and continue with the normal automatic exposure policy.
- Physical-iPhone acceptance evaluates brightness, noise, visible frame discontinuity, audio synchronization, thermal behavior, and consistency across Segment boundaries.
- Predictable motion continuity wins when the target device or format produces unacceptable switching artifacts; the capability policy may disable boost for that unsupported-quality combination.

### Secondary Capture controls

- The restrained chevron associated with the Project title opens a compact native Capture controls surface only while idle or paused.
- The surface contains Follow Subject and Low Light: Auto only when the current camera configuration supports them, plus an operational state only when it requires user attention.
- Stabilization, continuous autofocus, continuous exposure, automatic white balance, face priority, and geometric correction remain automatic capability policy rather than user-facing toggles.
- The controls surface closes before Record or Resume and leaves the active-Segment interface completely.

### Native interface constraint

- Prefer standard SwiftUI navigation, toolbars, menus, sheets, controls, typography, spacing, semantic colors, symbols, and accessibility behavior.
- Custom surfaces are limited to media interactions for which the system has no adequate equivalent, such as the Storyline filmstrip, Playhead, and trim handles.
- Avoid dashboard-like card stacks, persistent instructional paragraphs, decorative chrome, and rows of equally weighted buttons.
- At every moment, hierarchy and progressive disclosure must make the next valid action apparent.

### Control density and iconography

- Familiar, repeated actions prefer standard SF Symbol toolbar or icon controls over large text buttons: Back, Add, Share, More, Play, Pause, Undo, Redo, Flip, camera entry, and equivalent system conventions.
- Icon-only controls retain at least a 44-by-44-point interactive target even when their visible glyph is substantially smaller.
- Every icon-only action has a precise accessibility label, state value when applicable, and concise hint where the consequence is not obvious.
- Icons use semantic system tint, placement, and enabled state rather than decorative containers, gradients, shadows, or competing accent colors.
- Text remains appropriate for unfamiliar workflow transitions, Edit and Done states, destructive confirmations, and decisions whose consequence cannot be represented unambiguously by one familiar symbol.
- Contextual controls disappear when irrelevant; temporarily unavailable controls remain visible only when their location teaches the workflow and provide an accessible reason.
- Low visual density means fewer simultaneous decisions and restrained chrome, not undersized targets, undiscoverable gestures, or unlabeled accessibility output.

### Undo and Redo presentation

- Standard Undo and Redo symbols appear only in Storyline Edit and the caption editor, which maintain independent histories.
- A history survives focused submodes such as Trim and Adjust Timing and ends when Done closes that editing session.
- Confirmed permanent deletion and confirmed Picture Lock removal are recovery boundaries rather than entries in transient Undo history.
- Every undo or redo provides restrained haptic feedback and a precise accessibility announcement of the complete operation.

### Orientation behavior

- The first finalized Take continues to establish Project Format without a creation-time format picker.
- Portrait 9:16 is the primary design and physical acceptance format while existing landscape Projects remain viewable, editable, recordable, and exportable.
- A device orientation that does not match the Project disables Record with one restrained Rotate iPhone instruction instead of presenting a generic alert.
- Preview geometry, controls, symbols, captured rotation metadata, and export orientation remain internally consistent across supported formats.

### Accessibility and motion

- Dynamic Type applies to navigation, menus, workflow copy, transcript text, and named controls without obscuring the media surface.
- VoiceOver identifies Clip order, duration, selection, preparation state, time position, and available actions.
- Timeline, reorder, trim, and caption-timing gestures have named adjustable or contextual alternatives, and Switch Control can reach every required action.
- Selection, readiness, warning, and failure never depend on color alone.
- Reduce Motion replaces lift, zoom, and animated-scrolling transitions with restrained state changes while preserving insertion and selection clarity.
- Haptic feedback supplements visible and accessible state and is never the sole confirmation.

### Error and resource-state policy

- Expected lifecycle, capability fallback, and transient preparation events never publish generic error alerts.
- Recoverable failures appear inline beside the affected operation; modal alerts are reserved for destructive confirmation or a decision that cannot continue implicitly.
- Recording and export perform storage preflight before starting.
- Storage exhaustion during active capture closes the Segment through the AVFoundation completion path and preserves every valid recoverable file and manifest.
- System pressure or capability degradation first applies the strongest continuity-preserving fallback and communicates only a user-actionable remaining limitation.
- Retry never deletes recoverable media, and OSLog output excludes device identity and personal content.

## TDD seam contract

- Camera lifecycle and capability behavior is tested through a public capture-policy or coordinator seam that consumes explicit app/session/capability events and emits observable operational state and commands.
- Storyline behavior is tested through TimelineEditor commands and persisted Project snapshots, not SwiftUI gesture implementation details.
- Picture Lock and Caption Track behavior is tested through public Project workflow commands and Project-Time results, not storage internals.
- Caption composition is tested through a deterministic layout seam whose inputs are text, timing, Project configuration, canvas geometry, and font metrics and whose output is resolved lines and safe frames shared by preview and export.
- Export is tested through its public plan/result boundary with fixed source fixtures; UI progress presentation is tested separately from AVFoundation rendering mechanics.
- Every slice follows red, then the minimum green implementation, one observable behavior at a time. Broader refactoring and code review occur only after the behavioral slice is green.

## Stacked delivery

- The maintainer explicitly approved continuous implementation through stacked draft pull requests without intermediate physical-device checkpoints.
- Each pull request remains one independently testable increment and names its base branch, prerequisite pull request, and exact prerequisite commit.
- Work proceeds through the stack without waiting for intermediate maintainer validation; the top branch contains the complete integrated result.
- The maintainer performs one integrated physical-iPhone test on the top branch. A regression is fixed in the earliest stack layer that owns the behavior, downstream branches are restacked, and only the integrated top build requires renewed user testing.
- After integrated acceptance, pull requests merge in prerequisite order.
