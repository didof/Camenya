# Development workflow: sequential pull requests

Camenya development uses one independently testable product increment per pull request.

## Required sequence

1. Start feature work from the exact prerequisite commit that a maintainer has accepted, including physical-iPhone verification when the behavior requires it.
2. Create a focused feature branch before changing product code.
3. Keep the pull request scoped to one user-testable feature and its tests, specification, ADRs, and research.
4. Run the repository verification commands from `AGENTS.md` and record whether physical iPhone verification was actually performed.
5. Push the branch and open a pull request. Do not merge it or start a dependent feature until the required maintainer verification is complete, unless a stacked draft pull request was explicitly approved.
6. After acceptance and merge, update local `main` before branching for the next feature.

## Stacked work

A feature that depends on an unmerged pull request may use a stacked draft pull request only with explicit maintainer approval. Its description must name the base branch, prerequisite pull request, and commit. Rebase or retarget it onto `main` only after the prerequisite is accepted and merged.
