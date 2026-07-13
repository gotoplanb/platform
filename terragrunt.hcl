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

  # Multi-account routing (ADR-020). Map each stack (by path) to its target account. accounts.hcl
  # already resolves a blank member id to the current account, so this is a NO-OP for the
  # single-account estate until the ids are filled — and it resolves it in ONE place, which is the
  # point: this routing used to coalesce the blank itself, so a stack that read the raw env var and
  # rendered "arn:aws:iam:::root" stayed invisible until an apply (platform#58).
  acct = read_terragrunt_config(find_in_parent_folders("accounts.hcl")).locals
  rel  = path_relative_to_include()
  target = (
    # All account-level governance -> management (= current): the org, the platform-repo CI base
    # (OIDC provider + plan/apply roles + the account that assumes into members), and the
    # consolidated-billing budgets / cost-allocation-tag activation (payer-account only). None of
    # these belong in a member account; routing them to nonprod was a dormant landmine (ADR-020).
    startswith(local.rel, "account/") ? local.current :
    startswith(local.rel, "member-ci/nonprod") ? local.acct.nonprod_account_id :  # read-only CI plan role in nonprod
    startswith(local.rel, "member-ci/prod") ? local.acct.prod_account_id :        # read-only CI plan role in prod
    startswith(local.rel, "member-iam/nonprod") ? local.acct.nonprod_account_id : # provisioner role + boundary (ADR-044)
    startswith(local.rel, "member-iam/prod") ? local.acct.prod_account_id :
    startswith(local.rel, "member-oidc/nonprod") ? local.acct.nonprod_account_id : # GitHub federation entry for the pipeline account (platform#57)
    startswith(local.rel, "watch/us-east-1/prod/") ? local.acct.prod_account_id :
    startswith(local.rel, "watch/us-east-1/staging/") ? local.acct.nonprod_account_id :
    local.acct.nonprod_account_id # foundation (ecr/pipeline/connection/ci-trigger, watch/us-east-1/*) -> nonprod
  )
  cross = local.target != local.current

  # Which role the provider assumes in the target member account. Defaults to the admin
  # OrganizationAccountAccessRole (local dev, bootstrap, CI apply). The plan-on-PR CI job sets
  # WATCH_MEMBER_ROLE_NAME=watch-ci-plan so plan assumes the READ-ONLY member role instead (ADR-020).
  # Empty-string coalesces to the default (not just unset) so a blank WATCH_MEMBER_ROLE_NAME= in
  # .env behaves like the shell scripts' ${VAR:-default} — terragrunt and xacct must never disagree
  # on the role (caught by test/topology_test.go, platform#50).
  member_role_name = get_env("WATCH_MEMBER_ROLE_NAME", "") != "" ? get_env("WATCH_MEMBER_ROLE_NAME", "") : "OrganizationAccountAccessRole"

  # Normally we only assume when crossing an account boundary. But the provisioner (ADR-044) is a
  # role you assume even in your OWN account — that is the whole point: the caller (a human, or the
  # gha-apply OIDC role) holds nothing but sts:AssumeRole, and every write happens as the fenced
  # identity. WATCH_ASSUME_IN_ACCOUNT=1 turns that on; default off keeps the old behaviour exactly,
  # so a bootstrap-admin run and the single-account topology are unchanged until you opt in.
  assume_in_account = get_env("WATCH_ASSUME_IN_ACCOUNT", "0") == "1"

  # Base creds live in the management account and assume OrganizationAccountAccessRole into the
  # target member account. State stays centralized in the management bucket for now (per-member
  # state buckets are a later hardening — see ADR-020); the bucket keys off the current account.
  account_id        = local.current
  assume_role_block = (local.cross || local.assume_in_account) ? "assume_role { role_arn = \"arn:aws:iam::${local.target}:role/${local.member_role_name}\" }" : ""
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

# The permissions boundary every estate role must carry (ADR-044). Terragrunt merges these root
# inputs into every stack, and OpenTofu ignores a TF_VAR_ for a variable a module doesn't declare —
# so this reaches all ~24 roles without touching 20 stack files.
#
# It is a KNOB, not a mandate: WATCH_BOUNDARY=0 renders it empty, which is how you run this repo in
# an estate that hasn't adopted the fence (or during the one-time admin apply that CREATES the
# boundary, before it exists). Default on, because the fence is the whole point: without it, the
# provisioner's iam:CreateRole is a path to admin, and no security team will sign that.
inputs = {
  permissions_boundary = (
    get_env("WATCH_BOUNDARY", "1") == "0"
    ? ""
    : "arn:aws:iam::${local.target}:policy/${local.project}-boundary"
  )
}
