# AWS rollout plan — Watch (first project in the platform estate)

> Canonical plan, lives in `gotoplanb/platform` (the cloud IaC repo). Watch is the
> first project; the same Terragrunt estate will host the other gotoplanb projects.
> Tracking: the AWS rollout epic + sequenced issues in this repo's Issues.

Getting Watch running on AWS the way the ADRs specify: ECS Fargate behind an ALB,
**CodeDeploy blue/green**, AppConfig **feature flags**, Step Functions **escalation**,
durable **intake**, S3+CloudFront **status page**, OTel → **Watchtower**, all via
**Terragrunt** with **GitHub validates / AWS adjudicates** (ADR-004).

## Decisions for this rollout
- **Single AWS account; persistent `prod` + ephemeral `staging`.** Staging is spun up for
  a pipeline run (blue/green + migration exercise) then `terragrunt destroy`-ed — pay for
  pre-prod only while it runs. Single-region (ADR-005).
- **Cost profile = `lean` by default (ADR-015):** public subnets + public-IP Fargate
  (**no NAT**), RDS single-AZ (Multi-AZ optional) → **~$60–90/mo**. A Terragrunt toggle
  (`enable_nat`/`private_networking`, `multi_az`) flips to the **`ha`** profile (private
  subnets + NAT + Multi-AZ — the ADR-005 design) for occasional secure testing; both
  paths stay validated. See *Cost profile* + *Extending to private subnets + NAT* below.
- **GitHub → AWS via OIDC** role assumption — no long-lived keys.
- **This phase = author + validate IaC; apply deferred.** No AWS access in the build
  sandbox, so we write all Terragrunt + Lambda packaging and run `tofu validate` / `fmt`
  / hcl checks; `terraform apply` is gated on real credentials.
- **Everything as Terraform (ADR-006).** Terragrunt/OpenTofu manages not just AWS but
  **GitHub** (`github` provider — repo settings, rulesets/branch protection, the required
  CodeBuild status check, labels, repo variables) and **Cloudflare** (`cloudflare`
  provider — zone, DNS, TLS). Principle: **if Terraform can manage it, it does** — no
  click-ops. GitHub target is the **`gotoplanb` user account** (no org) — all repos are
  **public**, so rulesets/branch protection are free; auth via a **fine-grained PAT**.
  The repo config is a reusable module so it can extend to a handful of public
  `gotoplanb` repos (watch, watchtower, conduct). Cloudflare is a **personal account** +
  a **zone-scoped API token**.
- **Access posture (separation of duties).** A **temporary bootstrap credential**
  (write) creates the state backend + OIDC + initial provider config, then is rotated/
  disabled. In **normal operation Claude uses read-only credentials** (per service) to
  *verify* changes — **no writes via CLI**; every mutation flows through CodePipeline via
  OIDC-assumed roles (ADR-004). Provider tokens (GitHub, Cloudflare) are least-privilege
  and stored outside the repo.
- Everything else follows the ADRs (ECS Fargate, RDS Postgres Multi-AZ, ElastiCache
  Valkey, AppConfig, Step Functions, Terragrunt — ADR-001/003/005/006/010).

## Repo layout (Terragrunt) — at the `platform` repo root
```
platform/
  terragrunt.hcl                 # root: remote_state (S3+DynamoDB) + provider gen
  _envcommon/                    # shared stack inputs (DRY) per stack type
  bootstrap/                     # state backend + GitHub OIDC (chicken-and-egg; see #0)
  github/  cloudflare/           # GitHub + Cloudflare providers (estate-wide, ADR-006)
  modules/ (or git:: refs)       # reusable modules per stack
  watch/<region>/                # per-project AWS stacks
    staging/{network,data,secrets,app,escalation,intake,frontend,pipeline,observability}/
    prod/   {network,data,secrets,app,escalation,intake,frontend,pipeline,observability}/
```

