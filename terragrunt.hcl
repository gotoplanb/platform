# Root Terragrunt config (platform#1). Every stack `include`s this and inherits:
#   - S3 remote state + DynamoDB locking (the bucket/table are created once by ./bootstrap)
#   - a generated AWS provider + version pins
#
# Run with a profile set (AWS_PROFILE=watch-ro to plan/verify, watch-bootstrap for the
# one-time bootstrap apply); get_aws_account_id() reads it via STS. Use OpenTofu:
#   TG_TF_PATH=tofu terragrunt ...

locals {
  region  = "us-east-1"
  current = get_aws_account_id()

  # Boilerplate rename knob (platform#50): one env var renames the state bucket/lock-table
  # prefix and the default project tag. Default keeps this estate exactly as-is. If you change
  # it, pass the same prefix to ./bootstrap (-var state_bucket_prefix / lock_table_name).
  project = get_env("WATCH_PROJECT", "watch")

  # Multi-account routing (ADR-020). Map each stack (by path) to its target account; blank member
  # ids in accounts.hcl fall back to the current account, so this is a NO-OP for the single-account
  # estate until the ids are filled.
  acct = read_terragrunt_config(find_in_parent_folders("accounts.hcl")).locals
  rel  = path_relative_to_include()
  want = (
    # All account-level governance -> management (= current): the org, the platform-repo CI base
    # (OIDC provider + plan/apply roles + the account that assumes into members), and the
    # consolidated-billing budgets / cost-allocation-tag activation (payer-account only). None of
    # these belong in a member account; routing them to nonprod was a dormant landmine (ADR-020).
    startswith(local.rel, "account/")                  ? local.current :
    startswith(local.rel, "member-ci/nonprod")         ? local.acct.nonprod_account_id : # read-only CI plan role in nonprod
    startswith(local.rel, "member-ci/prod")            ? local.acct.prod_account_id :    # read-only CI plan role in prod
    startswith(local.rel, "watch/us-east-1/prod/")     ? local.acct.prod_account_id :
    startswith(local.rel, "watch/us-east-1/staging/")  ? local.acct.nonprod_account_id :
    local.acct.nonprod_account_id # foundation (ecr/pipeline/connection/ci-trigger, watch/us-east-1/*) -> nonprod
  )
  target = local.want != "" ? local.want : local.current
  cross  = local.target != local.current

  # Which role the provider assumes in the target member account. Defaults to the admin
  # OrganizationAccountAccessRole (local dev, bootstrap, CI apply). The plan-on-PR CI job sets
  # WATCH_MEMBER_ROLE_NAME=watch-ci-plan so plan assumes the READ-ONLY member role instead (ADR-020).
  # Empty-string coalesces to the default (not just unset) so a blank WATCH_MEMBER_ROLE_NAME= in
  # .env behaves like the shell scripts' ${VAR:-default} — terragrunt and xacct must never disagree
  # on the role (caught by test/topology_test.go, platform#50).
  member_role_name = get_env("WATCH_MEMBER_ROLE_NAME", "") != "" ? get_env("WATCH_MEMBER_ROLE_NAME", "") : "OrganizationAccountAccessRole"

  # Base creds live in the management account and assume OrganizationAccountAccessRole into the
  # target member account. State stays centralized in the management bucket for now (per-member
  # state buckets are a later hardening — see ADR-020); the bucket keys off the current account.
  account_id      = local.current
  assume_role_block = local.cross ? "assume_role { role_arn = \"arn:aws:iam::${local.target}:role/${local.member_role_name}\" }" : ""
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket         = "${local.project}-tfstate-${local.account_id}"
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = local.region
    encrypt        = true
    dynamodb_table = "${local.project}-tflocks"
    # Bucket/table are created explicitly by ./bootstrap — don't let Terragrunt mutate them.
    disable_bucket_update = true
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region              = "${local.region}"
      allowed_account_ids = ["${local.target}"]
      ${local.assume_role_block}
      default_tags {
        tags = {
          project    = "${local.project}"
          managed_by = "terragrunt"
          repo       = "gotoplanb/platform"
        }
      }
    }
  EOF
}

generate "versions" {
  path      = "versions.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    terraform {
      required_version = ">= 1.6"
      required_providers {
        aws = {
          source  = "hashicorp/aws"
          version = "~> 6.0"
        }
      }
    }
  EOF
}
