# Account registry for the multi-account split (ADR-020). Read by the root terragrunt.hcl to route
# each stack to its target AWS account via provider assume-role, and by the few stacks that need to
# name another account in a policy (trust, cross-account pull, cross-account assume).
#
# The IDs live in ~/platform/.env (gitignored), NOT here — the repo is public, and this keeps to
# the "never hardcode an account id" convention (the root reads the management account via
# get_aws_account_id()).
#
# In .env:  WATCH_NONPROD_ACCOUNT_ID=...  WATCH_PROD_ACCOUNT_ID=...  (source before running)
#
# A BLANK member id means two different things, and conflating them is what broke the
# single-account topology (platform#58): a stack read the raw blank and rendered
# "arn:aws:iam:::root", which IAM rejects. So both meanings are named here, and nothing should read
# the environment variable directly:
#
#   *_account_id  — WHERE a stack lives. Always resolves; blank falls back to the current account,
#                   because in the single-account topology "prod" IS this account. Use this to
#                   route a stack, or to name the account in a policy.
#   has_*         — whether a SEPARATE member account exists. This, and only this, is the
#                   cross-account signal: guard cross-account grants (ECR pull, assume-role,
#                   the pipeline's cross-account deploy role) on it.
locals {
  current = get_aws_account_id()

  nonprod_id_env = get_env("WATCH_NONPROD_ACCOUNT_ID", "") # watch-platform (staging + platform/build)
  prod_id_env    = get_env("WATCH_PROD_ACCOUNT_ID", "")    # watch-prod (product-prod)

  has_nonprod = local.nonprod_id_env != ""
  has_prod    = local.prod_id_env != ""

  nonprod_account_id = local.has_nonprod ? local.nonprod_id_env : local.current
  prod_account_id    = local.has_prod ? local.prod_id_env : local.current
}
