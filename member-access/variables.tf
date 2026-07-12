variable "hub_account_id" {
  description = "The account that runs terragrunt applies (your management/hub account) — trusted to assume this role."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.hub_account_id))
    error_message = "hub_account_id must be a 12-digit AWS account id."
  }
}

variable "role_name" {
  description = "Name of the role to mint. The default matches the org convention, so the root terragrunt needs no WATCH_MEMBER_ROLE_NAME override; use a custom name if your org reserves this one."
  type        = string
  default     = "OrganizationAccountAccessRole"
}

variable "policy_arn" {
  description = "Policy attached to the role. Admin by default (it IS the apply path); scope down if your org requires it — every stack this repo applies must fit whatever you attach."
  type        = string
  default     = "arn:aws:iam::aws:policy/AdministratorAccess"
}

variable "max_session_duration" {
  description = "Max STS session seconds."
  type        = number
  default     = 3600
}

variable "region" {
  description = "Provider region (IAM is global; this only anchors the provider)."
  type        = string
  default     = "us-east-1"
}

variable "tags" {
  type    = map(string)
  default = { component = "member-access", repo = "gotoplanb/platform" }
}
