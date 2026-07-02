# Foundations: network, DNS/TLS, security, observability, cost

## Networking

Per-env VPC with public + private subnets across AZs (ADR-005). The **cost profile** is a toggle
(ADR-015):

- **`ha`** (prod, and staging per ADR-019) — app tasks in **private** subnets, no public IP, egress
  via **NAT**; priced **VPC interface endpoints** (ECR api/dkr, SSM, Secrets Manager, Logs) so the
  tasks pull images + read secrets without internet egress. Multi-AZ RDS in prod.
- **`lean`** — public subnets + public-IP Fargate, no NAT; for cheap dev cycles. Both paths stay
  validated.

The only ingress is the ALB (its security group is the trust boundary); the app SG allows the ALB,
the data SG allows the app.

## DNS/TLS

TLS is **ACM on AWS**; DNS is **Cloudflare, DNS-only** (grey-cloud) — records point straight at the
ALB / CloudFront. Only the named subdomains + ACM-validation records are managed — **never the
apex** (ADR-006/013).

The cert is **split from the records** (its own stack) — this is load-bearing:

```
cert stack (acm-cert)                 dns stack (dns-records)
  aws_acm_certificate  ───┐             cloudflare_record.app    → ALB
  + Cloudflare validation │             cloudflare_record.status → CloudFront
  + aws_acm_certificate_validation
        │ output: certificate_arn
        ▼   (consumed as an INPUT by app :443 + frontend CloudFront)
```

Why: a combined dns+cert stack must depend on the app (for the CNAME targets), but the app needs
the cert — a bootstrap cycle. Splitting lets the **cert apply first** (it needs only the zone +
domain names), so `make live` works from scratch with no manual bootstrap. Both envs use this;
prod's live cert was migrated in place (`import` → `state rm` → config switch) with no recreation.
The cert stacks are **kept across teardowns** (revalidation is slow); teardown drops only the
`app`/`status` CNAMEs.

## Security & trust

- **Ingress** — ALB-only (SG). `DJANGO_ALLOWED_HOSTS` + `CSRF_TRUSTED_ORIGINS` scope to the real
  hostname behind HTTPS.
- **Secrets** — referenced, never inlined: SSM SecureString (static) + Secrets Manager (RDS
  rotation) via the task-def `secrets` block (§4.3). Nothing secret in images or `environment`.
- **AuthN/Z** — Django **session auth** (cookies in Valkey), tiers as Django **Groups**;
  ack/escalate/resolve require the incident's `current_tier` role **or higher** (ADR-008). Intake is
  machine-to-machine (shared secret), separate from human sessions.
- **No long-lived keys** — GitHub → AWS via **OIDC** role assumption. Operating posture:
  **`watch-ro`** (ReadOnlyAccess) for all verification, **`watch-bootstrap`** (temp admin) only for
  applies; the CI trigger role can only `StartPipelineExecution`.
- **HTTP hardening** — HTTPS-only (`:80`→`:443`), **HSTS** (app + status pages), and on the app:
  **CSP** (permits the `/ui` CDN deps, locks the rest), **X-Frame-Options: DENY**, nosniff,
  referrer-policy, Permissions-Policy.
- **Gated release** — SAST + DAST + functional smoke before prod (see [delivery](delivery.md));
  the DAST target *is* the prod-identical staging (ADR-019), so scans are legitimate and safe.

## Observability (ADR-016)

**The app names no telemetry backend.** It exports OTLP to a **local Alloy sidecar**; where
telemetry goes is a collector-config artifact per environment, not an app env var — so swapping a
backend is a collector change, no redeploy.

```
app ──OTLP──► alloy sidecar (per task) ──► gateway ──► backend
   OTEL_RESOURCE_ATTRIBUTES = deployment.environment=<env>,service.version=<git sha>
   (the pipeline injects the SHA; the app carries no vendor name, ever)
```

Both envs run the same shape (sidecar + gateway + tail-sampling/redaction at the gateway boundary).
The **only** per-env difference is the gateway's last hop: **staging → the in-AWS Watchtower LGTM
platform slice**; **prod → a managed vendor** (Watchtower stays out of product prod). The sidecar
keeps egress off the app's critical path (`essential=false`) — a backend outage never blocks the
app. (The gateway + Watchtower slice are the open follow-ups #19/#29/#23.)

## Cost

- **Profiles** (ADR-015) — `lean` ≈ $60–95/mo; `ha` (prod + persistent staging) ≈ $220–280/mo.
- **Ephemeral staging** (ADR-019) — stood up per release and torn down, so pre-prod bills only the
  hours it runs. `make teardown`/`make live` make this a two-command loop; the kept foundation is
  ~$0 at rest (ECR + state pennies, certs/connection/roles/budgets free).
- **Guardrails** — daily **AWS Budgets** per plane: `watch-prod-daily`, `watch-staging-daily`,
  `watch-platform-daily`, plus an account cap; scoped by the activated `env` cost-allocation tag.
  (Daily "did we overspend today" needs a Budget, not a CloudWatch billing alarm — that metric is
  month-to-date cumulative.)
- **Verify clean** — `make sweep` is a read-only billable-orphan check that exits nonzero if
  anything survives a teardown.
