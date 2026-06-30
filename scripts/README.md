# scripts/

Operational helpers for the Watch estate. Deterministic, re-runnable, and safe to read
before running (each has a header comment).

| Script | Profile | What it does |
|---|---|---|
| [`teardown.sh`](teardown.sh) | `watch-bootstrap` (write) | Destroys the per-env stacks (and the shared pipeline) dependents-first. Keeps the ~$0 foundation by default — state backend, `ecr`, `prod/dns` (ACM cert + Cloudflare records), `account/*`, `github/*`. |
| [`sweep.sh`](sweep.sh) | `watch-ro` (read-only) | Lists *billable* leftovers in the region and exits nonzero if any remain. Excludes the intentionally-kept foundation (tf-state, ECR, cert). |

## Nightly / between-release teardown (ADR-019: staging is ephemeral)
```sh
scripts/teardown.sh both -y      # destroy prod + staging + pipeline, keep foundation
scripts/sweep.sh                 # confirm clean; nonzero exit = something lingers
```
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
