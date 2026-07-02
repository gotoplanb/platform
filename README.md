# platform

GoToPlanB **cloud** infrastructure as code — the cloud counterpart to
[`dev-infrastructure`](https://github.com/gotoplanb/dev-infrastructure) (which manages
the local stack). One **Terragrunt / OpenTofu** estate for **AWS**, **GitHub**
(`github` provider), and **Cloudflare** (`cloudflare` provider) across GoToPlanB
projects.

**Principle (ADR-006 in `gotoplanb/watch`):** if Terraform can manage it, it does —
no click-ops.

## Docs
- **[docs/architecture/](docs/architecture/)** — how it fits together: [stacks](docs/architecture/stacks.md),
  [runtime](docs/architecture/runtime.md), [delivery](docs/architecture/delivery.md), [foundations](docs/architecture/foundations.md).
- **[ROLLOUT.md](ROLLOUT.md)** — the rollout plan + sequence + cost profiles.
- **[GOTCHAS.md](GOTCHAS.md)** — traps discovered building it · **[docs/releases/](docs/releases/)** — per-version changes.
- Decisions/tradeoffs (ADRs) live in `gotoplanb/watch` → `watch-adrs.md`.

## Scope (intended)
- **AWS** — shared bootstrap (Terraform state backend, GitHub OIDC), per-project stacks
  (network / data / app / escalation / intake / frontend), CodePipeline blue/green.
- **GitHub** — repo config as code (settings, rulesets, required status checks, labels,
  repo variables) for the public `gotoplanb` repos (watch, watchtower, conduct, …),
  owner = `gotoplanb` user account, fine-grained PAT auth.
- **Cloudflare** — zones, DNS, TLS (personal account + zone-scoped token).

## Access posture (separation of duties)
Mutations go through CI (**CodePipeline via OIDC**); humans + Claude operate
**read-only** for verification. A **temporary bootstrap** credential creates the state
backend + OIDC, then is rotated/disabled.

## Status
Bootstrapping. The deep rollout plan and the sequenced work live (for now) in
`gotoplanb/watch` → `infra/ROLLOUT.md` + the AWS rollout epic; the Terragrunt itself
will be authored here.
