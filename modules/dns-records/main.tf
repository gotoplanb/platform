# App + status subdomain CNAMEs -> ALB / CloudFront (platform#34). Split from the cert
# (modules/acm-cert) so the records can point at the app/frontend that are created AFTER the
# cert. Ephemeral: these point at resources destroyed on teardown, so teardown drops them
# (via -target) to keep a later create clean; the cert stack is kept. Only named subdomains,
# never the apex.

variable "zone_name" { type = string }
variable "app_hostname" { type = string }
variable "alb_dns_name" { type = string }
variable "status_hostname" { type = string }
variable "cloudfront_domain" { type = string }

data "cloudflare_zone" "this" {
  name = var.zone_name
}

resource "cloudflare_record" "app" {
  zone_id = data.cloudflare_zone.this.id
  name    = var.app_hostname
  type    = "CNAME"
  content = var.alb_dns_name
  proxied = false
  ttl     = 1 # auto
}

resource "cloudflare_record" "status" {
  zone_id = data.cloudflare_zone.this.id
  name    = var.status_hostname
  type    = "CNAME"
  content = var.cloudfront_domain
  proxied = false
  ttl     = 1
}
