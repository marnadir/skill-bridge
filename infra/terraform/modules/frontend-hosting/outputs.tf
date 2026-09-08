output "bucket" {
  description = "Frontend bucket name"
  value       = aws_s3_bucket.fe.bucket
}

output "distribution_id" {
  description = "CloudFront distribution id (for invalidations)"
  value       = aws_cloudfront_distribution.fe.id
}

output "domain_name" {
  description = "CloudFront domain name"
  value       = aws_cloudfront_distribution.fe.domain_name
}

output "url" {
  description = "Public frontend URL"
  value       = "https://${aws_cloudfront_distribution.fe.domain_name}"
}
