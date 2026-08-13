# Camenya

Camenya is a local-first, open-source iPhone camera for recording a story one perspective at a time. Pause closes the current Segment, Flip changes the selected camera while nothing is recording, and Resume begins a new Segment. Camenya preserves those Segments as one Take and combines the Project's Takes only when the user explicitly exports the Project.

Unfinished media stays inside the app. Camenya has no accounts, advertising, analytics, cloud service, network service, or third-party runtime dependency.

> Camenya is distributed as source code, not as a signed app. There is no official App Store, TestFlight, ad hoc, or enterprise build. Every user reviews, builds, signs, and installs their own copy with Xcode and their own Apple Account.

## What it does

- Records a Take from one or more uninterrupted Segment files.
- Allows Pause and Resume without including paused time.
- Allows front/rear camera changes only while idle or paused.
- Keeps recoverable local media when capture, export, saving, interruption, or storage operations fail.
- Organizes Takes into a Project Timeline.
- Offers non-destructive edge trimming and reviewed on-device captions.
- Saves to Photos only after an explicit finalized Project Export.

## Requirements

- A Mac with a compatible stable version of Xcode
- An iPhone running iOS 18 or later
- Your own Apple Account configured in Xcode
- A cable or trusted wireless connection between the Mac and iPhone
- Developer Mode enabled on the iPhone

Apple documents Developer Mode in [Enabling Developer Mode on a device](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).

## Build and install your own copy

Before running anything, inspect the repository yourself. If you prefer, ask a code-review tool or an AI assistant to explain the project, installation script, permissions, and data flow.

1. Clone the repository and open `Camenya.xcodeproj` in Xcode.
2. Add your Apple Account under Xcode Settings → Accounts.
3. Connect and unlock your iPhone, trust the Mac when prompted, and enable Developer Mode.
4. Select the Camenya target. Under Signing & Capabilities, choose your own Team. If Xcode reports that the neutral bundle identifier is unavailable, use a unique identifier of your own locally.
5. Select your iPhone as the run destination and press Run.

The repository also provides a guided command-line installer. It creates one owner-readable local configuration that Git ignores, then uses those values only as build-time overrides:

```sh
Scripts/configure-local-signing.sh --install
```

Later builds need only `Scripts/install-debug-app.sh`. The wizard stores the Team ID, physical-device destination, and a generated or chosen bundle identifier in `.camenya/local-signing.plist`. The directory is restricted to its owner, the plist has `0600` permissions, and its final and temporary names are ignored by Git. No checked-in personal defaults exist.

Read the [local signing boundary](docs/setup/local-signing.md) for the exact data flow, deletion instructions, and safe use with a local AI coding agent. Personal values must never appear in a public prompt, issue, pull request, tracked Xcode setting, or build log attached to the project.

Provisioning duration and device limits depend on the type of Apple developer account used. Camenya does not receive, store, or manage anyone's Apple credentials, certificates, profiles, or device identifiers.

## Permissions

Camenya requests only the system permissions needed for its current behavior:

- Camera and Microphone for recording
- Speech Recognition for explicitly requested on-device captions
- add-only Photos access when the user exports a finished Project

Adding a capability, entitlement, permission, network path, account system, telemetry, cloud storage, or third-party dependency is a protected project-level decision, not an ordinary feature change.

## Contributing

Start with [GOVERNANCE.md](GOVERNANCE.md) to understand what Camenya must remain, then read [CONTRIBUTING.md](CONTRIBUTING.md) before opening an issue or pull request. The [issue-label guide](docs/community/issue-labels.md) explains how ideas such as flash control, a teleprompter, caption styles, and overlays become safe, bounded contributions.

Every contribution must pass the repository guardrails, use a DCO `Signed-off-by` line, and preserve Camenya's local-first, source-only distribution model. Contributor identity belongs in Git authorship and the DCO sign-off; personal Apple signing, provisioning, and device identity never belongs in repository content.

Camenya was created by [@didof](https://github.com/didof). Accepted work remains attributed through Git authorship, DCO sign-offs, pull requests, and GitHub's [contributors graph](https://github.com/didof/Camenya/graphs/contributors). The project does not use a CLA to transfer contributor copyright.

## Verification

Run the public repository guardrails:

```sh
Scripts/verify-public-repository.sh
```

Compile without signing:

```sh
xcodebuild -project Camenya.xcodeproj -scheme Camenya \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/camenya-derived \
  CODE_SIGNING_ALLOWED=NO build
```

Automated tests do not verify physical camera capture. A pull request may claim physical verification only when its exact commit was tested on an iPhone and the result is recorded in the pull request.

## Support and warranty

Camenya is maintained on a best-effort basis. The project does not promise support, response times, roadmap delivery, compatibility, availability, or preservation of user media; see [SUPPORT.md](SUPPORT.md). The software is provided without warranty; see the [GPL-3.0-only license](LICENSE) for the controlling terms. Security reports follow [SECURITY.md](SECURITY.md). The source license does not authorize presenting a fork as the official project; see [TRADEMARKS.md](TRADEMARKS.md).
