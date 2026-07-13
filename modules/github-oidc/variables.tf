variable "github_org" {
  description = "GitHub org/user that owns the repos."
  type        = string
  default     = "gotoplanb"
}

variable "repo" {
  description = "Repo whose GitHub Actions may assume these roles (the IaC repo)."
  type        = string
  default     = "platform"
}

variable "apply_branch" {
  description = "Branch whose runs may assume the write/apply role."
  type        = string
  default     = "main"
}

variable "name_prefix" {
  description = "Prefix for the created IAM role names."
  type        = string
  default     = "gha" # github-actions
}

variable "member_plan_role_arns" {
  description = "Member-account read-only roles the plan role may assume for cross-account plan (ADR-020)."
  type        = list(string)
  default     = []
}

variable "provisioner_role_arns" {
  description = <<-EOT
    The provisioner roles (this account's and each member's) that the APPLY role may assume (ADR-044).
    Non-empty means CI apply holds no powers of its own — it can only become the provisioner, whose
    rights are the reviewable documents in policies/. Empty falls back to the legacy AdministratorAccess
    attachment, for an estate that hasn't adopted the fence yet.
  EOT
  type        = list(string)
  default     = []
}

variable "permissions_boundary" {
  description = "Permissions boundary applied to every role this module creates (ADR-044). Empty = none, for estates that have not adopted the fence."
  type        = string
  default     = ""
}
