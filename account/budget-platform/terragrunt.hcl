# Per-environment daily budget for the PLATFORM plane (platform#31). The third cost bucket
# alongside prod + staging: shared/foundation resources that outlive envs — ECR, the GitHub
# connection, the CI-trigger role, and (later) the Watchtower LGTM slice + SonarQube server
# (ADR-018). Scoped to env=platform, so those stacks must carry that tag (see below). Same
# ~24h cost-allocation-tag activation lag.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

terraform {
  source = "${get_repo_root()}//modules/budget"
}

inputs = {
  name                = "watch-platform-daily"
  amount              = 6 # placeholder; grows when the Watchtower slice + Sonar land (#29/#21)
  time_unit           = "DAILY"
  thresholds          = [80, 100]
  notification_emails = ["davestanton.us@gmail.com"]
  cost_filters        = { TagKeyValue = ["user:env$platform"] }
}
