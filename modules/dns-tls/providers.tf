# Cloudflare provider — token from CLOUDFLARE_API_TOKEN in the env (zone-scoped Edit zone
# DNS). required_providers (cloudflare source) is added to the stack's generated versions.tf
# (one required_providers block per module). `set -a; source .env; set +a` before running.
provider "cloudflare" {}
