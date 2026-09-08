##hosting del frontend: bucket S3 privato + CloudFront con OAC.
##Il deploy della build (s3 sync + invalidation) lo fa la pipeline
##.github/workflows/frontend.yml al merge su main

##origini autorizzate a chiamare la lambda presign e la PUT sul
##bucket cv: il dominio CloudFront + il dev server vite locale
locals {
  fe_origins = [
    "https://${aws_cloudfront_distribution.fe.domain_name}",
    "http://localhost:5173",
  ]
}

##--- bucket S3 con la build ----------------------------------------

resource "aws_s3_bucket" "fe" {
  bucket = "${local.name_prefix}-fe-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "fe" {
  bucket = aws_s3_bucket.fe.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

##solo CloudFront (questa distribution) puo' leggere dal bucket
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

##--- CloudFront -----------------------------------------------------

resource "aws_cloudfront_origin_access_control" "fe" {
  name                              = "${local.name_prefix}-fe"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "fe" {
  enabled             = true
  comment             = "${local.name_prefix} frontend"
  default_root_object = "index.html"
  price_class         = "PriceClass_100" ##solo edge EU/Nord America

  origin {
    origin_id                = "s3-fe"
    domain_name              = aws_s3_bucket.fe.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.fe.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-fe"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    ##managed policy CachingOptimized
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  ##SPA: le rotte client-side devono ricadere su index.html
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

##--- output per la pipeline di deploy -------------------------------

output "fe_bucket" {
  value = aws_s3_bucket.fe.bucket
}

output "fe_distribution_id" {
  value = aws_cloudfront_distribution.fe.id
}

output "fe_url" {
  value = "https://${aws_cloudfront_distribution.fe.domain_name}"
}
