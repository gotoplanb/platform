output "bucket_name" {
  description = "Sync the built status page here (deploy step)."
  value       = aws_s3_bucket.site.bucket
}

output "distribution_id" {
  description = "Invalidate this after a sync (deploy step)."
  value       = aws_cloudfront_distribution.site.id
}

output "distribution_domain_name" {
  description = "*.cloudfront.net domain (the #13 DNS record points at this)."
  value       = aws_cloudfront_distribution.site.domain_name
}

output "distribution_arn" {
  value = aws_cloudfront_distribution.site.arn
}
