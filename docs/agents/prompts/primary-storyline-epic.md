# Clean-task goal prompt: Primary Storyline Epic

Use the following prompt to start a new Codex task from a clean worktree.

```text
Own the Camenya non-destructive Primary Storyline Epic with the rigor of a senior iOS product engineer and technical lead.

Start by reading, completely and in this order:
1. AGENTS.md and every referenced repository workflow document.
2. PRODUCT.md and DESIGN.md.
3. CONTEXT.md and docs/adr/0008-adopt-a-non-destructive-primary-storyline.md.
4. docs/epics/primary-storyline.md.
5. docs/research/mobile-timeline-editing-models.md.

The accepted product ceiling is fixed: Camenya is a narrative recorder with one non-destructive Primary Storyline, not a multitrack editor or creator suite. Music is out of scope. Do not reopen settled product decisions unless repository evidence exposes a real contradiction.

Use the appropriate skills explicitly:
- $domain-modeling for any domain-language conflict or change.
- $codebase-design to design a deep TimelineEditor boundary and compare interfaces before implementation.
- $impeccable shape for every new or materially changed UI surface, applying PRODUCT.md and DESIGN.md as authority.
- $tdd for deterministic domain, persistence, Project Time, and snapshot behavior.
- $code-review before publication, reviewing both repository standards and correctness.
- $github:github to reconcile the Epic with existing public issues and create only missing, independently testable child issues.
- $github:yeet only after verification, to commit intentionally, push, and open a draft pull request.

Treat docs/epics/primary-storyline.md as the execution contract. Deliver one independently testable phase per branch and pull request. Begin with Phase 1, Foundation, only. Before product-code changes, ensure its GitHub issue has the user problem, smallest useful outcome, non-goals, acceptance criteria, and exact prerequisites. Create a codex/ prefixed feature branch from the accepted prerequisite commit.

For Phase 1, first inspect the current model and write the smallest coherent design for Take source identity, Timeline Clip occurrence identity, Primary Storyline persistence, Project Time mapping, automatic full-range Clip creation, immutable preview/export snapshot, and revision-safe asynchronous work. Preserve current media. The UI may change only where the foundation increment requires a user-testable outcome. Do not implement later phases opportunistically.

Follow repository verification exactly. Never claim physical iPhone testing unless it occurred. Stop after opening the Phase 1 draft pull request and provide: the issue and PR links, prerequisite commit, changed domain/interface summary, tests and build results, known physical-device checks, and the explicit acceptance gate before Phase 2. Do not start Phase 2 until the maintainer has accepted and physically validated the prerequisite where required, unless the maintainer explicitly approves a stacked draft.
```
