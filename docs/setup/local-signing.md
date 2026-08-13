# Local signing boundary

Camenya is published as source code. Each person who installs it creates and signs a private build with their own Apple Account. The project never distributes a signed app and never needs to know anyone's Apple credentials or identifiers.

## What the local file contains

`Scripts/configure-local-signing.sh` writes three values to `.camenya/local-signing.plist`:

- the Apple Development Team ID selected in Xcode;
- the destination ID of the physical iPhone;
- a unique bundle identifier for that local copy.

The directory is restricted to its owner, the plist has `0600` permissions, and both its final and temporary filenames are ignored by Git. The installer reads the plist as data; it does not execute or source it. The script deliberately does not infer a Team ID from certificate labels.

These identifiers are not passwords, but they are personal build metadata. Do not paste them into issues, pull requests, screenshots, public prompts, CI variables, or tracked Xcode settings. The scripts do not require an Apple password, private key, certificate export, or provisioning profile path.

## Guided setup

Configure Xcode with your Apple Account, connect and unlock the iPhone, then run:

```sh
Scripts/configure-local-signing.sh --install
```

The wizard shows Xcode's local destinations, asks for the three values, writes the ignored configuration, then builds and installs Camenya. Later installs need only:

```sh
Scripts/install-debug-app.sh
```

To review destinations without saving anything:

```sh
Scripts/configure-local-signing.sh --show-destinations
```

Delete `.camenya/local-signing.plist` to forget the local configuration. The next installer run will stop and ask you to configure again.

## Use with a local AI coding agent

An AI agent running on the Mac may inspect the source and run the same scripts. Ask it to explain `Scripts/configure-local-signing.sh` and `Scripts/install-debug-app.sh` before execution if desired. It can start the wizard, but personal values should be entered only through a trusted local terminal or injected as local process environment variables—not posted to a public conversation or written into repository files.

The agent should verify all of the following before installation:

1. `git check-ignore .camenya/local-signing.plist` succeeds.
2. `Scripts/verify-public-repository.sh` succeeds.
3. The build uses `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` only as command-line overrides.
4. No signing or device value appears in `git diff` or `git status`.

## Security properties and limits

The plist separates public source from local Apple identity and reduces accidental commits. It is not a secret vault: another process running as the same macOS user may read it. Xcode and Apple's tooling still create certificates and provisioning material in their normal private locations outside this repository.

The scripts build only the checked-out source. Users remain responsible for reviewing the source, trusting the Mac and connected iPhone, maintaining access to their Apple Account, and understanding Apple's provisioning limits.
