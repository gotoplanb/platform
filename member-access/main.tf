# Hub-assumable access role for a member account (platform#50, existing-org topology).
#
# Accounts CREATED by an AWS Organization get OrganizationAccountAccessRole automatically;
# accounts INVITED into an org (or managed by a landing zone that vends a different role) may
# have no role the hub can assume. This standalone module mints one. Like ./bootstrap it uses
# LOCAL state and is applied ONCE per member account WITH THAT MEMBER'S credentials —
# chicken-and-egg: the hub can't assume in until this exists.
#
# Default role name matches the OrganizationAccountAccessRole convention so no
# WATCH_MEMBER_ROLE_NAME override is needed afterward; pass role_name to mint a custom-named
# role instead (then set WATCH_MEMBER_ROLE_NAME to it).

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "AWS"
      # Account-root principal — the same trust shape OrganizationAccountAccessRole uses: any
      # identity in the hub account whose own IAM policy allows sts:AssumeRole on this ARN.
      identifiers = ["arn:aws:iam::${var.hub_account_id}:root"]
    }
  }
}

resource "aws_iam_role" "access" {
  name                 = var.role_name
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = var.max_session_duration
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "access" {
  role       = aws_iam_role.access.name
  policy_arn = var.policy_arn
}
