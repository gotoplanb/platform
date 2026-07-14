# Shared inputs for the github-as-code stacks (platform#15). The canonical label set,
# applied authoritatively to every managed repo so labels stay identical across the
# estate. Read by each stack via read_terragrunt_config(".../common.hcl").
locals {
  github_owner = "gotoplanb"

  labels = {
    "bug"              = { color = "d73a4a", description = "Something isn't working" }
    "documentation"    = { color = "0075ca", description = "Improvements or additions to documentation" }
    "drift"            = { color = "b60205", description = "AWS was changed outside terragrunt — the nightly drift report (ADR-046) owns this label" }
    "duplicate"        = { color = "cfd3d7", description = "This issue or pull request already exists" }
    "enhancement"      = { color = "a2eeef", description = "New feature or request" }
    "epic"             = { color = "5319e7", description = "Tracking epic" }
    "good first issue" = { color = "7057ff", description = "Good for newcomers" }
    "help wanted"      = { color = "008672", description = "Extra attention is needed" }
    "infra"            = { color = "1d76db", description = "AWS / Terragrunt infrastructure" }
    "invalid"          = { color = "e4e669", description = "This doesn't seem right" }
    "question"         = { color = "d876e3", description = "Further information is requested" }
    "spec-gap"         = { color = "5319e7", description = "Open question / gap in the v1 spec to resolve before build" }
    "tech-debt"        = { color = "d93f0b", description = "Cleanup / expedient to revisit (e.g. stopgaps for external blockers)" }
    "wontfix"          = { color = "ffffff", description = "This will not be worked on" }
  }
}
