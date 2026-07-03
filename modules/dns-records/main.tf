# App + status subdomain CNAMEs -> ALB / CloudFront (platform#34). Split from the cert
# (modules/acm-cert) so the records can point at the app/frontend that are created AFTER the
# cert. Ephemeral: these point at resources destroyed on teardown, so teardown drops them
# (via -target) to keep a later create clean; the cert stack is kept. Only named subdomains,
# never the apex.
#
# Each record is gated on its target being set (empty => count 0), so a stack can create JUST
# the app record or JUST the status record. This decouples the API hostname from the frontend:
# a CloudFront outage/hold (e.g. new-account verification, ADR-020) blocks only the status stack,
# not watch.<domain>. prod/dns creates the app record; prod/dns-status the status record.

variable "zone_name" { type = string }
variable "app_hostname" {
  type    = string
  default = ""
}
variable "alb_dns_name" {
  type    = string
  default = ""
}
variable "status_hostname" {
  type    = string
  default = ""
}
variable "cloudfront_domain" {
  type    = string
  default = ""
}

data "cloudflare_zone" "this" {
  name = var.zone_name
}

resource "cloudflare_record" "app" {
  count   = var.alb_dns_name != "" ? 1 : 0
  zone_id = data.cloudflare_zone.this.id
  name    = var.app_hostname
  type    = "CNAME"
  content = var.alb_dns_name
  proxied = false
  ttl     = 1 # auto
}

resource "cloudflare_record" "status" {
  count   = var.cloudfront_domain != "" ? 1 : 0
  zone_id = data.cloudflare_zone.this.id
  name    = var.status_hostname
  type    = "CNAME"
  content = var.cloudfront_domain
  proxied = false
  ttl     = 1
}

# Adopt pre-count state (e.g. staging/dns, which created both records before the app/status split)
# into the count-indexed addresses so existing CNAMEs are not destroyed+recreated. No-ops where the
# source never existed (the never-applied prod/dns + prod/dns-status stacks).
moved {
  from = cloudflare_record.app
  to   = cloudflare_record.app[0]
}
moved {
  from = cloudflare_record.status
  to   = cloudflare_record.status[0]
}
