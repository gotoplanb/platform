# DNS + TLS (platform#13, ADR-006). ACM cert (us-east-1) for the app + status hostnames,
# DNS-validated via Cloudflare, plus the two subdomain CNAMEs (grey-cloud / DNS-only:
# records point straight at the ALB + CloudFront; TLS is ACM on AWS). We ONLY create the
# named subdomain + validation records — never the apex or any existing record.

data "cloudflare_zone" "this" {
  name = var.zone_name
}

# One cert covering both names (CloudFront requires us-east-1; the ALB is us-east-1 too).
resource "aws_acm_certificate" "this" {
  domain_name               = var.app_hostname
  subject_alternative_names = [var.status_hostname]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, { Name = var.app_hostname })
}

# ACM DNS-validation records — one per name, created as individual Cloudflare records.
resource "cloudflare_record" "validation" {
  for_each = {
    for o in aws_acm_certificate.this.domain_validation_options : o.domain_name => o
  }

  zone_id = data.cloudflare_zone.this.id
  name    = trimsuffix(each.value.resource_record_name, ".")
  type    = each.value.resource_record_type
  content = trimsuffix(each.value.resource_record_value, ".")
  proxied = false # DNS-only so ACM can validate
  ttl     = 60
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in cloudflare_record.validation : r.name]
}

# App -> ALB (grey-cloud CNAME).
resource "cloudflare_record" "app" {
  zone_id = data.cloudflare_zone.this.id
  name    = var.app_hostname
  type    = "CNAME"
  content = var.alb_dns_name
  proxied = false
  ttl     = 1 # auto
}

# Status page -> CloudFront (grey-cloud CNAME).
resource "cloudflare_record" "status" {
  zone_id = data.cloudflare_zone.this.id
  name    = var.status_hostname
  type    = "CNAME"
  content = var.cloudfront_domain
  proxied = false
  ttl     = 1
}

output "certificate_arn" {
  description = "Validated ACM cert ARN — wire into the ALB :443 listener + CloudFront."
  value       = aws_acm_certificate_validation.this.certificate_arn
}
