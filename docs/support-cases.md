# AWS Support cases — new-account holds

Two new-account anti-abuse holds gate the Watch estate. Both must be filed from the **AWS console**
(the accounts are on **Basic** support, so the Support *API* returns `SubscriptionRequiredException`;
but new-account **limit-increase** and **account/billing** cases are available on Basic). Account IDs
live in `.env` (`WATCH_NONPROD_ACCOUNT_ID`, `WATCH_PROD_ACCOUNT_ID`) — never in this public repo.

File each from the console **while signed into that member account** (switch-role from the management
IAM admin — see `docs/architecture/accounts.md`).

## Case 1 — CodeBuild new-account build restriction  ·  account: `$WATCH_NONPROD_ACCOUNT_ID`

**Impact:** blocks CI/CD. Pipeline `watch` fails at **Build** (`StartBuild`) before any build runs, so
no commit reaches staging/prod through the pipeline (we deploy manually meanwhile).

- **Console path:** Support Center → Create case → **Looking to increase service limits?** →
  Service: **CodeBuild**, Region: **us-east-1**.
- **Subject:** New-account CodeBuild concurrent-build restriction — please remove
- **Body:**
  > Every build fails immediately at `StartBuild` with
  > `AccountLimitExceededException: Cannot have more than 0 builds in queue for the account`.
  > The project uses `BUILD_GENERAL1_SMALL` (Linux/Small), whose Service Quota (L-9D07B6EF) already
  > shows 10 — so this is the new-account concurrent-build safeguard overriding the quota, not a quota
  > value. This account runs a CodePipeline → CodeBuild CI/CD pipeline for our application. Please lift
  > the new-account build restriction so builds can run.

## Case 2 — CloudFront account verification  ·  accounts: `$WATCH_NONPROD_ACCOUNT_ID` **and** `$WATCH_PROD_ACCOUNT_ID`

**Impact:** blocks only the `{env}/frontend` (CloudFront) + `{env}/dns-status` stacks — the status-page
SPAs. The APIs (`watch.` / `watch-stg.`) are unaffected (DNS split, ADR-020). File once **per account**.

- **Console path:** Support Center → Create case → **Account and billing** → Service: **CloudFront**
  (or the "verify my account for CloudFront" flow).
- **Subject:** CloudFront account verification for new account
- **Body:**
  > Creating a CloudFront distribution fails with
  > `AccessDenied: Your account must be verified before you can add new CloudFront resources.`
  > Please verify this account for CloudFront. RequestID (this account's failed attempt):
  > **nonprod/staging** `c925854a-66ab-4129-a362-61f244a6a97b` · **prod** `d11dcdb3-39e5-42c3-80d2-44d1866402cb`.

## Status

- [ ] Case 1 — CodeBuild restriction (nonprod) — filed: ____  · resolved: ____
- [ ] Case 2a — CloudFront verify (nonprod) — filed: ____  · resolved: ____
- [ ] Case 2b — CloudFront verify (prod) — filed: ____  · resolved: ____

**Verify a lift:** CodeBuild → trigger pipeline `watch`, Build should pass `StartBuild`.
CloudFront → re-run `make live` (or apply `{env}/frontend`), the distribution should create; then
`{env}/dns-status` lands the `status[-stg].davestanton.com` record.
