# Rollout gotchas — Watch on AWS (v0.1.0)

Operational landmines hit while bringing Watch live (epic #16). The forward plan is
[`ROLLOUT.md`](ROLLOUT.md); the *why* behind decisions is the ADRs in `gotoplanb/watch`.
This file is the "things that cost us an hour" list — read it before the next env.

## Terragrunt / OpenTofu
- **`run-all` is gone.** The redesigned CLI is `terragrunt run --all apply` /
  `run --all destroy`; the non-interactive flag is `--non-interactive` (not the old
  `--terragrunt-non-interactive`). We drive OpenTofu via `TG_TF_PATH=tofu terragrunt …`.
- **One `required_providers` block per module.** Adding a 2nd provider (Cloudflare,
  GitHub) to a stack that inherits the root AWS provider needs the deep-merge include
  override (`include "root" { merge_strategy = "deep" }`) plus a `generate "versions"`
  block that re-declares aws **and** the extra provider — you can't just add a second
  `required_providers`.
- **Cloudflare provider v4 naming.** `cloudflare_record` takes `content` (not `value`);
  `data.cloudflare_zone` is looked up by `name`. v4.52.8 specifically.

## DNS / TLS (Cloudflare, davestanton.com)
- **Never touch the apex.** Only ever create the *named subdomain* records
  (`watch.`, `status.`, and the ACM validation CNAMEs) as individual
  `cloudflare_record` resources. No apex/MX/zone-authoritative records — the token is
  scoped "Edit zone DNS" and the IaC stays surgical so a bad plan can't nuke the root.
- ACM cert lives in **us-east-1** (CloudFront requirement), DNS-validated; validation
  records use `proxied = false` and `trimsuffix(record_name, ".")`.

## App behind the ALB (Django)
- **CSRF 403 on login behind a TLS-terminating ALB.** The ALB terminates TLS and talks
  HTTP to the task, so Django thinks the request is insecure and rejects the cross-origin
  POST. Fix: `SECURE_PROXY_SSL_HEADER=("HTTP_X_FORWARDED_PROTO","https")` +
  `CSRF_TRUSTED_ORIGINS=https://<host>` + secure session/CSRF cookies. These are wired
  via the app stack only when `app_hostname != ""`.
- **`:80 → :443` redirect broke the CloudFront `/api` proxy.** Once the app listener
  301-redirected to HTTPS, CloudFront's `/api` origin (which hit `:80`) got the redirect
  instead of a response → status page showed "Backend unreachable." We **retired the
  proxy**: the status SPA fetches `https://watch.davestanton.com` directly via CORS.
- **ALB `:80` listener replacement → `DuplicateListener`.** create-before-destroy tries
  to stand up the new `:80` listener while the old one still holds the port. Splitting
  into a redirect listener resolved it once the failed apply had freed `:80`.
- **`waitForTaskToken` must set `ResultPath` (`$.decision`)** or the task output replaces
  the whole state and wipes `incidentId` for later tiers (ADR-007).

## DNS/cert stacks (ACM + Cloudflare)
- **The cert must be its own stack, applied before the app.** The app looks up / consumes the
  ACM cert, but a combined dns+cert stack depends on the app (for the CNAME targets) → a
  bootstrap cycle. It "works" only if the cert already exists (kept). Split into `acm-cert`
  (no app dep, applies first) + `dns-records` (the CNAMEs); the app takes the cert ARN as an
  input. Both staging and prod use this (#34/#35).
- **Migrating a live cert between stacks (#35):** `import` it into the new cert stack, then
  `state rm` from the old — and **change the old stack's config to drop the cert in the same
  step**, before any apply (a stack with the cert in config-but-not-state will try to *create*
  a duplicate; in state-but-not-config it will *destroy* the live one). The cert imports as an
  in-place tags update (not recreated); the Cloudflare validation records force-replace because
  import returns the short `name` form vs the module's FQDN — harmless (identical DNS, ~1s gap,
  issued cert unaffected). `aws_acm_certificate_validation` can't be imported — it just
  re-creates (confirms the already-issued cert). Verify the ALB `:443` cert ARN is unchanged.
- **Retrofitting a hostname onto a live blue/green service** flips the production listener from
  `:80` to `:443`; CodeDeploy then rejects the next deploy ("TaskSet is behind prod listener")
  because the live task set sits on the *other* target group. A from-scratch create (hostname
  set from the start) avoids it; to recover an existing env, recreate the ECS service
  (`-replace`) so blue/green resets to a consistent state.

## Recreate after teardown (keeping the cert)
- **`CNAMEAlreadyExists` when re-creating the CloudFront status distro.** If teardown keeps
  `prod/dns` (to avoid slow ACM revalidation) but destroys `frontend`, the Cloudflare
  `status.davestanton.com` CNAME is left pointing at the now-deleted distribution. CloudFront
  then refuses to let the *new* distro claim that alias ("incorrectly configured DNS record
  that points to another CloudFront distribution"). Fix: teardown now target-destroys just
  the `watch`/`status` CNAMEs (`cloudflare_record.app`/`.status`) while keeping the ACM cert
  + validation records; `create.sh`'s dns apply recreates them against the new ALB/CloudFront.
  The dns dependency blocks allow `destroy` in `mock_outputs_allowed_terraform_commands` so
  the target-destroy runs even when `app`/`frontend` state is already gone.

## Teardown
- **VPC-Lambda ENIs stall `network` destroy 20-40 min.** `make teardown` gets to `<env>/network`
  fast, then `aws_subnet.private`/`aws_security_group.app` sit in `Still destroying…` for tens of
  minutes. Cause: the escalation (`record-token`, `commit`) + intake (`authorizer`, `consumer`)
  Lambdas are **VPC-attached**, and AWS keeps their Hyperplane ENI (`AWS Lambda VPC ENI-<fn>`,
  `status=in-use`) for 20-40 min *after* the function is deleted — the subnet/SG can't be removed
  until it's released. **Nothing is wrong; terragrunt retries until it clears — wait it out.**
  Confirm the blocker: `aws ec2 describe-network-interfaces --filters Name=subnet-id,Values=<subnet>`.
  Recreate is unaffected (fresh VPC). Expect this every teardown while those Lambdas are VPC-bound.
- **Killed `make teardown` keeps destroying.** The parallel per-env teardown runs `destroy_env &`
  subprocesses; killing the foreground `make` doesn't kill them, so a teardown can *finish on its
  own* after you think you stopped it. Re-running is safe (idempotent), but check state first.

## Lambda packaging
- **`/aws/lambda/<fn>` log groups orphan on teardown (fixed, #38).** Lambda auto-creates its
  log group on first invocation, *outside* Terraform — so `destroy` never removed them and every
  teardown left `/aws/lambda/watch-*-deploy-hook` + intake authorizer/consumer groups for the
  sweep. Fixed by declaring an `aws_cloudwatch_log_group` per Lambda (escalation already did;
  added intake authorizer/consumer + the pipeline deploy-hook `for_each`), so Lambda reuses the
  managed group and teardown deletes it. Takes effect on the **next clean create** — groups
  auto-created by a *pre-fix* create aren't in state, so they'd collide on re-apply; sweep them
  once (or `terragrunt import` them) so the first post-fix create is clean.
- **250 MB unzipped limit.** `cp -r backend/.` dragged in the fat `.venv` that
  `make coverage` builds → over the limit. Copy only `backend/config` + `backend/incidents`,
  and use a slim `escalation/lambdas/requirements.txt` (no OTel/gRPC).
- **Handler string must match the packaged filename.** `handler.handler` failed because
  the file was `intake_consumer.py` → set the handler to `intake_consumer.handler`.

## Auto-trigger the pipeline on push
- **The CodeConnections (GitHub App) V2 push trigger never delivered events**, even with the
  config verbatim-correct (V2 pipeline, `push`/branch filter, `source_action_name` matching),
  the connection `AVAILABLE`, and the pipeline created *fresh* against the available connection
  (Source pulls the repo fine; manual + create-triggered runs work). The gap is GitHub-App-side
  event delivery, not visible/fixable from the AWS CLI. **Don't sink time into the native
  trigger** — drive it from the app repo's **GitHub Actions via OIDC** instead
  (`modules/ci-pipeline-trigger` + `.github/workflows/trigger-pipeline.yml` calling
  `StartPipelineExecution`). Trigger-only (CodePipeline still builds/deploys, ADR-004) and
  more flexible — switch `main` pushes to release tags with a one-line `on:` change, no IAM.
- **`list-pipeline-executions --max-items N` appends a `None` pagination token** to
  `--output text`, corrupting an ID captured with `$(...)`. Use `--query '...[0].field'`
  without `--max-items`.

## Pipeline / build-once-promote-by-digest (ADR-017)
- **`ESCALATION_LOCAL_MODE` defaults to local.** Unset, `start_escalation` uses the
  in-process stub instead of real Step Functions. Set `"0"` explicitly in **both** the app
  and intake consumer task envs.
- **Docker Hub 429s in CodeBuild.** Use an ECR Public base
  (`public.ecr.aws/docker/library/python:…-slim-bookworm`), not `python:…` from Docker Hub.
- **buildspec shell functions don't survive.** Each buildspec command runs in its own
  shell, so a `render()` function defined earlier is "command not found" later. Inline the
  per-env render loop.
- **Immutable ECR + a re-run = tag conflict.** Push idempotently: `aws ecr describe-images`
  for the tag, reuse if present, else build+push. Promotion then references the digest
  (`image@sha256:…`), identical staging→prod.
- **Pipeline role needs `codedeploy:GetApplication` + `GetDeploymentGroup`.** First live
  run failed without them; a retry can race IAM propagation — wait, then re-run.

## Cost guardrails
- **A *daily* spend alarm is AWS Budgets, not a CloudWatch billing alarm.** CloudWatch's
  `EstimatedCharges` is month-to-date cumulative, so it can't answer "did we overspend
  *today*." Use an `aws_budgets_budget` with `time_unit = "DAILY"` (see `modules/budget`).

## Operating posture & verification
- **Two creds, separated by duty.** `watch-ro` (ReadOnlyAccess) for all CLI
  verification; `watch-bootstrap` (temp admin) only for applies. No long-lived write keys.
- **Verify UIs by *viewing* them, not curl.** A `200` is not proof — a broken status page
  still returns 200. Drive the real browser via the Playwright MCP. The container has no
  host mount, so screenshots land at `/home/node/<f>.png` inside it — retrieve with
  `docker cp <cid>:/home/node/<f>.png`. Submit forms with `form.requestSubmit()` (not
  `form.submit()` — a field named `submit` shadows the method).

## Verified end-to-end at v0.1.0
Intake webhook → SQS → consumer → incident; escalation auto-timeout commit + human
resolve via `/ui`; promote-by-digest (identical sha256 staging+prod); HTTPS-only on
`watch.davestanton.com` (app) + `status.davestanton.com` (status SPA), CSRF login working,
root landing page, daily cost budget. Remaining: #17 DevOps Agent, #32 DAST, and the
observability/account-seam follow-ups (#18/#19/#21/#22/#23/#25/#28/#29/#30/#31).
