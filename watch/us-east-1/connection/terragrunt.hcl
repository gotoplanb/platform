# Persistent GitHub connection for the region (platform#33). Kept across teardowns (like ecr
# + the ACM cert) — authorize it ONCE, then the pipeline's push trigger (#24) registers
# against an already-AVAILABLE connection on every recreate. teardown.sh never destroys this.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

terraform {
  source = "${get_repo_root()}//modules/connection"
}

inputs = {
  name = "watch-github"
  tags = { project = "watch", env = "platform" }
}
