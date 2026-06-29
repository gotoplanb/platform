# Root Terragrunt config (platform#1). Every stack `include`s this and inherits:
#   - S3 remote state + DynamoDB locking (the bucket/table are created once by ./bootstrap)
#   - a generated AWS provider + version pins
#
# Run with a profile set (AWS_PROFILE=watch-ro to plan/verify, watch-bootstrap for the
# one-time bootstrap apply); get_aws_account_id() reads it via STS. Use OpenTofu:
#   TG_TF_PATH=tofu terragrunt ...

locals {
  region     = "us-east-1"
  account_id = get_aws_account_id()
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket         = "watch-tfstate-${local.account_id}"
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = local.region
    encrypt        = true
    dynamodb_table = "watch-tflocks"
    # Bucket/table are created explicitly by ./bootstrap — don't let Terragrunt mutate them.
    disable_bucket_update = true
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region = "${local.region}"
      default_tags {
        tags = {
          project    = "watch"
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
