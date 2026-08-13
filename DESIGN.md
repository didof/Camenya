---
name: Camenya
description: A calm, tactile camera interface for one continuous multi-camera Take.
colors:
  ink: "#090A0D"
  paper: "#F6F6F1"
  recording: "#FF453B"
  warning: "#FFC738"
typography:
  headline:
    fontFamily: "SF Pro, system-ui, sans-serif"
    fontSize: "17px"
    fontWeight: 600
    lineHeight: 1.2
  title:
    fontFamily: "SF Pro, system-ui, sans-serif"
    fontSize: "20px"
    fontWeight: 600
    lineHeight: 1.25
  body:
    fontFamily: "SF Pro, system-ui, sans-serif"
    fontSize: "17px"
    fontWeight: 400
    lineHeight: 1.35
  label:
    fontFamily: "SF Pro, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 600
    lineHeight: 1.15
  timer:
    fontFamily: "SF Mono, ui-monospace, monospace"
    fontSize: "17px"
    fontWeight: 600
    lineHeight: 1
rounded:
  control: "15px"
  panel: "24px"
  shelf: "30px"
  pill: "999px"
spacing:
  xs: "6px"
  sm: "10px"
  md: "16px"
  lg: "24px"
components:
  button-primary:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    typography: "{typography.headline}"
    rounded: "{rounded.pill}"
    padding: "0 20px"
    height: "56px"
  button-utility:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.paper}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    size: "46px"
  record-button:
    backgroundColor: "{colors.recording}"
    textColor: "{colors.paper}"
    rounded: "{rounded.pill}"
    size: "72px"
  status-pill:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.paper}"
    typography: "{typography.label}"
    rounded: "{rounded.pill}"
    height: "38px"
---

# Design System: Camenya

## 1. Overview

**Creative North Star: "The Pocket Slate"**

Camenya is used one-handed in unpredictable light while the live camera image changes constantly. Its interface behaves like a compact physical recording tool: dark, steady framing around the preview; off-white tactile controls; signal colors reserved for recording, warnings, and destructive actions.

The preview remains the largest surface and the user's next valid action remains visually dominant. The system explicitly rejects a professional camera control deck, a social-video creator interface, and a decorative glass dashboard.

**Key Characteristics:**

- Restrained signal palette over an arbitrary live image.
- One primary action per recorder state.
- Visible icon and label pairs for recognition under pressure.
- Opaque tonal surfaces and hairlines, never ornamental glass.
- Native typography, Dynamic Type, and 44-point minimum targets.

## 2. Colors

The palette is almost neutral so the camera preview can carry the scene; red and yellow communicate state rather than decorate.

### Primary

- **Signal Red:** Record affordance, active recording state, Stop, and destructive emphasis.

### Secondary

- **Slate Ink:** Stable chrome, panels, scrims, and high-contrast framing around the preview.

### Tertiary

- **Caution Yellow:** Interruption and recovery only.

### Neutral

- **Soft Paper:** Primary actions, text, icons, and recording-ring contrast.

### Named Rules

**The Signal Rule.** Red means capture or destruction; yellow means attention. Neither color is decorative.

**The Preview Rule.** The live image supplies all other color. Interface chrome stays neutral.

## 3. Typography

**Display Font:** SF Pro with the native system fallback  
**Body Font:** SF Pro with the native system fallback  
**Label/Mono Font:** SF Mono for elapsed time only

**Character:** Native, compact, and immediately familiar. Weight and case communicate priority without introducing a display face.

### Hierarchy

- **Headline** (semibold, 17px, 1.2): Primary action labels and operational states.
- **Title** (semibold, 20px, 1.25): Pause note and recovery headings.
- **Body** (regular, 17px, 1.35): Notes and explanatory copy.
- **Label** (semibold, 12px, 1.15): Utility-control captions and status text.
- **Timer** (semibold monospaced, 17px, 1): Stable elapsed-time measurement.

### Named Rules

**The Native Voice Rule.** Use the system typeface everywhere; monospacing is reserved for time.

## 4. Elevation

Camenya is flat by default. Depth comes from opaque tonal layering, preview scrims, and a restrained one-point hairline; no drop shadows are used over the camera image.

### Named Rules

**The No Floating Glass Rule.** Panels may cover the changing preview for legibility, but blur and shadow never become decoration.

## 5. Components

### Buttons

- **Shape:** Tactile continuous curves for utility controls (15px) and capsules for primary actions.
- **Primary:** Soft Paper fill, Slate Ink text, 56px height, one per state.
- **Press / Focus:** A short scale-and-opacity response; native accessibility behavior remains intact.
- **Utility:** Icon above visible label, minimum 64px footprint, muted tonal fill behind the icon.
- **Destructive:** Signal Red icon and label with a low-opacity red field; never the filled primary action.

### Cards / Containers

- **Corner Style:** Continuous 24px pause panels and 30px control shelves.
- **Background:** Opaque Slate Ink tonal layers so content survives any preview frame.
- **Shadow Strategy:** None.
- **Border:** One-point Soft Paper hairline at low opacity.
- **Internal Padding:** 16px to 24px according to content density.

### Inputs / Fields

- **Style:** Native TextEditor on the secondary system background, with a real instructional empty state.
- **Focus:** Keyboard focus begins when the pause-note sheet opens.
- **Disabled:** Native semantics and reduced opacity; no custom focus invention.

### Navigation

The camera surface has no persistent navigation. Status and time occupy compact top pills; the bottom shelf changes controls according to recorder state.

### Record Shutter

A 72px Soft Paper ring contains a 58px Signal Red disc. It is the sole primary affordance before a Take starts and visibly dims until capture is ready.

## 6. Do's and Don'ts

### Do:

- **Do** keep the preview primary and use Slate Ink scrims only where text or controls need dependable contrast.
- **Do** show one filled Soft Paper action for the next valid workflow step.
- **Do** pair every bottom-control icon with a visible label and a minimum 44-point target.
- **Do** state when completed segments are safe during interruptions and recovery.
- **Do** use Signal Red only for recording and destructive actions, and Caution Yellow only for attention.

### Don't:

- **Don't** turn Camenya into a professional camera control deck packed with exposure, lens, waveform, and codec controls.
- **Don't** imitate a social-video creator interface filled with filters, stickers, feeds, trends, and promotional prompts.
- **Don't** create a decorative glass dashboard whose effects compete with the live preview.
- **Don't** add gradient text, decorative blur, side-stripe borders, or display fonts.
- **Don't** make Pause, Resume, Flip, and Stop compete with equal visual weight.
