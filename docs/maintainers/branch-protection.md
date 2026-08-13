# Default-branch protection

Repository files can define checks, but GitHub must be configured to make them mandatory. Before the repository is announced publicly, protect `main` with a ruleset that:

- requires pull requests and prevents direct pushes;
- requires at least one approving review;
- requires review from Code Owners;
- dismisses stale approvals when the diff changes;
- requires all review conversations to be resolved;
- requires the `Guardrails`, `DCO`, and `Unsigned build` status checks;
- requires the branch to be up to date before merge;
- blocks force pushes and branch deletion;
- applies to administrators and repository maintainers;
- permits squash merge and disables merge commits, keeping one reviewed increment per public commit;
- does not allow a check or review bypass for ordinary feature work.

After configuring the ruleset, test it with a draft pull request that deliberately fails each required check. A settings screenshot is not verification; the merge button must actually remain blocked.

GitHub-hosted settings are part of the release boundary. Recheck them after ownership transfers, organization migrations, plan changes, or ruleset edits.

Also enable private vulnerability reporting under the repository's security settings so the path documented in `SECURITY.md` and the issue-template link are active before announcement.
