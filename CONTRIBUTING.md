# Contributing to Camenya

Thank you for helping Camenya. Read [GOVERNANCE.md](GOVERNANCE.md) first: contributions are evaluated against the project's nature, not only against whether the code works.

## Before writing code

Open or join an issue that states the user problem. Keep one independently testable product increment per pull request. Large ideas such as a teleprompter, overlays, flash controls, or caption customization are not automatically `good first issue`; they become beginner-friendly only after being decomposed into a small, bounded change with clear acceptance criteria.

For a protected change, discuss the design before implementation. A proposal that changes a constitutional invariant must follow the standalone governance process and cannot include product code.

## Local setup

Build and test without signing whenever possible:

```sh
xcodebuild -project Camenya.xcodeproj -scheme Camenya \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/camenya-derived \
  CODE_SIGNING_ALLOWED=NO build
```

For installation on an iPhone, use your own Apple identity through Xcode or run `Scripts/configure-local-signing.sh --install`. The wizard writes an ignored owner-readable plist; subsequent installs use `Scripts/install-debug-app.sh`. Never place those values in a source file, project file, `.xcconfig`, example, screenshot, test fixture, issue, or pull-request description. See [the local signing boundary](docs/setup/local-signing.md).

## Never commit

- `.app`, `.ipa`, `.xcarchive`, `.dSYM`, `.xcresult`, or other compiled/exported bundles;
- certificates, private keys, provisioning profiles, signing identities, or Export Options;
- Apple Team IDs, device IDs, custom device names, private Apple Account details, or personal installation bundle IDs;
- `xcuserdata`, Derived Data, raw logs, or absolute local home paths;
- entitlement files, new capabilities, dependency manifests, vendored frameworks, network clients, cloud SDKs, analytics, telemetry, advertising, or payment code without an already-merged governance amendment.

Run the guardrail before committing:

```sh
Scripts/verify-public-repository.sh
```

## Developer Certificate of Origin

Camenya uses the [Developer Certificate of Origin 1.1](DCO). By signing off a commit, you certify that you have the right to submit the contribution under the project's license.

Create signed-off commits with:

```sh
git commit -s
```

The resulting commit message must contain a line like:

```text
Signed-off-by: Your Public Name <your-public-email@example.com>
```

The name and email must match the commit author. A GitHub no-reply address is acceptable. DCO sign-off is not GPG signing and does not transfer your copyright. Contributions are licensed under the same `GPL-3.0-only` terms as the project; there is no contributor license agreement or automatic proprietary relicensing grant.

If an AI tool helped produce a contribution, the human contributor must still understand, review, test, and take responsibility for it before signing off.

## Pull request requirements

- Explain the user-visible outcome and why it belongs in Camenya.
- Describe failure, cancellation, and media-recovery behavior where relevant.
- State whether permissions, privacy, distribution, signing, dependencies, or the local-only boundary change.
- Add or update deterministic tests.
- Run `git diff --check`, the repository guardrail, and the required unsigned simulator build.
- Report physical-iPhone testing only when performed on the exact commit. Do not include device or signing identifiers in the report.
- Complete every applicable item in the pull request template.

CI and review may reject a contribution that exposes local identity, expands the trust boundary, or makes media loss more likely even if the feature otherwise works.

## Review and acceptance

Maintainers review for both implementation quality and project fit. They may ask for a smaller scope or decline work that increases ongoing maintenance, weakens the invariants, duplicates a system capability, or moves Camenya away from a focused local-first recorder.

No issue assignment, review, or passing check promises that a contribution will be merged or released.
