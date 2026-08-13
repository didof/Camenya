# Public launch checklist

This checklist separates the inspectable source snapshot from the GitHub settings that cannot be enforced by repository files alone.

## 1. Freeze and verify the source snapshot

- Run `Scripts/verify-public-repository.sh`.
- Run the required unsigned generic iOS Simulator build.
- Compile and run tests on an installed iPhone Simulator, excluding the physical-only caption burn-in integration test.
- Confirm `git diff --check` passes.
- Inspect the complete candidate file list, including dotfiles and executable bits.
- Confirm `.scratch/`, `.impeccable/`, `output/`, `.artifacts/`, local signing data, Derived Data, and Xcode user data are absent.
- Confirm the snapshot contains `LICENSE`, `DCO`, `GOVERNANCE.md`, `CONTRIBUTING.md`, `SECURITY.md`, `SUPPORT.md`, and `TRADEMARKS.md`.

## 2. Publish into a fresh repository

Create `didof/Camenya` as a new repository rather than changing the visibility of, renaming, or force-pushing the historical private repository. Push only a new root commit made from the verified source snapshot. This keeps historical Apple identity, device metadata, working timestamps, deleted files, and unreachable Git objects out of the public repository.

The public root commit must:

- use the actual author and committer identity intended for public attribution;
- use the actual current timestamp—never a rewritten timestamp designed to imply different working hours;
- include a matching DCO `Signed-off-by` line;
- have no parent commits.

Keep the historical private repository private as the provenance archive. Do not add it as a public remote or upload a bundle, mirror, backup, or repository export containing its object database.

After pushing, clone the public repository into a new temporary directory and verify:

```sh
git rev-list --all --count
git log --format=fuller --decorate --all
Scripts/verify-public-repository.sh
```

The first command must report `1` at launch. Inspect the sole commit and rerun the guardrail from the public clone.

## 3. Configure GitHub before announcement

- Set the description, website if any, topics, social preview, and `main` as the default branch.
- Apply every label in `.github/labels.yml` with the exact spelling and meaning.
- Configure the default-branch ruleset in `docs/maintainers/branch-protection.md`.
- Enable Issues and private vulnerability reporting.
- Allow squash merges; disable merge commits and rebase merges for the initial one-increment history policy.
- Disable Wikis, Projects, Discussions, and Sponsorships unless the project has deliberately chosen to maintain them.
- Do not create a GitHub Release or attach a binary. GitHub-generated source archives are acceptable.
- Confirm the issue-template security link resolves to the new repository's private reporting form.

## 4. Exercise the contribution boundary

Open a draft pull request from a disposable branch and prove that:

- a missing DCO sign-off blocks merge;
- a fake Team ID or absolute home path fails `Guardrails`;
- a Swift compile error fails `Unsigned build`;
- an approval becomes stale after a new commit;
- the code-owner review and unresolved-conversation rules block merge;
- a passing pull request can be squash-merged without bypass.

Delete the disposable branch after the test. Keep the closed pull request as public evidence that the controls were exercised.

## 5. Final human review

- Read the README from the perspective of someone with only a Mac, iPhone, Xcode, and Apple Account.
- Follow the local-signing wizard using synthetic screenshots; redact all local identifiers before publication.
- Verify every external link.
- Complete a dedicated trademark clearance for “Camenya” in the intended jurisdictions. Repository policy and domain availability are not trademark clearance.
- Confirm the public launch date and work circumstances truthfully in private records. Git timestamps are supporting evidence, not proof of intellectual-property ownership or separation from employment.
- Announce only after the source clone, GitHub controls, and private vulnerability path have all been tested.
