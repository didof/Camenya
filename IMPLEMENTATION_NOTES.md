# Camenya implementation notes

## Toolchain

- Xcode: 26.2 (build 17C52)
- Swift toolchain: Apple Swift 6.2.3
- Swift language mode: Swift 5
- Deployment target: iOS 18.0
- Dependencies: none

## Capture and media

- Capture target: SDR H.264/AAC QuickTime movies, 1920×1080, 30 fps where supported.
- Session: one wide-angle video input, one microphone input, one movie-file output, and one preview layer.
- Front preview is mirrored; movie output is explicitly unmirrored.
- A Rotation Coordinator provides preview rotation and freezes the capture rotation angle when a Take starts.
- One-Segment Takes save the validated Segment directly.
- Multi-Segment Takes use `AVMutableComposition`.
- Equivalent transforms use pass-through export.
- Differing transforms use a 1080p normalized video composition at 30 fps.
- PhotoKit access is add-only. Source files are removed only after confirmed save.

## Automated verification

- Generic iOS Simulator build passes with code signing disabled.
- The test target covers capture state, logical time, persistence, Segment ordering, recovery, trimming, captions, playback, and Project Export.
- The public-release rename was verified with 115 passing tests on an installed iPhone Simulator. The physical-only visual caption burn-in integration test was excluded as required by `AGENTS.md`.
- Simulator results do not establish physical camera, microphone, rotation, torch, interruption, or provisioning behavior.

## Physical verification

- Signed installation and basic launch have been exercised on an iPhone, but the project does not publish that signed build or its signing/device metadata.
- `Scripts/configure-local-signing.sh` writes the contributor's Team, device, and bundle values to an ignored owner-readable plist. `Scripts/install-debug-app.sh` supplies those values only as build-time overrides and uses automatic provisioning updates, device registration, and `xcrun devicectl` for local installation.
- Certificate display names are not a reliable way to infer a Development Team. Contributors obtain the Team identifier from their own Xcode account configuration.
- A locked device accepts `devicectl device install app` but rejects `device process launch` with `RequestDenied ... Locked`; the install script treats this as a successful upload and prints the required manual-unlock action.
- Xcode may omit a connected but locked phone from its build destinations. The install script preflights `-showdestinations` and asks for unlock before starting the signed build.

The complete timed capture and failure matrix is not part of this snapshot. Therefore mirroring, rotation, exact final duration, multi-Segment export, interruption behavior, and recovery are not claimed as fully verified on physical hardware.

## Known limitations

- The project intentionally leaves the Development Team out of the shared Xcode settings. The install script supplies the verified Team and device IDs at build time, avoiding a machine-specific project-file change.
- Exact 1080p/30 fps support is device-dependent. The app configures it when a matching built-in wide-angle format exists.
- Hard-crash recovery can preserve completed Segments; the file actively being written at the crash may be unusable.
