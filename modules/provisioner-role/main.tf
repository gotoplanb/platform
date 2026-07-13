# The role that replaces bootstrap-admin (ADR-044).
#
# `watch-bootstrap` is an unrotated admin key doing three different jobs — provision, deploy, verify.
# No security team will approve that, which is the single biggest thing standing between this repo
# and a real engagement. This module mints the PROVISIONER: the identity OpenTofu runs as, holding
# exactly the actions the estate's own modules need, and no more.
#
# The interesting part is IAM. The provisioner must create ~20 roles, which means iam:CreateRole and
# iam:AttachRolePolicy — and unfenced, that is a straight path to admin (mint a role with
# AdministratorAccess, assume it, done). So every role it creates MUST carry the permissions
# boundary, enforced by an iam:PermissionsBoundary condition, and the provisioner is explicitly
# denied the ability to alter the boundary or its own policies. That condition is what turns "trust
# us" into something a reviewer can actually sign.
#
# The policy DOCUMENTS are the deliverable: policies/*.json, plain IAM JSON, readable without
# knowing Terraform. This module is just what applies them. `make policies` renders them concrete.

variable "project" {
  description = "Name prefix owning the estate — every resource ARN fence keys off it."
  type        = string
  default     = "watch"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "trusted_principal_arns" {
  description = <<-EOT
    Who may assume the provisioner. In a member account this is the hub identity (the account root,
    or better, the hub's own provisioner role). In a single-account estate it is whatever human or
    OIDC role runs `make live`. Keep this list short: it is the front door.
  EOT
  type        = list(string)
}

variable "max_session_duration" {
  description = "A full `make live` is long; a full teardown is longer (NAT/ENI release). 4h."
  type        = number
  default     = 14400
}

variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  vars = {
    project    = var.project
    region     = var.region
    account_id = local.account_id
  }
  # One file per concern, because IAM caps a managed policy at 6144 characters and because a
  # reviewer reads them one at a time: what it may build, what it may store, what it may ship,
  # and — the one that matters — what it may do to IAM itself.
  policy_files = {
    core     = "watch-provisioner-core.json"
    data     = "watch-provisioner-data.json"
    delivery = "watch-provisioner-delivery.json"
    iam      = "watch-provisioner-iam.json"
  }
}

# The ceiling on every role the estate creates. Nothing the provisioner mints can exceed it.
resource "aws_iam_policy" "boundary" {
  name        = "${var.project}-boundary"
  description = "Permissions boundary: the ceiling on every IAM role the ${var.project} estate creates. Roles may use the account, but may never grant themselves IAM, touch the org/account/billing, or destroy the audit trail."
  policy      = file("${path.module}/../../policies/watch-boundary.json")
  tags        = var.tags
}

resource "aws_iam_policy" "provisioner" {
  for_each = local.policy_files

  name        = "${var.project}-provisioner-${each.key}"
  description = "What the ${var.project} provisioner may do: ${each.key}."
  policy      = templatefile("${path.module}/../../policies/${each.value}", local.vars)
  tags        = var.tags
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = var.trusted_principal_arns
    }
  }
}

resource "aws_iam_role" "provisioner" {
  name                 = "${var.project}-provisioner"
  description          = "OpenTofu runs as this. Replaces bootstrap-admin (ADR-044)."
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = var.max_session_duration
  tags                 = var.tags

  # NOT boundary-fenced itself: the provisioner is the thing doing the fencing. It is fenced by its
  # own four policies (which deny it any power over the boundary or over itself), by its trust
  # policy, and by the fact that it cannot mint an IAM user or an access key.
}

resource "aws_iam_role_policy_attachment" "provisioner" {
  for_each = aws_iam_policy.provisioner

  role       = aws_iam_role.provisioner.name
  policy_arn = each.value.arn
}

output "role_arn" {
  value = aws_iam_role.provisioner.arn
}

output "boundary_arn" {
  value = aws_iam_policy.boundary.arn
}

output "policy_arns" {
  value = [for p in aws_iam_policy.provisioner : p.arn]
}
