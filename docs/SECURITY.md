# What this deployment needs from your AWS account

**For a security reviewer.** This document, plus the five JSON policies in [`policies/`](../policies/),
is the complete list of AWS permissions this project requires. Nothing here is
negotiable-by-omission: if an action is not in these documents, the deployment cannot perform it —
the identity that runs our Terraform has these permissions and no others, and there is no admin
credential in the loop after the one bootstrap step described in §5.

See §6 for **how we know that's true**, and for what is still being proven.

Render them with your account id, then read them:

```bash
ACCOUNT_ID=123456789012 make policies          # prints them; OUT=./handover writes files
```

---

## 1. Three identities, not one

The usual smell in an IaC repo is a single admin credential that provisions, deploys, and verifies.
This project separates them, because they have genuinely different blast radii:

| Identity | Who uses it | What it can do | Where it's defined |
|---|---|---|---|
| **`watch-provisioner`** | OpenTofu — `make live`, `make teardown`, and the CI apply job | Create/destroy the estate: the actions in the four `watch-provisioner-*.json` documents. **Cannot** create IAM users or access keys, touch the organization, the account, or billing, or grant itself more IAM. | `modules/provisioner-role`, applied by `account/provisioner` + `member-iam/*` |
| **`watch-ci-plan`** | The plan-on-PR CI job | `ReadOnlyAccess`. The plan path can never mutate anything. | `modules/member-ci-role` |
| **`watch-ro`** | Humans (and Claude) verifying a live estate | `ReadOnlyAccess`. | Your SSO/IAM, not created by us |

The CI **apply** role (`gha-apply`, GitHub OIDC, trusted only from `refs/heads/main`) holds **no
permissions of its own**. Its entire policy is `sts:AssumeRole` on the provisioner. Whatever CI can
do, you have already read in these documents.

## 2. The part worth your attention: IAM

The provisioner must create about 25 IAM roles — task roles, Lambda roles, the pipeline's roles. That
means it needs `iam:CreateRole` and `iam:AttachRolePolicy`, and **unfenced, those two actions are a
path to administrator**: create a role with `AdministratorAccess`, assume it, done. Any policy that
grants them and calls itself least-privilege is lying to you.

So they are fenced by a **permissions boundary** (`policies/watch-boundary.json`):

- The provisioner may only call `iam:CreateRole` **if the new role carries the boundary** —
  enforced by an `iam:PermissionsBoundary` condition (`CreateEstateRolesONLYWithTheBoundaryAttached`
  in `watch-provisioner-iam.json`). A role without the boundary cannot be created at all.
- The boundary **denies all IAM writes** to every role it caps (`ButNeverGrantThemselvesMoreIam`).
  A role the estate creates can use the account; it can never mint a more powerful identity. Reads
  and `iam:PassRole` are allowed, because the pipeline and deploy-hook roles genuinely need them.
- The provisioner **cannot alter the boundary, or its own policies, or its own role**
  (`NeverWeakenTheFenceThatHoldsYou`). It cannot escape its own fence.
- The provisioner **cannot create an IAM user, an access key, or a login profile**
  (`NeverMintHumansOrKeys`) — no long-lived credential can come out of this.
- Nothing — provisioner or estate role — can touch **Organizations, account settings, or billing**,
  or delete the **CloudTrail/Config audit trail**.

Role names are fenced to `watch-*` and `gha-*`; policy names to `watch-*`. The provisioner cannot
modify a role that isn't ours.

This is enforced in CI and in a pre-commit hook (`scripts/policy-check.sh`): if anyone ever removes
the boundary condition, or adds an IAM role that doesn't carry the boundary, the build goes red. The
fence cannot rot quietly.

**One thing you will notice if you run AWS Access Analyzer over these yourself:** the *boundary*
reports findings (`PASS_ROLE_WITH_STAR_IN_ACTION_AND_RESOURCE`, `CREATE_SLR_WITH_STAR_...`). That is
expected and correct. Access Analyzer reads every document as a grant, and a boundary is not a grant
— it is a **ceiling**: its `Allow *` exists solely to be cut down by the Denies beneath it, and
attaching it to a principal confers nothing. The four provisioner documents, which *are* grants, are
required to come back with **zero** findings above `SUGGESTION`, and the gate fails if they don't.

## 3. What it builds, service by service

Split into four documents so each can be read on its own (and because IAM caps a managed policy at
6144 characters):

