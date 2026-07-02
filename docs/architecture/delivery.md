# Delivery: how code reaches prod

## Build once, promote by digest (ADR-017)

One CodeBuild builds the image **once**, pushes it to the immutable ECR repo, captures the
`sha256` digest, and renders per-env task-def/appspec artifacts pinned to that digest. Staging and
prod deploy the **same digest** — no CodeBuild in the prod path, so what you tested is byte-for-byte
what ships. The build is idempotent (reuses the image if the tag already exists).

## The pipeline

```
Source ─► Build ─► DeployStaging ─► DAST ─► Smoke ─► ApproveProd ─► DeployProd
  │         │           │            │       │           │              │
 GitHub   Sonar       blue/green    OWASP   Playwright  manual        blue/green
 (conn)   (SAST) +    + migrate     ZAP     e2e vs      approval      + migrate
          build+push  hook          vs      watch-stg   (human)       hook
          + render    (staging)     stg                               (prod)
          taskdefs
```

Every stage after `DeployStaging` is a **gate**: DAST or Smoke failing blocks the run before the
prod approval is ever offered. The three gates are complementary — **SAST** (Sonar, at build,
against the source), **DAST** (ZAP, against a running staging), **functional smoke** (Playwright,
against a running staging).

### The gates

- **Build / SAST** — the authoritative `make coverage` (≥90%) + SonarQube quality gate run *in
  CodeBuild*, so they can't be bypassed with `--no-verify` (closes the local-hook gap, ADR-004).
- **DAST** — a ZAP baseline against the public `watch-stg` endpoint (no VPC), report → artifact
  bucket. Runs with `-I` (non-breaking to start; promote alerts to FAIL via a `.zap` rules config
  to gate).
- **Smoke** — the app repo's `e2e/` Playwright suite against `watch-stg`: health → status
  (Postgres/Valkey checks + SPA render) → login `t1a` → intake create → **escalate → poll to T2**.
  Exercises RDS (r/w), Valkey (session), Step Functions + commit Lambda, and the status SPA
  post-deploy. Intake secret injected from SSM; the Playwright version is pinned to the CodeBuild
  image's browser build.

### CodeDeploy blue/green

Two ALB target groups + a test listener. CodeDeploy shifts production traffic between them;
`BeforeAllowTraffic` runs the **expand-phase migration** (a one-off Fargate task on the green task
def) + smoke, gated on CloudWatch alarms with automatic rollback. The migrate hook is the same
`manage.py migrate --noinput` mechanism `make migrate` uses standalone.

## The trigger — GitHub Actions via OIDC (#24)

A push to `main` doesn't rely on the native CodeConnections webhook (which never delivered events
in this setup). Instead, a GitHub Actions workflow assumes a least-privilege OIDC role
(`watch-ci-trigger`) and calls `StartPipelineExecution` — trigger-only; CodePipeline still does the
build/deploy (ADR-004). It's one line to point at release tags instead of every `main` push.

The connection itself lives in its own **persistent** stack (#33), so teardown/recreate keeps it
`AVAILABLE` — authorize once, never re-auth.

## Lifecycle tooling

Every lifecycle operation is a checked-in script wrapped by a `make` target:

```
make live      # ONE approval: create both envs → migrate+seed (both) → status pages → promote latest main
make teardown  # ONE approval: parallel destroy of both envs + pipeline; drops CNAMEs, keeps foundation
make deploy    # promote latest main through the pipeline to the prod-approval gate
make create[-staging|-prod] / migrate / seed / deploy-frontend / pipeline / sweep
```

- **`create.sh`** — `terragrunt run --all apply`; DAG-ordered + parallel; self-heals a missing
  `:bootstrap` image; auto-stops the V2 pipeline's create-triggered run.
- **`teardown.sh`** — dependents-first, `--parallel` across envs, drops the `watch`/`status`
  CNAMEs (keeping the certs), keeps the foundation.
- **`db.sh`** (one-off migrate/seed Fargate tasks), **`deploy-frontend.sh`** (SPA → S3 +
  invalidation), **`deploy.sh`** (promote + wait to the approval gate), **`sweep.sh`** (read-only
  billable-orphan gate).

Determinism guarantees (learned the hard way, see [`../../GOTCHAS.md`](../../GOTCHAS.md)): teardown
drops the app/status CNAMEs so a recreate never hits `CNAMEAlreadyExists`; the cert stacks are kept
so there's no revalidation; the cert-first stack ordering means no manual bootstrap.

## The audit gate

`.claude/settings.json` encodes the operating model: the machine may do everything it needs
un-prompted, and **only the create and destroy levers** (plus the raw paths they wrap) prompt a
human. `deny` > `ask` > `allow`, so the broad allow can't slip an apply/destroy past the gate. Net:
**two deliberate human touchpoints** — one `make live` approval to stand the estate up, one
pipeline **ApproveProd** to ship real code to prod.

## Local mirror

The same gates run locally, as close to CI as practical: `make e2e` runs the Playwright suite
against the `make dev` loop, and the pre-commit hook runs **coverage (≥90%) + Sonar + the e2e
smoke** — the e2e gate conditional on the local app being up (like the Sonar gate keys off its
server), skippable with `SKIP_E2E=1`.
