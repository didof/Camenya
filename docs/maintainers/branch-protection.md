# Default-branch protection

Repository files can define checks, but GitHub must be configured to make them mandatory. Before the repository is announced publicly, protect `main` with a ruleset that:

- requires pull requests and prevents direct pushes;
- requires zero approving reviews while the project has only one maintainer;
- does not require Code Owner approval while the only Code Owner may also be the pull-request author;
- requires all review conversations to be resolved;
- requires the `Guardrails`, `DCO`, and `Unsigned build` status checks;
- requires the branch to be up to date before merge;
- blocks force pushes and branch deletion;
- applies to administrators and repository maintainers;
- permits squash merge and disables merge commits, keeping one reviewed increment per public commit;
- does not allow a check or review bypass for ordinary feature work.

This is the single-maintainer bootstrap mode. GitHub does not allow a pull-request author to approve their own change, so requiring one approval or Code Owner approval from `@didof` would make every maintainer-authored pull request impossible to merge. The remaining rules still force changes through a visible pull request and the complete automated boundary.

As soon as a second trusted maintainer becomes a Code Owner, raise the required approval count to one, require Code Owner review, and dismiss stale approvals when the diff changes. Do not represent the bootstrap mode as independent human review.

After configuring the ruleset, test it with a draft pull request that deliberately fails each required check. A settings screenshot is not verification; the merge button must actually remain blocked.

GitHub-hosted settings are part of the release boundary. Recheck them after ownership transfers, organization migrations, plan changes, or ruleset edits.

Also enable private vulnerability reporting under the repository's security settings so the path documented in `SECURITY.md` and the issue-template link are active before announcement.
