# ACM cert (us-east-1) for an app + status hostname pair, DNS-validated via Cloudflare.
# Split from the CNAME records (modules/dns-records) so the cert can be created BEFORE the
# app/frontend that consume it — this breaks the app<->dns bootstrap cycle (the app looks the
# cert up / takes its ARN, so the cert must already exist). Kept across teardowns like prod's
# cert; only the app/status CNAMEs are ephemeral (platform#34).

variable "zone_name" { type = string }
variable "app_hostname" { type = string }
variable "status_hostname" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}

data "cloudflare_zone" "this" {
  name = var.zone_name
}

resource "aws_acm_certificate" "this" {
  domain_name               = var.app_hostname
  subject_alternative_names = [var.status_hostname]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, { Name = var.app_hostname })
}

# One DNS-validation CNAME per name (individual Cloudflare records; never the apex).
resource "cloudflare_record" "validation" {
  for_each = {
    for o in aws_acm_certificate.this.domain_validation_options : o.domain_name => o
  }

  zone_id = data.cloudflare_zone.this.id
  name    = trimsuffix(each.value.resource_record_name, ".")
  type    = each.value.resource_record_type
  content = trimsuffix(each.value.resource_record_value, ".")
  proxied = false
  ttl     = 60
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in cloudflare_record.validation : r.name]
}

output "certificate_arn" {
  description = "Validated ACM cert ARN — wired into the app :443 listener + the frontend CloudFront."
  value       = aws_acm_certificate_validation.this.certificate_arn
}