## Sequence & dependencies
| # | Phase | Depends on | Key resources |
|---|-------|-----------|---------------|
| 00 | Local AWS access (operator prereq) | — | AWS CLI v2, account + region, bootstrap credential / SSO profile, `aws sts get-caller-identity` |
| 0a | State backend + Terragrunt structure | 00 | S3 state bucket, DynamoDB lock, root `terragrunt.hcl`, `_envcommon` |
| 0b | GitHub OIDC + IAM roles | 0a | OIDC provider, per-env deploy roles (least-priv), CI assume-role |
| 0c | GitHub repo/org as code (`github` provider) | 0b | repo settings, branch protection, **required CodeBuild status check**, labels, repo variables (OIDC role ARN) |
| 1 | `network` | 0 | VPC, public/private subnets ×AZ, NAT, SGs, VPC endpoints (ECR/S3/SSM/logs) |
| 2 | `data` | 1 | RDS Postgres Multi-AZ + Secrets Manager rotation, ElastiCache Valkey, subnet/param groups, KMS |
| 3 | `secrets` + AppConfig | 1 | SSM SecureString params, Secrets Manager entries; AppConfig app/env/profile + flags (ADR-003) |
| 4 | `app` (ECS) | 2,3 | ECR repo, ECS Fargate cluster/service, ALB **2 target groups + test listener**, task def (AppConfig Agent sidecar, `secrets` block), autoscaling |
| 5 | `escalation` | 2,4 | Step Functions Standard (rendered ASL, real ARNs/SLAs), `record_token`/`commit` Lambdas, IAM, **CloudWatch alarm on failed executions** (ADR-001) |
| 6 | `intake` | 1,2 | API Gateway (webhook, shared-secret authz) → SQS → consumer; DLQ; ack-on-enqueue (ADR-002) |
| 7 | `frontend` | 0 | S3 + CloudFront (OAC), fingerprinted assets + short-TTL `index.html` (ADR-005), build→sync→invalidation |
| 8 | `pipeline` (CD) | 4,5,6,7 | CodePipeline → CodeBuild (authoritative test/coverage/Sonar/build/push) → **CodeDeploy ECS blue/green** (alarm-gated canary/linear, auto-rollback, `BeforeAllowTraffic`/`AfterAllowTraffic` hooks), GitHub status-back; GitHub Actions = lint/format only (ADR-004) |
| 9 | `observability` | 4 | ECS OTel → Watchtower (traces+metrics+logs, proven locally), CloudWatch alarms, **masked drains** (Logs data-protection), SmokeShow E2E hook (#7) |
| 10 | Expand→contract migration | 4,8 | One real migration through expand → migrate → backfill → cut-over → **contract (separate release)** + runbook (§4.9) |
| 11 | DNS / TLS (`cloudflare` provider) | 4,7 | Cloudflare zone + DNS records (Terraform-managed) + ACM certs (ALB + CloudFront), domain wiring (ADR-006) |

## Blue/green mechanics (ADR-004 / §4.6)
Two ALB target groups + a **test listener**; CodeDeploy shifts traffic
canary/linear **gated on CloudWatch alarms**; `BeforeAllowTraffic` runs **migrations +
smoke** against the green task set, `AfterAllowTraffic` validates; **automatic rollback**
on alarm. The authoritative gates (the same `make coverage` + `make sonar-scan` we run
locally) run in **CodeBuild**, so they can't be bypassed with `--no-verify` (closes the
local-hook gap, ADR-004).

## Cross-cutting
- **Secrets** are referenced, never inlined: SSM SecureString (static) / Secrets Manager
  (RDS rotation) via the task-def `secrets` block (§4.3). No secrets in images or `environment`.
- **Flags** keep the `flags.is_enabled` seam; AppConfig Agent sidecar gives the identical
  `localhost:2772` path in ECS as locally (ADR-003).
- **Escalation Lambdas** package the existing `escalation/lambdas/{record_token,commit}.py`
  handlers (which call `incidents.services`) — same code proven locally via the shim (ADR-010).

