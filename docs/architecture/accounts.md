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
**assume-roles `OrganizationAccountAccessRole`** into it:

- `watch/us-east-1/prod/*` → prod · `watch/us-east-1/staging/*` → nonprod · foundation + `account/*`
  + `github/*` → nonprod · `account/organization` → management.
- Base credentials (`AWS_PROFILE`) must be an identity in **management**; it assumes into the member.
- **Gated:** blank member IDs in `accounts.hcl` fall back to the current account, so the seam is a
  **no-op until you fill the IDs** — the single-account estate keeps working unchanged.
- **State stays centralized** in the management bucket for now (ADR-020 §3); per-member state is a
  later hardening.

Verified 2026-07-03: `OrganizationAccountAccessRole` is assumable from `watch-bootstrap` into both
members; with blank IDs, `plan` on the live estate shows **no changes**.

## RESUME POINT (checkpoint 2026-07-03)

Everything below is staged; the running estate is being torn down as a checkpoint. State of play:
- **Done + committed, gated (no effect until `.env` is filled):** the provider seam (root
  `terragrunt.hcl` + `accounts.hcl`, assume-role proven into both members) and the ECR
  cross-account pull policy.
- **In flight:** `make teardown` of the current single-account estate (tmux `watch:shell`, log
  `scratchpad/teardown-cutover.log`). Wait for it + `scripts/sweep.sh` → clean.
- **Not built yet:** the cross-account pipeline refactor — the atomic 5-step unit in the *build
  spec* section above (artifact KMS CMK, extract `modules/codedeploy`, `prod/deploy` stack +
  cross-account role, `DeployProd` action `role_arn`, pipeline inputs).

**Owner note:** state is disposable and prod need not stay up (daily build/teardown). So this is a
**clean re-lay, not a migration** — no state preservation, no backward-compat needed.

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

## Cross-account pipeline deploy — build spec (Option A, ADR-017)

The pipeline (nonprod) builds once and deploys prod **in `watch-prod`** via CodePipeline's
action-level cross-account `role_arn`. Done so far: **ECR repo policy** grants `watch-prod` pull
(`modules/ecr`, gated on `WATCH_PROD_ACCOUNT_ID`). Remaining (an atomic unit — do together):

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

## Not yet done (follow-ups)
- **Org/accounts as code** — the accounts were created in the console; import them into an
  `account/organization` stack (`aws_organizations_organization` + `aws_organizations_account`,
  `prevent_destroy`) to manage them as code.
- **Per-member state buckets** (ADR-020 §3 hardening).
- **Cross-account ECR pull + pipeline deploy role** (step 3) — the real ADR-017 proof.
- **Per-member `watch-bootstrap`/`watch-ro`** — today we assume `OrganizationAccountAccessRole`;
  scope down to dedicated roles later.
