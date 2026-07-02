# Runtime: what serves traffic, and how an incident flows

## The app task

The ECS Fargate task runs three containers (ADR-003/016):

```
┌─ ECS task (awsvpc, private subnets in ha) ───────────────────────────┐
│  app (essential)            Django/DRF + HTMX UI, :8000                │
│    ├─ localhost:2772  ──►  appconfig-agent (essential)  feature flags  │
│    └─ localhost:4318  ──►  alloy (essential=false)      OTLP sidecar   │
│  secrets via the task-def `secrets` block (SSM SecureString +          │
│  Secrets Manager RDS credential) — never inlined in `environment`      │
└───────────────────────────────────────────────────────────────────────┘
```

- **app** — the system of record's API (`/api`, a read-only DRF viewset + action endpoints), the
  server-rendered working UI (`/ui`, HTMX/Alpine/Tailwind), the public landing (`/`), the intake
  webhook, and `/api/health` + `/api/status`.
- **appconfig-agent** — serves the AppConfig flag profile at `localhost:2772`, the *same* path the
  app uses locally, so `flags.is_enabled(...)` is identical in every environment (ADR-003).
- **alloy** — receives the app's OTLP on localhost and forwards it; `essential=false` so telemetry
  trouble never takes the app down (see [foundations](foundations.md) → observability).

## The request path

```
user ──HTTPS──► Cloudflare (DNS-only CNAME) ──► ALB :443 (ACM cert)
                                                   │  :80 → 301 → :443
                                                   ▼
                                         blue/green target group ──► app :8000
```

The ALB terminates TLS and talks HTTP to the task, so the app trusts `X-Forwarded-Proto` for
`request.is_secure()`, CSRF, and secure cookies. Ingress is ALB-only (security group) — that's the
trust boundary. CodeDeploy owns the two target groups + a test listener and shifts traffic between
them (see [delivery](delivery.md)).

## Data & sessions

- **RDS Postgres** — the system of record. Multi-AZ in prod; single-AZ + `skip_final_snapshot` in
  the disposable staging.
- **Valkey (ElastiCache)** — Django sessions live here (ADR-008), so login state survives task
  replacement during a blue/green deploy.
- **AppConfig** — flag evaluation, always behind `flags.is_enabled(name, default)`; both branches
  of every flag are tested (ADR-003).

## Intake — how an incident is created

```
source ──POST /webhook (shared secret)──► API Gateway (HTTP) ──► SQS ──► consumer λ
                                                                            │
   (ack-on-enqueue, ADR-002)                                               ▼
                                                       create_incident_idempotent()
                                                          │  dedupe: source event id, else
                                                          │  sha256(normalize(payload));
                                                          │  UNIQUE(dedupe_key) WHERE status=OPEN
                                                          │  + ON CONFLICT DO NOTHING (ADR-009)
                                                          ▼
                                              new incident (T1, routed to on-call)
                                                          │
                                                          ▼
                                              start one Step Functions execution (ADR-001)
```

The consumer's create logic is the *same* code the Django intake webhook exposes directly — so a
retry while OPEN is a no-op, and a re-fire after RESOLVED opens a fresh incident.

## Escalation — the engine (ADR-001 / 007 / 010)

**One Step Functions Standard execution per incident. ASL orchestrates; Python decides.** State is
**orthogonal**: `status` (OPEN/RESOLVED) × `current_tier` (T1/T2/T3) + `acknowledged_at`.

```
 start ─► [T1] waitForTaskToken ──timeout(SLA_T1)──► auto-escalate (system:auto-escalation)
             │  ▲                                         │
   SendTaskSuccess(outcome)                               ▼
             │  └─ ack: does NOT consume the token,   [T2] waitForTaskToken ──timeout──► [T3] …
             │     does NOT stop the SLA clock             │
             ├─ escalate ─────────────────────────────────┘  (one token consumed per tier)
             └─ resolve ─► Succeed  (no zombie timer)
```

- **One tier = one `waitForTaskToken`**; the token is consumed **exactly once per tier**. There's a
  single outstanding token, held in `current_task_token`; the API never trusts a client-supplied
  token — it looks up the current one and rejects on tier mismatch (409).
- **The decision is one implementation** (`incidents/services.py`) called by both the API and the
  Lambdas — every transition is idempotent ("act if still applicable", never blind-act).
- **In the real (AWS) engine the commit Lambda is the sole writer** of Transitions; the actor flows
  via `$.decision.actor` (timeouts use `system:auto-escalation`). The API only does
  `SendTaskSuccess`. Locally, `ESCALATION_LOCAL_MODE=1` short-circuits to direct `services` calls.
- ASL gotcha: the `waitForTaskToken` tasks set `ResultPath` (`$.decision`) so the task output
  doesn't wipe `incidentId` for later tiers.

This is why the smoke test's "escalate right after create" must retry: the token is registered a
beat after the execution starts (see [delivery](delivery.md) → gates).

## The status page

A build-less React SPA (S3 + CloudFront, OAC) that fetches `GET /api/status` from the app
cross-origin (CORS-open aggregate posture: open counts by tier + dependency checks). It's a
separate origin from the app — the delivery of its *contents* is a codified step
(`deploy-frontend.sh`), since Terraform builds the bucket/distribution but not the files.
