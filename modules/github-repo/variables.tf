variable "repo" {
  description = "Repository name (must already exist; this module manages, not creates)."
  type        = string
}

variable "github_owner" {
  description = "Account/owner login. Token comes from GITHUB_TOKEN env var."
  type        = string
  default     = "gotoplanb"
}

variable "description" {
  description = "Repo description."
  type        = string
  default     = ""
}

variable "homepage_url" {
  description = "Repo homepage."
  type        = string
  default     = ""
}

variable "visibility" {
  description = "public/private. Public keeps rulesets free."
  type        = string
  default     = "public"
}

variable "has_issues" {
  type    = bool
  default = true
}

variable "has_wiki" {
  type    = bool
  default = false
}

variable "has_projects" {
  type    = bool
  default = true
}

variable "allow_merge_commit" {
  type    = bool
  default = true
}

variable "allow_squash_merge" {
  type    = bool
  default = true
}

variable "allow_rebase_merge" {
  type    = bool
  default = true
}

variable "allow_auto_merge" {
  type    = bool
  default = false
}

variable "delete_branch_on_merge" {
  type    = bool
  default = true
}

variable "labels" {
  description = "Authoritative label set (name => {color, description}). Labels not listed are removed."
  type = map(object({
    color       = string
    description = string
  }))
  default = {}
}

variable "actions_variables" {
  description = "Repo-level GitHub Actions variables (NAME => value). For OIDC role ARNs — never static AWS keys."
  type        = map(string)
  default     = {}
}

# ---- main-branch ruleset ----------------------------------------------------

variable "manage_ruleset" {
  description = "Create the modern ruleset on the default branch."
  type        = bool
  default     = true
}

variable "require_pull_request" {
  description = "Require a PR to merge to the default branch. Off for solo flow until the CI gate (#10) exists."
  type        = bool
  default     = false
}

variable "required_approving_review_count" {
  type    = number
  default = 0
}

variable "required_status_checks" {
  description = "Status check contexts that must pass (e.g. the CodeBuild gate from #10). Empty = none yet."
  type        = list(string)
  default     = []
}

variable "admin_bypass" {
  description = "Let the repository admin bypass the ruleset (keeps the solo owner unblocked when checks tighten)."
  type        = bool
  default     = true
}
