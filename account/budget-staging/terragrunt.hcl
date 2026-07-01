# Per-environment daily budget for staging (platform#31). Scoped to env=staging via the
# activated `env` cost-allocation tag. Staging is single-AZ + ephemeral, so a lower cap.
# Same ~24h cost-allocation-tag activation lag as budget-prod.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

terraform {
  source = "${get_repo_root()}//modules/budget"
}

inputs = {
  name                = "watch-staging-daily"
  amount              = 6 # staging ha (single-AZ) daily (USD), placeholder
  time_unit           = "DAILY"
  thresholds          = [80, 100]
  notification_emails = ["davestanton.us@gmail.com"]
  cost_filters        = { TagKeyValue = ["user:env$staging"] }
}
