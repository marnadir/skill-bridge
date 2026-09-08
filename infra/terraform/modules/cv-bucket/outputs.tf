output "bucket_id" {
  description = "Bucket name/id"
  value       = aws_s3_bucket.cv.id
}

output "bucket_arn" {
  description = "Bucket ARN"
  value       = aws_s3_bucket.cv.arn
}
