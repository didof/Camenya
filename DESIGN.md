---
name: Camenya
description: A calm, native iPhone narrative recorder with a bounded Primary Storyline.
colors:
  foreground: "UIColor.label"
  secondaryForeground: "UIColor.secondaryLabel"
  background: "UIColor.systemBackground"
  secondaryBackground: "UIColor.secondarySystemBackground"
  groupedBackground: "UIColor.systemGroupedBackground"
  separator: "UIColor.separator"
  tint: "SwiftUI.Color.tint"
  recording: "UIColor.systemRed"
  warning: "UIColor.systemYellow"
typography:
  headline:
    swiftUI: "Font.headline"
  title:
    swiftUI: "Font.title3.weight(.semibold)"
  body:
    swiftUI: "Font.body"
  label:
    swiftUI: "Font.caption.weight(.semibold)"
  timer:
    swiftUI: "Font.body.monospacedDigit().weight(.semibold)"
spacing:
  compact: "8pt"
  standard: "16pt"
  section: "24pt"
components:
  button-primary:
    swiftUI: "Button with .buttonStyle(.borderedProminent)"
    minimumTarget: "44pt"
  button-utility:
    swiftUI: "Button with Label and a native bordered or plain style"
    minimumTarget: "44pt"
  record-button:
    backgroundColor: "{colors.recording}"
    size: "72px"
  timeline-clip:
    selectionColor: "{colors.tint}"
    minimumHeight: "52pt"
    minimumInteractiveTarget: "44pt"
---

# Design System: Camenya

## 1. Overview

**Creative North Star: "The Pocket Slate"**

Camenya is used on an iPhone in two concrete scenes. During capture, one person may be holding the phone in changing ambient light and needs the preview and recording truth at a glance. During editing, the phone is steadier, often held in two hands, and the user needs to shape a spoken story without learning a professional editor.

The interface should feel like it belongs beside Apple's focused first-party utilities: semantic system colors, SF typography, SF Symbols, standard navigation, native menus and confirmation patterns, predictable gestures, and restrained feedback. Familiarity is the desired character. Custom UI is reserved for the filmstrip, playhead, trim handles, and other controls that have no adequate system equivalent.

**Key Characteristics:**

- Semantic system colors that adapt to appearance and accessibility settings.
- One primary action per recorder state and one selected editing target at a time.
- Visible labels or accessible names for every action.
- Native containers and materials only when they improve hierarchy or legibility.
- Dynamic Type, VoiceOver, Reduce Motion, and 44-point minimum targets from the first implementation.

## 2. Colors

Use Apple's semantic colors rather than fixed light and dark swatches. The recorder must remain legible over arbitrary imagery; the editor follows the current system appearance and lets video thumbnails provide most of the color.

### Primary

- **System Red:** Record affordance, active recording state, Stop, and destructive emphasis.

### Secondary

- **System Tint:** Current selection, enabled primary editing actions, focus, and linked controls.

### Tertiary

- **System Yellow:** Interruption and recovery attention only.

### Neutral

- **Semantic Neutrals:** Label, secondaryLabel, systemBackground, secondarySystemBackground, grouped backgrounds, and separator.

### Named Rules

**The Signal Rule.** Red means capture or destruction; yellow means attention; tint means selection or an enabled action. None is decorative.

**The Semantic Color Rule.** Do not hard-code black, white, or custom neutral hex values. Start with semantic system colors and verify contrast in Light Mode, Dark Mode, Increase Contrast, and over representative video frames.

**The Preview Rule.** The live image and filmstrip supply all other color. Recorder chrome stays restrained and editor chrome follows the system appearance.

## 3. Typography

Use SwiftUI semantic text styles so size, leading, weight, and accessibility scaling stay native. Use `monospacedDigit()` for elapsed time and timecode only; do not introduce a display face.

**Character:** Native, compact, and immediately familiar. Weight and case communicate priority without introducing a display face.

### Hierarchy

- **Title / Title 3:** Screen and inspector hierarchy.
- **Headline:** Primary actions and operational states.
- **Body:** Notes, explanations, and empty-state guidance.
- **Callout / Caption:** Secondary metadata and compact Timeline labels.
- **Monospaced digits:** Elapsed time and precise edit values only.

### Named Rules

**The Native Voice Rule.** Use semantic system styles everywhere. Never freeze essential text at a pixel size, and allow labels to wrap before truncating meaning.

## 4. Elevation

Camenya is flat by default. Hierarchy comes from system background levels, separators, toolbars, safe-area placement, selection outlines, and native sheets. The recorder may use an opaque or system material scrim only when it materially protects legibility over the preview.

### Named Rules

**The No Floating Glass Rule.** Materials may solve contrast in a native toolbar or sheet, but blur and shadow never become decoration.

## 5. Components

### Native Controls First

