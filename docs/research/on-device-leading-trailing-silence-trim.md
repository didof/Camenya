# On-device leading/trailing low-audio trim

Date: 2026-08-12
Scope: technical feasibility for finalized local Camenya Takes; no product or schema decision is made here.

## Conclusion

Yes. Camenya can analyze a finalized local movie's audio entirely on-device, produce a conservative leading/trailing trim suggestion, preview either the original or selected range, and insert only the approved range into the existing Project export. This needs no network service, speech recognizer, ML framework, or destructive rewrite of a Take.

AVFoundation does **not** expose a documented “detect silence” operation in the relevant asset-reader, player, or composition APIs inspected. It exposes decoded audio samples and time-range editing primitives; Camenya must define the low-audio heuristic. Consequently, the output should be treated as a suggestion requiring review, not as an authoritative speech boundary.

## Recommended iOS 18 path

### 1. Decode only the audio track

For each finalized `take.mov`:

1. Open an `AVURLAsset` and load its audio track.
2. Construct `AVAssetReader(asset:)` and an `AVAssetReaderTrackOutput` for that track.
3. Request uncompressed linear PCM. `AVAssetReaderTrackOutput` can convert stored samples, but audio conversion output must use `AVFormatIDKey: kAudioFormatLinearPCM` [S2, lines 193–225]. A practical stable representation is 32-bit, little-endian float PCM using `AVLinearPCMBitDepthKey`, `AVLinearPCMIsFloatKey`, and `AVLinearPCMIsBigEndianKey`; the installed SDK declares these keys and their value types [S3, lines 14–27]. Do not force a sample rate or channel count without a demonstrated need.
4. Read `CMSampleBuffer`s synchronously with `copyNextSampleBuffer()`. Skip marker-only buffers for which `CMSampleBufferGetNumSamples` is zero, and inspect `reader.status` after a `nil` result to distinguish completion, failure, and cancellation [S2, lines 80–100].
5. Access PCM through `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer`, which provides contiguous audio buffers and a retained block buffer governing their lifetime [S4, lines 857–890]. This avoids assuming that a sample buffer's raw storage is contiguous.

Only the audio output is added, so this analysis does not require video-frame decoding. Camenya capture explicitly prefers H.264 video [R1, lines 168–177], while validation already requires a finalized audio track [R2, lines 15–24]. Whatever source audio format `AVCaptureMovieFileOutput` wrote, the reader-output conversion boundary presents PCM to the heuristic.

### 2. Derive a conservative suggestion

The following is an engineering recommendation, not behavior supplied by Apple:

- Aggregate all channels into short fixed-duration windows (approximately 10–30 ms) and calculate RMS energy. Convert it to dBFS with a small nonzero floor.
- Smooth several adjacent windows. Require sustained activity, not one loud sample, to enter the retained region; use hysteresis so the exit threshold is lower than the entry threshold.
- Find only the first and last sustained active regions. Keep every internal pause between them in this feature.
- Expand both boundaries with conservative pre/post-roll (initially around 200–400 ms), then clamp to the valid video range.
- Treat thresholds, sustained-duration rules, and padding as tuning parameters. Validate them with representative recordings on an iPhone before fixing defaults.
- Return “no suggestion” rather than an aggressive range when there is no audio track, no sustained activity, invalid timing, a negligible saving, or a range shorter than the minimum usable Take.

This is an amplitude detector, not a speech detector. Breathing, handling noise, a button tap, music, or room noise may count as activity; quiet opening consonants may look inactive. The raw Take therefore remains immutable and the user must be able to retain or adjust the original boundaries.

Timestamp boundaries should come from sample-buffer presentation timestamps and durations rather than from a presumed sample rate. CoreMedia exposes the earliest presentation timestamp, total duration, and sample count for each buffer [S5, lines 1197–1233]. Keep range calculations as `CMTime` until the persistence boundary to avoid cumulative floating-point drift.

### 3. Concurrency and cancellation

`AVAssetReader` and `AVAssetReaderOutput` are declared `NS_SWIFT_NONSENDABLE` [S1, lines 47–63; S2, lines 31–43]. The synchronous reader, output, sample loop, and mutable accumulator should therefore stay on one non-main serial execution context. Analyze Takes sequentially at first; this also bounds CPU, memory, and thermal load.

Cancellation must be cooperative:

- Check Swift task cancellation between buffer reads.
- Invoke `cancelReading()` from that same serialized context, between calls to `copyNextSampleBuffer()`.
- Never call it concurrently from the UI/main actor: Apple's contract explicitly forbids concurrent `cancelReading()` and `copyNextSampleBuffer()` calls [S1, lines 214–224].
- Surface cancellation separately from decode failure and do not modify persisted trim data until one Take's analysis completes.

The iOS 26 SDK adds `AVAssetReader.outputProvider(for:)`, async `Provider.next()`, and throwing `start()` [S6, lines 84–122; S6, lines 2042–2046]. Those APIs are iOS 26-only, while Camenya targets iOS 18 [R3, lines 96–101]. The initial implementation must therefore use the serialized legacy reader path. An iOS 26 branch can be evaluated later, but is not required for this feature.

## Preview

