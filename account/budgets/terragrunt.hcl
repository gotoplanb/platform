# Account cost guardrail. Daily spend budget ($10 placeholder) with email alerts —
# account-wide for now. Per-environment budgets are one more module instance each, scoped
# by the env tag (cost_filters = { TagKeyValue = ["user:env$prod"] }); see the issue.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

terraform {
  source = "${get_repo_root()}//modules/budget"
}

inputs = {
  name                = "watch-daily-cost"
  amount              = 20 # overall daily cap (USD) — covers prod + staging + foundation (#31)
  time_unit           = "DAILY"
  thresholds          = [80, 100]
  notification_emails = ["davestanton.us@gmail.com"]

  # Activate the env tag for cost allocation (once) so the per-env budgets can filter on it.
  cost_allocation_tags = ["env"]
}
