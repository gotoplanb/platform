# Account registry for the multi-account split (ADR-020). Read by the root terragrunt.hcl to route
# each stack to its target AWS account via provider assume-role.
#
# The IDs live in ~/platform/.env (gitignored), NOT here — the repo is public, and this keeps to
# the "never hardcode an account id" convention (the root reads the management account via
# get_aws_account_id()). Blank member ids == "not created yet" -> the root falls back to the
# current account, so the single-account estate keeps working until .env is populated at cutover.
#
# In .env:  WATCH_NONPROD_ACCOUNT_ID=...  WATCH_PROD_ACCOUNT_ID=...  (source before running)
locals {
  nonprod_account_id = get_env("WATCH_NONPROD_ACCOUNT_ID", "") # watch-platform (staging + platform/build)
  prod_account_id    = get_env("WATCH_PROD_ACCOUNT_ID", "")    # watch-prod (product-prod)
}
