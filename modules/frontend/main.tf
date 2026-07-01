# Frontend stack (platform#9, ADR-005/011): the read-only React status page on S3 +
# CloudFront. Private bucket reached only via CloudFront Origin Access Control (no public
# bucket). Cache split so a deploy never serves a half-old bundle: the default behavior
# (index.html / root) is short-TTL; fingerprinted /assets/* is long-TTL immutable.
# The build -> `aws s3 sync` -> CloudFront invalidation runs in the deploy step; #13 adds
# the custom domain + ACM cert (aliases/acm_certificate_arn).

# Find the cert by domain (the DNS stack #13 created + validated it) — no dependency cycle.
data "aws_acm_certificate" "this" {
  count       = var.cert_domain != "" ? 1 : 0
  domain      = var.cert_domain
  statuses    = ["ISSUED"]
  most_recent = true
}

locals {
  cert_arn          = var.cert_domain != "" ? data.aws_acm_certificate.this[0].arn : var.acm_certificate_arn
  use_custom_domain = length(var.aliases) > 0 && local.cert_arn != ""
  has_api           = var.api_origin_domain != ""
}

# Forward everything except Host so the ALB sees its own host (matches ALLOWED_HOSTS).
data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

resource "aws_s3_bucket" "site" {
  bucket        = "${var.name}-site"
  force_destroy = true # ephemeral test loop (ADR-015)
  tags          = merge(var.tags, { Name = "${var.name}-site" })
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${var.name}-site"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Managed cache policies: long/immutable for fingerprinted assets, disabled for index.html.
data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

# Security response headers for the status page (#30) — HSTS at the edge (immediate, no app
# code). include_subdomains scopes only to status.'s subdomains, not the apex; preload off.
resource "aws_cloudfront_response_headers_policy" "security" {
  name = "${var.name}-security-headers"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = false
      override                   = true
    }
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
  }
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  default_root_object = "index.html"
  price_class         = var.price_class
  comment             = "${var.name} status page"
  aliases             = var.aliases

  origin {
    origin_id                = "s3"
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  # Optional API proxy origin (the ALB). Viewer side stays HTTPS; CloudFront talks HTTP
  # to the ALB — so the status page is same-origin HTTPS with no mixed-content/CORS.
  dynamic "origin" {
    for_each = local.has_api ? [1] : []
    content {
      origin_id   = "alb"
      domain_name = var.api_origin_domain
      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "http-only"
        origin_ssl_protocols   = ["TLSv1.2"]
      }
    }
  }

  # Default (index.html / root): SHORT TTL so a new deploy is picked up immediately.
  default_cache_behavior {
    target_origin_id           = "s3"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id # HSTS (#30)
    compress                   = true
  }

  # Fingerprinted bundles: LONG TTL, immutable.
  ordered_cache_behavior {
    path_pattern               = "/assets/*"
    target_origin_id           = "s3"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
    compress                   = true
  }

  # /api/* -> ALB (no caching; forward everything but Host). Lets the SPA poll /api/status.
  dynamic "ordered_cache_behavior" {
    for_each = local.has_api ? [1] : []
    content {
      path_pattern             = "/api/*"
      target_origin_id         = "alb"
      viewer_protocol_policy   = "redirect-to-https"
      allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods           = ["GET", "HEAD"]
      cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
      origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
      compress                 = true
    }
  }

  # SPA routing: unknown paths fall back to index.html.
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  dynamic "viewer_certificate" {
    for_each = local.use_custom_domain ? [1] : []
    content {
      acm_certificate_arn      = local.cert_arn
      ssl_support_method       = "sni-only"
      minimum_protocol_version = "TLSv1.2_2021"
    }
  }

  dynamic "viewer_certificate" {
    for_each = local.use_custom_domain ? [] : [1]
    content {
      cloudfront_default_certificate = true
    }
  }

  tags = merge(var.tags, { Name = "${var.name}-site" })
}

# Bucket policy: only this CloudFront distribution (via OAC) may read.
data "aws_iam_policy_document" "site" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site.json
}
