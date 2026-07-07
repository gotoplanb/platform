# Multi-account layout & cutover (ADR-020)

The estate is moving from one AWS account to an **Organization**: the current account stays as a
**clean management account** (org governance + billing, no workloads), and all workloads run in two
member accounts along the plane boundary.

| Plane | Account | ID | Holds |
|---|---|---|---|
| management (clean) | Dave Stanton | *(current account; via `get_aws_account_id()`)* | the Org, consolidated billing, `account/organization`, centralized TF state (for now) |
| build / CI / dogfood | watch-platform | `$WATCH_NONPROD_ACCOUNT_ID` (.env) | staging + platform foundation (ECR, pipeline, connection, ci-trigger, Watchtower/Sonar), budgets |
| product prod | Watch Prod | `$WATCH_PROD_ACCOUNT_ID` (.env) | prod app/data/escalation/intake/frontend/gateway/dns/cert/observability |

(Account IDs live in `~/platform/.env`, not the repo — it's public. See `.env.example`.)

## How the seam works (`terragrunt.hcl` + `accounts.hcl`)

The root config maps each stack (by path) to a **target account** and generates a provider that
**assume-roles** into it (the role name is `local.member_role_name`, default
`OrganizationAccountAccessRole`; the CI plan job overrides it to the read-only `watch-ci-plan`):

- `watch/us-east-1/prod/*` → prod · `watch/us-east-1/staging/*` → nonprod · `member-ci/{nonprod,prod}`
  → the matching member · foundation (`ecr`/`pipeline`/`connection`/`ci-trigger`) → nonprod ·
  **all `account/*`** (org, the CI OIDC base, consolidated-billing budgets) → **management**.
- Base credentials (`AWS_PROFILE`) must be an identity in **management**; it assumes into the member.
- **Gated:** blank member IDs in `accounts.hcl` fall back to the current account, so the seam is a
  **no-op until you fill the IDs** — the single-account estate keeps working unchanged.
- **State stays centralized** in the management bucket for now (ADR-020 §3); per-member state is a
  later hardening.

Verified 2026-07-03: `OrganizationAccountAccessRole` is assumable from `watch-bootstrap` into both
members; with blank IDs, `plan` on the live estate shows **no changes**.

## STATUS (2026-07-03) — estate live cross-account, promote PROVEN

The re-lay is done and the crux is validated. State of play:
- **Estate up cross-account:** staging (foundation + staging + obs slice) in **watch-nonprod**,
  prod app plane in **watch-prod**, pipeline + `prod/deploy` (cross-account CodeDeploy + the
  `watch-prod-deploy` role) built. Provider seam (root `terragrunt.hcl` + `accounts.hcl`) routes
  each path to its account.
- **Cross-account promote PROVEN:** a CodeDeploy blue/green in watch-prod, driven by the nonprod
  pipeline identity assuming `watch-prod-deploy`, shifted traffic to a green task set pulling the
  **nonprod ECR image cross-account**. See ADR-020 "Crossing the seam".
- **Verified:** staging + prod `/api/status` 200 (migrated + seeded); obs plane (watch-backend
  traces in Tempo); **both APIs live by name — `watch.davestanton.com` (prod) and
  `watch-stg.davestanton.com` (staging) return 200**, independent of the CloudFront hold.
- **DNS split for parity (ADR-020):** each env's `dns` (app CNAME → ALB) is its own stack with no
  frontend dependency, so the app hostname comes up even while CloudFront is held; the status CNAME
  lives in `{env}/dns-status` (→ CloudFront) and stays gated. staging now mirrors prod.
- **Blocked on AWS (new-account holds — see below):** pipeline **Build** (CodeBuild), and **both
  envs' status SPA + `{staging,prod}/dns-status`** (CloudFront account-verification, both member
  accounts). Case opened.

**Console access (member accounts).** Root **cannot switch roles** — make an IAM admin user in
management (or IAM Identity Center), then switch-role into each member (IDs live in `.env`, never
committed — substitute `$WATCH_NONPROD_ACCOUNT_ID` / `$WATCH_PROD_ACCOUNT_ID`):
- nonprod: `https://signin.aws.amazon.com/switchrole?account=$WATCH_NONPROD_ACCOUNT_ID&roleName=OrganizationAccountAccessRole&displayName=watch-nonprod`
- prod:    `https://signin.aws.amazon.com/switchrole?account=$WATCH_PROD_ACCOUNT_ID&roleName=OrganizationAccountAccessRole&displayName=watch-prod`

**New-account activation holds.** Day-old member accounts block **CloudFront** and pin **CodeBuild**
concurrency to **0** until AWS verifies them (Account & billing case, free). The estate stands up
regardless; only CodeBuild + CloudFront wait. Draft: `support-case-newaccount-activation.md`.
**The holds are non-deterministic per account** — nonprod drew CodeBuild-only, prod drew
CloudFront-only; it's an independent AWS risk decision, not a config/env difference (both frontends
use the same module). Don't assume sibling accounts get the same holds, and don't chase a fix on
our side — the support case is the only lever.

**Owner note:** state is disposable and prod need not stay up (daily build/teardown) — a clean
re-lay, not a migration.

## Cutover (the clean re-lay)

1. **Teardown** the current estate (in flight). Optionally destroy the management state bucket +
   `bootstrap` too — nothing needs to survive.
2. **Per-member state buckets** — run `bootstrap` (with an `assume_role` into each member;
   see below) to create `watch-tfstate-<member>` + `watch-tflocks` in **watch-platform** and
   **watch-prod**. Then switch the root `remote_state` off centralized-in-management to per-member
   (ADR-020 §3 ideal — the centralized fallback was only for a live migration we no longer need).
