##frontend hosting: private S3 bucket + CloudFront with OAC. The
##build deploy (s3 sync + invalidation) is done by the frontend
##pipeline on merge to main

resource "aws_s3_bucket" "fe" {
  bucket = var.bucket_name
}


resource "aws_s3_bucket_public_access_block" "fe" {
  bucket = aws_s3_bucket.fe.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}


##only CloudFront (this distribution) can read from the bucket
resource "aws_s3_bucket_policy" "fe" {
  bucket = aws_s3_bucket.fe.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.fe.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.fe.arn
        }
      }
    }]
  })
}