## Open inputs (needed before `apply`)
AWS account id, region, domain name (Cloudflare zone), and whether **Watchtower is
reachable from AWS** (or we run an OTel Collector/Alloy in-VPC that forwards to it). Paging
(ntfy, ADR-013 / `gotoplanb/watch#8`) layers on after the app tier is live.
- **Region:** pick a region supported by **AWS DevOps Agent** (#17) — us-east-1 /
  us-west-2 / eu-central-1 / eu-west-1 / ap-southeast-2 / ap-northeast-1 — to keep that
  option open.

## AWS DevOps Agent (#17) — design-for-it now, integrate later
DevOps Agent (agentic incident investigation + release readiness; realizes §8 "AI-assisted
exception triage") acts on a **running** system, so it's integrated after the pipeline (#10)
+ observability (#11) land — not at bootstrap. But its inputs are exactly what we already
build: clean **CloudWatch alarms** (#7, #11), **OTel** telemetry, **CodePipeline/CodeBuild**
(#10), **GitHub PR checks** (#15). Keep those first-class so it lights up the moment we
deploy (idle-free billing + 2-month trial = ~$0 until invoked).

## Cost profile (ADR-015)
Rough monthly (us-east-1, on-demand), **lean** profile, single persistent prod:

| Component | ~$/mo | Note |
|---|--:|---|
| ALB | 22 | HTTPS + CodeDeploy blue/green |
| RDS Postgres (single-AZ `db.t4g.micro`) | 14 | Multi-AZ ≈ +$13 (ADR-005) |
| Fargate (1× 0.25 vCPU / 0.5 GB) + AppConfig sidecar | 9 | |
| ElastiCache Valkey (`cache.t4g.micro`, optional) | 0–12 | skip for a single task (local-memory sessions) |
| CloudWatch / Secrets / KMS / CodePipeline+Build / S3+CloudFront / ECR | ~12 | small fixed bits |
| Step Functions / Lambda / SQS / API GW (<100 incidents/day) | ~1 | basically free |
| NAT gateway | **0** | lean = public subnets, no NAT (~$36/env saved) |
| AWS DevOps Agent (#17) | **0** | flagged off + 2-mo trial; bills only when invoked |
| **≈ total** | **~$60–85** | |

Ephemeral `staging` adds only the hours it runs. The **`ha`** profile (private + NAT +
Multi-AZ, two persistent envs) is ~$220–280/mo — applied deliberately, never by default.
(AWS bills public IPv4 ~$0.005/hr each — ALB, public-IP Fargate, NAT EIP — so lean *left
running* is nearer ~$70–95/mo; pennies for short test cycles.)

## Dev/test loop: create → verify → destroy
Most resources bill **hourly, not per-create**, so validating a profile is cheap:
lean ≈ $0.10/hr, ha ≈ $0.35/hr → a full **create → verify → destroy** of both ≈ **a few
dollars** over an afternoon.
- **Keep the foundation up** (≈$0, must not churn): state backend (S3+DynamoDB), OIDC,
  GitHub + Cloudflare config. The loop only creates/destroys the **per-env app stacks**
  (network/data/app/escalation/intake/frontend/pipeline).
- **Make `destroy` clean** so nothing lingers billable / blocks teardown: RDS
  `deletion_protection=false` + `skip_final_snapshot=true` (ephemeral), buckets
  `force_destroy=true` (frontend/artifacts), short CloudWatch log retention. **Real prod
  overrides these** (deletion protection + final snapshot on).
- **Budget wall-clock, not dollars:** RDS Multi-AZ and CloudFront are slow to create *and*
  destroy (CloudFront disable+delete ~15–40 min).
- After teardown, a quick orphan sweep (EIPs, snapshots, volumes, log groups) keeps it
  truly a-few-bucks.

## Extending to private subnets + NAT (the `ha` profile)
> The `network` stack defaults to **public subnets**, chosen for cost + simplicity during
> development. Switching to the secure profile is a **variable change, not a rewrite**:
- `private_networking = true` (+ `enable_nat = true`): `network` creates **private subnets
  + NAT gateway(s)** (one per AZ for HA, or a single NAT to save cost) and routes egress
  through them; public subnets keep only the ALB.
- App: `assign_public_ip = false`, Fargate moves to the private subnets; add priced **VPC
  interface endpoints** (ECR api/dkr, SSM, Secrets Manager, Logs) so it pulls images +
  reads secrets without internet egress.
- Data: `multi_az = true` (ADR-005 survival).
- CI runs `tofu plan` on **both** profiles so the `ha` path never bit-rots. Apply it for
  occasional secure testing, then `terragrunt destroy` back to lean.

## Apply order
00 (operator: CLI + bootstrap creds) → 0a → 0b → 1 → (2,3 parallel) → (6 intake parallel
with 4 app) → 4 → 5 → 7 → 8 → 9 → 10/11.
Rollback is per-stack `destroy` in reverse, but prefer forward-fix; blue/green handles app
rollback automatically.
