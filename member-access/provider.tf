provider "aws" {
  region = var.region
  default_tags {
    tags = {
      managed_by = "opentofu"
      component  = "member-access"
      repo       = "gotoplanb/platform"
    }
  }
}
