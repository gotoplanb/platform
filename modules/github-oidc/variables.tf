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
