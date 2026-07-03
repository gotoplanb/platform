# Multi-account layout & cutover (ADR-020)

The estate is moving from one AWS account to an **Organization**: the current account stays as a
**clean management account** (org governance + billing, no workloads), and all workloads run in two
member accounts along the plane boundary.

| Plane | Account | ID | Holds |
|---|---|---|---|
| management (clean) | Dave Stanton | `614933206631` | the Org, consolidated billing, `account/organization`, centralized TF state (for now) |
| build / CI / dogfood | watch-platform | `176980002992` | staging + platform foundation (ECR, pipeline, connection, ci-trigger, Watchtower/Sonar), budgets |
| product prod | Watch Prod | `208166434910` | prod app/data/escalation/intake/frontend/gateway/dns/cert/observability |

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

## Cutover (run deliberately — this moves the estate to the members)

The estate is disposable, so the cutover is a **re-lay**, not a data migration. Order matters:

1. **Teardown the current estate in management** — `make teardown` with `accounts.hcl` still blank
   (targets `614933206631`). Wait out the VPC/ENI drain; `scripts/sweep.sh` → clean.
2. **Fill `accounts.hcl`** — uncomment `nonprod_account_id = "176980002992"` and
   `prod_account_id = "208166434910"`. This activates cross-account routing.
3. **Cross-account prerequisites** (one-time, in `watch-nonprod`): the shared ECR repo policy must
   grant `watch-prod` pull, and the pipeline needs a **cross-account CodeDeploy/ECS deploy role** in
   `watch-prod` (+ shared artifact-bucket KMS). This is the ADR-017 crux — build/verify before the
   first prod promote.
4. **`make live`** — stands the foundation + staging up in `watch-platform` and prod up in
   `watch-prod`, provider assume-role per stack. Verify endpoints + the obs plane as usual.

Roll back by re-blanking `accounts.hcl` (everything routes to management again).

## Not yet done (follow-ups)
- **Org/accounts as code** — the accounts were created in the console; import them into an
  `account/organization` stack (`aws_organizations_organization` + `aws_organizations_account`,
  `prevent_destroy`) to manage them as code.
- **Per-member state buckets** (ADR-020 §3 hardening).
- **Cross-account ECR pull + pipeline deploy role** (step 3) — the real ADR-017 proof.
- **Per-member `watch-bootstrap`/`watch-ro`** — today we assume `OrganizationAccountAccessRole`;
  scope down to dedicated roles later.
