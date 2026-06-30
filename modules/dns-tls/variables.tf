variable "zone_name" {
  description = "Cloudflare zone (apex domain), e.g. davestanton.com. We only ever create the named subdomain records below — never apex/MX/existing records."
  type        = string
}

variable "app_hostname" {
  description = "FQDN for the app/API -> ALB (e.g. watch.davestanton.com)."
  type        = string
}

variable "status_hostname" {
  description = "FQDN for the status page -> CloudFront (e.g. status.davestanton.com)."
  type        = string
}

variable "alb_dns_name" {
  description = "App ALB DNS name (#6) — the app CNAME target."
  type        = string
}

variable "cloudfront_domain" {
  description = "CloudFront distribution domain (#9) — the status CNAME target."
  type        = string
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "tags" {
  type    = map(string)
  default = {}
}
