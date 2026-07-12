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

**Mode-dependent stacks:**
- `account/budget-*` assumes the hub account sees the (consolidated) billing — in an
  existing org, billing usually consolidates at *their* management account, not your hub.
  Skip or adapt.
- `member-ci/*` is optional hardening (read-only plan roles for CI); apply if you use the
  plan-on-PR workflow.

---

## Renaming for reuse

`WATCH_PROJECT` (default `watch`) renames the state bucket prefix (`<project>-tfstate-<acct>`),
the lock table (`<project>-tflocks`), and the default `project` tag in one place. Pass the
same prefix to `./bootstrap` (`-var state_bucket_prefix=… -var lock_table_name=…`).
Stack-level resource names inherit `project` from each env's `env.hcl`.

## Guardrails

`scripts/lib/preflight.sh` enforces the 0-or-2 rule: if **either** member ID is set, **both**
must be valid 12-digit IDs (a half-configured shell is exactly how a teardown once ran
against the wrong account). It names the detected topology on every run. A one-member
hybrid is deliberately rejected — express "one account" by leaving both blank.
