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
