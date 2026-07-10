# scripts/

Operational helpers for the Watch estate. Deterministic, re-runnable, and safe to read
before running (each has a header comment). Most are wrapped by `make` targets at the repo
root (`make help`); the full-lifecycle target is **`make live`** (create + migrate + seed +
deploy-frontend).

| Script | Profile | What it does |
|---|---|---|
| [`create.sh`](create.sh) | `watch-bootstrap` (write) | (Re)creates the estate via `terragrunt run --all apply` (DAG orders + parallelizes). Self-heals a missing `:bootstrap` image; sources `CLOUDFLARE_API_TOKEN` from `.env` for `prod/dns`. |
| [`db.sh`](db.sh) | `watch-bootstrap` (write) | Runs `migrate`/`seed`/arbitrary command as a one-off Fargate task on the app task def (fresh envs come up on an empty DB). |
| [`deploy-frontend.sh`](deploy-frontend.sh) | `watch-bootstrap` (write) | Stages the status-page SPA (pins `WATCH_API` to the env's API origin), `s3 sync`s to the frontend bucket, invalidates CloudFront. Terraform makes the bucket/distro but not its contents. |
| [`deploy.sh`](deploy.sh) | `watch-bootstrap` (write) | Promotes latest `main` off the `:bootstrap` seed: starts a pipeline run (same path as a push, #24), waits through Build → DeployStaging → DAST, stops at the prod-approval gate. |
| [`teardown.sh`](teardown.sh) | `watch-bootstrap` (write) | Destroys the per-env stacks (and the shared pipeline) dependents-first. Keeps the ~$0 foundation by default — state backend, `ecr`, `prod/dns` cert, `account/*`, `github/*` — but drops the `watch`/`status` CNAMEs so a later create is clean. |
| [`sweep.sh`](sweep.sh) | `watch-ro` (read-only) | Lists *billable* leftovers in the region and exits nonzero if any remain. Excludes the intentionally-kept foundation (tf-state, ECR, cert). |
| [`doctor.sh`](doctor.sh) | `watch-bootstrap` (read-only calls) | Cross-account state-vs-reality drift: assumes into **both** member accounts and reports **orphans** (billable watch-* live in AWS that teardown missed) and, with `--state`, **ghosts** (tracked in terraform state but absent in AWS). Exits nonzero on orphans. `make doctor`. |
| [`nuke.sh`](nuke.sh) | `watch-bootstrap` (write) | **Last resort.** Force-deletes ALL billable `watch-*` in a member account, dependency-ordered with waits, keeping the persist-list (tf-state, ECR+`:bootstrap`, ACM certs, `watch-ci-*`/`watch-prod-deploy` IAM, org/account/github). Typed-target confirmation. Use only when `teardown.sh` leaves orphans `doctor.sh` flags. `make nuke TARGET=nonprod`. |
| [`lib/preflight.sh`](lib/preflight.sh) | — | Sourced by create/teardown/doctor/nuke: fail-fast BEFORE any mutation on a bad AWS identity, missing/malformed member account IDs, or (for DNS ops) a missing `CLOUDFLARE_API_TOKEN`. |
| [`aws-portal.py`](aws-portal.py) | — (browser) | Zero-dep local "access portal" — serves one page of **switch-role** links per member account (a stand-in for the IAM Identity Center start page). IDs read from `.env` (nothing committed). `make portal` → http://127.0.0.1:8765. Config: `aws-portal.example.json` (copy to gitignored `aws-portal.json` to customize). |

## Bring everything up from nothing (foundation already exists)
```sh
make live          # ONE approval: platform + BOTH app envs, then promote latest main
make sweep         # (after a later teardown) confirm nothing billable lingers
```
`make live` = `create` (both envs) → `migrate`+`seed` **staging and prod** → `deploy-frontend`
**staging and prod** → `deploy` (promote latest `main` through the pipeline to the prod-approval
gate). One human approval stands up the platform + both app envs; the pipeline's prod approval
is the separate gate for promoting real code to prod.
`create` brings up both envs on the kept `:bootstrap` image; `migrate`/`seed` populate the
fresh prod DB; `deploy-frontend` publishes the status page; **`deploy`** then promotes latest
`main` through the pipeline (Build → DeployStaging → DAST) and pauses at the prod-approval gate
— so a full `make live` leaves the app on real code, not the seed image, with prod one
approval away.

## Nightly / between-release teardown (ADR-019: staging is ephemeral)
```sh
scripts/teardown.sh both --parallel -y   # pipeline first, then staging & prod concurrently
scripts/sweep.sh                          # confirm clean; nonzero exit = something lingers
```
`--parallel` tears the two envs down at the same time (roughly halves wall-clock — both are
dominated by the same independent slow waits: ENI detachment, CloudFront disable+delete, RDS
deletion). It's safe: staging and prod are disjoint with separate TF state, and the only
shared stack — `pipeline` — is destroyed first, before the fan-out. Each env streams to its
own log (path printed at start) so output stays readable; within an env stacks stay
sequential (dependents-first). Drop `--parallel` for a single interleaved log.
Recreate next session from IaC (`terragrunt run --all apply` per env) — the kept ECR image
and ACM cert make it fast (no rebuild, no cert revalidation).

Tear down only the ephemeral env, leaving prod live:
```sh
scripts/teardown.sh staging -y
```

Also drop DNS (releases the cert + Cloudflare `watch.`/`status.` records):
```sh
scripts/teardown.sh both --with-dns -y
```

## Notes
- Gotchas that shaped these (e.g. `terragrunt destroy` needs `-auto-approve` *and*
  `--non-interactive`) are in [`../GOTCHAS.md`](../GOTCHAS.md).
- `teardown.sh` is continue-on-error: a single wedged stack won't abort the rest; the
  summary lists `OK`/`FAIL`/`SKIP` and the script exits nonzero if anything failed. Re-run
  is a no-op for already-destroyed stacks.