| Document | Services | Notes |
|---|---|---|
| `watch-provisioner-core.json` | VPC/EC2 networking, ECS/Fargate, ELBv2, Application Auto Scaling, Cloud Map, CloudWatch Logs + alarms | Explicitly **denies** `ec2:RunInstances`, key pairs, VPC peering, transit gateways, VPN — this workload runs no EC2 instances and opens no network paths out of the VPC. |
| `watch-provisioner-data.json` | RDS, ElastiCache, KMS, SSM Parameter Store, Secrets Manager, AppConfig | Explicitly **denies** snapshot copy/share, `RestoreDBInstanceFromS3`, export tasks, secret and key replication — the exfiltration verbs. |
| `watch-provisioner-delivery.json` | ECR, S3, DynamoDB (state lock), Lambda, Step Functions, SQS, API Gateway, CodeBuild/CodePipeline/CodeDeploy/CodeStar Connections, CloudFront, ACM, Budgets | S3 rights are scoped to `watch-*` buckets **only**, and the Terraform state bucket is explicitly protected from deletion even from the provisioner. |
| `watch-provisioner-iam.json` | IAM | §2 above. The one to read closely. |

Everything regional is conditioned on `aws:RequestedRegion` = your region (default `us-east-1`).

### What we could not scope further, and why

An honest list, because you will look for it:

- **EC2/VPC create actions take `Resource: "*"`.** AWS does not issue an ARN before the resource
  exists, so `ec2:CreateVpc` cannot be resource-scoped; the fences available are the region condition
  (applied) and tag conditions (not applied — several of these resources, e.g. routes and route-table
  associations, cannot carry tags at all, so a tag condition would break the apply rather than secure
  it). The compensating control is the explicit deny on `RunInstances`/peering/VPN above: the
  provisioner can build this VPC's plumbing and cannot build a way out of it.
- **ECS, Lambda, Step Functions, SQS, CodeBuild/CodePipeline/CodeDeploy** are region-scoped but not
  name-scoped. Their create-time ARNs are only known to Terraform, and AWS's resource-level support
  across these services is uneven. If you require name-prefix conditions here, the accounts these
  deploy into should be dedicated to this workload (which is the topology we recommend anyway).
- **CloudFront and ACM are global**, so no region condition applies.
- **`kms:Encrypt`/`Decrypt`/`GenerateDataKey`** are granted because Terraform reads and writes
  SSM SecureStrings and the RDS master secret during apply.

### Actions that are here only because the live rehearsal demanded them

Every one of these was **absent** from a policy written by reading all the Terraform, and **added**
because the estate refused to build without it. They are the argument for §6.

| Action | Why it is needed |
|---|---|
| `route53:*` (private zones) | Cloud Map's `aws_service_discovery_private_dns_namespace` creates a **Route53 private hosted zone** under the hood. There is not a single `aws_route53_*` resource in this repo — the requirement is invisible in the source. |
| `states:ValidateStateMachineDefinition` | The AWS provider **validates the ASL before creating** the state machine. A read-shaped call that no resource inventory implies. |
| `apigateway:TagResource` / `UntagResource` | API Gateway **v2** tags through these. Note: **AWS Access Analyzer reports that these actions do not exist** — its action database is out of date. We removed them on Analyzer's advice, and `CreateStage` then failed with `AccessDenied` in the live run. The policy gate now ignores that specific finding, with this explanation attached. A validator is evidence; the estate is the oracle. |
| `logs:CreateLogDelivery` (+ `Get`/`Update`/`Delete`/`List`, `PutResourcePolicy`) | API Gateway **access logging** is configured through the CloudWatch Logs *delivery* API — a different action family from `logs:CreateLogGroup`, and required merely to create the stage. |
| `application-autoscaling:ListTagsForResource` | That service reads tags through `List*`, not `Describe*`. Terraform reads them on every refresh, so this fails on the *second* apply, not the first. |
| `iam:PassRole` on `arn:aws:iam::*:role/watch-*-deploy` | The pipeline lives in the nonprod account but passes **prod's** `watch-prod-deploy` role to CodePipeline. Cross-account `PassRole` is evaluated in the *calling* account, so a same-account resource scope is not enough. Still conditioned on `iam:PassedToService`. |
| `s3:DeleteObjectVersion` | The buckets are **versioned**, so emptying one on destroy means deleting object versions and delete markers — not just objects. **This is the one that only `teardown` reveals**, and the one whose absence would leave an adopter unable to destroy what they created. |
| `sts:AssumeRole` **in the boundary** | See below. |

### The finding that justifies the whole exercise

The permissions boundary's `ButNeverGrantThemselvesMoreIam` statement denies everything except a
read-list **on IAM resources** (`arn:aws:iam::*:*`). An `sts:AssumeRole` call *targets an IAM role
ARN* — so it matched that resource, was not in the allow-list, and **was denied**. Every bounded role
was silently blocked from assuming any role: the pipeline could not reach the cross-account deploy
role, and **`gha-apply` — whose entire policy is `sts:AssumeRole` on the provisioner — could do
nothing at all.** CI would have been dead on arrival for every adopter.

The static gate was perfectly happy with that policy: valid IAM, correct conditions, no wildcards,
all 25 roles fenced. Green, and broken. `sts:AssumeRole` is now permitted through the boundary,
which is safe precisely because a bounded role **cannot change its own identity policy** — it can
only assume what it was already explicitly granted, and it can never grant itself more.

