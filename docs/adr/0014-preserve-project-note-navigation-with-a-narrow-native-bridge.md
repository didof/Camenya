# Preserve Project Note Navigation with a Narrow Native Bridge

Long Project Notes are reference material during Capture, not only short editable metadata. The recorder must therefore reopen a note at the same reading position between Segments. SwiftUI's `TextEditor` does not expose its cursor range or vertical content offset, so it cannot provide that behavior deterministically.

Camenya uses one narrow `UITextView` wrapper for the Project Note editor. `ProjectNoteStore` remains the owner of text and session navigation state; the wrapper only reports text, selection, and scroll changes and restores the supplied position when recreated. It does not own Project persistence, Capture behavior, or error recovery. Opening the note does not force keyboard focus, so it remains useful as a reading surface before the user explicitly edits it.

This extends the native-bridge boundary established by ADR 0013 for one concrete missing SwiftUI capability. The navigation state is transient to the active Project session, is normalized against the current UTF-16 text length, and has deterministic unit coverage. Physical-iPhone acceptance still verifies keyboard behavior, sheet resizing, Dynamic Type, VoiceOver, and restoration after a real Capture pause.
