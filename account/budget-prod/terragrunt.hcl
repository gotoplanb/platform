# Per-environment daily budget for prod (platform#31). Scoped to resources tagged env=prod
# via the activated `env` cost-allocation tag (see account/budgets). Placeholder limit — tune
# with real spend. NOTE: the env cost-allocation tag has a ~24h activation lag and only counts
# spend going forward, so this tracks $0 until then.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

terraform {
  source = "${get_repo_root()}//modules/budget"
}

inputs = {
  name                = "watch-prod-daily"
  amount              = 8 # prod ha daily (USD), placeholder
  time_unit           = "DAILY"
  thresholds          = [80, 100]
  notification_emails = ["davestanton.us@gmail.com"]
  cost_filters        = { TagKeyValue = ["user:env$prod"] }
}