This is why §6 insists on the live rehearsal, and why re-running it is on the major-release checklist.

### A hole the fence caught in its own plumbing

`modules/pipeline` calls `modules/codedeploy` as a **child module**. The Terragrunt root input that
carries the boundary only reaches the *root* module — so the child's IAM role was being created
**unfenced**, and `iam:CreateRole` was correctly denied. The fence caught a gap in its own wiring.
`scripts/policy-check.sh` now asserts that every module call into a role-creating child forwards the
boundary, so it cannot recur.

## 4. Where the roles go, per topology

The three supported shapes (see [`TOPOLOGIES.md`](TOPOLOGIES.md)); the policies are identical in all
three, only their location differs.

| Topology | Where the provisioner + boundary live | How you assume it |
|---|---|---|
| **Single account** | That account (`account/provisioner`) | An AWS profile with `role_arn = arn:aws:iam::<acct>:role/watch-provisioner`, or `WATCH_ASSUME_IN_ACCOUNT=1` |
| **Two members, new org** | Hub (`account/provisioner`) + each member (`member-iam/{nonprod,prod}`) | `WATCH_MEMBER_ROLE_NAME=watch-provisioner` — the hub identity assumes it in each member |
| **Two members, existing org** | Same as above | Same. If your landing zone already has an assumable role (`AWSControlTowerExecution`, etc.), it is used once, to create these — after that, nothing needs it |

The provisioner stacks are **persistent**: `make teardown` destroys the estate but never the identity
that destroys it.

## 5. The bootstrap problem, stated plainly

Something has to create the provisioner, and creating IAM roles requires IAM rights. So there is
exactly one admin-shaped step, and it is this:

```bash
# ONCE, with an admin identity (your break-glass, or AWS SSO AdministratorAccess):
WATCH_BOUNDARY=0 terragrunt apply -w account/provisioner     # hub (or the single account)
WATCH_BOUNDARY=0 terragrunt apply -w member-iam/nonprod      # each member
WATCH_BOUNDARY=0 terragrunt apply -w member-iam/prod
```

(`WATCH_BOUNDARY=0` because the boundary cannot be attached to roles until it exists.)

After that, the admin credential is **not needed again** — not for `make live`, not for teardown, not
for CI — and should be rotated or removed. If you would rather not run our Terraform with admin at
all: render the policies (`make policies`) and create the role, the boundary, and the four policies
by hand, or with your own tooling. The rest of this repo neither knows nor cares how they got there.

## 6. How we know these are correct

Not by reading them. A policy is only correct if it can actually build the thing.

- **Statically** — enforced on every PR and every commit (`make policy-check`): documents valid IAM,
  within the size limit, no `Allow *:*`, `iam:CreateRole` conditioned on the boundary, and every one
  of the 25 IAM roles in this repo carrying that boundary.
- **Live** — a full `make live` → `make live-verify` → `make teardown` performed **as
  `watch-provisioner` with no admin credential available**, once per topology. Teardown is the part
  that matters: a missing `Delete*` action does not surface until you try to leave.

> **Status (2026-07-13).** The static gate is in force. The live rehearsal is **done for the
> two-member topology** — the one an enterprise actually uses: a full `make live` → `live-verify`
> (app, worker, API and status page green in both accounts) → `make teardown` → `sweep` (no billable
> orphans), performed as `watch-provisioner` with no admin credential in the call path. It took
> **nine findings** to get there; all nine are recorded above, because an adopter re-reviewing these
> policies must be able to diff them and see why each action is present.
>
> **The single-account topology is now proven too** — `make live` → `make teardown` → `sweep` (no
> billable orphans), again as `watch-provisioner` with no admin credential in the call path, with
> **zero denials on both the create and the destroy path, and not one action added to these
> documents.** That is the useful result: the policies are a property of the *workload*, not of the
> account layout. What single-account did surface was a **design** flaw
> on our side, not a policy gap — several stacks each created an account-global name (the GitHub OIDC
> provider; `watch-provisioner` and `watch-boundary` themselves), which collided once they all landed
> in one account. Fixed and guarded in ADR-045 / [#57](https://github.com/gotoplanb/platform/issues/57)
> / [#58](https://github.com/gotoplanb/platform/issues/58). **Adopters should care about that fix:**
> it is also what would have made this repo collide with the GitHub federation your accounts already
> have. Set `WATCH_GITHUB_OIDC_EXISTS=1` and we adopt yours rather than fight it.
>
> The existing-org variant is tracked in
> [platform#55](https://github.com/gotoplanb/platform/issues/55). It differs from the two-member
> rehearsal only in *which admin role the hub assumes* (`WATCH_MEMBER_ROLE_NAME`), which the proven
> run already exercised by assuming `watch-provisioner` — but "nearly proved" is not "proved", and
> this document will say so until it is.

Re-proving both is on the **major-release checklist**, so the policies cannot drift away from what
you signed off on without the release failing.
