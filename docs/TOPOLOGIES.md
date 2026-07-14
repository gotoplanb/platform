# Deployment topologies (platform#50)

This repo deploys into **three account topologies** with the same code. The contract is
deliberately small: **zero or two member account IDs (`.env`) plus a role the hub can
assume**. There are no `aws_organizations_*` resources here and never will be — account
vending (creating orgs, vending accounts, landing zones) is permanently out of scope; if it
ever becomes code, it's a separate repo. You bring accounts; this repo brings everything
inside them.

The root `terragrunt.hcl` routes each stack by path: blank member IDs collapse every route
to the current account (`cross=false`, no assume-role); filled IDs send staging-classed
stacks to the nonprod member and prod-classed stacks to the prod member via provider
assume-role. State always lives in the hub account's bucket.

Verify any topology before applying: **`make topology-check`** (read-only; `PLAN=1` adds
representative terragrunt plans).

**Regression protection (Terratest, `test/`):** `make test-topology` renders every routing
class under all three topologies (plus the `WATCH_PROJECT` rename knob) and asserts the
generated provider targets the right account with the right assume-role — fast, mutation-free,
fake member ids, read-only creds, so it runs anywhere. `make test-member-access` is the one
real apply/assume/destroy Terratest (opt-in; hub admin creds) proving the invited-account
role module end to end. Evolve the routing map or the knobs, and these fail before an adopter
does.

---

## 1. Single account

Everything — staging, prod, pipeline, foundation — in one account. Right for trials, small
shops, and cost-minimal setups. Resource names are `<project>-<env>-*`, so the two envs
coexist without collisions.

**Setup:**
- Leave `WATCH_NONPROD_ACCOUNT_ID` / `WATCH_PROD_ACCOUNT_ID` **unset** (or absent from `.env`).
- Apply `./bootstrap` once (state backend), then the normal `make create` / lifecycle.

**Skip:** `member-ci/*` (no members to harden). `account/*` budgets apply to the one account.

## 2. Two members of a NEW organization

The reference topology (ADR-020): a management/hub account owns state + CI identities; a
nonprod member runs staging + the build foundation; a prod member runs production alone.

