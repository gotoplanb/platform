# Stacks & the dependency graph

The estate is decomposed into small Terragrunt stacks, each owning one concern and wired by
`dependency` blocks. Terragrunt computes the DAG, so `run --all` applies/destroys in the right
order and parallelizes independent units.

## Layout

```
account/                      # account-scoped, platform plane
  github-oidc/                #   GitHub OIDC provider + gha-apply/gha-plan roles
  budgets/ budget-{prod,staging,platform}/   # daily cost budgets per plane
watch/us-east-1/
  ecr/                        # shared IMMUTABLE image repo (promote by digest)
  connection/                 # persistent GitHub CodeConnections (authorized once)
  ci-trigger/                 # OIDC role the app repo assumes to start the pipeline
  pipeline/                   # region-level CodePipeline (spans both envs)
  <env>/                      # env ∈ {prod, staging}
    network/ data/ config/    # VPC/subnets/NAT/SG · RDS+Valkey · SSM+AppConfig
    cert/ dns/                # ACM cert (applies first) · app+status CNAMEs
    app/                      # ECS Fargate + ALB + sidecars
    escalation/ intake/       # Step Functions+Lambdas · API GW+SQS+consumer
    frontend/ observability/  # S3+CloudFront status page · alarms + log data-protection
```

## Dependency DAG (per environment + the shared bits)

```
ecr ─────────────┐
connection ──► pipeline ◄── ci-trigger(→ github-oidc)
                   ▲
   network ──► data ──┐         (pipeline also depends on both envs' app+network outputs)
      │        config │
      ▼          │    ▼
    cert ─────►  app ─┴─► escalation
      │           │  └──► intake
      │           │  └──► frontend ──► dns ◄── app (alb_dns)
      │           └──► observability
      └──────────────────────────────► (cert consumed by app :443 + frontend CloudFront)
```

Key edges:

- **`cert` before `app`** — the app takes the cert ARN as an input, so the cert stack applies
  first. This is the split that breaks the old bootstrap cycle (see [foundations](foundations.md)
  → DNS/TLS).
- **`dns` last** — the app/status CNAMEs point at the ALB + CloudFront, so `dns` (records only)
  depends on `app` + `frontend`.
- **`pipeline`** depends on `ecr`, `connection`, and **both** envs' `app`/`network` outputs (it
  deploys to both), so it applies after the envs.

## What each stack owns

| Stack | Owns |
|---|---|
| `network` | VPC, public/private subnets ×AZ, NAT, security groups, VPC interface endpoints |
| `data` | RDS Postgres (Multi-AZ in prod) + Secrets Manager rotation, ElastiCache Valkey, KMS |
| `config` | SSM SecureString params (Django key, intake secret), AppConfig app/env/profile + flags |
| `cert` | ACM cert (us-east-1) for `watch[-stg]` + `status[-stg]`, DNS-validated via Cloudflare |
| `app` | ECS cluster/service, task def (app + appconfig-agent + alloy sidecars), ALB + blue/green TGs + listeners |
| `escalation` | Step Functions Standard state machine + `record_token`/`commit` Lambdas + a failed-execution alarm |
| `intake` | API Gateway (HTTP) → SQS (+ DLQ) → consumer Lambda; the REQUEST authorizer |
| `frontend` | Private S3 + CloudFront (OAC) status page + the security response-headers policy |
| `dns` | The `watch`/`status` CNAMEs → ALB/CloudFront (records only; cert is separate) |
| `observability` | CloudWatch alarms (ELB/target 5xx, failed executions) + Logs data-protection (masked drains) |
| `ecr` | The one immutable `watch` repo (both envs pull the same digest) |
| `connection` | The GitHub CodeConnections connection (authorize once; survives recreate) |
| `ci-trigger` | Least-privilege OIDC role: `StartPipelineExecution` on the one pipeline |
| `pipeline` | CodePipeline + CodeBuild (build/DAST/smoke) + per-env CodeDeploy apps/groups + migrate-hook Lambdas |

## Kept vs ephemeral — the lifecycle boundary

Teardown (`make teardown`) destroys the **per-env** stacks + `pipeline` and drops the CNAMEs.
It **keeps** the foundation (~$0 at rest): the state backend, `ecr` (+ the `:bootstrap` image),
both `cert` stacks, `connection`, `ci-trigger`, `account/*`, `github/*`. So a later `make live`
is fast and clean — no cert revalidation, no re-authorization, no CNAME conflict. See
[delivery](delivery.md) → lifecycle for the exact targets.

## The multi-provider pattern

Most stacks use only the root-generated `aws` provider. Stacks that also manage Cloudflare
(`cert`, `dns`) add it via a deep-merge include override plus a `generate "versions"` block that
re-declares `aws` **and** `cloudflare` (only one `required_providers` per module). The
`cloudflare` token comes from `.env` at apply time; records are surgical — only the named
subdomains + ACM validation, **never the apex**.
