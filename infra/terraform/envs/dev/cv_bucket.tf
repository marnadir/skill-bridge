##bucket S3 privato dei CV; la presigned URL la genera la lambda
##backend-api (vedi backend_api.tf)

data "aws_caller_identity" "current" {}

##--- bucket S3 per i CV ---------------------------------------------

resource "aws_s3_bucket" "cv" {
  bucket = "${local.name_prefix}-cv-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "cv" {
  bucket = aws_s3_bucket.cv.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

##il browser carica direttamente sul bucket col presigned URL: serve
##il CORS per la PUT, limitato al dominio CloudFront del fe e al
##dev server locale
resource "aws_s3_bucket_cors_configuration" "cv" {
  bucket = aws_s3_bucket.cv.id

  cors_rule {
    allowed_methods = ["PUT"]
    allowed_origins = local.fe_origins
    allowed_headers = ["content-type"]
    max_age_seconds = 3600
  }
}
