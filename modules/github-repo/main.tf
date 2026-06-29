# Manage an EXISTING GitHub repo as code (platform#15): settings, an authoritative label
# set, the modern branch ruleset on the default branch, and repo-level Actions variables
# (OIDC role ARNs — never static AWS keys). The repo is imported, never created here;
# prevent_destroy guards the real repo against an accidental `terraform destroy`.

resource "github_repository" "this" {
  name         = var.repo
  description  = var.description
  homepage_url = var.homepage_url
  visibility   = var.visibility

  has_issues   = var.has_issues
  has_wiki     = var.has_wiki
  has_projects = var.has_projects

  allow_merge_commit     = var.allow_merge_commit
  allow_squash_merge     = var.allow_squash_merge
  allow_rebase_merge     = var.allow_rebase_merge
  allow_auto_merge       = var.allow_auto_merge
  delete_branch_on_merge = var.delete_branch_on_merge

  vulnerability_alerts = true

  lifecycle {
    prevent_destroy = true
    # Seed-only attributes that don't apply to an already-populated repo.
    ignore_changes = [auto_init, gitignore_template, license_template, template]
  }
}

# Authoritative: the complete label set for the repo. Anything not listed is removed.
resource "github_issue_labels" "this" {
  repository = github_repository.this.name

  dynamic "label" {
    for_each = var.labels
    content {
      name        = label.key
      color       = label.value.color
      description = label.value.description
    }
  }
}

# Modern ruleset on the default branch: block deletion + force-push always; PR and
# status-check requirements are opt-in (wired for the CI gate in #10) so solo pushes
# aren't blocked today. Repo admin can bypass.
resource "github_repository_ruleset" "main" {
  count = var.manage_ruleset ? 1 : 0

  name        = "main"
  repository  = github_repository.this.name
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion         = true
    non_fast_forward = true

    dynamic "required_status_checks" {
      for_each = length(var.required_status_checks) > 0 ? [1] : []
      content {
        dynamic "required_check" {
          for_each = var.required_status_checks
          content {
            context = required_check.value
          }
        }
        strict_required_status_checks_policy = true
      }
    }

    dynamic "pull_request" {
      for_each = var.require_pull_request ? [1] : []
      content {
        required_approving_review_count = var.required_approving_review_count
        dismiss_stale_reviews_on_push   = true
        require_last_push_approval      = false
      }
    }
  }

  dynamic "bypass_actors" {
    for_each = var.admin_bypass ? [1] : []
    content {
      actor_id    = 5 # repository Admin role
      actor_type  = "RepositoryRole"
      bypass_mode = "always"
    }
  }
}

resource "github_actions_variable" "this" {
  for_each = var.actions_variables

  repository    = github_repository.this.name
  variable_name = each.key
  value         = each.value
}