3. **Build the cross-account pipeline refactor** — the 5 steps in the build spec above.
4. **Fill `.env`** — `WATCH_NONPROD_ACCOUNT_ID` + `WATCH_PROD_ACCOUNT_ID`; `source` it (activates
   the seam).
5. **`make live`** — foundation + staging → watch-platform, prod → watch-prod (provider
   assume-role per stack). Verify endpoints + obs plane; run a promote to exercise the
   cross-account deploy and iterate on the IAM/KMS (2-3 rounds is normal).

Roll back at any point by re-blanking `.env` (everything routes to the current account again).

## Cross-account pipeline deploy — build spec (Option A, ADR-017) — ✅ IMPLEMENTED

All 5 steps below are built (2026-07-03) and the promote is proven; kept as the design record.
The pipeline (nonprod) builds once and deploys prod **in `watch-prod`** via CodePipeline's
action-level cross-account `role_arn`. The `watch-prod-deploy` **service** role collided with the
CodeDeploy service role (both derived `watch-prod-deploy`); the CodeDeploy service role is now
`…-codedeploy` (ADR-020). Steps:

1. **Artifact KMS key** (`modules/pipeline/main.tf`) — replace the artifact bucket's AES256 with a
   customer-managed `aws_kms_key`; set the CodePipeline `artifact_store.encryption_key`; key policy
   grants the cross-account deploy role `kms:Decrypt`/`GenerateDataKey`/`DescribeKey`. (Cross-account
   artifact decrypt *requires* a CMK — SSE-S3 can't be shared.)
2. **Extract `modules/codedeploy`** — the `aws_codedeploy_app` + `aws_codedeploy_deployment_group`
   for ONE env (fields: cluster/service name, production+test listener ARNs, blue/green TG names,
   rollback alarm names). `modules/pipeline/codedeploy.tf` keeps only **staging** (`local.envs`
   minus prod); the shared `aws_iam_role.deploy` stays for staging.
3. **New stack `watch/us-east-1/prod/deploy`** (routes to `watch-prod`) — uses `modules/codedeploy`
   for prod (depends on `prod/app` + `prod/observability` for the TGs/listeners/alarms) **plus** the
   cross-account deploy role: trusts the nonprod pipeline account, has `AWSCodeDeployRoleForECS`,
   `codedeploy:*`, `ecs:*`, `s3:GetObject*` on the artifact bucket, `kms:Decrypt` on the artifact
   key, and `iam:PassRole` for the prod ECS exec/task roles. CodeDeploy app/DG named `watch-prod`
   (predictable, so the pipeline references by string).
4. **Pipeline `DeployProd` action** (`codepipeline.tf`) — add the action-level
   `role_arn = <cross-account deploy role in watch-prod>`; set `ApplicationName`/`DeploymentGroupName`
   to the literal `watch-prod` names (no longer `aws_codedeploy_*.this["prod"]`). Pipeline role
   (`aws_iam_role_policy.pipeline`) gains `sts:AssumeRole` on that role + `kms:Decrypt`/`GenerateDataKey`
   on the artifact key.
5. **Pipeline inputs** — the `prod` object no longer feeds a CodeDeploy DG here; keep the fields the
   buildspec/migration-hook still use (`task_family`, subnets, sg, roles). The pipeline stack takes
   the cross-account role ARN as an input (predictable ARN or a dependency on `prod/deploy`).

Note: `CodeDeployToECS`'s `configuration` map has no role field — cross-account is the **action's**
`role_arn` argument (a general CodePipeline feature), not a Lambda wrapper.

## Platform CI (done 2026-07-04)
`terragrunt plan` on every PR + `apply` on manual dispatch, via the `gha-plan`/`gha-apply` OIDC
roles (`.github/workflows/terragrunt-{plan,apply}.yml`). Least-privilege cross-account: `gha-plan`
(read-only in management) assumes a read-only `watch-ci-plan` role in each member
(`modules/member-ci-role` + `member-ci/{nonprod,prod}`) — plan can never mutate a member; the
provider role is chosen by `WATCH_MEMBER_ROLE_NAME` (default admin for apply). Fork PRs get no OIDC.
Proven: plan-on-PR ran `run --all plan` over the whole estate read-only, 30/30 units. `apply` is
`workflow_dispatch`-only for now so a merge doesn't auto-recreate the disposable estate.

## Not yet done (follow-ups)
- **AWS new-account verification** — case opened; lifts the CloudFront + CodeBuild holds. Then:
  re-run the pipeline Build end-to-end, apply `prod/frontend` → `prod/dns-status`.
- **Org/accounts as code** — the accounts were created in the console; import them into an
  `account/organization` stack (`aws_organizations_organization` + `aws_organizations_account`,
  `prevent_destroy`) to manage them as code.
- **Per-member state buckets** (ADR-020 §3 hardening).
- **Scope down the apply path** — `gha-apply` still chains through admin `OrganizationAccountAccessRole`;
  a dedicated per-member apply role (narrower than admin) is the next tightening. (Plan is already
  least-privilege via `watch-ci-plan`.)
- **Switch apply-on-merge on** — flip `terragrunt-apply.yml` from `workflow_dispatch` to `push: main`
  once main should continuously track the live estate (not during the build/teardown cycle).
- **Split staging DNS too (symmetry)** — staging keeps one `dns` stack (both records); prod is
  split (`dns` + `dns-status`). Harmless (nonprod CloudFront isn't held); split later for parity.
