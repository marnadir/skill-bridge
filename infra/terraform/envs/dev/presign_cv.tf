##upload CV via presigned URL: bucket S3 privato + lambda che genera
##l'URL firmato, esposta al frontend tramite Lambda Function URL

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

##--- lambda presign -------------------------------------------------

##VINCOLO: nome ruolo col prefisso skillbridge-* (vedi main.tf)
resource "aws_iam_role" "presign_cv" {
  name = "${local.name_prefix}-presign-cv-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

##inline policy (niente managed policy: il ruolo CI non deve fare attach)
resource "aws_iam_role_policy" "presign_cv" {
  name = "presign-cv"
  role = aws_iam_role.presign_cv.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PutCv"
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cv.arn}/cv/*"
      },
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:*"
      },
    ]
  })
}

data "archive_file" "presign_cv" {
  type        = "zip"
  source_dir  = "${path.module}/../../../../backend/presign-cv"
  output_path = "${path.module}/.terraform/tmp/presign-cv.zip"
  excludes    = ["__pycache__"]
}

resource "aws_lambda_function" "presign_cv" {
  function_name = "${local.name_prefix}-presign-cv"
  role          = aws_iam_role.presign_cv.arn

  filename         = data.archive_file.presign_cv.output_path
  source_code_hash = data.archive_file.presign_cv.output_base64sha256

  runtime = "python3.13"
  handler = "lambda_function.lambda_handler"
  timeout = 10

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.cv.bucket
    }
  }
}

##endpoint pubblico per il frontend; il CORS lo gestisce la function url
resource "aws_lambda_function_url" "presign_cv" {
  function_name      = aws_lambda_function.presign_cv.function_name
  authorization_type = "NONE"

  cors {
    allow_origins = local.fe_origins
    allow_methods = ["POST"]
    allow_headers = ["content-type"]
    max_age       = 3600
  }
}

##da usare come VITE_API_BASE_URL nel frontend
output "presign_cv_url" {
  value = aws_lambda_function_url.presign_cv.function_url
}