For a lightweight “Original / Trimmed” comparison on the existing `AVPlayer`:

- Original: set `forwardPlaybackEndTime = .invalid`, then seek to the original start.
- Trimmed: set `forwardPlaybackEndTime` to the selected end, seek to the selected start, and start playback only after the seek completion reports success.
- On completion, seek back to the active range's start, not unconditionally to zero.
- Clamp scrubbing to the active range in the UI.

`forwardPlaybackEndTime` stops positive-rate playback at the selected time and posts `AVPlayerItemDidPlayToEndTime`, but does not alter the item duration [S7, lines 195–206 and 282–313]. It defines no start boundary; the explicit seek is required. Zero seek tolerance requests higher precision but can cost latency, so interactive dragging can use tolerances while final boundary auditioning can request a precise seek.

If a zero-based trimmed timeline is preferable, create an `AVPlayerItem` from an `AVMutableComposition` containing only the selected range. That is more setup but makes the presented duration equal to the retained range. Either approach remains non-destructive.

## Export integration

The existing exporter already builds one `AVMutableComposition`, inserts each source video range at a cursor, intersects it with the source audio range, preserves the audio offset, and advances the cursor by the inserted video duration [R4, lines 51–98]. The trim feature should change the source range, not create an intermediate trimmed movie:

1. Interpret an approved Take-relative range against the source video's loaded `timeRange`.
2. Clamp/intersect it with that video range.
3. Insert the selected video range at the current composition cursor.
4. Intersect the selected video range with the audio track's `timeRange`, and insert that audio intersection at `cursor + (audioIntersection.start - selectedVideoRange.start)`.
5. Give the video-composition instruction the selected duration and advance the cursor by that duration.

`AVMutableCompositionTrack.insertTimeRange(_:of:at:)` is available on the deployment target and inserts a source range at its natural duration and rate [S8, lines 140–157]. Applying one validated range coherently to video and audio preserves their relative timing, including a legitimate leading interval where video exists before audio begins.

Export should fail safely or fall back to the original range if persisted data is invalid; it must never delete or rewrite `take.mov`. The existing export session can continue producing the sole finalized Project Export. No change is needed to Photos authorization or saving because trimming occurs before that existing boundary.

## Deployment and failure considerations

- Required reader/composition/player APIs predate iOS 18; no deployment-target increase is needed. The optional provider API must not be used without an iOS 26 availability branch.
- Reader output settings must be validated by `canAdd`/`startReading`; unsupported or incompatible output settings can prevent initialization or start [S1, lines 153–205; S2, lines 243–282].
- Asset, audio, and video time ranges can start at nonzero times and can differ. Never assume `[0, asset.duration]` is valid for every source track.
- PCM can be mono or multichannel and interleaved or non-interleaved. Either request a specific layout and verify it, or parse the returned `AudioBufferList` according to its actual format.
- A missing/empty audio intersection is not an export error in the current exporter; preserve that behavior and retain video timing.
- Do not claim accuracy, performance, or physical capture verification until the heuristic is exercised with real Camenya Takes on an iPhone.

## Primary sources inspected

- **S1 — AVAssetReader contract:** `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.2.sdk/System/Library/Frameworks/AVFoundation.framework/Headers/AVAssetReader.h`
- **S2 — AVAssetReader output contract:** `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.2.sdk/System/Library/Frameworks/AVFoundation.framework/Headers/AVAssetReaderOutput.h`
- **S3 — PCM output-setting keys:** `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.2.sdk/System/Library/Frameworks/AVFAudio.framework/Headers/AVAudioSettings.h`
- **S4/S5 — audio-buffer access and sample timing:** `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.2.sdk/System/Library/Frameworks/CoreMedia.framework/Headers/CMSampleBuffer.h`
- **S6 — iOS 26 Swift reader APIs:** `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.2.sdk/usr/lib/swift/AVFoundation.swiftmodule/arm64e-apple-ios.swiftinterface`
- **S7 — bounded playback:** `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.2.sdk/System/Library/Frameworks/AVFoundation.framework/Headers/AVPlayerItem.h`
- **S8 — composition-track insertion:** `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.2.sdk/System/Library/Frameworks/AVFoundation.framework/Headers/AVCompositionTrack.h`
- **R1 — current capture format preference:** [`Camenya/Camera/CameraController.swift`](../../Camenya/Camera/CameraController.swift)
- **R2 — current finalized-media validation:** [`Camenya/Recording/SegmentValidator.swift`](../../Camenya/Recording/SegmentValidator.swift)
- **R3 — current deployment target:** [`Camenya.xcodeproj/project.pbxproj`](../../Camenya.xcodeproj/project.pbxproj)
- **R4 — current Project composition/export:** [`Camenya/Projects/ProjectExporter.swift`](../../Camenya/Projects/ProjectExporter.swift)

## Decision-ready recommendation

Proceed with an optional, non-destructive “suggest → review/adjust → approve → export” flow limited to leading and trailing low-audio regions. Build the analyzer behind a small non-UI interface, keep the legacy reader confined to one serial context, persist only validated selection metadata, use the same range for bounded preview and composition export, and defer internal-pause removal and speech classification to separate features.