- Use `NavigationStack`, `Toolbar`, `Button`, `Label`, `Menu`, `Toggle`, `Slider`, `confirmationDialog`, and system sheets where their behavior fits.
- Use SF Symbols with text labels in inspectors and menus. An icon-only toolbar action still requires a precise accessibility label and hint.
- Keep primary and destructive roles semantic so native tint, disabled, pressed, focus, and accessibility states remain coherent.
- Use system back navigation and swipe-to-go-back. Do not recreate them.
- Destructive confirmation belongs in `confirmationDialog`; ordinary choices remain inline or in a `Menu`.

### Recorder

- The live preview is the dominant surface.
- Record is the dominant idle action. Pause or Resume is primary once a Take exists; Flip and Stop remain clearly secondary and state-aware.
- Status, camera position, and elapsed time stay readable without creating a dashboard of equal-weight pills.
- Flip remains unavailable while a Segment is recording and becomes available only while idle or paused.

### Timeline Editor

- Use a standard navigation bar, a large viewer, one global playhead, a horizontally zoomable filmstrip, one selected Timeline Clip, and a compact contextual inspector.
- The filmstrip is a continuous primary storyline, not a grid of cards and not an ornamental waveform dashboard.
- Selection uses system tint plus shape or stroke, never color alone. Non-selected Clips remain quiet.
- The fixed playhead is visually distinct from Clip bounds. Seeking moves Project Time; trim handles change the selected Clip range.
- Trim handles and short Clips preserve 44-point interactive hit regions even when their visible geometry is smaller.
- Split, trim, reorder, remove, restore, mute, undo, and redo always have named controls. Gestures may accelerate them but are never the only route.
- After Split, keep the playhead at the cut, select the right Clip, keep playback paused, and announce the result through accessibility.
- Dragging a trim handle previews continuously but commits one edit on release. Reorder presents clear lift, destination, and cancellation feedback.
- `Removed & Unused` is a discrete management destination, not a permanent media-library pane.

### Inspector and Editing Values

- Prefer a bottom safe-area inspector or native sheet presentation that leaves the selected Clip and viewer context visible.
- Show the current operation, its value, and its recovery action. Do not expose internal IDs or source-time math.
- Use explicit minus and plus controls for 0.1-second nudges. Each control exposes its resulting value to VoiceOver and remains usable with Dynamic Type.
- Disabled actions explain why through visible state, nearby copy, or accessibility hints. Do not rely on unexplained dimming.

### Empty, Loading, and Error States

- An empty Storyline explains that recording a Take adds it automatically and that export requires at least one playable item.
- Persisted edits succeed independently from thumbnail generation. Placeholder frames may appear while thumbnails load without blocking the editing result.
- Export and persisted mutations show one unambiguous busy owner. Timeline structure cannot change during Project Export.
- Recovery copy names what remains safe and presents the next valid action.

## 6. Accessibility and Adaptation

- Support Dynamic Type through accessibility sizes without hiding the selected Clip, current time, or commit action.
- Give the Timeline a logical VoiceOver order: viewer state, playhead time, selected Clip summary, editing actions, then Storyline items.
- Each Clip exposes source date, selected duration, mute state, and position in the current Storyline.
- Provide non-drag alternatives for trim and reorder. Do not make precision depend on a gesture.
- Respect Reduce Motion. Preserve state with opacity, selection, and concise announcements when spatial animation is reduced.
- Use native haptics sparingly for committed cuts, valid reorder placement, and destructive confirmation, never for decorative motion.
- Verify compact iPhone widths, Dynamic Type accessibility sizes, portrait and landscape Project Formats, Light Mode, Dark Mode, and Increase Contrast.

## 7. Motion

- Keep ordinary feedback between 150 and 250 milliseconds with native or ease-out timing.
- Animate transforms and opacity, not layout metrics.
- Motion explains selection, insertion, removal, or restored position. It does not choreograph screen entry.
- Thumbnail loading and analysis progress do not move committed Clip boundaries.

## 8. Do's and Don'ts

### Do:

- **Do** use native controls and semantic system colors before creating a custom component.
- **Do** keep the preview primary during capture and the viewer plus selected Clip primary during editing.
- **Do** show one visually dominant action for the next valid workflow step.
- **Do** pair media-specific gestures with named controls and a minimum 44-point target.
- **Do** state when completed segments are safe during interruptions and recovery.
- **Do** use System Red only for recording and destructive actions, and System Yellow only for attention.

### Don't:

- **Don't** turn Camenya into a professional camera control deck packed with exposure, lens, waveform, and codec controls.
- **Don't** imitate a social-video creator interface filled with filters, stickers, feeds, trends, and promotional prompts.
- **Don't** imitate a desktop editor with arbitrary tracks, tiny unlabeled tools, or permanent inspectors.
- **Don't** create a decorative glass dashboard whose effects compete with the live preview.
- **Don't** add gradient text, decorative blur, side-stripe borders, nested cards, or display fonts.
- **Don't** make Pause, Resume, Flip, and Stop compete with equal visual weight.
- **Don't** hide essential editing actions behind gestures, context menus, or ambiguous icons alone.
