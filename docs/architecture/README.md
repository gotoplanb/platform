# Watch — architecture

Watch is an **incident intake & tiered-escalation platform**. This directory is the
"how it all fits together" reference. It complements — doesn't duplicate — the other docs:

| Doc | Answers |
|---|---|
| [`../../ROLLOUT.md`](../../ROLLOUT.md) | The rollout plan + sequence + cost profiles |
| `gotoplanb/watch` → `watch-adrs.md` | **Why** — the decisions and tradeoffs (ADRs) |
| [`../../GOTCHAS.md`](../../GOTCHAS.md) | The traps discovered building it |
| [`../releases/`](../releases/) | What changed per version |
| **here** | The **system architecture** — stacks, runtime flows, delivery, foundations |

Read in order: **[stacks](stacks.md)** (how the IaC is decomposed) → **[runtime](runtime.md)**
(what serves traffic and how an incident flows) → **[delivery](delivery.md)** (how code reaches
prod) → **[foundations](foundations.md)** (network, DNS/TLS, security, cost) →
**[observability](observability.md)** (telemetry: sidecar → gateway → backend, tail-sampling).

## The shape of it

Two **planes** and two **environments**, in one AWS account (us-east-1), all Terragrunt/OpenTofu:

- **App plane** — the product: per-environment stacks (`network`, `data`, `config`, `cert`,
  `app`, `escalation`, `intake`, `frontend`, `dns`, `observability`).
- **Platform plane** — shared/foundation that outlives environments: `ecr` (the image),
  `connection` (GitHub), `ci-trigger` (the deploy OIDC role), `pipeline`, the state backend,
  GitHub OIDC, budgets. Authorized/created once; kept across teardowns.
- **prod** — persistent, `ha` (private subnets + NAT + Multi-AZ RDS). **staging** — `ha` too
  (a faithful, disposable rehearsal per ADR-019), single-AZ, torn down between releases.

```
                             davestanton.com (Cloudflare DNS-only)
        watch[-stg].davestanton.com                 status[-stg].davestanton.com
                 │  CNAME → ALB                              │  CNAME → CloudFront
                 ▼                                           ▼
        ┌──────────────────┐                        ┌──────────────────┐
        │  ALB  :443 (ACM)  │                        │  CloudFront (OAC) │  React status SPA
        │  blue/green TGs   │                        │  S3 (private)     │──┐  (fetches /api/status
        └────────┬─────────┘                        └──────────────────┘  │   cross-origin, CORS)
                 ▼                                                         │
        ┌──────────────────────────────┐                                  │
        │ ECS Fargate task              │  ◀───────────────────────────────┘
        │  app · appconfig-agent · alloy│
        └───┬───────┬───────────┬───────┘
            ▼       ▼           ▼
          RDS    Valkey     Step Functions ── commit λ   (escalation, one execution / incident)
        (system  (sessions,  (per-incident)
        of record) flags via AppConfig sidecar)

  Intake:  webhook → API Gateway → SQS → consumer λ → incident + start escalation
  Delivery: push → GitHub Actions (OIDC) → CodePipeline → CodeDeploy blue/green
```

## Invariants (don't violate without a new ADR)

- **The escalation engine**: one Step Functions Standard execution per incident; **ASL
  orchestrates, Python decides**; every transition is idempotent ("act if still applicable");
  the **commit Lambda is the sole writer** of transitions. (ADR-001/007/010 — see
  [runtime](runtime.md).)
- **The app names no telemetry backend** — OTLP to a local Alloy sidecar (ADR-016).
- **Build once, promote by digest** — no CodeBuild in the prod path (ADR-017 — see
  [delivery](delivery.md)).
- **Everything is Terraform** — AWS, GitHub, and Cloudflare providers; if Terraform can manage
  it, it does (ADR-006).
- **Two human touchpoints** — one approval to stand the estate up, one to promote code to prod;
  everything else is gated + automated.
