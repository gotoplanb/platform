provider "aws" {
  region = var.region
  default_tags {
    tags = {
      project    = "watch"
      managed_by = "opentofu"
      component  = "tf-state-backend"
      repo       = "gotoplanb/platform"
    }
  }
}
