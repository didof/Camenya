# Camenya project governance

This document defines what the official Camenya project is, what it must remain, and how changes earn the right to be merged. It applies to maintainers, contributors, automation, documentation, and releases.

The GPL permits anyone to fork the code. It does not require the official project to accept every contribution or to change its identity. Maintainers are responsible for protecting that identity.

## Mission

Camenya is a focused, local-first iPhone recording tool. It helps one person assemble a coherent Project from multiple Takes and camera perspectives while keeping unfinished media on that person's device.

The project values predictable capture, recoverability, user agency, inspectable source code, and a small understandable system over growth, lock-in, engagement, or feature count.

## Constitutional invariants

The following are not ordinary implementation preferences:

1. **Source-only distribution.** The official project publishes source code. It does not publish or endorse signed `.app`, `.ipa`, `.xcarchive`, TestFlight, App Store, ad hoc, or enterprise distributions.
2. **Bring your own signing identity.** Every user builds with their own Apple Account, Team, certificate, profile, device, and—when needed—bundle identifier. The project owns and shares none of them.
3. **Local-first media.** Unfinished Projects, Takes, Segments, notes, trim metadata, and caption metadata remain on the device. There is no upload, synchronization, account, server, tracking, advertising, or telemetry path.
4. **Explicit export boundary.** Only an explicit finalized Project Export may be offered to Photos. In-app Takes and intermediate media are never offered directly.
5. **Recoverability before cleverness.** A failure during capture, switching, interruption, export, saving, or storage handling must preserve every piece of media that can still be recovered.
6. **Predictable capture semantics.** Pause ends a Segment, Resume starts a Segment, and Flip is permitted only while idle or paused.
7. **Native and inspectable.** Runtime code uses Apple system frameworks and no third-party runtime dependency. A contributor should be able to audit the complete data path in this repository.
8. **Best-effort community.** Contributions are welcome, but the project promises no support, response time, roadmap, compatibility window, or merge.

Any proposal that contradicts an invariant is outside the current project. It must not be hidden inside a feature pull request.

## Identity and privacy boundary

Public contributor attribution and private Apple development identity are different things.

Git author names, Git author emails, DCO sign-offs, pull-request authorship, review history, and an optional contributors list are normal public project records. Contributors should use a public or GitHub-provided no-reply email if they do not want a private email exposed in Git history.

Repository content must never contain a contributor's:

- Apple Account address or private account metadata;
- Development Team identifier;
- certificate, private key, serial number, fingerprint, or Keychain reference;
- provisioning profile, profile UUID, or profile name;
- device UDID, CoreDevice identifier, Xcode destination identifier, or custom device name;
- personal bundle identifier used only to install a local build;
- absolute home-directory path, raw build log, result bundle, or Xcode user data that exposes local machine identity.

Compiled or signed Apple artifacts are also forbidden. The supported boundary is `.camenya/local-signing.plist`, created by `Scripts/configure-local-signing.sh`. It is ignored by Git, readable only by its local owner, and consumed only while building a self-signed copy. Environment variables may override it for local automation. Neither form becomes project configuration, and diagnostic excerpts must remove these values before sharing.

## Permissions and capabilities

The accepted permission surface is Camera, Microphone, Speech Recognition for an explicit on-device caption action, and add-only Photos access for explicit Project Export.

Camenya has no checked-in entitlement file. New entitlements, capabilities, background modes, network access, cloud services, accounts, telemetry, advertising, payments, or third-party dependencies are constitutional changes. The repository guardrails reject them until this document and the guardrail itself are deliberately amended in a separate governance pull request.

## Change classes

### Regular changes

Focused bug fixes, accessibility improvements, tests, documentation, and bounded features that preserve all invariants may use the normal contribution process.

### Protected changes

A change is protected when it affects capture state, media lifetime, deletion, recovery, Project Export, permissions, privacy, signing, distribution, dependencies, branding, licensing, or governance. Its pull request must explain:

- the user problem and the smallest proposed solution;
- failure and recovery behavior;
- privacy, permission, and distribution impact;
- alternatives considered;
- automated verification and any physical-iPhone evidence.

A maintainer must explicitly approve a protected change.

### Constitutional changes

A proposal that alters an invariant must be a standalone governance pull request with no product implementation. It must identify the invariant, explain why the existing boundary is no longer adequate, describe risks and alternatives, and update both the written policy and its automated enforcement. Product work may begin only after that governance change is merged.

## Pull requests and merge authority

- One pull request represents one independently understandable and testable increment.
- Every commit carries a DCO `Signed-off-by` line.
- The pull request template is completed truthfully; unchecked or not-applicable items are explained.
- Repository guardrails and the unsigned simulator build pass.
- Physical verification is never inferred from simulator results and is never claimed unless the exact commit was exercised on an iPhone.
- Required conversations are resolved and a code owner approves the final diff.
- Maintainers may request changes, close, defer, or decline a pull request even when CI passes. Passing automation establishes eligibility for review, not entitlement to merge.

Direct pushes, force pushes, branch deletion, and bypassing required checks on the default branch are prohibited by the project's branch-protection policy.

## Decision records

`CONTEXT.md` is the canonical glossary. Architectural decisions are recorded only when they are costly to reverse, surprising without context, and the result of a real trade-off. Governance decisions live here rather than being scattered through pull-request comments.

## Enforcement

`Scripts/verify-public-repository.sh` is the executable form of the repository boundary. CI runs it for every pull request. `.github/CODEOWNERS` identifies the review authority, and `docs/maintainers/branch-protection.md` defines the GitHub settings required to make the checks non-optional.

No automated rule is complete. Reviewers remain responsible for noticing semantic changes that technically pass a pattern check while violating the purpose of an invariant.
