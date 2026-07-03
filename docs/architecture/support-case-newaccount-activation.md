# AWS Support case — new-account activation (CloudFront + CodeBuild)

Two brand-new AWS Organizations **member** accounts are under the standard new-account
fraud-prevention hold, which blocks CloudFront distribution creation and forces the
CodeBuild account-level concurrent-build limit to 0. Open an **Account & billing** case
(free on Basic support) to have AWS verify/activate the accounts.

> **The holds are non-deterministic per account.** Which subset an account draws is an
> independent AWS risk decision, not a config/env property — here nonprod drew CodeBuild-only
> and prod drew CloudFront-only. Don't assume sibling accounts get identical holds; open a case
> for whatever each account actually hits.

Account IDs live in `.env` (never committed — this repo is public). Substitute the real
values when you paste:

- **watch-nonprod** — `$WATCH_NONPROD_ACCOUNT_ID` — CodeBuild blocked
- **watch-prod** — `$WATCH_PROD_ACCOUNT_ID` — CloudFront blocked
- management account — `<mgmt-account-id>`

Open one case per member account (or one from the management account referencing both IDs).
Category: **Account and billing → Account → Activation**.

---

## Subject

    New Organizations member account — please verify/activate (CloudFront + CodeBuild blocked)

## Body (watch-prod — CloudFront)

    This account (<prod-account-id>) is a new member of my AWS Organization (management
    account <mgmt-account-id>). Creating a CloudFront distribution fails with:

      "Your account must be verified before you can add new CloudFront resources.
       To verify your account, please contact AWS Support."

    Please complete the new-account verification so I can create CloudFront
    distributions. This is a legitimate workload: a static status-page SPA served
    from S3 via CloudFront, deployed with Terraform/OpenTofu. Happy to provide any
    additional information. Thank you.

## Body (watch-nonprod — CodeBuild)

    This account (<nonprod-account-id>) is a new member of my AWS Organization (management
    account <mgmt-account-id>). Starting a CodeBuild build fails with:

      "Cannot have more than 0 builds in queue for the account
       (AccountLimitExceededException)"

    The per-compute Service Quota (Linux/Small) shows 10, but the account-level
    concurrent-build limit is effectively 0 — the standard new-account hold. Please
    complete new-account verification / lift the CodeBuild hold so builds can run.
    This is a legitimate CI/CD workload (CodePipeline + CodeBuild building a Django
    container image, gated by tests). Thank you.

---

## If opening ONE case from the management account

    I have two new Organizations member accounts under the standard new-account hold:

      - <prod-account-id> (watch-prod)     — CloudFront distribution creation blocked
                                             ("account must be verified")
      - <nonprod-account-id> (watch-nonprod) — CodeBuild account concurrent-build limit is 0
                                             ("Cannot have more than 0 builds in queue")

    Both are legitimate application/CI-CD workloads deployed via Terraform. Please
    verify/activate both member accounts to lift these new-account restrictions.
    Thank you.
