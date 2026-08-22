# Camenya repository guidance

## Product invariants

- A Take is one user-visible recording assembled from one or more Segment files.
- Pause ends the current Segment. Resume starts a new Segment.
- Flip is allowed only while idle or paused, never while a Segment is recording.
- Only explicit user-requested output boundaries may save to Photos: Finish Video saves one validated Clean Master checkpoint, and Project Export saves the finalized presentation. In-app Takes are never offered directly.
- Prefer predictable capture behavior over cleverness.

## Engineering constraints

- Use Swift, SwiftUI, AVFoundation, PhotoKit, and OSLog only.
- Keep camera and media behavior outside SwiftUI views.
- Serialize all capture-session mutations on one dedicated queue.
- Drive asynchronous transitions from AVFoundation completion callbacks; never add timing sleeps.
- Preserve recoverable media after any export, save, switch, interruption, or storage failure.
- Do not claim physical capture verification unless it was performed on an iPhone.

## Verification

- Run `xcodebuild -project Camenya.xcodeproj -scheme Camenya -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`.
- Run automated tests only on an installed iOS Simulator destination.
- Never build, test, install, or launch Camenya with a macOS or `Designed for [iPad,iPhone]` destination. Camenya is an iPhone app, and attempting to install the unsigned iOS app on macOS produces misleading integrity/damage alerts.
- Do not run the Core Animation caption burn-in integration test on iOS Simulator. The Simulator video compositor crashes Camenya and causes a host macOS “Camenya quit unexpectedly” alert. Keep deterministic caption timeline tests on Simulator; run the visual burn-in integration test only on the physical iPhone and only after the user explicitly authorizes that device test.
- Run `git diff --check` before committing.

## Development workflow

- Implement each independently testable feature on its own branch and deliver it through a pull request; do not add new feature commits directly to `main`.
- Keep one user-testable product increment per pull request so builds can be installed and evaluated sequentially.
- Do not begin a dependent feature until a maintainer has validated its prerequisite on a physical iPhone, unless a stacked draft pull request is explicitly approved.
- Record the exact prerequisite commit or pull request in the dependent feature's ticket and pull request description.
- See `docs/agents/development-workflow.md` for the branch, verification, and handoff sequence.

## Physical iPhone installation

- Use `Scripts/install-debug-app.sh` when asked to load the current app onto the connected phone.
- Run `Scripts/configure-local-signing.sh` first. It stores Team, device, and bundle values in the ignored `.camenya/local-signing.plist`; never copy them into a tracked file.
- `CAMENYA_DEVICE_ID`, `CAMENYA_TEAM_ID`, and `CAMENYA_BUNDLE_ID` may override the local plist for private automation. Never expose those overrides in tool output, prompts, issues, or pull requests.
- The signed build requires both `-allowProvisioningUpdates` and `-allowProvisioningDeviceRegistration`.
- The iPhone must be connected and unlocked when the signed build starts; otherwise Xcode may omit it from `-showdestinations`. The script checks this before building.
- Install and launch with `xcrun devicectl`; the CoreDevice identifier printed by `devicectl list devices` may differ from the Xcode destination identifier.
- A locked iPhone still accepts installation but rejects automatic launch with `RequestDenied ... Locked`. Treat that as a successful upload and ask the user to unlock/open the app; the install script handles this case explicitly.
- `CAMENYA_DERIVED_DATA` may override the temporary build location.

## Agent skills

### Issue tracker

Public work is tracked in GitHub Issues. Agents may keep disposable private notes under the ignored `.scratch/` directory. See `docs/agents/issue-tracker.md`.

### Domain docs

This is a single-context repository with `CONTEXT.md` and root ADRs. See `docs/agents/domain.md`.
