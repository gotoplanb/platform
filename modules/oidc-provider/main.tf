# The GitHub federation entry for ONE account (platform#57).
#
# An IAM OIDC provider is account-global: exactly one per URL per account. That makes it
# infrastructure, not a detail of whichever feature happens to want a federated role — so it gets
# its own owner, and consumers take an ARN. It used to be self-provisioned as a side-effect by
# modules/ci-pipeline-trigger, which worked only because the two owners happened to land in
# different accounts; in a single-account estate they collided (409 EntityAlreadyExists), and in an
# adopter's account that already runs GitHub Actions it would collide with THEIR provider.
#
# Hence `create`: an account that already federates GitHub sets create=false and passes its existing
# ARN through. Never fight an adopter's existing CI for ownership of a singleton.

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS no longer validates this for the well-known GitHub provider, but the field is kept.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
  tags = var.tags
}