**Setup:**
- Create the org and the two member accounts out-of-band (console/CLI — deliberately not
  this repo's job).
- Accounts **created by** an org get `OrganizationAccountAccessRole` automatically — the
  default role name; nothing to override.
- Fill both IDs in `.env`; `./bootstrap` in the hub; normal lifecycle.

**Note:** fresh member accounts can carry AWS verification holds (CloudFront creation,
CodeBuild concurrency 0) for days — see `docs/support-cases.md`.

## 3. Two members of an EXISTING organization

Same mechanics as topology 2 — the only difference is **who vended the accounts and which
role the hub may assume**.

**Setup:**
- Fill both IDs in `.env` with your two accounts.
- Role, one of:
  - Your accounts already have `OrganizationAccountAccessRole` (org-created): done.
  - Your landing zone vends a different admin role (e.g. Control Tower's
    `AWSControlTowerExecution`): set `WATCH_MEMBER_ROLE_NAME=<that role>` in `.env`. It is
    honored by the root terragrunt (provider assume-role) **and** the lifecycle scripts'
    raw-CLI steps (`scripts/lib/xacct.sh`).
  - Your accounts were **invited** into the org and have no hub-assumable role at all:
    mint one with [`member-access/`](../member-access/README.md) (applied once per member
    with member credentials, like `bootstrap`).
- `./bootstrap` in whichever account runs applies (your "hub" — it need not be the org's
  management account), then the normal lifecycle.

- **If your accounts already run GitHub Actions** — i.e. they already have a
  `token.actions.githubusercontent.com` OIDC provider — set `WATCH_GITHUB_OIDC_EXISTS=1`.
  An OIDC provider is account-global (one per URL per account), so we then **adopt** yours
  instead of creating one. Without this we would fail with `409 EntityAlreadyExists` on your
  existing federation, and we will never destroy or contest infrastructure we did not create
  (ADR-045). Your provider's trust conditions are unaffected; we only add roles that reference it.

**Mode-dependent stacks:**
- `account/budget-*` assumes the hub account sees the (consolidated) billing — in an
  existing org, billing usually consolidates at *their* management account, not your hub.
  Skip or adapt.
- `member-ci/*` is optional hardening (read-only plan roles for CI); apply if you use the
  plan-on-PR workflow.
- `account/oidc-provider` + `member-oidc/nonprod` own the GitHub federation entry in the two
  accounts that actually federate: the hub (for the platform repo's plan/apply roles) and the
  pipeline's account (for the app repo's `StartPipelineExecution` trigger role). **Prod
  federates GitHub nowhere** — nothing in GitHub reaches prod directly; the nonprod pipeline
  does, by assuming `watch-prod-deploy`.

---

## Renaming for reuse

`WATCH_PROJECT` (default `watch`) renames the state bucket prefix (`<project>-tfstate-<acct>`),
the lock table (`<project>-tflocks`), and the default `project` tag in one place. Pass the
same prefix to `./bootstrap` (`-var state_bucket_prefix=… -var lock_table_name=…`).
Stack-level resource names inherit `project` from each env's `env.hcl`.

## First boot in a fresh account

`create.sh` refuses to apply until the ECR repo holds a seedable image (the app task def
pulls `:bootstrap`). In an account that has never run the estate (a new single-account
setup, or a rebuilt member), bootstrap in this order (verified 2026-07-12):

```bash
(cd watch/us-east-1/ecr && terragrunt apply)          # the repo, alone
docker build --platform linux/amd64 -t watch:seed <app-repo>/backend
docker tag … <account>.dkr.ecr.<region>.amazonaws.com/watch:seed && docker push …
make create                                            # self-heals :bootstrap from :seed
```

Never commit a pinned image sha into an app stack's `image_uri` — it binds the estate to
one account's ECR history and breaks every fresh account (and with the CodeDeploy
deployment controller, a live service can't be re-pointed by re-apply alone).

## Switching topologies on an existing installation

The **disposable estate** switches topologies freely: teardown, change `.env`, create.
The **kept foundation stacks do not** — `connection` and `ci-trigger` survive teardown,
and their state binds them to the account they were created in. Re-applying them under a
different topology fails on refresh (AccessDenied reading the other account's resources).
Before switching, `terragrunt destroy` those stacks under the OLD `.env` (a fresh
CodeStar connection then needs its one-time authorization again), or accept that CI/CD
plumbing stays in the original account. Also disable AppConfig deletion protection per
account (`aws appconfig update-account-settings --deletion-protection Enabled=false`) or
fast teardowns will trip it — see GOTCHAS.

The same applies, with teeth, to the stacks that own **account-global names** (ADR-045):
`account/provisioner`, `member-iam/{nonprod,prod}`, `account/oidc-provider`,
`member-oidc/nonprod`. State keys are per-*path*, not per-topology, so after a switch these
stacks still hold the **old account's** role and policy ARNs while the provider now points at
the new target — and because IAM deletes by *name*, an apply could destroy the identically
named role in the account you just switched to (including the provisioner you are applying
as). Release the stale entries; never destroy them:

```bash
cd member-iam/nonprod && terragrunt state rm aws_iam_role.provisioner aws_iam_policy.boundary ...
```

`state rm` forgets the resource without touching AWS — the old account's role stays where it
is, and re-importing it is how you switch back. In the topology where the stack is not the
owner it then creates nothing (`create = has_nonprod`), which is the correct no-op.

## Guardrails

`scripts/lib/preflight.sh` enforces the 0-or-2 rule: if **either** member ID is set, **both**
must be valid 12-digit IDs (a half-configured shell is exactly how a teardown once ran
against the wrong account). It names the detected topology on every run. A one-member
hybrid is deliberately rejected — express "one account" by leaving both blank.
