output "oidc_provider_arn" {
  description = "ARN of this account's GitHub federation entry, whether we created it or it was already there. The ARN is fully determined by the account and the URL, so consumers can also derive it without a dependency."
  value       = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

data "aws_caller_identity" "current" {}
