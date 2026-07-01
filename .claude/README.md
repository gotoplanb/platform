# .claude/ — agent permission policy (audit gate)

`settings.json` encodes a deliberate audit model for the Watch estate lifecycle:

> **The machine runs the whole lifecycle deterministically; a human physically approves
> exactly two commands — one to create, one to destroy.**

Everything Claude needs to build, verify, migrate, seed, deploy the status page, sweep for
orphans, and commit is **pre-allowed** (no prompts). The only actions that **require a human
approval** are the create and destroy entry points — the consequential, cost-bearing,
hard-to-reverse operations — so the audit trail is unambiguous about who authorized them.

## What prompts (the two levers)
- **Create:** `make live` / `make create` / `make create-staging|-prod` / `make up` / `make recreate`
- **Destroy:** `make teardown` / `make teardown-staging|-prod` / `make down` / `make recreate`
- Plus the underlying paths they wrap, so they can't be reached un-prompted:
  `scripts/create.sh`, `scripts/teardown.sh`, and raw `terragrunt/tofu apply|destroy` (incl.
  `run --all apply|destroy`).

Because a make target is a single shell invocation, approving `make live` **once** runs the
entire create → migrate → seed → deploy-frontend chain; approving `make teardown` **once**
runs the whole parallel teardown. One human decision per lever.

## What runs without prompting (deterministic)
`make migrate` / `make seed` / `make deploy-frontend` / `make sweep`, the read/verify tooling
(`terragrunt output`, `aws` reads, `curl`, `git`, Playwright via the MCP gateway), and file
edits. Prefer make targets over ad-hoc commands so the deterministic path stays legible.

## Guardrails (`deny`)
`sudo` and force-pushes are denied outright — never silent, never auto-approved.

Notes:
- Precedence is `deny` > `ask` > `allow`, so the broad `Bash` allow can't override a gate.
- This is a **project (checked-in) policy** on purpose — the gate itself is versioned and
  auditable. Personal overrides belong in `.claude/settings.local.json` (git-ignored).
