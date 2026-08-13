# On-device captions on iPhone

Date: 2026-08-12

## Conclusion

Camenya can generate captions from finalized Take audio entirely on the iPhone. For its current iOS 18 deployment target, the compatible path is the Speech framework's `SFSpeechRecognizer` with `requiresOnDeviceRecognition` set to `true`, after verifying `supportsOnDeviceRecognition` for the requested locale. On iOS 26 and later, `SpeechAnalyzer` with `SpeechTranscriber` is the preferable file-oriented implementation: it exposes async results, time-indexed presets, local model inventory, and explicit preparation and cancellation APIs.

System Live Captions are an accessibility feature, not a public transcription feed for third-party apps. Camenya must run and persist its own transcription.

## iOS 18 baseline

`SFSpeechURLRecognitionRequest` accepts a recorded audio file, while `SFSpeechAudioBufferRecognitionRequest` accepts live or existing audio buffers. Because a Take is a movie, the most controlled integration is to decode its audio with the same local AVFoundation boundary already used by `TakeTrimAnalyzer` and feed those buffers to Speech.

An on-device request must set `requiresOnDeviceRecognition = true`. Apple explicitly says that this prevents sending audio over the network only when the chosen recognizer reports `supportsOnDeviceRecognition == true`. Camenya therefore needs a hard runtime capability check and must not silently retry with network recognition.

The legacy API can provide:

- final or partial results;
- automatic punctuation through `addsPunctuation`;
- custom contextual phrases;
- text alternatives and confidence;
- a timestamp and duration for each `SFTranscriptionSegment`, suitable for constructing caption cues.

It also requires Speech authorization and an `NSSpeechRecognitionUsageDescription` entry. Apple tells clients to plan for recognition tasks of roughly one minute, so longer Takes would need conservative chunking and timestamp rebasing. This makes the iOS 18 route feasible, but less elegant for long recordings.

Primary SDK evidence:

- `Speech.framework/Headers/SFSpeechRecognitionRequest.h:30-73, 77-145` — partial results, contextual strings, on-device requirement, punctuation, recorded-file and buffer requests.
- `Speech.framework/Headers/SFSpeechRecognizer.h:70-112, 128-161, 177-208` — one-minute guidance, authorization and Info.plist requirement, locale/runtime availability, on-device support, asynchronous tasks and cancellation handle.
- `Speech.framework/Headers/SFTranscriptionSegment.h:20-65` — segment text, character range, timestamp, duration, confidence and alternatives.

All paths above are relative to the installed SDK root:

`/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.2.sdk/System/Library/Frameworks/`

## Preferred iOS 26 path

The new Speech APIs are available only from iOS 26. `SpeechTranscriber` offers transcription and progressive, time-indexed presets; results are an async sequence whose attributed text can carry audio time ranges and transcription confidence. `SpeechAnalyzer` can process an `AVAudioFile`, prepare compatible formats, finalize through end of input, or cancel analysis.

The model is explicitly device-managed. `SpeechTranscriber` exposes supported and installed locales, while `AssetInventory` reports whether the necessary assets are unsupported, supported, downloading, or installed and can create an installation request. This enables honest UI such as “Italian model required” with download progress rather than an unexplained failure.

Primary SDK evidence:

- `Speech.framework/Modules/Speech.swiftmodule/arm64e-apple-ios.swiftinterface:10-50` — iOS 26 availability and local asset inventory/status/installation.
- Same interface `:55-174` — long-dictation presets, punctuation, time-range/confidence attributes, locales and async results.
- Same interface `:230-281` — analyzer preparation, sequence analysis, finalization, cancellation and compatible audio format selection.
- Same interface `:391-515` — audio-file helpers and `SpeechTranscriber` time-indexed presets/results.

## Caption review and export

Recognition should create editable metadata owned by each Take, not modify the raw movie. A practical flow is:

1. Analyze the approved effective range after edge cleanup.
2. Persist caption cues as rational start/end times plus editable text and locale.
3. Let the user play, scrub, correct text, split/merge cues, and disable individual cues.
4. Rebase every cue through the approved Take Selection and Timeline offsets at export.
5. Snapshot caption metadata in the immutable Project Export plan.

AVFoundation on iOS 18 can represent timed captions directly. `AVCaption` stores text and a `CMTimeRange`; `AVAssetWriterInputCaptionAdaptor` appends monotonically ordered captions to a text or closed-caption writer input. The newer async `CaptionReceiver` is iOS 26-only.

Primary SDK evidence:

- `AVFoundation.framework/Headers/AVCaption.h:360-426` — caption text and presentation time range, available on iOS 18.
- `AVFoundation.framework/Headers/AVAssetWriterInput.h:806-859` — iOS 18 caption writer adaptor and ordering requirements.
- `usr/lib/swift/AVFoundation.swiftmodule/arm64e-apple-ios.swiftinterface:339-370` — iOS 26 async caption receiver.

Two export forms are possible:

- **Burned-in captions:** rendered into the video image. This is the recommended Camenya default because the result remains visible after sharing to social apps, at the cost of being permanently styled into that export.
- **Selectable caption track:** stored as timed text using AVFoundation. This preserves accessibility and allows viewers to toggle captions, but downstream apps may omit or ignore the track.

Offering both is technically possible. Burn-in is not an automatic speech-framework feature; it requires a rendered video overlay during export. A selectable track requires moving the relevant export path to deliberate `AVAssetWriter` caption-track construction and validating Photos/downstream preservation on a physical iPhone.

## Other built-in capabilities and boundaries

- `SpeechDetector` in iOS 26 can report whether speech is present and may improve future speech-boundary analysis, but it does not produce caption text.
- Natural Language can help process text after transcription; it does not transcribe audio.
- Sound Analysis classifies sounds; it is not a speech-to-text engine.
- Translation can translate already-produced text where supported; it is a separate optional workflow, not caption generation.
- Accessibility Live Captions can display system transcription, but the public SDK does not expose its recognized text to Camenya. The only related API found controls whether that system feature is allowed during an assessment session.

## Recommendation for Camenya

Build captions as another optional, non-destructive review stage after edge cleanup and before final export. Keep iOS 18 support through a strict on-device `SFSpeechRecognizer` adapter, and add an iOS 26 adapter using `SpeechAnalyzer`/`SpeechTranscriber`. Use one shared caption domain model and editor so the recognition backend is replaceable.

Do not auto-publish recognition output. Caption text and timing are probabilistic and should be explicitly reviewed. Never send Take audio to a server as an implicit fallback. Default final export to burned-in captions, with a selectable track as an advanced option only after device/interoperability testing.
