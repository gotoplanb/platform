# Account registry for the multi-account split (ADR-020). Read by the root terragrunt.hcl to
# route each stack to its target AWS account via provider assume-role. Blank member ids ==
# "not created yet" -> the root falls back to the current account, so the single-account estate
# keeps working unchanged until these are filled.
#
# Fill nonprod/prod AFTER applying account/organization (from its outputs):
#   ( cd account/organization && TG_TF_PATH=tofu terragrunt output account_ids )
#
# The base credentials (AWS_PROFILE) must be an identity in the MANAGEMENT account; the root
# provider then assume-roles OrganizationAccountAccessRole into the target member account.
locals {
  management_account_id = "614933206631" # the current account; owns the Org (kept clean) — "Dave Stanton"
  # Accounts exist (created 2026-07-03). Fill these two AT CUTOVER — they are intentionally blank
  # now so the running single-account estate is untouched. Filling them activates cross-account
  # routing on the NEXT apply, so only do it as step 2 of the cutover (teardown mgmt → fill → live):
  #   nonprod_account_id = "176980002992"  # "watch-platform" (staging + platform/build plane)
  #   prod_account_id    = "208166434910"  # "Watch Prod" (product-prod plane)
  nonprod_account_id = ""
  prod_account_id    = ""
}
