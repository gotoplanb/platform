# Per-member read-only CI role (ADR-020 hardening). The management-account `gha-plan` OIDC role
# assumes THIS role to run `terragrunt plan` against a member account. Least-privilege: the plan
# path can never mutate a member — it gets ReadOnlyAccess here, NOT the admin
# OrganizationAccountAccessRole (which stays the apply path). Trust is exactly the gha-plan role.

variable "name" {
  type    = string
  default = "watch-ci-plan"
}
variable "trusted_plan_role_arn" {
  description = "The management-account gha-plan role allowed to assume this read-only role."
  type        = string
}
variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [var.trusted_plan_role_arn]
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.name
  description          = "Cross-account read-only role for terragrunt plan (assumed by gha-plan)."
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "readonly" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

output "role_arn" {
  value = aws_iam_role.this.arn
}
